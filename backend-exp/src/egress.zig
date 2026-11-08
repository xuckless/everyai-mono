//! Egress: the bytes the server sends out, metered and limited (owner,
//! 2026-11-08: "limit them, start up a global queue, our servers are small;
//! design it so it can become a product without a rewrite").
//!
//! Four pieces, each replaceable on its own:
//! - `Subject`: who the bytes count against. A claimed host counts against
//!   its account, an anonymous one against itself.
//! - `QuotaSource`: the limits of a subject (a vtable). Today `StaticQuotas`
//!   reads the config; a plans/entitlements table plugs in through the same
//!   interface later.
//! - `Ledger`: bytes per subject per day and per month, plus the server's
//!   month. In memory, flushed to `egress_usage` (hourly and on socket
//!   close) and loaded back at start, so a restart doesn't reset anyone.
//!   Metering and invoices would read the same rows.
//! - `Gate`: global admission and pacing. A token bucket caps the server's
//!   send rate; `max_live` caps open relay sockets, and a socket over it
//!   waits in one FIFO queue (told its place) instead of being refused; a
//!   subject may hold at most `per_subject_live` of them (fair share).
//!
//! A relay socket's states (`Admission`):
//!
//! ```text
//!   queued ──slot free, first in line──► admitted ⇄ throttled (pacing waits)
//!     │                                     │
//!     └──closed──► closed ◄──closed─────────┤
//!                                           └──quota spent──► over_quota ──► closed (4008)
//! ```
const std = @import("std");

pub const close_over_quota: u16 = 4008;

pub const Subject = struct {
    kind: Kind,
    id: []const u8,

    pub const Kind = enum { host, account };

    /// "host:<id>" / "account:<id>", as stored.
    pub fn key(self: Subject, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}:{s}", .{ @tagName(self.kind), self.id }) catch self.id;
    }
};

pub const Limits = struct {
    daily_bytes: u64,
    monthly_bytes: u64,
};

/// Where a subject's limits come from.
pub const QuotaSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        limits: *const fn (ptr: *anyopaque, subject: Subject) Limits,
    };

    pub fn limits(self: QuotaSource, subject: Subject) Limits {
        return self.vtable.limits(self.ptr, subject);
    }
};

/// Limits from the config: one tier for anonymous hosts, one for accounts.
pub const StaticQuotas = struct {
    host: Limits,
    account: Limits,

    pub fn source(self: *StaticQuotas) QuotaSource {
        return .{ .ptr = self, .vtable = &.{ .limits = limitsOf } };
    }

    fn limitsOf(ptr: *anyopaque, subject: Subject) Limits {
        const self: *StaticQuotas = @ptrCast(@alignCast(ptr));
        return switch (subject.kind) {
            .host => self.host,
            .account => self.account,
        };
    }
};

pub const Periods = struct {
    /// Days since the epoch (UTC).
    day: i64,
    /// year * 12 + month - 1 (UTC).
    month: i64,

    pub fn of(now_s: i64) Periods {
        const secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, now_s)) };
        const day = secs.getEpochDay();
        const yd = day.calculateYearDay();
        const md = yd.calculateMonthDay();
        return .{ .day = day.day, .month = @as(i64, yd.year) * 12 + (@as(i64, md.month.numeric()) - 1) };
    }
};

/// Per-subject usage for the current day and month.
pub const Usage = struct {
    day: i64 = 0,
    month: i64 = 0,
    day_bytes: u64 = 0,
    month_bytes: u64 = 0,
    /// Bytes not yet written to `egress_usage`.
    unflushed_day: u64 = 0,
    unflushed_month: u64 = 0,

    fn roll(self: *Usage, p: Periods) void {
        if (self.day != p.day) {
            self.day = p.day;
            self.day_bytes = 0;
            self.unflushed_day = 0;
        }
        if (self.month != p.month) {
            self.month = p.month;
            self.month_bytes = 0;
            self.unflushed_month = 0;
        }
    }
};

pub const Admission = enum { queued, admitted, throttled, over_quota, closed };

pub const Config = struct {
    /// Server-wide send rate (bytes per second); 0 = unpaced.
    rate_bytes_per_s: u64,
    /// Server-wide bytes a month; past it every relay socket is over quota.
    monthly_bytes: u64,
    /// Log a warning once the month passes this share of `monthly_bytes`.
    warn_share: f64 = 0.8,
    /// Open relay sockets at once; more wait in the queue.
    max_live: u32,
    /// Open relay sockets one subject may hold (fair share).
    per_subject_live: u32,
};

