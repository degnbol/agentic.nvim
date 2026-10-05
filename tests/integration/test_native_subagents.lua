local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- Lua run in each child: a bound session `_G.s` with a session id, a
--- throwaway session store and Claude config dir, and helpers that feed it
--- what the bridge sends.
local SETUP = [[
require("agentic.config").session_restore.storage_path = vim.fn.tempname()
require("agentic").toggle()
_G.s = require("agentic.session_registry").bound_session(
    vim.api.nvim_get_current_tabpage()
)
_G.s.session_id = "root"
_G.s.chat_history.session_id = "root"
_G.config_dir = vim.fn.tempname()
_G.s.agent.provider_config.env = { CLAUDE_CONFIG_DIR = _G.config_dir }

_G.update = function(source, update)
    _G.s:_on_session_update(update, source)
end
_G.spawn = function(child_id, name)
    _G.update("root", {
        sessionUpdate = "subagent_spawned",
        subagentSessionId = child_id,
        name = name or "find it",
        task = "Find the files.",
    })
end
_G.state = function(child_id, state)
    _G.update("root", {
        sessionUpdate = "subagent_state_update",
        subagentSessionId = child_id,
        state = state,
    })
end
_G.chunk = function(source, text, task_id)
    _G.update(source, {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = text },
        _meta = task_id and { claudeCode = { parentToolUseId = task_id } }
            or nil,
    })
end
_G.write_meta = function(agent_id, shape, tool_use_id)
    local dir = vim.fs.joinpath(
        _G.config_dir, "projects", "-tmp", "root", "subagents"
    )
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ vim.json.encode({
        agentType = "Explore",
        description = "d",
        toolUseId = tool_use_id,
        spawnDepth = 1,
        requestShape = shape,
    }) }, vim.fs.joinpath(dir, "agent-" .. agent_id .. ".meta.json"))
end
_G.transcript = function(child_id)
    return _G.s._agents[child_id].transcript
end
_G.text = function(bufnr)
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end
_G.block = function(child_id)
    return _G.s:_agent_block(child_id)
end
]]

