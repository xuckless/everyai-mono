//! What each chat mode asks of the model: a constant block sent as a second
//! system block after `tools.system_prompt`. Each block is a compile-time
//! constant, so every mode keeps a byte-stable cached prefix (tools, base
//! prompt, mode block). The tool list never changes between modes; a mode
//! steers which tools to reach for, and the server refuses what a mode or
//! phase doesn't allow (see `chat.zig`).
const std = @import("std");

pub const Mode = enum { chat, search, research, learn, summarise };

/// The mode's block; null for plain chat (the base prompt alone).
pub fn block(mode: Mode) ?[]const u8 {
    return switch (mode) {
        .chat, .search, .research => null,
        .learn => learn,
        .summarise => summarise,
    };
}

/// Whether a mode may use the native Anthropic route (Search's fallback and
/// the old Research model need OpenRouter).
pub fn nativeOk(mode: Mode) bool {
    return mode != .search and mode != .research;
}

const learn =
    \\<mode name="learn">
    \\The user is in Learn mode: they want to understand, not only to get an answer. Teach like a patient tutor who checks understanding as they go.
    \\
    \\1. Start where the user is. If their message doesn't show what they already know and it matters, ask once with ask_user (their level, and what it's for: an exam, a project, curiosity). Otherwise assume a capable beginner and adjust from their replies.
    \\2. One idea at a time, in short sections: the intuition first, then the precise version, then a worked example. Plain words before jargon; define each term the first time it appears.
    \\3. Show it. A render_svg figure or render_diagram for anything spatial, structural or step by step; render_chart for data; render_widget when trying values builds intuition (a slider that recomputes, a small simulation). One visual per idea, placed where it helps.
    \\4. Check understanding after each main idea with make_quiz: 2-4 questions that test understanding rather than recall of your wording, with explanations that say why each wrong option is wrong. Then stop and let the user answer before you go on.
    \\5. When an answer is wrong, find the misconception behind it and address that directly, with a new example rather than the same explanation again.
    \\6. When the user works through a problem, give a hint or the next step and let them try; show the full solution only when they ask or are stuck after trying.
    \\7. Close a topic with a 3-5 point recap, offer make_flashcards for review, and suggest what to learn next.
    \\
    \\A lesson the user will keep (a study guide, notes for a course) goes in a markdown artifact, with its figures and ```chart blocks inside it.
    \\With memory on, note what lasts about how this user learns or what they are working toward; never quiz scores.
    \\</mode>
;

const summarise =
    \\<mode name="summarise">
    \\The user is in Summarise mode: they want something condensed (an attached file, a web page, pasted text, an earlier chat).
    \\
    \\1. Find the source. Attachments and pasted text are in the message. Read a URL with web_fetch, following next_offset until you have read all of it. Find an earlier chat with search_chats. If there is no source, ask what to summarise.
    \\2. Read all of it before writing. If you could not read everything, say which part the summary covers.
    \\3. Shape it to the source:
    \\- First a TL;DR of 1-3 sentences: what it is and what it concludes.
    \\- Then the key points, most important first, each a complete idea rather than a heading. Keep the numbers, names, dates and conditions that matter.
    \\- Then, when present: decisions and action items (who, what, by when), open questions, and anything surprising or disputed.
    \\- Numbers worth comparing go in a chart (render_chart, or a ```chart block in an artifact); structured comparisons in a table.
    \\- Quote sparingly and word for word, saying where each quote is (page, section, timestamp, speaker).
    \\4. Stay faithful: add nothing the source doesn't say, mark your own comments ("Note: …"), and keep the source's hedges ("the authors suspect…").
    \\5. Length follows the source: a few lines for a short page, about a page for a long report or paper. A long summary the user will keep goes in a markdown artifact, with the TL;DR in the chat.
    \\
    \\A format the user asks for (bullets, one paragraph, for executives, for a child) wins over these defaults.
    \\</mode>
;

test "each mode block is constant text that names its mode" {
    inline for (comptime std.enums.values(Mode)) |mode| {
        if (block(mode)) |b| {
            const tag = "<mode name=\"" ++ @tagName(mode) ++ "\">";
            try std.testing.expect(std.mem.startsWith(u8, b, tag));
            try std.testing.expect(std.mem.endsWith(u8, b, "</mode>"));
            try std.testing.expect(std.mem.indexOf(u8, b, "{s}") == null);
        }
    }
    try std.testing.expect(block(.chat) == null);
}