pub const Gate = struct {
    gpa: std.mem.Allocator,
    cfg: Config,
    quotas: QuotaSource,
    mutex: std.Io.Mutex = .init,
    usage: std.StringHashMapUnmanaged(Usage) = .empty,
    /// Live sockets per subject key.
    live: std.StringHashMapUnmanaged(u32) = .empty,
    live_total: u32 = 0,
    /// Waiting tickets, oldest first, with their subject key (a slice of
    /// the ticket's own `key_buf`, which lives until `leave`).
    queue: std.ArrayList(Waiting) = .empty,
    /// Unflushed bytes of a day or month that ended before they were
    /// written (subject and period owned): `drain` hands them over.
    carry: std.ArrayList(Row) = .empty,
    next_ticket: u64 = 1,
    server: Usage = .{},
    warned_month: i64 = -1,
    /// Token bucket (bytes), refilled by elapsed time.
    tokens: f64 = 0,
    refilled_ns: i96 = 0,
    last_flush_s: i64 = 0,

    pub fn init(gpa: std.mem.Allocator, cfg: Config, quotas: QuotaSource) Gate {
        return .{ .gpa = gpa, .cfg = cfg, .quotas = quotas, .tokens = @floatFromInt(cfg.rate_bytes_per_s) };
    }

    pub fn deinit(self: *Gate) void {
        var it = self.usage.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.usage.deinit(self.gpa);
        var lit = self.live.keyIterator();
        while (lit.next()) |k| self.gpa.free(k.*);
        self.live.deinit(self.gpa);
        self.queue.deinit(self.gpa);
        for (self.carry.items) |r| {
            self.gpa.free(r.subject);
            self.gpa.free(r.period);
        }
        self.carry.deinit(self.gpa);
    }

    const Waiting = struct { id: u64, key: []const u8 };

    // -------------------------------------------------------------- admission

    pub const Ticket = struct { id: u64, key_buf: [160]u8 = undefined, key_len: usize = 0, state: Admission = .queued };

    pub const Ask = union(enum) {
        admitted,
        /// Waiting; `position` 1 is next.
        queued: u32,
        /// The subject already holds its share of sockets.
        subject_full,
        over_quota,
    };

    /// Asks for a slot. A ticket that waits keeps its place: call again
    /// with the same ticket until it is admitted (or give up with `leave`).
    pub fn admit(self: *Gate, io: std.Io, subject: Subject, ticket: *Ticket, now_s: i64) !Ask {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (ticket.key_len == 0) {
            ticket.key_len = subject.key(&ticket.key_buf).len;
            ticket.id = self.next_ticket;
            self.next_ticket += 1;
        }
        const key = ticket.key_buf[0..ticket.key_len];
        if (try self.overQuotaLocked(subject, key, now_s)) {
            self.dropFromQueueLocked(ticket.id);
            // It holds no slot: `leave` has nothing to give back.
            ticket.state = .closed;
            return .over_quota;
        }
        const pos = self.queuePosLocked(ticket.id);
        // Its share counts the sockets it has waiting too: otherwise one
        // subject could fill the line ahead of everyone else.
        const held = (self.live.get(key) orelse 0) + if (pos == null) self.waitingLocked(key) else 0;
        if (held >= self.cfg.per_subject_live) {
            self.dropFromQueueLocked(ticket.id);
            return .subject_full;
        }
        const first = if (pos) |p| p == 0 else self.queue.items.len == 0;
        if (self.live_total < self.cfg.max_live and first) {
            if (pos != null) _ = self.queue.orderedRemove(0);
            try self.addLiveLocked(key);
            ticket.state = .admitted;
            return .admitted;
        }
        if (pos) |p| return .{ .queued = @intCast(p + 1) };
        try self.queue.append(self.gpa, .{ .id = ticket.id, .key = key });
        ticket.state = .queued;
        return .{ .queued = @intCast(self.queue.items.len) };
    }

    /// A socket ends: frees its slot (or its place in line).
    pub fn leave(self: *Gate, io: std.Io, ticket: *Ticket) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        defer ticket.state = .closed;
        switch (ticket.state) {
            .queued => self.dropFromQueueLocked(ticket.id),
            .admitted, .throttled, .over_quota => {
                const key = ticket.key_buf[0..ticket.key_len];
                if (self.live.getPtr(key)) |n| {
                    if (n.* > 0) n.* -= 1;
                    if (self.live_total > 0) self.live_total -= 1;
                    if (n.* == 0) {
                        const kv = self.live.fetchRemove(key).?;
                        self.gpa.free(kv.key);
                    }
                }
            },
            .closed => {},
        }
    }

    fn addLiveLocked(self: *Gate, key: []const u8) !void {
        const e = try self.live.getOrPut(self.gpa, key);
        if (!e.found_existing) {
            e.key_ptr.* = self.gpa.dupe(u8, key) catch |err| {
                self.live.removeByPtr(e.key_ptr);
                return err;
            };
            e.value_ptr.* = 0;
        }
        e.value_ptr.* += 1;
        self.live_total += 1;
    }

    fn queuePosLocked(self: *Gate, id: u64) ?usize {
        for (self.queue.items, 0..) |w, i| if (w.id == id) return i;
        return null;
    }

    fn waitingLocked(self: *Gate, key: []const u8) u32 {
        var n: u32 = 0;
        for (self.queue.items) |w| if (std.mem.eql(u8, w.key, key)) {
            n += 1;
        };
        return n;
    }

    fn dropFromQueueLocked(self: *Gate, id: u64) void {
        if (self.queuePosLocked(id)) |p| _ = self.queue.orderedRemove(p);
    }

    // -------------------------------------------------------------- spending

    pub const Spend = union(enum) {
        ok,
        /// Wait this long before sending (the server's rate).
        wait_ns: u64,
        over_quota,
    };

    /// Counts `n` bytes against `subject` and the server. Over a quota: the
    /// bytes aren't sent (nor counted). Over the rate: they are counted,
    /// and the caller waits `wait_ns` before sending.
    pub fn spend(self: *Gate, io: std.Io, subject: Subject, n: u64, now_ns: i96) !Spend {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const now_s: i64 = @intCast(@divFloor(now_ns, std.time.ns_per_s));
        var buf: [160]u8 = undefined;
        const key = subject.key(&buf);
        if (try self.overQuotaLocked(subject, key, now_s)) return .over_quota;
        const u = try self.usageLocked(key, now_s);
        u.day_bytes += n;
        u.month_bytes += n;
        u.unflushed_day += n;
        u.unflushed_month += n;
        self.server.roll(Periods.of(now_s));
        self.server.month_bytes += n;
        self.server.day_bytes += n;
        self.warnLocked();
        return self.paceLocked(n, now_ns);
    }

    fn paceLocked(self: *Gate, n: u64, now_ns: i96) Spend {
        const rate = self.cfg.rate_bytes_per_s;
        if (rate == 0) return .ok;
        const cap: f64 = @floatFromInt(rate); // one second of burst
        if (self.refilled_ns == 0) self.refilled_ns = now_ns;
        const elapsed: f64 = @floatFromInt(@max(0, now_ns - self.refilled_ns));
        self.refilled_ns = now_ns;
        self.tokens = @min(cap, self.tokens + elapsed / std.time.ns_per_s * cap);
        self.tokens -= @floatFromInt(n);
        if (self.tokens >= 0) return .ok;
        const debt = -self.tokens;
        return .{ .wait_ns = @intFromFloat(debt / cap * std.time.ns_per_s) };
    }

    fn usageLocked(self: *Gate, key: []const u8, now_s: i64) !*Usage {
        const e = try self.usage.getOrPut(self.gpa, key);
        if (!e.found_existing) {
            e.key_ptr.* = self.gpa.dupe(u8, key) catch |err| {
                self.usage.removeByPtr(e.key_ptr);
                return err;
            };
            e.value_ptr.* = .{};
        }
        try self.rollLocked(e.key_ptr.*, e.value_ptr, Periods.of(now_s));
        return e.value_ptr;
    }

    /// Moves `u` to `p`, keeping the bytes of the day or month that ended
    /// and weren't flushed yet for the next `drain`.
    fn rollLocked(self: *Gate, key: []const u8, u: *Usage, p: Periods) !void {
        if (u.day != p.day and u.unflushed_day > 0) try self.carryLocked(key, 'd', u.day, u.unflushed_day);
        if (u.month != p.month and u.unflushed_month > 0) try self.carryLocked(key, 'm', u.month, u.unflushed_month);
        u.roll(p);
    }

    fn carryLocked(self: *Gate, key: []const u8, kind: u8, period: i64, bytes: u64) !void {
        const subject = try self.gpa.dupe(u8, key);
        errdefer self.gpa.free(subject);
        const name = try std.fmt.allocPrint(self.gpa, "{c}{d}", .{ kind, period });
        errdefer self.gpa.free(name);
        try self.carry.append(self.gpa, .{ .subject = subject, .period = name, .bytes = @intCast(bytes) });
    }

    fn overQuotaLocked(self: *Gate, subject: Subject, key: []const u8, now_s: i64) !bool {
        const p = Periods.of(now_s);
        self.server.roll(p);
        if (self.cfg.monthly_bytes > 0 and self.server.month_bytes >= self.cfg.monthly_bytes) return true;
        const lim = self.quotas.limits(subject);
        const u = self.usage.getPtr(key) orelse return false;
        try self.rollLocked(key, u, p);
        return (lim.daily_bytes > 0 and u.day_bytes >= lim.daily_bytes) or
            (lim.monthly_bytes > 0 and u.month_bytes >= lim.monthly_bytes);
    }

    fn warnLocked(self: *Gate) void {
        if (self.cfg.monthly_bytes == 0 or self.warned_month == self.server.month) return;
        const share = @as(f64, @floatFromInt(self.server.month_bytes)) / @as(f64, @floatFromInt(self.cfg.monthly_bytes));
        if (share < self.cfg.warn_share) return;
        self.warned_month = self.server.month;
        std.log.warn("egress: {d:.0}% of this month's relay budget used ({d} of {d} bytes)", .{ share * 100, self.server.month_bytes, self.cfg.monthly_bytes });
    }

    /// When the subject's quota resets next (start of the next UTC day, or
    /// of the next month when the month is what's spent): seconds since the
    /// epoch.
    pub fn resetsAt(self: *Gate, io: std.Io, subject: Subject, now_s: i64) i64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var buf: [160]u8 = undefined;
        const key = subject.key(&buf);
        const p = Periods.of(now_s);
        const next_day = (p.day + 1) * 86_400;
        const lim = self.quotas.limits(subject);
        const month_spent = (self.cfg.monthly_bytes > 0 and self.server.month_bytes >= self.cfg.monthly_bytes) or
            if (self.usage.get(key)) |u| (lim.monthly_bytes > 0 and u.month_bytes >= lim.monthly_bytes) else false;
        if (!month_spent) return next_day;
        var d = p.day + 1;
        while (Periods.of(d * 86_400).month == p.month) d += 1;
        return d * 86_400;
    }

    // -------------------------------------------------------------- the ledger

    pub const Row = struct { subject: []const u8, period: []const u8, bytes: i64 };

    /// Rows to add to `egress_usage` (`period`: "d<day>" / "m<month>"),
    /// and marks them flushed. The server's month is the sum of its
    /// subjects' month rows (`load`), so it needs no row of its own.
    pub fn drain(self: *Gate, io: std.Io, arena: std.mem.Allocator, now_s: i64) ![]const Row {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.last_flush_s = now_s;
        var out: std.ArrayList(Row) = .empty;
        try out.ensureUnusedCapacity(arena, self.carry.items.len);
        for (self.carry.items) |r| out.appendAssumeCapacity(.{ .subject = try arena.dupe(u8, r.subject), .period = try arena.dupe(u8, r.period), .bytes = r.bytes });
        for (self.carry.items) |r| {
            self.gpa.free(r.subject);
            self.gpa.free(r.period);
        }
        self.carry.clearRetainingCapacity();
        var it = self.usage.iterator();
        while (it.next()) |e| {
            const u = e.value_ptr;
            if (u.unflushed_day > 0) try out.append(arena, .{ .subject = try arena.dupe(u8, e.key_ptr.*), .period = try std.fmt.allocPrint(arena, "d{d}", .{u.day}), .bytes = @intCast(u.unflushed_day) });
            if (u.unflushed_month > 0) try out.append(arena, .{ .subject = try arena.dupe(u8, e.key_ptr.*), .period = try std.fmt.allocPrint(arena, "m{d}", .{u.month}), .bytes = @intCast(u.unflushed_month) });
            u.unflushed_day = 0;
            u.unflushed_month = 0;
        }
        return out.items;
    }

    /// Whether an hourly flush is due.
    pub fn flushDue(self: *Gate, io: std.Io, now_s: i64) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return now_s - self.last_flush_s >= 3600;
    }

    /// Restores this day's and month's totals at start.
    pub fn load(self: *Gate, io: std.Io, rows: []const Row, now_s: i64) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const p = Periods.of(now_s);
        self.last_flush_s = now_s;
        self.server.roll(p);
        for (rows) |r| {
            const u = try self.usageLocked(r.subject, now_s);
            const bytes: u64 = @intCast(@max(0, r.bytes));
            if (r.period.len > 1 and r.period[0] == 'd' and (std.fmt.parseInt(i64, r.period[1..], 10) catch -1) == p.day) u.day_bytes += bytes;
            if (r.period.len > 1 and r.period[0] == 'm' and (std.fmt.parseInt(i64, r.period[1..], 10) catch -1) == p.month) {
                u.month_bytes += bytes;
                self.server.month_bytes += bytes;
            }
        }
    }
};

