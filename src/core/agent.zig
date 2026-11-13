const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const transport = @import("../transport/transport.zig");
const tools = @import("../tools/registry.zig");

/// A single image attachment (base64 payload kept in memory for the API;
/// sessions persist only the originating path to stay small).
pub const Image = struct {
    mime: []const u8, // "image/png" | "image/jpeg" | ...
    data_b64: []const u8,
    path: ?[]const u8 = null,
};

/// A single message in conversation history
pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_id: ?[]const u8 = null, // Used for tool_call and tool_result
    tool_name: ?[]const u8 = null, // Name of the tool being called/reported
    images: []const Image = &[_]Image{},

    pub const Role = enum { system, user, assistant, tool_call, tool_result };
};

/// Function call request from the model
pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8, // JSON string
};

/// Result of processing a model response
pub const AgentResponse = struct {
    text: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    done: bool = true,
    usage_in: u64 = 0, // provider-reported token usage (0 = not provided)
    usage_out: u64 = 0,
    text_streamed: bool = false, // true = UI already printed the text live
    interrupted: bool = false, // true = user stopped generation mid-stream
};

pub const Sink = transport.Sink;

// ─────────────────────────────────────────────
// Fork v3.6: runtime OS detection. The prompts used to hardcode "Windows
// XP", which made the model claim to be on XP when running on Win7 etc.
// The truth is now detected at startup and injected into the system
// message, so it works no matter what config.json says.
// ─────────────────────────────────────────────
const OSVERSIONINFOW = extern struct {
    dwOSVersionInfoSize: u32,
    dwMajorVersion: u32,
    dwMinorVersion: u32,
    dwBuildNumber: u32,
    dwPlatformId: u32,
    szCSDVersion: [128]u16,
};
extern "kernel32" fn GetVersionExW(lpsi: *OSVERSIONINFOW) callconv(.winapi) i32;
extern "kernel32" fn GetComputerNameW(lpBuffer: [*]u16, lpnLength: *u32) callconv(.winapi) i32;
// ntdll RtlGetVersion reports the TRUE OS version (GetVersionExW lies 6.2
// on Win10+ for unmanifested apps). Present since XP SP2, stable forever.
extern "ntdll" fn RtlGetVersion(lpsi: *OSVERSIONINFOW) callconv(.winapi) i32;

/// Short human label, e.g. "Windows 7 SP1 (32-bit)". Static storage, valid
/// for program lifetime.
fn envW(name: []const u8) bool {
    if (builtin.os.tag != .windows) return std.process.hasEnvVarConstant(name);
    var wb: [64]u16 = undefined;
    var i: usize = 0;
    while (i < name.len and i < 63) : (i += 1) wb[i] = name[i];
    wb[i] = 0;
    return std.process.getenvW(wb[0..i :0].ptr) != null;
}

fn envWValue(name: []const u8, out: []u8) []const u8 {
    if (builtin.os.tag != .windows) return "";
    var wb: [64]u16 = undefined;
    var i: usize = 0;
    while (i < name.len and i < 63) : (i += 1) wb[i] = name[i];
    wb[i] = 0;
    const v = std.process.getenvW(wb[0..i :0].ptr) orelse return "";
    var n: usize = 0;
    while (v[n] != 0 and n < out.len) : (n += 1) out[n] = @intCast(v[n] & 0x7F);
    return out[0..n];
}

/// True when running on a 64-bit Windows (as either bitness of process).
fn is64BitOs() bool {
    var ab: [32]u8 = undefined;
    if (envW("PROCESSOR_ARCHITEW6432")) return true; // 32-bit proc on 64-bit OS
    const arch = envWValue("PROCESSOR_ARCHITECTURE", &ab);
    return std.mem.eql(u8, arch, "AMD64") or std.mem.eql(u8, arch, "ARM64") or std.mem.eql(u8, arch, "IA64");
}

pub fn osSummary() []const u8 {
    const Holder = struct { var storage: [96]u8 = undefined; };
    if (builtin.os.tag != .windows) {
        return std.fmt.bufPrint(&Holder.storage, "{s}", .{@tagName(builtin.os.tag)}) catch "unknown";
    }
    var vi = OSVERSIONINFOW{
        .dwOSVersionInfoSize = @sizeOf(OSVERSIONINFOW),
        .dwMajorVersion = 0,
        .dwMinorVersion = 0,
        .dwBuildNumber = 0,
        .dwPlatformId = 0,
        .szCSDVersion = [_]u16{0} ** 128,
    };
    if (RtlGetVersion(&vi) != 0) {
        vi = OSVERSIONINFOW{
            .dwOSVersionInfoSize = @sizeOf(OSVERSIONINFOW),
            .dwMajorVersion = 0,
            .dwMinorVersion = 0,
            .dwBuildNumber = 0,
            .dwPlatformId = 0,
            .szCSDVersion = [_]u16{0} ** 128,
        };
        if (GetVersionExW(&vi) == 0) return "Windows";
    }

    const base: []const u8 = switch (vi.dwMajorVersion * 100 + vi.dwMinorVersion) {
        500 => "Windows 2000",
        501 => "Windows XP",
        502 => "Windows Server 2003",
        600 => "Windows Vista",
        601 => "Windows 7",
        602 => "Windows 8",
        603 => "Windows 8.1",
        else => if (vi.dwMajorVersion >= 10) "Windows 10+" else "Windows",
    };
    // service pack from szCSDVersion ("Service Pack 3" / "SP3")
    var sp_buf: [16]u8 = undefined;
    var sp_txt: []const u8 = "";
    if (vi.szCSDVersion[0] != 0) {
        var k: usize = 0;
        var num: u8 = 0;
        var seen_digit = false;
        while (k < vi.szCSDVersion.len and vi.szCSDVersion[k] != 0) : (k += 1) {
            const c = vi.szCSDVersion[k];
            if (c >= '0' and c <= '9') {
                num = num * 10 + @as(u8, @intCast(c - '0'));
                seen_digit = true;
            }
        }
        if (seen_digit) {
            sp_txt = std.fmt.bufPrint(&sp_buf, " SP{d}", .{num}) catch "";
        }
    }
    // 32-bit OS vs 64-bit (works whether THIS process is 32 or 64-bit)
    const wow64 = is64BitOs();
    return std.fmt.bufPrint(&Holder.storage, "{s}{s} ({s})", .{
        base,
        sp_txt,
        if (wow64) "64-bit Windows" else "32-bit",
    }) catch base;
}

