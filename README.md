# MarksRetro

AI coding/diagnostic agent for **legacy 32-bit Windows** — Windows XP SP3 and
Windows 7, machines with 64 MB RAM and no modern TLS. An ~850 KB statically
linked binary plus a small local TLS bridge bring streaming LLM chat, tool
calling, vision, sessions and context compaction to hardware the modern
ecosystem forgot.

> **Fork notice.** This repository is a fork of the
> [micro-agent / retro-agent project](#attribution) (MIT, © 2025 micro-agent
> contributors), renamed to MarksRetro. The original `LICENSE` is retained in
> full; fork additions are © 2026 Mark under the same MIT terms. See
> `CHANGELOG.md` for what changed.

## Why this exists

Modern agents (Claude Code, opencode, Pi, …) need a Node/Bun/Python runtime:
150 MB–1.7 GB, and they refuse to load on XP because the required CRT and TLS
stacks do not exist there. MarksRetro is built to the opposite brief:

- **Runs on stock Windows XP SP3 (32-bit)** — no runtime, no installer, no
  UCRT. The binary imports only kernel32/advapi32-era APIs; even
  `RtlGetSystemTimePrecise` (Win8+) is shimmed.
- **~850 KB** (Zig, `ReleaseSmall`, stripped, single-threaded).
- **TLS is outsourced** to `retrobridge.exe` — compiled with Go 1.10, the last
  Go that supports XP — which speaks plain HTTP to the agent and TLS 1.2/1.3
  to the provider with its own crypto stack and bundled CA store.
- **Self-contained folder** (`RETRO-X86`): copy the directory anywhere, double
  click `agent.bat`, chat. Logs are written next to the running folder.

## Features (v3.6b)

- Streaming chat with live tool-call lines, collapsible thinking blocks
  (`/thinking brief|full`, `/expand`), token usage (`/usage`)
- Tool calling: exec / file_read / file_write / list_dir + 11 Windows
  diagnostic tools; **Plan/Build** modes (`/plan` hides mutating tools)
- Automatic context-window compaction (`/compact`), session persistence
  (`/sessions`, `/save`, `/new`, auto-save, resume)
- Vision: paste an image path or `/img file.png` (PNG/JPEG/GIF/WebP ≤ 3 MB)
- Multi-provider: `/model` lists the live provider catalog (with sibling
  endpoint fallback for Anthropic-style URLs), `/upstream` hot-swap,
  `/api chat|responses|anthropic`, `/think off|low|medium|high`,
  `/maxtok`, `/context`, `/stream`, `/key` (rewrites key.txt live)
- Runtime OS auto-detection injected into the system prompt (no more "I think
  I'm on XP" on Win7)
- GBK/CP936 console layer: correct Chinese input (incl. paste on non-Chinese
  locales via console codepage bootstrap), GBK box-drawing UI, plain
  black/white default with `/color on` for the full palette
- ESC or first Ctrl+C interrupts a reply without killing the session

## Layout

```
src/                 Zig agent (main, core/agent+config, transport/, tools/, ui/, utils/)
bridge/              retrobridge — Go 1.10 HTTPS/TLS proxy with upstream admin API
usb/                 XP-safe batch launchers (zero nested blocks, pure ASCII)
dist/RETRO-X86/      ready-to-run portable package (add your own key.txt; never commit it)
upstream-pristine/   untouched v0.1.0 sources for diffing against this fork
scripts/             development build/test scripts (sanitized)
docs/BUILD.md        pinned toolchains (URLs + SHA-256), rebuild steps, pitfalls
LICENSE              MIT (original) + fork attribution
CHANGELOG.md         v0.1.0 -> v3.6b history
```

Home: https://github.com/MrMark019/MarksRetro

## Build

```sh
# host (test/dev)
zig build -Doptimize=ReleaseFast
zig build test

# XP 32-bit artifact -> zig-out/bin/agentxp.exe  (rename micro-agent.exe)
zig build --build-file build-xp.zig

# bridge (must use Go 1.10.x for XP support)
cd bridge && go build -o retrobridge.exe .
```

## Attribution

Fork of **micro-agent** (retro-agent project), © 2025 micro-agent
contributors, MIT licensed. Original repository:
`<paste upstream repo URL here>` — v0.1.0 winxp build, artifact
SHA-256 `3be086f1e18a4dddcfb8f1fc4e31bcc7c7e95b76061ec6ac0f604258d1ea856f`.
Toolchain: Zig 0.15.2 (MIT), Go 1.10.8 (BSD-3). CA bundle: Mozilla CA
certificates (MPL 2.0), shipped as `ca-bundle.crt`.

*The original project's canonical URL should be filled in above from your
download record before publishing, so the attribution link is exact.*