// ------------------------------------------------------------------ tests

fn testGate(cfg: Config, quotas: *StaticQuotas) Gate {
    return Gate.init(std.testing.allocator, cfg, quotas.source());
}

const big: Limits = .{ .daily_bytes = 0, .monthly_bytes = 0 };

test "periods: day and month in UTC" {
    const p = Periods.of(1_762_560_000); // 2025-11-08 00:00 UTC
    try std.testing.expectEqual(@as(i64, 20400), p.day);
    try std.testing.expectEqual(@as(i64, 2025 * 12 + 10), p.month);
}

test "one queue, first in line goes first; a subject keeps its fair share" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var q: StaticQuotas = .{ .host = big, .account = big };
    var g = testGate(.{ .rate_bytes_per_s = 0, .monthly_bytes = 0, .max_live = 2, .per_subject_live = 2 }, &q);
    defer g.deinit();
    const a: Subject = .{ .kind = .host, .id = "a" };
    const b: Subject = .{ .kind = .host, .id = "b" };
    var t1: Gate.Ticket = .{ .id = 0 };
    var t2: Gate.Ticket = .{ .id = 0 };
    var t3: Gate.Ticket = .{ .id = 0 };
    var t4: Gate.Ticket = .{ .id = 0 };
    try std.testing.expectEqual(Gate.Ask.admitted, try g.admit(io, a, &t1, 0));
    try std.testing.expectEqual(Gate.Ask.admitted, try g.admit(io, a, &t2, 0));
    // a holds its two: a third is refused, not queued.
    var t5: Gate.Ticket = .{ .id = 0 };
    try std.testing.expectEqual(Gate.Ask.subject_full, try g.admit(io, a, &t5, 0));
    try std.testing.expectEqual(Gate.Ask{ .queued = 1 }, try g.admit(io, b, &t3, 0));
    try std.testing.expectEqual(Gate.Ask{ .queued = 2 }, try g.admit(io, b, &t4, 0));
    // The second in line can't jump the first.
    g.leave(io, &t1);
    try std.testing.expectEqual(Gate.Ask{ .queued = 2 }, try g.admit(io, b, &t4, 0));
    try std.testing.expectEqual(Gate.Ask.admitted, try g.admit(io, b, &t3, 0));
    try std.testing.expectEqual(Gate.Ask{ .queued = 1 }, try g.admit(io, b, &t4, 0));
    g.leave(io, &t2);
    try std.testing.expectEqual(Gate.Ask.admitted, try g.admit(io, b, &t4, 0));
    g.leave(io, &t3);
    g.leave(io, &t4);
    try std.testing.expectEqual(@as(u32, 0), g.live_total);
}

