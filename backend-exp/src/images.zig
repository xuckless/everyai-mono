//! Image generation through OpenRouter's image endpoint (`POST /images`).
//! Serves `POST /v1/images` and the chat `generate_image` tool.
//!
//! One request shape covers generating, editing and vector art: earlier images
//! go in as `input_references` (data: or https: URLs), and a Recraft vector
//! model with `output_format:"svg"` returns real SVG (`mime` image/svg+xml).
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const billing = @import("billing.zig");
const openrouter = @import("openrouter.zig");
const util = @import("util.zig");

pub const Image = struct {
    mime: []const u8,
    /// Base64, no data: prefix. For SVG, the SVG text.
    data: []const u8,
};

pub const Options = struct {
    model: []const u8,
    prompt: []const u8,
    aspect_ratio: ?[]const u8 = null,
    /// How many images (1-10).
    n: u8 = 1,
    quality: ?[]const u8 = null,
    /// png | jpeg | webp | svg (svg on vector models only).
    output_format: ?[]const u8 = null,
    /// Earlier images to edit or follow, as data: or https: URLs.
    references: []const []const u8 = &.{},
};

/// Vector (SVG) models: Recraft's `*-vector` slugs.
pub fn isVectorModel(model: []const u8) bool {
    return std.mem.startsWith(u8, model, "recraft/") and std.mem.endsWith(u8, model, "-vector");
}

/// The requested output format: vector models default to SVG.
fn formatOf(o: Options) ?[]const u8 {
    if (o.output_format) |f| return f;
    return if (isVectorModel(o.model)) "svg" else null;
}

/// A ceiling on what one image costs upstream, in micro-dollars. The catalog
/// lists no per-image output price, so this covers the dearer image models
/// (high quality is several times the standard price).
const image_ceiling_micros: i64 = 100_000;
const image_ceiling_high_micros: i64 = 300_000;

/// The most a request can cost after markup: `n` images at the ceiling.
pub fn worstCaseMicros(o: Options, markup: f64) i64 {
    const high = if (o.quality) |q| std.mem.eql(u8, q, "high") or std.mem.eql(u8, q, "hd") else false;
    const each = if (high) image_ceiling_high_micros else image_ceiling_micros;
    const n: i64 = @max(1, @min(o.n, 10));
    return util.applyMarkup(n * each, markup);
}

/// The upstream request body.
pub fn requestBody(arena: std.mem.Allocator, o: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    var s: std.json.Stringify = .{ .writer = &out.writer };
    try s.beginObject();
    try s.objectField("model");
    try s.write(o.model);
    try s.objectField("prompt");
    try s.write(o.prompt);
    try s.objectField("n");
    try s.write(@max(1, @min(o.n, 10)));
    if (o.aspect_ratio) |v| {
        try s.objectField("aspect_ratio");
        try s.write(v);
    }
    if (o.quality) |v| {
        try s.objectField("quality");
        try s.write(v);
    }
    const format = formatOf(o);
    if (format) |v| {
        try s.objectField("output_format");
        try s.write(v);
    }
    if (o.references.len > 0) {
        try s.objectField("input_references");
        try s.beginArray();
        for (o.references) |url| try s.write(.{ .type = "image_url", .image_url = .{ .url = url } });
        try s.endArray();
    }
    try s.endObject();
    return out.written();
}

/// The images in an upstream reply: `data[] {b64_json, media_type}` (or a
/// data: `url`). The type comes from `media_type`, else the requested format,
/// else the bytes.
pub fn parseImages(arena: std.mem.Allocator, raw: []const u8, format: ?[]const u8) ![]const Image {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return error.NoImage;
    return imagesIn(arena, v, format);
}

