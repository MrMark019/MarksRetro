const std = @import("std");
const config = @import("../core/config.zig");
const agent = @import("../core/agent.zig");

// ─────────────────────────────────────────────
// Transport: API (HTTP calls to OpenAI/Anthropic-compatible providers)
// FIX 1: Ollama/OpenAI-compatible only
// Fork v2: three wire styles (chat / responses / anthropic), SSE streaming
// with a Sink for live UI, model listing, and upstream admin passthrough.
// ─────────────────────────────────────────────

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8, // raw JSON schema
};

pub const HttpResult = struct {
    status: u16,
    content_type: []const u8, // owned, may be empty
    body: []const u8, // owned
};

/// Streaming event sink. Implemented by the UI (terminal.zig); all
/// callbacks are optional. Strings are transient UTF-8 fragments: the
/// fragment belongs to `prev`, `next`, or the final call — never free.
pub const Sink = struct {
    ctx: *anyopaque,
    thinking_fn: ?ThinkingFn = null,
    text_fn: ?TextFn = null,
    tool_fn: ?ToolFn = null,
    tool_done_fn: ?ToolDoneFn = null,
    stage_fn: ?StageFn = null,
    stop_fn: ?StopFn = null, // Fork v3.6: UI asks "did the user hit ESC/Ctrl+C?"

    pub const ThinkingFn: type = *const fn (ctx: *anyopaque, frag: []const u8, prev: bool, next: bool) void;
    pub const TextFn: type = *const fn (ctx: *anyopaque, frag: []const u8, prev: bool, next: bool) void;
    pub const ToolFn: type = *const fn (ctx: *anyopaque, name: []const u8, arguments: []const u8) void;
    pub const ToolDoneFn: type = *const fn (ctx: *anyopaque, name: []const u8, ok: bool, result: []const u8) void;
    pub const StageFn: type = *const fn (ctx: *anyopaque, msg: []const u8) void;
    pub const StopFn: type = *const fn (ctx: *anyopaque) bool;

    pub fn stopRequested(self: ?*const Sink) bool {
        if (self) |s| if (s.stop_fn) |f| return f(s.ctx);
        return false;
    }

    pub fn thinking(self: ?*const Sink, frag: []const u8, prev: bool, next: bool) void {
        if (self) |s| if (s.thinking_fn) |f| f(s.ctx, frag, prev, next);
    }
    pub fn text(self: ?*const Sink, frag: []const u8, prev: bool, next: bool) void {
        if (self) |s| if (s.text_fn) |f| f(s.ctx, frag, prev, next);
    }
    pub fn toolCall(self: ?*const Sink, name: []const u8, args: []const u8) void {
        if (self) |s| if (s.tool_fn) |f| f(s.ctx, name, args);
    }
    pub fn toolDone(self: ?*const Sink, name: []const u8, ok: bool, result: []const u8) void {
        if (self) |s| if (s.tool_done_fn) |f| f(s.ctx, name, ok, result);
    }
    pub fn stage(self: ?*const Sink, msg: []const u8) void {
        if (self) |s| if (s.stage_fn) |f| f(s.ctx, msg);
    }
};

// ─────────────────────────────────────────────
// Endpoint per style
// ─────────────────────────────────────────────

fn buildApiUrl(allocator: std.mem.Allocator, cfg: *config.Config) ![]const u8 {
    const suffix = switch (cfg.transport_api_style) {
        .chat => "/v1/chat/completions",
        .responses => "/v1/responses",
        .anthropic => "/v1/messages",
    };
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ cfg.transport_api_base_url, suffix });
}

fn authHeaders(allocator: std.mem.Allocator, cfg: *config.Config) ![]std.http.Header {
    var list = std.ArrayList(std.http.Header).initCapacity(allocator, 4) catch unreachable;
    try list.append(allocator, .{ .name = "Content-Type", .value = "application/json" });
    switch (cfg.transport_api_style) {
        .anthropic => {
            try list.append(allocator, .{ .name = "x-api-key", .value = cfg.transport_api_key });
            try list.append(allocator, .{ .name = "anthropic-version", .value = "2023-06-01" });
        },
        else => {
            const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.transport_api_key});
            try list.append(allocator, .{ .name = "Authorization", .value = auth });
        },
    }
    return try list.toOwnedSlice(allocator);
}

// ─────────────────────────────────────────────
// Request body builders (one per style)
// ─────────────────────────────────────────────

const BodyOpts = struct {
    stream: bool,
    thinking: bool, // false = retry pass without thinking knobs
    max_tok_override: ?u32 = null, // per-call clamp from provider range error
};

pub fn buildRequestBody(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
    tool_defs: ?[]const ToolDef,
    opts: BodyOpts,
) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    switch (cfg.transport_api_style) {
        .chat => try buildChatBody(allocator, writer, cfg, history, tool_defs, opts),
        .responses => try buildResponsesBody(allocator, writer, cfg, history, tool_defs, opts),
        .anthropic => try buildAnthropicBody(allocator, writer, cfg, history, tool_defs, opts),
    }
    return try buf.toOwnedSlice(allocator);
}

fn toolCount(td: ?[]const ToolDef) usize {
    if (td) |t| return t.len;
    return 0;
}

/// Effective output cap for this call: a per-call clamp parsed from the
/// provider's own range error wins over the configured value.
fn effMaxTokens(cfg: *config.Config, opts: BodyOpts) u32 {
    return opts.max_tok_override orelse cfg.transport_api_max_tokens;
}

/// Parse "Range of max_tokens should be [1, 65536]"-style provider errors.
/// Different endpoints cap differently (dashscope chat: window-scale;
/// apps/anthropic: 65536), so the only sane guard is the provider's own reply.
fn clampFromRangeError(body: []const u8) ?u32 {
    const pat = "max_tokens should be [1";
    const idx = std.mem.indexOf(u8, body, pat) orelse return null;
    var rest = body[idx + pat.len ..];
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    rest = rest[comma + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
    rest = std.mem.trim(u8, rest[0..close], " ");
    return std.fmt.parseInt(u32, rest, 10) catch null;
}
fn buildChatBody(
    allocator: std.mem.Allocator,
    writer: anytype,
    cfg: *config.Config,
    history: []const agent.Message,
    tool_defs: ?[]const ToolDef,
    opts: BodyOpts,
) !void {
    _ = allocator;
    try writer.writeAll("{\"model\":");
    try writeJsonString(writer, cfg.transport_api_model);
    try writer.writeAll(",\"messages\":[");
    for (history, 0..) |msg, i| {
        if (i > 0) try writer.writeAll(",");
        const role_str = switch (msg.role) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool_call => "assistant",
            .tool_result => "tool",
        };

        try writer.print("{{\"role\":\"{s}\"", .{role_str});

        if (msg.role == .tool_call) {
            // OpenAI canonical shape: assistant content null + tool_calls[]
            try writer.writeAll(",\"content\":null,\"tool_calls\":[{\"id\":");
            try writeJsonString(writer, msg.tool_id.?);
            try writer.print(",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":", .{msg.tool_name.?});
            try writeJsonString(writer, msg.content);
            try writer.writeAll("}}]");
        } else if (msg.role == .tool_result) {
            try writer.writeAll(",\"tool_call_id\":");
            try writeJsonString(writer, msg.tool_id.?);
            try writer.writeAll(",\"content\":");
            try writeJsonString(writer, msg.content);
        } else if (msg.images.len > 0) {
            // Multimodal: array content parts
            try writer.writeAll(",\"content\":[");
            if (msg.content.len > 0) {
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonString(writer, msg.content);
                try writer.writeAll("}");
            }
            for (msg.images) |img| {
                if (msg.content.len > 0) try writer.writeAll(",");
                // data URL: mime + base64 are JSON-safe ASCII — write raw,
                // do NOT wrap them in writeJsonString (adds stray quotes)
                try writer.writeAll("{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:");
                try writer.writeAll(img.mime);
                try writer.writeAll(";base64,");
                try writer.writeAll(img.data_b64);
                try writer.writeAll("\"}}");
            }
            try writer.writeAll("]");
        } else {
            try writer.writeAll(",\"content\":");
            try writeJsonString(writer, msg.content);
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]");

    if (tool_defs) |td| {
        if (td.len > 0) {
            try writer.writeAll(",\"tools\":[");
            for (td, 0..) |tool, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{{\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s}}}}}", .{
                    tool.name,
                    tool.description,
                    tool.parameters_json,
                });
            }
            try writer.writeAll("]");
        }
    }

    if (effMaxTokens(cfg, opts) > 0) {
        try writer.print(",\"max_tokens\":{d}", .{effMaxTokens(cfg, opts)});
    }

    // Fork v2: thinking knobs — dashscope-compatible fields, ignored elsewhere
    if (opts.thinking and cfg.transport_thinking != .off) {
        const budget: u32 = switch (cfg.transport_thinking) {
            .off => unreachable,
            .low => 1024,
            .medium => 4096,
            .high => 8192,
        };
        try writer.print(",\"enable_thinking\":true,\"thinking_budget\":{d}", .{budget});
    } else if (opts.thinking) {
        try writer.writeAll(",\"enable_thinking\":false");
    }

    if (opts.stream) {
        try writer.writeAll(",\"stream\":true");
    }
    try writer.writeAll("}");
}