test "quotas: per subject per day, the server's month; the ledger drains and loads" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var q: StaticQuotas = .{ .host = .{ .daily_bytes = 100, .monthly_bytes = 0 }, .account = big };
    var g = testGate(.{ .rate_bytes_per_s = 0, .monthly_bytes = 1000, .max_live = 10, .per_subject_live = 10 }, &q);
    defer g.deinit();
    const h: Subject = .{ .kind = .host, .id = "h" };
    const acct: Subject = .{ .kind = .account, .id = "u" };
    const t0: i96 = 1_762_560_000 * std.time.ns_per_s;
    try std.testing.expectEqual(Gate.Spend.ok, try g.spend(io, h, 60, t0));
    try std.testing.expectEqual(Gate.Spend.ok, try g.spend(io, h, 60, t0));
    try std.testing.expectEqual(Gate.Spend.over_quota, try g.spend(io, h, 1, t0));
    // The next UTC day it can send again.
    try std.testing.expectEqual(Gate.Spend.ok, try g.spend(io, h, 1, t0 + 86_400 * std.time.ns_per_s));
    try std.testing.expectEqual(@as(i64, 1_762_560_000 + 2 * 86_400), g.resetsAt(io, h, 1_762_560_000 + 86_400));

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = try g.drain(io, arena.allocator(), 1_762_560_000 + 86_400);
    try std.testing.expect(rows.len >= 2);
    try std.testing.expectEqual(@as(usize, 0), (try g.drain(io, arena.allocator(), 1_762_560_000 + 86_400)).len);

    // The server's month: past it, everyone is over.
    try std.testing.expectEqual(Gate.Spend.ok, try g.spend(io, acct, 900, t0 + 86_400 * std.time.ns_per_s));
    try std.testing.expectEqual(Gate.Spend.over_quota, try g.spend(io, acct, 1, t0 + 86_400 * std.time.ns_per_s));

    // A restart reads the month back.
    var g2 = testGate(.{ .rate_bytes_per_s = 0, .monthly_bytes = 1000, .max_live = 10, .per_subject_live = 10 }, &q);
    defer g2.deinit();
    try g2.load(io, &.{
        .{ .subject = "host:h", .period = "d20401", .bytes = 100 },
        .{ .subject = "host:h", .period = "m24310", .bytes = 1000 },
    }, 1_762_560_000 + 86_400);
    try std.testing.expectEqual(Gate.Spend.over_quota, try g2.spend(io, h, 1, t0 + 86_400 * std.time.ns_per_s));
}

