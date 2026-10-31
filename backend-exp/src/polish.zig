//! The figure Polish button: `POST /v1/figures/polish {svg, png_base64, brief?}`.
//!
//! One render-then-look round. The app rasterizes the SVG and sends both; a
//! vision model (routing job `polish`) looks at the picture, lists what is
//! visibly wrong, and writes a revised SVG. The revision must pass the same
//! checks as a `render_svg` call and stay a reasonable size, otherwise the
//! original comes back unchanged with the defect list. The call is
//! wallet-preflighted against a worst-case estimate and its output cap is
//! sized so the charge stays under POLISH_MAX_MICROS.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const billing = @import("billing.zig");
const models = @import("models.zig");
const openrouter = @import("openrouter.zig");
const routing = @import("routing.zig");
const tool_check = @import("tool_check.zig");
const util = @import("util.zig");

/// Figures above this are refused (they would not fit the cost cap anyway).
pub const max_svg_bytes = 200 * 1024;
const max_png_bytes = 12 * 1024 * 1024;
/// A revision more than twice the size of the original is rejected.
const growth_limit = 2;
const max_defects = 12;

/// Rough prompt overhead: the instructions plus one ~768 px image.
const prompt_overhead_tokens = 600;
const image_tokens = 1100;
/// The fewest output tokens worth asking for beyond the SVG itself.
const output_slack_tokens = 600;
const max_output_tokens = 16_000;

/// The reviewer's instructions. Our own wording; the defect list follows the
/// common ways hand-written SVG goes wrong (see docs/research/vector-art.md §3).
pub const instructions =
    \\You are reviewing an SVG figure. You get its source code and a PNG of how it actually renders. Judge the picture, not the code.
    \\
    \\First list the visible defects, most important first. Look for: parts that should touch but float apart; shapes hidden behind others or stacked in the wrong order; text that overflows, overlaps or is clipped; light-on-light or dark-on-dark contrast; content cut off by the edge of the canvas; uneven spacing or misalignment; implausible proportions; a subject that is hard to recognize; anything that contradicts the brief. Be concrete: name the element (by id when it has one) and what is wrong.
    \\
    \\Then write the corrected SVG. Fix the defects you listed and change nothing else: keep the subject, composition, palette, viewBox and every existing id; give any new layer a descriptive id. Stay self-contained: no scripts, no external images or fonts, no foreignObject.
    \\
    \\Reply in exactly this form and nothing else:
    \\DEFECTS:
    \\- one defect per line (write "- none" if the figure has no visible problems)
    \\SVG:
    \\<svg ...>...</svg>
;

pub const Reply = struct {
    defects: []const []const u8,
    /// The revised figure, or null when the reply had none.
    svg: ?[]const u8,
};

/// Splits a reviewer reply into its defect list and revised SVG.
pub fn parseReply(arena: std.mem.Allocator, text: []const u8) !Reply {
    const svg_start = std.mem.indexOf(u8, text, "<svg");
    var svg: ?[]const u8 = null;
    if (svg_start) |s| if (std.mem.lastIndexOf(u8, text, "</svg>")) |e| if (e > s) {
        svg = text[s .. e + "</svg>".len];
    };
    // Defects: bullet lines before the SVG (and before an "SVG:" heading).
    var head = text[0 .. svg_start orelse text.len];
    if (std.mem.indexOf(u8, head, "SVG:")) |i| head = head[0..i];
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, head, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len < 2 or !(line[0] == '-' or line[0] == '*' or line[0] == '•')) continue;
        var item = std.mem.trim(u8, line[1..], " \t");
        if (item.len == 0 or std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, item, "."), "none")) continue;
        if (item.len > 300) {
            var n: usize = 300;
            while (n > 0 and (item[n] & 0xC0) == 0x80) n -= 1;
            item = item[0..n];
        }
        if (list.items.len >= max_defects) break;
        try list.append(arena, item);
    }
    return .{ .defects = list.items, .svg = svg };
}

/// Why a revision can't replace the original, or null when it can.
pub fn rejectReason(arena: std.mem.Allocator, original: []const u8, revised: ?[]const u8) !?[]const u8 {
    const svg = revised orelse return "the reviewer returned no SVG";
    if (svg.len > original.len * growth_limit + 2048) return "the revision grew too large";
    const lower = try std.ascii.allocLowerString(arena, svg);
    if (std.mem.indexOf(u8, lower, "<script") != null or std.mem.indexOf(u8, lower, "<foreignobject") != null)
        return "the revision used scripts or foreignObject";
    if (std.mem.indexOf(u8, svg, "<svg") == null or !tool_check.hasViewBox(svg)) return "the revision failed the SVG checks";
    // render_svg's stable-ids rule is for model-written figures; imported
    // ones (Recraft vectors) have none, so only ids the original had must stay.
    if (tool_check.hasId(original) and !tool_check.hasId(svg)) return "the revision dropped the figure's ids";
    return null;
}

/// Rough token count of text (about 3 bytes per token for SVG markup).
fn tokensOf(text: []const u8) i64 {
    return @intCast(text.len / 3 + 1);
}

