//! Local mode: which local models are in memory, as one explicit state
//! machine per model, and the calls that load and unload them (Ollama, LM
//! Studio). The app reads it to show each model's state, and asks it at quit
//! to unload what EveryAI loaded (`ours`).
//!
//! States and events ([next] is the whole table):
//!
//!   unloaded --load--> loading --loaded--> loaded --unload--> unloading --unloaded--> unloaded
//!                         \--load_failed--> failed           \--unload_failed--> failed
//!   failed --load--> loading, failed --unload--> unloading
//!   seen_loaded / seen_unloaded: what the server itself reports (reconcile);
//!   ignored while a load or unload of ours is under way.
const std = @import("std");
const anole = @import("anole");
const util = @import("util.zig");
const local = @import("local.zig");
const App = @import("main.zig").App;

pub const kind_header = "X-Local-Kind";
pub const aux_kind_header = "X-Local-Aux-Kind";

/// The kinds of local server the app tells apart (`X-Local-Kind`).
pub const Kind = enum {
    ollama,
    lmstudio,
    fm,
    llamacpp,
    jan,
    vllm,
    mlx,
    custom,

    /// Unknown or missing: `custom` (no load or unload control).
    pub fn parse(raw: ?[]const u8) Kind {
        const s = std.mem.trim(u8, raw orelse return .custom, " \t");
        return std.meta.stringToEnum(Kind, s) orelse .custom;
    }

    /// Whether this server's models can be loaded and unloaded through it.
    pub fn controllable(self: Kind) bool {
        return self == .ollama or self == .lmstudio;
    }
};

pub const State = enum { unloaded, loading, loaded, unloading, failed };

pub const Event = enum {
    /// We start loading it (a load call, or a chat turn on a model not loaded).
    load,
    /// The load worked (the call answered, or the turn ran).
    loaded,
    load_failed,
    /// We start unloading it.
    unload,
    unloaded,
    unload_failed,
    /// The server reports it in memory / not in memory.
    seen_loaded,
    seen_unloaded,
};

/// The state after `event` in `state`, or null when the event makes no sense
/// there (it is then ignored). Exhaustive on purpose: a new state or event
/// doesn't compile until every pair is decided.
pub fn next(state: State, event: Event) ?State {
    return switch (state) {
        .unloaded => switch (event) {
            .load => .loading,
            .seen_loaded => .loaded,
            .seen_unloaded => .unloaded,
            .loaded, .load_failed, .unload, .unloaded, .unload_failed => null,
        },
        .loading => switch (event) {
            // A second turn on the same model while the first loads it.
            .load => .loading,
            .loaded => .loaded,
            .load_failed => .failed,
            // The server's view lags behind ours mid-load.
            .seen_loaded, .seen_unloaded => .loading,
            .unload, .unloaded, .unload_failed => null,
        },
        .loaded => switch (event) {
            // A turn on a model already in memory.
            .load, .loaded, .seen_loaded => .loaded,
            .unload => .unloading,
            // The server let it go by itself (its keep-alive ran out, memory).
            .seen_unloaded => .unloaded,
            .load_failed, .unloaded, .unload_failed => null,
        },
        .unloading => switch (event) {
            .unloaded => .unloaded,
            .unload_failed => .failed,
            .seen_loaded, .seen_unloaded => .unloading,
            .load, .loaded, .load_failed, .unload => null,
        },
        .failed => switch (event) {
            .load => .loading,
            .unload => .unloading,
            .seen_loaded => .loaded,
            .seen_unloaded => .unloaded,
            // A turn that ran after a failed load: it is loaded now.
            .loaded => .loaded,
            .load_failed, .unloaded, .unload_failed => null,
        },
    };
}

/// One model as the routes report it.
pub const Info = struct {
    kind: Kind,
    base_url: []const u8,
    name: []const u8,
    state: State,
    /// EveryAI loaded it (unloaded at quit by `unload_ours`).
    ours: bool,
    reason: ?[]const u8,
    /// When it entered `state` (unix seconds).
    since: i64,
    controllable: bool,
};

const Entry = struct {
    kind: Kind,
    base_url: []u8,
    name: []u8,
    api_key: []u8,
    state: State = .unloaded,
    ours: bool = false,
    reason: ?[]u8 = null,
    since: i64 = 0,
};

