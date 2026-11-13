// Fork v2: aggregate test root so `zig build test` actually runs the
// per-file unit tests (main.zig alone never references them).
const std = @import("std");

test "transport" {
    std.testing.refAllDecls(@import("transport/transport.zig"));
}

test "config" {
    std.testing.refAllDecls(@import("core/config.zig"));
}

test "agent" {
    std.testing.refAllDecls(@import("core/agent.zig"));
}

test "registry" {
    std.testing.refAllDecls(@import("tools/registry.zig"));
}

test "encoding" {
    std.testing.refAllDecls(@import("utils/encoding.zig"));
}