pub const Budget = struct {
    max_tokens: i64,
    /// Worst-case charge in micro-USD after markup (0 when prices are unknown).
    estimate_micros: i64,
};

/// The output cap for revising `svg_tokens` of SVG with `prompt_tokens` of
/// input, kept under `cap_micros` (after markup) when prices are known.
/// Null when not even the SVG itself fits under the cap.
pub fn budget(prices: ?models.Prices, markup: f64, prompt_tokens: i64, svg_tokens: i64, cap_micros: i64) ?Budget {
    const needed = svg_tokens + output_slack_tokens;
    var out: i64 = @min(max_output_tokens, @divTrunc(svg_tokens * 3, 2) + output_slack_tokens * 2);
    const p = prices orelse return .{ .max_tokens = out, .estimate_micros = 0 };
    const cost = struct {
        fn of(pr: models.Prices, mk: f64, input: i64, output: i64) i64 {
            return util.applyMarkup(util.usdToMicros(pr.cost(.{ .input = input, .cache_read = 0, .cache_write_5m = 0, .cache_write_1h = 0, .output = output })), mk);
        }
    }.of;
    if (p.base.completion > 0) {
        const input_micros = cost(p, markup, prompt_tokens, 0);
        const left_usd = (@as(f64, @floatFromInt(cap_micros - input_micros)) / markup) / 1_000_000.0;
        const affordable: i64 = if (left_usd <= 0) 0 else @intFromFloat(@min(0.99 * left_usd / p.base.completion, @as(f64, max_output_tokens)));
        out = @min(out, affordable);
    }
    if (out < needed) return null;
    return .{ .max_tokens = out, .estimate_micros = cost(p, markup, prompt_tokens, out) };
}

const PolishRequest = struct {
    svg: []const u8,
    /// The SVG rendered to PNG by the app (base64, optionally a data: URL).
    png_base64: []const u8,
    /// What the figure is meant to show (the user's request or its title).
    brief: ?[]const u8 = null,
    /// Usage attribution (the chat conversation id).
    session: ?[]const u8 = null,

    pub const field_rules = .{
        .svg = .{ anole.validate.trim, anole.validate.contains("<svg"), anole.validate.maxBytes(max_svg_bytes).withMessage("is too large to polish") },
        .png_base64 = .{ anole.validate.trim, anole.validate.notBlank, anole.validate.maxBytes(max_png_bytes).withMessage("is too large") },
    };
};

fn userText(arena: std.mem.Allocator, svg: []const u8, brief: ?[]const u8) ![]const u8 {
    const b = std.mem.trim(u8, brief orelse "", " \n\t");
    return std.fmt.allocPrint(arena, "{s}{s}{s}SVG source:\n{s}", .{
        if (b.len > 0) "Brief: " else "",
        if (b.len > 0) b[0..@min(b.len, 2000)] else "",
        if (b.len > 0) "\n\n" else "",
        svg,
    });
}

fn outOfCredits(res: *anole.Response) !void {
    res.status = .payment_required;
    return res.json(.{ .message = "You're out of credits.", .code = "out_of_credits" });
}

fn polish(app: *App, req: *anole.Request, res: *anole.Response) !void {
    // One whole model reply that rewrites an SVG.
    req.setTimeout(.fromSeconds(180));
    const who = try auth.identity(req);
    const body = try req.bind(PolishRequest);
    const svg = body.svg;
    var png = body.png_base64;
    if (std.mem.startsWith(u8, png, "data:")) png = png[(std.mem.indexOfScalar(u8, png, ',') orelse png.len - 1) + 1 ..];
    if (png.len == 0) return req.invalid("png_base64", "polish.png_empty", "must hold the rendered figure");

    const model = routing.modelFor(app.cfg, .polish);
    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    const free = app.catalog.facts(req.io, model).free;
    const text = try userText(req.arena, svg, body.brief);
    const prompt_tokens = tokensOf(instructions) + tokensOf(text) + prompt_overhead_tokens + image_tokens;
    const prices: ?models.Prices = if (free) null else app.catalog.pricesOf(req.io, model);
    const plan = budget(prices, app.cfg.markup, prompt_tokens, tokensOf(svg), app.cfg.polish_max_micros) orelse
        return res.fail(.unprocessable_entity, "This figure is too large to polish within the cost limit.");
    billing.preflight(app, req, who.user_id, free) catch |err| switch (err) {
        error.PaymentRequired => return outOfCredits(res),
        else => return err,
    };
    if (!free and plan.estimate_micros > 0 and try billing.available(app, req, who.user_id) < plan.estimate_micros) return outOfCredits(res);

    const image_url = try std.mem.concat(req.arena, u8, &.{ "data:image/png;base64,", png });
    const req_body = try std.json.Stringify.valueAlloc(req.arena, .{
        .model = model,
        .usage = .{ .include = true },
        .max_tokens = plan.max_tokens,
        .messages = .{
            .{ .role = "system", .content = instructions },
            .{ .role = "user", .content = .{
                .{ .type = "image_url", .image_url = .{ .url = image_url } },
                .{ .type = "text", .text = text },
            } },
        },
    }, .{});
    const s = try app.upstream.post(openrouter.ctxOf(req), "/chat/completions", req_body, &.{});
    defer s.close();
    const raw = try s.reader.allocRemaining(req.arena, .limited(8 * 1024 * 1024));
    if (s.status >= 300) return res.fail(.bad_gateway, openrouter.errorMessage(req.arena, raw));
    const v = std.json.parseFromSliceLeaky(std.json.Value, req.arena, raw, .{}) catch return res.fail(.bad_gateway, "the polish model failed");
    if (v != .object) return res.fail(.bad_gateway, "the polish model failed");

    var charged: i64 = 0;
    if (v.object.get("usage")) |u| if (u == .object) {
        const usage = openrouter.parseUsage(u.object);
        const c = try billing.charge(app, req, who.user_id, .{
            .kind = "polish",
            .model = model,
            .prompt_tokens = usage.prompt_tokens,
            .completion_tokens = usage.completion_tokens,
            .cached_tokens = usage.cached_tokens,
            .cost_usd = usage.cost_usd,
            .session = body.session,
        });
        charged = c.charged_micros;
    };
    const choices = if (v.object.get("choices")) |c| (if (c == .array) c.array.items else &.{}) else &.{};
    if (choices.len == 0) return res.fail(.bad_gateway, "the polish model returned nothing");
    const content = openrouter.jsonString(choices[0].object.get("message") orelse .null, "content") orelse "";
    const reply = try parseReply(req.arena, content);
    const reason = try rejectReason(req.arena, svg, reply.svg);
    const out = if (reason == null) reply.svg.? else svg;
    return res.json(.{
        .svg = out,
        .defects = reply.defects,
        .changed = !std.mem.eql(u8, out, svg),
        .kept_original = reason,
        .model = model,
        .charged_micros = charged,
    });
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    app.group("/v1", .{auth.Authenticate{ .app = state }}).post("/figures/polish", polish);
}

