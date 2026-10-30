//! Tool definitions and the system prompt. Both are compile-time constants,
//! so every request carries a byte-identical prefix: prompt caches (explicit
//! breakpoints on Anthropic/Gemini, implicit elsewhere) hit across turns and
//! users. Never interpolate per-request data into these.
const std = @import("std");

pub const Kind = enum {
    /// Rendered by the app; the model gets a short acknowledgement.
    ui,
    /// Executed by the server; the model gets the result.
    server,
};

pub fn kindOf(name: []const u8) ?Kind {
    inline for (ui_tools) |t| if (std.mem.eql(u8, t, name)) return .ui;
    inline for (server_tools) |t| if (std.mem.eql(u8, t, name)) return .server;
    return null;
}

pub const ui_tools = [_][]const u8{ "create_artifact", "update_artifact", "render_svg", "render_diagram", "render_chart", "make_quiz", "make_flashcards", "make_slides" };
pub const server_tools = [_][]const u8{ "web_fetch", "generate_image" };

pub const system_prompt =
    \\You are EveryAI, a helpful, precise assistant inside a desktop and mobile chat app.
    \\Format answers in GitHub-flavored Markdown. Use LaTeX for math ($inline$, $$display$$).
    \\When web sources are provided, cite them inline as [1], [2] matching their order.
    \\
    \\You have tools that render rich, interactive content in the app. Prefer them when they help:
    \\- create_artifact: substantial standalone content the user may keep, edit or download (documents, essays, code files, HTML pages, long lists). Not for short answers.
    \\- update_artifact: revise an artifact you created earlier (send the full new content).
    \\- render_svg: an inline vector illustration while explaining (shapes, labeled sketches, geometry, simple scenes). Self-contained SVG, viewBox set, no scripts or external references.
    \\- render_diagram: flowcharts, sequence, class, state, ER, timeline or mind-map diagrams as Mermaid.
    \\- render_chart: data visualizations from numbers (line, bar, pie, scatter, area).
    \\- make_quiz: multiple-choice questions to test understanding, each with the correct option (answer_index) or, for select-all-that-apply questions, every correct option (answer_indices), and an explanation.
    \\- make_flashcards: study cards (front/back).
    \\- make_slides: a presentation deck the user can present and export to PowerPoint.
    \\- web_fetch: read a specific URL the user gives you.
    \\- generate_image: create a raster image (photos, paintings, logos). Use render_svg for diagrams instead.
    \\Keep talking normally around tool calls: introduce what you made and add the explanation in text.
;

/// OpenAI tool schema list, serialized once. Order and bytes are fixed.
pub const definitions =
    \\[
    \\{"type":"function","function":{"name":"create_artifact","description":"Create a standalone artifact shown in the side panel, which the user can view, edit, copy and download.","parameters":{"type":"object","properties":{"id":{"type":"string","description":"Short kebab-case id, unique in this chat"},"title":{"type":"string"},"kind":{"type":"string","enum":["markdown","code","html","svg","mermaid"]},"language":{"type":"string","description":"For kind=code: the language"},"content":{"type":"string"}},"required":["id","title","kind","content"]}}},
    \\{"type":"function","function":{"name":"update_artifact","description":"Replace an existing artifact's content with a new version.","parameters":{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string"},"content":{"type":"string"}},"required":["id","content"]}}},
    \\{"type":"function","function":{"name":"render_svg","description":"Show an inline SVG illustration in the conversation.","parameters":{"type":"object","properties":{"title":{"type":"string"},"svg":{"type":"string","description":"A complete <svg> element with a viewBox; no scripts, no external references"}},"required":["svg"]}}},
    \\{"type":"function","function":{"name":"render_diagram","description":"Show a Mermaid diagram in the conversation.","parameters":{"type":"object","properties":{"title":{"type":"string"},"mermaid":{"type":"string","description":"Mermaid source"}},"required":["mermaid"]}}},
    \\{"type":"function","function":{"name":"render_chart","description":"Show a data chart in the conversation.","parameters":{"type":"object","properties":{"title":{"type":"string"},"type":{"type":"string","enum":["line","bar","pie","scatter","area"]},"x_label":{"type":"string"},"y_label":{"type":"string"},"series":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"points":{"type":"array","items":{"type":"object","properties":{"x":{"type":["string","number"]},"y":{"type":"number"}},"required":["x","y"]}}},"required":["name","points"]}}},"required":["type","series"]}}},
    \\{"type":"function","function":{"name":"make_quiz","description":"Show an interactive multiple-choice quiz.","parameters":{"type":"object","properties":{"title":{"type":"string"},"questions":{"type":"array","items":{"type":"object","properties":{"question":{"type":"string"},"options":{"type":"array","items":{"type":"string"},"minItems":2,"maxItems":6},"answer_index":{"type":"integer","description":"0-based index of the correct option (single-answer questions)"},"answer_indices":{"type":"array","items":{"type":"integer"},"description":"0-based indices of every correct option, for select-all-that-apply questions"},"explanation":{"type":"string"}},"required":["question","options","explanation"]}}},"required":["title","questions"]}}},
    \\{"type":"function","function":{"name":"make_flashcards","description":"Show a deck of flip cards for study.","parameters":{"type":"object","properties":{"title":{"type":"string"},"cards":{"type":"array","items":{"type":"object","properties":{"front":{"type":"string"},"back":{"type":"string"}},"required":["front","back"]}}},"required":["title","cards"]}}},
    \\{"type":"function","function":{"name":"make_slides","description":"Create a slide deck the user can present and export to PowerPoint.","parameters":{"type":"object","properties":{"title":{"type":"string"},"subtitle":{"type":"string"},"theme":{"type":"string","enum":["light","dark","navy","minimal"]},"slides":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"bullets":{"type":"array","items":{"type":"string"}},"body":{"type":"string","description":"Markdown body when bullets do not fit"},"notes":{"type":"string","description":"Speaker notes"}},"required":["title"]}}},"required":["title","slides"]}}},
    \\{"type":"function","function":{"name":"web_fetch","description":"Fetch a web page and return its readable text.","parameters":{"type":"object","properties":{"url":{"type":"string"}},"required":["url"]}}},
    \\{"type":"function","function":{"name":"generate_image","description":"Generate a raster image from a prompt and show it to the user.","parameters":{"type":"object","properties":{"prompt":{"type":"string"},"aspect_ratio":{"type":"string","enum":["1:1","16:9","9:16","4:3","3:4"]}},"required":["prompt"]}}}
    \\]
;

test "definitions are valid JSON and every tool has a kind" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), definitions, .{});
    try std.testing.expectEqual(ui_tools.len + server_tools.len, v.array.items.len);
    for (v.array.items) |t| {
        const name = t.object.get("function").?.object.get("name").?.string;
        try std.testing.expect(kindOf(name) != null);
    }
}
