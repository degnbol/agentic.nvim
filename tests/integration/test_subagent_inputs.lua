local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- Lua run in each child: a bound, ready session `_G.s` with a session id, a
--- throwaway session store and Claude config dir, background subagents, and
--- helpers that feed it what the bridge sends. Turns are recorded in
--- `_G.sent` instead of going to the provider, notifications in
--- `_G.notices`, bells in `_G.bells`.
local SETUP = [[
local Config = require("agentic.config")
Config.session_restore.storage_path = vim.fn.tempname()
Config.subagents.force_background = true
Config.keymaps.prompt.submit = "<F5>"
require("agentic").toggle()
_G.s = require("agentic.session_registry").bound_session(
    vim.api.nvim_get_current_tabpage()
)
_G.s.session_id = "root"
_G.s.chat_history.session_id = "root"
_G.s.agent.state = "ready"
_G.config_dir = vim.fn.tempname()
_G.s.agent.provider_config.env = { CLAUDE_CONFIG_DIR = _G.config_dir }

_G.sent = {}
_G.s._dispatch_turn = function(_, prompt)
    table.insert(_G.sent, prompt)
end
_G.notices = {}
require("agentic.utils.logger").notify = function(msg)
    table.insert(_G.notices, msg)
end
_G.bells = 0
require("agentic.session_manager")._ring_bell = function()
    _G.bells = _G.bells + 1
end

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
_G.chunk = function(source, text)
    _G.update(source, {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = text },
    })
end
_G.write_meta = function(agent_id, shape)
    local dir = vim.fs.joinpath(
        _G.config_dir, "projects", "-tmp", "root", "subagents"
    )
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ vim.json.encode({
        agentType = "Explore",
        description = "d",
        toolUseId = "toolu_" .. agent_id,
        spawnDepth = 1,
        requestShape = shape,
    }) }, vim.fs.joinpath(dir, "agent-" .. agent_id .. ".meta.json"))
end
-- Reads the record now, as the next update from the agent would.
_G.read_record = function(child_id)
    _G.s:_read_agent_record(child_id)
end
_G.transcript = function(child_id)
    return _G.s._agents[child_id].transcript
end
_G.input = function(agent_id)
    return _G.s._inputs[agent_id]
end
_G.text = function(bufnr)
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end
_G.sent_text = function(i)
    local prompt = _G.sent[i]
    return prompt and prompt[#prompt].text
end
-- Run the normal-mode map of `lhs` on `bufnr`, from the current window.
_G.press = function(bufnr, lhs)
    vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.maparg(lhs, "n", false, true)
    end).callback()
end
_G.wins_of = function(bufnr)
    return #vim.fn.win_findbuf(bufnr)
end
-- Buffers of the tab's windows, floats left out.
_G.tab_bufs = function(tab)
    local bufs = {}
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_get_config(winid).relative == "" then
            table.insert(bufs, vim.api.nvim_win_get_buf(winid))
        end
    end
    return bufs
end
-- Opens `bufnr` in a new last tabpage, as a user would, and keeps the current
-- tabpage current.
_G.show = function(bufnr)
    local tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("$tab sbuffer " .. bufnr)
    vim.api.nvim_set_current_tabpage(tab)
end
]]

