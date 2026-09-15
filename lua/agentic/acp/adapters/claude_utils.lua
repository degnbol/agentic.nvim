--- Constants and helpers for the Claude ACP adapter (claude_agent_acp).
local M = {}

--- Mode-switching tools: maps claude tool name to a short display label.
--- Body contains internal instructions, not user-facing content.
M.MODE_SWITCH_TOOLS = {
    EnterPlanMode = "Plan",
    ExitPlanMode = "Normal",
    EnterWorktree = "Normal",
}

--- claude-agent-acp's per-notification metadata, or an empty table when the
--- notification carries none — `_meta` is genuinely optional (the bridge's
--- untracked-tool fallback emits a `tool_call_update` without it), so a bare
--- three-level index throws.
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
--- @return agentic.acp.ClaudeCodeMeta
function M.claude_meta(update)
    return update._meta and update._meta.claudeCode or {}
end

--- The provider's own name for the tool (`Skill`, `ExitPlanMode`, …), the one
--- stable identifier on a tool-call notification. `title` is a display string
--- the bridge rewords between releases — 0.75.1 turned `Skill` into
--- "Load skill: <name>" and `ExitPlanMode` into "Approve Plan".
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
--- @return string|nil
function M.tool_name(update)
    return M.claude_meta(update).toolName
end

--- The kind this plugin gives a claude tool, keyed on the tool's wire name.
---
--- `tools.js` `toolInfoFromToolUse` kinds every one of these `other`, and for
--- the agent-orchestration family it has no display formatter either, so its
--- default branch titles them with the bare tool name — a gear glyph beside a
--- word the gutter should be saying. Tools sharing one glyph share one kind
--- (`TaskStop`/`TaskOutput`, the three `Cron*`), and their head names the
--- operation instead — see `tool_head`.
---
--- Every value needs a `Glyphs.KIND` entry, or the kind renders a gear that
--- reads as an unrecognised tool; `claude_agent_acp_adapter.test.lua` asserts
--- that for the whole table. The CamelCase spelling is also what keeps
--- `ToolCallRenderer.strip_kind_prefix` off a head built from these.
---
--- `MODE_SWITCH_TOOLS` stays a table of its own: those three share one kind but
--- differ in head label, which no name→kind map can express.
--- @type table<string, string>
M.TOOL_KINDS = {
    SlashCommand = "SlashCommand",
    Skill = "Skill",
    ToolSearch = "ToolSearch",
    SendMessage = "SendMessage",
    ListAgents = "ListAgents",
    Monitor = "Monitor",
    ScheduleWakeup = "ScheduleWakeup",
    TaskStop = "TaskControl",
    TaskOutput = "TaskControl",
    CronCreate = "Cron",
    CronDelete = "Cron",
    CronList = "Cron",
}

--- Server and tool halves of an `mcp__<server>__<tool>` wire name, or nil for
--- any other name.
---
--- The first capture is non-greedy, so it stops at the first `__` — a server
--- name is free to hold single underscores (`claude_ai_Linear`) but none
--- observed holds a double one.
--- @param tool_name string
--- @return string|nil server
--- @return string|nil tool
function M.split_mcp_name(tool_name)
    return tool_name:match("^mcp__(.-)__(.+)$")
end

--- This plugin's kind for a claude tool name, or nil when the bridge's own kind
--- stands.
---
--- `bridge_kind` gates the unbounded `mcp__` population: an MCP tool the bridge
--- does give a formatter keeps the richer kind it assigned. The named tools in
--- `TOOL_KINDS` need no such gate — the bridge kinds every one of them `other`.
--- @param tool_name string
--- @param bridge_kind string|nil The `kind` the bridge put on the notification
--- @return string|nil
function M.tool_kind(tool_name, bridge_kind)
    local kind = M.TOOL_KINDS[tool_name]
    if kind then
        return kind
    end
    if bridge_kind == "other" and M.split_mcp_name(tool_name) then
        return "Mcp"
    end
    return nil
end

--- `raw_input[key]` when it holds a non-empty string, else nil. Every field a
--- head reads is optional: input streams in field by field, and `task_id` is
--- optional outright.
--- @param raw_input agentic.acp.ClaudeAgentRawInput
--- @param key string
--- @return string|nil
local function nonempty(raw_input, key)
    local value = raw_input[key]
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

--- `<subject>: <detail>`, or the subject alone while the detail is missing.
--- @param subject string
--- @param detail string|nil
--- @return string
local function qualified(subject, detail)
    return detail and (subject .. ": " .. detail) or subject
end

