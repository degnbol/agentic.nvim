local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("session/load history", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
require("agentic.config").sessions.storage_path = vim.fn.tempname()
vim.cmd("Agentic")
_G.s = require("agentic.session_registry").current()
_G.persists = 0
_G.s._persist_history = function() _G.persists = _G.persists + 1 end
_G.s.agent.state = "ready"
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

    it(
        "load_acp_session shows an open session instead of loading it",
        function()
            child.lua([[_G.s.session_id = "sid-open"]])
            child.cmd("tabnew")

            child.lua([[require("agentic").load_acp_session("sid-open")]])
            child.flush()

            assert.equal(
                1,
                child.lua_get(
                    [[vim.tbl_count(require("agentic.session_registry").by_id)]]
                )
            )
            assert.equal(
                child.lua_get("_G.s.widget.buf_nrs.agent"),
                child.api.nvim_get_current_buf()
            )
            assert.is_true(child.lua_get("_G.load_cb == nil"))
        end
    )

    it("loads a file under its name and sends its ACP id", function()
        child.lua([[
_G.s.agent._send_request = function(_, method, params, cb)
    if method == "session/load" then
        _G.load_params, _G.load_cb = params, cb
    end
end
local saved = require("agentic.ui.chat_history"):new()
saved.chat_id = "chat-1"
saved.session_id = "acp-2"
saved.timestamp = 1000
saved:add_message({ type = "user", text = "q", timestamp = 0, provider_name = "p" })
assert(saved:save(vim.uv.fs_realpath("/tmp")) == nil)
_G.s:load_acp_session("chat-1")
_G.load_cb({}, nil)
]])
        child.flush()

        assert.equal("acp-2", child.lua_get("_G.load_params.sessionId"))
        assert.equal("acp-2", child.lua_get("_G.s.session_id"))
        assert.equal("chat-1", child.lua_get("_G.s:chat_id()"))
        assert.equal(1000, child.lua_get("_G.s.chat_history.timestamp"))
        assert.equal(
            "agentic://chat-1",
            child.lua_get(
                "vim.api.nvim_buf_get_name(_G.s.widget.buf_nrs.agent)"
            )
        )
    end)

    it("sends a load deferred until the agent is ready", function()
        child.lua([[
local agent = _G.s.agent
agent._send_request = function(_, method, params, cb)
    if method == "initialize" then
        cb({ protocolVersion = 1, agentCapabilities = { loadSession = true } }, nil)
    end
    if method == "session/load" then _G.load_params = params end
end
agent.transport = { start = function() agent.state = "connected" end }
local saved = require("agentic.ui.chat_history"):new()
saved.chat_id = "chat-1"
saved.session_id = "acp-2"
saved:add_message({ type = "user", text = "q", timestamp = 0, provider_name = "p" })
assert(saved:save(vim.uv.fs_realpath("/tmp")) == nil)
agent.state = "initializing"
vim.cmd("tabnew")
require("agentic").load_acp_session("chat-1")
_G.l = require("agentic.session_registry").session_for_key("chat-1")
_G.deferred = _G.l._pending_load ~= nil
_G.sent_early = _G.load_params ~= nil
agent.state = "disconnected"
agent:_connect()
]])
        child.flush()

        assert.is_true(child.lua_get("_G.deferred"))
        assert.is_false(child.lua_get("_G.sent_early"))
        assert.equal("acp-2", child.lua_get("_G.load_params.sessionId"))
        assert.is_true(child.lua_get("_G.l._pending_load == nil"))
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
        -- No session file: the replay is the only record, written at load end.
        assert.equal(1, child.lua_get("_G.persists"))

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
        assert.equal(2, child.lua_get("_G.persists"))
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

--- Occurrences of plain `needle` in `text`.
--- @param text string
--- @param needle string
--- @return integer
local function count(text, needle)
    local n, init = 0, 1
    while true do
        local i = text:find(needle, init, true)
        if not i then
            return n
        end
        n, init = n + 1, i + #needle
    end
end

describe("session/load from the session file", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
require("agentic.config").sessions.storage_path = vim.fn.tempname()
vim.cmd("Agentic")
_G.s = require("agentic.session_registry").current()
_G.s.agent.agent_capabilities = { loadSession = true }
_G.s.agent._send_request = function(_, method, _, cb)
    if method == "session/load" then _G.load_cb = cb end
    if method == "session/new" then _G.new_cb = cb end
end
local ChatHistory = require("agentic.ui.chat_history")
_G.saves = 0
local save = ChatHistory.save
ChatHistory.save = function(...)
    _G.saves = _G.saves + 1
    return save(...)
end
_G.p = function(text) return { type = "user", text = text, timestamp = 1, provider_name = "p" } end
_G.a = function(text) return { type = "agent", text = text, provider_name = "p" } end
local saved = ChatHistory:new()
saved.chat_id = "sid-x"
saved.session_id = "sid-x"
saved.timestamp = 1000
saved.messages = {
    _G.p("first prompt"),
    { type = "tool_call", tool_call_id = "t1", kind = "read", status = "completed",
      argument = "a.txt", causes = { { code = "grant" } } },
    _G.a("done text"),
    _G.p("/compact"),
    { type = "tool_call", tool_call_id = "t2", kind = "read", status = "cancelled",
      argument = "b.txt" },
    _G.a("after text"),
}
assert(saved:save(vim.uv.fs_realpath("/tmp")) == nil)
_G.saves = 0

_G.sub = function() return _G.s.agent.subscribers["sid-x"] end
_G.user = function(text)
    _G.sub().on_session_update({ sessionUpdate = "user_message_chunk",
        content = { type = "text", text = text } }, "sid-x")
end
_G.agent = function(text)
    _G.sub().on_session_update({ sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = text } }, "sid-x")
end
_G.tool = function(id, status, extra)
    _G.sub().on_tool_call(vim.tbl_extend("force", { tool_call_id = id,
        kind = "read", status = status, argument = id .. ".txt" }, extra or {}), "sid-x")
end
_G.tool_update = function(id, fields)
    _G.sub().on_tool_call_update(vim.tbl_extend("force", { tool_call_id = id }, fields), "sid-x")
end
-- The replay of the file's turns: the bridge drops `/compact` and `cancelled`.
_G.replay_file = function()
    _G.user("<environment_info>x</environment_info>")
    _G.user("first prompt")
    _G.tool("t1", "pending")
    _G.tool_update("t1", { status = "completed" })
    _G.agent("done text")
    _G.tool("t2", "in_progress")
    _G.tool_update("t2", { status = "completed", body = { "late" } })
    _G.agent("after text")
end
_G.replay_tail = function()
    _G.user("next prompt")
    _G.agent("tail reply")
end
_G.chat = function()
    return table.concat(vim.api.nvim_buf_get_lines(_G.s.widget.buf_nrs.agent, 0, -1, false), "\n")
end
_G.file = function()
    return require("agentic.utils.file_system").read_json(
        ChatHistory.get_file_path("sid-x", _G.s._cwd))
end
]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    it("renders the file before the replay arrives", function()
        child.lua([[_G.s:_do_load_acp_session("sid-x", "/tmp")]])

        local chat = child.lua_get("_G.chat()")
        assert.equal(1, count(chat, "first prompt"))
        assert.equal(1, count(chat, "after text"))
        assert.same(
            { { code = "grant" } },
            child.lua_get([[_G.s.message_writer.tool_call_blocks.t1.causes]])
        )
    end)

    it("holds a conversation update and applies provider state", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.user("next prompt")
_G.sub().on_session_update({ sessionUpdate = "available_commands_update",
    availableCommands = { { name = "cmd-x", description = "d" } } }, "sid-x")
]])
        child.flush()

        assert.equal(1, child.lua_get("#_G.s._replay_hold"))
        assert.equal(0, count(child.lua_get("_G.chat()"), "next prompt"))
        assert.equal("cmd-x", child.lua_get("_G.s._available_commands[1].name"))
    end)

    it("shows the file's rows once, then the new turn", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.replay_file()
_G.replay_tail()
]])
        child.flush()
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()

        local chat = child.lua_get("_G.chat()")
        for _, text in ipairs({
            "first prompt",
            "done text",
            "/compact",
            "after text",
            "next prompt",
            "tail reply",
        }) do
            assert.equal(1, count(chat, text))
        end
        assert.is_true(chat:find("after text") < chat:find("next prompt"))
        assert.equal(1000, child.lua_get("_G.s.chat_history.timestamp"))
    end)

    it("keeps a block the file rendered as the file has it", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.replay_file()
_G.replay_tail()
]])
        child.flush()
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()

        assert.equal(
            "cancelled",
            child.lua_get([[_G.s.message_writer.tool_call_blocks.t2.status]])
        )
        assert.equal(0, count(child.lua_get("_G.chat()"), "late"))
        local file = child.lua_get("_G.file()")
        assert.equal("cancelled", file.messages[5].status)
        assert.equal("/compact", file.messages[4].text)
        assert.equal(1000, file.timestamp)
    end)

    it("saves the tail and records no edit range for it", function()
        child.lua([[
_G.path = vim.fn.tempname()
vim.fn.writefile({ "a", "foo", "bar" }, _G.path)
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.replay_file()
_G.replay_tail()
_G.tool("t3", "pending", { kind = "edit", argument = _G.path,
    diff = { old = { "foo" }, new = { "foo", "bar" } } })
]])
        child.flush()
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()

        assert.is_false(child.lua_get([[_G.s.status_indicator:is_active()]]))
        assert.is_false(
            child.lua_get([[_G.s.permission_manager:has_edit_range("t3")]])
        )
        local file = child.lua_get("_G.file()")
        assert.equal("next prompt", file.messages[7].text)
        assert.equal("t3", file.messages[9].tool_call_id)
        child.lua([[vim.fs.rm(_G.path)]])
    end)

    it("adds nothing on a second load of the saved file", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.replay_file()
_G.replay_tail()
]])
        child.flush()
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()
        child.lua([[
_G.saves = 0
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.replay_file()
_G.replay_tail()
]])
        child.flush()
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()

        assert.equal(1, count(child.lua_get("_G.chat()"), "next prompt"))
        assert.equal(0, child.lua_get("_G.saves"))
    end)

    it("writes nothing when the replay has no tail", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.replay_file()
]])
        child.flush()
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()

        assert.equal(0, child.lua_get("_G.saves"))
        assert.is_false(child.lua_get("_G.s.chat_history.dirty"))
    end)

    it("warns and shows the file when the replay does not match", function()
        child.lua([[
_G.notices = {}
require("agentic.utils.logger").notify = function(msg) table.insert(_G.notices, msg) end
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.user("other prompt")
_G.agent("other reply")
]])
        child.flush()
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()

        assert.equal(1, child.lua_get("#_G.notices"))
        assert.equal(0, count(child.lua_get("_G.chat()"), "other"))
    end)

    it("shows the chat once after an error", function()
        child.lua([[
require("agentic.utils.logger").notify = function() end
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.replay_file()
]])
        child.flush()
        child.lua([[_G.load_cb(nil, { message = "gone" })]])
        child.flush()
        child.lua([[_G.new_cb({ sessionId = "sid-new" }, nil)]])
        child.flush()

        assert.equal(1, count(child.lua_get("_G.chat()"), "first prompt"))
    end)

    it("ignores the load callback after /new", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.replay_file()
_G.replay_tail()
_G.s:new_session({ quiet_welcome = true })
_G.new_cb({ sessionId = "sid-new" }, nil)
]])
        child.flush()
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()

        assert.equal("sid-new", child.lua_get("_G.s.session_id"))
        assert.equal(0, count(child.lua_get("_G.chat()"), "next prompt"))
        assert.equal(0, child.lua_get("#_G.s.chat_history.messages"))
    end)

    it("drops the rest of the replay after a refresh", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.replay_file()
_G.s:_refresh()
_G.replay_tail()
]])
        child.flush()
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()

        assert.equal(0, count(child.lua_get("_G.chat()"), "next prompt"))
        assert.equal(0, child.lua_get("_G.saves"))
        assert.is_true(child.lua_get([[_G.s._load_state ~= "dropping"]]))
    end)

    it("shows a turn sent after a refresh during the hold", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.s:_refresh()
_G.s:_send_synthetic_prompt("go on")
_G.agent("live reply")
]])
        child.flush()

        assert.equal(1, count(child.lua_get("_G.chat()"), "live reply"))
        assert.is_true(child.lua_get("_G.s._load_state == nil"))
    end)

    it("ends a load that a turn after a refresh outlived", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.s:_refresh()
_G.s:_send_synthetic_prompt("go on")
_G.replay_tail()
]])
        child.flush()
        child.lua([[
local write_notice = _G.s.message_writer.write_notice
_G.s.message_writer.write_notice = function(writer, notice)
    _G.resume_mid_turn = notice.mid_turn
    return write_notice(writer, notice)
end
_G.load_cb({}, nil)
]])
        child.flush()

        assert.equal(1, count(child.lua_get("_G.chat()"), "next prompt"))
        -- The turn is still running and finalizes the writer itself.
        assert.is_true(child.lua_get("_G.resume_mid_turn"))
    end)

    it("ends the hold when a new session supersedes the load", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.s:new_session({ history = require("agentic.ui.chat_history"):new() })
]])

        assert.is_true(child.lua_get("_G.s._replay_hold == nil"))
        assert.is_true(child.lua_get("_G.s._load_state == nil"))
    end)

    it(
        "puts a tail subagent's output, rows and end in its transcript",
        function()
            child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.replay_file()
_G.replay_tail()
local upd = function(source, update) _G.sub().on_session_update(update, source) end
upd("sid-x", { sessionUpdate = "subagent_update", sessionId = "c9",
    description = "finder", state = { state = "running" } })
for _, view in ipairs({ "sid-x", "c9" }) do
    upd(view, { sessionUpdate = "session_message", messageId = "toolu_9",
        senderSessionId = "sid-x", recipientSessionId = "c9",
        content = { { type = "text", text = "Find it." } } })
end
upd("c9", { sessionUpdate = "agent_message_chunk",
    content = { type = "text", text = "child found" } })
upd("sid-x", { sessionUpdate = "subagent_update", sessionId = "c9",
    state = { state = "idle", stopReason = "end_turn" } })
]])
            child.flush()
            child.lua([[_G.load_cb({}, nil)]])
            child.flush()
            child.lua(
                [[vim.fn.bufload(_G.s._subagents._agents.c9.transcript.bufnr)]]
            )

            local transcript = child.lua_get(
                [[table.concat(vim.api.nvim_buf_get_lines(
    _G.s._subagents._agents.c9.transcript.bufnr, 0, -1, false), "\n")]]
            )
            assert.equal(1, count(transcript, "child found"))
            assert.equal(1, count(transcript, "Find it."))
            assert.same(
                { "session_message", "agent", "subagent_end" },
                child.lua_get([[vim.tbl_map(function(m)
    return m.type
end, _G.file().subagent_messages)]])
            )
        end
    )
end)