/// Every model the bundled server has seen, by `base_url|name`. Owns its
/// strings (`gpa`); safe from any request (one mutex).
pub const Registry = struct {
    mutex: std.Io.Mutex = .init,
    entries: std.StringArrayHashMapUnmanaged(Entry) = .empty,

    pub const Model = struct { kind: Kind, base_url: []const u8, name: []const u8, api_key: []const u8 = "" };

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.entries.keys(), self.entries.values()) |k, *e| {
            gpa.free(k);
            freeEntry(gpa, e);
        }
        self.entries.deinit(gpa);
    }

    fn freeEntry(gpa: std.mem.Allocator, e: *Entry) void {
        gpa.free(e.base_url);
        gpa.free(e.name);
        gpa.free(e.api_key);
        if (e.reason) |r| gpa.free(r);
    }

    /// Applies `event` to `m` (added, unloaded, when new) and returns its new
    /// state, or null when the event was illegal there (logged, nothing changes).
    /// `ours` marks a model we loaded; `reason` goes with a failure.
    pub fn apply(self: *Registry, io: std.Io, gpa: std.mem.Allocator, m: Model, event: Event, reason: ?[]const u8) !?State {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const e = try self.entryLocked(gpa, m);
        const to = next(e.state, event) orelse {
            std.log.scoped(.local_models).warn("ignored {s} on {s} ({s})", .{ @tagName(event), e.name, @tagName(e.state) });
            return null;
        };
        if (m.api_key.len > 0 and !std.mem.eql(u8, m.api_key, e.api_key)) {
            gpa.free(e.api_key);
            e.api_key = try gpa.dupe(u8, m.api_key);
        }
        // `ours` follows who moved it into memory: a load of ours that worked,
        // or nobody's once it leaves memory.
        switch (to) {
            .loaded => if (e.state == .loading or (e.state == .failed and event == .loaded)) {
                e.ours = true;
            },
            .unloaded => e.ours = false,
            else => {},
        }
        if (e.reason) |r| gpa.free(r);
        e.reason = if (to == .failed) try gpa.dupe(u8, reason orelse "failed") else null;
        if (to != e.state) e.since = util.now(io);
        e.state = to;
        return to;
    }

    pub const Begun = enum { started, already, busy };

    /// Starts loading or unloading `m` in one step under the lock: `already`
    /// when it is there (loaded / unloaded), `busy` while another load or
    /// unload of it runs, else `started` (the state is now loading/unloading).
    pub fn begin(self: *Registry, io: std.Io, gpa: std.mem.Allocator, m: Model, dir: Direction) !Begun {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const e = try self.entryLocked(gpa, m);
        const settled: State, const event: Event = switch (dir) {
            .load => .{ .loaded, .load },
            .unload => .{ .unloaded, .unload },
        };
        if (e.state == settled) return .already;
        if (e.state == .loading or e.state == .unloading) return .busy;
        e.state = next(e.state, event).?;
        e.since = util.now(io);
        if (m.api_key.len > 0 and !std.mem.eql(u8, m.api_key, e.api_key)) {
            gpa.free(e.api_key);
            e.api_key = try gpa.dupe(u8, m.api_key);
        }
        return .started;
    }

    /// The state of `m` now (unloaded when unknown).
    pub fn stateOf(self: *Registry, io: std.Io, base_url: []const u8, name: []const u8) State {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var buf: [1024]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ base_url, name }) catch return .unloaded;
        return if (self.entries.get(key)) |e| e.state else .unloaded;
    }

    /// The model's report, copied into `arena`.
    pub fn info(self: *Registry, io: std.Io, arena: std.mem.Allocator, base_url: []const u8, name: []const u8) !?Info {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ base_url, name });
        const e = self.entries.getPtr(key) orelse return null;
        return try infoOf(arena, e);
    }

    /// Every model, copied into `arena`, in the order first seen.
    pub fn snapshot(self: *Registry, io: std.Io, arena: std.mem.Allocator) ![]Info {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const out = try arena.alloc(Info, self.entries.count());
        for (self.entries.values(), out) |*e, *o| o.* = try infoOf(arena, e);
        return out;
    }

    /// Models we loaded that are in memory, with their keys, copied into `arena`.
    pub fn ours(self: *Registry, io: std.Io, arena: std.mem.Allocator) ![]Model {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out: std.ArrayList(Model) = .empty;
        for (self.entries.values()) |e| if (e.ours and e.state == .loaded) try out.append(arena, .{
            .kind = e.kind,
            .base_url = try arena.dupe(u8, e.base_url),
            .name = try arena.dupe(u8, e.name),
            .api_key = try arena.dupe(u8, e.api_key),
        });
        return out.items;
    }

    /// The servers (kind, base URL, a key) whose models can be reconciled, once each.
    pub fn servers(self: *Registry, io: std.Io, arena: std.mem.Allocator) ![]Model {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out: std.ArrayList(Model) = .empty;
        outer: for (self.entries.values()) |e| {
            if (!e.kind.controllable()) continue;
            for (out.items) |s| if (std.mem.eql(u8, s.base_url, e.base_url)) continue :outer;
            try out.append(arena, .{ .kind = e.kind, .base_url = try arena.dupe(u8, e.base_url), .name = "", .api_key = try arena.dupe(u8, e.api_key) });
        }
        return out.items;
    }

    /// The names of the models on `base_url`, copied into `arena`.
    pub fn namesOn(self: *Registry, io: std.Io, arena: std.mem.Allocator, base_url: []const u8) ![]const []const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var out: std.ArrayList([]const u8) = .empty;
        for (self.entries.values()) |e| if (std.mem.eql(u8, e.base_url, base_url)) try out.append(arena, try arena.dupe(u8, e.name));
        return out.items;
    }

    fn entryLocked(self: *Registry, gpa: std.mem.Allocator, m: Model) !*Entry {
        const key = try std.fmt.allocPrint(gpa, "{s}|{s}", .{ m.base_url, m.name });
        const got = self.entries.getOrPut(gpa, key) catch |err| {
            gpa.free(key);
            return err;
        };
        if (got.found_existing) {
            gpa.free(key);
            return got.value_ptr;
        }
        errdefer {
            _ = self.entries.swapRemove(key);
            gpa.free(key);
        }
        const base = try gpa.dupe(u8, m.base_url);
        errdefer gpa.free(base);
        const name = try gpa.dupe(u8, m.name);
        errdefer gpa.free(name);
        got.value_ptr.* = .{ .kind = m.kind, .base_url = base, .name = name, .api_key = try gpa.dupe(u8, m.api_key) };
        return got.value_ptr;
    }

    fn infoOf(arena: std.mem.Allocator, e: *const Entry) !Info {
        return .{
            .kind = e.kind,
            .base_url = try arena.dupe(u8, e.base_url),
            .name = try arena.dupe(u8, e.name),
            .state = e.state,
            .ours = e.ours,
            .reason = if (e.reason) |r| try arena.dupe(u8, r) else null,
            .since = e.since,
            .controllable = e.kind.controllable(),
        };
    }
};