describe("native subagent sessions", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SETUP)
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    it("spawn creates a named transcript and a block", function()
        child.lua([[_G.spawn("aa11bb22cc33dd44", "find it")]])

        local name =
            child.lua_get([[vim.api.nvim_buf_get_name(_G.transcript("aa11bb22cc33dd44").bufnr)]])
        assert.is_true(vim.endswith(name, "/subagent/find-it-cc33dd44"))
        assert.equal(name, child.lua_get([[_G.block("aa11bb22cc33dd44").argument]]))
        assert.equal("SubAgent", child.lua_get([[_G.block("aa11bb22cc33dd44").kind]]))
        assert.truthy(
            child
                .lua_get([[_G.text(_G.s.widget.buf_nrs.chat)]])
                :find(name, 1, true)
        )
        assert.truthy(
            child
                .lua_get([[_G.text(_G.transcript("aa11bb22cc33dd44").bufnr)]])
                :find("## find it (Blocking?)", 1, true)
        )
        assert.equal(
            child.lua_get([[_G.transcript("aa11bb22cc33dd44").bufnr]]),
            child.lua_get(
                [[vim.api.nvim_win_get_buf(_G.s.widget:panel_win("subagent"))]]
            )
        )
    end)

    it("a child's chunks and tool calls land in its transcript", function()
        child.lua([[
_G.spawn("c1")
_G.chunk("c1", "child finding", "toolu_1")
_G.s:_on_tool_call({
    tool_call_id = "t1", kind = "read", status = "pending", argument = "a.txt",
    parent_tool_use_id = "toolu_1",
}, "c1")
]])

        assert.truthy(
            child
                .lua_get([[_G.text(_G.transcript("c1").bufnr)]])
                :find("child finding", 1, true)
        )
        assert.is_nil(
            child
                .lua_get([[_G.text(_G.s.widget.buf_nrs.chat)]])
                :find("child finding", 1, true)
        )
        assert.is_true(
            child.lua_get(
                [[_G.transcript("c1").writer.tool_call_blocks.t1 ~= nil]]
            )
        )
        assert.same(
            { "toolu_1", "toolu_1" },
            child.lua_get([[vim.tbl_map(function(m)
    return m.parent_tool_use_id
end, _G.s.chat_history.subagent_messages)]])
        )
        assert.equal(
            "toolu_1",
            child.lua_get([[_G.s.chat_history.subagents.c1.task_id]])
        )
    end)

    it("a root-session update tagged with a known Task id lands in its agent", function()
        child.lua([[
_G.write_meta("c1", "background", "toolu_1")
_G.spawn("c1")
_G.chunk("root", "tagged finding", "toolu_1")
]])

        assert.truthy(
            child
                .lua_get([[_G.text(_G.transcript("c1").bufnr)]])
                :find("tagged finding", 1, true)
        )
    end)

    it("a meta file found late updates the block", function()
        child.lua([[_G.spawn("c1")]])
        assert.is_true(
            child.lua_get([[_G.block("c1").subagent.agent_type == nil]])
        )

        child.lua([[
_G.write_meta("c1", "background", "toolu_1")
_G.s:_on_tool_call({
    tool_call_id = "t1", kind = "read", status = "pending", argument = "a.txt",
}, "c1")
]])

        assert.same(
            {
                label = "find it",
                agent_id = "c1",
                agent_type = "Explore",
                mode = "background",
                confirmed = true,
            },
            child.lua_get([[_G.block("c1").subagent]])
        )
        assert.truthy(
            child
                .lua_get([[_G.text(_G.s.widget.buf_nrs.chat)]])
                :find("Explore · find it (Background)", 1, true)
        )
    end)

    it("state closes one agent; an unknown or repeat one does nothing", function()
        child.lua([[
_G.spawn("c1")
_G.spawn("c2")
_G.state("c1", "completed")
_G.state("c1", "failed")
_G.state("nobody", "completed")
]])

        assert.is_false(child.lua_get([[_G.s._agents.c1.open]]))
        assert.is_true(child.lua_get([[_G.s._agents.c2.open]]))
        assert.equal("completed", child.lua_get([[_G.block("c1").status]]))
        assert.equal("in_progress", child.lua_get([[_G.block("c2").status]]))
    end)

    it("a turn's end closes nothing", function()
        child.lua([[
_G.s.agent.send_prompt = function(_, _, _, cb) _G.prompt_cb = cb end
_G.spawn("c1")
_G.s:_dispatch_turn({})
_G.prompt_cb({ stopReason = "end_turn" }, nil)
]])

        assert.is_true(child.lua_get([[_G.s._agents.c1.open]]))
        assert.equal("in_progress", child.lua_get([[_G.block("c1").status]]))
    end)

    it("disconnect closes all", function()
        child.lua([[
_G.spawn("c1")
_G.spawn("c2")
_G.s:_build_handlers().on_disconnect()
]])

        for _, id in ipairs({ "c1", "c2" }) do
            assert.is_false(child.lua_get(("_G.s._agents.%s.open"):format(id)))
            assert.equal(
                "failed",
                child.lua_get(([[_G.block(%q).status]]):format(id))
            )
        end
    end)

    it("an epoch advance closes quietly", function()
        child.lua([[
_G.spawn("c1")
_G.s:_advance_session_epoch()
]])

        assert.is_false(child.lua_get([[_G.s._agents.c1.open]]))
        assert.equal("in_progress", child.lua_get([[_G.block("c1").status]]))
        assert.is_false(
            child.lua_get([[_G.transcript("c1").status_indicator:is_active()]])
        )
    end)

    it(
        "spawn and state only touch the block while loading, with the meta file's type and mode",
        function()
            child.lua([[
_G.s.widget:close_subagent_window()
_G.s._loading = true
_G.write_meta("c1", "foreground", "toolu_1")
_G.spawn("c1")
_G.state("c1", "completed")
]])

            assert.equal("completed", child.lua_get([[_G.block("c1").status]]))
            assert.equal(
                "Explore",
                child.lua_get([[_G.block("c1").subagent.agent_type]])
            )
            assert.equal(
                "blocking",
                child.lua_get([[_G.block("c1").subagent.mode]])
            )
            assert.is_false(child.lua_get([[_G.s._agents.c1.open]]))
            assert.is_false(
                child.lua_get(
                    [[vim.api.nvim_buf_is_loaded(_G.transcript("c1").bufnr)]]
                )
            )
            assert.is_true(
                child.lua_get([[_G.s.widget:panel_win("subagent") == nil]])
            )
        end
    )

    it("closing an agent stamps its unresolved calls cancelled", function()
        child.lua([[
_G.spawn("c1")
_G.s:_on_tool_call({
    tool_call_id = "t1", kind = "read", status = "pending", argument = "a.txt",
}, "c1")
_G.state("c1", "cancelled")
]])

        assert.equal(
            "cancelled",
            child.lua_get([[_G.transcript("c1").writer.tool_call_blocks.t1.status]])
        )
        assert.equal(
            "cancelled",
            child.lua_get([[_G.s.chat_history.subagent_messages[1].status]])
        )
        assert.equal("cancelled", child.lua_get([[_G.block("c1").status]]))
    end)

    it(
        "a permission request from an agent whose transcript is hidden shows it",
        function()
            child.lua([[
_G.spawn("c1")
_G.spawn("c2")
_G.s:_on_request_permission({
    sessionId = "c1",
    toolCall = { toolCallId = "t9" },
    options = {
        { optionId = "allow", name = "Allow", kind = "allow_once" },
    },
}, function() end)
]])

            assert.equal(
                child.lua_get([[_G.transcript("c1").bufnr]]),
                child.lua_get(
                    [[vim.api.nvim_win_get_buf(_G.s.widget:panel_win("subagent"))]]
                )
            )
        end
    )

    it("a wiped transcript comes back with the agent's next output", function()
        child.lua([[
_G.spawn("c1")
_G.chunk("c1", "first", "toolu_1")
_G.old = _G.transcript("c1").bufnr
vim.cmd.bwipeout({ args = { tostring(_G.old) }, bang = true })
_G.chunk("c1", " second", "toolu_1")
]])

        local text = child.lua_get([[_G.text(_G.transcript("c1").bufnr)]])
        assert.truthy(text:find("first", 1, true))
        assert.truthy(text:find("second", 1, true))
        assert.is_false(
            child.lua_get([[_G.transcript("c1").bufnr == _G.old]])
        )
    end)
