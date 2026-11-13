const std = @import("std");

// Fork v3.6: how much of the model's thinking the UI shows by default.
pub const ThinkingDisplay = enum {
    brief, // collapsed: one summary line, /expand reveals it
    full, // stream it live (v3.5 behavior)

    pub fn fromString(s: []const u8) ?ThinkingDisplay {
        if (std.ascii.eqlIgnoreCase(s, "brief") or std.ascii.eqlIgnoreCase(s, "collapse") or std.ascii.eqlIgnoreCase(s, "off")) return .brief;
        if (std.ascii.eqlIgnoreCase(s, "full") or std.ascii.eqlIgnoreCase(s, "show") or std.ascii.eqlIgnoreCase(s, "on")) return .full;
        return null;
    }
};

pub const AgentMode = enum {
    api,
    bridge,
    offline,
    interactive,
    local,
};

// Fork v2: wire protocol dialect for the upstream provider.
pub const ApiStyle = enum {
    chat, // OpenAI /v1/chat/completions (dashscope, ollama, ...)
    responses, // OpenAI /v1/responses
    anthropic, // Anthropic /v1/messages

    pub fn fromString(s: []const u8) ?ApiStyle {
        if (std.ascii.eqlIgnoreCase(s, "chat") or std.ascii.eqlIgnoreCase(s, "openai") or std.ascii.eqlIgnoreCase(s, "openai_chat")) return .chat;
        if (std.ascii.eqlIgnoreCase(s, "responses") or std.ascii.eqlIgnoreCase(s, "openai_responses")) return .responses;
        if (std.ascii.eqlIgnoreCase(s, "anthropic") or std.ascii.eqlIgnoreCase(s, "claude")) return .anthropic;
        return null;
    }
};

