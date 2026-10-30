//! Which model runs each side job (titles, follow-ups, compaction, critique,
//! the goal judge). Every job defaults to `UTILITY_MODEL` and can be pointed
//! elsewhere with its own env var (AUX_FOLLOWUPS_MODEL, AUX_TITLE_MODEL, ...).
//! Also serves `POST /v1/aux/title` and the language pin used by follow-ups.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const config = @import("config.zig");
const auth = @import("auth.zig");
const billing = @import("billing.zig");
const openrouter = @import("openrouter.zig");

pub const Job = enum { title, followups, compaction, critique, judge };

/// The model for a side job: its override, else the utility model.
pub fn modelFor(cfg: config.Config, job: Job) []const u8 {
    const override = switch (job) {
        .title => cfg.aux_title_model,
        .followups => cfg.aux_followups_model,
        .compaction => cfg.aux_compaction_model,
        .critique => cfg.aux_critique_model,
        .judge => cfg.aux_judge_model,
    };
    return if (override.len > 0) override else cfg.utility_model;
}

/// A sentence telling the model which language to write in, from the script
/// (and a few stop words for Latin-script languages) of `text`.
pub fn languageNote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const name = languageOf(text);
    if (name) |n| return std.fmt.allocPrint(arena, "Write in {s}, the language of the user's message; do not switch to English or any other language.", .{n});
    return "Write in the same language as the user's message.";
}

const Script = struct { name: []const u8, lo: u21, hi: u21 };
const scripts = [_]Script{
    .{ .name = "Korean", .lo = 0xAC00, .hi = 0xD7AF },
    .{ .name = "Japanese", .lo = 0x3040, .hi = 0x30FF },
    .{ .name = "Chinese", .lo = 0x4E00, .hi = 0x9FFF },
    .{ .name = "Russian", .lo = 0x0400, .hi = 0x04FF },
    .{ .name = "Arabic", .lo = 0x0600, .hi = 0x06FF },
    .{ .name = "Hebrew", .lo = 0x0590, .hi = 0x05FF },
    .{ .name = "Hindi", .lo = 0x0900, .hi = 0x097F },
    .{ .name = "Thai", .lo = 0x0E00, .hi = 0x0E7F },
    .{ .name = "Greek", .lo = 0x0370, .hi = 0x03FF },
};

const stop_words = [_]struct { name: []const u8, words: []const []const u8 }{
    .{ .name = "English", .words = &.{ "the", "and", "is", "what", "how", "you", "of", "to", "why", "are" } },
    .{ .name = "Spanish", .words = &.{ "el", "los", "las", "que", "por", "como", "para", "una", "es", "qué" } },
    .{ .name = "French", .words = &.{ "le", "les", "des", "est", "pour", "que", "une", "comment", "pourquoi", "dans" } },
    .{ .name = "German", .words = &.{ "der", "die", "das", "und", "ist", "nicht", "wie", "ich", "ein", "warum" } },
    .{ .name = "Portuguese", .words = &.{ "os", "uma", "não", "como", "para", "são", "você", "isso", "porque", "com" } },
    .{ .name = "Italian", .words = &.{ "il", "gli", "che", "non", "come", "per", "una", "sono", "perché", "della" } },
};

/// The language of `text` when it is clear, else null. Kana wins over Han
/// (Japanese mixes both); Latin languages need at least two stop-word hits.
pub fn languageOf(text: []const u8) ?[]const u8 {
    var counts: [scripts.len]usize = @splat(0);
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var seen: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (seen > 4000) break;
        seen += 1;
        for (scripts, 0..) |s, i| if (cp >= s.lo and cp <= s.hi) {
            counts[i] += 1;
            break;
        };
    }
    // Kana (index 1) beats Han (index 2).
    if (counts[1] > 0) return "Japanese";
    var best: ?usize = null;
    for (counts, 0..) |c, i| if (c > 0 and (best == null or c > counts[best.?])) {
        best = i;
    };
    if (best) |b| return scripts[b].name;

    var hits: [stop_words.len]usize = @splat(0);
    var words = std.mem.tokenizeAny(u8, text[0..@min(text.len, 4000)], " \t\r\n.,;:!?¿¡()\"'");
    while (words.next()) |w| {
        var lower_buf: [24]u8 = undefined;
        if (w.len > lower_buf.len) continue;
        const lower = std.ascii.lowerString(&lower_buf, w);
        for (stop_words, 0..) |sw, i| for (sw.words) |x| if (std.mem.eql(u8, lower, x)) {
            hits[i] += 1;
        };
    }
    var top: usize = 0;
    for (hits, 0..) |h, i| if (h > hits[top]) {
        top = i;
    };
    return if (hits[top] >= 2) stop_words[top].name else null;
}

/// The title prompt for a conversation's opening messages.
pub fn titlePrompt(arena: std.mem.Allocator, user: []const u8, assistant: []const u8) ![]const u8 {
    const note = try languageNote(arena, user);
    return std.fmt.allocPrint(arena,
        \\User: {s}
        \\
        \\Assistant (excerpt): {s}
        \\
        \\Write a title for this conversation: at most 6 words, no quotes, no trailing punctuation. {s}
        \\Reply with only the title.
    , .{ user[0..@min(user.len, 1000)], assistant[0..@min(assistant.len, 1000)], note });
}