// ------------------------------------------------------------------ server calls

/// One HTTP exchange with a local server.
pub const Reply = struct { status: u16, body: []const u8 };

/// How a call reaches the server; tests answer without the network.
pub const Control = *const fn (io: std.Io, arena: std.mem.Allocator, method: anole.http.Method, url: []const u8, body: ?[]const u8, api_key: []const u8, timeout_s: u32) anyerror!Reply;

pub const load_timeout_s = 120;
pub const unload_timeout_s = 10;
pub const reconcile_timeout_s = 3;

pub fn httpControl(io: std.Io, arena: std.mem.Allocator, method: anole.http.Method, url: []const u8, body: ?[]const u8, api_key: []const u8, timeout_s: u32) anyerror!Reply {
    var h = try anole.http.Headers.init(arena, 2);
    try h.put("Content-Type", "application/json");
    if (api_key.len > 0) try h.put("Authorization", try std.fmt.allocPrint(arena, "Bearer {s}", .{api_key}));
    var res = try anole.client(io).http.fetch(url, .{
        .method = method,
        .headers = &h,
        .body = body,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    });
    defer res.deinit();
    return .{ .status = @intCast(@backingInt(res.status())), .body = try arena.dupe(u8, (try res.body()) orelse "") };
}

/// The server's root: `base_url` without its `/v1`.
pub fn rootOf(base_url: []const u8) []const u8 {
    var u = base_url;
    while (u.len > 0 and u[u.len - 1] == '/') u = u[0 .. u.len - 1];
    return if (std.mem.endsWith(u8, u, "/v1")) u[0 .. u.len - 3] else u;
}

