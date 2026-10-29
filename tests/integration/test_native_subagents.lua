local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- Lua run in each child: a bound session `_G.s` with a session id, a
--- throwaway session store and Claude config dir, and helpers that feed it
--- what the bridge sends.
local SETUP = [[
require("agentic.config").session_restore.storage_path = vim.fn.tempname()
vim.cmd("Agentic")
_G.s = require("agentic.session_registry").current()
_G.s.session_id = "root"
_G.s.chat_history.session_id = "root"
_G.config_dir = vim.fn.tempname()
_G.s.agent.provider_config.env = { CLAUDE_CONFIG_DIR = _G.config_dir }

_G.COMPLETED = { state = "idle", stopReason = "end_turn" }

_G.update = function(source, update)
    _G.s:_on_session_update(update, source)
end
-- The announce of a child on `parent` (default the root): running unless
-- `state` is given, `false` for none.
_G.announce = function(child_id, label, parent, state)
    if state == nil then
        state = { state = "running" }
    end
    _G.update(parent or "root", {
        sessionUpdate = "subagent_update",
        sessionId = child_id,
        description = label or "find it",
        capabilities = { cancel = {} },
        state = state or nil,
    })
end
-- A linked pair of session messages `id`, each view on its own session.
_G.message = function(id, sender, recipient, text)
    for _, view in ipairs({
        { session = sender, link = "recipientMessageId" },
        { session = recipient, link = "senderMessageId" },
    }) do
        _G.update(view.session, {
            sessionUpdate = "session_message",
            messageId = id,
            senderSessionId = sender,
            recipientSessionId = recipient,
            content = { { type = "text", text = text } },
            [view.link] = id,
        })
    end
end
-- A live launch: the announce, then the prompt from `parent`, as the Task
-- `toolu_<child_id>`.
_G.spawn = function(child_id, label, parent)
    _G.announce(child_id, label, parent)
    _G.message("toolu_" .. child_id, parent or "root", child_id, "Find the files.")
end
_G.state = function(child_id, state, parent)
    _G.update(parent or "root", {
        sessionUpdate = "subagent_update",
        sessionId = child_id,
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
_G.call = function(child_id, id)
    _G.s:_on_tool_call({
        tool_call_id = id, kind = "read", status = "pending", argument = "a.txt",
    }, child_id)
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
_G.ttext = function(child_id)
    return _G.text(_G.transcript(child_id).bufnr)
end
_G.chat_name = function()
    return vim.api.nvim_buf_get_name(_G.s.widget.buf_nrs.agent)
end
_G.tname = function(child_id)
    return vim.api.nvim_buf_get_name(_G.transcript(child_id).bufnr)
end
_G.G = require("agentic.glyphs")
_G.block = function(child_id)
    return _G.s:_agent_block(child_id)
end
_G.context = function(child_id)
    return vim.b[_G.transcript(child_id).bufnr].agentic_header.context
end
-- The sign on the first row of a transcript titled `title`.
_G.sign_of = function(child_id, title)
    return _G.buf_sign_of(_G.transcript(child_id).bufnr, title)
end
_G.chat_sign_of = function(title)
    return _G.buf_sign_of(_G.s.widget.buf_nrs.agent, title)
end
_G.buf_sign_of = function(bufnr, title)
    local W = require("agentic.ui.message_writer")
    for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if line == "## " .. title then
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr, W.NS_USER_ACTIONS, { i - 1, 0 }, { i - 1, -1 }, { details = true }
            )
            return marks[1] and vim.trim(marks[1][4].sign_text)
        end
    end
end
_G.types = function()
    return vim.tbl_map(function(m)
        return m.type
    end, _G.s.chat_history.subagent_messages)
end
]]

--- Number of times `needle` occurs in `haystack`.
--- @param haystack string
--- @param needle string
--- @return integer
local function count(haystack, needle)
    local n, init = 0, 1
    while true do
        local i = haystack:find(needle, init, true)
        if not i then
            return n
        end
        n, init = n + 1, i + #needle
    end
end

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

    it("a launch writes a named transcript, a completed block and the prompt's link", function()
        child.lua([[_G.spawn("aa11bb22cc33dd44", "find it")]])

        local name =
            child.lua_get([[vim.api.nvim_buf_get_name(_G.transcript("aa11bb22cc33dd44").bufnr)]])
        assert.is_true(vim.endswith(name, "/subagent/cc33dd44-find-it"))
        assert.equal(name, child.lua_get([[_G.block("aa11bb22cc33dd44").argument]]))
        assert.equal("SubAgent", child.lua_get([[_G.block("aa11bb22cc33dd44").kind]]))
        assert.equal("completed", child.lua_get([[_G.block("aa11bb22cc33dd44").status]]))
        assert.is_true(child.lua_get([[_G.block("aa11bb22cc33dd44").body == nil]]))
        local chat = child.lua_get([[_G.text(_G.s.widget.buf_nrs.agent)]])
        assert.truthy(chat:find("## Find the files.\n" .. name, 1, true))
        local transcript = child.lua_get([[_G.ttext("aa11bb22cc33dd44")]])
        assert.truthy(transcript:find("## Blocking? find it", 1, true))
        assert.equal(
            1,
            count(transcript, "## Find the files.\n" .. child.lua_get("_G.chat_name()"))
        )
        -- Both rows of a launch carry its glyph.
        assert.equal(
            child.lua_get("_G.G.MESSAGE.launch"),
            child.lua_get([[_G.sign_of("aa11bb22cc33dd44", "Find the files.")]])
        )
        assert.equal(
            child.lua_get("_G.G.MESSAGE.launch"),
            child.lua_get([[_G.chat_sign_of("Find the files.")]])
        )
        assert.is_true(child.lua_get([[_G.s._agents.aa11bb22cc33dd44.open]]))
    end)

    it("an announce without state opens no indicator and no input", function()
        child.lua([[
_G.s.agent.provider_config.subagents.force_background = true
_G.announce("c1", "find it", "root", false)
]])

        assert.is_false(child.lua_get([[_G.s._agents.c1.open]]))
        assert.is_false(
            child.lua_get([[_G.transcript("c1").status_indicator:is_active()]])
        )
        assert.is_true(child.lua_get([[_G.s._inputs.c1 == nil]]))
    end)

    it("a null state and a message without content change nothing else", function()
        child.lua([[
_G.spawn("c1")
_G.update("root", { sessionUpdate = "subagent_update", sessionId = "c1", state = vim.NIL })
_G.update("c1", {
    sessionUpdate = "session_message", messageId = "m9", recipientSessionId = "c1",
})
]])

        assert.is_true(child.lua_get([[_G.s._agents.c1.open]]))
        assert.truthy(
            child.lua_get([[_G.ttext("c1")]]):find("## (empty message)", 1, true)
        )
    end)

    it("a custom state is not an end", function()
        child.lua([[
_G.spawn("c1")
_G.state("c1", { state = "_paused" })
]])

        assert.is_true(child.lua_get([[_G.s._agents.c1.open]]))
        assert.is_nil(child.lua_get([[_G.ttext("c1")]]):find("_paused", 1, true))
    end)

    it("a message from a child is no delegation and no launch prompt", function()
        child.lua([[
-- An ancestor announced without state or prompt, as for a restored child.
_G.announce("c1", "alpha", "root", false)
_G.announce("c2", "beta", "c1")
_G.update("c1", {
    sessionUpdate = "session_message", messageId = "toolu_c2:reply",
    senderSessionId = "c2", recipientSessionId = "c1",
    content = { { type = "text", text = "Found it." } },
})
]])

        assert.is_true(child.lua_get([[_G.block("c1").body == nil]]))
        assert.is_true(
            child.lua_get([[_G.s._agent_by_task["toolu_c2:reply"] == nil]])
        )
        assert.truthy(
            child.lua_get([[_G.ttext("c1")]]):find("## Found it.\n" .. child.lua_get([[_G.tname("c2")]]), 1, true)
        )
        assert.equal(
            child.lua_get("_G.G.MESSAGE.result"),
            child.lua_get([[_G.sign_of("c1", "Found it.")]])
        )
    end)

    it("a later announce gives a known agent its parent", function()
        child.lua([[
_G.spawn("c1")
-- As for an agent restored from a file.
_G.s._agents.c1.parent_session_id = nil
_G.announce("c1", "find it", "root", false)
]])

        assert.equal("root", child.lua_get([[_G.s._agents.c1.parent_session_id]]))
    end)

    it("a SendMessage shows its text in both buffers, each with the other's path", function()
        child.lua([[
_G.spawn("c1")
_G.message("toolu_send", "root", "c1", "Look in lib/ too.\nAnd tests/.")
]])

        local transcript = child.lua_get([[_G.ttext("c1")]])
        assert.equal(
            1,
            count(transcript, "## Look in lib/ too.\n" .. child.lua_get("_G.chat_name()") .. "\n```markdown-fold\nAnd tests/.\n```")
        )
        local chat = child.lua_get([[_G.text(_G.s.widget.buf_nrs.agent)]])
        assert.equal(
            1,
            count(chat, "## Look in lib/ too.\n" .. child.lua_get([[_G.tname("c1")]]) .. "\n```markdown-fold\nAnd tests/.\n```")
        )
        assert.equal(
            child.lua_get("_G.G.MESSAGE.received"),
            child.lua_get([[_G.sign_of("c1", "Look in lib/ too.")]])
        )
        assert.equal(
            child.lua_get("_G.G.MESSAGE.sent"),
            child.lua_get([[_G.chat_sign_of("Look in lib/ too.")]])
        )
    end)

    it("a longer message folds its rest closed with a char count", function()
        child.lua([[
_G.spawn("c1")
_G.message("toolu_send", "root", "c1", "Next step.\none\ntwo")
]])
        child.flush()
        child.lua([[
vim.api.nvim_set_current_win(_G.s.widget:home_win())
_G.row = _G.s.message_writer:notice_row("toolu_send") + 1
]])

        -- Heading, path, concealed fence, then the folded body.
        assert.equal(-1, child.lua_get("vim.fn.foldclosed(_G.row + 2)"))
        assert.equal(
            child.lua_get("_G.row + 3"),
            child.lua_get("vim.fn.foldclosed(_G.row + 3)")
        )
        assert.equal(
            "    ··· 2 lines · 7 chars ···",
            child.lua_get("vim.fn.foldtextresult(_G.row + 3)")
        )
    end)

    it("a sibling's message shows in both transcripts", function()
        child.lua([[
_G.spawn("c1", "alpha")
_G.spawn("c2", "beta")
_G.message("toolu_s", "c1", "c2", "Your half.")
]])

        local c1_text = child.lua_get([[_G.ttext("c1")]])
        assert.truthy(c1_text:find("## Your half.\n" .. child.lua_get([[_G.tname("c2")]]), 1, true))
        local c2_text = child.lua_get([[_G.ttext("c2")]])
        assert.truthy(c2_text:find("## Your half.\n" .. child.lua_get([[_G.tname("c1")]]), 1, true))
        assert.equal(
            child.lua_get("_G.G.MESSAGE.sent"),
            child.lua_get([[_G.sign_of("c1", "Your half.")]])
        )
        assert.equal(
            child.lua_get("_G.G.MESSAGE.received"),
            child.lua_get([[_G.sign_of("c2", "Your half.")]])
        )
    end)

    it("a hand-back is a result in both buffers", function()
        child.lua([[
_G.spawn("c1")
_G.message("toolu_h", "c1", "root", "Report: done.")
]])

        local transcript = child.lua_get([[_G.ttext("c1")]])
        assert.equal(1, count(transcript, "## Report: done.\n" .. child.lua_get("_G.chat_name()")))
        assert.truthy(
            child
                .lua_get([[_G.text(_G.s.widget.buf_nrs.agent)]])
                :find("## Report: done.\n" .. child.lua_get([[_G.tname("c1")]]), 1, true)
        )
        assert.equal(
            child.lua_get("_G.G.MESSAGE.result"),
            child.lua_get([[_G.sign_of("c1", "Report: done.")]])
        )
        assert.equal(
            child.lua_get("_G.G.MESSAGE.result"),
            child.lua_get([[_G.chat_sign_of("Report: done.")]])
        )
        assert.equal("toolu_c1", child.lua_get([[_G.s.chat_history.subagents.c1.task_id]]))
    end)

    it("a delegation after an end is a task", function()
        child.lua([[
_G.spawn("c1")
_G.state("c1", _G.COMPLETED)
_G.state("c1", { state = "running" })
_G.message("toolu_again", "root", "c1", "Now the tests.")
_G.message("toolu_more", "root", "c1", "And docs.")
]])

        assert.equal(
            child.lua_get("_G.G.MESSAGE.task"),
            child.lua_get([[_G.sign_of("c1", "Now the tests.")]])
        )
        assert.equal(
            child.lua_get("_G.G.MESSAGE.received"),
            child.lua_get([[_G.sign_of("c1", "And docs.")]])
        )
    end)

    it("a launch reply, seen by the parent only, is a result in the chat", function()
        child.lua([[
_G.spawn("c1")
_G.update("root", {
    sessionUpdate = "session_message", messageId = "toolu_c1:reply",
    senderSessionId = "c1", recipientSessionId = "root",
    content = { { type = "text", text = "All found." } },
})
]])

        assert.truthy(
            child
                .lua_get([[_G.text(_G.s.widget.buf_nrs.agent)]])
                :find("## All found.\n" .. child.lua_get([[_G.tname("c1")]]), 1, true)
        )
        assert.is_nil(child.lua_get([[_G.ttext("c1")]]):find("All found.", 1, true))
        assert.same(
            { type = "session_message", message_id = "toolu_c1:reply", kind = "result",
              view = "received", sender_session_id = "c1", recipient_session_id = "root",
              text = "All found." },
            child.lua_get([[_G.s.chat_history.messages[#_G.s.chat_history.messages] ]])
        )
    end)

    it("CTRL-] jumps between a message's two rows, CTRL-T back", function()
        child.lua([[
_G.spawn("c1")
_G.message("toolu_send", "root", "c1", "Look in lib/ too.")
]])
        -- Let the follow scroll land before the cursor is placed.
        child.flush()
        child.lua([[
vim.api.nvim_set_current_win(_G.s.widget:home_win())
_G.chat_row = _G.s.message_writer:notice_row("toolu_send") + 1
vim.api.nvim_win_set_cursor(0, { _G.chat_row + 1, 0 })
]])
        child.type_keys("<C-]>")

        assert.equal(
            child.lua_get([[_G.transcript("c1").bufnr]]),
            child.api.nvim_get_current_buf()
        )
        assert.equal(
            child.lua_get([[_G.transcript("c1").writer:notice_row("toolu_send") + 1]]),
            child.lua_get("vim.fn.line('.')")
        )

        child.type_keys("<C-]>")
        assert.equal(child.lua_get("_G.s.widget.buf_nrs.agent"), child.api.nvim_get_current_buf())
        assert.equal(child.lua_get("_G.chat_row"), child.lua_get("vim.fn.line('.')"))

        child.type_keys("<C-t>")
        assert.equal(
            child.lua_get([[_G.transcript("c1").bufnr]]),
            child.api.nvim_get_current_buf()
        )
    end)

    for case, shift in pairs({
        ["lines go in above it"] = [[
local bufnr = _G.transcript("c1").bufnr
vim.bo[bufnr].modifiable = true
vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "x", "y", "z" })
]],
        ["its buffer re-renders"] = [[_G.s:_replay_transcript("c1")]],
    }) do
        it("CTRL-] lands on the other row after " .. case, function()
            child.lua([[
_G.spawn("c1")
_G.message("toolu_send", "root", "c1", "Look in lib/ too.")
]])
            child.lua(shift)
            child.flush()
            child.lua([[
vim.api.nvim_set_current_win(_G.s.widget:home_win())
vim.api.nvim_win_set_cursor(0, { _G.s.message_writer:notice_row("toolu_send") + 1, 0 })
]])
            child.type_keys("<C-]>")

            assert.equal(
                child.lua_get([[_G.transcript("c1").bufnr]]),
                child.api.nvim_get_current_buf()
            )
            local row = child.lua_get("vim.fn.line('.')")
            assert.same(
                { "## Look in lib/ too.", child.lua_get("_G.chat_name()") },
                child.api.nvim_buf_get_lines(0, row - 1, row + 1, false)
            )
        end)
    end

    it(":tag and :tnext visit both rows of a message", function()
        child.lua([[
_G.spawn("c1")
vim.api.nvim_set_current_win(_G.s.widget:home_win())
vim.cmd("tag toolu_c1")
_G.first = vim.api.nvim_get_current_buf()
vim.cmd("tnext")
_G.second = vim.api.nvim_get_current_buf()
]])

        local visited = { child.lua_get("_G.first"), child.lua_get("_G.second") }
        table.sort(visited)
        local expected = {
            child.lua_get("_G.s.widget.buf_nrs.agent"),
            child.lua_get([[_G.transcript("c1").bufnr]]),
        }
        table.sort(expected)
        assert.same(expected, visited)
    end)

    it("a row without a message id is no tag", function()
        child.lua([[
_G.spawn("c1")
_G.state("c1", _G.COMPLETED)
vim.cmd("tab sbuffer " .. _G.transcript("c1").bufnr)
for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line == "## completed" then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
    end
end
]])

        assert.is_true(child.lua_get([[_G.s:_tagfunc("completed", "c") == vim.NIL]]))
    end)

    it("an incoming view without a sender has no path", function()
        child.lua([[
_G.spawn("c1")
_G.update("c1", {
    sessionUpdate = "session_message",
    messageId = "c1:prompt:2",
    recipientSessionId = "c1",
    content = { { type = "text", text = "Hello." } },
})
]])

        local transcript = child.lua_get([[_G.ttext("c1")]])
        assert.truthy(transcript:find("## Hello.", 1, true))
        assert.is_nil(transcript:find("## Hello.\nagentic://", 1, true))
    end)

    it("a repeated message id on the same session writes no second row", function()
        child.lua([[
_G.spawn("c1")
_G.message("toolu_c1", "root", "c1", "Find the files.")
]])

        assert.equal(1, count(child.lua_get([[_G.ttext("c1")]]), "## Find the files."))
    end)

    it("a child's chunks and tool calls land in its transcript", function()
        child.lua([[
_G.spawn("c1")
_G.chunk("c1", "child finding", "toolu_c1")
_G.s:_on_tool_call({
    tool_call_id = "t1", kind = "read", status = "pending", argument = "a.txt",
    parent_tool_use_id = "toolu_c1",
}, "c1")
]])

        assert.truthy(child.lua_get([[_G.ttext("c1")]]):find("child finding", 1, true))
        assert.is_nil(
            child
                .lua_get([[_G.text(_G.s.widget.buf_nrs.agent)]])
                :find("child finding", 1, true)
        )
        assert.is_true(
            child.lua_get([[_G.transcript("c1").writer.tool_call_blocks.t1 ~= nil]])
        )
        assert.same(
            { "toolu_c1", "toolu_c1", "toolu_c1" },
            child.lua_get([[vim.tbl_map(function(m)
    return m.parent_tool_use_id
end, _G.s.chat_history.subagent_messages)]])
        )
    end)

    it("a row between two chunks leaves the child's turn open", function()
        child.lua([[
_G.spawn("c1")
_G.chunk("c1", "one", "toolu_c1")
_G.message("toolu_send", "root", "c1", "More.")
_G.chunk("c1", "two", "toolu_c1")
]])

        local transcript = child.lua_get([[_G.ttext("c1")]])
        local row = transcript:find("More.", 1, true)
        assert.truthy(row)
        assert.truthy(transcript:find("two", row, true))
        assert.same(
            { "session_message", "agent", "session_message", "agent" },
            child.lua_get("_G.types()")
        )
    end)

    it("a root-session update tagged with a known Task id lands in its agent", function()
        child.lua([[
_G.write_meta("c1", "background", "toolu_1")
_G.spawn("c1")
_G.chunk("root", "tagged finding", "toolu_1")
]])

        assert.truthy(child.lua_get([[_G.ttext("c1")]]):find("tagged finding", 1, true))
    end)

    it("a meta file found late updates the block", function()
        child.lua([[_G.spawn("c1")]])
        assert.is_true(child.lua_get([[_G.block("c1").subagent.agent_type == nil]]))

        child.lua([[
_G.write_meta("c1", "background", "toolu_c1")
_G.call("c1", "t1")
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
                .lua_get([[_G.text(_G.s.widget.buf_nrs.agent)]])
                :find("Background Explore · find it", 1, true)
        )
    end)

    for _, case in ipairs({
        { state = { state = "idle", stopReason = "end_turn" }, word = "completed" },
        { state = { state = "idle", stopReason = "cancelled" }, word = "cancelled" },
        { state = { state = "idle", stopReason = "error" }, word = "failed" },
        { state = { state = "idle", stopReason = "max_tokens" }, word = "max_tokens" },
        { state = { state = "idle" }, word = "ended" },
        { state = { state = "unknown" }, word = "unknown" },
    }) do
        it("an end as " .. case.word .. " writes one row and the header context", function()
            child.lua(
                [[
_G.spawn("c1")
_G.call("c1", "t1")
_G.state("c1", ...)
]],
                { case.state }
            )

            assert.is_false(child.lua_get([[_G.s._agents.c1.open]]))
            assert.is_false(
                child.lua_get([[_G.transcript("c1").status_indicator:is_active()]])
            )
            assert.equal(
                1,
                count(child.lua_get([[_G.ttext("c1")]]), "## " .. case.word .. "\n")
            )
            assert.equal(case.word, child.lua_get([[_G.context("c1")]]))
            local icon = child.lua_get(
                ([[require("agentic.config").status_icons[%q] or ""]]):format(case.word)
            )
            assert.equal(
                icon ~= "" and icon or child.lua_get("_G.G.RUN_ENDED"),
                child.lua_get(([[_G.sign_of("c1", %q)]]):format(case.word))
            )
            assert.equal(
                case.word == "completed" and "pending" or "cancelled",
                child.lua_get([[_G.transcript("c1").writer.tool_call_blocks.t1.status]])
            )
            assert.equal("completed", child.lua_get([[_G.block("c1").status]]))
        end)
    end

    it("a second failure report adds the error text", function()
        child.lua([[
_G.spawn("c1")
_G.state("c1", { state = "idle", stopReason = "error" })
_G.state("c1", {
    state = "idle", stopReason = "error",
    error = { code = -32603, message = "API overloaded" },
})
_G.state("c1", { state = "idle", stopReason = "error" })
]])

        local transcript = child.lua_get([[_G.ttext("c1")]])
        assert.equal(2, count(transcript, "## failed\n"))
        assert.truthy(transcript:find("## failed\nAPI overloaded", 1, true))
    end)

    it("idle then running reopens the same transcript", function()
        child.lua([[
_G.spawn("c1")
_G.bufnr = _G.transcript("c1").bufnr
_G.state("c1", _G.COMPLETED)
_G.state("c1", { state = "running" })
]])

        assert.is_true(child.lua_get([[_G.s._agents.c1.open]]))
        assert.is_true(child.lua_get([[_G.transcript("c1").bufnr == _G.bufnr]]))
        assert.is_true(
            child.lua_get([[_G.transcript("c1").status_indicator:is_active()]])
        )
        assert.is_true(child.lua_get([[_G.context("c1") == nil]]))
    end)

    it("running after a wipe reopens a remade transcript", function()
        child.lua([[
_G.spawn("c1")
_G.state("c1", _G.COMPLETED)
vim.cmd.bwipeout({ args = { tostring(_G.transcript("c1").bufnr) }, bang = true })
_G.state("c1", { state = "running" })
]])

        assert.is_true(child.lua_get([[_G.s._agents.c1.open]]))
        assert.is_true(
            child.lua_get([[_G.transcript("c1").status_indicator:is_active()]])
        )
        local transcript = child.lua_get([[_G.ttext("c1")]])
        assert.truthy(transcript:find("## Find the files.", 1, true))
        assert.truthy(transcript:find("## completed", 1, true))
    end)

    it("a resumed child keeps its launch id and its whole output", function()
        child.lua([[
_G.spawn("c1")
_G.chunk("c1", "before", "toolu_c1")
_G.state("c1", _G.COMPLETED)
_G.message("toolu_send", "root", "c1", "Again.")
_G.state("c1", { state = "running" })
_G.chunk("c1", "after", "toolu_send")
_G.s:_replay_transcript("c1")
]])

        assert.equal("toolu_c1", child.lua_get([[_G.s.chat_history.subagents.c1.task_id]]))
        local transcript = child.lua_get([[_G.ttext("c1")]])
        assert.truthy(transcript:find("before", 1, true))
        assert.truthy(transcript:find("after", 1, true))
        assert.truthy(transcript:find("Again.", 1, true))
    end)

    it("a turn's end closes nothing", function()
        child.lua([[
_G.s.agent.send_prompt = function(_, _, _, cb) _G.prompt_cb = cb end
_G.spawn("c1")
_G.s:_dispatch_turn({})
_G.prompt_cb({ stopReason = "end_turn" }, nil)
]])

        assert.is_true(child.lua_get([[_G.s._agents.c1.open]]))
    end)

    it("cancelling the main turn leaves a running child to its own end", function()
        child.lua([[
_G.s.agent.send_prompt = function(_, _, _, cb) _G.prompt_cb = cb end
_G.s.agent.stop_generation = function() end
_G.spawn("c1")
_G.call("c1", "t1")
_G.s:_dispatch_turn({})
_G.s:stop_generation()
_G.prompt_cb({ stopReason = "cancelled" }, nil)
]])

        assert.equal(
            "pending",
            child.lua_get([[_G.transcript("c1").writer.tool_call_blocks.t1.status]])
        )
        assert.is_true(
            child.lua_get([[_G.transcript("c1").status_indicator:is_active()]])
        )

        child.lua([[_G.state("c1", { state = "idle", stopReason = "cancelled" })]])

        assert.equal(
            "cancelled",
            child.lua_get([[_G.transcript("c1").writer.tool_call_blocks.t1.status]])
        )
    end)

    it("disconnect ends open agents as unknown and leaves ended ones", function()
        child.lua([[
_G.spawn("c1")
_G.spawn("c2")
_G.state("c2", _G.COMPLETED)
_G.c2_text = _G.ttext("c2")
_G.s:_build_handlers().on_disconnect()
]])

        assert.is_false(child.lua_get("_G.s._agents.c1.open"))
        assert.truthy(child.lua_get([[_G.ttext("c1")]]):find("## unknown", 1, true))
        assert.equal("unknown", child.lua_get([[_G.context("c1")]]))
        assert.equal(child.lua_get("_G.c2_text"), child.lua_get([[_G.ttext("c2")]]))
    end)

    it("an epoch advance closes quietly", function()
        child.lua([[
_G.spawn("c1")
_G.s:_advance_session_epoch()
]])

        assert.is_false(child.lua_get([[_G.s._agents.c1.open]]))
        assert.is_false(
            child.lua_get([[_G.transcript("c1").status_indicator:is_active()]])
        )
        assert.is_true(child.lua_get([[_G.context("c1") == nil]]))
    end)

    it("a child's config options stay out of the main agent's", function()
        child.lua([[
_G.spawn("c1")
_G.update("c1", {
    sessionUpdate = "config_option_update",
    configOptions = { {
        id = "model", name = "Model", category = "model", type = "select",
        currentValue = "child-model", options = {},
    } },
})
]])

        assert.is_true(
            child.lua_get([[_G.s.config_options:current_model_id() ~= "child-model"]])
        )
        assert.equal(
            "child-model",
            child.lua_get([[_G.s._agents.c1.config_options:current_model_id()]])
        )
    end)

    it("an unknown child's config options stay out of the main agent's", function()
        child.lua([[
_G.update("stranger", {
    sessionUpdate = "config_option_update",
    configOptions = { {
        id = "model", name = "Model", category = "model", type = "select",
        currentValue = "child-model", options = {},
    } },
})
]])

        assert.is_true(
            child.lua_get([[_G.s.config_options:current_model_id() ~= "child-model"]])
        )
    end)

    it("[[ and ]] move between a transcript's rows", function()
        child.lua([[
_G.spawn("c1")
_G.chunk("c1", "working", "toolu_c1")
_G.message("toolu_send", "root", "c1", "More.")
vim.cmd("tab sbuffer " .. _G.transcript("c1").bufnr)
]])
        -- Let the follow scroll land before the cursor is placed.
        child.flush()
        child.lua([[
vim.api.nvim_win_set_cursor(0, { 1, 0 })
_G.rows = {}
for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    if line == "## Find the files." or line == "## More." then
        table.insert(_G.rows, i)
    end
end
]])
        child.type_keys("]]")
        local first = child.lua_get("vim.fn.line('.')")
        child.type_keys("]]")
        local second = child.lua_get("vim.fn.line('.')")
        child.type_keys("[[")

        assert.same(child.lua_get("_G.rows"), { first, second })
        assert.equal(first, child.lua_get("vim.fn.line('.')"))
    end)

    it("a wiped transcript comes back with the agent's next output", function()
        child.lua([[
_G.spawn("c1")
_G.chunk("c1", "first", "toolu_c1")
_G.old = _G.transcript("c1").bufnr
vim.cmd.bwipeout({ args = { tostring(_G.old) }, bang = true })
_G.chunk("c1", " second", "toolu_c1")
]])

        local text = child.lua_get([[_G.ttext("c1")]])
        assert.truthy(text:find("first", 1, true))
        assert.truthy(text:find("second", 1, true))
        assert.is_false(child.lua_get([[_G.transcript("c1").bufnr == _G.old]]))
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
}, {
    type = "session_message", message_id = "toolu_1", kind = "launch", view = "sent",
    sender_session_id = "sid-x", recipient_session_id = "c1", text = "Find it.",
} }
_G.saved.subagents = { c1 = { task_id = "toolu_1" } }
_G.saved.subagent_messages = {
    { type = "session_message", message_id = "toolu_1", kind = "launch", view = "received",
      sender_session_id = "sid-x", recipient_session_id = "c1", text = "Find it.",
      parent_tool_use_id = "toolu_1" },
    { type = "session_message", message_id = "toolu_h", kind = "result", view = "sent",
      sender_session_id = "c1", recipient_session_id = "sid-x", text = "Report.",
      parent_tool_use_id = "toolu_1" },
    { type = "agent", text = "saved finding", provider_name = "p",
      parent_tool_use_id = "toolu_1" },
    { type = "subagent_end", state = "completed", parent_tool_use_id = "toolu_1" },
    { type = "agent", text = "legacy finding", provider_name = "p",
      parent_tool_use_id = "toolu_old" },
}
-- The folder that the load at "/tmp" saves to.
assert(_G.saved:save(vim.uv.fs_realpath("/tmp")) == nil)
]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    --- Run a session/load of `sid-x` whose replay announces `c1`, sends its
    --- prompt, output and reply, and ends it as bare `idle`, then complete it.
    --- @param before_complete string|nil Lua run before the load completes
    --- @param complete string|nil Lua that completes the load, by default a direct call of its callback
    local function load(before_complete, complete)
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.update = function(source, update)
    _G.s.agent.subscribers["sid-x"].on_session_update(update, source)
end
_G.announce("c1", "finder", "sid-x", { state = "running" })
_G.message("toolu_1", "sid-x", "c1", "Find it.")
_G.chunk("c1", "replayed chunk", "toolu_1")
_G.update("sid-x", {
    sessionUpdate = "session_message", messageId = "toolu_1:reply",
    senderSessionId = "c1", recipientSessionId = "sid-x",
    content = { { type = "text", text = "replayed reply" } },
})
_G.state("c1", { state = "idle" }, "sid-x")
]])
        if before_complete then
            child.lua(before_complete)
        end
        child.lua(complete or [[_G.load_cb({}, nil)]])
        child.flush()
    end

    it("a state sent right behind the load response comes after the load", function()
        load(
            nil,
            [[
local client = _G.s.agent
client.callbacks[99] = _G.load_cb
client:_handle_message({ jsonrpc = "2.0", id = 99, result = {} })
client:_handle_message({ jsonrpc = "2.0", method = "session/update", params = {
    sessionId = "sid-x",
    update = {
        sessionUpdate = "subagent_update", sessionId = "c1",
        state = { state = "running" },
    },
} })
]]
        )

        assert.is_true(child.lua_get("_G.s._agents.c1.open"))
    end)

    it("nothing is modified or written while the load runs", function()
        load([[
_G.mid_modified = vim.bo[_G.s.widget.buf_nrs.agent].modified
    or vim.bo[_G.transcript("c1").bufnr].modified
_G.s:_persist_history(_G.s.chat_history)
_G.mid_file = table.concat(vim.fn.readfile(
    require("agentic.ui.chat_history").get_file_path("sid-x", _G.s._cwd)
), "\n")
]])

        assert.is_false(child.lua_get("_G.mid_modified"))
        assert.truthy(child.lua_get("_G.mid_file"):find("saved finding", 1, true))
        assert.is_false(child.lua_get("_G.s.chat_history.dirty"))
    end)

    it("after a load the chat links the prompt, and gf loads the file's rows", function()
        load()

        local chat = child.lua_get([[_G.text(_G.s.widget.buf_nrs.agent)]])
        local name = child.lua_get([[_G.block("c1").argument]])
        assert.truthy(chat:find("## Find it.\n" .. name, 1, true))
        assert.truthy(chat:find("## replayed reply\n" .. name, 1, true))
        assert.same(
            { "tool_call", "session_message", "session_message" },
            child.lua_get([[vim.tbl_map(function(m)
    return m.type
end, _G.s.chat_history.messages)]])
        )
        child.lua([[
vim.api.nvim_set_current_win(_G.s.widget:home_win())
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
        assert.equal(1, count(text, "## Find it."))
        assert.equal(1, count(text, "## completed"))
        assert.is_nil(text:find("## ended", 1, true))
        assert.is_nil(text:find("replayed", 1, true))
        assert.is_nil(text:find("legacy finding", 1, true))
    end)

    it("a load whose replay sends the incoming view first writes one link", function()
        child.lua([[
_G.s:_do_load_acp_session("sid-x", "/tmp")
_G.update = function(source, update)
    _G.s.agent.subscribers["sid-x"].on_session_update(update, source)
end
_G.announce("c1", "finder", "sid-x", { state = "running" })
for _, view in ipairs({
    { session = "c1", link = "senderMessageId" },
    { session = "sid-x", link = "recipientMessageId" },
}) do
    _G.update(view.session, {
        sessionUpdate = "session_message", messageId = "toolu_send",
        senderSessionId = "sid-x", recipientSessionId = "c1",
        content = { { type = "text", text = "Also lib/." } },
        [view.link] = "toolu_send",
    })
end
_G.load_cb({}, nil)
]])
        child.flush()

        local chat = child.lua_get([[_G.text(_G.s.widget.buf_nrs.agent)]])
        assert.equal(1, count(chat, "## Also lib/."))
        child.lua([[vim.fn.bufload(_G.transcript("c1").bufnr)]])
        assert.is_nil(child.lua_get([[_G.ttext("c1")]]):find("Also lib/.", 1, true))
    end)

    it("a load takes the kinds and delegations from the file", function()
        load()

        -- Never replayed: only the file holds it.
        assert.equal("result", child.lua_get([[_G.s._message_kinds.toolu_h]]))
        assert.is_true(child.lua_get([[_G.s._delegated.c1]]))
        assert.is_true(child.lua_get([[_G.s._delegated["sid-x"] == nil]]))
    end)

    it("an end state sent again after the load writes nothing", function()
        load()
        child.lua([[_G.state("c1", { state = "idle" }, "sid-x")]])

        assert.is_false(child.lua_get("_G.s.chat_history.dirty"))
        assert.equal(5, child.lua_get("#_G.s.chat_history.subagent_messages"))
    end)

    it("running sent after the load reopens the child", function()
        load()
        child.lua([[_G.state("c1", { state = "running" }, "sid-x")]])

        assert.is_true(child.lua_get("_G.s._agents.c1.open"))
        assert.is_true(
            child.lua_get([[_G.transcript("c1").status_indicator:is_active()]])
        )
        assert.truthy(child.lua_get([[_G.ttext("c1")]]):find("saved finding", 1, true))
    end)

    it("output saved without an agent record gets its own transcript", function()
        load()

        child.lua([[vim.fn.bufload(_G.transcript("toolu_old").bufnr)]])

        assert.truthy(
            child.lua_get([[_G.ttext("toolu_old")]]):find("legacy finding", 1, true)
        )
    end)

    it("load then save keeps subagents", function()
        load()
        child.lua([[assert(_G.s.chat_history:save(_G.s._cwd) == nil)]])

        assert.same(
            { c1 = { task_id = "toolu_1" } },
            child.lua_get([[require("agentic.utils.file_system").read_json(
    require("agentic.ui.chat_history").get_file_path("sid-x", _G.s._cwd)
).subagents]])
        )
    end)

    it("a restore into another session manager links the new buffers", function()
        child.lua([[
vim.cmd("tabnew")
require("agentic").new_session({ auto_add_to_context = false })
_G.s2 = require("agentic.session_registry").current()
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
                .lua_get([[_G.text(_G.s2.widget.buf_nrs.agent)]])
                :find("## Find it.\n" .. name, 1, true)
        )
        child.lua([[vim.fn.bufload(_G.s2._agents.c1.transcript.bufnr)]])
        assert.truthy(
            child.lua_get([[_G.text(_G.s2._agents.c1.transcript.bufnr)]]):find(
                "## Report.\n"
                    .. child.lua_get([[vim.api.nvim_buf_get_name(_G.s2.widget.buf_nrs.agent)]]),
                1,
                true
            )
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
            child.lua_get([[vim.api.nvim_buf_is_loaded(_G.transcript("c1").bufnr)]])
        )
    end)

    it("an auto-approved request opens no tab", function()
        child.lua([[
_G.spawn("c1")
_G.s.permission_manager.add_request = function() return false end
_G.s:_on_request_permission({ sessionId = "c1", toolCall = { toolCallId = "t9" },
  options = { { optionId = "allow", name = "Allow", kind = "allow_once" } } }, function() end)
]])

        assert.equal(1, child.lua_get("#vim.api.nvim_list_tabpages()"))
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
_G.announce("c1")
_G.chunk("c1", "early", nil)
_G.write_meta("c1", "background", "toolu_1")
_G.call("c1", "t1")
_G.chunk("c1", " late", nil)
_G.s:_replay_transcript("c1")
]])

        assert.same(
            { "toolu_1", "toolu_1", "toolu_1" },
            child.lua_get([[vim.tbl_map(function(m)
    return m.parent_tool_use_id
end, _G.s.chat_history.subagent_messages)]])
        )
        local text = child.lua_get([[_G.ttext("c1")]])
        assert.truthy(text:find("early", 1, true))
        assert.truthy(text:find("late", 1, true))
    end)

    it("a stray buffer under a wiped transcript's name gives way", function()
        child.lua([[
_G.spawn("c1")
_G.name = vim.api.nvim_buf_get_name(_G.transcript("c1").bufnr)
vim.cmd.bwipeout({ args = { tostring(_G.transcript("c1").bufnr) }, bang = true })
vim.cmd.edit(vim.fn.fnameescape(_G.name))
_G.chunk("c1", "back", "toolu_c1")
]])

        assert.equal(
            child.lua_get("_G.name"),
            child.lua_get([[vim.api.nvim_buf_get_name(_G.transcript("c1").bufnr)]])
        )
        assert.truthy(child.lua_get([[_G.ttext("c1")]]):find("back", 1, true))
    end)

    it("two tabpages' sessions keep their transcripts apart", function()
        child.lua([[
_G.spawn("c1")
vim.cmd("$tab sbuffer " .. _G.transcript("c1").bufnr)
vim.cmd("tabnew")
require("agentic").new_session({ auto_add_to_context = false })
_G.s2 = require("agentic.session_registry").current()
]])
        child.flush()
        child.lua([[
_G.s2:_on_session_update({
    sessionUpdate = "subagent_update", sessionId = "c2",
    title = "other", state = { state = "running" },
}, "root2")
_G.s2:_reset_subagents()
]])

        assert.is_true(
            child.lua_get([[vim.api.nvim_buf_is_valid(_G.transcript("c1").bufnr)]])
        )
        assert.equal(
            1,
            child.lua_get([[#vim.fn.win_findbuf(_G.transcript("c1").bufnr)]])
        )
    end)
end)

describe("transcript windows", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua(SETUP)
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    for keys, check in pairs({
        gf = "in place",
        ["<C-w>f"] = "split",
        ["<C-w>gf"] = "tab",
    }) do
        it(keys .. " on a block's name opens the transcript (" .. check .. ")", function()
            child.lua([[_G.spawn("c1")]])
            -- Let the spawn's follow scroll land before the cursor is placed.
            child.flush()
            child.lua([[
vim.api.nvim_set_current_win(_G.s.widget:home_win())
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

    it("a finished transcript opened in a new tab shows its last line", function()
        child.lua([[
_G.spawn("c1")
local lines = {}
for i = 1, 200 do lines[i] = "finding " .. i end
_G.chunk("c1", table.concat(lines, "\n\n"), "toolu_c1")
_G.state("c1", _G.COMPLETED)
]])
        child.flush()
        child.lua([[vim.cmd("tab sbuffer " .. _G.transcript("c1").bufnr)]])
        child.flush()

        assert.is_true(child.lua_get([[
vim.fn.line("w$") == vim.api.nvim_buf_line_count(_G.transcript("c1").bufnr)
]]))
    end)
end)
