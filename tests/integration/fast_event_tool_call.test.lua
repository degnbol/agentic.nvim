local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

-- The stdio transport hands messages over from its libuv read callback, a
-- fast event context, so building a tool call must not call vimscript
-- functions or read `vim.env`.
describe("Tool call built in a fast event", function()
    local child = Child.new()

    before_each(child.launch)
    after_each(child.stop)

    it("claude adapter stamps the shell without E5560", function()
        child.lua([[
            local Adapter = require("agentic.acp.adapters.claude_agent_acp_adapter")
            local ClaudeUtils = require("agentic.acp.adapters.claude_utils")
            _G.expected_shell = ClaudeUtils.exec_shell(nil) or vim.NIL
            local client = Adapter:new(
                { name = "claude", command = "claude-agent-acp" },
                function() end
            )
            local timer = vim.uv.new_timer()
            timer:start(0, 0, function()
                timer:close()
                local ok, result = pcall(function()
                    return client:__build_tool_call_message({
                        sessionUpdate = "tool_call",
                        toolCallId = "tc-1",
                        kind = "execute",
                        status = "pending",
                        title = "ls",
                        rawInput = {},
                    }, "s-1")
                end)
                _G.result = ok and { shell = result.shell or vim.NIL }
                    or { err = tostring(result) }
            end)
        ]])
        vim.uv.sleep(100)

        assert.same(
            { shell = child.lua_get("_G.expected_shell") },
            child.lua_get("_G.result")
        )
    end)
end)