fn imagesIn(arena: std.mem.Allocator, v: std.json.Value, format: ?[]const u8) ![]const Image {
    const list = if (v == .object) v.object.get("data") orelse return error.NoImage else return error.NoImage;
    if (list != .array) return error.NoImage;
    var out: std.ArrayList(Image) = .empty;
    for (list.array.items) |item| {
        var data = openrouter.jsonString(item, "b64_json");
        var mime = openrouter.jsonString(item, "media_type");
        if (data == null) if (openrouter.jsonString(item, "url")) |url| if (std.mem.startsWith(u8, url, "data:")) {
            const comma = std.mem.indexOfScalar(u8, url, ',') orelse continue;
            if (mime == null) if (std.mem.indexOfScalar(u8, url[0..comma], ';')) |semi| {
                mime = url[5..semi];
            };
            data = url[comma + 1 ..];
        };
        const b64 = data orelse continue;
        try out.append(arena, .{ .mime = mime orelse mimeOf(format, b64), .data = b64 });
    }
    if (out.items.len == 0) return error.NoImage;
    return out.items;
}

/// The type of base64 image data with no `media_type`.
fn mimeOf(format: ?[]const u8, b64: []const u8) []const u8 {
    if (format) |f| {
        if (std.mem.eql(u8, f, "svg")) return "image/svg+xml";
        if (std.mem.eql(u8, f, "jpeg")) return "image/jpeg";
        if (std.mem.eql(u8, f, "webp")) return "image/webp";
        if (std.mem.eql(u8, f, "png")) return "image/png";
    }
    if (std.mem.startsWith(u8, b64, "/9j/")) return "image/jpeg";
    if (std.mem.startsWith(u8, b64, "UklGR")) return "image/webp";
    // "<svg" and "<?xml" encode to these.
    if (std.mem.startsWith(u8, b64, "PHN2Zy") or std.mem.startsWith(u8, b64, "PD94bW")) return "image/svg+xml";
    return "image/png";
}

/// Generates, charges the caller and returns the images. Upstream failures
/// (not billed by OpenRouter) are `error.UpstreamFailed` with the message in
/// `err_message` when given.
pub fn generate(app: *App, req: *anole.Request, who: auth.Identity, session: ?[]const u8, o: Options, err_message: ?*[]const u8) ![]const Image {
    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    const aux = try app.aux(req);
    const free = app.catalog.facts(req.io, o.model).free or aux.byok;
    try billing.preflight(app, req, who.user_id, free);
    // Images are billed after the fact, so a request must fit what is left.
    if (!free and try billing.available(app, req, who.user_id) < worstCaseMicros(o, app.cfg.markup)) return error.PaymentRequired;
    const body = try requestBody(req.arena, o);
    const s = try aux.up.post(openrouter.ctxOf(req), "/images", body, &.{});
    defer s.close();
    const raw = try s.reader.allocRemaining(req.arena, .limited(64 * 1024 * 1024));
    if (s.status >= 300) {
        if (err_message) |m| m.* = upstreamMessage(req.arena, raw);
        return error.UpstreamFailed;
    }
    const format = formatOf(o);
    const v = std.json.parseFromSliceLeaky(std.json.Value, req.arena, raw, .{}) catch return error.NoImage;
    const list = try imagesIn(req.arena, v, format);
    if (v.object.get("usage")) |u| if (u == .object) {
        const usage = openrouter.parseUsage(u.object);
        _ = try billing.charge(app, req, who.user_id, .{ .kind = "image", .model = o.model, .prompt_tokens = usage.prompt_tokens, .completion_tokens = usage.completion_tokens, .cost_usd = usage.cost_usd, .session = session, .byok = aux.byok });
    };
    return list;
}

fn upstreamMessage(arena: std.mem.Allocator, raw: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return "the image model failed";
    if (v == .object) if (v.object.get("error")) |e| if (openrouter.jsonString(e, "message")) |m| return m;
    return "the image model failed";
}

