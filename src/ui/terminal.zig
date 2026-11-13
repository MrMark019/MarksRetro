const std = @import("std");
const builtin = @import("builtin");
const config = @import("../core/config.zig");
const agent_mod = @import("../core/agent.zig");

// ─────────────────────────────────────────────
// Win32 Console API for colors on Windows XP
// ─────────────────────────────────────────────
const HANDLE = *anyopaque;
const WORD = u16;
const DWORD = u32;
const BOOL = i32;
const COORD = extern struct { X: i16, Y: i16 };
const SMALL_RECT = extern struct { Left: i16, Top: i16, Right: i16, Bottom: i16 };
const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;
extern "kernel32" fn GetACP() callconv(.winapi) c_uint;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) c_uint;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) c_uint;
extern "kernel32" fn SetConsoleCP(dwCodePageId: c_uint) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleOutputCP(dwCodePageId: c_uint) callconv(.winapi) BOOL;

// ─────────────────────────────────────────────
// Fork v3.5: CJK console bootstrap.
// Conhost converts PASTED clipboard text (UTF-16) to bytes using the
// console INPUT codepage - on a non-Chinese-locale Win7 (CP437) every
// Chinese char becomes '?', which looks like "cannot paste Chinese".
// Keyboard/IME input goes through the same codepage. The console codepage
// is a per-window setting that any Windows version can change to 936
// (the NLS tables are always present), so we force input+output to GBK
// for the lifetime of the session and restore the originals on exit.
// ─────────────────────────────────────────────
pub const ConsoleCjk = struct {
    saved_in: c_uint = 0,
    saved_out: c_uint = 0,
    applied: bool = false,

    pub fn apply(self: *ConsoleCjk) void {
        if (builtin.os.tag != .windows) return;
        const ci = GetConsoleCP();
        const co = GetConsoleOutputCP();
        if (ci == 936 and co == 936) return; // already GBK
        self.saved_in = ci;
        self.saved_out = co;
        _ = SetConsoleCP(936);
        _ = SetConsoleOutputCP(936);
        self.applied = true;
    }

    pub fn restore(self: *ConsoleCjk) void {
        if (!self.applied) return;
        _ = SetConsoleCP(self.saved_in);
        _ = SetConsoleOutputCP(self.saved_out);
        self.applied = false;
    }
};
extern "kernel32" fn MultiByteToWideChar(codePage: c_uint, dwFlags: c_uint, lpMultiByteStr: [*]const u8, cbMultiByte: c_int, lpWideCharStr: ?[*]u16, cWideChars: c_int) callconv(.winapi) c_int;
extern "kernel32" fn WideCharToMultiByte(codePage: c_uint, dwFlags: c_uint, lpWideCharStr: [*]const u16, cWideChars: c_int, lpMultiByteStr: ?[*]u8, cbMultiByte: c_int, lpDefaultChar: ?[*]const u8, lpUsedDefaultChar: ?[*]c_int) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleTextAttribute(hConsoleOutput: HANDLE, wAttributes: WORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetConsoleScreenBufferInfo(hConsoleOutput: HANDLE, lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleTitleA(lpConsoleTitle: [*:0]const u8) callconv(.winapi) BOOL;
// Fork v3.6: console look bootstrap + user interrupt plumbing
extern "kernel32" fn FillConsoleOutputAttribute(hConsoleOutput: HANDLE, wAttribute: WORD, nLength: DWORD, dwWriteCoordinate: COORD, lpNumberOfAttrsWritten: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn GetFileType(hFile: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn PeekConsoleInputW(hConsoleInput: HANDLE, lpBuffer: [*]u8, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ReadConsoleInputW(hConsoleInput: HANDLE, lpBuffer: [*]u8, nLength: DWORD, lpNumberOfEventsRead: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn SetConsoleCtrlHandler(handlerRoutine: ?*const fn (DWORD) callconv(.winapi) BOOL, add: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn GetTickCount() callconv(.winapi) DWORD; // ms since boot, wraps ~49 days

const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
const FILE_TYPE_CHAR: DWORD = 2;
const VK_ESCAPE: WORD = 0x1B;
const INPUT_RECORD_SIZE: usize = 20; // WORD type + WORD pad + 16-byte key event union

// Fork v3.6: global look/interaction state
var g_color: bool = false; // false = plain black-bg white-text everywhere
var g_think_brief: bool = true; // thinking collapsed by default
var g_busy = std.atomic.Value(bool).init(false); // a turn is in flight
var g_stop = std.atomic.Value(bool).init(false); // user asked to stop it
var g_ctrl_tick = std.atomic.Value(u32).init(0); // last idle Ctrl+C (double-press quit)
var console_in_handle: ?HANDLE = null; // null when stdin is redirected

fn ctrlHandler(ctl_type: DWORD) callconv(.winapi) BOOL {
    // Win32 truth: CTRL_C_EVENT = 0, CTRL_BREAK_EVENT = 1,
    // CTRL_CLOSE_EVENT = 2 (logoff 3 / shutdown 4).
    // Fork v3.6c: v3.6 had this mapping wrong (C=1, BREAK=2), so a real
    // Ctrl+C (0) fell through to "return 0" and the default handler KILLED
    // the agent mid-turn - that is the "Ctrl+C exits instead of
    // interrupting" field bug. Window-close (2) still terminates.
    if (ctl_type == 0 or ctl_type == 1) {
        if (g_busy.load(.acquire)) {
            g_stop.store(true, .release); // swallow: interrupt the turn, stay alive
            return 1;
        }
        // Idle: swallow a single Ctrl+C (cmd's "Terminate batch job Y/N"
        // can deliver stray events after an interrupt). Press it twice
        // within ~2.5s (or use /quit) and the second one quits for real.
        const now = GetTickCount();
        const prev = g_ctrl_tick.swap(now, .acq_rel);
        const elapsed: i32 = @bitCast(now -% prev);
        if (elapsed < 2500) return 0;
        return 1;
    }
    return 0;
}

/// Poll the console input buffer for a pressed ESC; consume events when found.
fn pollEscPressed() bool {
    const h = console_in_handle orelse return false;
    var buf: [INPUT_RECORD_SIZE * 16]u8 = undefined;
    var read_n: DWORD = 0;
    if (PeekConsoleInputW(h, &buf, 16, &read_n) == 0) return false;
    var i: usize = 0;
    var esc_at: ?usize = null;
    while (i < read_n) : (i += 1) {
        const base = i * INPUT_RECORD_SIZE;
        const ev_type = std.mem.readInt(u16, buf[base..][0..2], .little);
        if (ev_type != 1) continue; // KEY_EVENT
        const key_down = std.mem.readInt(u32, buf[base + 4 ..][0..4], .little);
        const vkey = std.mem.readInt(u16, buf[base + 8 ..][0..2], .little);
        if (key_down != 0 and vkey == VK_ESCAPE) {
            esc_at = i;
            break;
        }
    }
    if (esc_at == null) return false;
    // drain through the ESC press so it does not linger in the buffer
    var consumed: DWORD = 0;
    _ = ReadConsoleInputW(h, &buf, @intCast(esc_at.? + 1), &consumed);
    return true;
}

/// Sink stop_fn: ESC or Ctrl+C requested?
fn uiStopRequested(_: *anyopaque) bool {
    if (g_stop.load(.acquire)) return true;
    if (pollEscPressed()) {
        g_stop.store(true, .release);
        return true;
    }
    return false;
}

const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));

// Win32 Console Colors
const FG_BLACK: WORD = 0x0000;
const FG_BLUE: WORD = 0x0001;
const FG_GREEN: WORD = 0x0002;
const FG_CYAN: WORD = 0x0003;
const FG_RED: WORD = 0x0004;
const FG_MAGENTA: WORD = 0x0005;
const FG_YELLOW: WORD = 0x0006;
const FG_WHITE: WORD = 0x0007;
const FG_INTENSE: WORD = 0x0008;

// Color presets
const CLR_HEADER: WORD = FG_CYAN | FG_INTENSE;
const CLR_PROMPT: WORD = FG_GREEN | FG_INTENSE;
const CLR_PLAN: WORD = FG_YELLOW | FG_INTENSE;
const CLR_INFO: WORD = FG_CYAN;
const CLR_WARN: WORD = FG_YELLOW | FG_INTENSE;
const CLR_ERR: WORD = FG_RED | FG_INTENSE;
const CLR_TOOL: WORD = FG_MAGENTA | FG_INTENSE;
const CLR_DIM: WORD = FG_WHITE;
const CLR_TEXT: WORD = FG_WHITE | FG_INTENSE;
const CLR_ACCENT: WORD = FG_YELLOW;
const CLR_DEFAULT: WORD = FG_WHITE | FG_INTENSE;
const CLR_THINK: WORD = FG_CYAN;

// ─────────────────────────────────────────────
// Fork v2: UI glyphs are authored in UTF-8 and converted to the console
// code page at write time (uiWrite). On GBK consoles the box-drawing
// range is fully covered (verified: U+2550->A854, U+2500->A9A4 etc).
// The old CP437 single-byte constants produced nonsense CJK on Chinese
// Windows consoles and are gone for good.
// ─────────────────────────────────────────────
const BOX_TL = "╔";
const BOX_TR = "╗";
const BOX_BL = "╚";
const BOX_BR = "╝";
const BOX_H = "═";
const BOX_V = "║";
const BOX_H_S = "─";
const ARROW = "→";
const BULLET = "●";
const PROMPT_BUILD = ">";
const PROMPT_PLAN = "#";

// ─────────────────────────────────────────────
// Console helper
// ─────────────────────────────────────────────
var console_handle: ?HANDLE = null;
var saved_attributes: WORD = CLR_DEFAULT;

fn getConsole() HANDLE {
    if (console_handle) |h| return h;
    const h = GetStdHandle(STD_OUTPUT_HANDLE);
    console_handle = h;
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    _ = GetConsoleScreenBufferInfo(h, &info);
    saved_attributes = info.wAttributes;
    return h;
}

fn setColor(color: WORD) void {
    if (builtin.os.tag == .windows) {
        // Fork v3.6: monochrome default - everything is bright-white on black
        _ = SetConsoleTextAttribute(getConsole(), if (g_color) color else 0x0F);
    }
}

fn resetColor() void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleTextAttribute(getConsole(), if (g_color) CLR_DEFAULT else 0x0F);
    }
}

/// Fork v3.6: Win7-era consoles default to a white-background scheme, and
/// our color attributes carry black backgrounds -> patchy black-on-white UI.
/// Force the default attribute AND repaint the whole screen buffer to
/// bright-white-on-black (attributes only; existing text is preserved).
fn initConsoleLook() void {
    if (builtin.os.tag != .windows) return;
    const h = getConsole();
    _ = SetConsoleTextAttribute(h, 0x0F);
    var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (GetConsoleScreenBufferInfo(h, &info) == 0) return;
    const cells: i32 = @as(i32, info.dwSize.X) * info.dwSize.Y;
    if (cells <= 0) return;
    var written: DWORD = 0;
    _ = FillConsoleOutputAttribute(h, 0x0F, @intCast(cells), COORD{ .X = 0, .Y = 0 }, &written);
}

fn initInterruptPlumbing(stdin_handle: HANDLE) void {
    if (builtin.os.tag != .windows) return;
    _ = SetConsoleCtrlHandler(&ctrlHandler, 1);
    // ESC polling only works with a real console input handle
    if (GetFileType(stdin_handle) == FILE_TYPE_CHAR) {
        console_in_handle = stdin_handle;
    }
}

fn getConsoleWidth() u16 {
    if (builtin.os.tag == .windows) {
        var info: CONSOLE_SCREEN_BUFFER_INFO = undefined;
        _ = GetConsoleScreenBufferInfo(getConsole(), &info);
        const w = info.srWindow.Right - info.srWindow.Left + 1;
        return if (w > 20) @intCast(w) else 80;
    }
    return 80;
}

// ─────────────────────────────────────────────
// Code-page conversion with FIXED buffers (single-threaded UI)
// ─────────────────────────────────────────────
var wbuf: [8192]u16 = undefined;

// Console code pages (fall back to the system ACP when no console is
// attached). These are the RIGHT source of truth: a console switched to
// UTF-8 (chcp 65001, PS7 default on Win10+) must not be transcoded.
fn inputCodePage() c_uint {
    const cp = GetConsoleCP();
    return if (cp != 0) cp else GetACP();
}

fn outputCodePage() c_uint {
    const cp = GetConsoleOutputCP();
    return if (cp != 0) cp else GetACP();
}

fn toAcpFixed(in: []const u8, out: []u8) ?[]const u8 {
    if (in.len == 0) return in;
    if (builtin.os.tag != .windows) return null; // caller writes raw
    const acp = outputCodePage();
    if (acp == 65001) return null; // caller writes raw
    const wlen = MultiByteToWideChar(65001, 0, in.ptr, @intCast(in.len), null, 0);
    if (wlen <= 0 or wlen > wbuf.len) return null;
    const wsl = wbuf[0..@intCast(wlen)];
    const wgot = MultiByteToWideChar(65001, 0, in.ptr, @intCast(in.len), wsl.ptr, wlen);
    if (wgot <= 0) return null;
    var used = [1]c_int{0};
    const clen = WideCharToMultiByte(acp, 0, wsl.ptr, wgot, null, 0, null, &used);
    if (clen <= 0 or clen > out.len) return null;
    used[0] = 0;
    const cgot = WideCharToMultiByte(acp, 0, wsl.ptr, wgot, out.ptr, clen, null, &used);
    if (cgot <= 0) return null;
    // Emoji/symbols with no codepage equivalent arrive as '?' substitutions.
    // Rewrite char-by-char dropping unmappables instead of spamming '?'.
    if (used[0] != 0) {
        var n: usize = 0;
        var i: usize = 0;
        while (i < @as(usize, @intCast(wgot))) : (i += 1) {
            var ob: [8]u8 = undefined;
            var used2 = [1]c_int{0};
            const got = WideCharToMultiByte(acp, 0, wsl[i .. i + 1].ptr, 1, ob[0..].ptr, ob.len, null, &used2);
            if (got > 0 and used2[0] == 0 and n + @as(usize, @intCast(got)) <= out.len) {
                @memcpy(out[n .. n + @as(usize, @intCast(got))], ob[0..@intCast(got)]);
                n += @as(usize, @intCast(got));
            }
        }
        return out[0..n];
    }
    return out[0..@intCast(cgot)];
}

/// Write UTF-8 UI text to the console in its native code page.
fn uiWrite(stdout: std.fs.File, text: []const u8) !void {
    var obuf: [8192]u8 = undefined;
    if (toAcpFixed(text, &obuf)) |conv| {
        try stdout.writeAll(conv);
        return;
    }
    // raw path (unix / utf-8 console) or oversized text
    if (text.len > 8000) {
        var off: usize = 0;
        while (off < text.len) {
            const n = @min(4096, text.len - off);
            const chunk = text[off .. off + n];
            if (toAcpFixed(chunk, &obuf)) |conv| {
                try stdout.writeAll(conv);
            } else {
                try stdout.writeAll(chunk);
            }
            off += n;
        }
        return;
    }
    try stdout.writeAll(text);
}

// ─────────────────────────────────────────────
// Drawing primitives
// ─────────────────────────────────────────────
/// Largest prefix of s that ends on a complete UTF-8 codepoint boundary.
fn completeUtf8Prefix(s: []const u8) usize {
    if (s.len == 0) return 0;
    var back: usize = 0;
    while (back < @min(s.len, 4)) : (back += 1) {
        const i = s.len - 1 - back;
        const b = s[i];
        if (b < 0x80) return s.len; // ends on ASCII: fully complete
        if (b & 0xC0 == 0xC0) { // lead byte: does its sequence fit?
            const need: usize = if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else 1;
            return if (back + 1 >= need) s.len else i;
        }
        // continuation byte: keep walking back
    }
    return s.len; // >4 stray continuation bytes, flush anyway
}

// ─────────────────────────────────────────────
// ASCII fallback sanitizer (used only when ACP conversion is impossible)
// ─────────────────────────────────────────────
fn sanitizeUtf8ForConsole(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).initCapacity(allocator, input.len) catch unreachable;
    const writer = result.writer(allocator);

    var i: usize = 0;
    while (i < input.len) {
        const byte = input[i];
        if (byte < 0x80) {
            try writer.writeByte(byte);
            i += 1;
            continue;
        }

        var codepoint: u21 = 0;
        var seq_len: usize = 0;

        if (byte & 0xE0 == 0xC0) {
            seq_len = 2;
            if (i + 1 < input.len and input[i + 1] & 0xC0 == 0x80) {
                codepoint = (@as(u21, byte & 0x1F) << 6) | @as(u21, input[i + 1] & 0x3F);
            } else {
                try writer.writeByte('?');
                i += 1;
                continue;
            }
        } else if (byte & 0xF0 == 0xE0) {
            seq_len = 3;
            if (i + 2 < input.len and input[i + 1] & 0xC0 == 0x80 and input[i + 2] & 0xC0 == 0x80) {
                codepoint = (@as(u21, byte & 0x0F) << 12) | (@as(u21, input[i + 1] & 0x3F) << 6) | @as(u21, input[i + 2] & 0x3F);
            } else {
                try writer.writeByte('?');
                i += 1;
                continue;
            }
        } else if (byte & 0xF8 == 0xF0) {
            seq_len = 4;
            if (i + 3 < input.len and input[i + 1] & 0xC0 == 0x80 and input[i + 2] & 0xC0 == 0x80 and input[i + 3] & 0xC0 == 0x80) {
                codepoint = (@as(u21, byte & 0x07) << 18) | (@as(u21, input[i + 1] & 0x3F) << 12) | (@as(u21, input[i + 2] & 0x3F) << 6) | @as(u21, input[i + 3] & 0x3F);
            } else {
                try writer.writeByte('?');
                i += 1;
                continue;
            }
        } else {
            try writer.writeByte('?');
            i += 1;
            continue;
        }

        switch (codepoint) {
            // Box drawing / blocks / decorations (Fork v2)
            0x2500...0x257F => {
                const c: u8 = switch (codepoint) {
                    0x2502, 0x2503, 0x2551, 0x2553 => '|',
                    0x2500, 0x2501, 0x2550, 0x254C => '-',
                    0x2588, 0x2584, 0x2592, 0x2591 => '#',
                    0x25CF, 0x25CB, 0x2022 => '*',
                    0x2192, 0x21D2, 0x2794 => '>',
                    0x2190 => '<',
                    else => '+',
                };
                try writer.writeByte(c);
            },
            // Accented vowels -> base letter
            0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5 => try writer.writeByte('a'),
            0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5 => try writer.writeByte('A'),
            0xE8, 0xE9, 0xEA, 0xEB => try writer.writeByte('e'),
            0xC8, 0xC9, 0xCA, 0xCB => try writer.writeByte('E'),
            0xEC, 0xED, 0xEE, 0xEF => try writer.writeByte('i'),
            0xCC, 0xCD, 0xCE, 0xCF => try writer.writeByte('I'),
            0xF2, 0xF3, 0xF4, 0xF5, 0xF6 => try writer.writeByte('o'),
            0xD2, 0xD3, 0xD4, 0xD5, 0xD6 => try writer.writeByte('O'),
            0xF9, 0xFA, 0xFB, 0xFC => try writer.writeByte('u'),
            0xD9, 0xDA, 0xDB, 0xDC => try writer.writeByte('U'),
            0xDF => try writer.writeAll("ss"),
            0x2018, 0x2019 => try writer.writeByte('\''),
            0x201C, 0x201D => try writer.writeByte('"'),
            0x2013 => try writer.writeByte('-'),
            0x2014 => try writer.writeAll("--"),
            0x2026 => try writer.writeAll("..."),
            0x00A0 => try writer.writeByte(' '),
            0x00A9 => try writer.writeAll("(c)"),
            0x00AE => try writer.writeAll("(R)"),
            0x2122 => try writer.writeAll("(TM)"),
            else => {
                // CJK and everything else: drop (fallback path only)
                if (codepoint < 0x2E80) try writer.writeByte('?');
            },
        }

        i += seq_len;
    }

    return try result.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────
// Drawing primitives
// ─────────────────────────────────────────────
fn drawBoxTop(stdout: std.fs.File, width: usize) !void {
    setColor(CLR_HEADER);
    try uiWrite(stdout, BOX_TL);
    var i: usize = 0;
    while (i < width - 2) : (i += 1) try uiWrite(stdout, BOX_H);
    try uiWrite(stdout, BOX_TR);
    try stdout.writeAll("\n");
}

fn drawBoxBottom(stdout: std.fs.File, width: usize) !void {
    setColor(CLR_HEADER);
    try uiWrite(stdout, BOX_BL);
    var i: usize = 0;
    while (i < width - 2) : (i += 1) try uiWrite(stdout, BOX_H);
    try uiWrite(stdout, BOX_BR);
    try stdout.writeAll("\n");
    resetColor();
}

/// Display width in columns (CJK counts 2).
fn displayWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            w += 1;
            i += 1;
        } else if (b >= 0xE0 and b < 0xF0) {
            if (i + 3 <= s.len) {
                w += 2; // BMP CJK-ish assumption on this console
                i += 3;
            } else {
                w += 1;
                i += 1;
            }
        } else if (b < 0xE0) {
            w += 1;
            if (i + 2 <= s.len) i += 2 else i += 1;
        } else {
            w += 2;
            i += if (i + 4 <= s.len) @as(usize, 4) else 1;
        }
    }
    return w;
}

