local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("forking a conversation", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
require("agentic.config").sessions.storage_path = vim.fn.tempname()
vim.cmd("Agentic")
local Registry = require("agentic.session_registry")
_G.s = Registry.current()
_G.agent = _G.s.agent
_G.agent.agent_capabilities =
    { loadSession = true, sessionCapabilities = { fork = {} } }
_G.agent.state = "ready"
_G.sent = {}
_G.cbs = {}
_G.agent._send_request = function(_, method, params, cb)
    table.insert(_G.sent, { method = method, params = params })
    _G.cbs[method] = cb
end
_G.notes = {}
require("agentic.utils.logger").notify = function(message, level)
    table.insert(_G.notes, { message = message, level = level })
end
_G.methods = function()
    return vim.tbl_map(function(r) return r.method end, _G.sent)
end
_G.msg = function(type, text, extra)
    return vim.tbl_extend(
        "force",
        { type = type, text = text, timestamp = 0, provider_name = "p" },
        extra or {}
    )
end
_G.lines = function(session)
    return vim.api.nvim_buf_get_lines(session.widget.buf_nrs.agent, 0, -1, false)
end
_G.row_of = function(session, text)
    for i, line in ipairs(_G.lines(session)) do
        if line == text then
            return i
        end
    end
end
_G.input = function(session)
    return vim.api.nvim_buf_get_lines(session.widget.buf_nrs.input, 0, -1, false)
end

_G.s.session_id = "sid-src"
local h = _G.s.chat_history
h.chat_id = "sid-src"
h.session_id = "sid-src"
_G.s:_name_buffers()
--- The fork's chat id.
_G.fid = function()
    return _G.f.chat_history.chat_id
end
h:set_title("Src")
_G.q1 = _G.msg("user", "first question", { model = "m-old" })
_G.q2 = _G.msg("user", "second question", { model = "m-new" })
h:add_message(_G.q1)
h:add_message(_G.msg("agent", "first answer", { response_id = "r1" }))
h:add_message(_G.q2)
h:add_message(_G.msg("agent", "second answer", { response_id = "r2" }))
_G.s.message_writer:write_notice({ glyph = "x", title = "top" })
_G.s:_render_history()

--- Fork `_G.s` with the cursor on the chat row holding `text`; the new
--- session is `_G.f`.
_G.fork_at = function(text, mods)
    local win = vim.fn.bufwinid(_G.s.widget.buf_nrs.agent)
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { _G.row_of(_G.s, text), 0 })
    local before = Registry.last_active_id
    _G.s:fork_at_cursor(mods)
    if Registry.last_active_id ~= before then
        _G.f = Registry.by_id[Registry.last_active_id]
    end
