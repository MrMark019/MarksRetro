// retrobridge - local HTTP->HTTPS TLS bridge for legacy Windows (XP+)
// Built with Go 1.10 (last release supporting Windows XP).
//
// The XP machine's micro-agent speaks plain HTTP only; this bridge
// listens on 127.0.0.1 and forwards to an OpenAI-compatible HTTPS
// endpoint with its own TLS 1.2 stack (independent of SChannel).
//
// Usage:
//   retrobridge.exe -listen 127.0.0.1:8787 -upstream https://host/v1 [-cacert ca-bundle.crt]
package main

import (
	"bytes"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

var (
	listen   = flag.String("listen", "127.0.0.1:8787", "plain HTTP listen address")
	upstream = flag.String("upstream", "https://dashscope.aliyuncs.com/compatible-mode", "HTTPS upstream base (micro-agent always appends /v1/chat/completions itself)")
	cacert   = flag.String("cacert", "", "PEM CA bundle (recommended on XP; empty = system store)")
	debug    = flag.Bool("debug", false, "log request bodies (first 4KB) for debugging")
	check    = flag.Bool("check", false, "verify system clock plausibility and exit (0=ok, 3=clock wrong)")
	ping     = flag.Bool("ping", false, "probe the listen address: exit 0 if a bridge answers /health, 3 otherwise")
	logf     = flag.String("log", "", "append log lines to this file as well as stdout")
)

func newTransport() *http.Transport {
	tr := &http.Transport{
		DialContext: (&net.Dialer{
			Timeout:   15 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		TLSHandshakeTimeout:   20 * time.Second,
		ExpectContinueTimeout: 2 * time.Second,
		MaxIdleConnsPerHost:   8,
	}
	// Disable HTTP/2: keep SSE chunked streaming simple and predictable.
	tr.TLSNextProto = make(map[string]func(string, *tls.Conn) http.RoundTripper)

	cfg := &tls.Config{}
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	if *cacert != "" {
		pem, e := ioutil.ReadFile(*cacert)
		if e != nil {
			log.Printf("[bridge] WARN cannot read cacert %s: %v (falling back to system store)", *cacert, e)
		} else if !pool.AppendCertsFromPEM(pem) {
			log.Printf("[bridge] WARN no certs parsed from %s", *cacert)
		} else {
			log.Printf("[bridge] CA bundle loaded: %s", *cacert)
		}
	}
	cfg.RootCAs = pool
	cfg.MinVersion = tls.VersionTLS12
	tr.TLSClientConfig = cfg
	return tr
}

// ── Runtime-switchable upstream (fork addition) ─────────────────────────
// upstream.txt (next to the exe) overrides the -upstream flag at startup.
// POST /__admin/upstream switches it live and rewrites that file, so the
// choice survives restarts without touching retro.ini or agent.bat.
// Only ever reachable on the loopback listener; this box is single-user.
var (
	upMu   sync.RWMutex
	upFile string // path of upstream.txt ("" = cannot persist)
)

func currentUpstream() string {
	upMu.RLock()
	defer upMu.RUnlock()
	return *upstream
}

func setUpstream(u string) {
	upMu.Lock()
	*upstream = u
	p := upFile
	upMu.Unlock()
	if p != "" {
		if err := ioutil.WriteFile(p, []byte(u+"\n"), 0644); err != nil {
			log.Printf("[bridge] WARN persist upstream.txt: %v", err)
		}
	}
}

func adminHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case "GET":
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"ok":true,"upstream":%q}`, currentUpstream())
	case "POST":
		b, err := ioutil.ReadAll(io.LimitReader(r.Body, 2048))
		if err != nil {
			http.Error(w, `{"ok":false,"error":"read body"}`, http.StatusBadRequest)
			return
		}
		u := strings.TrimSpace(string(b))
		low := strings.ToLower(u)
		if !strings.HasPrefix(low, "http://") && !strings.HasPrefix(low, "https://") {
			http.Error(w, `{"ok":false,"error":"must start with http:// or https://"}`, http.StatusBadRequest)
			return
		}
		u = strings.TrimRight(u, "/")
		setUpstream(u)
		log.Printf("[bridge] upstream switched to %s", u)
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprintf(w, `{"ok":true,"upstream":%q}`, u)
	default:
		http.Error(w, `{"ok":false,"error":"method"}`, http.StatusMethodNotAllowed)
	}
}

func loadUpstreamFile() {
	exe, err := os.Executable()
	if err != nil {
		return
	}
	p := filepath.Join(filepath.Dir(exe), "upstream.txt")
	upMu.Lock()
	upFile = p
	upMu.Unlock()
	data, err := ioutil.ReadFile(p)
	if err != nil {
		return // no file: flag/config default stands
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(strings.Trim(strings.TrimSpace(line), "\r"))
		if line == "" || strings.HasPrefix(line, ";") || strings.HasPrefix(line, "#") {
			continue
		}
		setUpstream(strings.TrimRight(line, "/"))
		log.Printf("[bridge] upstream from upstream.txt: %s", currentUpstream())
		return
	}
}

var client *http.Client // built in main() AFTER flag.Parse(), so -cacert is honored

func handler(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	if r.URL.Path == "/health" {
		w.Header().Set("Content-Type", "text/plain")
		w.Write([]byte("ok"))
		return
	}
	if r.URL.Path == "/__admin/upstream" {
		adminHandler(w, r)
		return
	}

	target := strings.TrimRight(currentUpstream(), "/")
	// Guard against double /v1: if upstream already ends with /v1 but the
	// client also sent /v1/... (older configs), strip the duplicate segment.
	path := r.URL.Path
	if strings.HasSuffix(target, "/v1") && strings.HasPrefix(path, "/v1/") {
		path = path[len("/v1"):]
	}
	target += path
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}

	req, err := http.NewRequest(r.Method, target, r.Body)
	if err != nil {
		http.Error(w, `{"error":"bridge: bad request"}`, http.StatusBadGateway)
		return
	}
	if *debug {
		hl := make([]string, 0, 16)
		for k, vs := range r.Header {
			hl = append(hl, k + "=" + strings.Join(vs, ","))
		}
		sort.Strings(hl)
		log.Printf("[bridge] DEBUG headers: %s", strings.Join(hl, " | "))
	}
	if *debug && r.ContentLength != 0 {
		// buffer body for logging, then re-attach for upstream
		bb, _ := ioutil.ReadAll(io.LimitReader(r.Body, 4096))
		if r.ContentLength < 0 || int64(len(bb)) < r.ContentLength {
			rest, _ := ioutil.ReadAll(r.Body)
			bb = append(bb, rest...)
		}
		h := sha256.Sum256(bb)
		head := bb
		if len(head) > 60 { head = head[:60] }
		tail := bb
		if len(tail) > 60 { tail = tail[len(tail)-60:] }
		log.Printf("[bridge] DEBUG FORENSIC CL=%d read=%d sha=%q head=%q tail=%q",
			r.ContentLength, len(bb), string(h[:8]), string(head), string(tail))
		req.Body = ioutil.NopCloser(bytes.NewReader(bb))
		req.ContentLength = int64(len(bb))
	}
	// Copy headers except Host (net/http sets Host/SNI from target URL).
	// Also drop Accept-Encoding: keep upstream responses uncompressed so the
	// bridge can stream/inspect them transparently (loopback traffic anyway).
	for k, vs := range r.Header {
		if strings.EqualFold(k, "Host") || strings.EqualFold(k, "Accept-Encoding") {
			continue
		}
		for _, v := range vs {
			req.Header.Add(k, v)
		}
	}

	resp, err := client.Do(req)
	if err != nil {
		log.Printf("[bridge] %s %s -> UPSTREAM ERROR: %v", r.Method, r.URL.Path, err)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusBadGateway)
		fmt.Fprintf(w, `{"error":"bridge upstream: %s"}`, strings.Replace(err.Error(), `"`, `'`, -1))
		return
	}
	defer resp.Body.Close()

	// On upstream errors, log the response body (it contains the exact reason).
	if resp.StatusCode >= 400 {
		eb, _ := ioutil.ReadAll(io.LimitReader(resp.Body, 4096))
		log.Printf("[bridge] upstream %d body: %s", resp.StatusCode, strings.Replace(string(eb), "\n", " ", -1))
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(resp.StatusCode)
		w.Write(eb)
		log.Printf("[bridge] %s %s -> %d (%dms)", r.Method, r.URL.Path, resp.StatusCode, time.Since(start).Nanoseconds()/1e6)
		return
	}

	for k, vs := range resp.Header {
		if strings.EqualFold(k, "Content-Encoding") || strings.EqualFold(k, "Content-Length") {
			continue
		}
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)

	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 16*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, we := w.Write(buf[:n]); we != nil {
				break
			}
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			if err != io.EOF {
				log.Printf("[bridge] stream end: %v", err)
			}
			break
		}
	}
	log.Printf("[bridge] %s %s -> %d (%dms)", r.Method, r.URL.Path, resp.StatusCode, time.Since(start).Nanoseconds()/1e6)
}