test "pacing: past the rate, the caller is told how long to wait" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var q: StaticQuotas = .{ .host = big, .account = big };
    var g = testGate(.{ .rate_bytes_per_s = 1000, .monthly_bytes = 0, .max_live = 10, .per_subject_live = 10 }, &q);
    defer g.deinit();
    const h: Subject = .{ .kind = .host, .id = "h" };
    const t0: i96 = 1_000 * std.time.ns_per_s;
    try std.testing.expectEqual(Gate.Spend.ok, try g.spend(io, h, 1000, t0));
    const s = try g.spend(io, h, 500, t0);
    try std.testing.expect(s == .wait_ns);
    try std.testing.expect(s.wait_ns >= 400 * std.time.ns_per_ms and s.wait_ns <= 600 * std.time.ns_per_ms);
    // A second later the bucket is full again.
    try std.testing.expectEqual(Gate.Spend.ok, try g.spend(io, h, 100, t0 + 2 * std.time.ns_per_s));
}

test "a quota source can be swapped (a plan table later)" {
    const Plans = struct {
        fn source() QuotaSource {
            return .{ .ptr = undefined, .vtable = &.{ .limits = limitsOf } };
        }
        fn limitsOf(_: *anyopaque, s: Subject) Limits {
            return if (std.mem.eql(u8, s.id, "pro")) .{ .daily_bytes = 0, .monthly_bytes = 0 } else .{ .daily_bytes = 10, .monthly_bytes = 0 };
        }
    };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var g = Gate.init(std.testing.allocator, .{ .rate_bytes_per_s = 0, .monthly_bytes = 0, .max_live = 10, .per_subject_live = 10 }, Plans.source());
    defer g.deinit();
    const t0: i96 = 1_000 * std.time.ns_per_s;
    _ = try g.spend(io, .{ .kind = .account, .id = "free" }, 10, t0);
    try std.testing.expectEqual(Gate.Spend.over_quota, try g.spend(io, .{ .kind = .account, .id = "free" }, 1, t0));
    _ = try g.spend(io, .{ .kind = .account, .id = "pro" }, 10_000, t0);
    try std.testing.expectEqual(Gate.Spend.ok, try g.spend(io, .{ .kind = .account, .id = "pro" }, 1, t0));
}

