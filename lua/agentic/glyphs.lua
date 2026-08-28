--- Nerd Font glyph vocabulary for the chat buffer. Collected in one module so a
--- new glyph can be checked against every existing one at a glance: the chat
--- window is `signcolumn=yes:1`, so a glyph is the whole identity a row gets and
--- two regions sharing one are indistinguishable.
---
--- Glyphs are `nf-md-*`, never emoji. A `sign_text` must be `glyph .. " "` —
--- `nvim_buf_set_extmark` accepts 1-2 cells and rejects 3, and the trailing
--- space is what a wide-aspect glyph expands into instead of rendering squished
--- (kitty renders a Private Use character across the following spaces).
---
--- Reserved, do not spend elsewhere: 󰋚 history (a future rewind).
--- @class agentic.Glyphs
local Glyphs = {}

--- Per-kind tool-call glyph, keyed on the lowercased ACP kind; unlisted kinds
--- fall back to `KIND_DEFAULT`. edit and write intentionally share identity
--- (both arrive as kind == "edit", distinguished only by diff content).
--- @type table<string, string>
Glyphs.KIND = {
    read = "󰈈",
    edit = "󰏫",
    execute = "󰆍",
    search = "󰍉",
    fetch = "󰖟",
    websearch = "󰖟",
    subagent = "󰚩",
}

Glyphs.KIND_DEFAULT = "󰒓"

--- Identity of a collapsed thought run (`MessageWriter:flush_thought_run`).
--- The head family is otherwise spent on the model-switch notice (󱍐), so the
--- brain keeps thinking distinguishable from switching which model does it.
Glyphs.THINKING = "󰧑"

--- `THINKING` as a sign. Named because it is written and read at opposite ends
--- of a dispatch — the writer stamps it, `folds.lua` matches on it to decide
--- whether a fold summary carries a character count — and a padding change on
--- one side alone would silently drop the count.
Glyphs.THINKING_SIGN = Glyphs.THINKING .. " "

--- Per-command glyph for a client-side command notice
--- (`MessageWriter:write_notice`). Every value is distinct from `KIND`: a gutter
--- glyph reads as an identity, so a command confirmation must not look like a
--- tool call. Trust uses a handshake rather than a lock or shield because
--- setting a scope *grants* auto-approval — the guarding metaphors read the
--- wrong way round. Clearing it reuses the same glyph struck through, Nerd Fonts
--- having no struck-through variant.
--- @type table<string, string>
Glyphs.NOTICE = {
    TRUST = "󱈘",
    RENAME = "󱈤",
    CONTEXT = "󰊚",
    MODEL = "󱍐",
    PROVIDER = "󰚥",
    RESUME = "󰁯",
}

return Glyphs
