local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("a chat moved to a new ACP session", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
require("agentic.config").sessions.storage_path = vim.fn.tempname()
vim.cmd("Agentic")
_G.Registry = require("agentic.session_registry")
_G.ChatHistory = require("agentic.ui.chat_history")
_G.s = _G.Registry.current()
_G.first_cid = _G.s.chat_history.chat_id
_G.agent = _G.s.agent
_G.agent.state = "ready"
_G.cbs = {}
_G.agent._send_request = function(_, method, _, cb)
    _G.cbs[method] = cb
end
_G.agent.close_session = function(_, _, on_closed) on_closed() end
_G.name = function(bufnr)
    return vim.api.nvim_buf_get_name(bufnr)
end
]])
        child.flush()
        child.lua([[
_G.s:new_session()
_G.cid = _G.s.chat_history.chat_id
_G.name_before_new = _G.name(_G.s.widget.buf_nrs.agent)
_G.cbs["session/new"]({ sessionId = "sid-first" }, nil)
]])
        child.flush()
        child.lua([[
_G.s.chat_history.timestamp = 1000
_G.s.chat_history:add_message({
    type = "user", text = "go", timestamp = 0, provider_name = "p",
})
_G.s:_on_session_update({
    sessionUpdate = "subagent_update",
    sessionId = "c1",
    description = "finder",
    state = { state = "running" },
}, "sid-first")
_G.transcript = _G.s._subagents:buf_of("c1")
_G.c1 = "agentic://" .. _G.cid .. "/"
    .. require("agentic.utils.buffer_names").short_key("c1")
vim.cmd("tabnew")
]])
    end)

    after_each(function()
        child.stop()
    end)

    --- Assert the chat runs as `sid-next` under its chat id: same chat id,
    --- creation time, buffer names and one session file holding `sid-next`.
    local function assert_same_chat()
        assert.equal("sid-next", child.lua_get("_G.s.session_id"))
        assert.is_true(child.lua_get("_G.s:chat_id() == _G.cid"))
        assert.equal(1000, child.lua_get("_G.s.chat_history.timestamp"))
        assert.is_true(
            child.lua_get(
                [[_G.name(_G.s.widget.buf_nrs.agent) == "agentic://" .. _G.cid]]
            )
        )
        assert.is_true(child.lua_get("_G.name(_G.transcript) == _G.c1"))
        child.lua("_G.s:_write_session()")
        assert.equal(
            "sid-next",
            child.lua_get([[_G.ChatHistory.read_saved(_G.cid).session_id]])
        )
        assert.same(
            {},
            child.lua_get([[_G.ChatHistory.find_files("sid-next")]])
        )
    end

    it(
        "names the buffers after the chat id before session/new returns",
        function()
            assert.truthy(child.lua_get("_G.cid"):match("^%x+$"))
            assert.is_true(
                child.lua_get([[_G.name_before_new == "agentic://" .. _G.cid]])
            )
            assert.is_true(
                child.lua_get(
                    [[_G.name(_G.s.widget.buf_nrs.agent) == "agentic://" .. _G.cid]]
                )
            )
        end
    )

    it("keeps the chat across a provider switch", function()
        child.lua([[
local AgentInstance = require("agentic.acp.agent_instance")
_G.other = AgentInstance.get_instance("codex-acp")
_G.other.state = "ready"
_G.other.create_session = function(_, _, _, cb)
    cb({ sessionId = "sid-next" })
end
AgentInstance.get_instance = function(_, on_ready)
    on_ready(_G.other)
    return _G.other
end
_G.s:switch_provider("codex-acp")
]])
        child.flush()

        assert_same_chat()
    end)

    it("keeps the chat across a renewal", function()
        child.lua([[
require("agentic.session_recovery").renew_session(_G.s)
_G.cbs["session/new"]({ sessionId = "sid-next" }, nil)
]])
        child.flush()

        assert_same_chat()
    end)

    it("is found by its chat id", function()
        child.lua([[
require("agentic.session_recovery").renew_session(_G.s)
_G.cbs["session/new"]({ sessionId = "sid-next" }, nil)
]])
        child.flush()

        assert.is_true(
            child.lua_get([[_G.Registry.session_for_key(_G.cid) == _G.s]])
        )
    end)

    it("keeps the id it got at creation once the agent is ready", function()
        assert.is_true(child.lua_get("_G.first_cid == _G.cid"))
    end)

    it("gf on a name written before the move opens the live buffer", function()
        child.lua([[
require("agentic.session_recovery").renew_session(_G.s)
_G.cbs["session/new"]({ sessionId = "sid-next" }, nil)
]])
        child.flush()
        child.lua([[
vim.api.nvim_set_current_win(_G.s.widget:home_win())
local row = vim.fn.index(vim.api.nvim_buf_get_lines(0, 0, -1, false), _G.c1)
vim.api.nvim_win_set_cursor(0, { row + 1, 3 })
vim.api.nvim_feedkeys("gf", "mx", false)
]])
        child.flush()

        assert.is_true(
            child.lua_get("vim.api.nvim_get_current_buf() == _G.transcript")
        )
        assert.equal(1, child.lua_get("vim.tbl_count(_G.Registry.by_id)"))
    end)

    it("/delete while the new session is created removes the file", function()
        child.lua([[
require("agentic.config").sessions.confirm_delete = false
_G.s:_write_session()
require("agentic.session_recovery").renew_session(_G.s)
_G.s:_delete_session()
]])

        assert.same({}, child.lua_get([[_G.ChatHistory.find_files(_G.cid)]]))
    end)
end)
