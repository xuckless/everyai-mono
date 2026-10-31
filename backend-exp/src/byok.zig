//! Bring your own key. The app keeps the user's provider keys in the device
//! keychain and sends them with each model request; the server uses them
//! for that request only and never stores or logs them. Calls on the
//! user's key are recorded in usage_events but not charged.
//!
//! Only providers whose path we know works end to end (streaming, tool
//! calls, caching, usage) are accepted: OpenRouter (every catalog model)
//! and Anthropic (`anthropic/*`, through the native adapter).
const std = @import("std");
const anole = @import("anole");

pub const openrouter_header = "X-Provider-Key-OpenRouter";
pub const anthropic_header = "X-Provider-Key-Anthropic";

pub const Keys = struct {
    openrouter: ?[]const u8 = null,
    anthropic: ?[]const u8 = null,

    pub fn of(req: *anole.Request) Keys {
        return .{
            .openrouter = clean(req.headers.get(openrouter_header)),
            .anthropic = clean(req.headers.get(anthropic_header)),
        };
    }

    /// Whether `model` runs on one of these keys (so it is never charged).
    /// `native_ok` false means the call needs OpenRouter (the web plugin).
    pub fn covers(self: Keys, model: []const u8, native_ok: bool) bool {
        if (self.openrouter != null) return true;
        return native_ok and self.anthropic != null and isAnthropic(model);
    }
};

pub fn isAnthropic(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "anthropic/");
}

/// A key worth trying: trimmed, non-empty, printable ASCII without spaces
/// (it goes into an upstream header as is).
fn clean(raw: ?[]const u8) ?[]const u8 {
    const k = std.mem.trim(u8, raw orelse return null, " \t");
    if (k.len < 8 or k.len > 512) return null;
    for (k) |c| if (c <= ' ' or c >= 0x7f) return null;
    return k;
}

test "keys cover their models" {
    const both: Keys = .{ .openrouter = "sk-or-v1-abc", .anthropic = "sk-ant-abc" };
    try std.testing.expect(both.covers("openai/gpt-6.1-sol", true));
    const ant: Keys = .{ .anthropic = "sk-ant-abcdef" };
    try std.testing.expect(ant.covers("anthropic/claude-haiku-5.5", true));
    try std.testing.expect(!ant.covers("anthropic/claude-haiku-5.5", false));
    try std.testing.expect(!ant.covers("openai/gpt-6.1-sol", true));
    try std.testing.expect(!(Keys{}).covers("anthropic/claude-haiku-5.5", true));
}

test "malformed keys are ignored" {
    try std.testing.expect(clean("  sk-or-v1-abcdef  ") != null);
    try std.testing.expect(clean("short") == null);
    try std.testing.expect(clean("sk-or v1 abcdef") == null);
    try std.testing.expect(clean("sk-or-v1-abc\r\nX-Evil: 1") == null);
    try std.testing.expect(clean(null) == null);
}
