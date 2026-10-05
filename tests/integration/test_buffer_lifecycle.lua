local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Buffer lifecycle", function()
    local child = Child:new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        -- A test that quits the child leaves nothing to stop.
        pcall(child.stop)
    end)

    --- Whether the child still answers. `child.is_running()` stays true after
    --- the child exits by itself.
    --- @return boolean
    local function child_alive()
        return (pcall(child.lua_get, "1"))
    end

    --- Open a widget and give its session an id and a temporary session
    --- folder, as a session/new response would. Exposes it as `_G.s`.
    --- @param opts? { position?: string }
    local function open_session(opts)
        child.lua(
            [[require("agentic").toggle(...)]],
            { opts or vim.empty_dict() }
        )
        child.flush()
        child.lua([[
require("agentic.config").session_restore.storage_path = vim.fn.tempname()
local tab = vim.api.nvim_get_current_tabpage()
_G.s = require("agentic.session_registry").bound_session(tab)
_G.s.session_id = "sid-1"
_G.s.chat_history.session_id = "sid-1"
_G.chat = _G.s.widget.buf_nrs.chat
-- What ACP notifications reach.
_G.h = _G.s:_build_handlers()
_G.user_msg = function(text)
    return { type = "user", text = text, timestamp = 0, provider_name = "p" }
end
]])
    end

    --- Add a message the way a streaming update does, `mid_turn` or not.
    --- @param mid_turn boolean
    local function mutate(mid_turn)
        child.lua(
            [[
_G.s._prompt_pending = ... and 1 or 0
_G.s.chat_history:add_message(_G.user_msg("hello"))
_G.s:_history_changed(_G.s.chat_history)
]],
            { mid_turn }
        )
    end

    --- @return boolean
    local function chat_modified()
        return child.lua_get("vim.bo[_G.chat].modified")
    end

    --- @return boolean
    local function session_file_exists()
        return child.lua_get([[
vim.uv.fs_stat(require("agentic.ui.chat_history").get_file_path("sid-1")) ~= nil
]])
    end

    --- @return integer
    local function live_sessions()
        return child.lua_get(
            [[vim.tbl_count(require("agentic.session_registry").by_id)]]
        )
    end

    describe("chat modified", function()
        it("is set by a mid-turn mutation", function()
            open_session()
            mutate(true)
            assert.is_true(chat_modified())
        end)

        it("is unchanged by a render-only write", function()
            open_session()
            child.lua([[
_G.s.message_writer:write_message(
    require("agentic.acp.acp_payloads").generate_agent_message("rendered")
)
]])
            assert.is_false(chat_modified())
        end)

        it(
            "is cleared by :w when idle, which writes the session file",
            function()
                open_session()
                child.lua([[
_G.s.chat_history:add_message(_G.user_msg("hello"))
_G.s:_sync_modified(_G.s.chat_history)
vim.api.nvim_set_current_win(_G.s.widget.win_nrs.chat)
]])
                assert.is_true(chat_modified())

                child.cmd("write")

                assert.is_false(chat_modified())
                assert.is_true(session_file_exists())
            end
        )

        it("stays set after :w while a turn runs", function()
            open_session()
            mutate(true)
            child.lua(
                [[vim.api.nvim_set_current_win(_G.s.widget.win_nrs.chat)]]
            )

            child.cmd("write")

            assert.is_true(chat_modified())
            assert.is_true(session_file_exists())
        end)

        it("is cleared by an idle mutation, which persists at once", function()
            open_session()
            mutate(false)
            assert.is_false(chat_modified())
            assert.is_true(session_file_exists())
        end)

        it("is clean after a restore", function()
            open_session()
            child.lua([[
_G.s.chat_history:add_message(_G.user_msg("unsaved"))
_G.s:_sync_modified(_G.s.chat_history)
]])
            assert.is_true(chat_modified())
            child.lua([[
local history = require("agentic.ui.chat_history"):new()
history.messages = { _G.user_msg("restored") }
_G.s:restore_from_history(history, { reuse_session = true })
]])
            assert.is_false(chat_modified())
        end)
    end)

    describe("quitting", function()
        it(":qa refuses mid-turn", function()
            open_session()
            mutate(true)

            local result = child.lua_get([[{ pcall(vim.cmd, "qa") }]])

            assert.is_false(result[1])
            assert.truthy(tostring(result[2]):find("E37"))
            assert.is_true(child_alive())
        end)

        it(":wqa mid-turn writes the history and refuses to quit", function()
            open_session()
            mutate(true)

            pcall(child.cmd, "wqa")
            vim.uv.sleep(100)

            assert.is_true(child_alive())
            assert.is_true(session_file_exists())
            assert.is_true(chat_modified())
        end)

        it(":wqa when idle quits", function()
            open_session()
            mutate(false)

            pcall(child.cmd, "wqa")
            vim.uv.sleep(100)

            assert.is_false(child_alive())
        end)

        --- Make the session take a submitted prompt and start its turn.
        local function accept_prompts()
            child.lua([[
_G.sent = {}
_G.s.widget.on_submit_input = function(text)
    table.insert(_G.sent, text)
    _G.s:_set_prompt_pending(1)
    return true
end
]])
        end

        for _, cmd in ipairs({ "wq", "x" }) do
            it(":" .. cmd .. " in the input submits and closes it", function()
                open_session()
                accept_prompts()
                child.lua([[
local input = _G.s.widget.buf_nrs.input
vim.api.nvim_buf_set_lines(input, 0, -1, false, { "hello" })
vim.api.nvim_set_current_win(_G.s.widget.win_nrs.input)
vim.cmd("stopinsert")
]])

                child.cmd(cmd)

                assert.equal(
                    0,
                    child.lua_get("#vim.fn.win_findbuf(_G.s.widget.buf_nrs.input)")
                )
                assert.is_true(child.lua_get("#vim.fn.win_findbuf(_G.chat) > 0"))
                assert.same({ "hello" }, child.lua_get("_G.sent"))
            end)
        end

        it("the close keymap in the last window refuses while dirty", function()
            open_session({ position = "tab" })
            mutate(true)

            child.lua([[require("agentic").close()]])

            assert.is_true(child_alive())
            assert.is_true(child.lua_get("_G.s.widget:is_open()"))
        end)

        it("the close keymap in the last window quits when clean", function()
            open_session({ position = "tab" })
            mutate(false)

            pcall(child.lua, [[require("agentic").close()]])
            vim.uv.sleep(100)

            assert.is_false(child_alive())
        end)
    end)

    describe("windows", function()
        for _, panel in ipairs({ "chat", "input" }) do
            it(":q on the " .. panel .. " window keeps the session", function()
                open_session()
                mutate(false)
                child.lua(
                    [[vim.api.nvim_set_current_win(_G.s.widget.win_nrs[...])]],
                    { panel }
                )

                child.cmd("quit")
                child.flush()

                assert.equal(1, live_sessions())
            end)
        end

        it("an empty session ends when its last window closes", function()
            open_session()

            child.lua([[_G.s.widget:close_windows()]])
            child.flush()

            assert.equal(0, live_sessions())
        end)

        it(
            "a session with an unsent draft survives losing its windows",
            function()
                open_session()
                child.lua([[
local input = _G.s.widget.buf_nrs.input
vim.api.nvim_buf_set_lines(input, 0, -1, false, { "draft" })
require("agentic.utils.buf_helpers").sync_modified(input)
_G.s.widget:close_windows()
]])
                child.flush()

                assert.equal(1, live_sessions())
            end
        )

        it(
            "the close keymap closes what is left after :q on the chat",
            function()
                open_session()
                mutate(false)
                child.lua(
                    [[vim.api.nvim_set_current_win(_G.s.widget.win_nrs.chat)]]
                )
                child.cmd("quit")

                child.lua([[require("agentic").close()]])

                assert.is_false(child.lua_get("_G.s.widget:has_windows()"))
            end
        )

        it(
            "a new session replaces one that fills its tab, in that tab",
            function()
                child.cmd("tabnew")
                open_session({ position = "tab" })
                local tab = child.api.nvim_get_current_tabpage()

                child.lua([[require("agentic").new_session()]])
                child.flush()
                vim.uv.sleep(50)
                child.flush()

                assert.is_true(child.api.nvim_tabpage_is_valid(tab))
                assert.is_true(
                    child.lua_get(
                        [[require("agentic.session_registry").bound_session(...).widget:is_open()]],
                        { tab }
                    )
                )
            end
        )
    end)

    describe("names and flags", function()
        it("a title equal to a panel name renames the chat", function()
            open_session()

            local result = child.lua_get(
                [[{ pcall(_G.s.widget.set_chat_title, _G.s.widget, "input") }]]
            )

            assert.is_true(result[1])
        end)

        it("a drained queue leaves an empty input unmodified", function()
            open_session()
            child.lua([[
local widget = _G.s.widget
vim.api.nvim_buf_set_lines(widget.buf_nrs.input, 0, -1, false, { "queued" })
widget:_queue_line_range(0, 0)
vim.api.nvim_set_current_win(widget.win_nrs.chat)
widget:consume_queued_block()
]])

            assert.is_false(
                child.lua_get("vim.bo[_G.s.widget.buf_nrs.input].modified")
            )
        end)
    end)

    describe(":bd on the chat", function()
        it("ends an idle session and wipes its buffers", function()
            open_session()
            mutate(false)
            local bufs = child.lua_get("vim.tbl_values(_G.s.widget.buf_nrs)")

            child.cmd("bdelete " .. child.lua_get("_G.chat"))
            child.flush()

            assert.equal(0, live_sessions())
            for _, bufnr in ipairs(bufs) do
                assert.is_false(child.api.nvim_buf_is_valid(bufnr))
            end
        end)

        it("refuses mid-turn", function()
            open_session()
            mutate(true)

            local result =
                child.lua_get([[{ pcall(vim.cmd, "bdelete " .. _G.chat) }]])

            assert.is_false(result[1])
            assert.truthy(tostring(result[2]):find("E89"))
            assert.equal(1, live_sessions())
        end)

        it("with ! ends a dirty session once, without E937", function()
            open_session()
            mutate(true)
            child.lua([[
_G.destroys = 0
local destroy = _G.s.destroy
_G.s.destroy = function(self)
    _G.destroys = _G.destroys + 1
    destroy(self)
end
]])

            child.cmd("bdelete! " .. child.lua_get("_G.chat"))
            child.flush()

            assert.equal(1, child.lua_get("_G.destroys"))
            assert.equal(0, live_sessions())
            assert.is_false(child.lua_get("vim.api.nvim_buf_is_valid(_G.chat)"))
        end)
    end)

    describe(":e!", function()
        it("re-renders the chat with live trackers and highlighting", function()
            open_session()
            child.lua([[
_G.s.chat_history.messages = {
    _G.user_msg("first prompt"),
    {
        type = "tool_call",
        tool_call_id = "tc-1",
        kind = "read",
        argument = "/tmp/file.lua",
        status = "pending",
    },
}
_G.s.chat_history.dirty = true
vim.api.nvim_set_current_win(_G.s.widget.win_nrs.chat)
]])

            child.cmd("edit!")
            child.lua([[
_G.s.message_writer:write_message_chunk({
    sessionUpdate = "agent_message_chunk",
    content = { type = "text", text = "later chunk" },
})
]])

            local text = table.concat(
                child.lua_get(
                    "vim.api.nvim_buf_get_lines(_G.chat, 0, -1, false)"
                ),
                "\n"
            )
            assert.truthy(text:find("first prompt", 1, true))
            assert.truthy(text:find("later chunk", 1, true))
            assert.is_true(
                child.lua_get(
                    [[_G.s.message_writer.tool_call_blocks["tc-1"] ~= nil]]
                )
            )
            assert.is_true(
                child.lua_get(
                    "vim.treesitter.highlighter.active[_G.chat] ~= nil"
                )
            )
            assert.is_true(chat_modified())
        end)

        it("empties the input and re-attaches completion", function()
            open_session()
            child.lua([[
local input = _G.s.widget.buf_nrs.input
vim.api.nvim_buf_set_lines(input, 0, -1, false, { "draft" })
vim.api.nvim_set_current_win(_G.s.widget.win_nrs.input)
]])

            child.cmd("edit!")
            child.flush()

            assert.same(
                { "" },
                child.lua_get(
                    "vim.api.nvim_buf_get_lines(_G.s.widget.buf_nrs.input, 0, -1, false)"
                )
            )
            assert.equal(
                1,
                child.lua_get([[#vim.lsp.get_clients({
    bufnr = _G.s.widget.buf_nrs.input,
    name = "agentic_input",
})]])
            )
        end)
    end)

    describe("subagent transcript", function()
        --- Spawn subagent `id` in `_G.s`, its transcript `_G.sub`.
        --- @param id string
        local function open_task(id)
            child.lua(
                [[
local id = ...
_G.h.on_session_update({
    sessionUpdate = "subagent_spawned",
    subagentSessionId = id,
    name = "map",
    task = "Map it.",
}, "sid-1")
_G.sub = _G.s._agents[id].transcript.bufnr
]],
                { id }
            )
        end

        --- Start tool call `id` in subagent `parent`'s child session.
        --- @param id string
        --- @param parent string
        local function subagent_call(id, parent)
            child.lua(
                [[
local id, parent = ...
_G.h.on_tool_call({
    tool_call_id = id,
    parent_tool_use_id = "toolu-" .. parent,
    kind = "execute",
    status = "pending",
    argument = "ls " .. id,
    body = { "a", "b" },
}, parent)
]],
                { id, parent }
            )
        end

        --- Stream prose in subagent `parent`'s child session.
        --- @param text string
        --- @param parent string
        local function subagent_chunk(text, parent)
            child.lua(
                [[
local text, parent = ...
_G.h.on_session_update({
    sessionUpdate = "agent_message_chunk",
    content = { type = "text", text = text },
    _meta = { claudeCode = { parentToolUseId = "toolu-" .. parent } },
}, parent)
]],
                { text, parent }
            )
        end

        --- @param id string
        local function complete(id)
            child.lua(
                [[_G.h.on_tool_call_update({ tool_call_id = ..., status = "completed" })]],
                { id }
            )
        end

        --- Record every `Logger.notify` message in `_G.notes`.
        local function capture_notify()
            child.lua([[
_G.notes = {}
require("agentic.utils.logger").notify = function(msg)
    table.insert(_G.notes, msg)
end
]])
        end

        --- Run `cmd` in a window showing the subagent buffer, or with the
        --- buffer current when no window shows it.
        --- @param cmd string
        --- @param bufnr_expr string|nil Lua expression for the buffer; `_G.sub` when nil
        --- @return { [1]: boolean, [2]: string|nil } result pcall's results
        local function in_subagent(cmd, bufnr_expr)
            return child.lua_get(
                ([[(function(cmd)
    local buf = %s
    local win = vim.fn.win_findbuf(buf)[1]
    local run = function() vim.cmd(cmd) end
    if win then
        return { pcall(vim.api.nvim_win_call, win, run) }
    end
    return { pcall(vim.api.nvim_buf_call, buf, run) }
end)(...)]]):format(bufnr_expr or "_G.sub"),
                { cmd }
            )
        end

        --- @return string[]
        local function sub_lines()
            return child.lua_get(
                "vim.api.nvim_buf_get_lines(_G.sub, 0, -1, false)"
            )
        end

        --- @return boolean
        local function sub_modified()
            return child.lua_get("vim.bo[_G.sub].modified")
        end

        --- @param text string
        --- @return boolean
        local function sub_text_has(text)
            return table.concat(sub_lines(), "\n"):find(text, 1, true) ~= nil
        end

        --- @return string
        local function session_file()
            return child.lua_get([[table.concat(vim.fn.readfile(
    require("agentic.ui.chat_history").get_file_path("sid-1")
), "\n")]])
        end

        it("refuses :e and :bd mid-turn", function()
            open_session()
            child.lua([[_G.s:_set_prompt_pending(1)]])
            open_task("task-1")
            subagent_call("c-1", "task-1")
            local lines = sub_lines()

            local edit = in_subagent("edit")
            local delete = in_subagent("bdelete")

            assert.is_false(edit[1])
            assert.truthy(tostring(edit[2]):find("E37"))
            assert.is_false(delete[1])
            assert.truthy(tostring(delete[2]):find("E89"))
            assert.same(lines, sub_lines())
        end)

        it(":e! mid-turn re-renders the same content", function()
            open_session()
            child.lua([[_G.s:_set_prompt_pending(1)]])
            open_task("task-1")
            subagent_call("c-1", "task-1")
            local lines = sub_lines()
            assert.is_true(sub_text_has("ls c-1"))
            assert.is_true(sub_text_has("map ("))
            capture_notify()

            in_subagent("edit!")

            assert.same(lines, sub_lines())
            assert.is_true(sub_modified())

            complete("c-1")
            assert.same({}, child.lua_get("_G.notes"))
            assert.is_true(sub_text_has("completed"))
        end)

        it(":bd! mid-turn reloads the buffer on a later update", function()
            open_session()
            child.lua([[_G.s:_set_prompt_pending(1)]])
            open_task("task-1")
            subagent_call("c-1", "task-1")
            capture_notify()

            in_subagent("bdelete!")
            assert.is_false(child.lua_get("vim.api.nvim_buf_is_loaded(_G.sub)"))
            complete("c-1")

            assert.is_true(child.lua_get("vim.api.nvim_buf_is_loaded(_G.sub)"))
            assert.is_true(sub_text_has("ls c-1"))
            assert.is_true(sub_text_has("completed"))
            assert.is_false(child.lua_get("vim.bo[_G.sub].buflisted"))
            assert.same({}, child.lua_get("_G.notes"))
            assert.equal("acwrite", child.lua_get("vim.bo[_G.sub].buftype"))
            assert.equal(
                child.lua_get("_G.s.id"),
                child.lua_get("vim.b[_G.sub].agentic_session_id")
            )
            assert.is_true(child.lua_get([[(function()
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(_G.sub, "n")) do
        if map.desc == "Agentic: Stop subagent or generation" then
            return true
        end
    end
    return false
end)()]]))
        end)

        it(
            "outside a turn, writes on a call's completion, not per chunk",
            function()
                open_session()
                open_task("task-1")

                subagent_chunk("first finding", "task-1")
                assert.is_true(sub_modified())
                assert.is_nil(session_file():find("first finding", 1, true))

                subagent_call("c-1", "task-1")
                complete("c-1")
                assert.is_false(sub_modified())
                assert.truthy(session_file():find("first finding", 1, true))
                assert.truthy(session_file():find("ls c-1", 1, true))
            end
        )

        it(":w writes the session file and clears modified", function()
            open_session()
            open_task("task-1")
            subagent_chunk("first finding", "task-1")
            assert.is_true(sub_modified())

            in_subagent("write")

            assert.is_false(sub_modified())
            assert.truthy(session_file():find("first finding", 1, true))
        end)

        it("heads a running agent once across :e!", function()
            open_session()
            open_task("task-1")
            subagent_chunk("first", "task-1")

            in_subagent("edit!")
            subagent_chunk("\n\nsecond", "task-1")

            local headings = vim.tbl_filter(function(line)
                return vim.startswith(line, "## ")
            end, sub_lines())
            assert.equal(1, #headings)
            assert.truthy(headings[1]:find("## map (", 1, true))
            assert.equal(1, select(2, table.concat(sub_lines(), "\n"):gsub("first", "")))
        end)

        it("records a subagent edit that completes after :e!", function()
            open_session()
            open_task("task-1")
            child.lua([[
_G.s:_on_tool_call({
    tool_call_id = "e-1",
    parent_tool_use_id = "toolu-task-1",
    kind = "edit",
    status = "pending",
    argument = vim.fn.tempname(),
    diff = { old = { "a" }, new = { "b" } },
}, "task-1")
]])
            in_subagent("edit!")

            -- Read in the same call: the scheduled checktime clears the flag.
            local checktime_scheduled = child.lua([[
_G.s:_on_tool_call_update({ tool_call_id = "e-1", status = "completed" })
return _G.s._checktime_scheduled
]])

            assert.is_true(checktime_scheduled)
            assert.equal(1, child.lua_get("_G.s.file_activity:count()"))
        end)

        it(":e! leaves another tabpage's transcript alone", function()
            open_session()
            open_task("task-1")
            subagent_call("c-1", "task-1")
            child.lua([[_G.first, _G.first_sub = _G.s, _G.sub]])
            child.cmd("tabnew")
            open_session()
            open_task("task-1")
            subagent_call("c-2", "task-1")
            local lines = sub_lines()
            child.lua([=[
_G.writer_of = function(s) return s._agents["task-1"].transcript.writer end
_G.second_tracker = _G.writer_of(_G.s).tool_call_blocks["c-2"]
]=])

            in_subagent("edit!", "_G.first_sub")

            assert.same(lines, sub_lines())
            assert.is_true(
                child.lua_get(
                    [[_G.writer_of(_G.s).tool_call_blocks["c-2"] == _G.second_tracker]]
                )
            )
            assert.is_true(
                child.lua_get(
                    [[_G.writer_of(_G.first).tool_call_blocks["c-1"] ~= nil]]
                )
            )
        end)
    end)
end)
