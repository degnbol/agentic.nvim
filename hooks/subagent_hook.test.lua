local assert = require("tests.helpers.assert")

local HOOK = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
    .. "/subagent_hook.lua"

--- Run the hook the way the CLI does: event JSON on stdin.
--- @param stdin string
--- @return vim.SystemCompleted
local function run_hook(stdin)
    return vim.system(
        { vim.v.progpath, "--clean", "-l", HOOK },
        { stdin = stdin, text = true }
    ):wait()
end

describe("hooks/subagent_hook", function()
    it("keeps every input field and sets run_in_background", function()
        local result = run_hook(vim.json.encode({
            hook_event_name = "PreToolUse",
            tool_name = "Agent",
            tool_input = {
                description = "d",
                prompt = "p",
                subagent_type = "Explore",
                run_in_background = false,
            },
        }))

        assert.equal(0, result.code)
        assert.same({
            hookSpecificOutput = {
                hookEventName = "PreToolUse",
                permissionDecision = "allow",
                permissionDecisionReason = "agentic.nvim: subagents.force_background",
                updatedInput = {
                    description = "d",
                    prompt = "p",
                    subagent_type = "Explore",
                    run_in_background = true,
                },
            },
        }, vim.json.decode(result.stdout))
    end)

    it("fails without stdout for input that is not an event", function()
        local result = run_hook("not json")

        assert.equal(1, result.code)
        assert.equal("", result.stdout)
        assert.is_not.equal("", result.stderr)
    end)
end)