pub const Direction = enum { load, unload };

/// Loads or unloads `m` through its server. Null when it worked, else why not
/// (in `arena`). Only for `Kind.controllable` kinds.
pub fn call(io: std.Io, arena: std.mem.Allocator, control: Control, m: Registry.Model, dir: Direction) !?[]const u8 {
    return callWithin(io, arena, control, m, dir, if (dir == .load) load_timeout_s else unload_timeout_s);
}

/// [call] with its own time limit.
pub fn callWithin(io: std.Io, arena: std.mem.Allocator, control: Control, m: Registry.Model, dir: Direction, timeout: u32) !?[]const u8 {
    const root = rootOf(m.base_url);
    const req: struct { url: []const u8, body: []const u8 } = switch (m.kind) {
        // An empty prompt only loads (or, with keep_alive 0, unloads) the model.
        .ollama => .{
            .url = try std.fmt.allocPrint(arena, "{s}/api/generate", .{root}),
            .body = switch (dir) {
                .load => try std.json.Stringify.valueAlloc(arena, .{ .model = m.name, .keep_alive = "30m", .stream = false }, .{}),
                .unload => try std.json.Stringify.valueAlloc(arena, .{ .model = m.name, .keep_alive = 0, .stream = false }, .{}),
            },
        },
        .lmstudio => switch (dir) {
            .load => .{ .url = try std.fmt.allocPrint(arena, "{s}/api/v1/models/load", .{root}), .body = try std.json.Stringify.valueAlloc(arena, .{ .model = m.name }, .{}) },
            .unload => .{ .url = try std.fmt.allocPrint(arena, "{s}/api/v1/models/unload", .{root}), .body = try std.json.Stringify.valueAlloc(arena, .{ .instance_id = m.name }, .{}) },
        },
        else => return "This server doesn't let EveryAI load or unload its models.",
    };
    const reply = control(io, arena, .post, req.url, req.body, m.api_key, timeout) catch |err| return switch (err) {
        error.ConnectionRefused, error.ConnectionResetByPeer, error.NetworkUnreachable, error.HostUnreachable, error.UnknownHostName => "Couldn't reach the local model's server.",
        error.Timeout, error.ConnectionTimedOut => if (dir == .load) "The server took too long to load the model." else "The server took too long to unload the model.",
        else => try std.fmt.allocPrint(arena, "The call to the server failed ({s}).", .{@errorName(err)}),
    };
    if (reply.status < 300) return null;
    return try std.fmt.allocPrint(arena, "The server answered {d}: {s}", .{ reply.status, errorText(arena, reply.body) });
}

/// The `error` (string or `{message}`) of a JSON reply, else the reply cut short.
fn errorText(arena: std.mem.Allocator, body: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return body[0..@min(body.len, 200)];
    if (v == .object) if (v.object.get("error")) |e| switch (e) {
        .string => |s| return s,
        .object => |o| if (o.get("message")) |msg| if (msg == .string) return msg.string,
        else => {},
    };
    return body[0..@min(body.len, 200)];
}

/// The names `server` reports in memory (Ollama `/api/ps`, LM Studio
/// `/api/v0/models` with `state: loaded`), or null when it didn't answer.
pub fn loadedOn(io: std.Io, arena: std.mem.Allocator, control: Control, server: Registry.Model) ?[]const []const u8 {
    const root = rootOf(server.base_url);
    const url = switch (server.kind) {
        .ollama => std.fmt.allocPrint(arena, "{s}/api/ps", .{root}) catch return null,
        .lmstudio => std.fmt.allocPrint(arena, "{s}/api/v0/models", .{root}) catch return null,
        else => return null,
    };
    const reply = control(io, arena, .get, url, null, server.api_key, reconcile_timeout_s) catch return null;
    if (reply.status >= 300) return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, reply.body, .{}) catch return null;
    if (v != .object) return null;
    var out: std.ArrayList([]const u8) = .empty;
    switch (server.kind) {
        .ollama => {
            const list = v.object.get("models") orelse return null;
            if (list != .array) return null;
            for (list.array.items) |m| if (m == .object) if (m.object.get("name") orelse m.object.get("model")) |n| if (n == .string) {
                out.append(arena, n.string) catch return null;
            };
        },
        .lmstudio => {
            const list = v.object.get("data") orelse return null;
            if (list != .array) return null;
            for (list.array.items) |m| if (m == .object) {
                const id = m.object.get("id") orelse continue;
                const state = m.object.get("state") orelse continue;
                if (id == .string and state == .string and std.mem.eql(u8, state.string, "loaded")) out.append(arena, id.string) catch return null;
            };
        },
        else => unreachable,
    }
    return out.items;
}