// Fork v2: reasoning/thinking intensity, mapped per ApiStyle in transport.
pub const ThinkingLevel = enum {
    off,
    low,
    medium,
    high,

    pub fn fromString(s: []const u8) ?ThinkingLevel {
        if (std.ascii.eqlIgnoreCase(s, "off") or std.ascii.eqlIgnoreCase(s, "none") or std.ascii.eqlIgnoreCase(s, "false")) return .off;
        if (std.ascii.eqlIgnoreCase(s, "on") or std.ascii.eqlIgnoreCase(s, "true")) return .medium;
        if (std.ascii.eqlIgnoreCase(s, "low") or std.ascii.eqlIgnoreCase(s, "minimal")) return .low;
        if (std.ascii.eqlIgnoreCase(s, "medium")) return .medium;
        if (std.ascii.eqlIgnoreCase(s, "high")) return .high;
        return null;
    }

    pub fn toString(self: ThinkingLevel) []const u8 {
        return switch (self) {
            .off => "off",
            .low => "low",
            .medium => "medium",
            .high => "high",
        };
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,

    // Agent
    agent_name: []const u8 = "micro-agent",
    mode: AgentMode = .interactive,
    system_prompt: []const u8 = 
        \\You are a specialized AI assistant for system administrators and technicians on legacy Windows machines.
        \\
        \\SYSTEM CONTEXT (the RUNTIME ENVIRONMENT block appended below is auto-detected and authoritative):
        \\- OS: legacy Windows (XP / Vista / 7 era, typically 32-bit) - see detected value
        \\- Shell: cmd.exe (PowerShell only on Vista+ - see detected value)
        \\- Hardware: possibly slow HDD and limited RAM - keep commands light
        \\- Encoding: Chinese consoles use GBK/CP936 - the program transcodes automatically
        \\
        \\YOUR CAPABILITIES:
        \\You have access to diagnostic and maintenance tools for Windows XP systems:
        \\- System diagnostics (systeminfo, memory, disk space)
        \\- Process management (list, analyze CPU/memory usage)
        \\- Network diagnostics (connections, configuration, ping)
        \\- Service management (list, query status)
        \\- File operations (read logs, list directories)
        \\
        \\BEHAVIOR GUIDELINES:
        \\1. Be proactive: Suggest relevant diagnostic actions
        \\2. Be precise: Use technical terminology correctly
        \\3. Be efficient: Minimize commands on slow hardware
        \\4. Be clear: Explain what you're doing and why
        \\5. Be helpful: Provide actionable recommendations
        \\
        \\DIAGNOSTIC WORKFLOW:
        \\1. Gather information using read-only tools
        \\2. Analyze data and identify issues
        \\3. Propose solutions with clear rationale
        \\4. Execute fixes (with user approval if needed)
        \\5. Verify resolution
        \\
        \\HARDWARE LIMITATIONS:
        \\- Avoid full disk scans (too slow on legacy hardware)
        \\- Limit output to essential information
        \\- Consider limited RAM (no memory-intensive operations)
        \\- Be patient with command execution times
        \\
        \\OUTPUT FORMAT:
        \\- Present information in clear, organized sections
        \\- Use bullet points for lists
        \\- Highlight critical issues
        \\- Provide specific recommendations
        \\- Include relevant metrics (MB, %, counts)
        \\
        \\EXAMPLE INTERACTIONS:
        \\
        \\User: "System is running slow"
        \\You: Let me check system resources and running processes.
        \\[Use: system_info, check_memory_usage, diagnose_high_cpu]
        \\Analysis: Found high memory usage (450/512 MB used). Process "app.exe" using 180 MB.
        \\Recommendation: Consider closing unnecessary applications or restarting the high-memory process.
        \\
        \\User: "Can't connect to network"
        \\You: I'll check network configuration and connectivity.
        \\[Use: network_config, network_status, ping_host]
        \\Analysis: Network adapter configured correctly. Gateway not responding.
        \\Recommendation: Check physical connection or restart network adapter.
        \\
        \\Remember: You're assisting professionals managing critical legacy systems. Be thorough, accurate, and helpful.
    ,

    // Transport: API
    transport_api_provider: []const u8 = "openai",
    transport_api_key: []const u8 = "",
    transport_api_model: []const u8 = "",
    transport_api_base_url: []const u8 = "http://localhost:11434",
    // Fork v3.6c: last /upstream choice, persisted in settings.txt so the
    // agent can re-apply it to the bridge on startup (a stale retrobridge
    // that survived the previous window close never re-reads upstream.txt).
    upstream: []const u8 = "",
    // Fork patch: optional generation limits (0 = omit from request)
    transport_api_max_tokens: u32 = 0,
    transport_api_context_window: u32 = 0,
    // Fork v2: protocol style / streaming / thinking intensity
    transport_api_style: ApiStyle = .chat,
    transport_api_stream: bool = true,
    transport_thinking: ThinkingLevel = .off,
    // Fork v2: automatic context compaction
    auto_compact: bool = true,
    compact_threshold_pct: u32 = 75,
    keep_recent: u32 = 10,
    // Fork v3.6: console look, thinking display, tool loop cap
    console_color: bool = false, // false = plain black/white (Win7-friendly default)
    thinking_display: ThinkingDisplay = .brief,
    max_tool_rounds: u32 = 30,

    // Transport: Serial
    transport_serial_port: []const u8 = "/dev/ttyUSB0",
    transport_serial_baud: u32 = 115200,

    // Transport: File queue
    transport_file_inbox: []const u8 = "/var/spool/micro-agent/inbox",
    transport_file_outbox: []const u8 = "/var/spool/micro-agent/outbox",
    transport_file_poll_ms: u32 = 5000,

    // Monitor
    monitor_enabled: bool = false,

    // Security
    security_require_approval: bool = false,
    security_sandbox: bool = true,
    security_max_exec_timeout_ms: u32 = 30000,
    
    // Debug
    debug_mode: bool = false,

    // Fork v3.6: debug_mode was never parsed from config.json (field existed
    // but stayed false). Parsed now in parseJson root section.

    // FIX 6: History sliding window — max messages to keep in conversation history
    max_history_messages: u32 = 100,

    // Tools
    tool_exec_enabled: bool = true,
    tool_file_read_enabled: bool = true,
    tool_file_write_enabled: bool = true,
    tool_list_dir_enabled: bool = true,
    tool_alert_enabled: bool = true,

    // Allowed commands for exec tool (whitelist)
    tool_exec_allowed_commands: ?[]const []const u8 = null,
    // Allowed paths for file operations
    tool_file_read_allowed_paths: ?[]const []const u8 = null,
    tool_file_write_allowed_paths: ?[]const []const u8 = null,

    // Allocated strings that we own (need to free)
    _owned_json: ?[]const u8 = null,
    // Strings duplicated from JSON parsing (must be freed individually)
    _owned_strings: std.ArrayList([]const u8) = undefined,
    _strings_initialized: bool = false,

    pub fn defaults(allocator: std.mem.Allocator) Config {
        return Config{
            .allocator = allocator,
            ._owned_strings = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            ._strings_initialized = true,
        };
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.log.err("Cannot open config file '{s}': {}", .{ path, err });
            return err;
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size > 1024 * 1024) { // 1 MB max config
            return error.ConfigTooLarge;
        }

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);

        var cfg = Config{
            .allocator = allocator,
            ._owned_json = content,
            ._owned_strings = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable,
            ._strings_initialized = true,
        };

        // Parse JSON config
        cfg.parseJson(content) catch |err| {
            std.log.err("Invalid config JSON: {}", .{err});
            return err;
        };

        return cfg;
    }

    /// Duplicate a string and track it for cleanup
    pub fn dupeAndOwn(self: *Config, s: []const u8) ![]const u8 {
        const owned = try self.allocator.dupe(u8, s);
        try self._owned_strings.append(self.allocator, owned);
        return owned;
    }

    fn parseJson(self: *Config, content: []const u8) !void {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        // Agent section
        if (root.object.get("agent")) |agent_val| {
            if (agent_val == .object) {
                if (agent_val.object.get("name")) |v| {
                    if (v == .string) self.agent_name = try self.dupeAndOwn(v.string);
                }
                if (agent_val.object.get("system_prompt")) |v| {
                    if (v == .string) self.system_prompt = try self.dupeAndOwn(v.string);
                }
                if (agent_val.object.get("mode")) |v| {
                    if (v == .string) {
                        self.mode = modeFromString(v.string);
                    }
                }
                // FIX 6: Parse max_history from agent section
                if (agent_val.object.get("max_history")) |v| {
                    if (v == .integer) {
                        const val_int: i64 = v.integer;
                        if (val_int > 0 and val_int <= 10000) {
                            self.max_history_messages = @intCast(@as(u64, @bitCast(val_int)));
                        }
                    }
                }
                // Fork v2: compaction knobs
                if (agent_val.object.get("auto_compact")) |v| {
                    if (v == .bool) self.auto_compact = v.bool;
                }
                if (agent_val.object.get("compact_threshold_pct")) |v| {
                    if (v == .integer and v.integer > 10 and v.integer <= 95) self.compact_threshold_pct = @intCast(@as(u64, @bitCast(v.integer)));
                }
                if (agent_val.object.get("keep_recent")) |v| {
                    if (v == .integer and v.integer >= 2 and v.integer <= 100) self.keep_recent = @intCast(@as(u64, @bitCast(v.integer)));
                }
                // Fork v3.6
                if (agent_val.object.get("max_tool_rounds")) |v| {
                    if (v == .integer and v.integer >= 2 and v.integer <= 100) self.max_tool_rounds = @intCast(@as(u64, @bitCast(v.integer)));
                }
                if (agent_val.object.get("thinking_display")) |v| {
                    if (v == .string) {
                        if (ThinkingDisplay.fromString(v.string)) |td| self.thinking_display = td;
                    }
                }
                if (agent_val.object.get("color")) |v| {
                    if (v == .bool) self.console_color = v.bool;
                }
            }
        }

        // Transport section
        if (root.object.get("transport")) |transport_val| {
            if (transport_val == .object) {
                // API config
                if (transport_val.object.get("api")) |api_val| {
                    if (api_val == .object) {
                        if (api_val.object.get("provider")) |v| {
                            if (v == .string) self.transport_api_provider = try self.dupeAndOwn(v.string);
                        }
                        if (api_val.object.get("api_key")) |v| {
                            if (v == .string) self.transport_api_key = try self.dupeAndOwn(v.string);
                        }
                        if (api_val.object.get("model")) |v| {
                            if (v == .string) self.transport_api_model = try self.dupeAndOwn(v.string);
                        }
                        if (api_val.object.get("base_url")) |v| {
                            if (v == .string) self.transport_api_base_url = try self.dupeAndOwn(v.string);
                        }
                        // Fork patch: max_tokens / context_window (integers, >0)
                        if (api_val.object.get("max_tokens")) |v| {
                            if (v == .integer and v.integer > 0) {
                                self.transport_api_max_tokens = @intCast(@as(u64, @bitCast(v.integer)));
                            }
                        }
                        if (api_val.object.get("context_window")) |v| {
                            if (v == .integer and v.integer > 0) {
                                self.transport_api_context_window = @intCast(@as(u64, @bitCast(v.integer)));
                            }
                        }
                        // Fork v2: style / stream / thinking
                        if (api_val.object.get("api_style")) |v| {
                            if (v == .string) {
                                if (ApiStyle.fromString(v.string)) |st| self.transport_api_style = st;
                            }
                        }
                        if (api_val.object.get("stream")) |v| {
                            if (v == .bool) self.transport_api_stream = v.bool;
                        }
                        if (api_val.object.get("thinking")) |v| {
                            if (v == .string) {
                                if (ThinkingLevel.fromString(v.string)) |tl| self.transport_thinking = tl;
                            } else if (v == .bool) {
                                self.transport_thinking = if (v.bool) .medium else .off;
                            }
                        }
                        // Legacy alias: enable_thinking=true -> medium
                        if (api_val.object.get("enable_thinking")) |v| {
                            if (v == .bool and v.bool and self.transport_thinking == .off) self.transport_thinking = .medium;
                        }
                    }
                }

                // Serial config
                if (transport_val.object.get("serial")) |serial_val| {
                    if (serial_val == .object) {
                        if (serial_val.object.get("port")) |v| {
                            if (v == .string) self.transport_serial_port = try self.dupeAndOwn(v.string);
                        }
                        if (serial_val.object.get("baud_rate")) |v| {
                            if (v == .integer) self.transport_serial_baud = @intCast(@as(u32, @truncate(@as(u64, @bitCast(v.integer)))));
                        }
                    }
                }

                // File queue config
                if (transport_val.object.get("file_queue")) |fq_val| {
                    if (fq_val == .object) {
                        if (fq_val.object.get("inbox")) |v| {
                            if (v == .string) self.transport_file_inbox = try self.dupeAndOwn(v.string);
                        }
                        if (fq_val.object.get("outbox")) |v| {
                            if (v == .string) self.transport_file_outbox = try self.dupeAndOwn(v.string);
                        }
                    }
                }
            }
        }

        // Security section
        if (root.object.get("security")) |sec_val| {
            if (sec_val == .object) {
                if (sec_val.object.get("require_approval")) |v| {
                    if (v == .bool) self.security_require_approval = v.bool;
                }
                if (sec_val.object.get("sandbox")) |v| {
                    if (v == .bool) self.security_sandbox = v.bool;
                }
                // FIX 3: Parse max_exec_timeout_ms from security section
                if (sec_val.object.get("max_exec_timeout_ms")) |v| {
                    if (v == .integer) {
                        const val_int: i64 = v.integer;
                        if (val_int > 0) {
                            self.security_max_exec_timeout_ms = @intCast(@as(u64, @bitCast(val_int)));
                        }
                    }
                }
            }
        }

        // Fork v3.6: debug_mode actually parsed (was silently ignored before)
        if (root.object.get("debug_mode")) |v| {
            if (v == .bool) self.debug_mode = v.bool;
        }
    }

    fn modeFromString(s: []const u8) AgentMode {
        if (std.mem.eql(u8, s, "api")) return .api;
        if (std.mem.eql(u8, s, "bridge")) return .bridge;
        if (std.mem.eql(u8, s, "offline")) return .offline;
        if (std.mem.eql(u8, s, "local")) return .local;
        return .interactive;
    }

    // ─────────────────────────────────────────────
    // Fork v2: runtime settings file (settings.txt)
    // Plain ASCII "key=value" lines, ';' or '#' comments. Written by the
    // slash commands (/model /api /think /context /maxtok /stream ...) so
    // choices survive restarts without touching retro.ini or agent.bat.
    // Unknown/broken lines are silently ignored — this file is always the
    // *last* override layer, config.json stays the factory default.
    // ─────────────────────────────────────────────
    pub fn loadSettingsFile(self: *Config, path: []const u8) void {
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 64 * 1024) catch return;
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (key.len == 0 or val.len == 0) continue;

            if (std.ascii.eqlIgnoreCase(key, "model")) {
                // ignore junk persisted by mistake (see /model guard)
                if (val.len >= 2 and val[0] != '\\' and val[0] != '/' and val[0] != '|') {
                    self.transport_api_model = self.dupeAndOwn(val) catch continue;
                }
            } else if (std.ascii.eqlIgnoreCase(key, "api_style")) {
                if (ApiStyle.fromString(val)) |st| self.transport_api_style = st;
            } else if (std.ascii.eqlIgnoreCase(key, "stream")) {
                if (std.ascii.eqlIgnoreCase(val, "true") or std.ascii.eqlIgnoreCase(val, "1")) self.transport_api_stream = true;
                if (std.ascii.eqlIgnoreCase(val, "false") or std.ascii.eqlIgnoreCase(val, "0")) self.transport_api_stream = false;
            } else if (std.ascii.eqlIgnoreCase(key, "thinking")) {
                if (ThinkingLevel.fromString(val)) |tl| self.transport_thinking = tl;
            } else if (std.ascii.eqlIgnoreCase(key, "context_window")) {
                if (std.fmt.parseInt(u32, val, 10)) |n| {
                    self.transport_api_context_window = n;
                } else |_| {}
            } else if (std.ascii.eqlIgnoreCase(key, "max_tokens")) {
                // API ceiling for qwen-class models is the context window
                // itself (dashscope model detail: max_tokens 131072); keep
                // generous headroom, only reject absurd values.
                if (std.fmt.parseInt(u32, val, 10)) |n| {
                    if (n <= 1048576) self.transport_api_max_tokens = n;
                } else |_| {}
            } else if (std.ascii.eqlIgnoreCase(key, "auto_compact")) {
                if (std.ascii.eqlIgnoreCase(val, "true") or std.ascii.eqlIgnoreCase(val, "1")) self.auto_compact = true;
                if (std.ascii.eqlIgnoreCase(val, "false") or std.ascii.eqlIgnoreCase(val, "0")) self.auto_compact = false;
            } else if (std.ascii.eqlIgnoreCase(key, "keep_recent")) {
                if (std.fmt.parseInt(u32, val, 10)) |n| {
                    if (n >= 2 and n <= 100) self.keep_recent = n;
                } else |_| {}
            } else if (std.ascii.eqlIgnoreCase(key, "max_tool_rounds")) {
                if (std.fmt.parseInt(u32, val, 10)) |n| {
                    if (n >= 2 and n <= 100) self.max_tool_rounds = n;
                } else |_| {}
            } else if (std.ascii.eqlIgnoreCase(key, "thinking_display")) {
                if (ThinkingDisplay.fromString(val)) |td| self.thinking_display = td;
            } else if (std.ascii.eqlIgnoreCase(key, "color")) {
                if (std.ascii.eqlIgnoreCase(val, "on") or std.ascii.eqlIgnoreCase(val, "true") or std.ascii.eqlIgnoreCase(val, "1")) self.console_color = true;
                if (std.ascii.eqlIgnoreCase(val, "off") or std.ascii.eqlIgnoreCase(val, "false") or std.ascii.eqlIgnoreCase(val, "0")) self.console_color = false;
            } else if (std.ascii.eqlIgnoreCase(key, "upstream")) {
                // Fork v3.6c: /upstream persistence, agent-side (belt for the
                // bridge's upstream.txt). Must look like a URL or it is junk.
                if (std.mem.startsWith(u8, val, "http://") or std.mem.startsWith(u8, val, "https://")) {
                    self.upstream = self.dupeAndOwn(val) catch continue;
                }
            }
        }
    }

    pub fn saveSettingsFile(self: *Config, path: []const u8) !void {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 0) catch unreachable;
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);
        try w.writeAll("; micro-agent runtime settings - edited by /commands, safe to fix by hand\n");
        try w.writeAll("; (ASCII only; delete this file to reset all runtime overrides)\n");
        try w.print("model={s}\n", .{self.transport_api_model});
        try w.print("api_style={s}\n", .{@tagName(self.transport_api_style)});
        try w.print("stream={s}\n", .{if (self.transport_api_stream) "true" else "false"});
        try w.print("thinking={s}\n", .{self.transport_thinking.toString()});
        try w.print("context_window={d}\n", .{self.transport_api_context_window});
        try w.print("max_tokens={d}\n", .{self.transport_api_max_tokens});
        try w.print("auto_compact={s}\n", .{if (self.auto_compact) "true" else "false"});
        try w.print("keep_recent={d}\n", .{self.keep_recent});
        try w.print("max_tool_rounds={d}\n", .{self.max_tool_rounds});
        try w.print("thinking_display={s}\n", .{@tagName(self.thinking_display)});
        try w.print("color={s}\n", .{if (self.console_color) "on" else "off"});
        if (self.upstream.len > 0) try w.print("upstream={s}\n", .{self.upstream});

        const file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
        defer file.close();
        try file.writeAll(buf.items);
    }

    pub fn deinit(self: *Config) void {
        // Free all owned duplicated strings
        if (self._strings_initialized) {
            for (self._owned_strings.items) |s| {
                self.allocator.free(s);
            }
            self._owned_strings.deinit(self.allocator);
        }
        if (self._owned_json) |json| {
            self.allocator.free(json);
        }
    }
};

test "config defaults" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var cfg = Config.defaults(gpa.allocator());
    defer cfg.deinit();
    try std.testing.expectEqual(cfg.mode, .interactive);
    try std.testing.expectEqualStrings(cfg.agent_name, "micro-agent");
}