/// Cleans a model's title: first line, quotes and markdown trimmed, capped.
pub fn cleanTitle(raw: []const u8) []const u8 {
    var t = raw;
    if (std.mem.indexOfScalar(u8, t, '\n')) |i| t = t[0..i];
    t = std.mem.trim(u8, t, " \t\r\"'`*#“”");
    t = std.mem.trimEnd(u8, t, ".。!?");
    if (t.len > 80) {
        var n: usize = 80;
        while (n > 0 and (t[n] & 0xC0) == 0x80) n -= 1;
        t = t[0..n];
    }
    return t;
}

const Message = struct { role: []const u8, content: std.json.Value };
const TitleRequest = struct { messages: []const Message, session: ?[]const u8 = null };

fn textOf(v: std.json.Value) []const u8 {
    if (v == .string) return v.string;
    if (v == .array) for (v.array.items) |p| if (p == .object) {
        if (openrouter.jsonString(p, "text")) |t| return t;
    };
    return "";
}

fn title(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth.identity(req);
    const body = try req.bind(TitleRequest);
    var user: []const u8 = "";
    var assistant: []const u8 = "";
    for (body.messages) |m| {
        if (user.len == 0 and std.mem.eql(u8, m.role, "user")) user = textOf(m.content);
        if (assistant.len == 0 and std.mem.eql(u8, m.role, "assistant")) assistant = textOf(m.content);
    }
    if (std.mem.trim(u8, user, " \n\t").len == 0) return res.fail(.unprocessable_entity, "messages need a user message");
    const model = modelFor(app.cfg, .title);
    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    billing.preflight(app, req, who.user_id, app.catalog.facts(req.io, model).free) catch |err| switch (err) {
        error.PaymentRequired => {
            res.status = .payment_required;
            return res.json(.{ .message = "You're out of credits.", .code = "out_of_credits" });
        },
        else => return err,
    };
    const prompt = try titlePrompt(req.arena, user, assistant);
    const req_body = try std.json.Stringify.valueAlloc(req.arena, .{
        .model = model,
        .usage = .{ .include = true },
        .max_tokens = 40,
        .messages = .{.{ .role = "user", .content = prompt }},
    }, .{});
    const s = try app.upstream.post(req, "/chat/completions", req_body, &.{});
    defer s.close();
    const raw = try s.reader.allocRemaining(req.arena, .limited(1024 * 1024));
    if (s.status >= 300) return res.fail(.bad_gateway, "the title model failed");
    const v = std.json.parseFromSliceLeaky(std.json.Value, req.arena, raw, .{}) catch return res.fail(.bad_gateway, "the title model failed");
    var charged: i64 = 0;
    if (v.object.get("usage")) |u| if (u == .object) {
        const usage = openrouter.parseUsage(u.object);
        const c = try billing.charge(app, req, who.user_id, .{ .kind = "title", .model = model, .prompt_tokens = usage.prompt_tokens, .completion_tokens = usage.completion_tokens, .cost_usd = usage.cost_usd, .session = body.session });
        charged = c.charged_micros;
    };
    const choices = (v.object.get("choices") orelse return res.fail(.bad_gateway, "the title model failed")).array.items;
    if (choices.len == 0) return res.fail(.bad_gateway, "the title model failed");
    const content = openrouter.jsonString(choices[0].object.get("message") orelse return res.fail(.bad_gateway, "the title model failed"), "content") orelse "";
    const t = cleanTitle(content);
    if (t.len == 0) return res.fail(.bad_gateway, "the title model returned nothing");
    return res.json(.{ .title = t, .model = model, .charged_micros = charged });
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    app.group("/v1", .{auth.Authenticate{ .app = state }}).post("/aux/title", title);
}

test modelFor {
    var cfg: config.Config = .{ .jwt_secret = .init("x"), .openrouter_api_key = .init("y") };
    try std.testing.expectEqualStrings(cfg.utility_model, modelFor(cfg, .followups));
    cfg.aux_followups_model = "openai/gpt-5.4-mini";
    try std.testing.expectEqualStrings("openai/gpt-5.4-mini", modelFor(cfg, .followups));
    try std.testing.expectEqualStrings(cfg.utility_model, modelFor(cfg, .judge));
}

test languageOf {
    try std.testing.expectEqualStrings("Japanese", languageOf("Zigについて教えてください").?);
    try std.testing.expectEqualStrings("Chinese", languageOf("什么是编译期").?);
    try std.testing.expectEqualStrings("Korean", languageOf("안녕하세요 질문이 있어요").?);
    try std.testing.expectEqualStrings("Russian", languageOf("Как это работает?").?);
    try std.testing.expectEqualStrings("English", languageOf("What is the best way to learn it?").?);
    try std.testing.expectEqualStrings("Spanish", languageOf("¿Cómo funciona el compilador para los niños?").?);
    try std.testing.expectEqualStrings("German", languageOf("Wie funktioniert das und warum ist es so?").?);
    try std.testing.expect(languageOf("zig") == null);
}

test languageNote {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(std.mem.indexOf(u8, try languageNote(a, "日本語で答えて"), "Japanese") != null);
    try std.testing.expect(std.mem.indexOf(u8, try languageNote(a, "zig"), "same language") != null);
}

test cleanTitle {
    try std.testing.expectEqualStrings("Learning Zig", cleanTitle("\"Learning Zig.\"\nextra"));
    try std.testing.expectEqualStrings("Zigを学ぶ", cleanTitle("**Zigを学ぶ。**"));
}