/// Truncate to at most `avail` display columns without splitting a codepoint.
fn truncateCols(s: []const u8, avail: usize) []const u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += utf8SeqLen(s[i])) {
        const cw = colWidthOf(s[i]);
        if (w + cw > avail) break;
        w += cw;
    }
    return s[0..i];
}

fn utf8SeqLen(b: u8) usize {
    if (b < 0x80) return 1;
    if (b & 0xE0 == 0xC0) return 2;
    if (b & 0xF0 == 0xE0) return 3;
    if (b & 0xF8 == 0xF0) return 4;
    return 1;
}

fn colWidthOf(b: u8) usize {
    return if ((b >= 0xE0 and b < 0xF0) or b >= 0xF0) @as(usize, 2) else 1;
}

fn drawBoxLine(stdout: std.fs.File, text: []const u8, width: usize, color: WORD) !void {
    setColor(CLR_HEADER);
    try uiWrite(stdout, BOX_V);
    try stdout.writeAll(" ");
    setColor(color);

    const avail = if (width > 3) width - 3 else 0;
    const tw = displayWidth(text);
    if (tw <= avail) {
        try uiWrite(stdout, text);
        var i: usize = tw;
        while (i < avail) : (i += 1) try stdout.writeAll(" ");
    } else {
        try uiWrite(stdout, truncateCols(text, avail));
    }

    setColor(CLR_HEADER);
    try stdout.writeAll(" ");
    try uiWrite(stdout, BOX_V);
    try stdout.writeAll("\n");
}

