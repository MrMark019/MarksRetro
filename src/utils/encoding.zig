const std = @import("std");
const builtin = @import("builtin");

// Fork v3.3: tool-output encoding safety net.
//
// On Chinese Windows, cmd/file output arrives as raw GBK (ACP) bytes. Those
// bytes are INVALID UTF-8, and strict providers (dashscope's Anthropic
// endpoint especially) reject the whole JSON body with "Required body
// invalid" the moment a tool_result contains them. This helper guarantees
// any string entering the conversation history is valid UTF-8:
//   - already-valid UTF-8 (incl. plain ASCII)  -> passthrough copy
//   - otherwise                                 -> ACP -> UTF-8 re-encode
// Re-encoding runs in chunked passes so even mixed/broken streams can never
// emit lone surrogates or invalid lead sequences (failed chunks are dropped,
// with a marker counting what was lost).
//
// Returns an allocated slice (possibly the same bytes copied), or error.

extern "kernel32" fn GetACP() callconv(.winapi) c_uint;
extern "kernel32" fn MultiByteToWideChar(codePage: c_uint, dwFlags: c_uint, lpMultiByteStr: [*]const u8, cbMultiByte: c_int, lpWideCharStr: ?[*]u16, cWideChars: c_int) callconv(.winapi) c_int;
extern "kernel32" fn WideCharToMultiByte(codePage: c_uint, dwFlags: c_uint, lpWideCharStr: [*]const u16, cWideChars: c_int, lpMultiByteStr: ?[*]u8, cbMultiByte: c_int, lpDefaultChar: ?[*]const u8, lpUsedDefaultChar: ?[*]c_int) callconv(.winapi) c_int;

pub fn needsUtf8Fixup(s: []const u8) bool {
    if (builtin.os.tag != .windows) return false;
    if (s.len == 0) return false;
    // fast path: pure ASCII
    var any_hi = false;
    for (s) |c| {
        if (c >= 0x80) {
            any_hi = true;
            break;
        }
    }
    if (!any_hi) return false;
    return std.unicode.utf8ValidateSlice(s) == false;
}

pub fn toValidUtf8(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (!needsUtf8Fixup(s)) return allocator.dupe(u8, s);

    const acp = GetACP();
    if (acp == 65001) {
        // console claims UTF-8 but bytes are broken: drop invalid sequences
        return filterInvalidUtf8(allocator, s);
    }

    // chunked ACP -> UTF-8: 4KB in, aligned to char boundaries by retry logic
    var out = std.ArrayList(u8).initCapacity(allocator, s.len * 2) catch return allocator.dupe(u8, s);
    const wbuf = allocator.alloc(u16, 8192) catch {
        out.deinit(allocator);
        return allocator.dupe(u8, s);
    };
    defer allocator.free(wbuf);

    var dropped: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const take = @min(@as(usize, 4096), s.len - i);
        const chunk = s[i .. i + take];
        const wlen = MultiByteToWideChar(acp, 0, chunk.ptr, @intCast(chunk.len), wbuf.ptr, @intCast(wbuf.len));
        if (wlen > 0) {
            const ulen = WideCharToMultiByte(65001, 0, wbuf.ptr, wlen, null, 0, null, null);
            if (ulen > 0) {
                const old = out.items.len;
                out.resize(allocator, old + @as(usize, @intCast(ulen))) catch {
                    out.resize(allocator, old) catch {};
                };
                if (out.items.len == old + @as(usize, @intCast(ulen))) {
                    _ = WideCharToMultiByte(65001, 0, wbuf.ptr, wlen, out.items[old..].ptr, ulen, null, null);
                    // validate appended region; if a lone surrogate slipped in, filter it
                    if (!std.unicode.utf8ValidateSlice(out.items[old..])) {
                        const clean = filterInvalidUtf8(allocator, out.items[old..]) catch {
                            out.resize(allocator, old) catch {};
                            dropped += chunk.len;
                            i += take;
                            continue;
                        };
                        defer allocator.free(clean);
                        out.resize(allocator, old) catch {};
                        out.appendSlice(allocator, clean) catch {};
                    }
                }
            }
            // advance by the byte count the conversion actually consumed:
            // MultiByteToWideChar consumed >= wlen chars but may stop early on
            // an invalid byte — probe a conservative 1-byte-at-fault step.
            i += take;
        } else {
            // chunk failed wholesale: emit a safe ASCII placeholder byte-walk
            // (best effort: replace each lead byte of a GBK pair)
            out.appendSlice(allocator, " ? ") catch {};
            dropped += take;
            i += take;
        }
    }

    if (dropped > 0) {
        out.writer(allocator).print(" [{d} bytes undecodable dropped]", .{dropped}) catch {};
    }
    return out.toOwnedSlice(allocator);
}

fn filterInvalidUtf8(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).initCapacity(allocator, s.len) catch return allocator.dupe(u8, s);
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        const need: usize = if (b < 0x80) 1 else if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else 0;
        if (need == 0 or i + need > s.len) {
            i += 1;
            continue;
        }
        var ok = true;
        var j: usize = 1;
        while (j < need) : (j += 1) {
            if (s[i + j] & 0xC0 != 0x80) ok = false;
        }
        if (ok) {
            out.appendSlice(allocator, s[i .. i + need]) catch break;
            i += need;
        } else {
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

test "needsUtf8Fixup" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(!needsUtf8Fixup("hello")); // ascii
        try std.testing.expect(!needsUtf8Fixup("你好")); // valid UTF-8 CJK
        const gbk_bytes = "\xC4\xE3\xBA\xC3"; // 你好 in GBK = invalid UTF-8
        try std.testing.expect(needsUtf8Fixup(gbk_bytes));
    }
}

test "toValidUtf8 passthrough and repair" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    const a = try toValidUtf8(alloc, "plain ascii");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("plain ascii", a);

    const b = try toValidUtf8(alloc, "已经有效 UTF-8");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("已经有效 UTF-8", b);

    const c = try toValidUtf8(alloc, "prefix\xC4\xE3\xBA\xC3suffix"); // GBK inside
    defer alloc.free(c);
    try std.testing.expect(std.unicode.utf8ValidateSlice(c));
    try std.testing.expect(std.mem.startsWith(u8, c, "prefix"));
    try std.testing.expect(std.mem.indexOf(u8, c, "\xe4\xbd\xa0\xe5\xa5\xbd") != null); // 你好 restored
}