const ImageRequest = struct {
    /// An image model; the configured IMAGE_MODEL when absent, VECTOR_MODEL
    /// with `engine: "vector"`.
    model: ?[]const u8 = null,
    prompt: []const u8,
    aspect_ratio: []const u8 = "1:1",
    /// "raster" (default) or "vector" (SVG).
    engine: ?[]const u8 = null,
    n: u8 = 1,
    quality: ?[]const u8 = null,
    output_format: ?[]const u8 = null,
    /// Images to edit or follow: data: or https: URLs.
    input_references: []const []const u8 = &.{},

    pub const field_rules = .{
        .prompt = .{ anole.validate.trim, anole.validate.notBlank, anole.validate.maxLength(32_000) },
        .engine = .{anole.validate.oneOf(.{ "raster", "vector" })},
        .n = .{anole.validate.range(1, 10)},
        .input_references = .{anole.validate.maxItems(16)},
    };
};

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    // A batch of images takes a minute or more.
    req.setTimeout(.fromSeconds(300));
    const who = try auth.identity(req);
    const body = try req.bind(ImageRequest);
    const vector = std.mem.eql(u8, body.engine orelse "", "vector");
    const model = body.model orelse if (vector) app.cfg.vector_model else app.cfg.image_model;
    var message: []const u8 = "The image model returned no image.";
    const list = generate(app, req, who, null, .{
        .model = model,
        .prompt = body.prompt,
        .aspect_ratio = body.aspect_ratio,
        .n = body.n,
        .quality = body.quality,
        .output_format = body.output_format orelse if (vector) "svg" else null,
        .references = body.input_references,
    }, &message) catch |err| switch (err) {
        error.PaymentRequired => {
            res.status = .payment_required;
            return res.json(.{ .message = "You're out of credits.", .code = "out_of_credits" });
        },
        error.NoImage, error.UpstreamFailed => return res.fail(.bad_gateway, message),
        else => return err,
    };
    // `mime`/`data` is the first image, as before; `images` has them all.
    return res.json(.{ .mime = list[0].mime, .data = list[0].data, .images = list });
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    app.group("/v1", .{auth.Authenticate{ .app = state }}).post("/images", create);
}

test requestBody {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raster = try requestBody(a, .{ .model = "google/gemini-3.1-flash-image", .prompt = "a cat", .aspect_ratio = "16:9", .references = &.{"data:image/png;base64,AAAA"} });
    try std.testing.expectEqualStrings(
        \\{"model":"google/gemini-3.1-flash-image","prompt":"a cat","n":1,"aspect_ratio":"16:9","input_references":[{"type":"image_url","image_url":{"url":"data:image/png;base64,AAAA"}}]}
    , raster);
    const vector = try requestBody(a, .{ .model = "recraft/recraft-v4.1-vector", .prompt = "a fox", .n = 40 });
    try std.testing.expectEqualStrings(
        \\{"model":"recraft/recraft-v4.1-vector","prompt":"a fox","n":10,"output_format":"svg"}
    , vector);
}

test worstCaseMicros {
    try std.testing.expectEqual(@as(i64, 115_000), worstCaseMicros(.{ .model = "m", .prompt = "p" }, 1.15));
    try std.testing.expectEqual(@as(i64, 3_000_000), worstCaseMicros(.{ .model = "m", .prompt = "p", .n = 40, .quality = "high" }, 1.0));
    try std.testing.expectEqual(@as(i64, 100_000), worstCaseMicros(.{ .model = "m", .prompt = "p", .n = 0 }, 1.0));
}

test parseImages {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try parseImages(a,
        \\{"data":[{"b64_json":"iVBORw0K","media_type":"image/png"},{"b64_json":"PHN2ZyB4bWxucz0i"},{"url":"data:image/webp;base64,UklGRg=="}],"usage":{"cost":0.04}}
    , null);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings("image/png", list[0].mime);
    try std.testing.expectEqualStrings("image/svg+xml", list[1].mime);
    try std.testing.expectEqualStrings("image/webp", list[2].mime);
    try std.testing.expectEqualStrings("UklGRg==", list[2].data);
    try std.testing.expectEqualStrings("image/svg+xml", (try parseImages(a, "{\"data\":[{\"b64_json\":\"x\"}]}", "svg"))[0].mime);
    try std.testing.expectError(error.NoImage, parseImages(a, "{\"data\":[]}", null));
    try std.testing.expect(isVectorModel("recraft/recraft-v4-pro-vector"));
    try std.testing.expect(!isVectorModel("recraft/recraft-v4.1-flash"));
}