fn drawSeparator(stdout: std.fs.File, width: usize) !void {
    setColor(CLR_DIM);
    var i: usize = 0;
    while (i < width) : (i += 1) try uiWrite(stdout, BOX_H_S);
    try stdout.writeAll("\n");
    resetColor();
}

// ─────────────────────────────────────────────
// Banner
// ─────────────────────────────────────────────
fn drawBanner(stdout: std.fs.File, allocator: std.mem.Allocator, cfg: *config.Config, ag: *agent_mod.Agent) !void {
    const w: usize = 62;
    var buf: [512]u8 = undefined;

    if (builtin.os.tag == .windows) {
        _ = SetConsoleTitleA("Retro Agent - Windows System Assistant");
    }

    try stdout.writeAll("\n");
    drawBoxTop(stdout, w) catch {};
    drawBoxLine(stdout, "  Retro Agent v0.3.0-fork2", w, CLR_TEXT) catch {};
    drawBoxLine(stdout, std.fmt.bufPrint(&buf, "  {s} assistant (bridge TLS)", .{agent_mod.osSummary()}) catch "  Windows assistant (bridge TLS)", w, CLR_DIM) catch {};
    drawBoxLine(stdout, "", w, CLR_TEXT) catch {};

    setColor(CLR_HEADER);
    try uiWrite(stdout, BOX_V);
    setColor(CLR_DIM);
    var i: usize = 0;
    while (i < w - 2) : (i += 1) try uiWrite(stdout, BOX_H_S);
    setColor(CLR_HEADER);
    try uiWrite(stdout, BOX_V);
    try stdout.writeAll("\n");

    drawBoxLine(stdout, std.fmt.bufPrint(&buf, "Model    {s}", .{cfg.transport_api_model}) catch "Model ?", w, CLR_INFO) catch {};
    drawBoxLine(stdout, std.fmt.bufPrint(&buf, "API      {s}  ({s})", .{ @tagName(cfg.transport_api_style), if (cfg.transport_api_stream) "stream" else "batch" }) catch "API ?", w, CLR_INFO) catch {};
    drawBoxLine(stdout, std.fmt.bufPrint(&buf, "Endpoint {s}", .{cfg.transport_api_base_url}) catch "Endpoint ?", w, CLR_DIM) catch {};

    // Fork v3.6c: show the bridge's ACTUAL upstream so a switch is visible
    // right at startup (localhost endpoint alone was confusing in the field).
    if (bridgeUpstream(allocator, cfg)) |u| {
        defer allocator.free(u);
        drawBoxLine(stdout, std.fmt.bufPrint(&buf, "Upstream {s}", .{u}) catch "Upstream ?", w, CLR_DIM) catch {};
    }

    const mode_txt = switch (ag.mode_op) {
        .build => "build (full access)",
        .plan => "plan  (read-only)",
    };
    drawBoxLine(stdout, std.fmt.bufPrint(&buf, "Mode     {s}", .{mode_txt}) catch "Mode ?", w, if (ag.mode_op == .plan) CLR_WARN else CLR_INFO) catch {};

    if (cfg.transport_thinking != .off) {
        drawBoxLine(stdout, std.fmt.bufPrint(&buf, "Thinking {s}", .{cfg.transport_thinking.toString()}) catch "Thinking ?", w, CLR_THINK) catch {};
    }
    if (cfg.transport_api_context_window > 0) {
        drawBoxLine(stdout, std.fmt.bufPrint(&buf, "Context  ~{d} / {d} tokens ({d}%)", .{ ag.estimateTokens(), cfg.transport_api_context_window, ag.contextPct() }) catch "Context ?", w, CLR_DIM) catch {};
    }
    const approval_str = if (cfg.security_require_approval) "enabled" else "disabled";
    drawBoxLine(stdout, std.fmt.bufPrint(&buf, "Approval {s}", .{approval_str}) catch "Approval ?", w, CLR_DIM) catch {};

    // Fork v3.6: show look/thinking mode at a glance
    drawBoxLine(stdout, std.fmt.bufPrint(&buf, "UI       {s}  thinking {s}  (ESC/Ctrl+C stops a reply)", .{
        if (g_color) "color" else "mono",
        if (g_think_brief) "brief" else "full",
    }) catch "UI ?", w, CLR_DIM) catch {};

    // Fork v3.5: console CP is forced to 936 by ConsoleCjk, so input/paste
    // always works now. What can still break on a non-Chinese-locale system
    // is FONT GLYPHS (CJK renders as boxes) - warn about the real culprit.
    if (GetACP() != 936) {
        drawBoxLine(stdout, std.fmt.bufPrint(&buf, "Locale    non-Chinese system: CJK may show as boxes (install East Asian fonts)", .{}) catch "Locale ?", w, CLR_WARN) catch {};
    }
    if (ag.session_name) |sn| {
        drawBoxLine(stdout, std.fmt.bufPrint(&buf, "Session  {s}", .{sn}) catch "Session ?", w, CLR_DIM) catch {};
    }

    drawBoxLine(stdout, "", w, CLR_TEXT) catch {};
    drawBoxBottom(stdout, w) catch {};

    try stdout.writeAll("\n");
    setColor(CLR_DIM);
    try stdout.writeAll("  Type ");
    setColor(CLR_ACCENT);
    try stdout.writeAll("/help");
    setColor(CLR_DIM);
    try stdout.writeAll(" for commands. Ask anything in natural language.\n\n");
    resetColor();
}

// ─────────────────────────────────────────────
// Help screen
// ─────────────────────────────────────────────
fn drawHelp(stdout: std.fs.File) !void {
    try stdout.writeAll("\n");
    setColor(CLR_HEADER);
    try uiWrite(stdout, "  CONVERSATION\n");
    setColor(CLR_DIM);
    var i: usize = 0;
    while (i < 60) : (i += 1) try uiWrite(stdout, BOX_H_S);
    try stdout.writeAll("\n");

    const cmds = [_][2][]const u8{
        .{ "/model [n|name]", "list provider models / pick / set" },
        .{ "/upstream [url]", "show or switch provider URL (persisted)" },
        .{ "/key [new key]", "show masked / replace key (rewrites key.txt)" },
        .{ "/api <style>", "chat | responses | anthropic" },
        .{ "/think <lvl>", "thinking: off low medium high" },
        .{ "/stream <on|off>", "live streaming reply" },
        .{ "/img <path>", "attach png/jpg/gif/webp to next message" },
        .{ "/plan  /build", "read-only planning / full access" },
        .{ "/compact", "summarize old context now" },
        .{ "/thinking brief|full", "collapse/expand thinking block" },
        .{ "/expand", "show last thinking in full" },
        .{ "/color on|off", "color scheme vs plain black/white" },
        .{ "ESC / Ctrl+C", "stop current reply (2x Ctrl+C when idle quits)" },
        .{ "/sessions [n]", "list / resume saved sessions" },
        .{ "/save <name>", "save conversation under name" },
        .{ "/new", "start a fresh conversation" },
        .{ "/usage", "token usage of the last turn" },
        .{ "/context <n>", "set context window (tokens)" },
        .{ "/maxtok <n>", "set max output tokens (0=auto)" },
        .{ "/info /tools", "configuration / tools" },
        .{ "/clear", "wipe history (/new is friendlier)" },
        .{ "/quit", "exit (bridge stops too)" },
    };

    for (cmds) |cmd| {
        setColor(CLR_ACCENT);
        try stdout.writeAll("  ");
        try stdout.writeAll(cmd[0]);
        var pad: usize = cmd[0].len;
        while (pad < 20) : (pad += 1) try stdout.writeAll(" ");
        setColor(CLR_DIM);
        try uiWrite(stdout, cmd[1]);
        try stdout.writeAll("\n");
    }
    try stdout.writeAll("\n");
    resetColor();
}

// ─────────────────────────────────────────────
// Tools list
// ─────────────────────────────────────────────
fn drawToolsList(stdout: std.fs.File, ag: *agent_mod.Agent) !void {
    var buf: [512]u8 = undefined;

    try stdout.writeAll("\n");
    setColor(CLR_HEADER);
    try stdout.writeAll("  AVAILABLE TOOLS");
    if (ag.mode_op == .plan) try stdout.writeAll("  (plan mode: read-only subset)");
    try stdout.writeAll("\n");
    setColor(CLR_DIM);
    var i: usize = 0;
    while (i < 60) : (i += 1) try uiWrite(stdout, BOX_H_S);
    try stdout.writeAll("\n\n");

    var count: usize = 0;
    for (ag.tool_registry.tools.items) |tool| {
        if (!tool.enabled) continue;
        if (ag.mode_op == .plan and tool.mutating) continue;

        setColor(CLR_TOOL);
        try stdout.writeAll("  ");
        try uiWrite(stdout, BULLET);
        try stdout.writeAll(" ");
        setColor(CLR_TEXT);
        try stdout.writeAll(tool.name);
        if (tool.mutating) {
            setColor(CLR_WARN);
            try stdout.writeAll("  [writes]");
        }
        try stdout.writeAll("\n");

        setColor(CLR_DIM);
        try stdout.writeAll("    ");
        try uiWrite(stdout, truncateCols(tool.description, 64));
        if (displayWidth(tool.description) > 64) try stdout.writeAll("...");
        try stdout.writeAll("\n\n");
        count += 1;
    }

    setColor(CLR_DIM);
    i = 0;
    while (i < 60) : (i += 1) try uiWrite(stdout, BOX_H_S);
    try stdout.writeAll("\n");
    setColor(CLR_INFO);
    const total = std.fmt.bufPrint(&buf, "  {d} tools available\n\n", .{count}) catch "  ? tools\n\n";
    try stdout.writeAll(total);
    resetColor();
}

// ─────────────────────────────────────────────
// Info screen
// ─────────────────────────────────────────────
fn drawInfo(stdout: std.fs.File, allocator: std.mem.Allocator, ag: *agent_mod.Agent, cfg: *config.Config) !void {
    try stdout.writeAll("\n");
    setColor(CLR_HEADER);
    try stdout.writeAll("  CONFIGURATION\n");
    setColor(CLR_DIM);
    var i: usize = 0;
    while (i < 50) : (i += 1) try uiWrite(stdout, BOX_H_S);
    try stdout.writeAll("\n\n");

    const line = struct {
        fn p(out: std.fs.File, label: []const u8, val: []const u8, color: WORD) !void {
            setColor(CLR_DIM);
            try out.writeAll("  ");
            try out.writeAll(label);
            var pad: usize = label.len;
            while (pad < 16) : (pad += 1) try out.writeAll(" ");
            setColor(color);
            try uiWrite(out, val);
            try out.writeAll("\n");
        }
    }.p;

    try line(stdout, "Model", cfg.transport_api_model, CLR_TEXT);
    try line(stdout, "API style", @tagName(cfg.transport_api_style), CLR_TEXT);
    try line(stdout, "Streaming", if (cfg.transport_api_stream) "on" else "off", CLR_TEXT);
    try line(stdout, "Thinking", cfg.transport_thinking.toString(), CLR_TEXT);
    try line(stdout, "Endpoint", cfg.transport_api_base_url, CLR_DIM);
    if (bridgeUpstream(allocator, cfg)) |u| {
        defer allocator.free(u);
        try line(stdout, "Upstream", u, CLR_DIM);
    }
    try line(stdout, "Mode", if (ag.mode_op == .plan) "plan (read-only)" else "build (full)", if (ag.mode_op == .plan) CLR_WARN else CLR_INFO);
    try line(stdout, "Agent", cfg.agent_name, CLR_TEXT);

    var cwbuf: [64]u8 = undefined;
    try line(stdout, "Context win", if (cfg.transport_api_context_window > 0)
        std.fmt.bufPrint(&cwbuf, "{d}", .{cfg.transport_api_context_window}) catch "?"
    else "unset", CLR_TEXT);

    var tkbuf: [96]u8 = undefined;
    const est_txt = std.fmt.bufPrint(&tkbuf, "~{d} est ({d}%), {d} msgs", .{ ag.estimateTokens(), ag.contextPct(), ag.history.items.len }) catch "?";
    try line(stdout, "History", est_txt, CLR_DIM);

    var mkbuf: [64]u8 = undefined;
    try line(stdout, "Max tokens", if (cfg.transport_api_max_tokens > 0) std.fmt.bufPrint(&mkbuf, "{d}", .{cfg.transport_api_max_tokens}) catch "?" else "auto", CLR_TEXT);
    try line(stdout, "Approval", if (cfg.security_require_approval) "enabled" else "disabled", if (cfg.security_require_approval) CLR_WARN else CLR_INFO);
    try line(stdout, "Session", if (ag.session_name) |sn| sn else "(unsaved)", CLR_TEXT);
    try stdout.writeAll("\n");
    resetColor();
}