/// Brings the registry in line with what each controllable server reports:
/// models it holds are `seen_loaded` (added when new), the rest `seen_unloaded`.
/// A server that doesn't answer is left as it was.
/// `extra` adds servers the app named (their loaded models join the registry).
pub fn reconcile(reg: *Registry, io: std.Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, control: Control, extra: []const Registry.Model) !void {
    var all: std.ArrayList(Registry.Model) = .empty;
    try all.appendSlice(arena, try reg.servers(io, arena));
    outer: for (extra) |x| {
        if (!x.kind.controllable()) continue;
        for (all.items) |s| if (std.mem.eql(u8, s.base_url, x.base_url)) continue :outer;
        try all.append(arena, x);
    }
    for (all.items) |server| {
        const loaded = loadedOn(io, arena, control, server) orelse continue;
        for (loaded) |name| _ = try reg.apply(io, gpa, .{ .kind = server.kind, .base_url = server.base_url, .name = name, .api_key = server.api_key }, .seen_loaded, null);
        for (try reg.namesOn(io, arena, server.base_url)) |name| {
            const there = for (loaded) |l| {
                if (std.mem.eql(u8, l, name)) break true;
            } else false;
            if (!there) _ = try reg.apply(io, gpa, .{ .kind = server.kind, .base_url = server.base_url, .name = name }, .seen_unloaded, null);
        }
    }
}

// ------------------------------------------------------------------ routes

/// Local mode only; the launch-token guard covers them.
pub fn routes(app: *anole.Server(App), state: *App) void {
    if (!state.cfg.local_mode) return;
    app.get("/v1/local/models", listModels);
    app.post("/v1/local/models/load", loadModel);
    app.post("/v1/local/models/unload", unloadModel);
    app.post("/v1/local/models/unload_ours", unloadOurs);
    app.post("/v1/local/shutdown", shutdown);
}

fn controlOf(app: *App) Control {
    return app.local_control orelse httpControl;
}

/// What the load and unload routes take.
pub const Target = struct { kind: []const u8, base_url: []const u8, name: []const u8 };

/// `t` as a model on this computer, or null (with the reason answered).
fn modelOf(req: *anole.Request, res: *anole.Response, t: Target) !?Registry.Model {
    const base = local.cleanUrl(t.base_url) orelse {
        res.fail(.unprocessable_entity, "base_url must be an http(s) URL");
        return null;
    };
    if (!local.isLoopbackUrl(base)) {
        res.fail(.unprocessable_entity, "base_url must be on this computer");
        return null;
    }
    const name = std.mem.trim(u8, t.name, " \t");
    if (name.len == 0 or name.len > 256) {
        res.fail(.unprocessable_entity, "name is required");
        return null;
    }
    const key = std.mem.trim(u8, req.headers.get(local.key_header) orelse "", " \t");
    return .{ .kind = Kind.parse(t.kind), .base_url = base, .name = name, .api_key = key };
}

/// The servers named in `?server=<kind>|<base_url>` (repeatable), loopback only.
pub fn serversInQuery(arena: std.mem.Allocator, url: []const u8) ![]const Registry.Model {
    const q = std.mem.indexOfScalar(u8, url, '?') orelse return &.{};
    var out: std.ArrayList(Registry.Model) = .empty;
    var it = std.mem.tokenizeScalar(u8, url[q + 1 ..], '&');
    while (it.next()) |pair| {
        if (!std.mem.startsWith(u8, pair, "server=")) continue;
        const value = try percentDecode(arena, pair["server=".len..]);
        const bar = std.mem.indexOfScalar(u8, value, '|') orelse continue;
        const base = local.cleanUrl(value[bar + 1 ..]) orelse continue;
        if (!local.isLoopbackUrl(base)) continue;
        try out.append(arena, .{ .kind = Kind.parse(value[0..bar]), .base_url = base, .name = "" });
    }
    return out.items;
}

