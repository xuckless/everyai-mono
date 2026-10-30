//! Curated models for the Code agent, by tier, each at a reasoning effort:
//!
//!   GET /v1/agents   {tiers: [{id, name, blurb}], models: [Agent], default}
//!
//! Only models that work as agents (tool use, long multi-step tasks) are
//! listed; image/audio-only and non-agentic models never are. Placement is
//! evidence-based: `evidence` says where it comes from ("user" for the
//! owner's own experience, "eval:<date>" for tool/agent_eval runs, empty when
//! unverified). Orchestrator entries stay `candidate` until they pass the
//! subagent and worktree evals. Anthropic only for now (OpenRouter credits).
const std = @import("std");
const anole = @import("anole");
const App = @import("main.zig").App;

pub const Tier = struct {
    id: []const u8,
    name: []const u8,
    blurb: []const u8,
};

pub const Agent = struct {
    model: []const u8,
    effort: []const u8,
    tier: []const u8,
    label: []const u8,
    blurb: []const u8,
    /// May delegate to subagents (the `delegate` tool).
    subagents: bool = false,
    /// Placed by evidence rather than by expectation.
    verified: bool = false,
    /// Up for the tier, pending evals.
    candidate: bool = false,
    evidence: []const u8 = "",
};

pub const tiers = [_]Tier{
    .{ .id = "writer", .name = "Writer", .blurb = "Docs, READMEs, small and well-specified edits." },
    .{ .id = "everyday", .name = "Everyday", .blurb = "Well-scoped features and bug fixes across a few files." },
    .{ .id = "engineer", .name = "Engineer", .blurb = "Multi-file work, debugging, design judgment." },
    .{
        .id = "orchestrator",
        .name = "Orchestrator",
        .blurb = "Subagent-heavy work across worktrees. Proven models only.",
    },
};

pub const agents = [_]Agent{
    .{
        .model = "anthropic/claude-haiku-5.5",
        .effort = "medium",
        .tier = "writer",
        .label = "Haiku 5.5 · medium",
        .blurb = "Fast and cheap; quick edits, docs and explanations.",
    },
    .{
        .model = "anthropic/claude-sonnet-5.5",
        .effort = "medium",
        .tier = "writer",
        .label = "Sonnet 5.5 · medium",
        .blurb = "Writes a solid README or doc pass.",
        .verified = true,
        .evidence = "user",
    },
    .{
        .model = "anthropic/claude-opus-5.5",
        .effort = "medium",
        .tier = "everyday",
        .label = "Opus 5.5 · medium",
        .blurb = "Very good at everyday, well-scoped tasks.",
        .verified = true,
        .evidence = "user",
    },
    .{
        .model = "anthropic/claude-sonnet-5.5",
        .effort = "high",
        .tier = "everyday",
        .label = "Sonnet 5.5 · high",
        .blurb = "Cheaper everyday work with more care.",
    },
    .{
        .model = "anthropic/claude-opus-5.5",
        .effort = "high",
        .tier = "engineer",
        .label = "Opus 5.5 · high",
        .blurb = "A decent pseudo-engineer for multi-file work.",
        .verified = true,
        .evidence = "user",
    },
    .{
        .model = "anthropic/claude-fable-5.1",
        .effort = "medium",
        .tier = "engineer",
        .label = "Fable 5.1 · medium",
        .blurb = "The strongest model; costs the most.",
    },
    .{
        .model = "anthropic/claude-opus-5.5",
        .effort = "xhigh",
        .tier = "orchestrator",
        .label = "Opus 5.5 · xhigh",
        .blurb = "Candidate: leads subagents on large tasks.",
        .subagents = true,
        .candidate = true,
    },
    .{
        .model = "anthropic/claude-fable-5.1",
        .effort = "high",
        .tier = "orchestrator",
        .label = "Fable 5.1 · high",
        .blurb = "Candidate: leads subagents on large tasks.",
        .subagents = true,
        .candidate = true,
    },
};

/// The Code default: the first verified Everyday entry.
pub const default_index = blk: {
    for (agents, 0..) |a, i| {
        if (std.mem.eql(u8, a.tier, "everyday") and a.verified) break :blk i;
    }
    @compileError("no verified everyday agent");
};

fn list(_: *App, _: *anole.Request) struct { tiers: []const Tier, models: []const Agent, default: Agent } {
    return .{ .tiers = &tiers, .models = &agents, .default = agents[default_index] };
}

pub fn routes(app: *anole.Server(App), _: *App) void {
    app.get("/v1/agents", list);
}

test "every agent is in a known tier at a known effort" {
    for (agents) |a| {
        var found = false;
        for (tiers) |t| found = found or std.mem.eql(u8, t.id, a.tier);
        try std.testing.expect(found);
        var ok = false;
        for ([_][]const u8{ "low", "medium", "high", "xhigh", "max" }) |e| ok = ok or std.mem.eql(u8, e, a.effort);
        try std.testing.expect(ok);
        // Orchestrators are candidates until evals say otherwise.
        if (std.mem.eql(u8, a.tier, "orchestrator")) try std.testing.expect(a.candidate or a.verified);
    }
    try std.testing.expectEqualStrings("everyday", agents[default_index].tier);
}