func main() {
	flag.Parse()
	if *logf != "" {
		if f, err := os.OpenFile(*logf, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644); err == nil {
			log.SetOutput(io.MultiWriter(os.Stderr, f))
		}
	}
	if *ping {
		client := &http.Client{Transport: &http.Transport{}, Timeout: 1500 * time.Millisecond}
		resp, err := client.Get("http://" + *listen + "/health")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode == 200 {
				fmt.Println("bridge ready on", *listen)
				os.Exit(0)
			}
			err = fmt.Errorf("status %d", resp.StatusCode)
		}
		fmt.Println("bridge not answering:", err)
		os.Exit(3)
	}
	if *check {
		// Clock guard for batch launchers: dead-CMOS machines drift to 2001
		// and every TLS cert then fails validation with confusing errors.
		y := time.Now().Year()
		if y < 2020 || y > 2035 {
			fmt.Printf("clock wrong: year=%d\n", y)
			os.Exit(3)
		}
		fmt.Printf("clock ok: year=%d\n", y)
		os.Exit(0)
	}
	loadUpstreamFile()
	client = &http.Client{Transport: newTransport()}
	log.SetFlags(log.Ltime)
	log.Printf("[bridge] listening http://%s  upstream=%s", *listen, *upstream)

	srv := &http.Server{
		Addr:           *listen,
		Handler:        http.HandlerFunc(handler),
		ReadTimeout:    120 * time.Second,
		WriteTimeout:   0, // streaming responses; rely on TCP
		MaxHeaderBytes: 1 << 20,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
	os.Exit(0)
}