fn percentDecode(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16)) |b| {
                try out.append(arena, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(arena, if (s[i] == '+') ' ' else s[i]);
    }
    return out.items;
}

fn listModels(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try reconcile(&app.local_models, req.io, app.gpa, req.arena, controlOf(app), try serversInQuery(req.arena, req.url));
    try res.json(.{ .models = try app.local_models.snapshot(req.io, req.arena) });
}

fn loadModel(app: *App, req: *anole.Request, res: *anole.Response, in: anole.In(.{ .body = Target })) !void {
    const m = try modelOf(req, res, in.body) orelse return;
    return change(app, req, res, m, .load);
}

fn unloadModel(app: *App, req: *anole.Request, res: *anole.Response, in: anole.In(.{ .body = Target })) !void {
    const m = try modelOf(req, res, in.body) orelse return;
    return change(app, req, res, m, .unload);
}

/// Loads or unloads `m`: 200 `{model}` when it worked or was so already, 409
/// `unsupported` / `busy`, 502 `load_failed` / `unload_failed` with the reason.
fn change(app: *App, req: *anole.Request, res: *anole.Response, m: Registry.Model, dir: Direction) !void {
    const reg = &app.local_models;
    if (!m.kind.controllable()) {
        res.status = .conflict;
        return res.json(.{ .message = "This server doesn't let EveryAI load or unload its models.", .code = "unsupported" });
    }
    switch (try reg.begin(req.io, app.gpa, m, dir)) {
        .already => {},
        .busy => {
            res.status = .conflict;
            return res.json(.{ .message = "This model is being loaded or unloaded already.", .code = "busy", .model = try reg.info(req.io, req.arena, m.base_url, m.name) });
        },
        .started => if (try call(req.io, req.arena, controlOf(app), m, dir)) |why| {
            _ = try reg.apply(req.io, app.gpa, m, if (dir == .load) .load_failed else .unload_failed, why);
            res.status = .bad_gateway;
            return res.json(.{ .message = why, .code = if (dir == .load) "load_failed" else "unload_failed", .model = try reg.info(req.io, req.arena, m.base_url, m.name) });
        } else {
            _ = try reg.apply(req.io, app.gpa, m, if (dir == .load) .loaded else .unloaded, null);
        },
    }
    try res.json(.{ .model = try reg.info(req.io, req.arena, m.base_url, m.name) });
}

pub const Failed = struct { name: []const u8, reason: []const u8 };

/// Unloads every model EveryAI loaded that is still in memory (the app, at quit).
fn unloadOurs(app: *App, req: *anole.Request, res: *anole.Response) !void {
    try res.json(unloadAllOurs(app, req.io, req.arena, unload_timeout_s));
}

// ------------------------------------------------------------------ shutdown

/// Ends the server's `run` (the server drains first).
pub const Stopper = struct {
    ptr: *anyopaque,
    stop: *const fn (*anyopaque) void,
};

/// The outcome of unloading what we loaded.
pub const Unloaded = struct { unloaded: []const []const u8, failed: []const Failed };

/// Unloads every model EveryAI loaded that is still in memory, each call
/// within `timeout_s`. Never fails: a model it couldn't unload is in `failed`.
pub fn unloadAllOurs(app: *App, io: std.Io, arena: std.mem.Allocator, timeout_s: u32) Unloaded {
    const reg = &app.local_models;
    var unloaded: std.ArrayList([]const u8) = .empty;
    var failed: std.ArrayList(Failed) = .empty;
    const list = reg.ours(io, arena) catch return .{ .unloaded = &.{}, .failed = &.{} };
    for (list) |m| {
        if (!m.kind.controllable()) continue;
        const begun = reg.begin(io, app.gpa, m, .unload) catch continue;
        if (begun != .started) continue;
        const why = callWithin(io, arena, controlOf(app), m, .unload, timeout_s) catch "out of memory";
        if (why) |w| {
            _ = reg.apply(io, app.gpa, m, .unload_failed, w) catch {};
            failed.append(arena, .{ .name = m.name, .reason = w }) catch {};
        } else {
            _ = reg.apply(io, app.gpa, m, .unloaded, null) catch {};
            unloaded.append(arena, m.name) catch {};
        }
    }
    return .{ .unloaded = unloaded.items, .failed = failed.items };
}