fn buildResponsesBody(
    allocator: std.mem.Allocator,
    writer: anytype,
    cfg: *config.Config,
    history: []const agent.Message,
    tool_defs: ?[]const ToolDef,
    opts: BodyOpts,
) !void {
    // System prompts -> top-level instructions (concatenated)
    var sys_parts = std.ArrayList([]const u8).initCapacity(allocator, 2) catch unreachable;
    defer sys_parts.deinit(allocator);

    try writer.writeAll("{\"model\":");
    try writeJsonString(writer, cfg.transport_api_model);
    try writer.writeAll(",\"input\":[");

    var wrote: usize = 0;
    for (history) |msg| {
        switch (msg.role) {
            .system => {
                try sys_parts.append(allocator, msg.content);
                continue;
            },
            .tool_call => {
                if (wrote > 0) try writer.writeAll(",");
                wrote += 1;
                try writer.writeAll("{\"type\":\"function_call\"");
                try writer.writeAll(",\"call_id\":");
                try writeJsonString(writer, msg.tool_id.?);
                try writer.writeAll(",\"name\":");
                try writeJsonString(writer, msg.tool_name.?);
                try writer.writeAll(",\"arguments\":");
                try writeJsonString(writer, msg.content);
                try writer.writeAll("}");
            },
            .tool_result => {
                if (wrote > 0) try writer.writeAll(",");
                wrote += 1;
                try writer.writeAll("{\"type\":\"function_call_output\"");
                try writer.writeAll(",\"call_id\":");
                try writeJsonString(writer, msg.tool_id.?);
                try writer.writeAll(",\"output\":");
                try writeJsonString(writer, msg.content);
                try writer.writeAll("}");
            },
            else => {
                const role_str: []const u8 = if (msg.role == .user) "user" else "assistant";
                if (wrote > 0) try writer.writeAll(",");
                wrote += 1;
                try writer.print("{{\"role\":\"{s}\",\"content\":[", .{role_str});
                var parts: usize = 0;
                if (msg.content.len > 0 or msg.images.len == 0) {
                    const ctype: []const u8 = if (msg.role == .user) "input_text" else "output_text";
                    try writer.writeAll("{\"type\":\"");
                    try writer.writeAll(ctype);
                    try writer.writeAll("\",\"text\":");
                    try writeJsonString(writer, msg.content);
                    try writer.writeAll("}");
                    parts += 1;
                }
                for (msg.images) |img| {
                    if (parts > 0) try writer.writeAll(",");
                    parts += 1;
                    try writer.writeAll("{\"type\":\"input_image\",\"image_url\":\"data:");
                    try writer.writeAll(img.mime);
                    try writer.writeAll(";base64,");
                    try writer.writeAll(img.data_b64);
                    try writer.writeAll("\"}");
                }
                try writer.writeAll("]}");
            },
        }
    }
    try writer.writeAll("]");

    if (sys_parts.items.len > 0) {
        try writer.writeAll(",\"instructions\":");
        if (sys_parts.items.len == 1) {
            try writeJsonString(writer, sys_parts.items[0]);
        } else {
            var joined = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable;
            defer joined.deinit(allocator);
            for (sys_parts.items, 0..) |p, i| {
                if (i > 0) joined.appendSlice(allocator, "\n\n") catch {};
                joined.appendSlice(allocator, p) catch {};
            }
            try writeJsonString(writer, joined.items);
        }
    }

    if (tool_defs) |td| {
        if (td.len > 0) {
            try writer.writeAll(",\"tools\":[");
            for (td, 0..) |tool, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{{\"type\":\"function\",\"name\":\"{s}\",\"description\":\"{s}\",\"parameters\":{s}}}", .{
                    tool.name,
                    tool.description,
                    tool.parameters_json,
                });
            }
            try writer.writeAll("]");
        }
    }

    if (effMaxTokens(cfg, opts) > 0) {
        try writer.print(",\"max_output_tokens\":{d}", .{effMaxTokens(cfg, opts)});
    }
    if (opts.thinking and cfg.transport_thinking != .off) {
        const eff: []const u8 = switch (cfg.transport_thinking) {
            .off => unreachable,
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
        try writer.print(",\"reasoning_effort\":\"{s}\"", .{eff});
    }
    if (opts.stream) {
        try writer.writeAll(",\"stream\":true");
    }
    try writer.writeAll("}");
}

fn buildAnthropicBody(
    allocator: std.mem.Allocator,
    writer: anytype,
    cfg: *config.Config,
    history: []const agent.Message,
    tool_defs: ?[]const ToolDef,
    opts: BodyOpts,
) !void {
    var sys_msg = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable;
    defer sys_msg.deinit(allocator);

    var max_tokens: u32 = if (effMaxTokens(cfg, opts) > 0) effMaxTokens(cfg, opts) else 4096;
    const think_budget: u32 = blk: {
        if (!opts.thinking or cfg.transport_thinking == .off) break :blk 0;
        break :blk switch (cfg.transport_thinking) {
            .off => unreachable,
            .low => 1024,
            .medium => 2048,
            .high => 4096,
        };
    };
    if (think_budget > 0 and max_tokens < think_budget + 1024) max_tokens = think_budget + 1024;

    try writer.writeAll("{\"model\":");
    try writeJsonString(writer, cfg.transport_api_model);
    try writer.print(",\"max_tokens\":{d},\"messages\":[", .{max_tokens});

    // Anthropic: tool_use lives inside assistant content; tool_result inside
    // user content. Consecutive same-role messages merge into one envelope.
    var started = false;
    var open_role: []const u8 = "";
    var parts: usize = 0;

    for (history) |msg| {
        const role: []const u8 = switch (msg.role) {
            .system => {
                if (sys_msg.items.len > 0) try sys_msg.appendSlice(allocator, "\n\n");
                try sys_msg.appendSlice(allocator, msg.content);
                continue;
            },
            .tool_result => "user",
            .tool_call => "assistant",
            .user => "user",
            .assistant => "assistant",
        };

        if (!started or !std.mem.eql(u8, open_role, role)) {
            if (started) try writer.writeAll("]},"); // close prev content array AND envelope
            try writer.print("{{\"role\":\"{s}\",\"content\":[", .{role});
            open_role = role;
            parts = 0;
            started = true;
        }

        if (msg.role == .tool_call) {
            if (parts > 0) try writer.writeAll(",");
            parts += 1;
            try writer.writeAll("{\"type\":\"tool_use\",\"id\":");
            try writeJsonString(writer, msg.tool_id.?);
            try writer.writeAll(",\"name\":");
            try writeJsonString(writer, msg.tool_name.?);
            try writer.writeAll(",\"input\":");
            // arguments arrive as raw JSON text; fall back to empty object
            const args = if (msg.content.len > 0 and msg.content[0] == '{') msg.content else "{}";
            try writer.writeAll(args);
            try writer.writeAll("}"); // close the tool_use part object
        } else if (msg.role == .tool_result) {
            if (parts > 0) try writer.writeAll(",");
            parts += 1;
            try writer.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
            try writeJsonString(writer, msg.tool_id.?);
            try writer.writeAll(",\"content\":");
            try writeJsonString(writer, msg.content);
            try writer.writeAll("}");
        } else {
            if (msg.content.len > 0 or msg.images.len == 0) {
                if (parts > 0) try writer.writeAll(",");
                parts += 1;
                try writer.writeAll("{\"type\":\"text\",\"text\":");
                try writeJsonString(writer, msg.content);
                try writer.writeAll("}");
            }
            for (msg.images) |img| {
                if (parts > 0) try writer.writeAll(",");
                parts += 1;
                try writer.writeAll("{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
                try writeJsonString(writer, img.mime);
                try writeJsonString(writer, img.data_b64);
                try writer.writeAll("}}");
            }
        }
    }
    if (started) {
        try writer.writeAll("]}");
    }
    try writer.writeAll("]");

    if (sys_msg.items.len > 0) {
        try writer.writeAll(",\"system\":");
        try writeJsonString(writer, sys_msg.items);
    }

    if (tool_defs) |td| {
        if (td.len > 0) {
            try writer.writeAll(",\"tools\":[");
            for (td, 0..) |tool, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("{{\"name\":\"{s}\",\"description\":\"{s}\",\"input_schema\":{s}}}", .{
                    tool.name,
                    tool.description,
                    tool.parameters_json,
                });
            }
            try writer.writeAll("]");
        }
    }

    if (think_budget > 0) {
        try writer.print(",\"thinking\":{{\"type\":\"enabled\",\"budget_tokens\":{d}}}", .{think_budget});
    }
    if (opts.stream) {
        try writer.writeAll(",\"stream\":true");
    }
    try writer.writeAll("}");
}

// ─────────────────────────────────────────────
// HTTP core
// ─────────────────────────────────────────────

fn openRequest(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
    cfg: *config.Config,
    extra_hdrs: []const std.http.Header,
) !struct { req: std.http.Client.Request, hdrs: []std.http.Header } {
    const hdrs = try authHeaders(allocator, cfg);
    var all = std.ArrayList(std.http.Header).initCapacity(allocator, hdrs.len + extra_hdrs.len) catch unreachable;
    for (hdrs) |h| try all.append(allocator, h);
    for (extra_hdrs) |h| try all.append(allocator, h);
    const owned = try all.toOwnedSlice(allocator);
    // Note: `owned` (and the Bearer string inside) intentionally lives as
    // long as the request; the client keeps pointers into it. A ~100-byte
    // leak per turn is irrelevant for a REPL session on this hardware.

    const uri = try std.Uri.parse(url);
    var req = try client.request(method, uri, .{ .extra_headers = owned });
    if (body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
    }
    return .{ .req = req, .hdrs = owned };
}

/// Non-streaming POST; returns full response (status, body). Caller frees.
pub fn httpPostFull(
    allocator: std.mem.Allocator,
    url: []const u8,
    body: []const u8,
    cfg: *config.Config,
) !HttpResult {
    if (cfg.debug_mode) {
        std.debug.print("\n[DEBUG] HTTP POST to: {s} ({d} bytes)\n", .{ url, body.len });
    }
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    if (std.mem.startsWith(u8, url, "https://")) {
        client.ca_bundle.rescan(allocator) catch {
            std.log.err("TLS/HTTPS not available on this system. Use the retrobridge HTTP base_url.", .{});
            return error.TlsNotAvailable;
        };
    }

    var opened = try openRequest(allocator, &client, .POST, url, body, cfg, &.{});
    defer opened.req.deinit();
    if (cfg.debug_mode) std.debug.print("[DEBUG] request opened\n", .{});

    var req_write_buf: [1024]u8 = undefined;
    var req_body = try opened.req.sendBodyUnflushed(&req_write_buf);
    try req_body.writer.writeAll(body);
    try req_body.end();
    try opened.req.connection.?.flush();
    if (cfg.debug_mode) std.debug.print("[DEBUG] body sent\n", .{});

    var redirect_buf: [4096]u8 = undefined;
    var response = try opened.req.receiveHead(&redirect_buf);
    if (cfg.debug_mode) std.debug.print("[DEBUG] head received\n", .{});

    const status: u16 = @intFromEnum(response.head.status);

    var response_transfer_buf: [4096]u8 = undefined;
    // Fork v3.6 fix: .unlimited makes allocRemaining pre-allocate maxInt
    // bytes on Zig 0.15 -> instant OutOfMemory. A real chat completion
    // response fits far under 64MB.
    const response_body = try response.reader(&response_transfer_buf).allocRemaining(allocator, config_Limit64m);
    if (cfg.debug_mode) std.debug.print("[DEBUG] body read: {d} bytes\n", .{response_body.len});

    // NOTE: do NOT touch response.head.content_type here — head string
    // fields alias the client's internal header buffer, which the body
    // read above has already recycled. A stale slice meant dupe() saw a
    // garbage length and OOM'd. Callers of the non-stream path never
    // need the content type (SSE detection lives in streamCall instead).
    return HttpResult{ .status = status, .content_type = "", .body = response_body };
}

/// Simple GET with Bearer auth (for /v1/models). Non-2xx is returned as a
/// normal HttpResult — only transport failures raise errors.
fn httpGet(allocator: std.mem.Allocator, url: []const u8, cfg: *config.Config) !HttpResult {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    if (std.mem.startsWith(u8, url, "https://")) {
        client.ca_bundle.rescan(allocator) catch return error.TlsNotAvailable;
    }
    var opened = try openRequest(allocator, &client, .GET, url, null, cfg, &.{});
    defer opened.req.deinit();
    try opened.req.sendBodiless();

    var redirect_buf: [4096]u8 = undefined;
    var response = try opened.req.receiveHead(&redirect_buf);
    const status: u16 = @intFromEnum(response.head.status);

    var transfer_buf: [4096]u8 = undefined;
    const resp_body = try response.reader(&transfer_buf).allocRemaining(allocator, config_Limit8m);

    return HttpResult{ .status = status, .content_type = "", .body = resp_body };
}

// ─────────────────────────────────────────────
// High-level: one model call (streaming or not)
// ─────────────────────────────────────────────

/// Unified model call. Picks streaming SSE when cfg.transport_api_stream
/// and the server actually answers with an event-stream; otherwise reads a
/// plain body and parses it for the configured style. Falls back once
/// without thinking knobs if the provider rejects the request (400/404).
pub fn modelCall(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
    tool_defs: ?[]const ToolDef,
    sink: ?*const Sink,
) !agent.AgentResponse {
    const url = try buildApiUrl(allocator, cfg);
    defer allocator.free(url);

    if (cfg.transport_api_stream) {
        var attempt: u8 = 0;
        var thinking_on = true;
        while (attempt < 4) : (attempt += 1) {
            const body = try buildRequestBody(allocator, cfg, history, tool_defs, .{ .stream = true, .thinking = thinking_on });
            const result = streamCall(allocator, cfg, url, body, sink, thinking_on) catch |err| {
                if (err == error.StreamRejectedThinking and thinking_on) {
                    thinking_on = false;
                    Sink.stage(sink, "provider rejected thinking knobs, retrying without");
                    continue;
                }
                if (err == error.MaxTokClamped) {
                    Sink.stage(sink, "clamped max_tokens to provider cap, retrying");
                    continue;
                }
                return err;
            };
            return result;
        }
        const msg = try allocator.dupe(u8, "Error: provider rejected the streaming request repeatedly.");
        return agent.AgentResponse{ .text = msg, .done = true };
    }

    // Non-streaming path with two recovery passes: drop thinking knobs on
    // rejection; clamp max_tokens down to the provider's own reported cap.
    var thinking_on = true;
    var pass: u8 = 0;
    while (pass < 4) : (pass += 1) {
        const body = try buildRequestBody(allocator, cfg, history, tool_defs, .{ .stream = false, .thinking = thinking_on });
        defer allocator.free(body);

        const res = httpPostFull(allocator, url, body, cfg) catch |e| {
            const msg = std.fmt.allocPrint(allocator, "Error: could not reach the AI provider ({s}). Check the bridge is running.", .{@errorName(e)}) catch
                "Error: could not reach the AI provider. Check your connection and API key.";
            return agent.AgentResponse{ .text = msg, .done = true };
        };
        defer allocator.free(res.content_type);

        if (res.status >= 400) {
            // (a) provider names its real max_tokens ceiling in the error — use it
            if (clampFromRangeError(res.body)) |cap| {
                if (cfg.transport_api_max_tokens == 0 or cfg.transport_api_max_tokens > cap) {
                    cfg.transport_api_max_tokens = cap;
                    allocator.free(res.body);
                    Sink.stage(sink, "max_tokens clamped to provider cap, retrying");
                    continue;
                }
            }
            // (b) thinking knobs not accepted here
            if (thinking_on and (res.status == 400 or res.status == 404)) {
                thinking_on = false;
                allocator.free(res.body);
                Sink.stage(sink, "provider rejected thinking knobs, retrying without");
                continue;
            }
            const msg = try apiErrorText(allocator, res.body);
            allocator.free(res.body);
            return agent.AgentResponse{ .text = msg, .done = true };
        }
        var parsed = parseResponseForStyle(allocator, cfg, res.body) catch {
            const msg = try allocator.dupe(u8, "Error: could not parse API response.");
            return agent.AgentResponse{ .text = msg, .done = true };
        };
        allocator.free(res.body);
        parsed.done = true;
        return parsed;
    }
    const msg = try allocator.dupe(u8, "Error: request failed after recovery attempts.");
    return agent.AgentResponse{ .text = msg, .done = true };
}

fn apiErrorText(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    // Best effort: {"error":{"message":"..."}} or {"message":"..."}
    if (std.json.parseFromSlice(std.json.Value, allocator, body, .{})) |parsed| {
        defer parsed.deinit();
        if (parsed.value == .object) {
            var err_node = parsed.value.object;
            if (err_node.get("error")) |e| { if (e == .object) { err_node = e.object; } }
            if (err_node.get("message")) |m| if (m == .string) {
                return try std.fmt.allocPrint(allocator, "Error: provider said: {s}", .{m.string});
            };
        }
    } else |_| {}
    const head = body[0..@min(body.len, 160)];
    return try std.fmt.allocPrint(allocator, "Error: provider returned HTTP error: {s}", .{head});
}

// ─────────────────────────────────────────────
// Streaming (SSE) implementation
// ─────────────────────────────────────────────

const PartialTool = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    args: std.ArrayList(u8),
};

