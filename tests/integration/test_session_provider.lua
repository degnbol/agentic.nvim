local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("per-session provider", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
vim.cmd("Agentic")
_G.a = require("agentic.session_registry").current()
_G.b = require("agentic").new_session({
    provider = "opencode-acp",
    auto_add_to_context = false,
})
]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    --- @return integer
    local function instance_count()
        return child.lua_get(
            [[vim.tbl_count(require("agentic.acp.agent_instance")._instances)]]
        )
    end

    it("runs each session on its own provider", function()
        assert.equal(
            "claude-agent-acp",
            child.lua_get("_G.a.agent.provider_name")
        )
        assert.equal("opencode-acp", child.lua_get("_G.b.agent.provider_name"))
        assert.is_true(child.lua_get("_G.a.agent ~= _G.b.agent"))
        assert.equal(
            "claude-agent-acp",
            child.lua_get([[require("agentic.config").provider]])
        )
        assert.equal(2, instance_count())
    end)

    it("starts a new session on the current session's provider", function()
        child.lua([[
_G.c = require("agentic").new_session({ auto_add_to_context = false })
]])

        assert.equal("opencode-acp", child.lua_get("_G.c.agent.provider_name"))
        assert.is_true(child.lua_get("_G.c.agent == _G.b.agent"))
    end)

    it("switches only the session it is called on", function()
        child.lua([[
_G.c = require("agentic").new_session({ auto_add_to_context = false })
_G.b_agent, _G.c_agent = _G.b.agent, _G.c.agent
_G.a:switch_provider("gemini-acp")
]])
        child.flush()

        assert.equal("gemini-acp", child.lua_get("_G.a.agent.provider_name"))
        assert.is_true(child.lua_get("_G.b.agent == _G.b_agent"))
        assert.is_true(child.lua_get("_G.c.agent == _G.c_agent"))
        assert.equal(
            "claude-agent-acp",
            child.lua_get([[require("agentic.config").provider]])
        )
        assert.equal(3, instance_count())
    end)

    it(
        "reads permission rules from the switched provider's config dir",
        function()
            child.lua([[
local providers = require("agentic.config").acp_providers
providers["gemini-acp"].env = { CLAUDE_CONFIG_DIR = "/tmp/gemini-claude" }
_G.a:switch_provider("gemini-acp")
]])
            child.flush()

            assert.equal(
                "/tmp/gemini-claude",
                child.lua_get("_G.a.permission_manager._get_config_dir()")
            )
            assert.are_not.equal(
                "/tmp/gemini-claude",
                child.lua_get("_G.b.permission_manager._get_config_dir()")
            )
        end
    )

    it("records each session's provider in its history", function()
        local providers = child.lua_get([[
vim.tbl_map(function(s)
    s:_sync_history_context(s.chat_history)
    return s.chat_history.provider
end, {
    _G.a,
    _G.b,
    require("agentic").new_session({ auto_add_to_context = false }),
})
]])

        assert.same(
            { "claude-agent-acp", "opencode-acp", "opencode-acp" },
            providers
        )
    end)
end)
