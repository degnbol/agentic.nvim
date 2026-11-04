local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- Lua run in each child: two sessions `_G.s1` and `_G.s2` on one provider.
--- A session with no prompt is replaced by the next one shown in its place,
--- so `_G.s1` gets one.
local SESSIONS = [[
local Config = require("agentic.config")
Config.sessions.storage_path = vim.fn.tempname()
vim.cmd("Agentic")
_G.s1 = require("agentic.session_registry").current()
_G.s1.chat_history:add_message({
    type = "user",
    text = "earlier",
    timestamp = 0,
    provider_name = "p",
})
require("agentic").new_session({ auto_add_to_context = false })
_G.s2 = require("agentic.session_registry").current()
]]

--- Lua run in each child once the sessions' deferred startup has run: both
--- are bound, ready and subscribed to their client. Turns are recorded in
--- `_G.sent` as `{ session = <session id>, provider = <provider>, text = … }`
--- instead of going to the provider.
local READY = [[
_G.sent = {}
_G.ready = function(s, session_id)
    s.session_id = session_id
    s.agent.state = "ready"
    s.agent:_subscribe(session_id, s:_build_handlers())
    s._dispatch_turn = function(this, prompt)
        table.insert(_G.sent, {
            session = this.session_id,
            provider = this.agent.provider_name,
            text = prompt[#prompt].text,
        })
    end
end
_G.ready(_G.s1, "one")
_G.ready(_G.s2, "two")
_G.limit = _G.s1.agent.usage_limit
]]

describe("usage limit", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SESSIONS)
        child.flush()
        child.lua(READY)
    end)

    after_each(function()
        child.stop()
    end)

    it(
        "holds every session on the provider, and its lift drains each",
        function()
            child.lua([[
_G.s1:_queue_input("first queued")
_G.s2:_queue_input("second queued")
_G.limit:hold(os.time() + 3600)
_G.drained = { _G.s1:_drain_queue(), _G.s2:_drain_queue() }
_G.reasons = {
    _G.s1:_submit_defer_reason("x"),
    _G.s2:_submit_defer_reason("x"),
}
_G.limit:_lift()
]])
            child.flush()

            assert.same({ false, false }, child.lua_get("_G.drained"))
            assert.same(
                { "usage_limited", "usage_limited" },
                child.lua_get("_G.reasons")
            )
            local sent = child.lua_get("_G.sent")
            table.sort(sent, function(a, b)
                return a.session < b.session
            end)
            local PROVIDER = "claude-agent-acp"
            assert.same({
                { session = "one", provider = PROVIDER, text = "first queued" },
                {
                    session = "two",
                    provider = PROVIDER,
                    text = "second queued",
                },
            }, sent)
        end
    )

    it("sends a queued continue to the provider switched to", function()
        child.lua([[
local AgentInstance = require("agentic.acp.agent_instance")
_G.other = AgentInstance.get_instance("codex-acp")
_G.other.state = "ready"
_G.other.create_session = function(_, _, _, cb)
    cb({ sessionId = "three" })
end
AgentInstance.get_instance = function(_, on_ready)
    on_ready(_G.other)
    return _G.other
end

_G.limit:hold(os.time() + 3600)
_G.s1:_queue_input("held on claude")
_G.s2:_queue_input("continue")
_G.s2:switch_provider("codex-acp")
]])
        child.flush()

        assert.same({
            { session = "three", provider = "codex-acp", text = "continue" },
        }, child.lua_get("_G.sent"))
        assert.is_true(child.lua_get("_G.limit:is_held()"))
        assert.is_false(child.lua_get("_G.other.usage_limit:holds_drain()"))
        child.lua("_G.limit:stop()")
    end)
end)
