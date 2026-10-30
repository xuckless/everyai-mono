//! The chat's web tools: `web_search` (OpenRouter's web plugin on the utility
//! model, read back as citations), paged `web_fetch` windows, and the source
//! ledger that numbers every web source of a turn once.
//!
//! The ledger is the single owner of citation numbers: the search plugin's
//! annotations, `web_search` results and fetched pages all go through it, so
//! a URL keeps its number however often it comes back, and the app's
//! `sources` events carry only sources it has not seen (appended in number
//! order, so `[n]` is the n-th chip).
const std = @import("std");
const openrouter = @import("openrouter.zig");
const safe_fetch = @import("net/safe_fetch.zig");

const Source = openrouter.Source;

// ------------------------------------------------------------------ ledger

pub const Ledger = struct {
    list: std.ArrayList(Source) = .empty,

    pub const Entry = struct {
        /// The citation number, from 1.
        n: usize,
        /// First time this turn: the app has not been sent it yet.
        new: bool,
    };

    /// The number of `source`'s URL, adding it when it is new.
    pub fn add(self: *Ledger, arena: std.mem.Allocator, source: Source) !Entry {
        const key = normalized(source.url);
        for (self.list.items, 1..) |s, n| if (std.mem.eql(u8, normalized(s.url), key)) return .{ .n = n, .new = false };
        try self.list.append(arena, source);
        return .{ .n = self.list.items.len, .new = true };
    }

    /// Adds every source; returns the ones that were new, in number order.
    /// The slice is valid until the next add.
    pub fn addAll(self: *Ledger, arena: std.mem.Allocator, sources: []const Source) ![]const Source {
        const first = self.list.items.len;
        for (sources) |s| _ = try self.add(arena, s);
        return self.list.items[first..];
    }
};

/// A URL without its fragment or a trailing slash, for deduplication.
fn normalized(url: []const u8) []const u8 {
    var u = url;
    if (std.mem.indexOfScalar(u8, u, '#')) |i| u = u[0..i];
    while (u.len > 0 and u[u.len - 1] == '/') u = u[0 .. u.len - 1];
    return u;
}

// ------------------------------------------------------------------ web_search

pub const default_results = 5;
pub const max_results = 10;

/// The non-streaming request that runs one search: the query as the only
/// message (the plugin searches for the last user message), a tiny reply cap,
/// since only the citations are read.
pub fn searchBody(arena: std.mem.Allocator, model: []const u8, engine: []const u8, query: []const u8, limit: usize) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, .{
        .model = model,
        .usage = .{ .include = true },
        .max_tokens = 32,
        .plugins = .{.{ .id = "web", .engine = engine, .max_results = limit }},
        .messages = .{.{ .role = "user", .content = query }},
    }, .{});
}

pub const SearchReply = struct {
    sources: []const Source,
    usage: ?openrouter.Usage,
};

/// The results of a search call: the `url_citation` annotations on the reply,
/// deduplicated, in the order given.
pub fn parseSearch(arena: std.mem.Allocator, raw: []const u8) !SearchReply {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{});
    if (v != .object) return error.BadReply;
    const usage: ?openrouter.Usage = if (v.object.get("usage")) |u| (if (u == .object) openrouter.parseUsage(u.object) else null) else null;
    var out: std.ArrayList(Source) = .empty;
    const choices = v.object.get("choices") orelse return .{ .sources = &.{}, .usage = usage };
    if (choices != .array or choices.array.items.len == 0) return .{ .sources = &.{}, .usage = usage };
    const choice = choices.array.items[0];
    if (choice != .object) return error.BadReply;
    const message = choice.object.get("message") orelse return .{ .sources = &.{}, .usage = usage };
    if (message != .object) return error.BadReply;
    const ann = message.object.get("annotations") orelse return .{ .sources = &.{}, .usage = usage };
    if (ann != .array) return .{ .sources = &.{}, .usage = usage };
    for (ann.array.items) |a| {
        if (a != .object) continue;
        const cit = a.object.get("url_citation") orelse continue;
        if (cit != .object) continue;
        const url = openrouter.jsonStr(cit.object.get("url")) orelse continue;
        const seen = for (out.items) |s| {
            if (std.mem.eql(u8, s.url, url)) break true;
        } else false;
        if (seen) continue;
        const snippet = openrouter.jsonStr(cit.object.get("content"));
        try out.append(arena, .{
            .url = url,
            .title = openrouter.jsonStr(cit.object.get("title")) orelse url,
            .snippet = if (snippet) |s| clip(s, 300) else null,
        });
    }
    return .{ .sources = out.items, .usage = usage };
}

