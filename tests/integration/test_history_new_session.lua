local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("a history carried into a new ACP session", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
require("agentic.config").sessions.storage_path = vim.fn.tempname()
vim.cmd("Agentic")
_G.s = require("agentic.session_registry").current()
_G.s.agent.agent_capabilities = { loadSession = true }
_G.s.agent.state = "ready"
_G.sent = {}
_G.s.agent._send_request = function(_, method, _, cb)
    table.insert(_G.sent, method)
    if method == "session/load" then _G.load_cb = cb end
    if method == "session/new" then _G.new_cb = cb end
end
_G.msg = function(type, text)
    return { type = type, text = text, timestamp = 0, provider_name = "p" }
end
_G.count_in_chat = function(needle)
    local text = table.concat(
        vim.api.nvim_buf_get_lines(_G.s.widget.buf_nrs.agent, 0, -1, false),
        "\n"
    )
    local n = 0
    for _ in text:gmatch(vim.pesc(needle)) do
        n = n + 1
    end
    return n
end
_G.chunk = function(session_id, text)
    _G.s.agent.subscribers[session_id].on_session_update({
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = text },
    })
end
]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    --- Assert the session runs as `sid-new` with the saved question and
    --- answer shown once and queued for the first prompt.
    local function assert_carried()
        assert.equal("sid-new", child.lua_get("_G.s.session_id"))
        assert.is_false(child.lua_get("_G.s._loading_saved"))
        assert.equal(1, child.lua_get([[_G.count_in_chat("saved question")]]))
        assert.equal(1, child.lua_get([[_G.count_in_chat("saved answer")]]))
        assert.equal(2, child.lua_get("#_G.s._history_to_send.messages"))
        assert.is_true(child.lua_get("_G.s._is_first_message"))
    end

    it("restart_session replays the history once and queues it", function()
        child.lua([[
_G.s.session_id = "sid-old"
_G.s.chat_history.session_id = "sid-old"
_G.s.chat_history:add_message(_G.msg("user", "saved question"))
_G.s.chat_history:add_message(_G.msg("agent", "saved answer"))
_G.s:restart_session()
_G.new_cb({ sessionId = "sid-new" }, nil)
]])
        child.flush()

        assert_carried()
    end)

    it("a failed load replaces its partial replay with the file", function()
        child.lua([[
local saved = require("agentic.ui.chat_history"):new()
saved.session_id = "sid-x"
saved:add_message(_G.msg("user", "saved question"))
saved:add_message(_G.msg("agent", "saved answer"))
assert(saved:save(vim.uv.fs_realpath("/tmp")) == nil)
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.chunk("sid-x", "saved answer")
_G.load_cb(nil, { code = -32603, message = "boom" })
_G.new_cb({ sessionId = "sid-new" }, nil)
]])
        child.flush()

        assert_carried()
        assert.is_true(
            child.lua_get([=[_G.s.agent.subscribers["sid-x"] == nil]=])
        )
    end)

    it("a failed load without a file starts an empty session", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-none", "/tmp")
_G.chunk("sid-none", "partial text")
-- A prompt submitted during the load, held for the loaded conversation.
vim.api.nvim_buf_set_lines(_G.s.widget.buf_nrs.input, 0, -1, false, { "follow up" })
_G.s.widget.input_dispatch:submit()
assert(_G.s.widget.input_dispatch:queued_block_count() == 1)
-- What a replayed plan and edit leave in the panels.
_G.s.todo_list:render({ { content = "step", status = "pending", priority = "medium" } })
local edited = vim.fn.tempname()
vim.fn.writefile({ "x" }, edited)
_G.s.file_activity:record({ tool_call_id = "t1", path = edited, op = "edit" })
assert(not _G.s.todo_list:is_empty() and _G.s.file_activity:count() == 1)
_G.load_cb(nil, { code = -32603, message = "boom" })
_G.new_cb({ sessionId = "sid-new" }, nil)
]])
        child.flush()

        assert.equal("sid-new", child.lua_get("_G.s.session_id"))
        assert.equal(0, child.lua_get([[_G.count_in_chat("partial text")]]))
        assert.equal(0, child.lua_get("#_G.s.chat_history.messages"))
        assert.is_true(child.lua_get("_G.s.todo_list:is_empty()"))
        assert.equal(0, child.lua_get("_G.s.file_activity:count()"))
        -- The held prompt stays as draft and reaches no agent.
        assert.equal(
            0,
            child.lua_get("_G.s.widget.input_dispatch:queued_block_count()")
        )
        assert.same(
            { "follow up" },
            child.lua_get(
                "vim.api.nvim_buf_get_lines(_G.s.widget.buf_nrs.input, 0, -1, false)"
            )
        )
        assert.is_false(
            child.lua_get([[vim.tbl_contains(_G.sent, "session/prompt")]])
        )
        assert.equal(
            child.lua_get(
                [[require("agentic.utils.file_system").canonical_path("/tmp")]]
            ),
            child.lua_get("_G.s._cwd")
        )
    end)

    it(
        "replace_with_history keeps the history when session/new fails",
        function()
            child.lua([[
_G.h = require("agentic.ui.chat_history"):new()
_G.h:add_message(_G.msg("user", "saved question"))
_G.s:replace_with_history(_G.h)
_G.new_cb(nil, { code = -32603, message = "nope" })
]])
            child.flush()

            assert.is_true(child.lua_get("_G.s.chat_history == _G.h"))
            assert.is_true(child.lua_get("_G.s.session_id == nil"))
        end
    )
end)