// ─────────────────────────────────────────────
// Fork-patch: ACP<->UTF-8 conversion for API payloads
// ─────────────────────────────────────────────
fn convertAcpToUtf8(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return allocator.dupe(u8, input);
    const acp = inputCodePage();
    if (acp == 65001) return allocator.dupe(u8, input);
    const wlen = MultiByteToWideChar(acp, 0, input.ptr, @intCast(input.len), null, 0);
    if (wlen <= 0) return error.AcpConvertFailed;
    const wbuf2 = try allocator.alloc(u16, @intCast(wlen));
    defer allocator.free(wbuf2);
    const wgot = MultiByteToWideChar(acp, 0, input.ptr, @intCast(input.len), wbuf2.ptr, @intCast(wbuf2.len));
    if (wgot <= 0) return error.AcpConvertFailed;
    const ulen = WideCharToMultiByte(65001, 0, wbuf2.ptr, @intCast(wgot), null, 0, null, null);
    if (ulen <= 0) return error.AcpConvertFailed;
    const ubuf = try allocator.alloc(u8, @intCast(ulen));
    const ugot = WideCharToMultiByte(65001, 0, wbuf2.ptr, @intCast(wgot), ubuf.ptr, @intCast(ubuf.len), null, null);
    if (ugot <= 0) {
        allocator.free(ubuf);
        return error.AcpConvertFailed;
    }
    return ubuf[0..@intCast(ugot)];
}

pub fn convertUtf8ToAcp(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return allocator.dupe(u8, input);
    const acp = outputCodePage();
    if (acp == 65001) return allocator.dupe(u8, input);
    const wlen = MultiByteToWideChar(65001, 0, input.ptr, @intCast(input.len), null, 0);
    if (wlen <= 0) return error.Utf8ConvertFailed;
    const wbuf2 = try allocator.alloc(u16, @intCast(wlen));
    defer allocator.free(wbuf2);
    const wgot = MultiByteToWideChar(65001, 0, input.ptr, @intCast(input.len), wbuf2.ptr, @intCast(wbuf2.len));
    if (wgot <= 0) return error.Utf8ConvertFailed;
    const clen = WideCharToMultiByte(acp, 0, wbuf2.ptr, @intCast(wgot), null, 0, null, null);
    if (clen <= 0) return error.Utf8ConvertFailed;
    const cbuf = try allocator.alloc(u8, @intCast(clen));
    const cgot = WideCharToMultiByte(acp, 0, wbuf2.ptr, @intCast(wgot), cbuf.ptr, @intCast(cbuf.len), null, null);
    if (cgot <= 0) {
        allocator.free(cbuf);
        return error.Utf8ConvertFailed;
    }
    return cbuf[0..@intCast(cgot)];
}

// ─────────────────────────────────────────────
// Stream renderer: Sink implementation
// ─────────────────────────────────────────────
const Render = struct {
    stdout: std.fs.File,
    alloc: std.mem.Allocator,
    carry: [8]u8 = undefined,
    carry_len: usize = 0,
    in_text: bool = false,
    in_think: bool = false,
    streamed_any: bool = false,
    line_open: bool = false,
    tool_line: [256]u8 = undefined,
    // Fork v3.6: brief mode parks the whole thinking block here instead of
    // the screen; /expand dumps it. Cleared at the start of every turn.
    last_thinking: std.ArrayList(u8) = undefined,
    thinking_started: bool = false,
};

fn sinkThinking(ctx: *anyopaque, frag: []const u8, prev: bool, next: bool) void {
    const r: *Render = @ptrCast(@alignCast(ctx));
    if (!prev) r.thinking_started = true;
    if (g_think_brief) {
        // accumulate quietly; show only a summary when the block closes
        r.last_thinking.appendSlice(r.alloc, frag) catch {};
        if (!next) {
            r.stdout.writeAll("\n  [thinking] ") catch {};
            setColor(CLR_DIM);
            var nb: [96]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d} chars - /expand to show", .{r.last_thinking.items.len}) catch "...";
            r.stdout.writeAll(s) catch {};
            r.stdout.writeAll("\n") catch {};
            resetColor();
            r.thinking_started = false;
        }
        return;
    }
    if (!prev) {
        setColor(CLR_DIM);
        r.stdout.writeAll("\n  [thinking] ") catch {};
    }
    emitFrag(r, frag, false);
    r.streamed_any = true;
    if (!next) {
        closeBlocks(r);
        r.thinking_started = false;
    }
}

fn emitFrag(r: *Render, frag: []const u8, text_block: bool) void {
    // merge carry + frag, emit complete prefix, keep the tail incomplete
    var tmp: [8200]u8 = undefined;
    var data: []const u8 = frag;
    if (r.carry_len > 0) {
        @memcpy(tmp[0..r.carry_len], r.carry[0..r.carry_len]);
        if (r.carry_len + frag.len > tmp.len) return; // pathological; drop
        @memcpy(tmp[r.carry_len .. r.carry_len + frag.len], frag);
        data = tmp[0 .. r.carry_len + frag.len];
    }
    const cp = completeUtf8Prefix(data);
    r.carry_len = 0;
    if (cp < data.len) {
        @memcpy(r.carry[0 .. data.len - cp], data[cp..]);
        r.carry_len = data.len - cp;
    }
    const out = data[0..cp];
    if (out.len == 0) return;

    if (text_block) {
        if (!r.in_text) {
            setColor(CLR_TEXT);
            r.in_text = true;
            r.line_open = true;
        }
    } else {
        if (!r.in_think) {
            setColor(CLR_THINK);
            r.in_think = true;
            r.line_open = true;
        }
    }
    var obuf: [8192]u8 = undefined;
    if (toAcpFixed(out, &obuf)) |conv| {
        r.stdout.writeAll(conv) catch {};
    } else {
        r.stdout.writeAll(out) catch {};
    }
}

fn closeBlocks(r: *Render) void {
    if (r.carry_len > 0) {
        // flush a dangling partial with '?' to avoid garbage
        r.stdout.writeAll("?") catch {};
        r.carry_len = 0;
    }
    if (r.in_think or r.in_text) {
        r.stdout.writeAll("\n") catch {};
    }
    r.in_think = false;
    r.in_text = false;
    r.line_open = false;
    resetColor();
}

fn sinkText(ctx: *anyopaque, frag: []const u8, prev: bool, next: bool) void {
    const r: *Render = @ptrCast(@alignCast(ctx));
    if (!prev) {
        setColor(CLR_DIM);
        r.stdout.writeAll("\n\n") catch {};
        setColor(CLR_HEADER);
        r.stdout.writeAll("  Agent ") catch {};
        setColor(CLR_DIM);
        uiWrite(r.stdout, ARROW) catch {};
        r.stdout.writeAll(" ") catch {};
    }
    emitFrag(r, frag, true);
    r.streamed_any = true;
    if (!next) closeBlocks(r);
}

fn sinkTool(ctx: *anyopaque, name: []const u8, arguments: []const u8) void {
    const r: *Render = @ptrCast(@alignCast(ctx));
    closeBlocks(r);
    setColor(CLR_TOOL);
    var linebuf: [320]u8 = undefined;
    const one = oneLine(&linebuf, arguments);
    r.stdout.writeAll("\n  [tool] ") catch {};
    setColor(CLR_TEXT);
    r.stdout.writeAll(name) catch {};
    setColor(CLR_DIM);
    r.stdout.writeAll("  ") catch {};
    uiWrite(r.stdout, truncateCols(one, 70)) catch {};
    r.stdout.writeAll("\n") catch {};
    resetColor();
}

fn sinkToolDone(ctx: *anyopaque, name: []const u8, ok: bool, result: []const u8) void {
    const r: *Render = @ptrCast(@alignCast(ctx));
    _ = name;
    setColor(if (ok) CLR_DIM else CLR_ERR);
    var head: [400]u8 = undefined;
    const one = oneLine(&head, result);
    r.stdout.writeAll("         ") catch {};
    uiWrite(r.stdout, ARROW) catch {};
    r.stdout.writeAll(" ") catch {};
    uiWrite(r.stdout, truncateCols(one, 76)) catch {};
    if (displayWidth(result) > 200) r.stdout.writeAll(" ...") catch {};
    r.stdout.writeAll("\n") catch {};
    resetColor();
}

fn sinkStage(ctx: *anyopaque, msg: []const u8) void {
    const r: *Render = @ptrCast(@alignCast(ctx));
    closeBlocks(r);
    setColor(CLR_DIM);
    r.stdout.writeAll("  ... ") catch {};
    uiWrite(r.stdout, truncateCols(msg, 68)) catch {};
    r.stdout.writeAll("     \n") catch {};
    resetColor();
}

fn oneLine(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (n >= buf.len - 1) break;
        buf[n] = if ((c == '\n' or c == '\r' or c == '\t')) ' ' else c;
        n += 1;
    }
    return buf[0..n];
}

fn renderSink(r: *Render) agent_mod.Sink {
    return .{
        .ctx = @ptrCast(r),
        .thinking_fn = sinkThinking,
        .text_fn = sinkText,
        .tool_fn = sinkTool,
        .tool_done_fn = sinkToolDone,
        .stage_fn = sinkStage,
        .stop_fn = uiStopRequested,
    };
}

