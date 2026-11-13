#requires -Version 5.1
# ==================================================================
#  api-relay.ps1 - HTTP -> HTTPS reverse relay for legacy clients
#  (Windows XP micro-agent speaks plain HTTP; this relay terminates
#   plain HTTP locally and forwards to an OpenAI-compatible HTTPS
#   endpoint with TLS 1.2+. Run on a modern Windows machine.)
#  Usage:
#    powershell -NoProfile -ExecutionPolicy Bypass -File api-relay.ps1
#    optional: -Port 8787 -Upstream https://host/path/v1 -LocalOnly
# ==================================================================
param(
    [int]$Port = 8787,
    [string]$Upstream = 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    [switch]$LocalOnly
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 64

$listener = New-Object Net.HttpListener
$bound = $false
if (-not $LocalOnly) {
    try {
        $listener.Prefixes.Add("http://+:$Port/")
        $listener.Start()
        $bound = $true
        Write-Host "[relay] listening on 0.0.0.0:$Port (LAN clients OK)"
    } catch {
        $listener = New-Object Net.HttpListener
    }
}
if (-not $bound) {
    $listener.Prefixes.Add("http://127.0.0.1:$Port/")
    $listener.Start()
    Write-Host "[relay] listening on 127.0.0.1:$Port ONLY (not admin? run elevated to serve LAN/XP clients)"
}
Write-Host "[relay] upstream = $Upstream"
Write-Host "[relay] health   = http://127.0.0.1:$Port/health   (Ctrl+C to stop)"

$skipReq = @('Host','Content-Length','Connection','Proxy-Connection','Expect','Accept-Encoding','Via','X-Forwarded-For','X-Forwarded-Host','Max-Forwards','TE')
$skipRsp = @('Transfer-Encoding','Content-Length','Connection','Keep-Alive','Proxy-Authenticate','Proxy-Authorization','Date','Server','TE')

while ($true) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    $t0 = Get-Date
    $rsp = $null
    try {
        if ($req.Url.AbsolutePath -eq '/health') {
            $hb = [Text.Encoding]::UTF8.GetBytes('ok')
            $res.ContentLength64 = $hb.Length
            $res.OutputStream.Write($hb, 0, $hb.Length)
            $res.Close()
            continue
        }
        $target = $Upstream.TrimEnd('/') + $req.Url.Path
        if ($req.Url.Query) { $target += '?' + $req.Url.Query }

        $wr = [Net.HttpWebRequest]::Create($target)
        $wr.Method = $req.HttpMethod
        $wr.Timeout = 600000
        $wr.ReadWriteTimeout = 600000
        $wr.AllowReadStreamBuffering = $false
        $wr.AllowWriteStreamBuffering = $false

        foreach ($k in $req.Headers.AllKeys) {
            if ($skipReq -contains $k) { continue }
            try { $wr.Headers[$k] = $req.Headers[$k] } catch { }
        }

        if ($req.HasEntityBody) {
            if ($req.ContentLength64 -ge 0) { $wr.ContentLength64 = $req.ContentLength64 }
            else { $wr.SendChunked = $true }
            $sIn = $req.InputStream
            $sOut = $wr.GetRequestStream()
            $buf = New-Object byte[] 65536
            while (($n = $sIn.Read($buf, 0, $buf.Length)) -gt 0) { $sOut.Write($buf, 0, $n) }
            $sOut.Close()
        }

        try { $rsp = $wr.GetResponse() }
        catch [Net.WebException] { $rsp = $_.Exception.Response }
        if ($null -eq $rsp) { throw 'upstream unreachable' }

        $res.StatusCode = [int]$rsp.StatusCode
        foreach ($h in $rsp.Headers.AllKeys) {
            if ($skipRsp -contains $h) { continue }
            try { $res.AddHeader($h, $rsp.Headers[$h]) } catch { }
        }

        $rs = $rsp.GetResponseStream()
        $os = $res.OutputStream
        $buf = New-Object byte[] 16384
        while (($n = $rs.Read($buf, 0, $buf.Length)) -gt 0) {
            $os.Write($buf, 0, $n)
            $os.Flush()
        }
        $rs.Close()
        $rsp.Close()
        $res.Close()
        $ms = [int](((Get-Date) - $t0).TotalMilliseconds)
        Write-Host ("[relay] {0} {1} -> {2} ({3}ms)" -f $req.HttpMethod, $req.Url.Path, [int]$rsp.StatusCode, $ms)
    }
    catch {
        Write-Host ("[relay] ERROR {0} {1}: {2}" -f $req.HttpMethod, $req.Url.Path, $_.Exception.Message)
        try {
            $res.StatusCode = 502
            $eb = [Text.Encoding]::UTF8.GetBytes(('{{"error":"relay: {0}"}}' -f ($_.Exception.Message -replace '"', "'")))
            $res.ContentType = 'application/json'
            $res.OutputStream.Write($eb, 0, $eb.Length)
            $res.Close()
        } catch { }
        if ($rsp) { try { $rsp.Close() } catch { } }
    }
}
