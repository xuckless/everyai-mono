//! Shared test helpers: signing in the way the app does (magic link, the
//! emailed code read from a fake mailer).
const std = @import("std");
const app_main = @import("app");

pub const Asked = struct { request_id: []const u8, request_secret: []const u8, expires_at: i64 };
pub const Signed = struct { status: []const u8, tokens: ?struct { access_token: []const u8, refresh_token: []const u8, user: struct { id: []const u8, email: []const u8 } } = null };

/// The 6-digit code in a sign-in mail's text.
pub fn codeIn(m: app_main.mail.Mail) []const u8 {
    const at = std.mem.indexOf(u8, m.text, "Your code: ").? + "Your code: ".len;
    return m.text[at .. at + 6];
}

/// The link token in a sign-in mail's text.
pub fn tokenIn(m: app_main.mail.Mail) []const u8 {
    const at = std.mem.indexOf(u8, m.text, "/auth/l/").? + "/auth/l/".len;
    const end = std.mem.indexOfScalarPos(u8, m.text, at, '\n') orelse m.text.len;
    return m.text[at..end];
}

/// Asks for a sign-in mail and redeems its code; returns "Bearer <access>".
pub fn signIn(t: anytype, mails: *app_main.mail.Fake, a: std.mem.Allocator, email: []const u8) ![]const u8 {
    var asked = try t.post("/v1/auth/magic", .{ .json = .{ .email = email, .device_name = "Test" } });
    defer asked.deinit();
    try asked.expectStatus(.accepted);
    const req = try asked.json(Asked);
    const code = codeIn(mails.last().?);
    var done = try t.post("/v1/auth/magic/code", .{ .json = .{ .request_id = req.request_id, .request_secret = req.request_secret, .code = code } });
    defer done.deinit();
    try done.expectStatus(.ok);
    const signed = try done.json(Signed);
    return std.fmt.allocPrint(a, "Bearer {s}", .{signed.tokens.?.access_token});
}
