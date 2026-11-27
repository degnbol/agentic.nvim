local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- Lua run in each child: a bound, ready session `_G.s` with a session id, a
--- throwaway session store and Claude config dir, background subagents, and
--- helpers that feed it what the bridge sends. Turns are recorded in
--- `_G.sent` instead of going to the provider, the session ids of
--- `session/cancel` in `_G.cancels`, notifications in `_G.notices`, bells in
--- `_G.bells`.
local SETUP = [[
local Config = require("agentic.config")
Config.sessions.storage_path = vim.fn.tempname()
Config.keymaps.prompt.submit = "<F5>"
vim.cmd("Agentic")
_G.s = require("agentic.session_registry").current()
_G.s.session_id = "root"
_G.s.chat_history.session_id = "root"
_G.s.agent.state = "ready"
_G.config_dir = vim.fn.tempname()
_G.s.agent.provider_config.env = { CLAUDE_CONFIG_DIR = _G.config_dir }

_G.sent = {}
_G.s._dispatch_turn = function(self, prompt, sent)
    table.insert(_G.sent, prompt)
    table.insert(self._untaken, sent)
end
_G.cancels = {}
_G.s.agent.stop_generation = function(_, session_id)
    table.insert(_G.cancels, session_id)
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
        sessionUpdate = "subagent_update",
        sessionId = child_id,
        description = name or "find it",
        capabilities = { cancel = {} },
        state = { state = "running" },
    })
end
_G.state = function(child_id, state)
    _G.update("root", {
        sessionUpdate = "subagent_update",
        sessionId = child_id,
        state = state,
    })
end
_G.COMPLETED = { state = "idle", stopReason = "end_turn" }
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
    _G.s._subagents:read_record(child_id)
end
_G.transcript = function(child_id)
    return _G.s._subagents._agents[child_id].transcript
end
_G.input = function(child_id)
    return _G.s._subagents._inputs[child_id]
end
_G.text = function(bufnr)
    return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end
_G.sent_text = function(i)
    local prompt = _G.sent[i]
    return prompt and prompt[#prompt].text
end
-- Run the normal-mode map of `lhs` on `bufnr`, from the current window, and
-- the keys it feeds, ending in normal mode.
_G.press = function(bufnr, lhs)
    vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.maparg(lhs, "n", false, true)
    end).callback()
    vim.api.nvim_feedkeys("", "x", false)
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

    it("no input with an adapter that gives no instruction", function()
        child.lua([[
_G.s.agent.subagent_message_instruction = function() return nil end
_G.spawn("c1")
]])

        assert.is_true(child.lua_get([[_G.input("c1") == nil]]))
    end)

    it(
        "a resumed agent keeps its input and its transcript's windows",
        function()
            child.lua([[
_G.spawn("c1")
_G.old = _G.transcript("c1").bufnr
_G.show(_G.old)
_G.first_input = _G.input("c1")
_G.state("c1", _G.COMPLETED)
_G.state("c1", { state = "running" })
]])

            assert.is_true(child.lua_get([[_G.input("c1") == _G.first_input]]))
            assert.equal(1, child.lua_get("_G.wins_of(_G.old)"))
            assert.is_true(
                child.lua_get([[_G.transcript("c1").bufnr == _G.old]])
            )
        end
    )

    it("<C-c> stops the agent in a wiped and remade transcript", function()
        child.lua([[
_G.spawn("c1")
vim.cmd.bwipeout({ args = { tostring(_G.transcript("c1").bufnr) }, bang = true })
_G.chunk("c1", "back")
_G.press(_G.transcript("c1").bufnr, "<C-c>")
]])

        assert.same({ "c1" }, child.lua_get("_G.cancels"))
        assert.equal(0, child.lua_get("#_G.sent"))
    end)

    for state, setup in pairs({
        blocking = [[
_G.write_meta("c1", "blocking")
_G.read_record("c1")
]],
        finished = [[_G.state("c1", _G.COMPLETED)]],
        ["not cancellable"] = [[
_G.update("root", {
    sessionUpdate = "subagent_update", sessionId = "c1", capabilities = vim.NIL,
})
]],
    }) do
        it("<C-c> on a " .. state .. " agent cancels its session", function()
            child.lua([[_G.spawn("c1")]])
            child.lua(setup)
            child.lua([[_G.press(_G.transcript("c1").bufnr, "<C-c>")]])

            assert.same({ "c1" }, child.lua_get("_G.cancels"))
            assert.equal(0, child.lua_get("#_G.sent"))
        end)
    end
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

    it("in the home window open the input panel, then reuse it", function()
        child.lua([[
_G.home = _G.s.widget:home_win()
vim.api.nvim_set_current_win(_G.home)
_G.press(_G.s.widget.buf_nrs.agent, "i")
_G.first = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(_G.home)
_G.press(_G.s.widget.buf_nrs.agent, "a")
]])

        assert.equal(
            child.lua_get([[_G.s.widget:panel_win("input")]]),
            child.lua_get("vim.api.nvim_get_current_win()")
        )
        assert.equal(
            child.lua_get("_G.first"),
            child.lua_get("vim.api.nvim_get_current_win()")
        )
        assert.equal(1, child.lua_get("_G.wins_of(_G.s.widget.buf_nrs.input)"))
        assert.equal(
            child.lua_get("_G.home"),
            child.lua_get([[vim.fn.win_getid(vim.fn.winnr("k"))]])
        )
    end)

    it("in a chat window outside the home's tab move the home there", function()
        child.lua([[
vim.cmd("tabnew")
_G.chat_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(0, _G.s.widget.buf_nrs.agent)
_G.press(_G.s.widget.buf_nrs.agent, "i")
_G.input_win = vim.api.nvim_get_current_win()
]])

        assert.equal(
            child.lua_get("_G.s.widget.buf_nrs.input"),
            child.lua_get("vim.api.nvim_win_get_buf(_G.input_win)")
        )
        assert.equal(2, child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"))
        assert.equal(
            child.lua_get("_G.chat_win"),
            child.lua_get("_G.s.widget:home_win()")
        )
        assert.equal(
            child.lua_get("_G.input_win"),
            child.lua_get([[_G.s.widget:panel_win("input")]])
        )
    end)

    it(
        "p in a chat window outside the home's tab pastes into its input",
        function()
            child.lua([[
vim.fn.setreg('"', "pasted")
vim.cmd("tabnew")
vim.api.nvim_win_set_buf(0, _G.s.widget.buf_nrs.agent)
_G.press(_G.s.widget.buf_nrs.agent, "p")
]])

            assert.equal(
                child.lua_get("_G.s.widget.buf_nrs.input"),
                child.lua_get("vim.api.nvim_get_current_buf()")
            )
            assert.equal(
                "pasted",
                child.lua_get("_G.text(_G.s.widget.buf_nrs.input)")
            )
        end
    )
end)