const StreamAccum = struct {
    allocator: std.mem.Allocator,
    style: config.ApiStyle,
    text: std.ArrayList(u8),
    thinking: std.ArrayList(u8),
    tools: [8]PartialTool = [_]PartialTool{.{ .args = undefined }} ** 8,
    tool_names: usize = 0,
    finish: []const u8 = "",
    usage_in: u64 = 0,
    usage_out: u64 = 0,
    open_block: u32 = 0,

    fn toolSlot(self: *StreamAccum, idx_in: usize) *PartialTool {
        var idx = idx_in;
        if (idx >= self.tools.len) idx = self.tools.len - 1; // clamp hostile index
        while (self.tool_names < idx + 1 and self.tool_names < self.tools.len) : (self.tool_names += 1) {
            self.tools[self.tool_names].args = std.ArrayList(u8).initCapacity(self.allocator, 256) catch unreachable;
        }
        return &self.tools[idx];
    }
};

fn streamCall(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    url: []const u8,
    body: []const u8, // owned here; freed by this call
    sink: ?*const Sink,
    had_thinking: bool,
) !agent.AgentResponse {
    defer allocator.free(body);
    if (cfg.debug_mode) std.debug.print("[DEBUG] stream POST to {s}\n", .{url});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    if (std.mem.startsWith(u8, url, "https://")) {
        client.ca_bundle.rescan(allocator) catch return error.TlsNotAvailable;
    }
    var opened = try openRequest(allocator, &client, .POST, url, body, cfg, &.{});
    defer opened.req.deinit();

    var write_buf: [1024]u8 = undefined;
    var req_body = try opened.req.sendBodyUnflushed(&write_buf);
    try req_body.writer.writeAll(body);
    try req_body.end();
    try opened.req.connection.?.flush();

    var redirect_buf: [4096]u8 = undefined;
    var response = opened.req.receiveHead(&redirect_buf) catch {
        const msg = try allocator.dupe(u8, "Error: no response from the bridge/provider (stream).");
        return agent.AgentResponse{ .text = msg, .done = true };
    };
    const status: u16 = @intFromEnum(response.head.status);

    if (status >= 400) {
        var tb: [4096]u8 = undefined;
        const err_body = response.reader(&tb).allocRemaining(allocator, config_Limit64k) catch "";
        // provider names its real max_tokens ceiling in the error -> clamp & retry
        if (err_body.len > 0) {
            if (clampFromRangeError(err_body)) |cap| {
                if (cfg.transport_api_max_tokens == 0 or cfg.transport_api_max_tokens > cap) {
                    cfg.transport_api_max_tokens = cap;
                    allocator.free(err_body);
                    return error.MaxTokClamped;
                }
            }
        }
        if (had_thinking and (status == 400 or status == 404)) {
            if (err_body.len > 0) allocator.free(err_body);
            return error.StreamRejectedThinking;
        }
        const msg = if (err_body.len > 0) blk: {
            const t = apiErrorText(allocator, err_body) catch err_body;
            if (t.ptr != err_body.ptr) allocator.free(err_body);
            break :blk t;
        } else try std.fmt.allocPrint(allocator, "Error: provider returned HTTP {d}", .{status});
        return agent.AgentResponse{ .text = msg, .done = true };
    }

    var ctype: []const u8 = "";
    if (response.head.content_type) |ct| ctype = ct;
    const is_sse = std.mem.indexOf(u8, ctype, "event-stream") != null;

    if (!is_sse) {
        // Provider answered with a plain body despite stream=true: parse normally.
        var rb: [4096]u8 = undefined;
        const plain = response.reader(&rb).allocRemaining(allocator, config_Limit32m) catch {
            const msg = try allocator.dupe(u8, "Error: failed reading provider response.");
            return agent.AgentResponse{ .text = msg, .done = true };
        };
        defer allocator.free(plain);
        var parsed = parseResponseForStyle(allocator, cfg, plain) catch {
            const msg = try allocator.dupe(u8, "Error: could not parse API response.");
            return agent.AgentResponse{ .text = msg, .done = true };
        };
        // UI never saw the text: emit it now (counts as streamed display).
        if (parsed.text) |t| {
            Sink.text(sink, t, false, false);
            parsed.text_streamed = true;
        }
        parsed.done = true;
        return parsed;
    }

    // ── SSE loop ──
    var acc = StreamAccum{
        .allocator = allocator,
        .style = cfg.transport_api_style,
        .text = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable,
        .thinking = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable,
    };
    defer acc.text.deinit(allocator);
    defer acc.thinking.deinit(allocator);

    // ── SSE loop (line-based, zero-copy through Client.Reader) ──
    // Big transfer buffer: responses-style "response.completed" lines are one
    // giant JSON object; 4KB would die with StreamTooLong.
    const transfer_buf = allocator.alloc(u8, 2 * 1024 * 1024) catch allocator.alloc(u8, 64 * 1024) catch return error.OutOfMemory;
    defer allocator.free(transfer_buf);
    var reader = response.reader(transfer_buf);
    var saw_done = false;
    var read_err: ?anyerror = null;
    var user_stopped = false;

    read_loop: while (!saw_done) {
        // Fork v3.6: user interrupt (ESC / Ctrl+C) checked between SSE events
        if (Sink.stopRequested(sink)) {
            user_stopped = true;
            break :read_loop;
        }
        const maybe_line = reader.takeDelimiter('\n') catch |err| {
            read_err = err;
            break :read_loop;
        };
        const raw_line = maybe_line orelse break :read_loop;
        const l = std.mem.trim(u8, raw_line, " \r");
        if (l.len > 0 and std.mem.startsWith(u8, l, "data:")) {
            const payload = std.mem.trim(u8, l["data:".len..], " ");
            if (std.mem.eql(u8, payload, "[DONE]")) {
                saw_done = true;
            } else if (payload.len > 0) {
                handleSseEvent(&acc, sink, payload) catch {};
            }
        }
    }

    // ── finalize: build AgentResponse ──
    if (acc.thinking.items.len > 0) {
        Sink.thinking(sink, "", true, false); // close thinking block (summary line in brief mode)
    }
    if (acc.tool_names > 0) {
        if (acc.text.items.len > 0) Sink.text(sink, "", true, false); // close streamed text before tools
        var calls = std.ArrayList(agent.ToolCall).initCapacity(allocator, acc.tool_names) catch unreachable;
        var ti: usize = 0;
        while (ti < acc.tool_names) : (ti += 1) {
            const slot = &acc.tools[ti];
            if (slot.name.len == 0) continue; // skip malformed
            // transfer ownership DIRECTLY from the slot (a struct copy would
            // leave slot.args pointing at the moved buffer -> double free,
            // which corrupted the heap and crashed AV-style later)
            const id_owned: []const u8 = if (slot.id.len > 0) slot.id else (allocator.dupe(u8, "call") catch continue);
            const args_owned = slot.args.toOwnedSlice(allocator) catch {
                if (id_owned.ptr != slot.id.ptr) allocator.free(id_owned);
                continue;
            };
            calls.append(allocator, .{
                .id = id_owned,
                .name = slot.name,
                .arguments = args_owned,
            }) catch {
                if (id_owned.ptr != slot.id.ptr) allocator.free(id_owned);
                allocator.free(args_owned);
                continue;
            };
            slot.id = ""; slot.name = ""; // moved into the call
        }
        const resp = agent.AgentResponse{
            .text = if (acc.text.items.len > 0) try acc.text.toOwnedSlice(allocator) else null,
            .tool_calls = try calls.toOwnedSlice(allocator),
            .done = false,
            .usage_in = acc.usage_in,
            .usage_out = acc.usage_out,
            .text_streamed = true,
            .interrupted = user_stopped,
        };
        // free slot buffers of remaining tools
        var fj: usize = 0;
        while (fj < acc.tool_names) : (fj += 1) {
            if (acc.tools[fj].args.items.len > 0) acc.tools[fj].args.deinit(allocator);
            if (acc.tools[fj].id.len > 0) allocator.free(acc.tools[fj].id);
            if (acc.tools[fj].name.len > 0) allocator.free(acc.tools[fj].name);
        }
        return resp;
    }

    if (acc.text.items.len > 0) {
        Sink.text(sink, "", true, false); // close text block
        return agent.AgentResponse{
            .text = try acc.text.toOwnedSlice(allocator),
            .done = true,
            .usage_in = acc.usage_in,
            .usage_out = acc.usage_out,
            .text_streamed = true,
            .interrupted = user_stopped,
        };
    }

    if (read_err) |e| {
        std.log.err("stream read error: {s}", .{@errorName(e)});
        const msg = try allocator.dupe(u8, "Error: connection dropped mid-response. Try again.");
        return agent.AgentResponse{ .text = msg, .done = true };
    }

    const msg = try allocator.dupe(u8, "Error: stream produced no content (empty response).");
    return agent.AgentResponse{ .text = msg, .done = true };
}

