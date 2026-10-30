//! Plans, quotas and the prepaid wallet. Every paid upstream call costs
//! upstream cost × markup (micro-USD), taken first from the plan's monthly
//! included usage, then from the wallet. Zero-cost (free) models never charge.
//! Periods renew lazily on the first charge after they end.
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;
const util = @import("util.zig");
const auth = @import("auth.zig");

pub const Plan = struct {
    id: []const u8,
    name: []const u8,
    /// Monthly price in cents (Stripe).
    price_cents: i64,
    /// Charged usage included per period, micro-USD (already marked up).
    included_micros: i64,
    blurb: []const u8,
};

pub const plans = [_]Plan{
    .{ .id = "free", .name = "Free", .price_cents = 0, .included_micros = 1_000_000, .blurb = "All free models, plus $1 of premium usage a month" },
    .{ .id = "pro", .name = "Pro", .price_cents = 2000, .included_micros = 20_000_000, .blurb = "$20 of usage a month, then pay as you go" },
    .{ .id = "max", .name = "Max", .price_cents = 10000, .included_micros = 100_000_000, .blurb = "$100 of usage a month, then pay as you go" },
};

pub const period_seconds = 30 * 24 * 3600;

pub fn planById(id: []const u8) ?Plan {
    for (plans) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

pub const CreditKind = enum { topup, usage, grant, refund };

pub fn credit(app: *App, ctx: anytype, user_id: []const u8, micros: i64, kind: CreditKind, ref: ?[]const u8) !void {
    _ = try app.db.exec(ctx, "INSERT INTO wallet_ledger (user_id, amount_micros, kind, ref, created_at) VALUES (?, ?, ?, ?, ?)", .{
        user_id, micros, @tagName(kind), ref, util.now(ctx.io),
    });
}

/// Opens a period for `plan_id` starting now (plan change or renewal).
pub fn startPeriod(app: *App, ctx: anytype, user_id: []const u8, plan_id: []const u8) !void {
    const plan = planById(plan_id) orelse return error.UnknownPlan;
    const now = util.now(ctx.io);
    // Close any open period first.
    _ = try app.db.exec(ctx, "UPDATE quota_periods SET period_end = ? WHERE user_id = ? AND period_end > ?", .{ now, user_id, now });
    _ = try app.db.exec(ctx, "INSERT OR REPLACE INTO quota_periods (user_id, period_start, period_end, included_micros) VALUES (?, ?, ?, ?)", .{
        user_id, now, now + period_seconds, plan.included_micros,
    });
    _ = try app.db.exec(ctx, "UPDATE users SET plan = ? WHERE id = ?", .{ plan_id, user_id });
}

const Period = struct { period_start: i64, period_end: i64, included_micros: i64, used_micros: i64 };

/// The open period, renewing it if the last one ended.
fn currentPeriod(app: *App, ctx: anytype, user_id: []const u8) !Period {
    const now = util.now(ctx.io);
    if (try app.db.optional(Period, ctx, "SELECT period_start, period_end, included_micros, used_micros FROM quota_periods WHERE user_id = ? AND period_end > ? ORDER BY period_start DESC LIMIT 1", .{ user_id, now })) |p| return p;
    const plan = try app.db.one([]const u8, ctx, "SELECT plan FROM users WHERE id = ?", .{user_id});
    try startPeriod(app, ctx, user_id, plan);
    return app.db.one(Period, ctx, "SELECT period_start, period_end, included_micros, used_micros FROM quota_periods WHERE user_id = ? AND period_end > ? ORDER BY period_start DESC LIMIT 1", .{ user_id, now });
}

pub fn walletBalance(app: *App, ctx: anytype, user_id: []const u8) !i64 {
    return app.db.one(i64, ctx, "SELECT COALESCE(SUM(amount_micros), 0) FROM wallet_ledger WHERE user_id = ?", .{user_id});
}

/// What a paid request may still spend: quota left plus wallet.
pub fn available(app: *App, ctx: anytype, user_id: []const u8) !i64 {
    const p = try currentPeriod(app, ctx, user_id);
    return @max(0, p.included_micros - p.used_micros) + try walletBalance(app, ctx, user_id);
}

/// 402 before a paid call when nothing is left. Free models always pass.
pub fn preflight(app: *App, ctx: anytype, user_id: []const u8, model_is_free: bool) !void {
    if (model_is_free) return;
    if (try available(app, ctx, user_id) <= 0) return error.PaymentRequired;
}

pub const Usage = struct {
    kind: []const u8,
    model: []const u8,
    prompt_tokens: i64 = 0,
    completion_tokens: i64 = 0,
    cached_tokens: i64 = 0,
    cache_write_tokens: i64 = 0,
    /// Upstream cost in USD as reported.
    cost_usd: f64 = 0,
    session: ?[]const u8 = null,
    api_key_id: ?[]const u8 = null,
    /// Who served the call: "openrouter" or "anthropic".
    provider: []const u8 = "openrouter",
};

pub const Charge = struct { cost_micros: i64, charged_micros: i64, from_quota: i64, from_wallet: i64 };

/// Records one upstream call and takes its price from quota, then wallet.
/// The wallet may go slightly negative on the call that crosses zero; the
/// next preflight stops further paid calls.
pub fn charge(app: *App, ctx: anytype, user_id: []const u8, u: Usage) !Charge {
    const cost = util.usdToMicros(u.cost_usd);
    const charged = util.applyMarkup(cost, app.cfg.markup);
    var from_quota: i64 = 0;
    var from_wallet: i64 = 0;
    if (charged > 0) {
        const p = try currentPeriod(app, ctx, user_id);
        from_quota = @min(charged, @max(0, p.included_micros - p.used_micros));
        from_wallet = charged - from_quota;
        if (from_quota > 0) _ = try app.db.exec(ctx, "UPDATE quota_periods SET used_micros = used_micros + ? WHERE user_id = ? AND period_start = ?", .{ from_quota, user_id, p.period_start });
        if (from_wallet > 0) try credit(app, ctx, user_id, -from_wallet, .usage, u.model);
    }
    _ = try app.db.exec(ctx,
        \\INSERT INTO usage_events (user_id, api_key_id, session, kind, model, prompt_tokens, completion_tokens,
        \\  cached_tokens, cache_write_tokens, cost_micros, charged_micros, from_quota_micros, from_wallet_micros, created_at, provider)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    , .{ user_id, u.api_key_id, u.session, u.kind, u.model, u.prompt_tokens, u.completion_tokens, u.cached_tokens, u.cache_write_tokens, cost, charged, from_quota, from_wallet, util.now(ctx.io), u.provider });
    return .{ .cost_micros = cost, .charged_micros = charged, .from_quota = from_quota, .from_wallet = from_wallet };
}

// ------------------------------------------------------------------ routes

const UsageRow = struct {
    created_at: i64,
    kind: []const u8,
    model: []const u8,
    prompt_tokens: i64,
    completion_tokens: i64,
    cached_tokens: i64,
    cache_write_tokens: i64,
    charged_micros: i64,
    session: ?[]const u8,
    provider: []const u8,
};

const usage_columns = "created_at, kind, model, prompt_tokens, completion_tokens, cached_tokens, cache_write_tokens, charged_micros, session, provider";

fn summary(app: *App, req: *anole.Request) !struct {
    plan: Plan,
    plans: []const Plan,
    period_start: i64,
    period_end: i64,
    included_micros: i64,
    used_micros: i64,
    wallet_micros: i64,
    markup: f64,
    month_tokens: i64,
    month_cached_tokens: i64,
    recent: []const UsageRow,
} {
    const who = try auth.identity(req);
    const user = try auth.loadUser(app, req, who.user_id);
    const p = try currentPeriod(app, req, who.user_id);
    const tokens = try app.db.one(struct { t: i64, c: i64 }, req, "SELECT COALESCE(SUM(prompt_tokens + completion_tokens), 0) AS t, COALESCE(SUM(cached_tokens), 0) AS c FROM usage_events WHERE user_id = ? AND created_at >= ?", .{ who.user_id, p.period_start });
    return .{
        .plan = planById(user.plan) orelse plans[0],
        .plans = &plans,
        .period_start = p.period_start,
        .period_end = p.period_end,
        .included_micros = p.included_micros,
        .used_micros = p.used_micros,
        .wallet_micros = try walletBalance(app, req, who.user_id),
        .markup = app.cfg.markup,
        .month_tokens = tokens.t,
        .month_cached_tokens = tokens.c,
        .recent = try app.db.all(UsageRow, req, "SELECT " ++ usage_columns ++ " FROM usage_events WHERE user_id = ? ORDER BY id DESC LIMIT 50", .{who.user_id}),
    };
}

fn usage(app: *App, req: *anole.Request, in: anole.In(.{ .query = struct { from: i64 = 0, to: i64 = std.math.maxInt(i64), limit: u32 = 500 } })) ![]const UsageRow {
    const who = try auth.identity(req);
    return app.db.all(UsageRow, req, "SELECT " ++ usage_columns ++ " FROM usage_events WHERE user_id = ? AND created_at BETWEEN ? AND ? ORDER BY id DESC LIMIT ?", .{ who.user_id, in.query.from, in.query.to, in.query.limit });
}

const SessionTotals = struct {
    calls: i64,
    prompt_tokens: i64,
    completion_tokens: i64,
    cached_tokens: i64,
    cache_write_tokens: i64,
    charged_micros: i64,
    /// The latest model call (not follow-ups or images): how full the
    /// context window is now.
    last_prompt_tokens: i64 = 0,
    last_completion_tokens: i64 = 0,
};

/// Totals for one chat conversation or Code session (the `session` the app
/// or the gateway's `X-EveryAI-Session` named), for the composer meter.
fn sessionUsage(app: *App, req: *anole.Request, in: anole.In(.{ .path = struct { id: []const u8 } })) !SessionTotals {
    const who = try auth.identity(req);
    var t = try app.db.one(SessionTotals, req,
        \\SELECT COUNT(*) AS calls, COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens, COALESCE(SUM(completion_tokens), 0) AS completion_tokens,
        \\  COALESCE(SUM(cached_tokens), 0) AS cached_tokens, COALESCE(SUM(cache_write_tokens), 0) AS cache_write_tokens,
        \\  COALESCE(SUM(charged_micros), 0) AS charged_micros, 0 AS last_prompt_tokens, 0 AS last_completion_tokens
        \\FROM usage_events WHERE user_id = ? AND session = ?
    , .{ who.user_id, in.path.id });
    if (try app.db.optional(struct { p: i64, c: i64 }, req, "SELECT prompt_tokens AS p, completion_tokens AS c FROM usage_events WHERE user_id = ? AND session = ? AND kind IN ('chat', 'gateway') ORDER BY id DESC LIMIT 1", .{ who.user_id, in.path.id })) |last| {
        t.last_prompt_tokens = last.p;
        t.last_completion_tokens = last.c;
    }
    return t;
}

const Checkout = struct {
    /// "topup" or "subscription".
    kind: []const u8,
    /// Top-up amount in cents (min $5).
    amount_cents: i64 = 0,
    /// Plan id for subscriptions.
    plan: []const u8 = "",
    pub const field_rules = .{ .kind = .{anole.validate.oneOf(.{ "topup", "subscription" })} };
};

/// Returns a Stripe Checkout URL, or (no Stripe key: mock mode) applies the
/// purchase right away and returns `mock: true`.
fn checkout(app: *App, req: *anole.Request, in: anole.In(.{ .body = Checkout })) !struct { url: ?[]const u8, mock: bool } {
    const who = try auth.identity(req);
    const is_topup = std.mem.eql(u8, in.body.kind, "topup");
    if (is_topup and in.body.amount_cents < 500) return error.UnprocessableEntity;
    const plan = if (is_topup) null else (planById(in.body.plan) orelse return error.UnprocessableEntity);

    const key = app.cfg.stripe_secret_key orelse {
        if (plan) |p| try startPeriod(app, req, who.user_id, p.id) else try credit(app, req, who.user_id, in.body.amount_cents * 10_000, .topup, "mock checkout");
        return .{ .url = null, .mock = true };
    };

    var form: std.Io.Writer.Allocating = .init(req.arena);
    const w = &form.writer;
    try w.print("success_url={s}/billing/done&cancel_url={s}/billing/cancel&client_reference_id={s}&line_items[0][quantity]=1&line_items[0][price_data][currency]=usd", .{ app.cfg.public_url, app.cfg.public_url, who.user_id });
    if (plan) |p| {
        try w.print("&mode=subscription&line_items[0][price_data][unit_amount]={d}&line_items[0][price_data][recurring][interval]=month&line_items[0][price_data][product_data][name]=EveryAI%20{s}&metadata[kind]=subscription&metadata[plan]={s}&subscription_data[metadata][user_id]={s}&subscription_data[metadata][plan]={s}", .{ p.price_cents, p.name, p.id, who.user_id, p.id });
    } else {
        try w.print("&mode=payment&line_items[0][price_data][unit_amount]={d}&line_items[0][price_data][product_data][name]=EveryAI%20credits&metadata[kind]=topup&metadata[amount_cents]={d}", .{ in.body.amount_cents, in.body.amount_cents });
    }

    var r = try anole.client(req).fetch("https://api.stripe.com/v1/checkout/sessions", .{
        .method = .post,
        .headers = &.{
            .{ "Authorization", try std.fmt.allocPrint(req.arena, "Bearer {s}", .{key.expose()}) },
            .{ "Content-Type", "application/x-www-form-urlencoded" },
        },
        .body = form.written(),
    });
    defer r.deinit();
    if (@backingInt(r.status()) >= 300) {
        std.log.err("stripe checkout failed: {d} {s}", .{ @backingInt(r.status()), r.body() catch "" });
        return error.BadGateway;
    }
    const session = try r.json(struct { url: []const u8 }, req.arena);
    return .{ .url = session.url, .mock = false };
}

/// Stripe webhook (signature and duplicate deliveries handled by Anole's
/// `webhookVerify` preset). Credits top-ups and applies subscriptions.
fn stripeWebhook(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const body = (try req.body()) orelse "";
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{});
    const ev_type = parsed.object.get("type").?.string;
    const obj = parsed.object.get("data").?.object.get("object").?.object;
    const meta = if (obj.get("metadata")) |m| m.object else null;

    if (std.mem.eql(u8, ev_type, "checkout.session.completed")) {
        const user_id = obj.get("client_reference_id").?.string;
        const kind = if (meta) |m| (if (m.get("kind")) |k| k.string else "") else "";
        if (std.mem.eql(u8, kind, "topup")) {
            const cents = try std.fmt.parseInt(i64, meta.?.get("amount_cents").?.string, 10);
            try credit(app, req, user_id, cents * 10_000, .topup, obj.get("id").?.string);
        } else if (std.mem.eql(u8, kind, "subscription")) {
            const plan = meta.?.get("plan").?.string;
            try startPeriod(app, req, user_id, plan);
            _ = try app.db.exec(req, "INSERT OR REPLACE INTO subscriptions (user_id, plan, status, stripe_subscription_id) VALUES (?, ?, 'active', ?)", .{
                user_id, plan, if (obj.get("subscription")) |s| (if (s == .string) s.string else null) else null,
            });
        }
    } else if (std.mem.eql(u8, ev_type, "invoice.paid")) {
        // Renewal: a fresh period for the subscription's plan.
        if (obj.get("subscription")) |s| if (s == .string) {
            if (try app.db.optional(struct { user_id: []const u8, plan: []const u8 }, req, "SELECT user_id, plan FROM subscriptions WHERE stripe_subscription_id = ?", .{s.string})) |sub|
                try startPeriod(app, req, sub.user_id, sub.plan);
        };
    } else if (std.mem.eql(u8, ev_type, "customer.subscription.deleted")) {
        if (obj.get("id")) |s| if (try app.db.optional([]const u8, req, "SELECT user_id FROM subscriptions WHERE stripe_subscription_id = ?", .{s.string})) |user_id| {
            _ = try app.db.exec(req, "UPDATE subscriptions SET status = 'canceled' WHERE user_id = ?", .{user_id});
            try startPeriod(app, req, user_id, "free");
        };
    }
    res.status = .ok;
    try res.json(.{ .received = true });
}

fn listPlans(_: *App, _: *anole.Request) []const Plan {
    return &plans;
}

pub fn routes(app: *anole.Server(App), state: *App) void {
    app.get("/v1/plans", listPlans);
    const user = app.group("/v1", .{auth.Authenticate{ .app = state }});
    user.get("/billing", summary);
    user.get("/usage", usage);
    user.get("/usage/session/:id", sessionUsage);
    user.post("/billing/checkout", checkout);
    if (state.cfg.stripe_webhook_secret) |secret| {
        // The middleware keeps the slice: it must outlive this function.
        state.stripe_secrets[0] = secret.expose();
        const hook = app.webhookVerify(.{ .preset = .stripe, .secrets = state.stripe_secrets[0..1] });
        app.with(.{hook}).post("/v1/billing/webhook", stripeWebhook);
    }
}