// ─────────────────────────────────────────────
// Response formatting (non-streaming path)
// ─────────────────────────────────────────────
fn printFormattedResponse(stdout: std.fs.File, allocator: std.mem.Allocator, response: []const u8) !void {
    _ = allocator; // raw UTF-8 flows through uiWrite which converts ONCE (batch path)

    setColor(CLR_DIM);
    try stdout.writeAll("\n  Agent ");
    try uiWrite(stdout, ARROW);
    try stdout.writeAll(" \n");
    setColor(CLR_TEXT);

    var lines_iter = std.mem.splitSequence(u8, response, "\n");
    while (lines_iter.next()) |line| {
        if (line.len == 0) {
            try stdout.writeAll("\n");
            continue;
        }
        const trimmed = std.mem.trim(u8, line, "\r");
        if (std.mem.startsWith(u8, trimmed, "===")) {
            setColor(CLR_HEADER);
            try uiWrite(stdout, trimmed);
            try stdout.writeAll("\n");
            setColor(CLR_TEXT);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "---")) {
            setColor(CLR_DIM);
            var i: usize = 0;
            while (i < @min(trimmed.len, 76)) : (i += 1) try uiWrite(stdout, BOX_H_S);
            try stdout.writeAll("\n");
            setColor(CLR_TEXT);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            setColor(CLR_ACCENT);
            try stdout.writeAll("  ");
            try uiWrite(stdout, ARROW);
            setColor(CLR_TEXT);
            try uiWrite(stdout, trimmed[2..]);
            try stdout.writeAll("\n");
            continue;
        }
        try uiWrite(stdout, trimmed);
        try stdout.writeAll("\n");
    }

    try stdout.writeAll("\n");
    resetColor();
}

// ─────────────────────────────────────────────
// Command helpers
// ─────────────────────────────────────────────
var cached_models: []const []const u8 = &[_][]const u8{};
var cached_upstream: []const u8 = ""; // upstream the cached list belongs to

fn freeCachedModels(allocator: std.mem.Allocator) void {
    if (cached_models.len > 0) {
        for (cached_models) |m| allocator.free(m);
        allocator.free(cached_models);
        cached_models = &[_][]const u8{};
    }
    if (cached_upstream.len > 0) {
        allocator.free(cached_upstream);
        cached_upstream = "";
    }
}

fn bridgeUpstream(allocator: std.mem.Allocator, cfg: *config.Config) ?[]const u8 {
    const transport = @import("../transport/transport.zig");
    const res = transport.adminUpstream(allocator, cfg, null) catch return null;
    defer allocator.free(res.detail);
    if (!res.ok) return null;
    if (std.json.parseFromSlice(std.json.Value, allocator, res.detail, .{})) |p| {
        defer p.deinit();
        if (p.value == .object) {
            if (p.value.object.get("upstream")) |u| if (u == .string) {
                return allocator.dupe(u8, u.string) catch null;
            };
        }
    } else |_| {}
    return null;
}

/// Fork v3.6c: re-apply the persisted /upstream choice to the live bridge.
/// Scenario from the field: the user closes the agent window (the minimized
/// retrobridge window survives), runs agent.bat again; the "-check" sees the
/// old bridge and reuses it - upstream.txt was never re-read, so requests
/// still go to the previous provider while key.txt has the new key:
/// "invalid api key" on the second start. Healing here fixes that class.
fn healUpstream(allocator: std.mem.Allocator, cfg: *config.Config, stdout: std.fs.File) void {
    const transport = @import("../transport/transport.zig");
    if (cfg.upstream.len == 0) return;
    const cur = bridgeUpstream(allocator, cfg) orelse return; // no bridge / old bridge
    defer allocator.free(cur);
    const want = std.mem.trimRight(u8, cfg.upstream, "/");
    if (std.mem.eql(u8, cur, want)) return; // already right
    if (transport.adminUpstream(allocator, cfg, want)) |res| {
        allocator.free(res.detail);
        if (res.ok) {
            setColor(CLR_DIM);
            stdout.writeAll("  (upstream re-applied from saved settings)\n") catch {};
            resetColor();
            freeCachedModels(allocator);
        }
    } else |_| {}
}

fn saveModelCache(allocator: std.mem.Allocator, upstream: []const u8, models: []const []const u8) void {
    if (models.len == 0) return;
    var out = std.ArrayList(u8).initCapacity(allocator, 4096) catch return;
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    w.print("#micro-agent model cache\n#upstream {s}\n", .{upstream}) catch return;
    for (models) |m| w.print("{s}\n", .{m}) catch return;
    const f = std.fs.cwd().createFile("models.cache.txt", .{ .truncate = true }) catch return;
    defer f.close();
    f.writeAll(out.items) catch {};
}

fn loadModelCache(allocator: std.mem.Allocator, want_upstream: []const u8) ![]const []const u8 {
    const content = try std.fs.cwd().readFileAlloc(allocator, "models.cache.txt", 4 * 1024 * 1024);
    defer allocator.free(content);
    var list = std.ArrayList([]const u8).initCapacity(allocator, 64) catch unreachable;
    errdefer {
        for (list.items) |it| allocator.free(it);
        list.deinit(allocator);
    }
    var lines = std.mem.splitScalar(u8, content, '\n');
    var saw_us = false;
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \r");
        if (l.len == 0) continue;
        if (std.mem.startsWith(u8, l, "#upstream ")) {
            if (!std.mem.eql(u8, l["#upstream ".len..], want_upstream)) return error.CacheMismatch;
            saw_us = true;
            continue;
        }
        if (l[0] == '#') continue;
        if (!saw_us) return error.CacheMismatch;
        try list.append(allocator, try allocator.dupe(u8, l));
    }
    if (list.items.len == 0) return error.CacheMismatch;
    return try list.toOwnedSlice(allocator);
}

/// Fetch provider models with graceful fallbacks for endpoints that lack
/// GET /v1/models (dashscope's /apps/anthropic is one):
///  1) ask the current endpoint directly
///  2) anthropic style: flip the bridge to the provider's sibling
///     compatible-mode endpoint just for the listing, then restore
///  3) on-disk cache tied to the exact upstream URL
fn fetchModels(allocator: std.mem.Allocator, cfg: *config.Config, out_note: ?*[]const u8) []const []const u8 {
    const transport = @import("../transport/transport.zig");
    const none = &[_][]const u8{};

    if (transport.listModels(allocator, cfg)) |m| {
        if (m.len > 0) return m;
    } else |_| {}

    const up = bridgeUpstream(allocator, cfg);
    const up_key = up orelse allocator.dupe(u8, cfg.transport_api_base_url) catch return none;

    if (cfg.transport_api_style == .anthropic and std.mem.indexOf(u8, up_key, "/apps/anthropic") != null and up != null) {
        // derive scheme://host/compatible-mode from scheme://host/apps/anthropic...
        if (std.mem.indexOf(u8, up_key, "://")) |sc| {
            const hostpart = up_key[sc + 3 ..];
            const hlen = std.mem.indexOfScalar(u8, hostpart, '/') orelse hostpart.len;
            if (allocator.alloc(u8, sc + 3 + hlen + "/compatible-mode".len)) |alt| {
                @memcpy(alt[0 .. sc + 3], up_key[0 .. sc + 3]);
                @memcpy(alt[sc + 3 ..][0..hlen], hostpart[0..hlen]);
                @memcpy(alt[sc + 3 + hlen ..], "/compatible-mode");
                if (transport.adminUpstream(allocator, cfg, alt)) |r| {
                    const switched = r.ok;
                    allocator.free(r.detail);
                    if (switched) {
                        var probe = cfg.*;
                        probe.transport_api_style = .chat;
                        if (transport.listModels(allocator, &probe)) |m2| {
                            if (m2.len > 0) {
                                if (out_note) |note| note.* = "via sibling compatible-mode endpoint";
                                // restore original upstream (best effort)
                                if (transport.adminUpstream(allocator, cfg, up_key)) |r2| { allocator.free(r2.detail); } else |_| {}
                                allocator.free(alt);
                                return m2;
                            }
                        } else |_| {}
                        if (transport.adminUpstream(allocator, cfg, up_key)) |r2| { allocator.free(r2.detail); } else |_| {}
                    }
                } else |_| {}
                allocator.free(alt);
            } else |_| {}
        }
    }

    if (loadModelCache(allocator, up_key)) |mc| {
        if (out_note) |note| note.* = "from local cache (same upstream)";
        if (up) |u| allocator.free(u);
        return mc;
    } else |_| {}

    if (up) |u| allocator.free(u);
    return none;
}

fn argAfter(cmd: []const u8, prefix_len: usize) []const u8 {
    return std.mem.trim(u8, cmd[prefix_len..], " \t\r\n");
}

fn printModelList(stdout: std.fs.File, allocator: std.mem.Allocator, cfg: *config.Config) !void {
    const transport = @import("../transport/transport.zig");

    try stdout.writeAll("\n");
    setColor(CLR_HEADER);
    try stdout.writeAll("  MODEL\n");

    setColor(CLR_DIM);
    try stdout.writeAll("  endpoint ");
    try stdout.writeAll(cfg.transport_api_base_url);
    try stdout.writeAll("\n");

    // Current upstream, straight from the bridge admin endpoint
    if (transport.adminUpstream(allocator, cfg, null)) |up| {
        defer allocator.free(up.detail);
        if (up.ok) {
            var shown = false;
            if (std.json.parseFromSlice(std.json.Value, allocator, up.detail, .{})) |p| {
                defer p.deinit();
                if (p.value == .object) {
                    if (p.value.object.get("upstream")) |uv| if (uv == .string) {
                        setColor(CLR_DIM);
                        try stdout.writeAll("  upstream ");
                        try uiWrite(stdout, uv.string);
                        try stdout.writeAll("\n");
                        shown = true;
                    };
                }
            } else |_| {}
            if (!shown) {
                setColor(CLR_DIM);
                try stdout.writeAll("  upstream ");
                try stdout.writeAll(truncateCols(oneLine(&msg_static, up.detail), 110));
                try stdout.writeAll("\n");
            }
        } else {
            setColor(CLR_WARN);
            try stdout.writeAll("  upstream: bridge admin not answering (old bridge?)\n");
        }
    } else |_| {
        setColor(CLR_WARN);
        try stdout.writeAll("  upstream: cannot reach the bridge\n");
    }

    // Live model list with fallbacks (sibling endpoint / local cache)
    var note: []const u8 = "";
    if (cached_models.len == 0) {
        cached_models = fetchModels(allocator, cfg, &note);
        if (cached_models.len > 0) {
            if (bridgeUpstream(allocator, cfg)) |u| {
                saveModelCache(allocator, u, cached_models);
                allocator.free(u);
            } else saveModelCache(allocator, cfg.transport_api_base_url, cached_models);
        }
    }

    if (cached_models.len > 0) {
        setColor(CLR_HEADER);
        if (note.len > 0) {
            try stdout.writeAll("  provider models ");
            setColor(CLR_DIM);
            try stdout.writeAll("(");
            try stdout.writeAll(note);
            try stdout.writeAll(")");
            try stdout.writeAll(" (pick: /model N)\n");
        } else {
            try stdout.writeAll("  provider models (pick: /model N)\n");
        }
        const show = @min(cached_models.len, 40);
        var idx: usize = 0;
        var nbuf: [12]u8 = undefined;
        while (idx < show) : (idx += 1) {
            const m = cached_models[idx];
            const is_cur = std.mem.eql(u8, m, cfg.transport_api_model);
            setColor(if (is_cur) CLR_ACCENT else CLR_TEXT);
            try stdout.writeAll(if (is_cur) " *[" else "  [");
            try stdout.writeAll(std.fmt.bufPrint(&nbuf, "{d}", .{idx + 1}) catch "?");
            try stdout.writeAll("] ");
            try stdout.writeAll(m);
            try stdout.writeAll("\n");
        }
        if (cached_models.len > show) {
            setColor(CLR_DIM);
            var b2: [64]u8 = undefined;
            try stdout.writeAll(std.fmt.bufPrint(&b2, "  ... {d} more (set by name: /model <name>)\n", .{cached_models.len - show}) catch "  ...\n");
        }
    } else {
        setColor(CLR_WARN);
        try stdout.writeAll("  provider list unavailable; set by name: /model <name>\n");
    }
    setColor(CLR_DIM);
    try stdout.writeAll("  current: ");
    setColor(CLR_TEXT);
    try stdout.writeAll(cfg.transport_api_model);
    try stdout.writeAll("\n\n");
    resetColor();
}

