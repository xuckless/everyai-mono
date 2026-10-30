//! Recovering from replies cut off by the output token limit
//! (`finish_reason: "length"`), shared by the chat loop and the gateway.
//!
//! The rules:
//! - A tool call that was cut off never runs: its arguments are incomplete.
//! - The cut-off call is asked for again once, with a bigger output cap.
//! - Cut-off text is continued with a short nudge (at most `max_continuations`).
//! - When the chat step budget runs out, one last call without tools asks for
//!   a summary instead of ending on a silent tool call.
const std = @import("std");
const openrouter = @import("openrouter.zig");

/// Text continuations per turn (chat) or per request (gateway).
pub const max_continuations = 2;

/// The smallest cap a retry asks for, and the ceiling when the catalog
/// doesn't know the model's output limit.
const boost_floor: i64 = 32_768;
const unknown_ceiling: i64 = 128_000;

/// Sent as a user message after cut-off text, so the model picks up mid-sentence.
pub const continue_nudge =
    \\[Your last reply stopped because it reached the output length limit. Carry on from the exact point where it stopped. Do not repeat or summarize what you already wrote.]
;

/// Sent when the chat turn has used all its tool steps.
pub const summary_nudge =
    \\[This turn has used all of its tool steps, so no more tools can run. Reply to the user now without calling any tool: say what you did, what you found, and what is still left to do.]
;

/// The tool result for a call that was cut off and not run.
pub fn notRun(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "Error: this {s} call was not run. Your reply reached the output token limit before its arguments were complete, so nothing was changed. Split the work into smaller calls (for example create a shorter first version, then add to it with edits) and call again with complete arguments.", .{name});
}

/// Appended to a cut-off call's arguments in the gateway: whatever the JSON
/// was, it no longer parses, so the harness reports an error instead of
/// running a half-written command or file.
pub const cut_marker = "\n[cut off: output token limit reached before the arguments were complete; not run]";

pub fn isLength(finish_reason: []const u8) bool {
    return std.mem.eql(u8, finish_reason, "length");
}

/// The output cap for a retry after a cut-off tool call: at least 32K and
/// twice the cap that was hit, bounded by the model's output limit (0 =
/// unknown). Null when that wouldn't give the model more room.
pub fn boostedCap(hit: i64, model_limit: i64) ?i64 {
    const ceiling = if (model_limit > 0) model_limit else unknown_ceiling;
    const want = @min(@max(boost_floor, hit *| 2), ceiling);
    return if (want > hit) want else null;
}

/// Wraps a delta sink for a retried request: the app already has the first
/// attempt's text and reasoning, so the retry's copies of them are dropped
/// while they match, and only what is new goes through. Sources already sent
/// are dropped too.
pub fn Replay(comptime Inner: type) type {
    return struct {
        inner: Inner,
        text: Prefix,
        reasoning: Prefix,
        sources: []const openrouter.Source,
        new_sources: std.ArrayList(openrouter.Source) = .empty,
        arena: std.mem.Allocator,

        const Self = @This();

        pub fn init(arena: std.mem.Allocator, inner: Inner, first: openrouter.Result) Self {
            return .{ .inner = inner, .text = .{ .sent = first.text }, .reasoning = .{ .sent = first.reasoning }, .sources = first.sources, .arena = arena };
        }

        pub fn onDelta(self: *Self, d: openrouter.Delta) !void {
            switch (d) {
                .text => |t| if (self.text.fresh(t)) |rest| try self.inner.onDelta(.{ .text = rest }),
                .reasoning => |t| if (self.reasoning.fresh(t)) |rest| try self.inner.onDelta(.{ .reasoning = rest }),
                .sources => |list| {
                    self.new_sources.clearRetainingCapacity();
                    for (list) |s| {
                        if (!hasUrl(self.sources, s.url)) try self.new_sources.append(self.arena, s);
                    }
                    if (self.new_sources.items.len > 0) try self.inner.onDelta(.{ .sources = self.new_sources.items });
                },
            }
        }
    };
}

/// Skips streamed text while it repeats `sent`. After the first difference
/// (or once `sent` is used up) everything goes through.
pub const Prefix = struct {
    sent: []const u8,
    at: usize = 0,
    diverged: bool = false,

    /// The part of `chunk` the app hasn't seen, or null if there is none.
    pub fn fresh(self: *Prefix, chunk: []const u8) ?[]const u8 {
        if (self.diverged) return if (chunk.len > 0) chunk else null;
        const left = self.sent[self.at..];
        const n = std.mem.indexOfDiff(u8, chunk, left) orelse chunk.len;
        if (n == chunk.len) {
            self.at += n;
            return null;
        }
        self.at += n;
        self.diverged = true;
        return chunk[n..];
    }
};

fn hasUrl(list: []const openrouter.Source, url: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s.url, url)) return true;
    return false;
}

test boostedCap {
    try std.testing.expectEqual(@as(?i64, 32_768), boostedCap(4_096, 0));
    try std.testing.expectEqual(@as(?i64, 64_000), boostedCap(32_000, 64_000));
    try std.testing.expectEqual(@as(?i64, 128_000), boostedCap(100_000, 0));
    // Already at the model's limit: a retry can't help.
    try std.testing.expectEqual(@as(?i64, null), boostedCap(64_000, 64_000));
}

test Prefix {
    var p: Prefix = .{ .sent = "Hello there" };
    try std.testing.expect(p.fresh("Hel") == null);
    try std.testing.expect(p.fresh("lo there") == null);
    try std.testing.expectEqualStrings("!", p.fresh("!").?);
    try std.testing.expectEqualStrings("more", p.fresh("more").?);

    var q: Prefix = .{ .sent = "abc" };
    try std.testing.expectEqualStrings("xyz", q.fresh("abxyz").?);
    try std.testing.expectEqualStrings("c", q.fresh("c").?);
}

test Replay {
    const Collect = struct {
        out: *std.Io.Writer.Allocating,
        pub fn onDelta(self: @This(), d: openrouter.Delta) !void {
            switch (d) {
                .text => |t| try self.out.writer.writeAll(t),
                .reasoning => |t| try self.out.writer.print("<r:{s}>", .{t}),
                .sources => |l| for (l) |s| try self.out.writer.print("<s:{s}>", .{s.url}),
            }
        }
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const first: openrouter.Result = .{
        .text = "I'll write it.",
        .reasoning = "plan",
        .tool_calls = &.{},
        .sources = &.{.{ .url = "https://a", .title = "a" }},
        .usage = .{},
        .finish_reason = "length",
        .model = "m",
    };
    var r = Replay(Collect).init(arena.allocator(), .{ .out = &out }, first);
    try r.onDelta(.{ .reasoning = "plan" });
    try r.onDelta(.{ .text = "I'll " });
    try r.onDelta(.{ .text = "write it." });
    try r.onDelta(.{ .sources = &.{ .{ .url = "https://a", .title = "a" }, .{ .url = "https://b", .title = "b" } } });
    try r.onDelta(.{ .text = " Done." });
    try std.testing.expectEqualStrings("<s:https://b> Done.", out.written());
}