/// `POST /v1/local/shutdown`: unloads our models, answers, then ends the server.
fn shutdown(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const done = unloadAllOurs(app, req.io, req.arena, unload_timeout_s);
    try res.json(done);
    if (app.stop_server) |s| s.stop(s.ptr);
}

/// Whether the app that started this sidecar is gone: on POSIX this process
/// was handed to another parent (`ppid` is no longer `parent`); on Windows
/// `parent_alive` says whether the process still runs.
pub fn parentGone(parent: i64, ppid: ?i64, parent_alive: ?bool) bool {
    if (parent_alive) |alive| return !alive;
    return ppid != null and ppid.? != parent;
}

const builtin = @import("builtin");

const win = struct {
    extern "kernel32" fn OpenProcess(access: u32, inherit: i32, pid: u32) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, ms: u32) callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) i32;
    const synchronize: u32 = 0x00100000;
    const wait_timeout: u32 = 0x102;
};

fn parentIsGone(parent: i64) bool {
    if (builtin.os.tag == .windows) {
        const h = win.OpenProcess(win.synchronize, 0, @intCast(parent)) orelse return true;
        defer _ = win.CloseHandle(h);
        return parentGone(parent, null, win.WaitForSingleObject(h, 0) == win.wait_timeout);
    }
    return parentGone(parent, @intCast(std.posix.getppid()), null);
}

/// Every 2 s: when the app (`parent`) is gone, unload our models (5 s per
/// call) and end the server. Cancelled when the server ends first.
pub fn watchParent(app: *App, io: std.Io, parent: i64) std.Io.Cancelable!void {
    while (true) {
        try io.sleep(.fromSeconds(2), .awake);
        if (!parentIsGone(parent)) continue;
        std.log.scoped(.local_models).info("the app (pid {d}) is gone: unloading its models and stopping", .{parent});
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        _ = unloadAllOurs(app, io, arena.allocator(), 5);
        if (app.stop_server) |s| s.stop(s.ptr);
        return;
    }
}

// ------------------------------------------------------------------ chat turns

/// A chat turn on `m` starts: loading, unless it is in memory already.
pub fn turnStarts(app: *App, io: std.Io, m: Registry.Model) bool {
    if (app.local_models.stateOf(io, m.base_url, m.name) == .loaded) return false;
    const to = app.local_models.apply(io, app.gpa, m, .load, null) catch return false;
    return to == .loading;
}

/// The turn on `m` ended: it ran (the model is in memory), or failed with
/// `reason`. `loading` is what [turnStarts] said.
pub fn turnEnded(app: *App, io: std.Io, m: Registry.Model, loading: bool, reason: ?[]const u8) void {
    const event: Event = if (reason == null) .loaded else if (loading) .load_failed else return;
    _ = app.local_models.apply(io, app.gpa, m, event, reason) catch {};
}

// ------------------------------------------------------------------ tests