end
]])
    end)

    after_each(function()
        child.stop()
    end)

    --- Assert that the child's Lua expression `expr` is nil.
    --- @param expr string
    local function absent(expr)
        assert.is_true(child.lua_get("(" .. expr .. ") == nil"))
    end

    --- Fork at the second answer and let the provider cut it.
    local function fork_natively()
        child.lua([[_G.fork_at("second answer")]])
        child.flush()
        child.lua([[_G.cbs["session/fork"]({ sessionId = "sid-fork" }, nil)]])
        child.flush()
        child.lua([[_G.fork_cid = _G.fid()]])
    end

    --- The fork's session holds the first turn, renders from its link and
    --- has the second prompt as its draft, and the source links to it above
    --- that prompt.
    local function assert_forked()
        assert.equal("sid-fork", child.lua_get("_G.f.session_id"))
        assert.truthy(child.lua_get("_G.f:chat_id()"):match("^%x+$"))
        assert.same(
            { "user", "agent", "fork_link" },
            child.lua_get([[vim.tbl_map(function(m) return m.type end,
                _G.f.chat_history.messages)]])
        )
        assert.equal("Src (fork)", child.lua_get("_G.f.chat_history.title"))
        absent([[_G.row_of(_G.f, "## first question")]])
        assert.equal(1, child.lua_get([[_G.row_of(_G.f, "## Src")]]))
        assert.equal(
            2,
            child.lua_get([[_G.row_of(_G.f, "Forked from agentic://sid-src")]])
        )
        assert.same({ "second question" }, child.lua_get("_G.input(_G.f)"))
        assert.equal(
            1,
            child.lua_get(
                [[#require("agentic.ui.chat_history").find_files(_G.fid())]]
            )
        )

        local link = child.lua_get("_G.s.chat_history.messages[3]")
        assert.equal("fork_link", link.type)
        assert.equal("to", link.direction)
        assert.equal(child.lua_get("_G.fid()"), link.chat_id)
        assert.equal("Src (fork)", link.title)
        local link_row = child.lua_get([[_G.row_of(_G.s, "## Src (fork)")]])
        assert.equal(
            "Forked to agentic://" .. link.chat_id,
            child.lua_get("_G.lines(_G.s)")[link_row + 1]
        )
        assert.equal(
            link_row + 3,
            child.lua_get([[_G.row_of(_G.s, "## second question")]])
        )
    end

    it("lets the provider cut the conversation before the turn", function()
        fork_natively()

        assert.equal("session/fork", child.lua_get("_G.sent[1].method"))
        local fork = child.lua_get("_G.sent[1].params")
        assert.equal("sid-src", fork.sessionId)
        assert.same(
            { version = 1, messageId = "r1" },
            fork._meta.jetbrains.air.fork
        )
        assert.is_false(
            child.lua_get([[vim.tbl_contains(_G.methods(), "session/new")]])
        )
        assert_forked()
        -- The provider holds the conversation: nothing is sent as text.
        absent("_G.f._history_to_send")
        assert.equal(
            "m-new",
            child.lua_get("_G.f.config_options._pending_initial_model")
        )
    end)

    it("sends the history as text without a native fork", function()
        child.lua([[_G.agent.agent_capabilities = { loadSession = true }]])
        child.lua([[_G.fork_at("second answer")]])
        child.flush()
        child.lua([[_G.cbs["session/new"]({ sessionId = "sid-fork" }, nil)]])
        child.flush()

        assert.same({ "session/new" }, child.lua_get("_G.methods()"))
        assert_forked()
        assert.equal(3, child.lua_get("#_G.f._history_to_send.messages"))
        absent("_G.f.chat_history.messages[2].response_id")
    end)

    it("falls back quietly when the response was never recorded", function()
        child.lua([[_G.fork_at("second answer")]])
        child.flush()
        child.lua([[
_G.cbs["session/fork"](nil, { code = -32602, message = "not found" })
]])
        child.flush()
        child.lua([[_G.cbs["session/new"]({ sessionId = "sid-fork" }, nil)]])
        child.flush()

        assert.equal(0, child.lua_get("#_G.notes"))
        assert_forked()
    end)

    it("warns on another fork error, then falls back", function()
        child.lua([[_G.fork_at("second answer")]])
        child.flush()
        child.lua([[
_G.cbs["session/fork"](nil, { code = -32603, message = "boom" })
]])
        child.flush()
        child.lua([[_G.cbs["session/new"]({ sessionId = "sid-fork" }, nil)]])
        child.flush()

        assert.equal(1, child.lua_get("#_G.notes"))
        assert.equal(
            child.lua_get("vim.log.levels.WARN"),
            child.lua_get("_G.notes[1].level")
        )
        assert_forked()
    end)

    it("keeps the source's mode", function()
        child.lua([[
_G.s.config_options.legacy_agent_modes.current_mode_id = "plan"
_G.fork_at("second answer")
_G.f.config_options.set_initial_mode = function(_, mode)
    _G.mode = mode
end
]])
        child.flush()
        child.lua([[_G.cbs["session/fork"]({ sessionId = "sid-fork" }, nil)]])

        assert.equal("plan", child.lua_get("_G.mode"))
    end)

    it("forks before the last prompt from the end of the chat", function()
        child.lua([[_G.fork_at("second answer")]])
        child.flush()

        assert.equal(
            "r1",
            child.lua_get(
                [[_G.sent[1].params._meta.jetbrains.air.fork.messageId]]
            )
        )
    end)

    it("starts a plain new session above the first prompt", function()
        child.lua([[_G.fork_at("## top")]])
        child.flush()
        child.lua([[_G.cbs["session/new"]({ sessionId = "sid-fork" }, nil)]])
        child.flush()

        assert.same({ "session/new" }, child.lua_get("_G.methods()"))
        assert.equal("sid-fork", child.lua_get("_G.f.session_id"))
        assert.equal(0, child.lua_get("#_G.f.chat_history.messages"))
        assert.same({ "" }, child.lua_get("_G.input(_G.f)"))
        assert.equal(4, child.lua_get("#_G.s.chat_history.messages"))
    end)

    it("forks while a turn runs", function()
        child.lua([[_G.s._foreground = "running"]])
        fork_natively()

        assert_forked()
    end)

    it("keeps a running turn's output below its forked prompt", function()
        child.lua([[
_G.s:_handle_input_submit("third question")
_G.s:_on_prompt_taken()
_G.s:_on_turn_state({ state = "running" })
_G.update = _G.s:_build_handlers().on_session_update
_G.update({
    sessionUpdate = "agent_message_chunk",
    content = { type = "text", text = "early part" },
})
]])
        child.flush()
        child.lua([[_G.fork_at("early part")]])
        child.flush()
        child.lua([[
_G.cbs["session/fork"]({ sessionId = "sid-fork" }, nil)
]])
        child.flush()
        child.lua([[
_G.update({
    sessionUpdate = "agent_message_chunk",
    content = { type = "text", text = " late part" },
})
]])
        child.flush()

        local link = child.lua_get([[_G.row_of(_G.s, "## Src (fork)")]])
        local prompt = child.lua_get([[_G.row_of(_G.s, "## third question")]])
        local answer =
            child.lua_get([[_G.row_of(_G.s, "early part late part")]])
        assert.is_true(link < prompt)
        assert.is_true(prompt < answer)
    end)

    it("refuses while the agent is not ready", function()
        child.lua([[
_G.agent.state = "disconnected"
_G.fork_at("second answer")
]])
        child.flush()

        absent("_G.f")
        assert.equal(0, child.lua_get("#_G.sent"))
        assert.equal(
            child.lua_get("vim.log.levels.WARN"),
            child.lua_get("_G.notes[1].level")
        )
    end)

    it("takes the turn above a prompt the history no longer holds", function()
        child.lua([[
_G.s.chat_history:truncate_from(_G.q2)
_G.fork_at("second answer")
]])
        child.flush()

        -- Before the first prompt: nothing to copy.
        assert.same({ "session/new" }, child.lua_get("_G.methods()"))
        assert.same({ "first question" }, child.lua_get("_G.input(_G.f)"))
    end)

    it("drops the fork's id when its session is destroyed meanwhile", function()
        child.lua([[_G.fork_at("second answer")]])
        child.flush()
        child.lua([[
require("agentic.session_registry").destroy(_G.f)
_G.cbs["session/fork"]({ sessionId = "sid-fork" }, nil)
]])
        child.flush()

        assert.is_true(
            child.lua_get([[_G.agent.subscribers["sid-fork"] == nil]])
        )
        assert.equal(4, child.lua_get("#_G.s.chat_history.messages"))
    end)

    it("links nothing into a source that moved to another chat", function()
        child.lua([[_G.fork_at("second answer")]])
        child.flush()
        child.lua([[
_G.s.session_id = "sid-other"
_G.s.chat_history.chat_id = "sid-other"
_G.cbs["session/fork"]({ sessionId = "sid-fork" }, nil)
]])
        child.flush()

        assert.equal(
            "sid-src",
            child.lua_get("_G.f.chat_history.messages[3].chat_id")
        )
        assert.equal(4, child.lua_get("#_G.s.chat_history.messages"))
    end)

    it("links into a source whose chat moved to a new session", function()
        child.lua([[_G.fork_at("second answer")]])
        child.flush()
        child.lua([[
_G.s.session_id = "sid-switched"
_G.cbs["session/fork"]({ sessionId = "sid-fork" }, nil)
]])
        child.flush()

        assert.equal(5, child.lua_get("#_G.s.chat_history.messages"))
    end)

    it("drains a submit made while session/fork is in flight", function()
        child.lua([[_G.fork_at("second answer")]])
        child.flush()
        child.lua([[_G.f:_handle_input_submit("go on")]])
        assert.is_false(
            child.lua_get([[vim.tbl_contains(_G.methods(), "session/prompt")]])
        )
        child.lua([[_G.cbs["session/fork"]({ sessionId = "sid-fork" }, nil)]])
        child.flush()

        assert.is_true(
            child.lua_get([[vim.tbl_contains(_G.methods(), "session/prompt")]])
        )
    end)

    --- Press `keys` with the cursor on the last character of the link name
    --- in the source chat's fork link row.
    --- @param keys string
    local function follow_link(keys)
        child.lua(
            [[
local win = vim.fn.bufwinid(_G.s.widget.buf_nrs.agent)
if win == -1 then
    vim.api.nvim_set_current_buf(_G.s.widget.buf_nrs.agent)
    win = vim.api.nvim_get_current_win()
end
vim.api.nvim_set_current_win(win)
local row = _G.row_of(_G.s, "Forked to agentic://" .. _G.fork_cid)
vim.api.nvim_win_set_cursor(win, { row, #_G.lines(_G.s)[row] - 1 })
vim.api.nvim_feedkeys(vim.keycode(...), "mx", false)
]],
            { keys }
        )
        child.flush()
    end

    it("opens the other chat with gf on its name", function()
        fork_natively()
        follow_link("gf")

        assert.is_true(
            child.lua_get(
                "vim.api.nvim_get_current_buf() == _G.f.widget.buf_nrs.agent"
            )
        )
    end)

    it("loads a closed chat with gf in the window gf chose", function()
        fork_natively()
        child.lua([[require("agentic.session_registry").destroy(_G.f)]])
        child.flush()
        child.lua([[_G.tabs = #vim.api.nvim_list_tabpages()]])
        follow_link("<C-w>gf")
        child.lua([[
_G.l = require("agentic.session_registry").session_for_key(_G.fork_cid)
_G.shown_win = vim.api.nvim_get_current_win()
]])
        child.lua([[_G.cbs["session/load"]({}, nil)]])
        child.flush()

        assert.equal(
            child.lua_get("_G.tabs + 1"),
            child.lua_get("#vim.api.nvim_list_tabpages()")
        )
        assert.is_true(
            child.lua_get(
                "vim.api.nvim_win_get_buf(_G.shown_win) == _G.l.widget.buf_nrs.agent"
            )
        )
        assert.is_true(
            child.lua_get(
                [[vim.api.nvim_buf_get_name(_G.l.widget.buf_nrs.agent) == "agentic://" .. _G.fork_cid]]
            )
        )
        assert.equal(1, child.lua_get([[_G.row_of(_G.l, "## Src")]]))
    end)

    it("renders a reloaded fork from its link", function()
        fork_natively()
        child.lua([[_G.f:_reload_chat()]])

        absent([[_G.row_of(_G.f, "## first question")]])
        assert.equal(1, child.lua_get([[_G.row_of(_G.f, "## Src")]]))
    end)

    it("renders a loaded fork from its link", function()
        fork_natively()
        child.lua([[
_G.l = require("agentic.session_registry").create()
_G.l:load_acp_session(_G.fork_cid)
]])
        child.flush()

        absent([[_G.row_of(_G.l, "## first question")]])
        assert.equal(1, child.lua_get([[_G.row_of(_G.l, "## Src")]]))
    end)

    it(
        "add_fork_link writes only the history for an unrendered prompt",
        function()
            child.lua([[
_G.q3 = _G.msg("user", "unrendered")
_G.s.chat_history:add_message(_G.q3)
_G.link = { type = "fork_link", direction = "to", chat_id = "sid-x",
    cwd = "/c", title = "Linked" }
_G.s:add_fork_link(_G.link, _G.q3)
_G.s:add_fork_link(_G.link, _G.msg("user", "gone"))
]])

            assert.equal(6, child.lua_get("#_G.s.chat_history.messages"))
            assert.equal(
                "fork_link",
                child.lua_get("_G.s.chat_history.messages[5].type")
            )
            absent([[_G.row_of(_G.s, "## Linked")]])
        end
    )

    it("binds every form of the fork key with its window variants", function()
        child.lua([[
require("agentic.config").keymaps.agent.fork =
    { { "<F5>", mode = "n" }, "<F6>" }
_G.k = require("agentic.session_registry").create()
]])
        for _, lhs in ipairs({
            "<F5>",
            "<C-w><F5>",
            "<C-w>g<F5>",
            "<F6>",
            "<C-w><F6>",
            "<C-w>g<F6>",
        }) do
            child.lua("_G.lhs = ...", { lhs })
            assert.equal(
                "Agentic: Fork before this turn",
                child.lua_get(
                    [[vim.api.nvim_buf_call(_G.k.widget.buf_nrs.agent, function()
                        return vim.fn.maparg(_G.lhs, "n", false, true).desc
                    end)]]
                )
            )
        end
    end)
end)
