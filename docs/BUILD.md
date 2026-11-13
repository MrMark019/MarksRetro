# Build environment & reproduction

The toolchains are intentionally NOT committed (GitHub blocks files >100 MB;
zig.exe alone is 168 MB). Pin them with these exact URLs and checksums.

## Toolchains

| Tool | Version | URL | SHA-256 |
|---|---|---|---|
| Zig (host: x86_64 windows) | 0.15.2 | https://ziglang.org/download/0.15.2/zig-x86_64-windows-0.15.2.zip | `3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c` |
| Go (32-bit! last XP-capable line) | 1.10.8 windows/386 | https://dl.google.com/go/go1.10.8.windows-386.zip | official SHASUMS256 at https://golang.org/dl/ |
| Upstream base zip (retro-agent v0.1.0 winxp) | 0.1.0 | (see README Attribution for the repo) | `3be086f1e18a4dddcfb8f1fc4e31bcc7c7e95b76061ec6ac0f604258d1ea856f` |

> Zig download tip (learned the hard way): ziglang.org throttles single
> connections (~12 KB/s). `scripts/zig-seg.ps1` + `scripts/fill-segs.ps1`
> fetch it as 8 parallel HTTP Range segments (~90 KB/s).

## Layout of this repo

```
src/                 the Zig agent (v3.6b)
bridge/              retrobridge Go source (build with Go 1.10 ONLY)
usb/                 XP-safe launcher batch files (pure ASCII, zero nested blocks)
dist/RETRO-X86/      ready-to-run portable package (no secrets)
upstream-pristine/   untouched v0.1.0 sources, kept for diffing against our fork
scripts/             historical build/test scripts from development (sanitized)
```

## Rebuild the agent

```sh
# 1) sanity build for your dev machine
zig build -Doptimize=ReleaseFast
zig build test

# 2) the artifact that runs on XP SP3 / Win7 32-bit:
zig build --build-file build-xp.zig
#    -> zig-out/bin/agentxp.exe  (rename to micro-agent.exe, drop into dist/RETRO-X86/)
```

`build-xp.zig` pins: `x86 / windows / os_version_min=xp / gnu abi /
ReleaseSmall / stripped / single-threaded / 16 MB stack`. Do not relax these
if you want XP to load the binary.

## Rebuild the bridge

```bat
:: MUST be Go 1.10.x — later Go dropped Windows XP support.
set GOROOT=...\go
set GOPATH=.\gopath
go build -o retrobridge.exe main.go
```

The 386 toolchain cross-builds nothing: Go 1.10 windows-386 produces exactly
the 32-bit exe XP needs, and the same binary also runs on Win7/Win11.

## Verifying an XP/Win7 build without an XP box

`scripts/final-xp-sim.ps1` and `scripts/hardened-verify.ps1` reproduce the
known XP failure modes on a modern Windows console (codepage switching, GBK
pipe truncation, cmd block parsing). The real acceptance test still needs
physical hardware — copy `dist/RETRO-X86` (plus your own `key.txt`) and run
`agent.bat`.

## Known pitfalls encoded in this codebase

- XP cmd 5.1 mis-parses nested batch blocks: `usb/*.bat` are zero-nested-block
  by design; keep them that way (see CHANGELOG v2.x).
- All `.bat` must stay pure ASCII + CRLF; `.ps1` with Chinese must be UTF-8
  BOM + CRLF (PowerShell 5.1 misread otherwise).
- Console input/output codepages are bootstrapped to 936 at runtime
  (`ConsoleCjk`) — never replace that with GetACP().
- Never read `head.content_type` after the body has been drained (dangling
  alias; see CHANGELOG v3.6b).