/// Machine name for the environment block ("" if unavailable). Static.
fn computerName(allocator: std.mem.Allocator) []const u8 {
    _ = allocator;
    const Holder = struct { var storage: [64]u8 = undefined; };
    if (builtin.os.tag != .windows) return "";
    var wbuf: [64]u16 = undefined;
    var len: u32 = wbuf.len;
    if (GetComputerNameW(&wbuf, &len) == 0 or len == 0) return "";
    const name = wbuf[0..len];
    var n: usize = 0;
    for (name) |u| {
        if (n >= Holder.storage.len - 1) break;
        if (u < 0x80) {
            Holder.storage[n] = @intCast(u);
            n += 1;
        }
    }
    return Holder.storage[0..n];
}

/// The block appended to the system prompt. Static storage; lifetime = process.
fn environmentBlock(allocator: std.mem.Allocator) []const u8 {
    const Holder = struct { var storage: [512]u8 = undefined; };
    const os = osSummary();
    const host = computerName(allocator);
    const bits_hint: []const u8 = if (std.mem.indexOf(u8, os, "XP") != null or std.mem.indexOf(u8, os, "2000") != null)
        "cmd.exe only, NO PowerShell, NO wmic guarantees; fsutil works without admin"
    else
        "cmd.exe available; PowerShell usually available; fsutil/disk queries may need admin";
    return std.fmt.bufPrint(&Holder.storage,
        "\n\nRUNTIME ENVIRONMENT (auto-detected at startup - this overrides any assumption):\n" ++
            "- OS: {s}\n- Host: {s}\n- Shell notes: {s}\n" ++
            "- Encoding: console codepage is handled automatically; reply in the user's language.",
        .{ os, if (host.len > 0) host else "unknown", bits_hint },
    ) catch "\n\nRUNTIME ENVIRONMENT: auto-detection unavailable.";
}

// Fork v2: interaction modes (plan = read-only, build = full access)
pub const AgentModeOp = enum { plan, build };

const plan_overlay =
    \\[mode:plan] READ-ONLY reconnaissance mode. Use diagnostic/read tools to
    \\investigate, then give a clear step-by-step plan. Mutating tools (exec,
    \\file_write) are unavailable in this mode; if a step needs them, list it
    \\as a plan step and remind the user they can /build to execute.
;
const build_overlay =
    \\[mode:build] Full access mode. You may execute commands and write files
    \\to carry out what the user asks, with the care guidelines above.
;

const summary_system_prompt =
    \\You compress older portions of a chat log into terse notes for the same
    \\assistant to continue later. Reply in the same language as the log.
    \\Preserve: decisions made, facts learned about the machine, file paths,
    \\numbers/metrics, unfinished tasks, and user preferences. Output plain
    \\bullet lines only, no preamble.
;