fn handleSseEvent(acc: *StreamAccum, sink: ?*const Sink, payload: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, acc.allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const root = parsed.value.object;

    switch (acc.style) {
        .chat, .responses => try handleOpenAIStreamEvent(acc, sink, root),
        .anthropic => try handleAnthropicStreamEvent(acc, sink, root),
    }
}

fn handleOpenAIStreamEvent(acc: *StreamAccum, sink: ?*const Sink, root: std.json.ObjectMap) !void {
    const alloc = acc.allocator;

    // responses API: flat event objects with "type"
    if (root.get("type")) |tv| {
        if (tv == .string) {
            const t = tv.string;
            if (std.mem.eql(u8, t, "response.output_text.delta")) {
                if (root.get("delta")) |d| if (d == .string) {
                    try acc.text.appendSlice(alloc, d.string);
                    Sink.text(sink, d.string, acc.text.items.len > d.string.len, true);
                };
                return;
            } else if (std.mem.eql(u8, t, "response.reasoning_summary_text.delta") or std.mem.eql(u8, t, "response.output_text.reasoning.delta")) {
                if (root.get("delta")) |d| if (d == .string) {
                    try acc.thinking.appendSlice(alloc, d.string);
                    Sink.thinking(sink, d.string, acc.thinking.items.len > d.string.len, true);
                };
                return;
            } else if (std.mem.eql(u8, t, "response.output_item.added")) {
                if (root.get("item")) |it| if (it == .object) {
                    if (it.object.get("type")) |ty| if (ty == .string and std.mem.eql(u8, ty.string, "function_call")) {
                        const idx: usize = if (root.get("output_index")) |oi| blk: {
                            break :blk if (oi == .integer) @intCast(@max(oi.integer, 0)) else acc.tool_names;
                        } else acc.tool_names;
                        const slot = acc.toolSlot(idx);
                        if (it.object.get("call_id")) |cid| { if (cid == .string and slot.id.len == 0) slot.id = try alloc.dupe(u8, cid.string); }
                        if (it.object.get("name")) |nm| { if (nm == .string and slot.name.len == 0) slot.name = try alloc.dupe(u8, nm.string); }
                    };
                };
                return;
            } else if (std.mem.eql(u8, t, "response.function_call_arguments.delta")) {
                const idx: usize = if (root.get("output_index")) |oi| blk: {
                    break :blk if (oi == .integer) @intCast(@max(oi.integer, 0)) else 0;
                } else 0;
                const slot = acc.toolSlot(idx);
                if (root.get("delta")) |d| if (d == .string) {
                    try slot.args.appendSlice(alloc, d.string);
                };
                return;
            } else if (std.mem.eql(u8, t, "response.completed")) {
                if (root.get("response")) |r| if (r == .object) {
                    if (r.object.get("usage")) |u| if (u == .object) {
                        if (u.object.get("input_tokens")) |v| { if (v == .integer) acc.usage_in = @intCast(@max(v.integer, 0)); }
                        if (u.object.get("output_tokens")) |v| { if (v == .integer) acc.usage_out = @intCast(@max(v.integer, 0)); }
                    };
                };
                return;
            }
        }
    }

    // chat completions dialect: choices[0].delta
    const choices = root.get("choices") orelse return;
    if (choices != .array or choices.array.items.len == 0) {
        // top-level usage (some gateways)
        if (root.get("usage")) |u| if (u == .object) {
            if (u.object.get("prompt_tokens")) |v| { if (v == .integer) acc.usage_in = @intCast(@max(v.integer, 0)); }
            if (u.object.get("completion_tokens")) |v| { if (v == .integer) acc.usage_out = @intCast(@max(v.integer, 0)); }
        };
        return;
    }
    const c0 = choices.array.items[0];
    if (c0 != .object) return;

    if (c0.object.get("finish_reason")) |fr| {
        if (fr == .string) acc.finish = fr.string;
    }

    const delta = c0.object.get("delta") orelse return;
    if (delta != .object) return;

    if (delta.object.get("reasoning_content")) |rc| {
        if (rc == .string and rc.string.len > 0) {
            try acc.thinking.appendSlice(alloc, rc.string);
            Sink.thinking(sink, rc.string, acc.thinking.items.len > rc.string.len, true);
        }
    }
    if (delta.object.get("content")) |ct| {
        if (ct == .string and ct.string.len > 0) {
            try acc.text.appendSlice(alloc, ct.string);
            Sink.text(sink, ct.string, acc.text.items.len > ct.string.len, true);
        }
    }
    if (delta.object.get("tool_calls")) |tcs| {
        if (tcs == .array) {
            for (tcs.array.items) |tc| {
                if (tc != .object) continue;
                const idx: usize = if (tc.object.get("index")) |ix| blk: {
                    break :blk if (ix == .integer) @intCast(@max(ix.integer, 0)) else acc.tool_names;
                } else acc.tool_names;
                const slot = acc.toolSlot(idx);
                if (tc.object.get("id")) |id| { if (id == .string and id.string.len > 0 and slot.id.len == 0) slot.id = try alloc.dupe(u8, id.string); }
                if (tc.object.get("function")) |f| if (f == .object) {
                    if (f.object.get("name")) |nm| { if (nm == .string and nm.string.len > 0 and slot.name.len == 0) slot.name = try alloc.dupe(u8, nm.string); }
                    if (f.object.get("arguments")) |ar| if (ar == .string and ar.string.len > 0) {
                        try slot.args.appendSlice(alloc, ar.string);
                    };
                };
            }
        }
    }
}