--- Head text per minted kind. A head drops the tool name exactly when the
--- glyph is unique to that tool, and keeps it when the glyph is a family's —
--- so the family builders read the name and the rest return "" until their
--- field lands. Nothing is lost for the two sign-less consumers: the picker
--- preview and the Path B prose prefix both print the kind beside the head.
--- @type table<string, fun(raw_input: agentic.acp.ClaudeAgentRawInput, tool_name: string): string>
local HEADS = {
    ToolSearch = function(raw_input)
        return nonempty(raw_input, "query") or ""
    end,
    -- `summary` is documented in the tool's own input schema as "a 5-10 word
    -- label for your own transcript row (not transmitted)" — a head is
    -- precisely what it is for. Shape matches the SubAgent head.
    SendMessage = function(raw_input)
        local to = nonempty(raw_input, "to")
        return to and qualified(to, nonempty(raw_input, "summary")) or ""
    end,
    Monitor = function(raw_input)
        return nonempty(raw_input, "description") or ""
    end,
    ScheduleWakeup = function(raw_input)
        return nonempty(raw_input, "reason") or ""
    end,
    ListAgents = function()
        return ""
    end,
    -- `tools.js` has no formatter for SlashCommand either, so its title is the
    -- bare tool name until `__apply_raw_input` swaps in the command line.
    SlashCommand = function()
        return ""
    end,
    TaskControl = function(raw_input, tool_name)
        return qualified(tool_name, nonempty(raw_input, "task_id"))
    end,
    Cron = function(raw_input, tool_name)
        return qualified(tool_name, nonempty(raw_input, "cron"))
    end,
    Mcp = function(_, tool_name)
        local server, tool = M.split_mcp_name(tool_name)
        return server and (server .. ": " .. tool) or tool_name
    end,
}

--- Head text for a kind this plugin minted. Returns nil when the bridge's own
--- title stands (Skill and the mode switches, the ones it does word itself),
--- "" to clear a title that is only the tool's name, and the name-derived head
--- for the family kinds. `raw_input` may be empty — every field it reads is
--- optional, so the same call builds the base head before any input has
--- streamed and the refined head once it has.
--- @param kind string|nil
--- @param raw_input agentic.acp.ClaudeAgentRawInput
--- @param tool_name string
--- @return string|nil
function M.tool_head(kind, raw_input, tool_name)
    local build = kind and HEADS[kind]
    if not build then
        return nil
    end
    return build(raw_input, tool_name)
end

--- Rewrite a leading "grep " in a synthesised search command to "rg ".
--- The Claude Code Grep tool is statically-linked ripgrep, but
--- claude-agent-acp synthesises rawInput.command using "grep" as the program
--- name. Flag set maps 1:1 to rg, so a prefix swap produces an accurate and
--- copy-pasteable invocation.
--- @param argument string|nil
--- @return string|nil
function M.rewrite_grep_to_rg(argument)
    if argument and argument:sub(1, 5) == "grep " then
        return "rg " .. argument:sub(6)
    end
    return argument
end

--- SDK placeholder titles emitted before tool input has finished streaming.
--- The bridge (`@agentclientprotocol/claude-agent-acp` tools.js
--- `toolInfoFromToolUse`) returns these literals when the relevant input
--- field is still undefined. We swap them for an empty string so the
--- rendered block shows a blank placeholder line until the actual argument
--- arrives in a later tool_call_update.
M.PLACEHOLDER_TITLES = {
    Terminal = true, -- Bash with no command
    Task = true, -- Task with no description
    ["Read File"] = true, -- Read with no file_path
    Write = true, -- Write with no file_path
    Edit = true, -- Edit with no file_path
    grep = true, -- Grep with no flags/pattern
    Find = true, -- Glob with no pattern/path
    ["Load skill"] = true, -- Skill with no skill name
    Fetch = true, -- WebFetch with no URL
    ["Web search"] = true, -- WebSearch with no query
    ["Unknown Tool"] = true, -- catch-all in tools.js
}

--- @param title string|nil
--- @return string|nil
function M.suppress_placeholder_title(title)
    if title and M.PLACEHOLDER_TITLES[title] then
        return ""
    end
    return title
end

--- Strip the ```console wrapper the bridge adds around Bash output. tools.js
--- `toolUpdateFromToolResult` formats stdout/stderr as
--- `` `\`\`\`console\n${output}\n\`\`\` ``, so the body arrives already fenced.
--- The chat renderer wraps the body in its own fence, so without stripping the
--- output is double-fenced (an outer fence widened by `safe_fence` around the
--- bridge's inner one). Returns the inner lines plus whether a fence was found,
--- so callers can tell bridge-fenced output apart from the unfenced description
--- echo the initial tool_call carries.
--- @param body string[]|nil
--- @return string[]|nil inner
--- @return boolean was_fenced
function M.strip_console_fence(body)
    if
        body
        and #body >= 2
        and body[1]:match("^```%a*$")
        and body[#body]:match("^```$")
    then
        return vim.list_slice(body, 2, #body - 1), true
    end
    return body, false
end

return M