pub const SessionInfo = struct {
    name: []const u8, // display name (file stem)
    path: []const u8, // full relative path
    model: []const u8, // model recorded in the file
    updated: []const u8, // timestamp recorded
    messages: usize, // message count
    corrupt: bool = false, // file exists but cannot be parsed (old bug etc.)
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    cfg: *config.Config,
    history: std.ArrayList(Message),
    tool_registry: tools.ToolRegistry,
    running: bool = false,

    // Fork v2 state
    mode_op: AgentModeOp = .build,
    session_name: ?[]const u8 = null,
    session_dir: []const u8 = "sessions",
    last_usage_in: u64 = 0,
    last_usage_out: u64 = 0,
    // Fork v3.6: did the last returned text reach the screen via streaming?
    last_text_streamed: bool = false,
    last_interrupted: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: *config.Config) !Agent {
        var self = Agent{
            .allocator = allocator,
            .cfg = cfg,
            .history = std.ArrayList(Message).initCapacity(allocator, 0) catch unreachable,
            .tool_registry = tools.ToolRegistry.init(allocator, cfg),
        };

        // Register built-in tools
        try self.tool_registry.registerBuiltins();

        try self.resetHistory();
        return self;
    }

    /// Rebuild history = [system prompt + runtime env block, mode overlay].
    fn fullSystemPrompt(self: *Agent) ![]const u8 {
        return std.mem.concat(self.allocator, u8, &.{ self.cfg.system_prompt, environmentBlock(self.allocator) });
    }

    pub fn resetHistory(self: *Agent) !void {
        for (self.history.items) |msg| self.freeMessage(msg);
        self.history.clearRetainingCapacity();

        const owned_system_prompt = try self.fullSystemPrompt();
        try self.history.append(self.allocator, .{
            .role = .system,
            .content = owned_system_prompt,
        });
        try self.history.append(self.allocator, .{
            .role = .system,
            .content = try self.allocator.dupe(u8, overlayText(self.mode_op)),
        });
    }

    fn overlayText(op: AgentModeOp) []const u8 {
        return switch (op) {
            .plan => plan_overlay,
            .build => build_overlay,
        };
    }

    fn freeMessage(self: *Agent, msg: Message) void {
        self.allocator.free(msg.content);
        if (msg.tool_id) |id| self.allocator.free(id);
        if (msg.tool_name) |name| self.allocator.free(name);
        for (msg.images) |img| {
            self.allocator.free(img.mime);
            self.allocator.free(img.data_b64);
            if (img.path) |p| self.allocator.free(p);
        }
        if (msg.images.len > 0) self.allocator.free(msg.images);
    }

    pub fn deinit(self: *Agent) void {
        for (self.history.items) |msg| {
            self.freeMessage(msg);
        }
        self.history.deinit(self.allocator);
        self.tool_registry.deinit();
        if (self.session_name) |n| self.allocator.free(n);
    }

    // ─────────────────────────────────────────
    // Fork v2: plan/build switching
    // ─────────────────────────────────────────
    pub fn setAgentMode(self: *Agent, op: AgentModeOp) !void {
        if (self.mode_op == op) return;
        self.mode_op = op;
        // Replace overlay text in history slot 1 (always exists post-init)
        if (self.history.items.len > 1) {
            const ov = &self.history.items[1];
            if (ov.role == .system) {
                self.allocator.free(ov.content);
                ov.content = try self.allocator.dupe(u8, overlayText(op));
            }
        }
        // Any pending cached tool defs must be rebuilt for the new gating
        self.tool_registry._cache_dirty = true;
    }

    fn readOnly(self: *Agent) bool {
        return self.mode_op == .plan;
    }

    // ─────────────────────────────────────────
    // Main message pipeline
    // ─────────────────────────────────────────
    /// Process a single user message and return the agent's response.
    /// Handles tool call loops internally; reports progress through sink.
    pub fn processMessage(self: *Agent, user_input: []const u8, images: []const Image, sink: ?*const Sink) ![]const u8 {
        // Add user message to history (own the string)
        const owned_user_input = try self.allocator.dupe(u8, user_input);
        var owned_images: []const Image = &[_]Image{};
        if (images.len > 0) {
            const copy = try self.allocator.alloc(Image, images.len);
            for (images, 0..) |img, i| {
                copy[i] = .{
                    .mime = try self.allocator.dupe(u8, img.mime),
                    .data_b64 = try self.allocator.dupe(u8, img.data_b64),
                    .path = if (img.path) |p| try self.allocator.dupe(u8, p) else null,
                };
            }
            owned_images = copy;
        }
        try self.history.append(self.allocator, .{
            .role = .user,
            .content = owned_user_input,
            .images = owned_images,
        });

        // Agent loop: send to model, handle tool calls, repeat
        var iterations: u32 = 0;
        const max_iterations: u32 = self.cfg.max_tool_rounds; // Fork v3.6: was 10 — far too small for real engineering tasks

        while (iterations < max_iterations) : (iterations += 1) {
            // Fork v3.6: ESC / first Ctrl+C during the previous round?
            if (Sink.stopRequested(sink)) {
                self.last_text_streamed = true; // partial already on screen
                self.last_interrupted = true;
                return try self.allocator.dupe(u8, "");
            }

            // Fork v2: keep the context inside the window before calling
            try self.maybeCompact(sink);

            // Fork v3.6: two rounds before the cap, ask the model to wrap up
            var wrap_hint_idx: ?usize = null;
            if (iterations + 2 == max_iterations) {
                const hint = try self.allocator.dupe(u8, "[system note] Tool-round budget almost exhausted. Finish NOW: summarize what you did and list remaining steps instead of starting new tool calls.");
                try self.history.append(self.allocator, .{ .role = .system, .content = hint });
                wrap_hint_idx = self.history.items.len - 1;
            }

            Sink.stage(sink, switch (self.cfg.transport_api_style) {
                .chat => if (self.cfg.transport_api_stream) "streaming (chat)..." else "requesting (chat)...",
                .responses => if (self.cfg.transport_api_stream) "streaming (responses)..." else "requesting (responses)...",
                .anthropic => if (self.cfg.transport_api_stream) "streaming (anthropic)..." else "requesting (anthropic)...",
            });

            // Send conversation to model via transport
            const response = try self.callModel(sink);

            // Fork v3.6: the wrap-up note is transient — remove it now that the model answered
            if (wrap_hint_idx) |wi| {
                if (wi >= 2 and wi < self.history.items.len) {
                    self.freeMessage(self.history.items[wi]);
                    _ = self.history.orderedRemove(wi);
                }
            }

            // If model wants to call tools
            if (response.tool_calls) |tc| {
                // Surface any accompanying assistant text into history
                if (response.text) |txt| {
                    if (txt.len > 0) {
                        try self.history.append(self.allocator, .{ .role = .assistant, .content = txt });
                    } else {
                        self.allocator.free(txt);
                    }
                }
                var emitted: usize = 0;
                for (tc) |call| {
                    // Save assistant message with tool call to history (OpenAI style)
                    const owned_args = try self.allocator.dupe(u8, call.arguments);
                    const owned_id = try self.allocator.dupe(u8, call.id);
                    const owned_name = try self.allocator.dupe(u8, call.name);
                    try self.history.append(self.allocator, .{
                        .role = .tool_call,
                        .content = owned_args,
                        .tool_id = owned_id,
                        .tool_name = owned_name,
                    });

                    Sink.toolCall(sink, call.name, call.arguments);

                    // Execute tool
                    const result = self.executeTool(call) catch |err| blk: {
                        const msg = std.fmt.allocPrint(self.allocator, "Tool failed: {s}", .{@errorName(err)}) catch "Tool failed";
                        break :blk msg;
                    };
                    defer self.allocator.free(result);

                    Sink.toolDone(sink, call.name, true, result);

                    // Add result to history
                    const owned_result = try self.allocator.dupe(u8, result);
                    const owned_id_result = try self.allocator.dupe(u8, call.id);
                    const owned_name_result = try self.allocator.dupe(u8, call.name);
                    try self.history.append(self.allocator, .{
                        .role = .tool_result,
                        .content = owned_result,
                        .tool_id = owned_id_result,
                        .tool_name = owned_name_result,
                    });
                    emitted += 1;
                }

                // Free the tool calls received from the model
                for (tc) |call| {
                    self.allocator.free(call.id);
                    self.allocator.free(call.name);
                    self.allocator.free(call.arguments);
                }
                self.allocator.free(tc);

                // Continue loop — model needs to see tool results
                continue;
            }

            // No tool calls — we have a final text response
            if (response.text) |raw_text| {
                // Fork v3.6: strip leaked think-tag fragments the provider sometimes emits
                var text = stripThinkTags(self.allocator, raw_text) catch raw_text;
                if (text.ptr != raw_text.ptr) self.allocator.free(raw_text);
                // Fork v3.6: mark interrupted generations for the model
                if (response.interrupted) {
                    const marked = std.mem.concat(self.allocator, u8, &.{ text, "\n[user interrupted]" }) catch text;
                    if (marked.ptr != text.ptr) self.allocator.free(text);
                    text = marked;
                }
                // history takes ownership of the response text
                try self.history.append(self.allocator, .{
                    .role = .assistant,
                    .content = text,
                });
                self.last_usage_in = response.usage_in;
                self.last_usage_out = response.usage_out;
                self.last_text_streamed = response.text_streamed;
                self.last_interrupted = response.interrupted;
                // FIX 6 + Fork v2: sliding window is the last-resort bound;
                // compaction already ran above if it was configured.
                self.trimHistory();
                self.saveSession(null) catch {}; // auto-save, best effort
                return text;
            }

            break;
        }

        // Fork v3.6: cap reached — the UI MUST print this (last_text_streamed
        // = false) instead of silently ending, and the session is saved so
        // "continue" picks up exactly where we stopped.
        self.last_text_streamed = false;
        self.last_interrupted = false;
        const bail = try std.fmt.allocPrint(
            self.allocator,
            "[!] Tool-round limit reached ({d} rounds). Send \"continue\" to keep going.",
            .{max_iterations},
        );
        try self.history.append(self.allocator, .{
            .role = .assistant,
            .content = try self.allocator.dupe(u8, bail),
        });
        self.saveSession(null) catch {};
        return bail;
    }

    /// Fork v3.6: remove leaked think-tag fragments (observed from
    /// qwen3.8-flash via dashscope when thinking mode ends oddly).
    /// Tags are built from bytes so this source stays ASCII-safe.
    fn stripThinkTags(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
        const open_tag: []const u8 = "<" ++ "think" ++ ">";
        const close_tag: []const u8 = "<" ++ "/" ++ "think" ++ ">";
        var t = std.mem.trim(u8, s, " \r\n\t");
        if (t.len > 0 and (std.mem.eql(u8, t, open_tag) or std.mem.eql(u8, t, close_tag))) {
            return try allocator.dupe(u8, "");
        }
        var start: usize = 0;
        var end: usize = t.len;
        while (start + open_tag.len <= end and std.mem.startsWith(u8, t[start..end], open_tag)) {
            start += open_tag.len;
        }
        while (end > start and std.mem.endsWith(u8, t[start..end], close_tag)) {
            end -= close_tag.len;
        }
        if (start == 0 and end == t.len) return try allocator.dupe(u8, s);
        return try allocator.dupe(u8, std.mem.trim(u8, t[start..end], " \r\n\t"));
    }

    // FIX 6: Sliding window — trim history to max_history_messages, keeping
    // system prompt + mode overlay (indices 0 and 1).
    fn trimHistory(self: *Agent) void {
        const keep_head: usize = 2;
        const max = self.cfg.max_history_messages;
        if (max < keep_head + 2) return;
        if (self.history.items.len <= max) return;

        // Drop oldest messages after the head pair, but never split a
        // tool_call from its tool_result: also drop a trailing result.
        var to_remove: usize = self.history.items.len - max;
        while (keep_head + to_remove < self.history.items.len and
            self.history.items[keep_head + to_remove].role == .tool_result) : (to_remove += 1)
        {}

        // Free memory for removed messages
        for (self.history.items[keep_head .. keep_head + to_remove]) |msg| {
            self.freeMessage(msg);
        }

        // Shift remaining messages down
        const remaining = self.history.items[keep_head + to_remove ..];
        std.mem.copyForwards(Message, self.history.items[keep_head..], remaining);
        self.history.items.len = self.history.items.len - to_remove;
    }

    // ─────────────────────────────────────────
    // Fork v2: token estimation + compaction
    // ─────────────────────────────────────────
    pub fn estimateTokens(self: *const Agent) usize {
        var chars: usize = 0;
        var imgs: usize = 0;
        for (self.history.items) |msg| {
            chars += msg.content.len;
            if (msg.tool_name) |n| chars += n.len;
            imgs += msg.images.len;
        }
        return chars / 2 + imgs * 1200; // conservative CJK-heavy heuristic
    }

    pub fn contextPct(self: *const Agent) usize {
        const cw = self.cfg.transport_api_context_window;
        if (cw == 0) return 0;
        return self.estimateTokens() * 100 / @as(usize, cw);
    }

    fn maybeCompact(self: *Agent, sink: ?*const Sink) !void {
        if (!self.cfg.auto_compact) return;
        const cw = self.cfg.transport_api_context_window;
        if (cw == 0) return;
        const est = self.estimateTokens();
        if (est * 100 < @as(usize, cw) * self.cfg.compact_threshold_pct) return;
        try self.compactNow(sink, true);
    }

    /// Summarize the oldest chunk of the conversation into one note message.
    /// Keeps head pair + the freshest keep_recent messages.
    pub fn compactNow(self: *Agent, sink: ?*const Sink, auto: bool) !void {
        const keep_head: usize = 2;
        const total = self.history.items.len;
        if (total <= keep_head + @as(usize, self.cfg.keep_recent) + 2) {
            if (!auto) Sink.stage(sink, "nothing to compact yet");
            return;
        }

        var cut = total - @as(usize, self.cfg.keep_recent);

        // Boundary hygiene: the kept region must not start with a
        // tool_result (orphaned) or a tool_call whose result we cut away.
        while (cut > keep_head and
            (self.history.items[cut].role == .tool_result or self.history.items[cut].role == .tool_call)) : (cut += 1)
        {}
        // And the last summarized message must not be a tool_call waiting
        // for a result we're keeping.
        while (cut > keep_head and self.history.items[cut - 1].role == .tool_call) : (cut -= 1)
        {}

        if (cut <= keep_head + 1) {
            if (!auto) Sink.stage(sink, "nothing to compact yet");
            return;
        }

        Sink.stage(sink, if (auto) "context near limit — compacting..." else "compacting...");

        // Build transcript text of [keep_head .. cut)
        var transcript = std.ArrayList(u8).initCapacity(self.allocator, 16 * 1024) catch unreachable;
        defer transcript.deinit(self.allocator);
        for (self.history.items[keep_head..cut]) |msg| {
            const tag: []const u8 = switch (msg.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .tool_call => "tool_call",
                .tool_result => "tool_result",
            };
            transcript.writer(self.allocator).print("{s}: ", .{tag}) catch {};
            transcript.appendSlice(self.allocator, msg.content) catch {};
            if (msg.images.len > 0) transcript.appendSlice(self.allocator, " [image]") catch {};
            if (msg.tool_name) |n| transcript.writer(self.allocator).print(" (tool: {s})", .{n}) catch {};
            transcript.appendSlice(self.allocator, "\n") catch {};
        }
        // Bound transcript size: keep the tail (most recent matters most)
        const max_transcript: usize = 48 * 1024;
        const ttext = if (transcript.items.len > max_transcript)
            transcript.items[transcript.items.len - max_transcript ..]
        else
            transcript.items;

        // Ask the model (non-streaming, no tools) for the summary
        var tmp_hist = std.ArrayList(Message).initCapacity(self.allocator, 2) catch unreachable;
        defer tmp_hist.deinit(self.allocator);
        try tmp_hist.append(self.allocator, .{ .role = .system, .content = summary_system_prompt });
        try tmp_hist.append(self.allocator, .{ .role = .user, .content = ttext });

        const summary = transport.simpleCompletion(self.allocator, self.cfg, tmp_hist.items) catch |err| {
            Sink.stage(sink, switch (err) {
                error.OutOfMemory => "compact failed: out of memory",
                else => "compact failed: provider error (will trim instead)",
            });
            return; // fall back to plain sliding window on later turns
        };
        defer self.allocator.free(summary);

        // Replace [keep_head .. cut) with a single user note
        const note = try std.fmt.allocPrint(
            self.allocator,
            "[Summary of earlier conversation — {d} messages compressed]\n{s}",
            .{ cut - keep_head, summary },
        );
        for (self.history.items[keep_head..cut]) |msg| self.freeMessage(msg);
        const tail = std.ArrayList(Message).fromOwnedSlice(self.history.items[cut..]);
        var newlist = std.ArrayList(Message).initCapacity(self.allocator, keep_head + 1 + (total - cut)) catch unreachable;
        for (self.history.items[0..keep_head]) |m| try newlist.append(self.allocator, m);
        try newlist.append(self.allocator, .{ .role = .user, .content = note });
        for (tail.items) |m| try newlist.append(self.allocator, m);
        var oldlist = self.history;
        self.history = newlist;
        oldlist.deinit(self.allocator); // backing array only; items were moved

        const after = self.estimateTokens();
        var buf: [96]u8 = undefined;
        Sink.stage(sink, std.fmt.bufPrint(&buf, "compacted. context now ~{d} tokens", .{after}) catch "compacted");
    }

    // ─────────────────────────────────────────
    // Fork v2: session persistence
    // ─────────────────────────────────────────
    fn ensureSessionName(self: *Agent) ![]const u8 {
        if (self.session_name) |n| return n;
        var ts_buf: [32]u8 = undefined;
        const ts = std.fmt.bufPrint(&ts_buf, "auto-{d}", .{std.time.timestamp()}) catch "auto-session";
        self.session_name = try self.allocator.dupe(u8, ts);
        return self.session_name.?;
    }

    fn sessionPath(self: *Agent, buf: []u8, name: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}.json", .{ self.session_dir, name }) catch buf[0..0];
    }

    pub fn saveSession(self: *Agent, rename: ?[]const u8) !void {
        const src = if (rename) |rn| rn else try self.ensureSessionName();

        // Fork v3.5 fix: duplicate FIRST, then swap ownership, then use the
        // OWNED copy everywhere below. (The old code built the path from
        // `name`, which on the auto-save path aliased the just-freed
        // session_name buffer -> use-after-free, garbage filenames, and
        // silently missing auto-saves.)
        const owned_name = try self.allocator.dupe(u8, src);
        if (self.session_name) |old| self.allocator.free(old);
        self.session_name = owned_name;

        // Directory may not exist yet
        std.fs.cwd().makePath(self.session_dir) catch {};

        var pbuf: [512]u8 = undefined;
        const path = self.sessionPath(&pbuf, owned_name);
        if (path.len == 0) return error.NameTooLong;

        var out = std.ArrayList(u8).initCapacity(self.allocator, 8 * 1024) catch unreachable;
        errdefer out.deinit(self.allocator);
        const w = out.writer(self.allocator);

        try w.writeAll("{\"name\":");
        try transport_writeJsonString(w, owned_name);
        try w.writeAll(",\"model\":");
        try transport_writeJsonString(w, self.cfg.transport_api_model);
        try w.print(",\"ts\":{d},\"messages\":[", .{std.time.timestamp()});

        var wrote_any = false;
        for (self.history.items, 0..) |msg, i| {
            // The overlay (index 1) is regenerated on load; skip it.
            if (i == 1) continue;
            if (wrote_any) try w.writeByte(',');
            wrote_any = true;
            try w.writeByte('{');
            try w.writeAll("\"role\":");
            try transport_writeJsonString(w, roleName(msg.role));
            try w.writeAll(",\"content\":");
            try transport_writeJsonString(w, msg.content);
            if (msg.tool_id) |id| {
                try w.writeAll(",\"tool_id\":");
                try transport_writeJsonString(w, id);
            }
            if (msg.tool_name) |n2| {
                try w.writeAll(",\"tool_name\":");
                try transport_writeJsonString(w, n2);
            }
            if (msg.images.len > 0) {
                try w.writeAll(",\"images\":[");
                for (msg.images, 0..) |img, j| {
                    if (j > 0) try w.writeByte(',');
                    try w.writeAll("{\"mime\":");
                    try transport_writeJsonString(w, img.mime);
                    if (img.path) |p| {
                        try w.writeAll(",\"path\":");
                        try transport_writeJsonString(w, p);
                    }
                    try w.writeAll("}");
                }
                try w.writeAll("]");
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");

        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(out.items);
        out.deinit(self.allocator);
    }

    pub fn loadSession(self: *Agent, path: []const u8) !void {
        const content = try std.fs.cwd().readFileAlloc(self.allocator, path, 32 * 1024 * 1024);
        defer self.allocator.free(content);

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.BadSession;

        const root = parsed.value.object;
        const msgs = root.get("messages") orelse return error.BadSession;
        if (msgs != .array) return error.BadSession;

        // Clear current history (keep system prompt + overlay logic)
        for (self.history.items) |m| self.freeMessage(m);
        self.history.clearRetainingCapacity();

        const sys = try self.fullSystemPrompt();
        try self.history.append(self.allocator, .{ .role = .system, .content = sys });
        const ov = try self.allocator.dupe(u8, overlayText(self.mode_op));
        try self.history.append(self.allocator, .{ .role = .system, .content = ov });

        for (msgs.array.items) |item| {
            if (item != .object) continue;
            const robj = item.object;
            const role_str = if (robj.get("role")) |r| (if (r == .string) r.string else continue) else continue;
            const content_str = if (robj.get("content")) |c| (if (c == .string) c.string else "") else "";
            const role = roleFromString(role_str) orelse continue;

            var images: []const Image = &[_]Image{};
            if (robj.get("images")) |il| {
                if (il == .array and il.array.items.len > 0) {
                    var list = std.ArrayList(Image).initCapacity(self.allocator, il.array.items.len) catch unreachable;
                    for (il.array.items) |ient| {
                        if (ient != .object) continue;
                        const mime_v = ient.object.get("mime") orelse continue;
                        const path_v = ient.object.get("path");
                        if (path_v == null or path_v.? != .string) continue;
                        const p = path_v.?.string;
                        // Re-encode the file if it is still around
                        const raw = std.fs.cwd().readFileAlloc(self.allocator, p, 4 * 1024 * 1024) catch continue;
                        defer self.allocator.free(raw);
                        const b64 = std.base64.standard.Encoder.calcSize(raw.len);
                        const buf = try self.allocator.alloc(u8, b64);
                        _ = std.base64.standard.Encoder.encode(buf, raw);
                        try list.append(self.allocator, .{
                            .mime = try self.allocator.dupe(u8, mime_v.string),
                            .data_b64 = buf,
                            .path = try self.allocator.dupe(u8, p),
                        });
                    }
                    if (list.items.len > 0) images = list.items;
                }
            }

            try self.history.append(self.allocator, .{
                .role = role,
                .content = self.ensureUtf8(self.allocator.dupe(u8, content_str) catch continue),
                .tool_id = if (robj.get("tool_id")) |v| (if (v == .string) try self.allocator.dupe(u8, v.string) else null) else null,
                .tool_name = if (robj.get("tool_name")) |v| (if (v == .string) try self.allocator.dupe(u8, v.string) else null) else null,
                .images = images,
            });
        }

        // Remember the session name from the file stem
        const stem = std.fs.path.stem(path);
        if (self.session_name) |old| self.allocator.free(old);
        self.session_name = try self.allocator.dupe(u8, stem);
    }

    pub fn listSessions(self: *Agent) ![]SessionInfo {
        var dir = std.fs.cwd().openDir(self.session_dir, .{ .iterate = true }) catch
            return &[_]SessionInfo{};
        defer dir.close();

        var out = std.ArrayList(SessionInfo).initCapacity(self.allocator, 0) catch unreachable;
        var it = dir.iterate();
        while (true) {
            const maybe_entry = it.next() catch break;
            const entry = maybe_entry orelse break;
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            var info = SessionInfo{
                .name = try self.allocator.dupe(u8, std.fs.path.stem(entry.name)),
                .path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.session_dir, entry.name }),
                .model = "",
                .updated = "",
                .messages = 0,
            };
            if (std.fs.cwd().readFileAlloc(self.allocator, info.path, 8 * 1024 * 1024)) |fcontent| {
                defer self.allocator.free(fcontent);
                var parsed_ok = false;
                if (std.json.parseFromSlice(std.json.Value, self.allocator, fcontent, .{})) |p| {
                    defer p.deinit();
                    parsed_ok = true;
                    if (p.value == .object) {
                        if (p.value.object.get("model")) |m| if (m == .string) {
                            info.model = try self.allocator.dupe(u8, m.string);
                        };
                        if (p.value.object.get("ts")) |t| if (t == .integer) {
                            var tb: [32]u8 = undefined;
                            info.updated = try self.allocator.dupe(u8, std.fmt.bufPrint(&tb, "{d}", .{t.integer}) catch "-");
                        };
                        if (p.value.object.get("messages")) |mm| if (mm == .array) {
                            info.messages = mm.array.items.len;
                        };
                    }
                } else |_| {}
                info.corrupt = !parsed_ok;
            } else |_| {
                info.corrupt = true;
            }
            try out.append(self.allocator, info);
        }
        return try out.toOwnedSlice(self.allocator);
    }

    pub fn freeSessions(self: *Agent, list: []const SessionInfo) void {
        // Element strings only: the caller may hold a const empty slice.
        for (list) |s| {
            self.allocator.free(s.name);
            self.allocator.free(s.path);
            if (s.model.len > 0) self.allocator.free(s.model);
            if (s.updated.len > 0) self.allocator.free(s.updated);
        }
    }

    fn roleName(r: Message.Role) []const u8 {
        return switch (r) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool_call => "tool_call",
            .tool_result => "tool_result",
        };
    }

    fn roleFromString(s: []const u8) ?Message.Role {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "tool_call")) return .tool_call;
        if (std.mem.eql(u8, s, "tool_result")) return .tool_result;
        return null;
    }

    // ─────────────────────────────────────────
    fn callModel(self: *Agent, sink: ?*const Sink) !AgentResponse {
        return switch (self.cfg.mode) {
            .api, .interactive => try transport.modelCall(
                self.allocator,
                self.cfg,
                self.history.items,
                self.tool_registry.getToolDefs(self.readOnly()),
                sink,
            ),
            .bridge => try transport.bridgeCall(self.allocator, self.cfg, self.history.items),
            .offline => try transport.fileQueueCall(self.allocator, self.cfg, self.history.items),
            .local => try transport.localCall(self.allocator, self.cfg, self.history.items),
        };
    }

    fn executeTool(self: *Agent, call: ToolCall) ![]const u8 {
        // Fork v2: plan mode hard-gate (defs already hidden, but a model
        // can still hallucinate the call — answer it in-band).
        if (self.readOnly() and self.tool_registry.isMutating(call.name)) {
            return try self.allocator.dupe(u8, "DENIED: mutating tools are disabled in plan mode. Describe the command in your plan instead; the user runs /build to let you execute.");
        }
        // Security check: require approval if configured
        if (self.cfg.security_require_approval) {
            const approved = try self.requestApproval(call);
            if (!approved) {
                return try self.allocator.dupe(u8, "Tool execution denied by user.");
            }
        }

        const raw = try self.tool_registry.execute(call.name, call.arguments);
        return self.ensureUtf8(raw);
    }

    /// Fork v3.3: last-line guarantee that any string destined for the API
    /// body is valid UTF-8. Strict providers reject whole requests otherwise.
    pub fn ensureUtf8(self: *Agent, text: []const u8) []const u8 {
        if (!@import("../utils/encoding.zig").needsUtf8Fixup(text)) return text;
        const fixed = @import("../utils/encoding.zig").toValidUtf8(self.allocator, text) catch return text;
        self.allocator.free(text);
        return fixed;
    }

    fn requestApproval(self: *Agent, call: ToolCall) !bool {
        _ = self;
        const stdout = std.fs.File.stdout();
        var msg_buf: [1024]u8 = undefined;

        try stdout.writeAll("\n[!] Tool call requested: ");
        try stdout.writeAll(call.name);
        try stdout.writeAll("\n");
        _ = try std.fmt.bufPrint(&msg_buf, "   Args: {s}\n", .{call.arguments});
        try stdout.writeAll(msg_buf[0..std.mem.indexOf(u8, &msg_buf, "\n").? + 1]);
        try stdout.writeAll("   Approve? [y/N] ");

        var buf: [16]u8 = undefined;
        const bytes_read = std.fs.File.stdin().read(&buf) catch return false;
        if (bytes_read == 0) return false;
        const line = buf[0..bytes_read];

        return line.len > 0 and (line[0] == 'y' or line[0] == 'Y');
    }

    /// Run in daemon mode (non-interactive, for monitor/bridge)
    pub fn run(self: *Agent) !void {
        self.running = true;
        const stdout = std.fs.File.stdout();
        var msg_buf: [512]u8 = undefined;

        const msg = try std.fmt.bufPrint(&msg_buf, "micro-agent [{s}] starting in {s} mode...\n", .{
            self.cfg.agent_name,
            @tagName(self.cfg.mode),
        });
        try stdout.writeAll(msg);

        switch (self.cfg.mode) {
            .offline => try self.runFileQueueLoop(),
            .bridge => try self.runBridgeLoop(),
            .api => try self.runApiDaemon(),
            else => {
                try stdout.writeAll("Daemon mode not supported for this mode.\n");
            },
        }
    }

    fn runFileQueueLoop(self: *Agent) !void {
        const stdout = std.fs.File.stdout();
        var msg_buf: [1024]u8 = undefined;

        _ = try std.fmt.bufPrint(&msg_buf, "Watching inbox: {s}\n", .{self.cfg.transport_file_inbox});
        try stdout.writeAll(msg_buf[0..std.mem.indexOf(u8, &msg_buf, "\n").? + 1]);
        _ = try std.fmt.bufPrint(&msg_buf, "Writing to outbox: {s}\n", .{self.cfg.transport_file_outbox});
        try stdout.writeAll(msg_buf[0..std.mem.indexOf(u8, &msg_buf, "\n").? + 1]);

        while (self.running) {
            // Check inbox directory for new .prompt files
            const inbox_dir = std.fs.cwd().openDir(self.cfg.transport_file_inbox, .{
                .iterate = true,
            }) catch {
                std.Thread.sleep(self.cfg.transport_file_poll_ms * std.time.ns_per_ms);
                continue;
            };
            _ = inbox_dir;

            // TODO: iterate files, process prompts, write responses
            std.Thread.sleep(self.cfg.transport_file_poll_ms * std.time.ns_per_ms);
        }
    }

    fn runBridgeLoop(self: *Agent) !void {
        _ = self;
        try std.fs.File.stdout().writeAll("Bridge mode: serial transport not yet implemented.\n");
    }

    fn runApiDaemon(self: *Agent) !void {
        _ = self;
        try std.fs.File.stdout().writeAll("API daemon mode: use --interactive for now.\n");
    }
};