fn setModelByName(stdout: std.fs.File, allocator: std.mem.Allocator, cfg: *config.Config, name: []const u8) !void {
    // Guard against junk persisted by mistake (e.g. "/model \" bricked setups)
    if (name.len < 2 or name[0] == '\\' or name[0] == '/' or name[0] == '|') {
        setColor(CLR_WARN);
        try stdout.writeAll("  that does not look like a model name - nothing changed\n\n");
        resetColor();
        return;
    }
    cfg.transport_api_model = try cfg.dupeAndOwn(name);
    cfg.saveSettingsFile("settings.txt") catch {};
    setColor(CLR_INFO);
    try stdout.writeAll("  model -> ");
    setColor(CLR_TEXT);
    try stdout.writeAll(name);
    try stdout.writeAll("\n\n");
    _ = allocator;
    resetColor();
}

// ─────────────────────────────────────────────
// Main run loop
// ─────────────────────────────────────────────
pub fn run(allocator: std.mem.Allocator, cfg: *config.Config) !void {
    const stdout = std.fs.File.stdout();

    // Fork v3.5: force the console to GBK for this session BEFORE drawing
    // anything (paste/IME of Chinese depends on the console input codepage;
    // CP437 turns every pasted CJK char into '?'). Restored on exit.
    var cjk = ConsoleCjk{};
    cjk.apply();
    defer cjk.restore();

    // Fork v3.6: plain black/white look + interrupt plumbing
    g_color = cfg.console_color;
    g_think_brief = cfg.thinking_display == .brief;
    initConsoleLook();
    initInterruptPlumbing(std.fs.File.stdin().handle);

    // Fork v3.6c: make sure a reused/stale bridge serves the last /upstream
    healUpstream(allocator, cfg, stdout);

    var ag = try agent_mod.Agent.init(allocator, cfg);
    defer ag.deinit();

    var render = Render{ .stdout = stdout, .alloc = allocator };
    render.last_thinking = std.ArrayList(u8).initCapacity(allocator, 16 * 1024) catch unreachable;
    defer render.last_thinking.deinit(allocator);
    const sink = renderSink(&render);

    try drawBanner(stdout, allocator, cfg, &ag);

    var input_buf: [4096]u8 = undefined;
    var msg_buf: [4096]u8 = undefined;
    var pending_images = std.ArrayList(agent_mod.Image).initCapacity(allocator, 0) catch unreachable;
    defer clearImages(allocator, &pending_images);

    // Line accumulator: stdin chunks may split GBK characters mid-byte
    // (pipes can cut anywhere). Keep raw bytes until a full line (\n) has
    // arrived; only then convert the COMPLETE line GBK->UTF-8. Keyboard
    // input is naturally whole-line; this makes piped input equally safe.
    var line_acc = std.ArrayList(u8).initCapacity(allocator, 8192) catch unreachable;
    defer line_acc.deinit(allocator);
    var feed_eof = false;

    outer: while (true) {
        // Read a chunk (blocking). EOF ends the feed after flushing residue.
        if (!feed_eof) {
            setColor(if (ag.mode_op == .plan) CLR_PLAN else CLR_PROMPT);
            try stdout.writeAll(if (ag.mode_op == .plan) PROMPT_PLAN else PROMPT_BUILD);
            try stdout.writeAll(" ");
            resetColor();

            const n = std.fs.File.stdin().read(&input_buf) catch |err| {
                if (err == error.EndOfStream) {
                    feed_eof = true;
                    continue :outer;
                }
                setColor(CLR_ERR);
                try stdout.writeAll("Error reading input\n");
                resetColor();
                return err;
            };
            if (n == 0) {
                feed_eof = true;
                continue :outer;
            }
            try line_acc.appendSlice(allocator, input_buf[0..n]);
        }

        // Consume every complete line currently buffered
        while (std.mem.indexOfScalar(u8, line_acc.items, '\n')) |nl| {
            const raw_line = line_acc.items[0..nl];
            const owned_line = try allocator.dupe(u8, raw_line);
            line_acc.replaceRangeAssumeCapacity(0, nl + 1, &.{});

            const trimmed = std.mem.trim(u8, owned_line, " \t\r\n");
            defer allocator.free(owned_line);
            if (trimmed.len == 0) continue;

            const utf8_input = if (builtin.os.tag == .windows)
                convertAcpToUtf8(allocator, trimmed) catch trimmed
            else
                trimmed;
            defer if (builtin.os.tag == .windows and utf8_input.ptr != trimmed.ptr) allocator.free(utf8_input);

            if (utf8_input[0] == '/') {
                const should_continue = try handleCommand(utf8_input, &ag, cfg, allocator, &render, &pending_images);
                if (!should_continue) return goodbye(stdout);
                continue :outer;
            }

            // Normal turn (inner)
            // Fork v3.4: image paths mentioned in text are auto-attached
            autoAttachImages(allocator, utf8_input, &pending_images, stdout);

            // Fork v3.6: arm interrupt detection for this turn
            render.last_thinking.clearRetainingCapacity();
            render.thinking_started = false;
            g_stop.store(false, .release);
            g_busy.store(true, .release);
            const response = ag.processMessage(utf8_input, pending_images.items, &sink) catch |err| {
                g_busy.store(false, .release);
                closeBlocks(&render);
                setColor(CLR_ERR);
                const msg = std.fmt.bufPrint(&msg_buf, "  Error: {s}\n\n", .{@errorName(err)}) catch "  Error\n\n";
                try stdout.writeAll(msg);
                resetColor();
                clearImages(allocator, &pending_images);
                continue :outer;
            };
            g_busy.store(false, .release);
            clearImages(allocator, &pending_images);

            // Fork v3.6: print only if the text did NOT already stream to
            // screen (this is what silently swallowed the round-cap error
            // before - the streamed_any heuristic was the wrong signal).
            if (!ag.last_text_streamed) {
                if (response.len > 0) {
                    try printFormattedResponse(stdout, allocator, response);
                }
            } else {
                stdout.writeAll("\n") catch {};
            }
            render.streamed_any = false;
            if (ag.last_interrupted) {
                setColor(CLR_WARN);
                try stdout.writeAll("  [!] interrupted - send \"continue\" to resume\n\n");
                resetColor();
            }
            // NOTE: do NOT free response - ownership belongs to history.
        }

        if (feed_eof) {
            // flush any trailing partial line as final input
            if (line_acc.items.len > 0) {
                const trimmed0 = std.mem.trim(u8, line_acc.items, " \t\r\n");
                if (trimmed0.len > 0 and trimmed0[0] != '/') {
                    const utf8_input = if (builtin.os.tag == .windows)
                        convertAcpToUtf8(allocator, trimmed0) catch trimmed0
                    else
                        trimmed0;
                    defer if (builtin.os.tag == .windows and utf8_input.ptr != trimmed0.ptr) allocator.free(utf8_input);
                    g_stop.store(false, .release);
                    g_busy.store(true, .release);
                    const response = ag.processMessage(utf8_input, pending_images.items, &sink) catch {
                        g_busy.store(false, .release);
                        break;
                    };
                    g_busy.store(false, .release);
                    clearImages(allocator, &pending_images);
                    if (!ag.last_text_streamed and response.len > 0) {
                        try printFormattedResponse(stdout, allocator, response);
                    } else {
                        stdout.writeAll("\n") catch {};
                    }
                }
            }
            break;
        }
    }
    return goodbye(stdout);
}

fn goodbye(stdout: std.fs.File) !void {
    try stdout.writeAll("\n");
    setColor(CLR_DIM);
    var i: usize = 0;
    while (i < 40) : (i += 1) try uiWrite(stdout, BOX_H_S);
    try stdout.writeAll("\n");
    setColor(CLR_INFO);
    try stdout.writeAll("  Session ended. Goodbye.\n\n");
    resetColor();
}

fn clearImages(allocator: std.mem.Allocator, imgs: *std.ArrayList(agent_mod.Image)) void {
    for (imgs.items) |img| {
        allocator.free(img.mime);
        allocator.free(img.data_b64);
        if (img.path) |p| allocator.free(p);
    }
    imgs.clearRetainingCapacity();
}

