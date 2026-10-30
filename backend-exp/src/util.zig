//! Small helpers shared by the routes: time, ids, tokens, hashing, money.
const std = @import("std");

pub fn now(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toSeconds();
}

/// Random UUID v4 as 36 lowercase characters.
pub fn uuid(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    var b: [16]u8 = undefined;
    try io.randomSecure(&b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const h = std.fmt.bytesToHex(b, .lower);
    return std.fmt.allocPrint(arena, "{s}-{s}-{s}-{s}-{s}", .{ h[0..8], h[8..12], h[12..16], h[16..20], h[20..32] });
}

/// `prefix` + 32 random bytes, base64url without padding.
pub fn randomToken(arena: std.mem.Allocator, io: std.Io, prefix: []const u8) ![]const u8 {
    var b: [32]u8 = undefined;
    try io.randomSecure(&b);
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out = try arena.alloc(u8, prefix.len + enc.calcSize(b.len));
    @memcpy(out[0..prefix.len], prefix);
    _ = enc.encode(out[prefix.len..], &b);
    return out;
}

pub fn sha256Hex(arena: std.mem.Allocator, data: []const u8) ![]const u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    const hex = std.fmt.bytesToHex(d, .lower);
    return arena.dupe(u8, &hex);
}

/// USD (as reported by the upstream) to integer micro-USD, rounded up so a
/// non-zero cost never rounds to free.
pub fn usdToMicros(usd: f64) i64 {
    if (usd <= 0) return 0;
    return @intFromFloat(@ceil(usd * 1_000_000.0));
}

pub fn applyMarkup(cost_micros: i64, markup: f64) i64 {
    if (cost_micros <= 0) return 0;
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(cost_micros)) * markup));
}

test usdToMicros {
    try std.testing.expectEqual(@as(i64, 26), usdToMicros(0.0000252));
    try std.testing.expectEqual(@as(i64, 0), usdToMicros(0));
    try std.testing.expectEqual(@as(i64, 115), applyMarkup(100, 1.15));
    try std.testing.expectEqual(@as(i64, 2), applyMarkup(1, 1.15));
}
