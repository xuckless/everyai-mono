//! Tool calls the app runs itself ("client-executed"): the chat turn sends a
//! `tool_wait` event, parks here, and resumes when the app POSTs the result to
//! `/v1/chat/tool_result` (or the wait times out).
//!
//! A `Waiter` lives in the waiting request's arena and is linked into `Waits`
//! for as long as it waits. Everything that touches a linked waiter does so
//! under the mutex; the result bytes cross over in the shared allocator.
const std = @import("std");

pub const Waiter = struct {
    user_id: []const u8,
    call_id: []const u8,
    next: ?*Waiter = null,
    done: std.Io.Event = .unset,
    /// Set (owned by the shared allocator) when the app answers.
    result: ?[]u8 = null,
    is_error: bool = false,
};

pub const Answer = struct { text: []const u8, is_error: bool };

pub const Outcome = union(enum) {
    answered: Answer,
    timeout,
};

pub const Waits = struct {
    mutex: std.Io.Mutex = .init,
    head: ?*Waiter = null,

    /// Links `w` so `resolve` can find it. Call before telling the app.
    pub fn add(self: *Waits, io: std.Io, w: *Waiter) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        w.next = self.head;
        self.head = w;
    }

    /// Hands the app's answer to the waiting turn. False when no turn of this
    /// user waits for `call_id` (it timed out, finished or never existed).
    pub fn resolve(self: *Waits, io: std.Io, gpa: std.mem.Allocator, user_id: []const u8, call_id: []const u8, result: []const u8, is_error: bool) !bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var it = self.head;
        while (it) |w| : (it = w.next) {
            if (!std.mem.eql(u8, w.call_id, call_id) or !std.mem.eql(u8, w.user_id, user_id)) continue;
            self.unlink(w);
            w.result = try gpa.dupe(u8, result);
            w.is_error = is_error;
            // Under the mutex: the waiter can't return (and free `w`) before this.
            w.done.set(io);
            return true;
        }
        return false;
    }

    /// Blocks until the app answers `w` or `timeout` passes. `beat.heartbeat()`
    /// runs every `beat_every` while waiting (an SSE comment keeps proxies from
    /// closing the idle stream; its error, a gone client, ends the wait). `w` is
    /// unlinked whatever happens; the answer is copied into `arena`.
    pub fn wait(self: *Waits, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, w: *Waiter, timeout: std.Io.Duration, beat_every: std.Io.Duration, beat: anytype) !Outcome {
        errdefer self.drop(io, gpa, w);
        const Ts = std.Io.Clock.Timestamp;
        const deadline = Ts.fromNow(io, .{ .raw = timeout, .clock = .awake });
        while (!w.done.isSet()) {
            const now = Ts.now(io, .awake);
            if (now.compare(.gte, deadline)) break;
            const next_beat = now.addDuration(.{ .raw = beat_every, .clock = .awake });
            const until = if (next_beat.compare(.lt, deadline)) next_beat else deadline;
            w.done.waitTimeout(io, .{ .deadline = until }) catch |err| switch (err) {
                error.Timeout => {},
                error.Canceled => return err,
            };
            if (!w.done.isSet() and Ts.now(io, .awake).compare(.gte, next_beat)) try beat.heartbeat();
        }
        self.detach(io, w);
        // Unlinked: nobody else touches `w` now.
        const bytes = w.result orelse return .timeout;
        w.result = null;
        defer gpa.free(bytes);
        return .{ .answered = .{ .text = try arena.dupe(u8, bytes), .is_error = w.is_error } };
    }

    /// Unlinks `w` without waiting (the app could not be told), dropping any answer.
    pub fn drop(self: *Waits, io: std.Io, gpa: std.mem.Allocator, w: *Waiter) void {
        self.detach(io, w);
        if (w.result) |bytes| gpa.free(bytes);
        w.result = null;
    }

    fn detach(self: *Waits, io: std.Io, w: *Waiter) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.unlink(w);
    }

    /// Caller holds the mutex. A waiter already unlinked is left alone.
    fn unlink(self: *Waits, w: *Waiter) void {
        var link = &self.head;
        while (link.*) |cur| : (link = &cur.next) {
            if (cur == w) {
                link.* = w.next;
                w.next = null;
                return;
            }
        }
    }

    /// How many turns wait now (tests).
    pub fn count(self: *Waits, io: std.Io) usize {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var n: usize = 0;
        var it = self.head;
        while (it) |w| : (it = w.next) n += 1;
        return n;
    }
};

const NoBeat = struct {
    beats: usize = 0,
    fn heartbeat(self: *NoBeat) !void {
        self.beats += 1;
    }
};

test "waits: an answer given before the wait is returned; others are refused" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var waits: Waits = .{};
    var w: Waiter = .{ .user_id = "u1", .call_id = "call_1" };
    var other: Waiter = .{ .user_id = "u1", .call_id = "call_2" };
    waits.add(io, &w);
    waits.add(io, &other);
    try std.testing.expectEqual(@as(usize, 2), waits.count(io));
    // Another user can't answer it.
    try std.testing.expect(!try waits.resolve(io, gpa, "u2", "call_1", "x", false));
    try std.testing.expect(try waits.resolve(io, gpa, "u1", "call_1", "Parse error on line 2", true));
    // Answered once: a second answer finds nothing.
    try std.testing.expect(!try waits.resolve(io, gpa, "u1", "call_1", "again", false));
    var beat: NoBeat = .{};
    const out = try waits.wait(io, gpa, arena.allocator(), &w, .fromSeconds(5), .fromSeconds(1), &beat);
    try std.testing.expectEqualStrings("Parse error on line 2", out.answered.text);
    try std.testing.expect(out.answered.is_error);
    try std.testing.expectEqual(@as(usize, 1), waits.count(io));
    waits.detach(io, &other);
    try std.testing.expectEqual(@as(usize, 0), waits.count(io));
}

test "waits: no answer times out, beating meanwhile, and unlinks" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var waits: Waits = .{};
    var w: Waiter = .{ .user_id = "u1", .call_id = "call_1" };
    waits.add(io, &w);
    var beat: NoBeat = .{};
    const out = try waits.wait(io, gpa, arena.allocator(), &w, .fromMilliseconds(60), .fromMilliseconds(10), &beat);
    try std.testing.expect(out == .timeout);
    try std.testing.expect(beat.beats >= 1);
    try std.testing.expectEqual(@as(usize, 0), waits.count(io));
    try std.testing.expect(!try waits.resolve(io, gpa, "u1", "call_1", "late", false));
}
