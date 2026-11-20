# Changelog — MarksRetro

## v3.6d (2026-11-20)
- New `/rounds <2..100>` command: tool-call budget per reply (default 30),
  live + persisted to settings.txt (was file-edit-only)
- Fixed "panic: Invalid free" when starting with the bridge DOWN: the v3.6c
  banner's Upstream lookup freed a static string on the admin-error path
  (contract now: AdminResult.detail is always allocator-owned). Affected
  /model, /upstream and startup-heal whenever no retrobridge was listening.

## v3.6c (2026-11-13)
- Fixed Ctrl+C: v3.6 used wrong event codes (CTRL_C_EVENT is 0, not 1), so
  Ctrl+C never interrupted a turn and always killed the agent - the field
  "打断没生效" report. Now Ctrl+C/ESC interrupt the current reply; window
  close (CTRL_CLOSE_EVENT=2) terminates again; a lone Ctrl+C while idle is
  swallowed, pressing it twice within ~2.5s quits.
- Fixed /upstream persistence across sessions: a retrobridge window can
  survive the agent window close and agent.bat reuses it without re-reading
  upstream.txt, so the switch silently reverted on next start ("invalid
  api key"). The choice is now persisted agent-side in settings.txt and
  re-applied to the live bridge at startup (heal).
- Banner + /info now show the bridge's ACTUAL upstream URL, not just the
  localhost endpoint; agent.bat banner prefers upstream.txt over retro.ini.

## v3.6b (2026-11-13)
- Runtime OS detection (RtlGetVersion + env + computer name) injected into the
  system prompt; banner/title/defaults de-hardcoded from "Windows XP"
- Fixed: non-streaming (batch) path always failed with a masked
  "could not reach provider (OutOfMemory)" — stale alias into the client's
  header buffer after the body read; error text now carries the real error name
- Fixed: `debug_mode` was never parsed from config.json (fork-original bug)

## v3.6
- Plain black/white console default (Win7 white-background scheme fix),
  `/color on|off` persisted
- Thinking blocks collapsed by default (`/thinking brief|full`, `/expand`)
- ESC / first Ctrl+C interrupts the current reply (partial kept in history,
  `continue` resumes); idle Ctrl+C still quits
- Tool-round cap 10 -> 30 (`max_tool_rounds`), wrap-up hint before the cap,
  cap message always reaches the screen (was silently swallowed)
- Strip leaked think-tags from provider content; UI strings pure ASCII

## v3.5b
- Console codepage bootstrap: force GBK (936) for input+output during a
  session, restore on exit — fixes Chinese paste/input on non-Chinese locales
- Fixed use-after-free in session auto-save; interrupted generations are
  recorded and persisted like normal turns

## v3.5
- Fixed exec pipe deadlock (stderr merged into stdout, single-pipe design)
- Oversized command output truncated at 1 MB instead of failing
- check_disk_space via GetDiskFreeSpaceExW (no cmd/wmic/admin)

## v3.4
- Fixed double-free in streamed tool-call finalization (delayed heap
  corruption -> access violation after multi-round tool use)
- Image paths typed in a message are auto-attached (no /img needed)
- file_read binary guard (images/executables point to /img)
- qwen3.8-flash confirmed natively multimodal; test baseline switched

## v3.3
- Model list fallback: sibling compatible-mode endpoint borrow via bridge
  admin API + on-disk cache keyed by upstream URL (anthropic-style endpoints
  without GET /v1/models still get the full catalog)

## v3.2
- `/key` command (live swap + rewrites key.txt)
- Fixed per-fragment newlines in streaming (delta block semantics),
  StreamTooLong on long SSE lines (2 MB transfer buffer), double-comma in
  session JSON, GBK truncation on piped input, console-vs-system codepage
  selection (GetConsoleCP/OutputCP), bad model-name / window-scale max_tokens
  guards

## v3.1
- max_tokens auto-clamp to provider-reported ceiling
- sessions marked unreadable instead of silently 0 msgs

## v3.0 (2026-11-11)
- GBK box-drawing UI layer (CP437 artifacts on Chinese consoles gone)
- SSE streaming with live tool lines + thinking display (chat/responses/
  anthropic dialects)
- Automatic context compaction + /compact
- Plan/Build modes with mutating-tool gating
- Session persistence: /sessions /save /new, auto-save, resume
- /model live provider catalog, /upstream hot-swap (bridge admin endpoint +
  upstream.txt), /api style switch, /think levels, /context /maxtok /usage
- Image input (/img, data URLs per style)
- Bridge: upstream.txt override + runtime switch endpoint (Go 1.10)

## v2.x (2026-11-11)
- XP-safe launcher scripts (zero nested cmd blocks; silent-death root cause)
- Bridge -ping/-log/-check; clock guard with NTP retry

## v0.1.0-fork (base)
- Upstream micro-agent v0.1.0 (MIT), winxp build; first patches:
  GBK<->UTF-8 console round-trip (terminal.zig), max_tokens/context_window
  config plumbing, /model switching