describe("subagent permission prompts", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SETUP)
        child.lua([[
_G.s.chat_history:add_message({
    type = "user", text = "go", timestamp = 0, provider_name = "p",
})
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

    describe("whose transcript has no window", function()
        before_each(function()
            child.lua([[
_G.float = _G.s.permission_manager.permission_float
_G.float_win = function()
    return vim.api.nvim_win_get_config(_G.float._winid).win
end
_G.chat_win = function()
    return _G.s.widget:home_win()
end
_G.transcript_win = function()
    return vim.fn.win_findbuf(_G.transcript("c1").bufnr)[1]
end
_G.title = function()
    local title = vim.api.nvim_win_get_config(_G.float._winid).title
    return title and title[1][1]
end
_G.label = function()
    return _G.s._subagents:agent_label("c1")
end
]])
        end)

        --- Ask, press `lhs` on the chat from the current window, and let the
        --- layout settle.
        --- @param lhs string
        local function request_and_press(lhs)
            child.lua([[_G.request()]])
            child.flush()
            child.lua([[_G.press(_G.s.widget.buf_nrs.agent, ...)]], { lhs })
            child.flush()
        end

        it("shows on the chat, which holds the subagent's block", function()
            child.lua([[_G.request()]])
            child.flush()

            assert.equal(1, child.lua_get("#vim.api.nvim_list_tabpages()"))
            assert.equal(
                child.lua_get("_G.chat_win()"),
                child.lua_get("_G.float_win()")
            )
            assert.equal("find it", child.lua_get("_G.label()"))
            assert.equal("find it", child.lua_get("_G.title()"))
            assert.equal(
                "c1",
                child.lua_get("_G.s.message_writer._held_tool_call_id")
            )
        end)

        it("\\v opens a vsplit and the prompt moves there, pending", function()
            request_and_press("<localLeader>v")

            assert.equal(
                1,
                child.lua_get("_G.wins_of(_G.transcript('c1').bufnr)")
            )
            assert.is_true(
                child.lua_get("_G.s.permission_manager.current_request ~= nil")
            )
            assert.equal(
                child.lua_get("_G.transcript_win()"),
                child.lua_get("_G.float_win()")
            )
            assert.equal(vim.NIL, child.lua_get("_G.title()"))
            assert.equal(
                "",
                child.lua_get(
                    [[vim.api.nvim_buf_call(_G.s.widget.buf_nrs.agent, function()
    return vim.fn.maparg("<localLeader>v", "n")
end)]]
                )
            )
            assert.equal(
                vim.NIL,
                child.lua_get("_G.s.message_writer._held_tool_call_id")
            )
        end)

        it("with the transcript wiped, \\v opens the remade one", function()
            child.lua([[
_G.request()
_G.old = _G.transcript("c1").bufnr
vim.cmd.bwipeout({ args = { tostring(_G.old) }, bang = true })
]])
            child.flush()
            child.lua([[_G.press(_G.s.widget.buf_nrs.agent, "<localLeader>v")]])
            child.flush()

            assert.is_true(child.lua_get("_G.transcript('c1').bufnr ~= _G.old"))
            assert.equal(
                1,
                child.lua_get("_G.wins_of(_G.transcript('c1').bufnr)")
            )
            assert.equal(
                child.lua_get("_G.transcript_win()"),
                child.lua_get("_G.float_win()")
            )
            assert.equal(
                "t9",
                child.lua_get(
                    "_G.transcript('c1').view.writer._held_tool_call_id"
                )
            )
        end)

        it("\\s opens a split in the current tab", function()
            request_and_press("<localLeader>s")

            assert.equal(1, child.lua_get("#vim.api.nvim_list_tabpages()"))
            assert.equal(
                1,
                child.lua_get("_G.wins_of(_G.transcript('c1').bufnr)")
            )
        end)

        it("\\t opens a last tab and enters it", function()
            request_and_press("<localLeader>t")

            assert.equal(2, child.lua_get("#vim.api.nvim_list_tabpages()"))
            assert.equal(2, child.lua_get("vim.api.nvim_tabpage_get_number(0)"))
            assert.equal(
                child.lua_get("_G.transcript_win()"),
                child.lua_get("vim.api.nvim_get_current_win()")
            )
        end)

        it("\\e in the chat window replaces it", function()
            child.lua([[vim.api.nvim_set_current_win(_G.chat_win())]])
            local chat_win = child.lua_get("_G.chat_win()")

            request_and_press("<localLeader>e")

            assert.equal(chat_win, child.lua_get("_G.transcript_win()"))
            assert.equal(chat_win, child.lua_get("_G.float_win()"))
            assert.equal(vim.NIL, child.lua_get("_G.title()"))
        end)

        it(
            "\\e in the input replaces the chat window and focuses it",
            function()
                local chat_win = child.lua_get("_G.chat_win()")
                child.lua(
                    [[vim.api.nvim_set_current_win(_G.s.widget:input_win())]]
                )

                request_and_press("<localLeader>e")

                assert.equal(chat_win, child.lua_get("_G.transcript_win()"))
                assert.equal(
                    chat_win,
                    child.lua_get("vim.api.nvim_get_current_win()")
                )
                assert.equal(vim.NIL, child.lua_get("_G.title()"))
            end
        )

        it(
            "with the chat in another tab, shows on the current tab titled, holding nothing",
            function()
                child.lua([[
_G.s.chat_history.title = "Fix parser"
vim.cmd("tabnew")
_G.request()
]])
                child.flush()

                assert.equal(
                    child.lua_get("vim.api.nvim_get_current_win()"),
                    child.lua_get("_G.float_win()")
                )
                assert.equal(
                    "Fix parser · " .. child.lua_get("_G.label()"),
                    child.lua_get("_G.title()")
                )
                assert.equal(
                    vim.NIL,
                    child.lua_get("_G.s.message_writer._held_tool_call_id")
                )
            end
        )

        it(
            "with the chat not shown, shows on the current window, then on the chat once :Agentic shows it",
            function()
                child.lua([[
-- A message keeps the session alive while its chat is not shown.
table.insert(_G.s.chat_history.messages, { type = "user", text = "hi" })
vim.api.nvim_set_current_win(_G.chat_win())
vim.cmd("enew")
_G.request()
]])
                child.flush()
                assert.equal(
                    child.lua_get("vim.api.nvim_get_current_win()"),
                    child.lua_get("_G.float_win()")
                )

                child.cmd("Agentic")
                child.flush()

                assert.equal(
                    child.lua_get("_G.chat_win()"),
                    child.lua_get("_G.float_win()")
                )
            end
        )
    end)

    it(
        "after \\v, the transcript's prompting block is placed in view",
        function()
            child.lua([[
local writer = _G.transcript("c1").view.writer
for i = 1, 60 do
    _G.chunk("c1", "line " .. i .. "\n\n")
end
writer:write_tool_call_block({
    tool_call_id = "t9", status = "pending", kind = "execute",
    argument = "ls", body = { "output" },
})
for i = 1, 60 do
    _G.chunk("c1", "after " .. i .. "\n\n")
end
_G.request()
]])
            child.flush()
            child.lua([[_G.press(_G.s.widget.buf_nrs.agent, "<localLeader>v")]])
            child.flush()

            assert.is_true(child.lua_get([[(function()
    local transcript = _G.transcript("c1")
    local writer = transcript.view.writer
    local s = writer:_block_rows(writer.tool_call_blocks.t9)
    local win = vim.fn.win_findbuf(transcript.bufnr)[1]
    local info = vim.fn.getwininfo(win)[1]
    return s ~= nil and info.topline <= s + 1 and info.botline >= s + 1
end)()]]))
        end
    )
end)