fn handleAnthropicStreamEvent(acc: *StreamAccum, sink: ?*const Sink, root: std.json.ObjectMap) !void {
    const alloc = acc.allocator;
    const tv = root.get("type") orelse return;
    if (tv != .string) return;
    const t = tv.string;

    if (std.mem.eql(u8, t, "message_start")) {
        if (root.get("message")) |m| if (m == .object) {
            if (m.object.get("usage")) |u| if (u == .object) {
                if (u.object.get("input_tokens")) |v| { if (v == .integer) acc.usage_in = @intCast(@max(v.integer, 0)); }
            };
        };
    } else if (std.mem.eql(u8, t, "content_block_start")) {
        const idx: usize = if (root.get("index")) |ix| blk: {
            break :blk if (ix == .integer) @intCast(@max(ix.integer, 0)) else 0;
        } else 0;
        acc.open_block = @intCast(idx);
        if (root.get("content_block")) |cb| if (cb == .object) {
            if (cb.object.get("type")) |bt| if (bt == .string and std.mem.eql(u8, bt.string, "tool_use")) {
                const slot = acc.toolSlot(idx);
                if (cb.object.get("id")) |id| { if (id == .string and slot.id.len == 0) slot.id = try alloc.dupe(u8, id.string); }
                if (cb.object.get("name")) |nm| { if (nm == .string and slot.name.len == 0) slot.name = try alloc.dupe(u8, nm.string); }
            };
        };
    } else if (std.mem.eql(u8, t, "content_block_delta")) {
        if (root.get("delta")) |d| if (d == .object) {
            if (d.object.get("type")) |dt| if (dt == .string) {
                if (std.mem.eql(u8, dt.string, "text_delta")) {
                    if (d.object.get("text")) |x| if (x == .string) {
                        try acc.text.appendSlice(alloc, x.string);
                        Sink.text(sink, x.string, acc.text.items.len > x.string.len, true);
                    };
                } else if (std.mem.eql(u8, dt.string, "thinking_delta")) {
                    if (d.object.get("thinking")) |x| if (x == .string) {
                        try acc.thinking.appendSlice(alloc, x.string);
                        Sink.thinking(sink, x.string, acc.thinking.items.len > x.string.len, true);
                    };
                } else if (std.mem.eql(u8, dt.string, "input_json_delta")) {
                    if (d.object.get("partial_json")) |x| if (x == .string) {
                        const slot = acc.toolSlot(acc.open_block);
                        try slot.args.appendSlice(alloc, x.string);
                    };
                }
            };
        };
    } else if (std.mem.eql(u8, t, "message_delta")) {
        if (root.get("usage")) |u| if (u == .object) {
            if (u.object.get("output_tokens")) |v| { if (v == .integer) acc.usage_out = @intCast(@max(v.integer, 0)); }
        };
    }
}