test "next: every legal transition, and the illegal ones are null" {
    const legal = [_]struct { State, Event, State }{
        .{ .unloaded, .load, .loading },           .{ .unloaded, .seen_loaded, .loaded },       .{ .unloaded, .seen_unloaded, .unloaded },
        .{ .loading, .load, .loading },            .{ .loading, .loaded, .loaded },             .{ .loading, .load_failed, .failed },
        .{ .loading, .seen_loaded, .loading },     .{ .loading, .seen_unloaded, .loading },     .{ .loaded, .load, .loaded },
        .{ .loaded, .loaded, .loaded },            .{ .loaded, .seen_loaded, .loaded },         .{ .loaded, .unload, .unloading },
        .{ .loaded, .seen_unloaded, .unloaded },   .{ .unloading, .unloaded, .unloaded },       .{ .unloading, .unload_failed, .failed },
        .{ .unloading, .seen_loaded, .unloading }, .{ .unloading, .seen_unloaded, .unloading }, .{ .failed, .load, .loading },
        .{ .failed, .unload, .unloading },         .{ .failed, .seen_loaded, .loaded },         .{ .failed, .seen_unloaded, .unloaded },
        .{ .failed, .loaded, .loaded },
    };
    var count: usize = 0;
    for (std.enums.values(State)) |s| for (std.enums.values(Event)) |e| {
        const want: ?State = for (legal) |l| {
            if (l[0] == s and l[1] == e) break l[2];
        } else null;
        try std.testing.expectEqual(want, next(s, e));
        if (want != null) count += 1;
    };
    try std.testing.expectEqual(legal.len, count);
    // A few that must stay refused.
    try std.testing.expectEqual(@as(?State, null), next(.unloaded, .unload));
    try std.testing.expectEqual(@as(?State, null), next(.unloading, .load));
    try std.testing.expectEqual(@as(?State, null), next(.loading, .unload));
}

test "registry: ours follows our loads, failures keep their reason, illegal events change nothing" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var reg: Registry = .{};
    defer reg.deinit(gpa);
    const m: Registry.Model = .{ .kind = .ollama, .base_url = "http://127.0.0.1:11434/v1", .name = "qwen3:8b" };

    try std.testing.expectEqual(@as(?State, null), try reg.apply(io, gpa, m, .unload, null));
    try std.testing.expectEqual(@as(?State, .loading), try reg.apply(io, gpa, m, .load, null));
    try std.testing.expectEqual(@as(?State, .loaded), try reg.apply(io, gpa, m, .loaded, null));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(usize, 1), (try reg.ours(io, a)).len);

    // Someone else's model the server reports is not ours.
    const other: Registry.Model = .{ .kind = .ollama, .base_url = m.base_url, .name = "llama3.2:3b" };
    _ = try reg.apply(io, gpa, other, .seen_loaded, null);
    try std.testing.expectEqual(@as(usize, 1), (try reg.ours(io, a)).len);

    _ = try reg.apply(io, gpa, m, .unload, null);
    try std.testing.expectEqual(@as(?State, .failed), try reg.apply(io, gpa, m, .unload_failed, "busy"));
    const info = (try reg.info(io, a, m.base_url, m.name)).?;
    try std.testing.expectEqualStrings("busy", info.reason.?);
    try std.testing.expectEqual(State.failed, reg.stateOf(io, m.base_url, m.name));
    _ = try reg.apply(io, gpa, m, .seen_unloaded, null);
    try std.testing.expectEqual(@as(usize, 0), (try reg.ours(io, a)).len);
    try std.testing.expectEqual(@as(usize, 2), (try reg.snapshot(io, a)).len);
    try std.testing.expectEqual(@as(usize, 1), (try reg.servers(io, a)).len);
}

test "serversInQuery reads repeated server= params, loopback only" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try serversInQuery(arena.allocator(), "/v1/local/models?server=ollama%7Chttp%3A%2F%2F127.0.0.1%3A11434%2Fv1&x=1&server=lmstudio|http://localhost:1234/v1&server=ollama%7Chttp%3A%2F%2F10.0.0.2%3A11434");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(Kind.ollama, got[0].kind);
    try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1", got[0].base_url);
    try std.testing.expectEqual(Kind.lmstudio, got[1].kind);
}

test "parentGone: a new parent (POSIX) or a dead process (Windows) means shut down" {
    try std.testing.expect(!parentGone(4242, 4242, null));
    try std.testing.expect(parentGone(4242, 1, null));
    try std.testing.expect(!parentGone(4242, null, true));
    try std.testing.expect(parentGone(4242, null, false));
    try std.testing.expect(!parentGone(4242, null, null));
}

test "rootOf and Kind.parse" {
    try std.testing.expectEqualStrings("http://127.0.0.1:11434", rootOf("http://127.0.0.1:11434/v1"));
    try std.testing.expectEqualStrings("http://h:1", rootOf("http://h:1/"));
    try std.testing.expectEqual(Kind.lmstudio, Kind.parse(" lmstudio"));
    try std.testing.expectEqual(Kind.custom, Kind.parse("nope"));
    try std.testing.expectEqual(Kind.custom, Kind.parse(null));
}