test "a ticket refused over its quota gives back no slot it never held" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var q: StaticQuotas = .{ .host = .{ .daily_bytes = 10, .monthly_bytes = 0 }, .account = big };
    var g = testGate(.{ .rate_bytes_per_s = 0, .monthly_bytes = 0, .max_live = 10, .per_subject_live = 10 }, &q);
    defer g.deinit();
    const h: Subject = .{ .kind = .host, .id = "h" };
    const t0: i96 = 1_000 * std.time.ns_per_s;
    var live: Gate.Ticket = .{ .id = 0 };
    try std.testing.expectEqual(Gate.Ask.admitted, try g.admit(io, h, &live, 1_000));
    _ = try g.spend(io, h, 10, t0);
    for (0..3) |_| {
        var refused: Gate.Ticket = .{ .id = 0 };
        try std.testing.expectEqual(Gate.Ask.over_quota, try g.admit(io, h, &refused, 1_000));
        g.leave(io, &refused);
    }
    // The one live socket is still counted.
    try std.testing.expectEqual(@as(u32, 1), g.live_total);
    try std.testing.expectEqual(@as(u32, 1), g.live.get("host:h").?);
    g.leave(io, &live);
    try std.testing.expectEqual(@as(u32, 0), g.live_total);
}

test "a subject's waiting sockets count against its share" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var q: StaticQuotas = .{ .host = big, .account = big };
    var g = testGate(.{ .rate_bytes_per_s = 0, .monthly_bytes = 0, .max_live = 1, .per_subject_live = 2 }, &q);
    defer g.deinit();
    const a: Subject = .{ .kind = .host, .id = "a" };
    const b: Subject = .{ .kind = .host, .id = "b" };
    var full: Gate.Ticket = .{ .id = 0 };
    try std.testing.expectEqual(Gate.Ask.admitted, try g.admit(io, b, &full, 0));
    var t: [4]Gate.Ticket = @splat(.{ .id = 0 });
    try std.testing.expectEqual(Gate.Ask{ .queued = 1 }, try g.admit(io, a, &t[0], 0));
    try std.testing.expectEqual(Gate.Ask{ .queued = 2 }, try g.admit(io, a, &t[1], 0));
    // a has two waiting: a third can't join the line ahead of others.
    try std.testing.expectEqual(Gate.Ask.subject_full, try g.admit(io, a, &t[2], 0));
    try std.testing.expectEqual(Gate.Ask{ .queued = 3 }, try g.admit(io, b, &t[3], 0));
    // The waiting ones keep their places.
    try std.testing.expectEqual(Gate.Ask{ .queued = 1 }, try g.admit(io, a, &t[0], 0));
    g.leave(io, &full);
    try std.testing.expectEqual(Gate.Ask.admitted, try g.admit(io, a, &t[0], 0));
    for (&t) |*x| g.leave(io, x);
    try std.testing.expectEqual(@as(u32, 0), g.live_total);
    try std.testing.expectEqual(@as(usize, 0), g.queue.items.len);
}