test parseReply {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try parseReply(a,
        \\DEFECTS:
        \\- The #wing-left floats above the body.
        \\* Label text overflows the box
        \\SVG:
        \\```svg
        \\<svg viewBox="0 0 10 10"><g id="bird"/></svg>
        \\```
    );
    try std.testing.expectEqual(@as(usize, 2), r.defects.len);
    try std.testing.expectEqualStrings("The #wing-left floats above the body.", r.defects[0]);
    try std.testing.expectEqualStrings("<svg viewBox=\"0 0 10 10\"><g id=\"bird\"/></svg>", r.svg.?);

    const none = try parseReply(a, "DEFECTS:\n- none\nSVG:\n<svg viewBox=\"0 0 1 1\"/></svg>");
    try std.testing.expectEqual(@as(usize, 0), none.defects.len);
    try std.testing.expect((try parseReply(a, "DEFECTS:\n- broken")).svg == null);
}

test rejectReason {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const orig = "<svg viewBox=\"0 0 9 9\"><rect/></svg>";
    try std.testing.expect((try rejectReason(a, orig, "<svg viewBox=\"0 0 9 9\"><circle/></svg>")) == null);
    try std.testing.expect((try rejectReason(a, orig, null)) != null);
    try std.testing.expect((try rejectReason(a, orig, "<svg><rect/></svg>")) != null);
    try std.testing.expect((try rejectReason(a, orig, "<svg viewBox=\"0 0 9 9\"><script>x</script></svg>")) != null);
    // An imported vector with many paths and no ids may stay without ids.
    const paths = "<svg viewBox=\"0 0 9 9\"><path/><path/><path/><path/><path/><path/><path/></svg>";
    try std.testing.expect((try rejectReason(a, paths, paths)) == null);
    try std.testing.expect((try rejectReason(a, "<svg viewBox=\"0 0 9 9\"><g id=\"a\"/></svg>", paths)) != null);
    const huge = try a.alloc(u8, 4000);
    @memset(huge, ' ');
    try std.testing.expect((try rejectReason(a, orig, try std.mem.concat(a, u8, &.{ "<svg viewBox=\"0 0 9 9\">", huge, "</svg>" }))) != null);
}

test budget {
    // $1 / Mtok in, $5 / Mtok out, markup 1.15.
    const p: models.Prices = .{ .base = .{ .prompt = 1e-6, .completion = 5e-6 } };
    const small = budget(p, 1.15, 3000, 1000, 50_000).?;
    try std.testing.expectEqual(@as(i64, 2700), small.max_tokens);
    try std.testing.expect(small.estimate_micros > 0 and small.estimate_micros <= 50_000);
    // A big figure is capped by the cost limit, not the size rule.
    const big = budget(p, 1.15, 20_000, 8000, 90_000).?;
    try std.testing.expect(big.max_tokens < 13_200 and big.max_tokens >= 8600);
    try std.testing.expect(big.estimate_micros <= 90_000);
    // Too big for the cap.
    try std.testing.expect(budget(p, 1.15, 20_000, 8000, 20_000) == null);
    // Unknown prices: size rule only.
    try std.testing.expectEqual(@as(i64, 2700), budget(null, 1.15, 3000, 1000, 1).?.max_tokens);
}
