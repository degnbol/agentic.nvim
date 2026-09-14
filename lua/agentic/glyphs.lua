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
--- @class agentic.Glyphs
local Glyphs = {}

--- Per-kind tool-call glyph, keyed on the lowercased ACP kind; unlisted kinds
--- fall back to `KIND_DEFAULT`.
---
--- Covers every kind any adapter can produce — the lowercase protocol set and
--- the CamelCase kinds this plugin's own adapters mint (`acp_kind.lua` names
--- the split). Sized that way because a gutter that cannot tell a file deletion
--- from an unrecognised tool is the thing this table exists to prevent, and
--- only the Claude adapter's subset was covered before. `write` is deliberately
--- the closest neighbour of `edit` — a whole-file write and a hunk edit are the
--- same act at different granularity, and the diff already separates them.
--- @type table<string, string>
Glyphs.KIND = {
    read = "󰈈",
    edit = "󰏫",
    write = "󰷈",
    create = "󰝒",
    delete = "󰩹",
    move = "󰪹",
    execute = "󰆍",
    search = "󰍉",
    fetch = "󰖟",
    websearch = "󰖟",
    subagent = "󰚩",
    skill = "󰗚",
    todowrite = "󰝖",
    -- Both plan-mode tools and EnterWorktree arrive as this one kind; the head
    -- text ("Plan" / "Normal") is what tells them apart.
    switch_mode = "󰍍",
    -- `think` and `slashcommand` are assigned below, from THINKING and
    -- COMMAND_DEFAULT: each is one identity reached through two channels.
}

--- The kind carries no identity worth showing. Two populations reach it, and
--- the gutter cannot separate them: `other`, which the protocol defines and
--- `KNOWN_ACP_KINDS` accepts — the Claude bridge kinds a large share of its
--- tools that way — and kinds no adapter recognises at all. A gear therefore
--- does *not* imply the "unknown ACP tool call kind" warning fired.
Glyphs.KIND_DEFAULT = "󰒓"

--- Identity of a collapsed thought run (`MessageWriter:flush_thought_run`).
--- The head family is otherwise spent on `/model` (󱍐), so the brain keeps
--- thinking distinguishable from switching which model does it.
Glyphs.THINKING = "󰧑"

--- `THINKING` as a sign. Named because it is written and read at opposite ends
--- of a dispatch — the writer stamps it, `folds.lua` matches on it to decide
--- whether a fold summary carries a character count — and a padding change on
--- one side alone would silently drop the count.
Glyphs.THINKING_SIGN = Glyphs.THINKING .. " "

--- A `think` tool call is the same act as a thought run, arriving as a tool
--- rather than as streamed thought chunks. Sharing the glyph is the point:
--- what the reader wants to know is that the model stopped to think.
Glyphs.KIND.think = Glyphs.THINKING

--- Identity of a hook's activity (`MessageWriter:write_hook_block`). The one
--- region whose glyph names the mechanism rather than the content: a hook can
--- deliver anything, so the reader's question is which script spoke.
Glyphs.HOOK = "󰛢"

--- Identity of a failure the provider reported for the turn
--- (`MessageWriter:write_error_message`). A crossed circle rather than the alert
--- triangle: the triangle reads as a warning, and every region this marks is a
--- turn that produced no answer.
Glyphs.ERROR = "󰅚"

--- Identity of a prompt the user wrote themselves — the absence of a command
--- word rather than a glyph of its own, and the only sign here that is not
--- `nf-md`. In `COMMAND`'s channel, so it belongs to the same check for
--- accidental collisions.
Glyphs.PROMPT = "❯"

--- Identities reported after the fact, with no command that asks for them: a
--- provider swap, and a session restored through the picker or `:AgenticResume`.
Glyphs.PROVIDER = "󰚥"
Glyphs.RESUME = "󰁯"

--- Per-command glyph, keyed on the command word without its leading slash (the
--- word `PromptBlocks.command` returns). Stamped on the heading row of whatever
--- the command produces — a local command's notice (`write_notice`) or a
--- forwarded command's prompt row (`write_user_prompt`).
---
--- Keyed by word rather than by who handles it, because that split is not the
--- reader's: `/compact` goes to the provider and `/context` is answered here,
--- and both are the user asking about the same thing. Which words exist is
--- provider-specific, so an unlisted one is expected, not an error — it takes
--- `COMMAND_DEFAULT`.
---
--- Deliberately not sized to what the provider advertises. Claude's
--- `SlashCommand` carries `aliases` ("/cost and /stats both resolve to
--- /usage"), and the bridge both filters on the canonical name and drops the
--- alias list — so a typeable word can be absent from every list the plugin
--- sees. The word the user typed is the only thing this table can key on.
---
--- `new` and `clear` are synonyms handled by one code path, so they share a
--- glyph. Both reset the chat buffer they would be written to, so neither is
--- visible today; they are listed so the vocabulary stays complete if that
--- changes. Trust uses a handshake rather than a lock or shield because setting
--- a scope *grants* auto-approval — the guarding metaphors read the wrong way
--- round. Clearing it reuses the same glyph struck through, Nerd Fonts having
--- no struck-through variant.
--- @type table<string, string>
Glyphs.COMMAND = {
    -- Session
    new = "󰃢",
    clear = "󰃢",
    delete = "󰗩",
    rename = "󱈤",
    resume = Glyphs.RESUME,
    rewind = "󰋚",
    export = "󰈇",
    -- Context window
    compact = "󰡍",
    context = "󰊚",
    cost = "󰇁",
    usage = "󰞯",
    ["extra-usage"] = "󱉡",
    memory = "󰠮",
    -- Agent setup
    model = "󱍐",
    agents = "󰡉",
    mcp = "󰌘",
    config = "󰘮",
    hooks = Glyphs.HOOK,
    -- Permissions
    trust = "󱈘",
    permissions = "󰌋",
    -- Work
    init = "󱀺",
    review = "󰭎",
    ["security-review"] = "󰶚",
    insights = "󱕍",
    ["team-onboarding"] = "󱟄",
    -- Account
    login = "󰍂",
    logout = "󰍃",
    -- Diagnostics
    doctor = "󰓙",
    help = "󰘥",
    heapdump = "󰍛",
}

--- A command word with no entry of its own. A book rather than something
--- neutral because skills dominate this population: the provider keeps skills
--- and built-in commands in one flat namespace (the SDK's `SlashCommand` type
--- documents `name` as "Skill name"), and the built-ins are the half that has
--- glyphs. Anything left is a skill or a user-defined command — both of them a
--- documented procedure invoked by name.
Glyphs.COMMAND_DEFAULT = Glyphs.KIND.skill

--- The agent calling a slash command as a tool, which a survey of 1,973 cached
--- sessions never once caught happening — the adapter mints this kind, nothing
--- has yet made it. Assigned anyway so the kind cannot reach `KIND_DEFAULT` and
--- read as an unrecognised tool. `KIND` is all `render_decorations` receives,
--- so even when it does fire the head cannot name the command the way a
--- user-typed one does; it takes the glyph an unlisted word would.
Glyphs.KIND.slashcommand = Glyphs.COMMAND_DEFAULT

return Glyphs