/// What the model reads back from `web_search`: one numbered entry per result
/// (the numbers it cites), fenced as untrusted since titles and snippets come
/// from the web.
pub fn formatResults(arena: std.mem.Allocator, query: []const u8, numbered: []const Numbered) ![]const u8 {
    if (numbered.len == 0) return std.fmt.allocPrint(arena, "No results for \"{s}\". Try other words, or a broader query.", .{query});
    var body: std.Io.Writer.Allocating = .init(arena);
    for (numbered, 0..) |r, i| {
        if (i > 0) try body.writer.writeByte('\n');
        try body.writer.print("[{d}] {s}\n{s}\n", .{ r.n, r.source.title, r.source.url });
        if (r.source.snippet) |s| try body.writer.print("{s}\n", .{s});
    }
    const fenced = try safe_fetch.wrapUntrusted(arena, "web_search", body.written());
    return std.fmt.allocPrint(arena, "{d} result(s) for \"{s}\". Cite them by their numbers, e.g. [{d}]. Snippets are short: call web_fetch on a URL to read the page.\n{s}", .{ numbered.len, query, numbered[0].n, fenced });
}

pub const Numbered = struct { n: usize, source: Source };

// ------------------------------------------------------------------ web_fetch paging

pub const default_chars = 20_000;
pub const max_chars = 40_000;
pub const min_chars = 1_000;

pub const Window = struct {
    text: []const u8,
    start: usize,
    end: usize,
    total: usize,

    /// Where the next window starts, if the text goes on.
    pub fn nextOffset(self: Window) ?usize {
        return if (self.end < self.total) self.end else null;
    }
};

/// At most `limit` bytes of `text` from `offset`, both ends moved back to a
/// UTF-8 boundary and the end, when it cuts, to the last space in its final
/// 200 bytes (so words stay whole across pages).
pub fn window(text: []const u8, offset: usize, limit: usize) Window {
    const start = charStart(text, @min(offset, text.len));
    var end = @min(text.len, start + limit);
    if (end < text.len) {
        end = charStart(text, end);
        const floor = if (end > start + 200) end - 200 else start;
        if (std.mem.lastIndexOfScalar(u8, text[floor..end], ' ')) |i| {
            if (floor + i > start) end = floor + i + 1;
        }
        if (end <= start) end = @min(text.len, start + limit);
    }
    return .{ .text = text[start..end], .start = start, .end = end, .total = text.len };
}

fn charStart(text: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and j < text.len and text[j] & 0xc0 == 0x80) j -= 1;
    return j;
}

/// The paging line after a fetched window, outside the untrusted fence.
pub fn pagingNote(arena: std.mem.Allocator, n: usize, w: Window) ![]const u8 {
    if (w.nextOffset()) |next| return std.fmt.allocPrint(arena, "Source [{d}]. Showing characters {d}-{d} of {d}. next_offset: {d} (call web_fetch with this offset to read on).", .{ n, w.start, w.end, w.total, next });
    if (w.start > 0) return std.fmt.allocPrint(arena, "Source [{d}]. Showing characters {d}-{d} of {d}: the end of the page.", .{ n, w.start, w.end, w.total });
    return std.fmt.allocPrint(arena, "Source [{d}]. The whole page ({d} characters).", .{ n, w.total });
}

/// The `<title>` of an HTML page, whitespace collapsed; null when absent.
pub fn titleOf(arena: std.mem.Allocator, html: []const u8) !?[]const u8 {
    const head = html[0..@min(html.len, 64 * 1024)];
    const open = indexOfIgnoreCase(head, "<title") orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, head, open, '>') orelse return null;
    const close = indexOfIgnoreCase(head[gt..], "</title") orelse return null;
    const raw = head[gt + 1 .. gt + close];
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, raw, " \t\r\n");
    while (it.next()) |word| {
        if (out.items.len > 0) try out.append(arena, ' ');
        try out.appendSlice(arena, word);
    }
    if (out.items.len == 0) return null;
    return clip(out.items, 200);
}

