local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("session/load history", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
require("agentic").toggle()
local tab = vim.api.nvim_get_current_tabpage()
_G.s = require("agentic.session_registry").bound_session(tab)
_G.persists = 0
_G.s._persist_history = function() _G.persists = _G.persists + 1 end
require("agentic.ui.chat_history").load = function(_, cb) cb(nil) end
_G.s.agent.agent_capabilities = { loadSession = true }
_G.s.agent._send_request = function(_, method, _, cb)
    if method == "session/load" then _G.load_cb = cb end
end
]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    it("records the replayed and the later tool calls", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.s.agent.subscribers["sid-x"].on_tool_call({
    tool_call_id = "replayed", kind = "read", status = "completed", argument = "a.txt",
})
_G.load_cb({}, nil)
]])
        child.flush()
        -- The replay mirrors the session file: nothing to write.
        assert.equal(0, child.lua_get("_G.persists"))
        assert.is_false(child.lua_get("_G.s.chat_history.dirty"))

        child.lua([[
_G.s.agent.subscribers["sid-x"].on_tool_call({
    tool_call_id = "live", kind = "read", status = "pending", argument = "b.txt",
})
]])

        local ids = child.lua_get([[
vim.tbl_map(function(m) return m.tool_call_id end, vim.tbl_filter(function(m)
    return m.type == "tool_call"
end, _G.s.chat_history.messages))
]])
        assert.same({ "replayed", "live" }, ids)
        assert.equal(1, child.lua_get("_G.persists"))
    end)
end)