describe("subagents", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SETUP)
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    for mode, background in pairs({ background = true, blocking = false }) do
        it("a " .. mode .. " spawn opens no window", function()
            child.lua(string.format(
                [[
require("agentic.config").subagents.force_background = %s
_G.spawn("c1")
]],
                tostring(background)
            ))

            assert.equal(1, child.lua_get("#vim.api.nvim_list_tabpages()"))
            assert.equal(0, child.lua_get([[_G.wins_of(_G.transcript("c1").bufnr)]]))
            assert.equal(background, child.lua_get([[_G.input("c1") ~= nil]]))
        end)
    end

    it("a background spawn's input is in no window", function()
        child.lua([[_G.spawn("c1")]])

        assert.equal(0, child.lua_get([[_G.wins_of(_G.input("c1").bufnr)]]))
    end)

    it("a record confirming background gives the input then", function()
        child.lua([[
require("agentic.config").subagents.force_background = false
_G.spawn("c1")
_G.write_meta("c1", "background")
_G.read_record("c1")
]])

        assert.is_true(child.lua_get([[_G.input("c1") ~= nil]]))
    end)

    it("a record confirming background after the agent ended gives no input", function()
        child.lua([[
require("agentic.config").subagents.force_background = false
_G.spawn("c1")
_G.state("c1", "completed")
_G.write_meta("c1", "background")
_G.read_record("c1")
]])

        assert.is_true(child.lua_get([[_G.input("c1") == nil]]))
    end)

    it("a record confirming blocking destroys the input", function()
        child.lua([[
_G.spawn("c1")
_G.bufnr = _G.input("c1").bufnr
_G.write_meta("c1", "blocking")
_G.read_record("c1")
]])

        assert.is_true(child.lua_get([[_G.input("c1") == nil]]))
        assert.is_false(child.lua_get("vim.api.nvim_buf_is_valid(_G.bufnr)"))
    end)

    it("no input while loading", function()
        child.lua([[
_G.s._loading = true
_G.spawn("c1")
]])

        assert.is_true(child.lua_get([[_G.input("c1") == nil]]))
    end)

    it("no input with an adapter that gives no instruction", function()
        child.lua([[
_G.s.agent.subagent_message_instruction = function() return nil end
_G.spawn("c1")
]])

        assert.is_true(child.lua_get([[_G.input("c1") == nil]]))
    end)

    it("a later generation reuses the input and takes over the windows", function()
        child.lua([[
_G.spawn("c1")
_G.old = _G.transcript("c1").bufnr
_G.show(_G.old)
vim.cmd("vsplit")
vim.api.nvim_win_set_buf(0, _G.old)
_G.first_input = _G.input("c1")
_G.state("c1", "completed")
_G.spawn("c1:generation:2")
_G.new = _G.transcript("c1:generation:2").bufnr
-- The older generation's record, read late, takes nothing back.
_G.s._agents.c1.record_read = false
_G.write_meta("c1", "background")
_G.read_record("c1")
]])

        assert.equal(2, child.lua_get("#vim.api.nvim_list_tabpages()"))
        assert.is_true(child.lua_get([[_G.input("c1") == _G.first_input]]))
        assert.equal(0, child.lua_get("_G.wins_of(_G.old)"))
        assert.equal(2, child.lua_get("_G.wins_of(_G.new)"))
    end)

    it("with no window, output lands and <C-c> stops that agent", function()
        child.lua([[
_G.spawn("c1")
_G.chunk("c1", "still going")
_G.press(_G.transcript("c1").bufnr, "<C-c>")
_G.press(_G.input("c1").bufnr, "<C-c>")
]])

        assert.truthy(
            child
                .lua_get([[_G.text(_G.transcript("c1").bufnr)]])
                :find("still going", 1, true)
        )
        assert.equal(2, child.lua_get("#_G.sent"))
        assert.truthy(child.lua_get("_G.sent_text(1)"):find("TaskStop", 1, true))
        assert.truthy(child.lua_get("_G.sent_text(2)"):find('"c1"', 1, true))
    end)

    it("<C-c> stops the agent in a wiped and remade transcript", function()
        child.lua([[
_G.spawn("c1")
vim.cmd.bwipeout({ args = { tostring(_G.transcript("c1").bufnr) }, bang = true })
_G.chunk("c1", "back")
_G.press(_G.transcript("c1").bufnr, "<C-c>")
]])

        assert.truthy(child.lua_get("_G.sent_text(1)"):find("TaskStop", 1, true))
    end)

    it("stopping a finished agent notifies and sends nothing", function()
        child.lua([[
_G.spawn("c1")
_G.state("c1", "completed")
_G.s:_stop_agent("c1")
]])

        assert.equal(0, child.lua_get("#_G.sent"))
        assert.truthy(
            child.lua_get("_G.notices[#_G.notices]"):find("finished", 1, true)
        )
    end)

    for _, case in ipairs({
        { how = "the submit map", run = [[_G.press(_G.bufnr, "<F5>")]] },
        { how = ":w", run = [[vim.api.nvim_buf_call(_G.bufnr, function() vim.cmd.write() end)]] },
    }) do
        it(case.how .. " relays the message and clears the input", function()
            child.lua([[
_G.spawn("c1")
_G.bufnr = _G.input("c1").bufnr
vim.api.nvim_buf_set_lines(_G.bufnr, 0, -1, false, { "look in lib/" })
]] .. case.run)

            assert.truthy(
                child.lua_get("_G.sent_text(1)"):find("SendMessage", 1, true)
            )
            assert.truthy(
                child.lua_get("_G.sent_text(1)"):find("look in lib/", 1, true)
            )
            assert.equal("", child.lua_get("_G.text(_G.bufnr)"))
            assert.is_false(child.lua_get("vim.bo[_G.bufnr].modified"))
        end)
    end

    it(":w sends past a usage limit; the submit map does not", function()
        child.lua([[
_G.spawn("c1")
_G.s._usage_reset_epoch = os.time() + 3600
_G.bufnr = _G.input("c1").bufnr
vim.api.nvim_buf_set_lines(_G.bufnr, 0, -1, false, { "held" })
_G.press(_G.bufnr, "<F5>")
_G.after_map = #_G.sent
vim.api.nvim_buf_call(_G.bufnr, function() vim.cmd.write() end)
]])

        assert.equal(0, child.lua_get("_G.after_map"))
        assert.equal(1, child.lua_get("#_G.sent"))
    end)

    it("a relay that cannot go out stays in the input with the notice", function()
        child.lua([[
_G.spawn("c1")
_G.s.agent.state = "disconnected"
_G.bufnr = _G.input("c1").bufnr
vim.api.nvim_buf_set_lines(_G.bufnr, 0, -1, false, { "first" })
_G.press(_G.bufnr, "<F5>")
_G.s:_relay_to_agent("c1", "second", { force = false })
]])

        assert.equal(0, child.lua_get("#_G.sent"))
        assert.equal("first", child.lua_get("_G.text(_G.bufnr)"))
        assert.is_true(child.lua_get("vim.bo[_G.bufnr].modified"))
        assert.truthy(child.lua_get("_G.notices[1]"):find("no session yet", 1, true))
        assert.is_true(child.lua_get("_G.s._pending_bufferless_prompt == nil"))
    end)

    it("a relay leaves the next turn's context, title and system info alone", function()
        child.lua([[
_G.spawn("c1")
_G.file = vim.fn.tempname()
vim.fn.writefile({ "x" }, _G.file)
_G.s.file_list:add(_G.file)
_G.had_file = not _G.s.file_list:is_empty()
_G.s._prompt_pending = 1
_G.s._is_first_message = true
_G.s._history_to_send = { { type = "user", text = "earlier" } }
_G.s:_relay_to_agent("c1", "hi", { force = false })
]])

        assert.equal(1, child.lua_get("#_G.sent"))
        assert.equal(1, child.lua_get("#_G.sent[1]"))
        assert.is_true(child.lua_get("_G.had_file"))
        assert.is_false(child.lua_get("_G.s.file_list:is_empty()"))
        assert.is_true(child.lua_get("_G.s._is_first_message"))
        assert.is_true(child.lua_get("_G.s._history_to_send ~= nil"))
        assert.equal("", child.lua_get("_G.s.chat_history.title"))
        assert.truthy(
            child
                .lua_get("_G.text(_G.s.widget.buf_nrs.chat)")
                :find("SendMessage", 1, true)
        )
        assert.equal(
            "user",
            child.lua_get(
                "_G.s.chat_history.messages[#_G.s.chat_history.messages].type"
            )
        )
    end)

    it("an input reloaded after :bd gets its setup back", function()
        child.lua([[
_G.spawn("c1")
_G.bufnr = _G.input("c1").bufnr
vim.cmd.bdelete({ args = { tostring(_G.bufnr) } })
_G.loaded_after_bd = vim.api.nvim_buf_is_loaded(_G.bufnr)
vim.fn.bufload(_G.bufnr)
]])

        assert.is_false(child.lua_get("_G.loaded_after_bd"))
        assert.equal("acwrite", child.lua_get("vim.bo[_G.bufnr].buftype"))
        assert.equal(
            child.lua_get("_G.s.id"),
            child.lua_get("vim.b[_G.bufnr].agentic_session_id")
        )
        assert.truthy(
            child
                .lua_get("vim.b[_G.bufnr].agentic_header.title")
                :find("Message to find it", 1, true)
        )
        assert.is_true(
            child.lua_get([[vim.api.nvim_buf_call(_G.bufnr, function()
    return vim.fn.maparg("<F5>", "n") ~= "" and vim.fn.maparg("<C-c>", "n") ~= ""
end)]])
        )
    end)

    it("a new session and a subagent reset wipe the inputs, giving back their text", function()
        child.lua([[
_G.spawn("c1")
_G.spawn("c2")
_G.one = _G.input("c1").bufnr
vim.api.nvim_buf_set_lines(_G.one, 0, -1, false, { "unsent words" })
_G.s:_advance_session_epoch()
_G.after_epoch = vim.tbl_count(_G.s._inputs)
_G.spawn("c3")
_G.three = _G.input("c3").bufnr
_G.s:_reset_subagents()
]])

        assert.equal(0, child.lua_get("_G.after_epoch"))
        assert.is_false(child.lua_get("vim.api.nvim_buf_is_valid(_G.one)"))
        assert.is_false(child.lua_get("vim.api.nvim_buf_is_valid(_G.three)"))
        assert.equal(0, child.lua_get("vim.tbl_count(_G.s._inputs)"))
        assert.equal(1, child.lua_get("#_G.notices"))
        assert.truthy(child.lua_get("_G.notices[1]"):find("unsent words", 1, true))
    end)

    it("a current tab holding only a transcript and its input closes when they go", function()
        child.lua([[
_G.spawn("c1")
_G.show(_G.transcript("c1").bufnr)
vim.cmd("tabnext 2")
_G.press(_G.transcript("c1").bufnr, "i")
vim.cmd("stopinsert")
_G.s:_reset_subagents()
]])

        assert.equal(1, child.lua_get("#vim.api.nvim_list_tabpages()"))
    end)
