local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("opening agentic:// names", function()
    local child = Child.new()

    before_each(function()
        child.setup()
        child.lua([[
require("agentic.config").sessions.storage_path = vim.fn.tempname()
vim.cmd("Agentic")
_G.Registry = require("agentic.session_registry")
_G.s = _G.Registry.current()
_G.agent = _G.s.agent
_G.agent.agent_capabilities = { loadSession = true }
_G.agent.state = "ready"
_G.cbs = {}
_G.agent._send_request = function(_, method, _, cb)
    _G.cbs[method] = cb
end
_G.notes = {}
require("agentic.utils.logger").notify = function(message, level)
    table.insert(_G.notes, { message = message, level = level })
end

local ChatHistory = require("agentic.ui.chat_history")
local saved = ChatHistory:new("sid-saved")
saved.session_id = "sid-saved"
saved.timestamp = 1000
saved.messages = {
    { type = "user", text = "saved prompt", timestamp = 0, provider_name = "p" },
}
assert(saved:save(vim.uv.fs_realpath("/tmp")) == nil)

_G.key = require("agentic.utils.buffer_names").short_key
_G.name = function(bufnr)
    return vim.api.nvim_buf_get_name(bufnr)
end
_G.has_row = function(bufnr, text)
    return vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), text)
end
_G.loaded = function()
    return _G.Registry.session_for_key("sid-saved")
end
_G.announce = function(child_id, label)
    _G.s:_on_session_update({
        sessionUpdate = "subagent_update",
        sessionId = child_id,
        description = label,
        state = { state = "running" },
    }, "sid-live")
end
]])
        child.flush()
        child.lua([[
_G.s:new_session()
_G.cbs["session/new"]({ sessionId = "sid-live" }, nil)
_G.live = "agentic://" .. _G.s.chat_history.chat_id
_G.c1 = _G.live .. "/" .. _G.key("c1")
]])
        child.flush()
        -- A used session: an unused one closes when its chat leaves the
        -- window. Away from the chat, so `:e` does not replace it.
        child.lua([[
_G.s.chat_history:add_message({
    type = "user", text = "go", timestamp = 0, provider_name = "p",
})
_G.notes = {}
vim.cmd("tabnew")
]])
    end)

    after_each(function()
        child.stop()
    end)

    it("names a session's buffers after its chat id", function()
        assert.is_true(
            child.lua_get("_G.name(_G.s.widget.buf_nrs.agent) == _G.live")
        )
        assert.is_true(
            child.lua_get(
                [[_G.name(_G.s.widget.buf_nrs.input) == _G.live .. "/input"]]
            )
        )
    end)

    for cmd, opened in pairs({
        edit = { wins = 0, tabs = 0 },
        split = { wins = 1, tabs = 0 },
        tabedit = { wins = 1, tabs = 1 },
    }) do
        it(":" .. cmd .. " on a saved chat loads it there", function()
            child.lua([[
_G.wins = #vim.api.nvim_list_wins()
_G.tabs = #vim.api.nvim_list_tabpages()
]])
            child.cmd(cmd .. " agentic://sid-saved")
            child.lua([[_G.shown = vim.api.nvim_get_current_win()]])
            child.lua([[_G.cbs["session/load"]({}, nil)]])
            child.flush()

            assert.is_true(child.lua_get("_G.loaded() ~= _G.s"))
            assert.is_true(
                child.lua_get(
                    "vim.api.nvim_win_get_buf(_G.shown) == _G.loaded().widget.buf_nrs.agent"
                )
            )
            assert.equal(
                "agentic://sid-saved",
                child.lua_get("_G.name(_G.loaded().widget.buf_nrs.agent)")
            )
            assert.is_true(
                child.lua_get(
                    [[_G.has_row(_G.loaded().widget.buf_nrs.agent, "## saved prompt")]]
                )
            )
            assert.equal(
                opened.wins,
                child.lua_get("#vim.api.nvim_list_wins() - _G.wins")
            )
            assert.equal(
                opened.tabs,
                child.lua_get("#vim.api.nvim_list_tabpages() - _G.tabs")
            )
        end)
    end

    it("notifies an error for a closed chat's transcript name", function()
        child.lua([[vim.cmd("edit agentic://sid-saved/" .. _G.key("c1"))]])

        assert.equal(1, child.lua_get("vim.tbl_count(_G.Registry.by_id)"))
        assert.equal(
            child.lua_get("vim.log.levels.ERROR"),
            child.lua_get("_G.notes[1].level")
        )
    end)

    it("a second :e during a deferred load shows the same chat", function()
        child.lua([[
_G.agent.agent_capabilities = nil
vim.cmd("edit agentic://sid-saved")
_G.first = vim.api.nvim_get_current_buf()
vim.cmd("tabedit agentic://sid-saved")
_G.second = vim.api.nvim_get_current_buf()
_G.agent.agent_capabilities = { loadSession = true }
]])

        assert.equal(2, child.lua_get("vim.tbl_count(_G.Registry.by_id)"))
        assert.is_true(child.lua_get("_G.first == _G.second"))
        assert.is_true(
            child.lua_get("_G.first == _G.loaded().widget.buf_nrs.agent")
        )
    end)

    it("reads nothing into a buffer loaded in no window", function()
        child.lua([[vim.fn.bufload(vim.fn.bufadd("agentic://sid-saved"))]])
        child.flush()

        assert.equal(1, child.lua_get("vim.tbl_count(_G.Registry.by_id)"))
        assert.same({}, child.lua_get("_G.notes"))
    end)

    it("notifies an error for an unknown id", function()
        child.cmd("edit agentic://sid-unknown")

        assert.equal(1, child.lua_get("vim.tbl_count(_G.Registry.by_id)"))
        assert.equal(
            child.lua_get("vim.log.levels.ERROR"),
            child.lua_get("_G.notes[1].level")
        )
    end)

    it("reaches a session before its session/new returns", function()
        child.new_session()
        child.lua([[
_G.n = _G.Registry.current()
vim.cmd("tabnew")
vim.cmd("edit agentic://" .. _G.n.chat_history.chat_id)
]])

        assert.is_true(
            child.lua_get(
                "vim.api.nvim_get_current_buf() == _G.n.widget.buf_nrs.agent"
            )
        )
    end)

    it("makes a live session's wiped panel again", function()
        child.lua([[
vim.cmd.bwipeout(_G.s.widget.buf_nrs.files)
vim.cmd("tabnew")
vim.cmd("edit " .. _G.live .. "/files")
]])

        assert.is_true(
            child.lua_get(
                "vim.api.nvim_get_current_buf() == _G.s.widget.buf_nrs.files"
            )
        )
        assert.equal(
            "AgenticFiles",
            child.lua_get("vim.bo[_G.s.widget.buf_nrs.files].filetype")
        )
        assert.same({}, child.lua_get("_G.notes"))
    end)

    it("makes a wiped transcript again", function()
        child.lua([[
_G.announce("c1", "finder")
local old = _G.s._subagents:buf_of("c1")
vim.cmd.bwipeout({ args = { tostring(old) }, bang = true })
vim.cmd("tabnew")
vim.cmd("edit " .. _G.c1)
]])

        assert.is_true(
            child.lua_get(
                [[vim.api.nvim_get_current_buf() == _G.s._subagents:buf_of("c1")]]
            )
        )
        assert.is_true(child.lua_get("_G.name(0) == _G.c1"))
    end)

    it("reloads a transcript :bd! unloaded, keeping its buffer", function()
        child.lua([[
_G.announce("c1", "finder")
_G.t = _G.s._subagents:buf_of("c1")
vim.cmd("tab sbuffer " .. _G.t)
vim.cmd("bdelete!")
vim.cmd("edit " .. _G.c1)
]])

        assert.is_true(child.lua_get("vim.api.nvim_get_current_buf() == _G.t"))
        assert.is_true(child.lua_get("vim.api.nvim_buf_is_loaded(_G.t)"))
        assert.same({}, child.lua_get("_G.notes"))
    end)

    it(
        "notifies an error for a message input a subagent cannot have",
        function()
            child.lua([[
_G.announce("c1", "finder")
vim.cmd("edit " .. _G.c1 .. "/input")
]])

            assert.is_true(
                child.lua_get(
                    [[vim.api.nvim_get_current_buf() ~= _G.s._subagents:buf_of("c1")]]
                )
            )
            assert.equal(
                child.lua_get("vim.log.levels.ERROR"),
                child.lua_get("_G.notes[1].level")
            )
        end
    )

    it("notifies an error for an unknown subagent of a live session", function()
        child.lua([[vim.cmd("edit " .. _G.live .. "/" .. _G.key("c9"))]])

        assert.equal(
            child.lua_get("vim.log.levels.ERROR"),
            child.lua_get("_G.notes[1].level")
        )
    end)

    it("keeps the names when the conversation moves to a new id", function()
        child.lua([[
_G.announce("c1", "finder")
_G.s:_adopt_session("sid-next", {}, true)
]])

        assert.is_true(
            child.lua_get([[_G.name(_G.s._subagents:buf_of("c1")) == _G.c1]])
        )
        assert.is_true(
            child.lua_get(
                [[_G.s._subagents:_agent_block("c1").argument == _G.c1]]
            )
        )
        assert.is_true(
            child.lua_get(
                [[_G.name(_G.s.widget.buf_nrs.files) == _G.live .. "/files"]]
            )
        )

        -- `gf` on the block's name line, written before the move, opens
        -- the live transcript.
        child.flush()
        child.lua([[
vim.api.nvim_set_current_win(_G.s.widget:home_win())
local row = vim.fn.index(vim.api.nvim_buf_get_lines(0, 0, -1, false), _G.c1)
vim.api.nvim_win_set_cursor(0, { row + 1, 3 })
vim.api.nvim_feedkeys("gf", "mx", false)
]])
        child.flush()
        assert.is_true(
            child.lua_get(
                [[vim.api.nvim_get_current_buf() == _G.s._subagents:buf_of("c1")]]
            )
        )
    end)

    it("names the buffers after a new chat id on /new", function()
        child.lua([[_G.s:new_session()]])

        assert.is_true(
            child.lua_get(
                "_G.name(_G.s.widget.buf_nrs.agent) == 'agentic://' .. _G.s.chat_history.chat_id"
            )
        )
        assert.is_false(
            child.lua_get("_G.name(_G.s.widget.buf_nrs.agent) == _G.live")
        )
    end)
end)
