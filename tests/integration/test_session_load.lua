local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("session/load history", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
vim.cmd("Agentic")
local tab = vim.api.nvim_get_current_tabpage()
_G.s = require("agentic.session_registry").bound_session(tab)
_G.persists = 0
_G.s._persist_history = function() _G.persists = _G.persists + 1 end
require("agentic.ui.chat_history").read = function() return nil end
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

    it("records an edit range for live edits only", function()
        -- The file already holds the replayed edit, a pure addition whose
        -- `diff.old` would still match uniquely.
        child.lua([[
_G.path = vim.fn.tempname()
vim.fn.writefile({ "a", "foo", "bar", "z" }, _G.path)
_G.s:_do_load_acp_session("sid-x", "/tmp")
local sub = _G.s.agent.subscribers["sid-x"]
sub.on_tool_call({
    tool_call_id = "replayed", kind = "edit", status = "pending", argument = _G.path,
    diff = { old = { "foo" }, new = { "foo", "bar" } },
})
sub.on_tool_call_update({ tool_call_id = "replayed", status = "completed" })
_G.load_cb({}, nil)
]])
        child.flush()

        child.lua([[
_G.s.agent.subscribers["sid-x"].on_tool_call({
    tool_call_id = "live", kind = "edit", status = "pending", argument = _G.path,
    diff = { old = { "z" }, new = { "z", "w" } },
})
]])

        assert.is_false(
            child.lua_get(
                [[_G.s.permission_manager:has_edit_range("replayed")]]
            )
        )
        assert.is_true(
            child.lua_get([[_G.s.permission_manager:has_edit_range("live")]])
        )
        child.lua([[vim.fs.rm(_G.path)]])
    end)
end)