/// `s` cut to at most `n` bytes on a UTF-8 boundary.
pub fn clip(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    return s[0..charStart(s, n)];
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

// ------------------------------------------------------------------ tests

test "ledger: stable numbers, duplicates (fragment, trailing slash) keep theirs, only new ones are returned" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l: Ledger = .{};
    const fresh = try l.addAll(a, &.{ .{ .url = "https://a.dev/", .title = "A" }, .{ .url = "https://b.dev", .title = "B" } });
    try std.testing.expectEqual(@as(usize, 2), fresh.len);
    const again = try l.addAll(a, &.{ .{ .url = "https://b.dev#top", .title = "B" }, .{ .url = "https://c.dev", .title = "C" }, .{ .url = "https://a.dev", .title = "A" } });
    try std.testing.expectEqual(@as(usize, 1), again.len);
    try std.testing.expectEqualStrings("https://c.dev", again[0].url);
    try std.testing.expectEqual(Ledger.Entry{ .n = 2, .new = false }, try l.add(a, .{ .url = "https://b.dev/", .title = "B" }));
    try std.testing.expectEqual(Ledger.Entry{ .n = 4, .new = true }, try l.add(a, .{ .url = "https://d.dev", .title = "D" }));
}

test "parseSearch reads url_citation annotations, dedups, clips snippets, reads usage" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseSearch(a,
        \\{"choices":[{"message":{"role":"assistant","content":"ok","annotations":[
        \\{"type":"url_citation","url_citation":{"url":"https://ziglang.org","title":"Zig","content":"Zig is a language"}},
        \\{"type":"url_citation","url_citation":{"url":"https://ziglang.org","title":"Zig again"}},
        \\{"type":"url_citation","url_citation":{"url":"https://x.dev/no-title"}}]}}],
        \\"usage":{"prompt_tokens":300,"completion_tokens":4,"cost":0.02}}
    );
    try std.testing.expectEqual(@as(usize, 2), r.sources.len);
    try std.testing.expectEqualStrings("Zig is a language", r.sources[0].snippet.?);
    try std.testing.expectEqualStrings("https://x.dev/no-title", r.sources[1].title);
    try std.testing.expectEqual(@as(f64, 0.02), r.usage.?.cost_usd);
    const empty = try parseSearch(a, "{\"choices\":[{\"message\":{\"content\":\"nothing\"}}]}");
    try std.testing.expectEqual(@as(usize, 0), empty.sources.len);
}

test "searchBody asks the web plugin with the query as the only message" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const body = try searchBody(arena.allocator(), "google/gemini-3.5-flash-lite", "exa", "zig 0.17 release", 3);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"plugins\":[{\"id\":\"web\",\"engine\":\"exa\",\"max_results\":3}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"zig 0.17 release\"") != null);
}

test "formatResults numbers entries and fences them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try formatResults(a, "zig", &.{ .{ .n = 3, .source = .{ .url = "https://z.dev", .title = "Z", .snippet = "snip" } }, .{ .n = 4, .source = .{ .url = "https://y.dev", .title = "Y" } } });
    try std.testing.expect(std.mem.indexOf(u8, text, "[3] Z\nhttps://z.dev\nsnip") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[4] Y") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "<untrusted_tool_result source=\"web_search\">") != null);
    try std.testing.expect(std.mem.startsWith(u8, try formatResults(a, "zig", &.{}), "No results"));
}

test "window pages on word and UTF-8 boundaries and reports next_offset" {
    const text = "alpha beta gamma delta";
    const w1 = window(text, 0, 13);
    try std.testing.expectEqualStrings("alpha beta ", w1.text);
    try std.testing.expectEqual(@as(?usize, 11), w1.nextOffset());
    const w2 = window(text, w1.end, 13);
    try std.testing.expectEqualStrings("gamma delta", w2.text);
    try std.testing.expectEqual(@as(?usize, null), w2.nextOffset());
    // Past the end: empty, nothing next.
    try std.testing.expectEqual(@as(usize, 0), window(text, 99, 10).text.len);
    // A cut inside a multi-byte character moves back to its start.
    const accents = "ééééé"; // 2 bytes each, no spaces
    const w3 = window(accents, 0, 5);
    try std.testing.expectEqualStrings("éé", w3.text);
    try std.testing.expectEqualStrings("ééé", window(accents, w3.end, 6).text);
    // An offset inside a character starts at that character.
    try std.testing.expectEqual(@as(usize, 2), window(accents, 3, 4).start);
}

test "pagingNote and titleOf" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const note = try pagingNote(a, 2, window("one two three", 0, 8));
    try std.testing.expect(std.mem.indexOf(u8, note, "next_offset: 8") != null);
    try std.testing.expect(std.mem.startsWith(u8, note, "Source [2]."));
    try std.testing.expect(std.mem.indexOf(u8, try pagingNote(a, 1, window("short", 0, 100)), "whole page") != null);
    try std.testing.expectEqualStrings("Zig Docs", (try titleOf(a, "<html><head><TITLE class=x>\n Zig  Docs </title>")).?);
    try std.testing.expect((try titleOf(a, "<p>no title</p>")) == null);
}
