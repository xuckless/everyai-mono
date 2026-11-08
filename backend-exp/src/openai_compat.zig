//! A direct OpenAI-compatible provider on the user's own key (byok.zig):
//! OpenAI, Google AI Studio, xAI, DeepSeek and the rest of `providers.json`.
//! The body is the one we'd send OpenRouter, rewritten for a plain
//! OpenAI-style endpoint (local.rewriteBody: OpenRouter-only fields dropped,
//! `stream_options.include_usage`), with the model renamed to the
//! provider's own id. These providers report tokens but no cost, so billing
//! prices the call from the catalog (`billing.charge`).
const std = @import("std");
const openrouter = @import("openrouter.zig");
const local = @import("local.zig");
const byok = @import("byok.zig");

pub const Adapter = struct {
    inner: openrouter.Upstream,
    provider: byok.Provider,
    model: []const u8,

    pub fn upstream(self: *Adapter) openrouter.Upstream {
        return .{ .ptr = self, .vtable = &.{ .post = post, .get = get } };
    }

    fn post(ptr: *anyopaque, cx: openrouter.Ctx, path: []const u8, body: []const u8, extra: []const [2][]const u8) anyerror!openrouter.Stream {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        return self.inner.post(cx, path, try rewrite(cx.arena, body, self.provider, self.model), extra);
    }

    fn get(ptr: *anyopaque, io: std.Io, arena: std.mem.Allocator, path: []const u8) anyerror![]const u8 {
        const self: *Adapter = @ptrCast(@alignCast(ptr));
        return self.inner.get(io, arena, path);
    }
};

pub fn rewrite(arena: std.mem.Allocator, body: []const u8, provider: byok.Provider, model: []const u8) ![]const u8 {
    return local.rewriteBody(arena, body, provider.modelId(model), .custom);
}

test "the body goes out under the provider's own model id, without OpenRouter's fields" {
    try byok.load();
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try rewrite(a,
        \\{"model":"openai/gpt-6.1-sol","stream":true,"provider":{"sort":"price"},"usage":{"include":true},"plugins":[],"messages":[{"role":"user","content":"hi","cache_control":{"type":"ephemeral"}}]}
    , byok.byId("openai").?, "openai/gpt-6.1-sol");
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, out, .{});
    try std.testing.expectEqualStrings("gpt-6.1-sol", v.object.get("model").?.string);
    try std.testing.expect(v.object.get("provider") == null);
    try std.testing.expect(v.object.get("plugins") == null);
    try std.testing.expect(v.object.get("stream_options").?.object.get("include_usage").?.bool);
    try std.testing.expect(v.object.get("messages").?.array.items[0].object.get("cache_control") == null);
}