end)

describe("insert keys", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SETUP)
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    it("in a transcript with an input open the input below, then focus it", function()
        child.lua([[
_G.spawn("c1")
_G.show(_G.transcript("c1").bufnr)
vim.cmd("tabnext 2")
_G.tr = vim.api.nvim_get_current_win()
_G.press(_G.transcript("c1").bufnr, "i")
_G.first = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(_G.tr)
_G.press(_G.transcript("c1").bufnr, "a")
]])

        assert.equal(
            child.lua_get([[_G.input("c1").bufnr]]),
            child.lua_get("vim.api.nvim_get_current_buf()")
        )
        assert.equal(child.lua_get("_G.first"), child.lua_get("vim.api.nvim_get_current_win()"))
        assert.equal(2, child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"))
    end)

    it("in a blocking transcript go to the main input", function()
        child.lua([[
require("agentic.config").subagents.force_background = false
_G.spawn("c1")
_G.show(_G.transcript("c1").bufnr)
vim.cmd("tabnext 2")
_G.press(_G.transcript("c1").bufnr, "i")
]])

        assert.equal(
            child.lua_get("_G.s.widget.buf_nrs.input"),
            child.lua_get("vim.api.nvim_get_current_buf()")
        )
        assert.equal(2, child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"))
    end)

    it("p in a transcript pastes into its input", function()
        child.lua([[
vim.fn.setreg('"', "pasted")
_G.spawn("c1")
_G.show(_G.transcript("c1").bufnr)
vim.cmd("tabnext 2")
_G.press(_G.transcript("c1").bufnr, "p")
]])

        assert.equal("pasted", child.lua_get([[_G.text(_G.input("c1").bufnr)]]))
    end)

    it("in the widget's chat window reopen the widget's input slot", function()
        child.lua([[
vim.api.nvim_win_close(_G.s.widget.win_nrs.input, true)
vim.api.nvim_set_current_win(_G.s.widget:panel_win("chat"))
_G.press(_G.s.widget.buf_nrs.chat, "i")
_G.s.widget:show({ focus_prompt = false })
]])

        assert.is_true(child.lua_get([[_G.s.widget:panel_win("input") ~= nil]]))
        assert.equal(1, child.lua_get("_G.wins_of(_G.s.widget.buf_nrs.input)"))
    end)

    it("in a chat window outside the widget open a split below it", function()
        child.lua([[
vim.cmd("tabnew")
_G.chat_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(0, _G.s.widget.buf_nrs.chat)
_G.press(_G.s.widget.buf_nrs.chat, "i")
_G.input_win = vim.api.nvim_get_current_win()
]])

        assert.equal(
            child.lua_get("_G.s.widget.buf_nrs.input"),
            child.lua_get("vim.api.nvim_win_get_buf(_G.input_win)")
        )
        assert.equal(2, child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"))
        assert.is_true(
            child.lua_get([[_G.s.widget.win_nrs.input ~= _G.input_win]])
        )
    end)

    it("p in a chat window outside the widget pastes into the split below", function()
        child.lua([[
vim.fn.setreg('"', "pasted")
vim.cmd("tabnew")
vim.api.nvim_win_set_buf(0, _G.s.widget.buf_nrs.chat)
_G.press(_G.s.widget.buf_nrs.chat, "p")
]])

        assert.equal(
            child.lua_get("_G.s.widget.buf_nrs.input"),
            child.lua_get("vim.api.nvim_get_current_buf()")
        )
        assert.equal("pasted", child.lua_get("_G.text(_G.s.widget.buf_nrs.input)"))
    end)
end)

describe("subagent permission prompts", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SETUP)
        child.lua([[
_G.spawn("c1")
_G.request = function()
    _G.s:_on_request_permission({
        sessionId = "c1",
        toolCall = { toolCallId = "t9", kind = "edit", rawInput = { file_path = "/nonexistent/x" } },
        options = { { optionId = "allow", name = "Allow", kind = "allow_once" } },
    }, function() end)
end
]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    it("a prompt not in the current tab is hidden until its tab is entered, and rings once", function()
        child.lua([[
_G.show(_G.transcript("c1").bufnr)
_G.request()
]])
        child.flush()
        assert.is_true(child.lua_get("_G.s.permission_manager._hidden"))
        assert.equal(1, child.lua_get("_G.bells"))

        child.lua([[vim.cmd("tabnext 2")]])
        child.flush()
        assert.is_false(child.lua_get("_G.s.permission_manager._hidden"))
        assert.equal(
            "Select permission option allow",
            child.lua_get([[vim.api.nvim_buf_call(_G.input("c1").bufnr, function()
    return vim.fn.maparg("<localLeader>y", "n", false, true).desc
end)]])
        )

        child.lua([[vim.cmd("tabnext 1")]])
        child.flush()
        child.lua([[vim.cmd("tabnext 2")]])
        child.flush()
        assert.equal(1, child.lua_get("_G.bells"))
    end)

    it("the [?] badge stays until the prompt is answered", function()
        child.lua([[
_G.badge = function()
    return require("agentic.ui.window_decoration").get_header(_G.transcript("c1").bufnr).badge
end
_G.show(_G.transcript("c1").bufnr)
_G.request()
]])
        child.flush()
        child.lua([[vim.cmd("tabnext 2")]])
        child.flush()
        assert.equal("[?]", child.lua_get("_G.badge()"))

        child.lua([[_G.s.permission_manager:_complete_request("allow")]])
        assert.equal(vim.NIL, child.lua_get("_G.badge()"))
    end)

    it("a prompt whose transcript has no window opens its tab", function()
        child.lua([[_G.request()]])

        assert.same(
            { child.lua_get([[_G.transcript("c1").bufnr]]) },
            child.lua_get("_G.tab_bufs(vim.api.nvim_list_tabpages()[2])")
        )
    end)
end)
