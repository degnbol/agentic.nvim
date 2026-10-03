-- Claude Code PreToolUse hook (matcher `Agent`) that runs every subagent in
-- the background. Usage: `nvim --clean -l subagent_hook.lua`, with the hook
-- event JSON on stdin and the hook output JSON on stdout. Input that is not a
-- hook event prints nothing on stdout, which keeps the model's tool input, an
-- error on stderr, and exits 1.
--
-- `allow` grants nothing new: the Agent tool already allows itself, and a
-- hook `allow` still yields to settings deny/ask rules.

local ok, event = pcall(vim.json.decode, io.read("*a"))
if
    not (ok and type(event) == "table" and type(event.tool_input) == "table")
then
    io.stderr:write(
        "subagent_hook: not a hook event: " .. tostring(event) .. "\n"
    )
    os.exit(1)
end

io.stdout:write(vim.json.encode({
    hookSpecificOutput = {
        hookEventName = "PreToolUse",
        permissionDecision = "allow",
        permissionDecisionReason = "agentic.nvim: subagents.force_background",
        updatedInput = vim.tbl_extend(
            "force",
            event.tool_input,
            { run_in_background = true }
        ),
    },
}))