end)

describe("subagents on load and restore", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SETUP)
        child.lua([[
_G.s.agent.agent_capabilities = { loadSession = true }
_G.s.agent._send_request = function(_, method, _, cb)
    if method == "session/load" then _G.load_cb = cb end
end
local ChatHistory = require("agentic.ui.chat_history")
_G.saved = ChatHistory:new()
_G.saved.session_id = "sid-x"
_G.saved.messages = { {
    type = "tool_call", tool_call_id = "c1", kind = "SubAgent",
    status = "completed", argument = "agentic://999/subagent/finder-c1",
    body = { "Find it." },
    subagent = { label = "finder", agent_id = "c1", mode = "blocking", confirmed = true },
} }
_G.saved.subagents = { c1 = { task_id = "toolu_1" } }
_G.saved.subagent_messages = {
    { type = "agent", text = "saved finding", provider_name = "p",
      parent_tool_use_id = "toolu_1" },
    { type = "agent", text = "legacy finding", provider_name = "p",
      parent_tool_use_id = "toolu_old" },
}
assert(_G.saved:save() == nil)
]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    --- Run a session/load of `sid-x` whose replay spawns and ends `c1` and
    --- replays its output, then complete it.
    --- @param before_complete string|nil Lua run before the load completes
    local function load(before_complete)
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
local sub = _G.s.agent.subscribers["sid-x"]
sub.on_session_update({
    sessionUpdate = "subagent_spawned", subagentSessionId = "c1",
    name = "finder", task = "Find it.",
}, "sid-x")
sub.on_session_update({
    sessionUpdate = "agent_message_chunk",
    content = { type = "text", text = "replayed chunk" },
    _meta = { claudeCode = { parentToolUseId = "toolu_1" } },
}, "c1")
sub.on_session_update({
    sessionUpdate = "subagent_state_update", subagentSessionId = "c1",
    state = "completed",
}, "sid-x")
]])
        if before_complete then
            child.lua(before_complete)
        end
        child.lua([[_G.load_cb({}, nil)]])
        child.flush()
    end

    it("nothing is modified or written while the load runs", function()
        load([[
_G.mid_modified = vim.bo[_G.s.widget.buf_nrs.chat].modified
    or vim.bo[_G.transcript("c1").bufnr].modified
_G.s:_persist_history(_G.s.chat_history)
_G.mid_file = table.concat(vim.fn.readfile(
    require("agentic.ui.chat_history").get_file_path("sid-x")
), "\n")
]])

        assert.is_false(child.lua_get("_G.mid_modified"))
        assert.truthy(
            child.lua_get("_G.mid_file"):find("saved finding", 1, true)
        )
        assert.is_false(child.lua_get("_G.s.chat_history.dirty"))
    end)

    it("after a load the block exists, and gf on its name loads its transcript", function()
        load()

        assert.equal(1, child.lua_get("#_G.s.chat_history.messages"))
        child.lua([[
vim.api.nvim_set_current_win(_G.s.widget:panel_win("chat"))
local name = _G.block("c1").argument
for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line == name then
        vim.api.nvim_win_set_cursor(0, { i, 3 })
    end
end
]])
        child.type_keys("gf")
        child.flush()

        assert.equal(
            child.lua_get([[_G.transcript("c1").bufnr]]),
            child.api.nvim_get_current_buf()
        )
        local text = child.lua_get([[_G.text(0)]])
        assert.truthy(text:find("saved finding", 1, true))
        assert.is_nil(text:find("replayed chunk", 1, true))
        assert.is_nil(text:find("legacy finding", 1, true))
    end)

    it("output saved without an agent record gets its own transcript", function()
        load()

        child.lua([[vim.fn.bufload(_G.transcript("toolu_old").bufnr)]])

        assert.truthy(
            child
                .lua_get([[_G.text(_G.transcript("toolu_old").bufnr)]])
                :find("legacy finding", 1, true)
        )
    end)

    it("load then save keeps subagents", function()
        load()
        child.lua([[assert(_G.s.chat_history:save() == nil)]])

        assert.same(
            { c1 = { task_id = "toolu_1" } },
            child.lua_get([[require("agentic.ui.chat_history").read("sid-x").subagents]])
        )
    end)

    it("a restore into another session manager names the new transcript", function()
        child.lua([[
vim.cmd("tabnew")
require("agentic").toggle()
_G.s2 = require("agentic.session_registry").bound_session(
    vim.api.nvim_get_current_tabpage()
)
]])
        -- The new session's own `new_session`, deferred, runs first.
        child.flush()
        child.lua([[
_G.s2.session_id = "sid-live"
_G.s2:restore_from_history(vim.deepcopy(_G.saved), { reuse_session = true })
]])

        local name = child.lua_get(
            [[vim.api.nvim_buf_get_name(_G.s2._agents.c1.transcript.bufnr)]]
        )
        assert.truthy(
            name:find(("agentic://%d/"):format(child.lua_get("_G.s2.id")), 1, true)
        )
        assert.equal(name, child.lua_get([[_G.s2:_agent_block("c1").argument]]))
        assert.truthy(
            child
                .lua_get([[_G.text(_G.s2.widget.buf_nrs.chat)]])
                :find(name, 1, true)
        )
    end)
