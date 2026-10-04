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

describe("subagent output on load and restore", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
require("agentic").toggle()
local tab = vim.api.nvim_get_current_tabpage()
_G.s = require("agentic.session_registry").bound_session(tab)
_G.sub = _G.s.widget.buf_nrs.subagent
_G.s.agent.agent_capabilities = { loadSession = true }
_G.s.agent._send_request = function(_, method, _, cb)
    if method == "session/load" then _G.load_cb = cb end
end

require("agentic.config").session_restore.storage_path = vim.fn.tempname()
local ChatHistory = require("agentic.ui.chat_history")
_G.task_call = {
    type = "tool_call", tool_call_id = "task-1", kind = "SubAgent",
    status = "completed", argument = "Explore: find",
    subagent = { label = "finder", mode = "blocking", confirmed = true },
}
_G.saved = ChatHistory:new()
_G.saved.session_id = "sid-x"
_G.saved.messages = { vim.deepcopy(_G.task_call) }
_G.saved.subagent_messages = {
    { type = "agent", text = "saved finding", provider_name = "p",
      parent_tool_use_id = "task-1" },
    { type = "agent", text = "other finding", provider_name = "p",
      parent_tool_use_id = "task-2" },
}
assert(_G.saved:save() == nil)

_G.sub_text = function()
    return table.concat(vim.api.nvim_buf_get_lines(_G.sub, 0, -1, false), "\n")
end
_G.count = function(text, needle)
    return select(2, text:gsub(vim.pesc(needle), ""))
end
]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    --- Run a session/load of `sid-x` whose replay holds the Task and a
    --- subagent's prompt, chunk and tool call, then complete it.
    --- @param before_complete string|nil Lua run before the load completes
    local function load(before_complete)
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
local sub = _G.s.agent.subscribers["sid-x"]
sub.on_tool_call(vim.deepcopy(_G.task_call))
local meta = { claudeCode = { parentToolUseId = "task-1" } }
sub.on_session_update({
    sessionUpdate = "user_message_chunk",
    content = { type = "text", text = "replayed subagent prompt" },
    _meta = meta,
})
sub.on_session_update({
    sessionUpdate = "agent_message_chunk",
    content = { type = "text", text = "replayed chunk" },
    _meta = meta,
})
sub.on_tool_call({
    tool_call_id = "replayed-sub", parent_tool_use_id = "task-1",
    kind = "read", status = "pending", argument = "a.txt",
})
sub.on_tool_call_update({ tool_call_id = "replayed-sub", status = "completed" })
]])
        if before_complete then
            child.lua(before_complete)
        end
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()
    end

    it("a load shows the file's subagent output once", function()
        load()

        local text = child.lua_get("_G.sub_text()")
        assert.equal(
            1,
            child.lua_get([[_G.count(_G.sub_text(), "saved finding")]])
        )
        assert.equal(
            1,
            child.lua_get([[_G.count(_G.sub_text(), "other finding")]])
        )
        assert.is_nil(text:find("replayed", 1, true))
        assert.truthy(text:find("finder (Blocking)", 1, true))
        local chat = table.concat(
            child.lua_get(
                "vim.api.nvim_buf_get_lines(_G.s.widget.buf_nrs.chat, 0, -1, false)"
            ),
            "\n"
        )
        assert.is_nil(chat:find("replayed subagent prompt", 1, true))
        assert.equal(1, child.lua_get("#_G.s.chat_history.messages"))
        assert.is_false(child.lua_get("_G.s.chat_history.dirty"))
    end)

    it("nothing is modified or written while the load runs", function()
        load([[
_G.mid_modified = vim.bo[_G.s.widget.buf_nrs.chat].modified
    or vim.bo[_G.sub].modified
vim.cmd("silent! wall")
_G.s:_persist_history(_G.s.chat_history)
_G.mid_file = table.concat(vim.fn.readfile(
    require("agentic.ui.chat_history").get_file_path("sid-x")
), "\n")
]])

        assert.is_false(child.lua_get("_G.mid_modified"))
        assert.truthy(
            child.lua_get("_G.mid_file"):find("saved finding", 1, true)
        )
    end)

    for _, reuse in ipairs({ true, false }) do
        it(
            "a restore from history shows it, reuse_session " .. tostring(reuse),
            function()
                child.lua(
                    [[
_G.s.session_id = "sid-live"
_G.s.new_session = function(_, opts) opts.on_created() end
_G.s:restore_from_history(vim.deepcopy(_G.saved), { reuse_session = ... })
]],
                    { reuse }
                )

                assert.equal(
                    1,
                    child.lua_get([[_G.count(_G.sub_text(), "saved finding")]])
                )
                assert.truthy(
                    child
                        .lua_get("_G.sub_text()")
                        :find("finder (Blocking)", 1, true)
                )
            end
        )
    end

    it("a restore into an unloaded subagent buffer shows it on load", function()
        child.lua([[
vim.cmd("bdelete! " .. _G.sub)
_G.s.session_id = "sid-live"
_G.s:restore_from_history(vim.deepcopy(_G.saved), { reuse_session = true })
]])
        assert.is_false(child.lua_get("vim.api.nvim_buf_is_loaded(_G.sub)"))

        -- What every ACP handler does before it writes.
        child.lua([[_G.s:_load_subagent_buffer()]])

        assert.equal(
            1,
            child.lua_get([[_G.count(_G.sub_text(), "saved finding")]])
        )
    end)
end)