// ─────────────────────────────────────────────
// Non-stream response parsing per style
// ─────────────────────────────────────────────

pub fn parseResponseForStyle(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    body: []const u8,
) !agent.AgentResponse {
    return switch (cfg.transport_api_style) {
        .chat => try parseChatResponse(allocator, cfg, body),
        .responses => try parseResponsesResponse(allocator, cfg, body),
        .anthropic => try parseAnthropicResponse(allocator, cfg, body),
    };
}

const Usage = struct { in: u64, out: u64 };

const Limit = std.Io.Limit;
const config_Limit64k = Limit.limited(64 * 1024);
const config_Limit32m = Limit.limited(32 * 1024 * 1024);
const config_Limit8m = Limit.limited(8 * 1024 * 1024);
const config_Limit64m = Limit.limited(64 * 1024 * 1024);

fn parseUsage(obj: std.json.ObjectMap, in_keys: []const []const u8, out_keys: []const []const u8) Usage {
    var res = Usage{ .in = 0, .out = 0 };
    if (obj.get("usage") == null) return res;
    const u = obj.get("usage").?;
    if (u != .object) return res;
    for (in_keys) |k| { if (u.object.get(k)) |v| { if (v == .integer) res.in = @intCast(@max(v.integer, 0)); } }
    for (out_keys) |k| { if (u.object.get(k)) |v| { if (v == .integer) res.out = @intCast(@max(v.integer, 0)); } }
    return res;
}

fn extractToolCallsFromArray(allocator: std.mem.Allocator, tcs: std.json.Value) ![]agent.ToolCall {
    if (tcs != .array) return error.NoToolCalls;
    var calls = std.ArrayList(agent.ToolCall).initCapacity(allocator, 0) catch unreachable;
    for (tcs.array.items) |item| {
        if (item != .object) continue;
        const idv = item.object.get("id") orelse continue;
        const fv = item.object.get("function") orelse continue;
        if (fv != .object) continue;
        const nm = fv.object.get("name") orelse continue;
        const ar = fv.object.get("arguments") orelse continue;
        if (idv != .string or nm != .string or ar != .string) continue;
        try calls.append(allocator, .{
            .id = try allocator.dupe(u8, idv.string),
            .name = try allocator.dupe(u8, nm.string),
            .arguments = try allocator.dupe(u8, ar.string),
        });
    }
    if (calls.items.len == 0) {
        calls.deinit(allocator);
        return error.NoToolCalls;
    }
    return try calls.toOwnedSlice(allocator);
}

fn parseChatResponse(allocator: std.mem.Allocator, cfg: *config.Config, body: []const u8) !agent.AgentResponse {
    _ = cfg;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadFormat;

    const root = parsed.value.object;
    if (root.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0) {
            const first = choices.array.items[0];
            if (first == .object) {
                if (first.object.get("message")) |msg| {
                    if (msg == .object) {
                        if (msg.object.get("tool_calls")) |tc| {
                            if (tc == .array and tc.array.items.len > 0) {
                                const calls = extractToolCallsFromArray(allocator, tc) catch null;
                                if (calls) |c| {
                                    var maybe_text: ?[]const u8 = null;
                                    if (msg.object.get("content")) |ct| {
                                        if (ct == .string and ct.string.len > 0) maybe_text = try allocator.dupe(u8, ct.string);
                                    }
                                    return agent.AgentResponse{ .text = maybe_text, .tool_calls = c, .done = false };
                                }
                            }
                        }
                        if (msg.object.get("content")) |c| {
                            if (c == .string) {
                                const u = parseUsage(root, &.{"prompt_tokens"}, &.{"completion_tokens"});
                                return agent.AgentResponse{
                                    .text = try allocator.dupe(u8, c.string),
                                    .done = true,
                                    .usage_in = u.in,
                                    .usage_out = u.out,
                                };
                            }
                        }
                    }
                }
            }
        }
    }
    return error.BadFormat;
}

fn parseResponsesResponse(allocator: std.mem.Allocator, cfg: *config.Config, body: []const u8) !agent.AgentResponse {
    _ = cfg;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadFormat;
    const root = parsed.value.object;

    const output = root.get("output") orelse return error.BadFormat;
    if (output != .array) return error.BadFormat;

    var text_parts = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable;
    defer text_parts.deinit(allocator);
    var calls = std.ArrayList(agent.ToolCall).initCapacity(allocator, 0) catch unreachable;
    errdefer calls.deinit(allocator);

    for (output.array.items) |item| {
        if (item != .object) continue;
        const ty = item.object.get("type") orelse continue;
        if (ty != .string) continue;
        if (std.mem.eql(u8, ty.string, "function_call")) {
            const cid = item.object.get("call_id") orelse item.object.get("id") orelse continue;
            const nm = item.object.get("name") orelse continue;
            const ar = item.object.get("arguments") orelse continue;
            if (cid != .string or nm != .string or ar != .string) continue;
            try calls.append(allocator, .{
                .id = try allocator.dupe(u8, cid.string),
                .name = try allocator.dupe(u8, nm.string),
                .arguments = try allocator.dupe(u8, ar.string),
            });
        } else if (std.mem.eql(u8, ty.string, "message")) {
            if (item.object.get("content")) |cont| {
                if (cont == .array) {
                    for (cont.array.items) |part| {
                        if (part != .object) continue;
                        if (part.object.get("text")) |tx| if (tx == .string) {
                            if (text_parts.items.len > 0) text_parts.append(allocator, '\n') catch {};
                            text_parts.appendSlice(allocator, tx.string) catch {};
                        };
                    }
                }
            }
        }
    }

    const u = parseUsage(root, &.{"input_tokens"}, &.{"output_tokens"});
    if (calls.items.len > 0) {
        return agent.AgentResponse{
            .text = if (text_parts.items.len > 0) try allocator.dupe(u8, text_parts.items) else null,
            .tool_calls = try calls.toOwnedSlice(allocator),
            .done = false,
            .usage_in = u.in,
            .usage_out = u.out,
        };
    }
    if (text_parts.items.len > 0) {
        if (calls.items.len > 0) calls.deinit(allocator);
        return agent.AgentResponse{
            .text = try allocator.dupe(u8, text_parts.items),
            .done = true,
            .usage_in = u.in,
            .usage_out = u.out,
        };
    }
    return error.BadFormat;
}

fn parseAnthropicResponse(allocator: std.mem.Allocator, cfg: *config.Config, body: []const u8) !agent.AgentResponse {
    _ = cfg;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadFormat;
    const root = parsed.value.object;

    const content = root.get("content") orelse return error.BadFormat;
    if (content != .array) return error.BadFormat;

    var text_parts = std.ArrayList(u8).initCapacity(allocator, 1024) catch unreachable;
    defer text_parts.deinit(allocator);
    var calls = std.ArrayList(agent.ToolCall).initCapacity(allocator, 0) catch unreachable;
    errdefer calls.deinit(allocator);

    for (content.array.items) |part| {
        if (part != .object) continue;
        const ty = part.object.get("type") orelse continue;
        if (ty != .string) continue;
        if (std.mem.eql(u8, ty.string, "text")) {
            if (part.object.get("text")) |tx| if (tx == .string) {
                if (text_parts.items.len > 0) text_parts.append(allocator, '\n') catch {};
                text_parts.appendSlice(allocator, tx.string) catch {};
            };
        } else if (std.mem.eql(u8, ty.string, "tool_use")) {
            const idv = part.object.get("id") orelse continue;
            const nm = part.object.get("name") orelse continue;
            const input = part.object.get("input") orelse continue;
            if (idv != .string or nm != .string) continue;
            // Serialize input object back to compact JSON text
            var args_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch unreachable;
            jsonCompact(input, args_buf.writer(allocator)) catch {
                args_buf.deinit(allocator);
                continue;
            };
            try calls.append(allocator, .{
                .id = try allocator.dupe(u8, idv.string),
                .name = try allocator.dupe(u8, nm.string),
                .arguments = try args_buf.toOwnedSlice(allocator),
            });
        }
    }

    const u = parseUsage(root, &.{"input_tokens"}, &.{"output_tokens"});
    if (calls.items.len > 0) {
        return agent.AgentResponse{
            .text = if (text_parts.items.len > 0) try allocator.dupe(u8, text_parts.items) else null,
            .tool_calls = try calls.toOwnedSlice(allocator),
            .done = false,
            .usage_in = u.in,
            .usage_out = u.out,
        };
    }
    if (text_parts.items.len > 0) {
        if (calls.items.len > 0) calls.deinit(allocator);
        return agent.AgentResponse{
            .text = try allocator.dupe(u8, text_parts.items),
            .done = true,
            .usage_in = u.in,
            .usage_out = u.out,
        };
    }
    return error.BadFormat;
}