test "the ledger keeps a day's and a month's unflushed bytes past midnight" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var q: StaticQuotas = .{ .host = big, .account = big };
    var g = testGate(.{ .rate_bytes_per_s = 0, .monthly_bytes = 0, .max_live = 10, .per_subject_live = 10 }, &q);
    defer g.deinit();
    const h: Subject = .{ .kind = .host, .id = "h" };
    const oct31: i64 = 1_761_955_200 - 60; // 2025-10-31 23:59 UTC
    _ = try g.spend(io, h, 70, @as(i96, oct31) * std.time.ns_per_s);
    // Past midnight (and the month), before any flush.
    _ = try g.spend(io, h, 5, @as(i96, oct31 + 120) * std.time.ns_per_s);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const rows = try g.drain(io, arena.allocator(), oct31 + 120);
    var day_before: i64 = 0;
    var month_before: i64 = 0;
    var total: i64 = 0;
    for (rows) |r| {
        if (std.mem.eql(u8, r.period, "d20392")) day_before += r.bytes;
        if (std.mem.eql(u8, r.period, "m24309")) month_before += r.bytes;
        total += r.bytes;
    }
    try std.testing.expectEqual(@as(i64, 70), day_before);
    try std.testing.expectEqual(@as(i64, 70), month_before);
    try std.testing.expectEqual(@as(i64, 150), total);
    try std.testing.expectEqual(@as(usize, 0), (try g.drain(io, arena.allocator(), oct31 + 120)).len);
}
