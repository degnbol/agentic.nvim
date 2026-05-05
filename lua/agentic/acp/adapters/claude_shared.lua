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

return M