fn handleCommand(
    cmd: []const u8,
    ag: *agent_mod.Agent,
    cfg: *config.Config,
    allocator: std.mem.Allocator,
    render: *Render,
    pending_images: *std.ArrayList(agent_mod.Image),
) !bool {
    const stdout = std.fs.File.stdout();
    const transport = @import("../transport/transport.zig");

    if (std.mem.eql(u8, cmd, "/quit") or std.mem.eql(u8, cmd, "/exit") or std.mem.eql(u8, cmd, "/q")) {
        return false;
    }
    if (std.mem.eql(u8, cmd, "/help") or std.mem.eql(u8, cmd, "/h")) {
        try drawHelp(stdout);
        return true;
    }
    if (std.mem.eql(u8, cmd, "/info")) {
        try drawInfo(stdout, allocator, ag, cfg);
        return true;
    }
    if (std.mem.eql(u8, cmd, "/tools")) {
        try drawToolsList(stdout, ag);
        return true;
    }
    if (std.mem.eql(u8, cmd, "/plan")) {
        try ag.setAgentMode(.plan);
        setColor(CLR_WARN);
        try stdout.writeAll("\n  PLAN mode: read-only. I investigate and write plans; nothing changes.\n  /build to execute.\n\n");
        resetColor();
        return true;
    }
    if (std.mem.eql(u8, cmd, "/build")) {
        try ag.setAgentMode(.build);
        setColor(CLR_INFO);
        try stdout.writeAll("\n  BUILD mode: full tool access restored.\n\n");
        resetColor();
        return true;
    }
    if (std.mem.eql(u8, cmd, "/compact")) {
        const s = renderSink(render);
        ag.compactNow(&s, false) catch |e| {
            setColor(CLR_ERR);
            try stdout.writeAll("  compact failed: ");
            try stdout.writeAll(@errorName(e));
            try stdout.writeAll("\n\n");
            resetColor();
        };
        return true;
    }
    if (std.mem.eql(u8, cmd, "/usage")) {
        var buf: [256]u8 = undefined;
        setColor(CLR_INFO);
        const s = std.fmt.bufPrint(&buf, "\n  history ~{d} est tokens ({d}% of {d})\n  last turn: {d} in / {d} out (reported)\n\n", .{
            ag.estimateTokens(),
            ag.contextPct(),
            cfg.transport_api_context_window,
            ag.last_usage_in,
            ag.last_usage_out,
        }) catch "\n  ?\n\n";
        try stdout.writeAll(s);
        resetColor();
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "/stream")) {
        const a = argAfter(cmd, 7);
        if (a.len == 0) {
            cfg.transport_api_stream = !cfg.transport_api_stream;
        } else if (std.mem.eql(u8, a, "on") or std.mem.eql(u8, a, "true")) {
            cfg.transport_api_stream = true;
        } else if (std.mem.eql(u8, a, "off") or std.mem.eql(u8, a, "false")) {
            cfg.transport_api_stream = false;
        }
        cfg.saveSettingsFile("settings.txt") catch {};
        setColor(CLR_INFO);
        var buf: [64]u8 = undefined;
        try stdout.writeAll("\n  streaming ");
        try stdout.writeAll(if (cfg.transport_api_stream) "ON" else "off");
        try stdout.writeAll(std.fmt.bufPrint(&buf, "\n\n", .{}) catch "\n\n");
        resetColor();
        return true;
    }
    // Fork v3.6: /color on|off - plain black/white (default) vs color scheme
    if (std.mem.startsWith(u8, cmd, "/color")) {
        const a = argAfter(cmd, 6);
        const want: bool = if (a.len == 0) !g_color else (std.mem.eql(u8, a, "on") or std.mem.eql(u8, a, "true") or std.mem.eql(u8, a, "1"));
        g_color = want;
        cfg.console_color = want;
        cfg.saveSettingsFile("settings.txt") catch {};
        if (!want) initConsoleLook(); // repaint the whole buffer black/white
        setColor(CLR_INFO);
        try stdout.writeAll("\n  colors ");
        try stdout.writeAll(if (want) "ON (new output only)" else "off (plain black/white)");
        try stdout.writeAll("\n\n");
        resetColor();
        return true;
    }
    // Fork v3.6: /thinking brief|full - collapse/expand the thinking block
    if (std.mem.startsWith(u8, cmd, "/thinking")) {
        const a = argAfter(cmd, 9);
        if (a.len == 0) {
            setColor(CLR_INFO);
            try stdout.writeAll("\n  thinking display: ");
            try stdout.writeAll(if (g_think_brief) "brief (/expand shows last, set: /thinking full)" else "full (set: /thinking brief)");
            try stdout.writeAll("\n\n");
            resetColor();
        } else if (config.ThinkingDisplay.fromString(a)) |td| {
            g_think_brief = td == .brief;
            cfg.thinking_display = td;
            cfg.saveSettingsFile("settings.txt") catch {};
            setColor(CLR_INFO);
            try stdout.writeAll("\n  thinking display -> ");
            try stdout.writeAll(if (g_think_brief) "brief" else "full");
            try stdout.writeAll("\n\n");
            resetColor();
        } else {
            setColor(CLR_WARN);
            try stdout.writeAll("  usage: /thinking brief|full\n\n");
            resetColor();
        }
        return true;
    }
    // Fork v3.6: /expand - dump the collapsed thinking of the last turn
    if (std.mem.eql(u8, cmd, "/expand")) {
        if (render.last_thinking.items.len == 0) {
            setColor(CLR_DIM);
            try stdout.writeAll("\n  no thinking stored this session\n\n");
            resetColor();
            return true;
        }
        setColor(CLR_THINK);
        try stdout.writeAll("\n  [thinking expanded]\n");
        try uiWrite(stdout, render.last_thinking.items);
        try stdout.writeAll("\n\n");
        resetColor();
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "/think")) {
        const a = argAfter(cmd, 6);
        if (a.len == 0) {
            setColor(CLR_INFO);
            var buf: [96]u8 = undefined;
            try stdout.writeAll(std.fmt.bufPrint(&buf, "\n  thinking: {s}  (set: /think off|low|medium|high)\n\n", .{cfg.transport_thinking.toString()}) catch "\n  ?\n\n");
            resetColor();
        } else if (config.ThinkingLevel.fromString(a)) |tl| {
            cfg.transport_thinking = tl;
            cfg.saveSettingsFile("settings.txt") catch {};
            setColor(CLR_INFO);
            var buf: [96]u8 = undefined;
            try stdout.writeAll(std.fmt.bufPrint(&buf, "\n  thinking -> {s}\n\n", .{tl.toString()}) catch "\n  ok\n\n");
            resetColor();
        } else {
            setColor(CLR_WARN);
            try stdout.writeAll("  levels: off low medium high\n\n");
            resetColor();
        }
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "/api")) {
        const a = argAfter(cmd, 4);
        if (a.len == 0) {
            setColor(CLR_INFO);
            var buf: [128]u8 = undefined;
            try stdout.writeAll(std.fmt.bufPrint(&buf, "\n  api style: {s}   (set: /api chat|responses|anthropic)\n\n", .{@tagName(cfg.transport_api_style)}) catch "\n  ?\n\n");
            resetColor();
        } else if (config.ApiStyle.fromString(a)) |st| {
            cfg.transport_api_style = st;
            cfg.saveSettingsFile("settings.txt") catch {};
            setColor(CLR_INFO);
            var buf: [96]u8 = undefined;
            try stdout.writeAll(std.fmt.bufPrint(&buf, "\n  api style -> {s}\n\n", .{@tagName(st)}) catch "\n  ok\n\n");
            resetColor();
        } else {
            setColor(CLR_WARN);
            try stdout.writeAll("  styles: chat responses anthropic\n\n");
            resetColor();
        }
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "/context")) {
        const a = argAfter(cmd, 8);
        if (a.len == 0) {
            setColor(CLR_INFO);
            var buf: [96]u8 = undefined;
            try stdout.writeAll(std.fmt.bufPrint(&buf, "\n  context_window: {d}  (set: /context 131072)\n\n", .{cfg.transport_api_context_window}) catch "\n  ?\n\n");
            resetColor();
        } else if (std.fmt.parseInt(u32, a, 10)) |n| {
            cfg.transport_api_context_window = n;
            cfg.saveSettingsFile("settings.txt") catch {};
            setColor(CLR_INFO);
            var buf: [96]u8 = undefined;
            try stdout.writeAll(std.fmt.bufPrint(&buf, "\n  context_window -> {d}\n\n", .{n}) catch "\n  ok\n\n");
            resetColor();
        } else |_| {
            setColor(CLR_WARN);
            try stdout.writeAll("  usage: /context <tokens>\n\n");
            resetColor();
        }
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "/maxtok")) {
        const a = argAfter(cmd, 7);
        if (std.fmt.parseInt(u32, a, 10)) |n| {
            // qwen-class APIs accept max_tokens up to the context window
            // (dashscope /models detail: max_tokens ceiling = 131072 for
            // qwen3.8-flash; the 8192 in extra_info is only the default).
            // Reject only values above the declared window.
            const cw = cfg.transport_api_context_window;
            if (cw > 0 and n > cw) {
                setColor(CLR_WARN);
                var wbuf2: [128]u8 = undefined;
                try stdout.writeAll(std.fmt.bufPrint(&wbuf2, "  max_tokens {d} exceeds context_window {d} - raise /context first\n\n", .{ n, cw }) catch "  too large\n\n");
                resetColor();
                return true;
            }
            cfg.transport_api_max_tokens = n;
            cfg.saveSettingsFile("settings.txt") catch {};
            setColor(CLR_INFO);
            var buf: [96]u8 = undefined;
            try stdout.writeAll(std.fmt.bufPrint(&buf, "\n  max output tokens -> {d} (0 = provider default)\n\n", .{n}) catch "\n  ok\n\n");
            resetColor();
        } else |_| {
            setColor(CLR_WARN);
            try stdout.writeAll("  usage: /maxtok <tokens> (0 = auto)\n\n");
            resetColor();
        }
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "/upstream")) {
        const a = argAfter(cmd, 9);
        if (a.len == 0) {
            if (transport.adminUpstream(allocator, cfg, null)) |res| {
                defer allocator.free(res.detail);
                setColor(if (res.ok) CLR_INFO else CLR_ERR);
                try stdout.writeAll("\n  upstream: ");
                try stdout.writeAll(truncateCols(oneLine(&msg_static, res.detail), 120));
                try stdout.writeAll("\n\n");
                resetColor();
            } else |_| {
                setColor(CLR_ERR);
                try stdout.writeAll("\n  bridge unreachable\n\n");
                resetColor();
            }
        } else {
            if (transport.adminUpstream(allocator, cfg, a)) |res| {
                defer allocator.free(res.detail);
                setColor(if (res.ok) CLR_INFO else CLR_ERR);
                if (res.ok) {
                    // Fork v3.6c: persist agent-side too. The bridge keeps
                    // its own upstream.txt, but a stale bridge process that
                    // survives the window close never re-reads it - the
                    // settings.txt copy lets startup heal it.
                    cfg.upstream = cfg.dupeAndOwn(a) catch cfg.upstream;
                    cfg.saveSettingsFile("settings.txt") catch {};
                    try stdout.writeAll("\n  upstream switched (persisted: settings.txt + upstream.txt).\n  model list refreshed for new provider.\n\n");
                    freeCachedModels(allocator);
                    // warm the new provider's list now (with fallbacks)
                    var warm_note: []const u8 = "";
                    cached_models = fetchModels(allocator, cfg, &warm_note);
                    if (cached_models.len > 0) {
                        if (bridgeUpstream(allocator, cfg)) |u| {
                            saveModelCache(allocator, u, cached_models);
                            allocator.free(u);
                        }
                    }
                } else {
                    try stdout.writeAll("\n  switch failed: ");
                    try stdout.writeAll(truncateCols(oneLine(&msg_static, res.detail), 100));
                    try stdout.writeAll("\n\n");
                }
                resetColor();
            } else |_| {
                setColor(CLR_ERR);
                try stdout.writeAll("\n  bridge unreachable\n\n");
                resetColor();
            }
        }
        return true;
    }
    // /key - show masked, or replace live + rewrite key.txt (single source of truth)
    if (std.mem.startsWith(u8, cmd, "/key")) {
        const a = argAfter(cmd, 4);
        if (a.len == 0) {
            var buf: [128]u8 = undefined;
            const k = cfg.transport_api_key;
            const shown = if (k.len > 12)
                std.fmt.bufPrint(&buf, "{s}...{s}", .{ k[0..5], k[k.len - 4 ..] }) catch "***"
            else if (k.len > 0) "(set, too short to mask)" else "(not set)";
            setColor(CLR_INFO);
            try stdout.writeAll("\n  key: ");
            try stdout.writeAll(shown);
            try stdout.writeAll("\n  replace: /key sk-xxxx  (updates live + rewrites key.txt)\n\n");
            resetColor();
        } else {
            if (a.len < 8) {
                setColor(CLR_WARN);
                try stdout.writeAll("  that key looks too short - nothing changed\n\n");
                resetColor();
                return true;
            }
            cfg.transport_api_key = try cfg.dupeAndOwn(a);
            const persisted = blk: {
                const file = std.fs.cwd().createFile("key.txt", .{ .truncate = true }) catch break :blk false;
                defer file.close();
                file.writeAll(a) catch break :blk false;
                file.writeAll("\n") catch break :blk false;
                break :blk true;
            };
            var buf: [128]u8 = undefined;
            setColor(if (persisted) CLR_INFO else CLR_WARN);
            const shown = std.fmt.bufPrint(&buf, "{s}...{s}", .{ a[0..5], a[a.len - 4 ..] }) catch "***";
            try stdout.writeAll("\n  key -> ");
            try stdout.writeAll(shown);
            try stdout.writeAll(if (persisted) "  (saved to key.txt)\n\n" else "  (live only - key.txt NOT writable?)\n\n");
            resetColor();
        }
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "/model")) {
        const a = argAfter(cmd, 6);
        if (a.len == 0) {
            try printModelList(stdout, allocator, cfg);
        } else if (std.fmt.parseInt(usize, a, 10)) |n| {
            if (n >= 1 and n <= cached_models.len) {
                try setModelByName(stdout, allocator, cfg, cached_models[n - 1]);
            } else {
                setColor(CLR_WARN);
                try stdout.writeAll("  no numbered entry (run /model to list)\n\n");
                resetColor();
            }
        } else |_| {
            freeCachedModels(allocator);
            try setModelByName(stdout, allocator, cfg, a);
        }
        return true;
    }
    if (std.mem.eql(u8, cmd, "/sessions")) {
        const list = ag.listSessions() catch &[_]agent_mod.SessionInfo{};
        setColor(CLR_HEADER);
        try stdout.writeAll("\n  SESSIONS (resume: /sessions N)\n");
        if (list.len == 0) {
            setColor(CLR_DIM);
            try stdout.writeAll("  (none yet - they auto-save under sessions\\)\n\n");
        }
        var idx: usize = 0;
        var nbuf: [12]u8 = undefined;
        while (idx < list.len) : (idx += 1) {
            const s = list[idx];
            const is_cur = ag.session_name != null and std.mem.eql(u8, ag.session_name.?, s.name);
            setColor(if (is_cur) CLR_ACCENT else CLR_TEXT);
            try stdout.writeAll(if (is_cur) " *[" else "  [");
            try stdout.writeAll(std.fmt.bufPrint(&nbuf, "{d}", .{idx + 1}) catch "?");
            try stdout.writeAll("] ");
            try stdout.writeAll(s.name);
            if (s.corrupt) {
                setColor(CLR_ERR);
                try stdout.writeAll("  (unreadable - delete this file)");
                try stdout.writeAll("\n");
                continue;
            }
            setColor(CLR_DIM);
            try stdout.writeAll("  ");
            try stdout.writeAll(s.model);
            var cbuf: [48]u8 = undefined;
            try stdout.writeAll(std.fmt.bufPrint(&cbuf, "  {d} msgs\n", .{s.messages}) catch "\n");
        }
        try stdout.writeAll("\n");
        resetColor();
        ag.freeSessions(list);
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "/sessions ")) {
        const a = argAfter(cmd, 9);
        const n = std.fmt.parseInt(usize, a, 10) catch {
            setColor(CLR_WARN);
            try stdout.writeAll("  usage: /sessions <number>\n\n");
            resetColor();
            return true;
        };
        const list = ag.listSessions() catch &[_]agent_mod.SessionInfo{};
        if (n >= 1 and n <= list.len) {
            ag.loadSession(list[n - 1].path) catch |e| {
                setColor(CLR_ERR);
                try stdout.writeAll("  load failed: ");
                try stdout.writeAll(@errorName(e));
                try stdout.writeAll("\n\n");
                resetColor();
                ag.freeSessions(list);
                return true;
            };
            setColor(CLR_INFO);
            try stdout.writeAll("  resumed: ");
            try stdout.writeAll(list[n - 1].name);
            try stdout.writeAll("\n\n");
            resetColor();
        } else {
            setColor(CLR_WARN);
            try stdout.writeAll("  no such number (see /sessions)\n\n");
            resetColor();
        }
        ag.freeSessions(list);
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "/save")) {
        const a = argAfter(cmd, 5);
        var namebuf: [128]u8 = undefined;
        const name = if (a.len > 0)
            sanitizeName(&namebuf, a)
        else blk: {
            break :blk sanitizeName(&namebuf, std.fmt.bufPrint(&msg_static, "save-{d}", .{std.time.timestamp()}) catch "save-manual");
        };
        ag.saveSession(name) catch |e| {
            setColor(CLR_ERR);
            try stdout.writeAll("  save failed: ");
            try stdout.writeAll(@errorName(e));
            try stdout.writeAll("\n\n");
            resetColor();
            return true;
        };
        setColor(CLR_INFO);
        try stdout.writeAll("  saved as: ");
        try stdout.writeAll(name);
        try stdout.writeAll("\n\n");
        resetColor();
        return true;
    }
    if (std.mem.eql(u8, cmd, "/new")) {
        ag.saveSession(null) catch {};
        try ag.resetHistory();
        if (ag.session_name) |sn| allocator.free(sn);
        ag.session_name = null;
        clearImages(allocator, pending_images);
        setColor(CLR_INFO);
        try stdout.writeAll("\n  new conversation started.\n\n");
        resetColor();
        return true;
    }
    if (std.mem.startsWith(u8, cmd, "/img ")) {
        const p = argAfter(cmd, 4);
        attachImage(stdout, allocator, pending_images, p) catch |e| {
            setColor(CLR_ERR);
            try stdout.writeAll("  image failed: ");
            try stdout.writeAll(@errorName(e));
            try stdout.writeAll("\n\n");
            resetColor();
        };
        return true;
    }
    if (std.mem.eql(u8, cmd, "/attach")) {
        setColor(CLR_INFO);
        var buf: [96]u8 = undefined;
        try stdout.writeAll(std.fmt.bufPrint(&buf, "\n  attached: {d} image(s) go with your next message\n\n", .{pending_images.items.len}) catch "\n  ?\n\n");
        resetColor();
        return true;
    }
    if (std.mem.eql(u8, cmd, "/clear")) {
        try ag.resetHistory();
        clearImages(allocator, pending_images);
        setColor(CLR_INFO);
        try stdout.writeAll("\n  History cleared.\n\n");
        resetColor();
        return true;
    }
    if (std.mem.eql(u8, cmd, "/mode")) {
        setColor(CLR_INFO);
        try stdout.writeAll("\n  interactive mode: ");
        try stdout.writeAll(if (ag.mode_op == .plan) "plan" else "build");
        try stdout.writeAll(" | transport: ");
        try stdout.writeAll(@tagName(cfg.mode));
        try stdout.writeAll("\n\n");
        resetColor();
        return true;
    }

    setColor(CLR_WARN);
    var buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "\n  Unknown command: {s}. Type /help\n\n", .{truncateCols(cmd, 40)}) catch "\n  Unknown command\n\n";
    try stdout.writeAll(msg);
    resetColor();
    return true;
}

