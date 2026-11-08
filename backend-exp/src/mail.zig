//! Outbound email: the one external service sign-in depends on.
//!
//! `Mailer` is a small vtable (like `openrouter.Upstream`) with three
//! implementations:
//! - `Resend`: Resend's HTTPS API (`POST https://api.resend.com/emails`).
//!   HTTPS, not SMTP: GCP blocks outbound port 25.
//! - `Log`: no `RESEND_API_KEY` in development; the message goes to the
//!   console so a local sign-in still works. Production never uses it: a
//!   server without a mail key answers 503 `mail_unavailable` instead of
//!   writing sign-in codes into its logs.
//! - `Fake`: tests read what was sent.
const std = @import("std");
const anole = @import("anole");

pub const Mail = struct {
    to: []const u8,
    subject: []const u8,
    text: []const u8,
    html: []const u8,
    /// Resend dedups a retried POST with the same key.
    idempotency_key: []const u8,
};

pub const Error = error{MailFailed};

pub const Mailer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, req: *anole.Request, mail: Mail) anyerror!void,
    };

    pub fn send(self: Mailer, req: *anole.Request, mail: Mail) !void {
        return self.vtable.send(self.ptr, req, mail);
    }
};

pub const Resend = struct {
    api_key: []const u8,
    from: []const u8,
    base_url: []const u8 = "https://api.resend.com",

    pub fn mailer(self: *Resend) Mailer {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: *anole.Request, m: Mail) anyerror!void {
        const self: *Resend = @ptrCast(@alignCast(ptr));
        const body = try std.json.Stringify.valueAlloc(req.arena, .{
            .from = self.from,
            .to = [_][]const u8{m.to},
            .subject = m.subject,
            .text = m.text,
            .html = m.html,
        }, .{});
        var r = try anole.client(req).fetch(try std.fmt.allocPrint(req.arena, "{s}/emails", .{self.base_url}), .{
            .method = .post,
            .headers = &.{
                .{ "Authorization", try std.fmt.allocPrint(req.arena, "Bearer {s}", .{self.api_key}) },
                .{ "Content-Type", "application/json" },
                .{ "Idempotency-Key", m.idempotency_key },
            },
            .body = body,
        });
        defer r.deinit();
        const status = @backingInt(r.status());
        if (status >= 300) {
            // Never log the message itself (it carries the sign-in code).
            req.log().err("resend send failed", .{ .status = status, .body = r.body() catch "" });
            return error.MailFailed;
        }
    }
};

pub const Log = struct {
    pub fn mailer(self: *Log) Mailer {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(_: *anyopaque, _: *anole.Request, m: Mail) anyerror!void {
        std.log.info("mail (no RESEND_API_KEY, development) to {s}: {s}\n{s}", .{ m.to, m.subject, m.text });
    }
};

/// Records every message (copied, the request arena goes away).
pub const Fake = struct {
    gpa: std.mem.Allocator,
    sent: std.ArrayList(Mail) = .empty,
    fail: bool = false,
    mutex: std.Io.Mutex = .init,

    pub fn mailer(self: *Fake) Mailer {
        return .{ .ptr = self, .vtable = &.{ .send = send } };
    }

    fn send(ptr: *anyopaque, req: *anole.Request, m: Mail) anyerror!void {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        if (self.fail) return error.MailFailed;
        self.mutex.lockUncancelable(req.io);
        defer self.mutex.unlock(req.io);
        try self.sent.append(self.gpa, .{
            .to = try self.gpa.dupe(u8, m.to),
            .subject = try self.gpa.dupe(u8, m.subject),
            .text = try self.gpa.dupe(u8, m.text),
            .html = try self.gpa.dupe(u8, m.html),
            .idempotency_key = try self.gpa.dupe(u8, m.idempotency_key),
        });
    }

    pub fn last(self: *Fake) ?Mail {
        return if (self.sent.items.len == 0) null else self.sent.items[self.sent.items.len - 1];
    }

    pub fn deinit(self: *Fake) void {
        for (self.sent.items) |m| {
            self.gpa.free(m.to);
            self.gpa.free(m.subject);
            self.gpa.free(m.text);
            self.gpa.free(m.html);
            self.gpa.free(m.idempotency_key);
        }
        self.sent.deinit(self.gpa);
    }
};

/// Escapes text for HTML element content and attribute values.
pub fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

pub fn escapeAlloc(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeEscaped(&out.writer, s);
    return out.written();
}

test "html escaping" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeEscaped(&w, "<a href=\"x\">Tom & 'Jerry'</a>");
    try std.testing.expectEqualStrings("&lt;a href=&quot;x&quot;&gt;Tom &amp; &#39;Jerry&#39;&lt;/a&gt;", w.buffered());
}