// Reuse the transport string escaper for session files.
fn transport_writeJsonString(writer: anytype, s: []const u8) !void {
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

test "agent init" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cfg = config.Config.defaults(gpa.allocator());
    defer cfg.deinit();
    var ag = try Agent.init(gpa.allocator(), &cfg);
    defer ag.deinit();
    try std.testing.expect(ag.history.items.len == 2); // system + overlay
}

test "stripThinkTags" {
    const alloc = std.testing.allocator;
    const close: []const u8 = "<" ++ "/" ++ "think" ++ ">";

    const t1 = try Agent.stripThinkTags(alloc, close);
    defer alloc.free(t1);
    try std.testing.expectEqualStrings("", t1);

    const t2 = try Agent.stripThinkTags(alloc, "hello world");
    defer alloc.free(t2);
    try std.testing.expectEqualStrings("hello world", t2);

    const t3 = try Agent.stripThinkTags(alloc, "<" ++ "think" ++ "> inner text kept");
    defer alloc.free(t3);
    try std.testing.expectEqualStrings("inner text kept", t3);

    const t4 = try Agent.stripThinkTags(alloc, "real answer" ++ close);
    defer alloc.free(t4);
    try std.testing.expectEqualStrings("real answer", t4);
}

test "plan mode gating" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var cfg = config.Config.defaults(a);
    defer cfg.deinit();
    var ag = try Agent.init(a, &cfg);
    defer ag.deinit();

    try ag.setAgentMode(.plan);
    try std.testing.expect(ag.readOnly());
    // defs must exclude mutating tools in plan mode
    const defs = ag.tool_registry.getToolDefs(true).?;
    for (defs) |d| {
        try std.testing.expect(!std.mem.eql(u8, d.name, "exec"));
        try std.testing.expect(!std.mem.eql(u8, d.name, "file_write"));
    }
    // full defs still contain them (if enabled on this platform)
    try std.testing.expect(ag.tool_registry.isMutating("exec"));
    try ag.setAgentMode(.build);
    try std.testing.expect(!ag.readOnly());
    try std.testing.expect(std.mem.indexOf(u8, ag.history.items[1].content, "mode:build") != null);
}
