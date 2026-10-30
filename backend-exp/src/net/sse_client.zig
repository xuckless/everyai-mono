//! Incremental Server-Sent Events parser for outbound streams (WHATWG
//! "event stream interpretation"), reading from any `std.Io.Reader` — such as
//! `anole.http.Client` responses fetched with `.stream = true`. Lines of any
//! length (a base64 image in one `data:` line) are handled. Candidate for
//! upstreaming into Anole (`anole.sse.Client`).
const std = @import("std");

pub const Event = struct {
    /// "message" when the stream named none.
    event: []const u8,
    /// `data:` lines joined with '\n'. Valid until the next `next` call.
    data: []const u8,
    /// The last `id:` seen, if any.
    id: ?[]const u8,
};

pub const Parser = struct {
    reader: *std.Io.Reader,
    line: std.Io.Writer.Allocating,
    data: std.Io.Writer.Allocating,
    event: std.Io.Writer.Allocating,
    last_id: std.Io.Writer.Allocating,
    has_id: bool = false,
    has_data: bool = false,
    first_line: bool = true,

    pub fn init(gpa: std.mem.Allocator, reader: *std.Io.Reader) Parser {
        return .{
            .reader = reader,
            .line = .init(gpa),
            .data = .init(gpa),
            .event = .init(gpa),
            .last_id = .init(gpa),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.line.deinit();
        self.data.deinit();
        self.event.deinit();
        self.last_id.deinit();
    }

    /// The next dispatched event, or null at the end of the stream. An event
    /// cut off by the end of the stream (no blank line after it) is dropped,
    /// as the spec says.
    pub fn next(self: *Parser) !?Event {
        self.data.clearRetainingCapacity();
        self.event.clearRetainingCapacity();
        self.has_data = false;
        while (true) {
            self.line.clearRetainingCapacity();
            _ = try self.reader.streamDelimiterEnding(&self.line.writer, '\n');
            const at_end = blk: {
                _ = self.reader.peekByte() catch |err| switch (err) {
                    error.EndOfStream => break :blk true,
                    else => |e| return e,
                };
                self.reader.toss(1); // the '\n'
                break :blk false;
            };
            if (at_end and self.line.written().len == 0) return null;
            if (at_end) return null; // unterminated last line: incomplete event

            var line = self.line.written();
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (self.first_line) {
                self.first_line = false;
                if (std.mem.startsWith(u8, line, "\xEF\xBB\xBF")) line = line[3..];
            }

            if (line.len == 0) {
                if (!self.has_data) {
                    self.event.clearRetainingCapacity();
                    continue;
                }
                return .{
                    .event = if (self.event.written().len == 0) "message" else self.event.written(),
                    .data = self.data.written(),
                    .id = if (self.has_id) self.last_id.written() else null,
                };
            }
            if (line[0] == ':') continue; // comment / keep-alive

            const colon = std.mem.indexOfScalar(u8, line, ':');
            const field = if (colon) |c| line[0..c] else line;
            var value: []const u8 = if (colon) |c| line[c + 1 ..] else "";
            if (value.len > 0 and value[0] == ' ') value = value[1..];

            if (std.mem.eql(u8, field, "data")) {
                if (self.has_data) try self.data.writer.writeByte('\n');
                try self.data.writer.writeAll(value);
                self.has_data = true;
            } else if (std.mem.eql(u8, field, "event")) {
                self.event.clearRetainingCapacity();
                try self.event.writer.writeAll(value);
            } else if (std.mem.eql(u8, field, "id")) {
                if (std.mem.indexOfScalar(u8, value, 0) == null) {
                    self.last_id.clearRetainingCapacity();
                    try self.last_id.writer.writeAll(value);
                    self.has_id = true;
                }
            }
            // `retry:` and unknown fields are ignored.
        }
    }
};

fn collect(input: []const u8, out: *std.ArrayList([2][]const u8), arena: std.mem.Allocator) !void {
    var r: std.Io.Reader = .fixed(input);
    var p = Parser.init(std.testing.allocator, &r);
    defer p.deinit();
    while (try p.next()) |e| try out.append(arena, .{ try arena.dupe(u8, e.event), try arena.dupe(u8, e.data) });
}

test "parses OpenRouter-style chunks, comments, multi-line data and CRLF" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList([2][]const u8) = .empty;
    try collect(
        ": OPENROUTER PROCESSING\n\n" ++
            "data: {\"a\":1}\n\n" ++
            "event: delta\r\ndata: one\r\ndata: two\r\n\r\n" ++
            "data:[DONE]\n\n" ++
            "data: cut off",
        &out,
        arena,
    );
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("message", out.items[0][0]);
    try std.testing.expectEqualStrings("{\"a\":1}", out.items[0][1]);
    try std.testing.expectEqualStrings("delta", out.items[1][0]);
    try std.testing.expectEqualStrings("one\ntwo", out.items[1][1]);
    try std.testing.expectEqualStrings("[DONE]", out.items[2][1]);
}

test "a line longer than any buffer" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const big: [70_000]u8 = @splat('x');
    const input = try std.mem.concat(arena, u8, &.{ "data: ", &big, "\n\n" });
    var out: std.ArrayList([2][]const u8) = .empty;
    try collect(input, &out, arena);
    try std.testing.expectEqual(big.len, out.items[0][1].len);
}
