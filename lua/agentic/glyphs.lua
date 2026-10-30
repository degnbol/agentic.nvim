--- Nerd Font glyph vocabulary for the chat gutter, the headers and the
--- statusline.
--- Collected in one module so a new glyph can be checked against every
--- existing one at a glance: the chat window is `signcolumn=yes:1`, so a
--- glyph is the whole gutter identity a row gets. Two acts sharing one are
--- indistinguishable in the gutter; two tools doing one act may share one,
--- and the head text names which tool ran.
---
--- Glyphs are `nf-md-*`, never emoji. A `sign_text` must be `glyph .. " "` —
--- `nvim_buf_set_extmark` accepts 1-2 cells and rejects 3, and the trailing
--- space is what a wide-aspect glyph expands into instead of rendering squished
--- (kitty renders a Private Use character across the following spaces).
---
--- @class agentic.Glyphs
local Glyphs = {}

--- Identity of an agent, the main one or a subagent: the lead glyph of their
--- headers and a subagent's tool call.
Glyphs.AGENT = "󰚩"

--- Header state glyphs, shown after the title while the state holds.
--- @type table<agentic.ui.HeaderState, string>
Glyphs.HEADER_STATE = {
    permission = "?", -- plain text: the circled nf-md-help_circle is hard to read at text size
    running = "󰔟", -- nf-md-timer_sand
    idle = "󰂞", -- nf-md-bell_ring
}

--- Per-kind tool-call glyph, keyed on the lowercased ACP kind; unlisted kinds
--- fall back to `KIND_DEFAULT`.
---
--- Covers every kind any adapter can produce — the lowercase protocol set and
--- the CamelCase kinds this plugin's own adapters mint
--- (`ClaudeUtils.TOOL_KINDS`, plus the pattern-derived `Mcp`). Sized that way
--- because a gutter that cannot tell a file deletion from an unrecognised tool
--- is the thing this table exists to prevent, and only the Claude adapter's
--- subset was covered before. `write` is deliberately the closest neighbour of
--- `edit` — a whole-file write and a hunk edit are the same act at different
--- granularity, and the diff already separates them.
---
--- The agent-orchestration family is the other place one glyph covers several
--- tools: `taskcontrol` and `cron` are a family each, and their head names the
--- operation. `md-robot_outline` against `subagent`'s filled 󰚩, and `md-alarm` or `md-autorenew` against the round `status_icons` faces, are
--- the outline-vs-filled indistinguishability this module exists to prevent —
--- hence a tray and a calendar.
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
    subagent = Glyphs.AGENT,
    skill = "󰗚",
    todowrite = "󰝖",
    -- Both plan-mode tools arrive as this one kind; the head text ("Plan" /
    -- "Normal") is what tells them apart.
    switch_mode = "󰍍",
    -- The toolbox is what a tool search searches; the magnifier is spent on
    -- `search`, and the head carries the query either way.
    toolsearch = "󰦬",
    sendmessage = "󰒊",
    -- A radar sweeping until a condition holds, rather than `md-monitor_eye`,
    -- which reads as a screen and collides in spirit with `read`'s eye.
    monitor = "󰐷",
    taskcontrol = "󱊖",
    -- A "Z" for a single fire, against `cron`'s recurring calendar.
    schedulewakeup = "󰒲",
    cron = "󰃰",
    -- `think`, `slashcommand`, `listagents` and `mcp` are assigned below, from
    -- THINKING, COMMAND_DEFAULT and COMMAND: each is one identity reached
    -- through two channels.
}

--- The kind carries no identity worth showing. Two populations reach it, and
--- the gutter cannot separate them: `other`, which the protocol defines and
--- `AcpKind.PROTOCOL_KINDS` accepts — the Claude bridge kinds a large share of its
--- tools that way — and kinds no adapter recognises at all. A gear therefore
--- does *not* imply the "unknown ACP tool call kind" warning fired.
Glyphs.KIND_DEFAULT = "󰒓"

--- Identity of a collapsed thought run (`MessageWriter:flush_thought_run`).
--- The head family is otherwise spent on `/model` (󱍐), so the brain keeps
--- thinking distinguishable from switching which model does it.
Glyphs.THINKING = "󰧑"

--- `THINKING` as a `sign_text`.
Glyphs.THINKING_SIGN = Glyphs.THINKING .. " "

--- A `think` tool call is the same act as a thought run, arriving as a tool
--- rather than as streamed thought chunks. Sharing the glyph is the point:
--- what the reader wants to know is that the model stopped to think.
Glyphs.KIND.think = Glyphs.THINKING

--- Identity of a hook's activity (`MessageWriter:write_hook_block`). The one
--- region whose glyph names the mechanism rather than the content: a hook can
--- deliver anything, so the reader's question is which script spoke.
Glyphs.HOOK = "󰛢"

--- Identity of a received `message` row. A letter against
--- `KIND.sendmessage`'s send arrow, which marks a sent one.
Glyphs.MESSAGE_RECEIVED = "󰇮"

--- A subagent handing its result back to its caller: the `SubagentHandback`
--- tool call and the `result` message row are one identity.
Glyphs.HANDBACK = "󰌑"
Glyphs.KIND.subagenthandback = Glyphs.HANDBACK

--- Glyph of a session message row, keyed by the row's kind, or by its view
--- (`sent`/`received`) for a `message` row.
--- @type table<"task"|"result"|"sent"|"received", string>
Glyphs.MESSAGE = {
    task = "󰙓",
    result = Glyphs.HANDBACK,
    sent = Glyphs.KIND.sendmessage,
    received = Glyphs.MESSAGE_RECEIVED,
}

--- A subagent run's end, when its state has no usable `Config.status_icons`
--- entry. A flag rather than a circle: `status_icons.cancelled` is a round
--- face.
Glyphs.RUN_ENDED = "󰈼"

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

Glyphs.PROVIDER = "󰚥"
Glyphs.RESUME = "󰁯"
Glyphs.AUTH = "󰍂"

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
--- changes. Grant uses a handshake rather than a lock or shield because adding
--- a scope *grants* auto-approval — the guarding metaphors read the wrong way
--- round. Removing it reuses the same glyph struck through, Nerd Fonts having
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
    grant = "󱈘",
    permissions = "󰌋",
    -- Work
    init = "󱀺",
    review = "󰭎",
    ["security-review"] = "󰶚",
    insights = "󱕍",
    ["team-onboarding"] = "󱟄",
    -- Account
    login = Glyphs.AUTH,
    logout = "󰍃",
    -- Diagnostics
    doctor = "󰓙",
    help = "󰘥",
    heapdump = "󰍛",
}

--- `/agents` and the `ListAgents` tool are one identity reached through two
--- channels, as are `/mcp` and an `mcp__*` tool call — the relation
--- `KIND.think`/`THINKING` and `COMMAND.hooks`/`HOOK` already encode. Written
--- as assignments rather than repeated codepoints so the shared identity
--- survives a later change to either side.
Glyphs.KIND.listagents = Glyphs.COMMAND.agents
Glyphs.KIND.mcp = Glyphs.COMMAND.mcp

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

--- Gauge of a fraction used: an empty circle, then 1 to 8 eighths filled.
--- @type string[]
Glyphs.GAUGE =
    { "󰝦", "󰪞", "󰪟", "󰪠", "󰪡", "󰪢", "󰪣", "󰪤", "󰪥" }

return Glyphs