fn jsonCompact(v: std.json.Value, w: anytype) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string => |s| try w.print("{s}", .{s}),
        .string => |s| try writeJsonString(w, s),
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |it, idx| {
                if (idx > 0) try w.writeByte(',');
                try jsonCompact(it, w);
            }
            try w.writeByte(']');
        },
        .object => |obj| {
            try w.writeByte('{');
            for (obj.keys(), obj.values(), 0..) |k, val, idx| {
                if (idx > 0) try w.writeByte(',');
                try writeJsonString(w, k);
                try w.writeByte(':');
                try jsonCompact(val, w);
            }
            try w.writeByte('}');
        },
    }
}

/// One-shot non-streaming completion for internal chores (compaction
/// summaries). Returns owned text or an error. Caller frees.
pub fn simpleCompletion(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
) ![]const u8 {
    const url = try buildApiUrl(allocator, cfg);
    defer allocator.free(url);
    const body = try buildRequestBody(allocator, cfg, history, null, .{ .stream = false, .thinking = false });
    defer allocator.free(body);

    const res = try httpPostFull(allocator, url, body, cfg);
    defer allocator.free(res.content_type);
    defer allocator.free(res.body);

    if (res.status >= 400) return error.ProviderRejected;
    const parsed = try parseResponseForStyle(allocator, cfg, res.body);
    if (parsed.text) |t| return t;
    if (parsed.tool_calls) |tc| freeToolCalls(allocator, tc);
    return error.NoText;
}

pub fn freeToolCalls(allocator: std.mem.Allocator, calls: []const agent.ToolCall) void {
    for (calls) |c| {
        allocator.free(c.id);
        allocator.free(c.name);
        allocator.free(c.arguments);
    }
    allocator.free(@constCast(calls));
}

// ─────────────────────────────────────────────
// Model listing + upstream admin (via the bridge/base_url)
// ─────────────────────────────────────────────

pub fn listModels(allocator: std.mem.Allocator, cfg: *config.Config) ![]const []const u8 {
    const url = try std.fmt.allocPrint(allocator, "{s}/v1/models", .{cfg.transport_api_base_url});
    defer allocator.free(url);

    const res = httpGet(allocator, url, cfg) catch return error.NetFail;
    defer allocator.free(res.body);
    if (res.status >= 400) return error.Http4xx;
    if (res.body.len > 4 * 1024 * 1024) return error.TooBig;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, res.body, .{}) catch return error.BadJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadJson;
    const root = parsed.value.object;

    var items: ?std.json.Value = null;
    if (root.get("data")) |d| {
        if (d == .array) items = d;
    } else if (root.get("models")) |d| {
        if (d == .array) items = d;
    }

    var out = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    errdefer out.deinit(allocator);
    if (items) |arr| {
        for (arr.array.items) |it| {
            if (it == .string) {
                try out.append(allocator, try allocator.dupe(u8, it.string));
            } else if (it == .object) {
                if (it.object.get("id")) |id| if (id == .string) {
                    try out.append(allocator, try allocator.dupe(u8, id.string));
                };
            }
        }
    }
    return try out.toOwnedSlice(allocator);
}

pub fn freeModels(allocator: std.mem.Allocator, models: []const []const u8) void {
    for (models) |m| allocator.free(m);
    allocator.free(models);
}

pub const AdminResult = struct { ok: bool, detail: []const u8 };

/// v3.6d CONTRACT: .detail is ALWAYS allocator-owned. Every caller does an
/// unconditional allocator.free(res.detail); returning static strings caused
/// a "panic: Invalid free" at the startup banner whenever the bridge was
/// down (v3.6c field crash). Failures now dupe the message (OOM -> error).
pub fn adminUpstream(allocator: std.mem.Allocator, cfg: *config.Config, new_upstream: ?[]const u8) !AdminResult {
    const url = try std.fmt.allocPrint(allocator, "{s}/__admin/upstream", .{cfg.transport_api_base_url});
    defer allocator.free(url);

    if (new_upstream) |nu| {
        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();
        var opened = openRequest(allocator, &client, .POST, url, nu, cfg, &.{}) catch return .{
            .ok = false, .detail = try allocator.dupe(u8, "cannot reach bridge"),
        };
        defer opened.req.deinit();
        var write_buf: [1024]u8 = undefined;
        var req_body = opened.req.sendBodyUnflushed(&write_buf) catch return .{
            .ok = false, .detail = try allocator.dupe(u8, "bridge send failed"),
        };
        req_body.writer.writeAll(nu) catch {};
        req_body.end() catch {};
        opened.req.connection.?.flush() catch {};
        var redirect_buf: [4096]u8 = undefined;
        var response = opened.req.receiveHead(&redirect_buf) catch return .{
            .ok = false, .detail = try allocator.dupe(u8, "bridge no answer"),
        };
        const status: u16 = @intFromEnum(response.head.status);
        var tb: [2048]u8 = undefined;
        const resp_body = response.reader(&tb).allocRemaining(allocator, config_Limit64k) catch {
            if (status < 400) return .{ .ok = false, .detail = try allocator.dupe(u8, "bridge answer unreadable") };
            return .{ .ok = false, .detail = try allocator.alloc(u8, 0) };
        };
        if (status >= 400) return .{ .ok = false, .detail = resp_body };
        return .{ .ok = true, .detail = resp_body };
    }

    const res = httpGet(allocator, url, cfg) catch return .{
        .ok = false, .detail = try allocator.dupe(u8, "cannot reach bridge"),
    };
    return .{ .ok = res.status < 400, .detail = res.body };
}

// ─────────────────────────────────────────────
// Bridge transport (serial) — stubs unchanged
// ─────────────────────────────────────────────

pub fn bridgeCall(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
) !agent.AgentResponse {
    _ = allocator;
    _ = cfg;
    _ = history;
    return agent.AgentResponse{
        .text = "Bridge transport not yet implemented.",
        .done = true,
    };
}

pub fn fileQueueCall(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
) !agent.AgentResponse {
    _ = allocator;
    _ = cfg;
    _ = history;
    return agent.AgentResponse{
        .text = "File queue transport not yet implemented.",
        .done = true,
    };
}

pub fn localCall(
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: []const agent.Message,
) !agent.AgentResponse {
    _ = allocator;
    _ = cfg;
    _ = history;
    return agent.AgentResponse{
        .text = "Local inference not yet implemented.",
        .done = true,
    };
}

// ─────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

// ─────────────────────────────────────────────
// Tests — parsing fixtures for all three styles
// ─────────────────────────────────────────────

fn testCfg(allocator: std.mem.Allocator, style: config.ApiStyle) config.Config {
    var cfg = config.Config.defaults(allocator);
    cfg.transport_api_style = style;
    return cfg;
}

test "parse: chat text + usage" {
    const alloc = std.testing.allocator;
    var cfg = testCfg(alloc, .chat);
    const json_str =
        \\{"choices":[{"message":{"role":"assistant","content":"Hello 世界"}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}
    ;
    const resp = try parseResponseForStyle(alloc, &cfg, json_str);
    try std.testing.expectEqualStrings("Hello 世界", resp.text.?);
    try std.testing.expectEqual(@as(u64, 10), resp.usage_in);
    try std.testing.expectEqual(@as(u64, 5), resp.usage_out);
    alloc.free(resp.text.?);
}

test "parse: chat tool_calls (null content)" {
    const alloc = std.testing.allocator;
    var cfg = testCfg(alloc, .chat);
    const json_str =
        \\{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"exec","arguments":"{\"command\":\"dir\"}"}}]}}]}
    ;
    const resp = try parseResponseForStyle(alloc, &cfg, json_str);
    try std.testing.expect(resp.tool_calls != null);
    try std.testing.expectEqualStrings("exec", resp.tool_calls.?[0].name);
    for (resp.tool_calls.?) |c| {
        alloc.free(c.id);
        alloc.free(c.name);
        alloc.free(c.arguments);
    }
    alloc.free(resp.tool_calls.?);
}

test "parse: responses style message + function_call" {
    const alloc = std.testing.allocator;
    var cfg = testCfg(alloc, .responses);
    const json_str =
        \\{"output":[{"type":"message","content":[{"type":"output_text","text":"done"}]},{"type":"function_call","call_id":"call_9","name":"ping_host","arguments":"{\"host\":\"1.2.3.4\"}"}],"usage":{"input_tokens":7,"output_tokens":3}}
    ;
    const resp = try parseResponseForStyle(alloc, &cfg, json_str);
    try std.testing.expect(resp.tool_calls != null);
    try std.testing.expectEqualStrings("ping_host", resp.tool_calls.?[0].name);
    try std.testing.expectEqualStrings("call_9", resp.tool_calls.?[0].id);
    try std.testing.expectEqualStrings("done", resp.text.?);
    try std.testing.expectEqual(@as(u64, 7), resp.usage_in);
    alloc.free(resp.text.?);
    for (resp.tool_calls.?) |c| {
        alloc.free(c.id);
        alloc.free(c.name);
        alloc.free(c.arguments);
    }
    alloc.free(resp.tool_calls.?);
}

