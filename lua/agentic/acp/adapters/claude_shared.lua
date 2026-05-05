--- Shared constants and helpers for Claude ACP adapters (claude_acp + claude_agent_acp).
local M = {}

--- Mode-switching tools: maps ACP tool_call title to a short display label.
--- Body contains internal instructions, not user-facing content.
M.MODE_SWITCH_TOOLS = {
    EnterPlanMode = "Plan",
    ExitPlanMode = "Normal",
    EnterWorktree = "Normal",
}

--- Resolve mode-switch label from a tool_call title.
--- ACP has no stable tool-name field — `title` is the only identifier, and
--- the provider may send a user-facing string (e.g. "Ready to code?",
--- "Ready for implementation") instead of the internal tool name.
--- @param title string
--- @return string|nil label "Plan" or "Normal", or nil if not a mode switch
function M.mode_switch_label(title)
    local label = M.MODE_SWITCH_TOOLS[title]
    if label then
        return label
    end
    -- Provider exit-plan titles start with "Ready" (e.g. "Ready to code?")
    if title:match("^Ready%s") then
        return "Normal"
    end
    return nil
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

return M