var msg_static: [256]u8 = undefined;

fn sanitizeName(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (n >= buf.len - 1) break;
        const okc = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        buf[n] = if (okc) c else '_';
        if (buf[n] != '_') n += 1 else if (n == 0 or buf[n - 1] != '_') {
            n += 1;
        }
    }
    while (n > 0 and buf[n - 1] == '_') n -= 1;
    return buf[0..n];
}

fn detectImageMime(raw: []const u8) ?[]const u8 {
    if (raw.len > 8 and std.mem.eql(u8, raw[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (raw.len > 2 and raw[0] == 0xFF and raw[1] == 0xD8) return "image/jpeg";
    if (raw.len > 6 and (std.mem.eql(u8, raw[0..6], "GIF87a") or std.mem.eql(u8, raw[0..6], "GIF89a"))) return "image/gif";
    if (raw.len > 12 and std.mem.startsWith(u8, raw[0..4], "RIFF") and std.mem.eql(u8, raw[8..12], "WEBP")) return "image/webp";
    return null;
}

/// Attach one image file to the pending list. Caller prints status.
fn attachImageFile(allocator: std.mem.Allocator, list: *std.ArrayList(agent_mod.Image), path: []const u8) bool {
    if (list.items.len >= 4) return false; // sane per-message cap
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    const raw = file.readToEndAlloc(allocator, 3 * 1024 * 1024) catch return false;
    defer allocator.free(raw);
    const mime = detectImageMime(raw) orelse return false;
    const b64 = std.base64.standard.Encoder.calcSize(raw.len);
    const buf = allocator.alloc(u8, b64) catch return false;
    _ = std.base64.standard.Encoder.encode(buf, raw);
    const duped_path = allocator.dupe(u8, path) catch null;
    list.append(allocator, .{
        .mime = allocator.dupe(u8, mime) catch {
            allocator.free(buf);
            if (duped_path) |p| allocator.free(p);
            return false;
        },
        .data_b64 = buf,
        .path = duped_path,
    }) catch {
        allocator.free(buf);
        if (duped_path) |p| allocator.free(p);
        return false;
    };
    return true;
}

/// Fork v3.4: auto-attach image paths typed in a normal message
/// ("看看 C:\pics\截图 2025-01-01 1203.png 里有什么") - scan for
/// drive-letter paths ending in an image extension; attach real files.
fn autoAttachImages(allocator: std.mem.Allocator, text: []const u8, list: *std.ArrayList(agent_mod.Image), stdout: std.fs.File) void {
    const exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp" };
    var i: usize = 0;
    while (i + 3 < text.len) {
        const c = text[i];
        const drive_start = ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z')) and text[i + 1] == ':' and (text[i + 2] == '\\' or text[i + 2] == '/');
        if (!drive_start) {
            i += 1;
            continue;
        }
        // search forward for the first "<ext>" boundary (followed by
        // end/space/quote) within a windows-path-length window
        var found_end: ?usize = null;
        var j: usize = i + 3;
        const limit = @min(i + 260, text.len);
        while (j + 4 <= limit) : (j += 1) {
            if (text[j] != '.') continue;
            for (exts) |e| {
                if (j + e.len <= text.len and std.ascii.eqlIgnoreCase(text[j .. j + e.len], e)) {
                    const after_ok = j + e.len >= text.len or text[j + e.len] == ' ' or text[j + e.len] == '"' or text[j + e.len] == '\t';
                    if (after_ok) {
                        found_end = j + e.len;
                        break;
                    }
                }
            }
            if (found_end != null) break;
        }
        if (found_end) |pe| {
            const path = text[i..pe];
            if (attachImageFile(allocator, list, path)) {
                var nb: [300]u8 = undefined;
                setColor(CLR_INFO);
                stdout.writeAll("\n  [img] auto-attached: ") catch {};
                uiWrite(stdout, truncateCols(oneLine(&nb, path), 90)) catch {};
                stdout.writeAll("\n") catch {};
                resetColor();
            }
            i = pe;
        } else {
            i += 3;
        }
    }
}

fn attachImage(stdout: std.fs.File, allocator: std.mem.Allocator, list: *std.ArrayList(agent_mod.Image), path: []const u8) !void {
    if (attachImageFile(allocator, list, path)) {
        setColor(CLR_INFO);
        var nbuf: [160]u8 = undefined;
        try stdout.writeAll(std.fmt.bufPrint(&nbuf, "  attached: {s} ({d} pending for next message)\n\n", .{ path, list.items.len }) catch "  attached\n\n");
        resetColor();
    } else {
        // diagnose why for the user
        const raw = std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024) catch {
            setColor(CLR_ERR);
            try stdout.writeAll("  cannot read that file (missing or too big)\n\n");
            resetColor();
            return;
        };
        defer allocator.free(raw);
        setColor(CLR_ERR);
        if (raw.len > 3 * 1024 * 1024) {
            try stdout.writeAll("  image too large (>3MB)\n\n");
        } else if (detectImageMime(raw) == null) {
            try stdout.writeAll("  unsupported image (need png/jpg/gif/webp)\n\n");
        } else {
            try stdout.writeAll("  attach failed (out of memory?)\n\n");
        }
        resetColor();
    }
}

pub const StatusLevel = enum { info, warning, err };

fn showStatus(allocator: std.mem.Allocator, s: []const u8, level: StatusLevel) !void {
    _ = allocator;
    const stdout = std.fs.File.stdout();

    const color: WORD = switch (level) {
        .info => CLR_INFO,
        .warning => CLR_WARN,
        .err => CLR_ERR,
    };
    const symbol = switch (level) {
        .info => "[OK] ",
        .warning => "[!!] ",
        .err => "[XX] ",
    };

    setColor(color);
    try stdout.writeAll("  ");
    try stdout.writeAll(symbol);
    try uiWrite(stdout, s);
    try stdout.writeAll("\n");
    resetColor();
}