test "parse: anthropic text + tool_use" {
    const alloc = std.testing.allocator;
    var cfg = testCfg(alloc, .anthropic);
    const json_str =
        \\{"content":[{"type":"text","text":"working"},{"type":"tool_use","id":"tu_1","name":"exec","input":{"command":"dir C:\\","x":1}}],"usage":{"input_tokens":11,"output_tokens":6}}
    ;
    const resp = try parseResponseForStyle(alloc, &cfg, json_str);
    try std.testing.expect(resp.tool_calls != null);
    try std.testing.expectEqualStrings("exec", resp.tool_calls.?[0].name);
    try std.testing.expect(std.mem.indexOf(u8, resp.tool_calls.?[0].arguments, "\"command\"") != null);
    try std.testing.expectEqualStrings("working", resp.text.?);
    alloc.free(resp.text.?);
    for (resp.tool_calls.?) |c| {
        alloc.free(c.id);
        alloc.free(c.name);
        alloc.free(c.arguments);
    }
    alloc.free(resp.tool_calls.?);
}

test "body: chat stream + thinking flags" {
    const alloc = std.testing.allocator;
    var cfg = testCfg(alloc, .chat);
    cfg.transport_thinking = .high;
    cfg.transport_api_max_tokens = 2048;
    const hist = [_]agent.Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "hi" },
        .{ .role = .tool_call, .content = "{\"command\":\"dir\"}", .tool_id = "c1", .tool_name = "exec" },
        .{ .role = .tool_result, .content = "ok", .tool_id = "c1", .tool_name = "exec" },
    };
    const body = try buildRequestBody(alloc, &cfg, &hist, null, .{ .stream = true, .thinking = true });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "enable_thinking") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_call_id\"") != null);
    // must be valid JSON
    var p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    p.deinit();
}

test "body: anthropic folds system and keeps tool_use in assistant" {
    const alloc = std.testing.allocator;
    var cfg = testCfg(alloc, .anthropic);
    const hist = [_]agent.Message{
        .{ .role = .system, .content = "instructions here" },
        .{ .role = .user, .content = "go" },
        .{ .role = .tool_call, .content = "{\"path\":\"a\"}", .tool_id = "t1", .tool_name = "file_read" },
        .{ .role = .tool_result, .content = "data", .tool_id = "t1", .tool_name = "file_read" },
    };
    const body = try buildRequestBody(alloc, &cfg, &hist, null, .{ .stream = false, .thinking = false });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_use") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool_result") != null);
    var p = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch {
        std.debug.print("anthropic body was: {s}\n", .{body});
        return error.TestExpectedEqual;
    };
    p.deinit();
}

test "body: responses style structure" {
    const alloc = std.testing.allocator;
    var cfg = testCfg(alloc, .responses);
    const hist = [_]agent.Message{
        .{ .role = .system, .content = "be nice" },
        .{ .role = .user, .content = "hi" },
        .{ .role = .tool_call, .content = "{}", .tool_id = "x1", .tool_name = "t" },
        .{ .role = .tool_result, .content = "r", .tool_id = "x1", .tool_name = "t" },
    };
    const body = try buildRequestBody(alloc, &cfg, &hist, null, .{ .stream = true, .thinking = true });
    defer alloc.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "function_call_output") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "instructions") != null);
    var p = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    p.deinit();
}

test "clampFromRangeError parses provider caps" {
    try std.testing.expectEqual(@as(?u32, 65536), clampFromRangeError(
        \\{"error":{"type":"InvalidParameter","message":"<400> InternalError.Algo.InvalidParameter: Range of max_tokens should be [1, 65536]"}}
    ));
    try std.testing.expectEqual(@as(?u32, 131072), clampFromRangeError("Range of max_tokens should be [1,131072] blah"));
    try std.testing.expectEqual(@as(?u32, null), clampFromRangeError("some other error"));
}

test "sse: chat event accumulation (simulated)" {
    const alloc = std.testing.allocator;
    var acc = StreamAccum{
        .allocator = alloc,
        .style = .chat,
        .text = std.ArrayList(u8).initCapacity(alloc, 0) catch unreachable,
        .thinking = std.ArrayList(u8).initCapacity(alloc, 0) catch unreachable,
    };
    defer acc.text.deinit(alloc);
    defer acc.thinking.deinit(alloc);
    defer {
        var i: usize = 0;
        while (i < acc.tool_names) : (i += 1) { acc.tools[i].args.deinit(alloc); if (acc.tools[i].id.len > 0) alloc.free(acc.tools[i].id); if (acc.tools[i].name.len > 0) alloc.free(acc.tools[i].name); }
    }

    try handleSseEvent(&acc, null, "{\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}");
    try handleSseEvent(&acc, null, "{\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}");
    try handleSseEvent(&acc, null, "{\"choices\":[{\"delta\":{\"reasoning_content\":\"think \"}}]}");
    try handleSseEvent(&acc, null, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c9\",\"function\":{\"name\":\"exec\",\"arguments\":\"{\\\"c\\\"\"}}]}}]}");
    try handleSseEvent(&acc, null, "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":1}\"}}]}}]}");
    try std.testing.expectEqualStrings("Hello", acc.text.items);
    try std.testing.expectEqualStrings("think ", acc.thinking.items);
    try std.testing.expectEqual(@as(usize, 1), acc.tool_names);
    try std.testing.expectEqualStrings("exec", acc.tools[0].name);
    try std.testing.expectEqualStrings("{\"c\":1}", acc.tools[0].args.items);
}

test "sse: anthropic event accumulation" {
    const alloc = std.testing.allocator;
    var acc = StreamAccum{
        .allocator = alloc,
        .style = .anthropic,
        .text = std.ArrayList(u8).initCapacity(alloc, 0) catch unreachable,
        .thinking = std.ArrayList(u8).initCapacity(alloc, 0) catch unreachable,
    };
    defer acc.text.deinit(alloc);
    defer acc.thinking.deinit(alloc);
    defer {
        var i: usize = 0;
        while (i < acc.tool_names) : (i += 1) { acc.tools[i].args.deinit(alloc); if (acc.tools[i].id.len > 0) alloc.free(acc.tools[i].id); if (acc.tools[i].name.len > 0) alloc.free(acc.tools[i].name); }
    }

    try handleSseEvent(&acc, null, "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu9\",\"name\":\"file_read\"}}");
    try handleSseEvent(&acc, null, "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\"\"}}");
    try handleSseEvent(&acc, null, "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\":\\\"f\\\"}\"}}");
    try handleSseEvent(&acc, null, "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}");
    try std.testing.expectEqualStrings("hi", acc.text.items);
    try std.testing.expectEqualStrings("tu9", acc.tools[0].id);
    try std.testing.expectEqualStrings("{\"path\":\"f\"}", acc.tools[0].args.items);
}

test "sse: responses event accumulation" {
    const alloc = std.testing.allocator;
    var acc = StreamAccum{
        .allocator = alloc,
        .style = .responses,
        .text = std.ArrayList(u8).initCapacity(alloc, 0) catch unreachable,
        .thinking = std.ArrayList(u8).initCapacity(alloc, 0) catch unreachable,
    };
    defer acc.text.deinit(alloc);
    defer acc.thinking.deinit(alloc);
    defer {
        var i: usize = 0;
        while (i < acc.tool_names) : (i += 1) { acc.tools[i].args.deinit(alloc); if (acc.tools[i].id.len > 0) alloc.free(acc.tools[i].id); if (acc.tools[i].name.len > 0) alloc.free(acc.tools[i].name); }
    }

    try handleSseEvent(&acc, null, "{\"type\":\"response.output_text.delta\",\"delta\":\"par\"}");
    try handleSseEvent(&acc, null, "{\"type\":\"response.output_text.delta\",\"delta\":\"tial\"}");
    try handleSseEvent(&acc, null, "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"call_id\":\"fc1\",\"name\":\"t\"}}");
    try handleSseEvent(&acc, null, "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":0,\"delta\":\"{}\"}");
    try handleSseEvent(&acc, null, "{\"type\":\"response.completed\",\"response\":{\"usage\":{\"input_tokens\":2,\"output_tokens\":3}}}");
    try std.testing.expectEqualStrings("partial", acc.text.items);
    try std.testing.expectEqual(@as(u64, 2), acc.usage_in);
    try std.testing.expectEqual(@as(usize, 1), acc.tool_names);
    try std.testing.expectEqualStrings("{}", acc.tools[0].args.items);
}