end)

describe("subagent edge cases", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SETUP)
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    it("a tool call update while loading leaves the transcript unloaded", function()
        child.lua([[
_G.s._loading = true
_G.spawn("c1")
local h = _G.s:_build_handlers()
h.on_tool_call({ tool_call_id = "t1", kind = "read", status = "pending", argument = "a" }, "c1")
h.on_tool_call_update({ tool_call_id = "t1", status = "completed" }, "c1")
]])

        assert.is_false(
            child.lua_get(
                [[vim.api.nvim_buf_is_loaded(_G.transcript("c1").bufnr)]]
            )
        )
    end)

    it("an auto-approved request opens no subagent window", function()
        child.lua([[
_G.s.widget:close_subagent_window()
_G.spawn("c1")
_G.s.widget:close_subagent_window()
_G.s.permission_manager.add_request = function() return false end
_G.s:_on_request_permission({ sessionId = "c1", toolCall = { toolCallId = "t9" },
  options = { { optionId = "allow", name = "Allow", kind = "allow_once" } } }, function() end)
]])

        assert.is_true(
            child.lua_get([[_G.s.widget:panel_win("subagent") == nil]])
        )
    end)

    it("answering a subagent's request leaves the chat's indicator alone", function()
        child.lua([[
_G.spawn("c1")
_G.s.status_indicator:stop()
_G.s.permission_manager.add_request = function(_, _, cb) _G.cb = cb; return true end
_G.s:_on_request_permission({ sessionId = "c1", toolCall = { toolCallId = "t9" },
  options = { { optionId = "allow", name = "Allow", kind = "allow_once" } } }, function() end)
_G.cb("allow")
]])

        assert.is_false(child.lua_get([[_G.s.status_indicator:is_active()]]))
    end)

    it("output from before the Task id is known replays with the rest", function()
        child.lua([[
_G.spawn("c1")
_G.chunk("c1", "early", nil)
_G.write_meta("c1", "background", "toolu_1")
_G.s:_on_tool_call({
    tool_call_id = "t1", kind = "read", status = "pending", argument = "a.txt",
}, "c1")
_G.chunk("c1", " late", nil)
_G.s:_replay_transcript("c1")
]])

        assert.same(
            { "toolu_1", "toolu_1", "toolu_1" },
            child.lua_get([[vim.tbl_map(function(m)
    return m.parent_tool_use_id
end, _G.s.chat_history.subagent_messages)]])
        )
        local text = child.lua_get([[_G.text(_G.transcript("c1").bufnr)]])
        assert.truthy(text:find("early", 1, true))
        assert.truthy(text:find("late", 1, true))
    end)

    it("a session change drops the cached session directory", function()
        child.lua([[
_G.write_meta("x", "background", "toolu_x")
_G.found = _G.s:_find_session_dir()
_G.s.session_id = "other"
_G.s:_advance_session_epoch()
]])

        assert.is_true(child.lua_get("_G.found ~= nil"))
        assert.is_true(child.lua_get([[_G.s:_find_session_dir() == nil]]))
    end)

    it("a stray buffer under a wiped transcript's name gives way", function()
        child.lua([[
_G.spawn("c1")
_G.name = vim.api.nvim_buf_get_name(_G.transcript("c1").bufnr)
vim.cmd.bwipeout({ args = { tostring(_G.transcript("c1").bufnr) }, bang = true })
vim.cmd.edit(vim.fn.fnameescape(_G.name))
_G.chunk("c1", "back", "toolu_1")
]])

        assert.equal(
            child.lua_get("_G.name"),
            child.lua_get(
                [[vim.api.nvim_buf_get_name(_G.transcript("c1").bufnr)]]
            )
        )
        assert.truthy(
            child
                .lua_get([[_G.text(_G.transcript("c1").bufnr)]])
                :find("back", 1, true)
        )
    end)

    it("two tabpages' sessions keep their transcripts apart", function()
        child.lua([[
_G.spawn("c1")
vim.cmd("tabnew")
require("agentic").toggle()
_G.s2 = require("agentic.session_registry").bound_session(
    vim.api.nvim_get_current_tabpage()
)
]])
        child.flush()
        child.lua([[
_G.s2:_on_session_update({
    sessionUpdate = "subagent_spawned", subagentSessionId = "c2",
    name = "other", task = "t",
}, "root2")
_G.s2:_reset_subagents()
]])

        assert.is_true(
            child.lua_get(
                [[vim.api.nvim_buf_is_valid(_G.transcript("c1").bufnr)]]
            )
        )
        assert.is_true(
            child.lua_get([[_G.s2.widget:panel_win("subagent") == nil]])
        )
        assert.equal(
            child.lua_get([[_G.transcript("c1").bufnr]]),
            child.lua_get(
                [[vim.api.nvim_win_get_buf(_G.s.widget:panel_win("subagent"))]]
            )
        )
    end)
end)

describe("subagent window", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SETUP)
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    it("show_subagent switches the buffer of an open subagent window", function()
        child.lua([[
_G.spawn("c1")
_G.win = _G.s.widget:panel_win("subagent")
_G.spawn("c2")
]])

        assert.equal(
            child.lua_get("_G.win"),
            child.lua_get([[_G.s.widget:panel_win("subagent")]])
        )
        assert.equal(
            child.lua_get([[_G.transcript("c2").bufnr]]),
            child.lua_get([[vim.api.nvim_win_get_buf(_G.win)]])
        )
    end)

    for keys, check in pairs({
        gf = "in place",
        ["<C-w>f"] = "split",
        ["<C-w>gf"] = "tab",
    }) do
        it(keys .. " on a block's name opens the transcript (" .. check .. ")", function()
            child.lua([[
_G.spawn("c1")
vim.api.nvim_set_current_win(_G.s.widget:panel_win("chat"))
local name = _G.block("c1").argument
for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line == name then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
    end
end
]])
            child.type_keys(keys)
            child.flush()

            assert.equal(
                child.lua_get([[_G.transcript("c1").bufnr]]),
                child.api.nvim_get_current_buf()
            )
        end)
    end
end)
