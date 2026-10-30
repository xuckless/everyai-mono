//! Image generation through an OpenRouter image-output model. Serves
//! `POST /v1/images` (the old /stability and /gpt image routes) and the chat
//! `generate_image` tool.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const auth = @import("auth.zig");
const billing = @import("billing.zig");
const openrouter = @import("openrouter.zig");

pub const Image = struct {
    mime: []const u8,
    /// Base64, no data: prefix.
    data: []const u8,
};

pub fn generate(app: *App, req: *anole.Request, who: auth.Identity, session: ?[]const u8, model: []const u8, prompt: []const u8, aspect_ratio: []const u8) !Image {
    app.catalog.ensureFresh(app.upstream, req.io, app.cfg.markup);
    try billing.preflight(app, req, who.user_id, app.catalog.facts(req.io, model).free);
    const body = try std.json.Stringify.valueAlloc(req.arena, .{
        .model = model,
        .modalities = .{ "image", "text" },
        .usage = .{ .include = true },
        .image_config = .{ .aspect_ratio = aspect_ratio },
        .messages = .{.{ .role = "user", .content = prompt }},
    }, .{});
    const s = try app.upstream.post(req, "/chat/completions", body, &.{});
    defer s.close();
    const raw = try s.reader.allocRemaining(req.arena, .limited(32 * 1024 * 1024));
    if (s.status >= 300) return error.UpstreamFailed;
    const v = try std.json.parseFromSliceLeaky(std.json.Value, req.arena, raw, .{});
    if (v.object.get("usage")) |u| if (u == .object) {
        const usage = openrouter.parseUsage(u.object);
        _ = try billing.charge(app, req, who.user_id, .{ .kind = "image", .model = model, .prompt_tokens = usage.prompt_tokens, .completion_tokens = usage.completion_tokens, .cost_usd = usage.cost_usd, .session = session });
    };
    const choices = (v.object.get("choices") orelse return error.NoImage).array.items;
    if (choices.len == 0) return error.NoImage;
    const message = (choices[0].object.get("message") orelse return error.NoImage).object;
    const list = (message.get("images") orelse return error.NoImage).array.items;
    if (list.len == 0) return error.NoImage;
    const url = list[0].object.get("image_url").?.object.get("url").?.string;
    // data:image/png;base64,....
    const comma = std.mem.indexOfScalar(u8, url, ',') orelse return error.NoImage;
    const mime = if (std.mem.indexOfScalar(u8, url[0..comma], ';')) |semi| url[5..semi] else "image/png";
    return .{ .mime = mime, .data = url[comma + 1 ..] };
}

const ImageRequest = struct {
    /// An image-output model; the configured IMAGE_MODEL when absent.
    model: ?[]const u8 = null,
    prompt: []const u8,
    aspect_ratio: []const u8 = "1:1",
};

fn create(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const who = try auth.identity(req);
    const body = try req.bind(ImageRequest);
    if (std.mem.trim(u8, body.prompt, " \n\t").len == 0) return res.fail(.unprocessable_entity, "prompt must not be blank");
    const img = generate(app, req, who, null, body.model orelse app.cfg.image_model, body.prompt, body.aspect_ratio) catch |err| switch (err) {
        error.PaymentRequired => {
            res.status = .payment_required;
            return res.json(.{ .message = "You're out of credits.", .code = "out_of_credits" });
        },
        error.NoImage, error.UpstreamFailed => return res.fail(.bad_gateway, "The image model returned no image."),
        else => return err,
    };
    return res.json(img);
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    app.group("/v1", .{auth.Authenticate{ .app = state }}).post("/images", create);
}
