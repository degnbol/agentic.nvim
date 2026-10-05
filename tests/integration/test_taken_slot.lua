local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- A widget window that shows a buffer of the user's (`:e`, `gf`, `:b`) is the
--- user's window: layout commands, focus and attention leave it alone.
describe("Widget window showing another buffer", function()
    local child = Child:new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        pcall(child.stop)
    end)

    --- Open a used session, as `_G.s`, so it outlives its chat leaving a
    --- window.
    --- @param opts? { position?: string }
    local function open_session(opts)
        child.lua(
            [[require("agentic").toggle(...)]],
            { opts or vim.empty_dict() }
        )
        child.flush()
        child.lua([[
_G.s = require("agentic.session_registry").bound_session(
    vim.api.nvim_get_current_tabpage()
)
table.insert(_G.s.chat_history.messages, { type = "user", text = "hi" })
]])
    end

    --- `:enew` in the widget's `panel` window, which becomes `_G.taken`.
    --- @param panel string
    local function take_slot(panel)
        child.lua(
            [[
_G.taken = _G.s.widget.win_nrs[...]
vim.api.nvim_set_current_win(_G.taken)
vim.cmd.enew()
_G.other = vim.api.nvim_get_current_buf()
]],
            { panel }
        )
        child.flush()
    end

    --- @return boolean
    local function taken_shows_other()
        return child.lua_get([[
vim.api.nvim_win_is_valid(_G.taken)
    and vim.api.nvim_win_get_buf(_G.taken) == _G.other
]])
    end

    it("toggle leaves it open, and the next toggle opens a new chat", function()
        open_session()
        take_slot("chat")

        child.lua([[require("agentic").toggle()]])
        child.flush()
        assert.is_true(taken_shows_other())
        assert.is_false(child.lua_get([[_G.s.widget:has_windows()]]))

        child.lua([[require("agentic").toggle()]])
        child.flush()
        assert.is_true(taken_shows_other())
        local chat_win = child.lua_get([[_G.s.widget:panel_win("chat")]])
        assert.is_not_nil(chat_win)
        assert.are_not.equal(child.lua_get("_G.taken"), chat_win)
    end)

    it("hide and rotate_layout leave it open", function()
        open_session()
        take_slot("chat")

        child.lua([[_G.s.widget:rotate_layout()]])
        child.flush()
        assert.is_true(taken_shows_other())

        child.lua([[_G.s.widget:hide()]])
        child.flush()
        assert.is_true(taken_shows_other())
    end)

    it("Agentic.close in the only tab does not quit", function()
        -- The widget fills the only tab.
        open_session({ position = "tab" })
        take_slot("chat")

        child.lua([[require("agentic").close()]])
        child.flush()

        assert.is_true(taken_shows_other())
    end)

    it("Agentic.close does not close the tab", function()
        child.cmd("tabnew")
        local other_tab = child.api.nvim_get_current_tabpage()
        -- The widget fills a second tab.
        open_session({ position = "tab" })
        take_slot("chat")

        child.lua([[require("agentic").close()]])
        child.flush()

        assert.is_true(taken_shows_other())
        assert.equal(2, #child.api.nvim_list_tabpages())
        assert.is_true(child.api.nvim_tabpage_is_valid(other_tab))
    end)

    it(":bd in a panel window opens no extra window on show", function()
        open_session()
        child.lua([[
vim.api.nvim_set_current_win(_G.s.widget.win_nrs.input)
vim.cmd.bdelete()
_G.s.widget:show()
]])
        child.flush()
        local n_wins = #child.api.nvim_tabpage_list_wins(0)

        child.lua([[_G.s.widget:show()]])
        child.flush()

        assert.equal(n_wins, #child.api.nvim_tabpage_list_wins(0))
    end)

    it("restoring onto the tab keeps an edited buffer in it", function()
        open_session()
        take_slot("chat")
        child.lua([[
vim.api.nvim_buf_set_lines(_G.other, 0, -1, false, { "unsaved" })
_G.s.widget:close_empty_non_widget_windows()
]])

        assert.is_true(taken_shows_other())
    end)

    it("p in the chat pastes into a reopened input, not into it", function()
        open_session()
        take_slot("input")
        child.lua([[
vim.fn.setreg('"', "pasted")
vim.api.nvim_set_current_win(_G.s.widget:panel_win("chat"))
]])

        child.type_keys("p")

        assert.equal(
            child.lua_get("_G.s.widget.buf_nrs.input"),
            child.api.nvim_get_current_buf()
        )
        assert.same({ "pasted" }, child.api.nvim_buf_get_lines(0, 0, -1, false))
        assert.same(
            { "" },
            child.lua_get(
                [[vim.api.nvim_buf_get_lines(_G.other, 0, -1, false)]]
            )
        )
    end)

    it("focus moves to no panel in it", function()
        open_session()
        take_slot("input")
        local chat_win = child.lua_get([[_G.s.widget:panel_win("chat")]])
        child.api.nvim_set_current_win(chat_win)

        child.lua([[_G.s.widget:move_cursor_to("input")]])
        child.flush()

        assert.equal(chat_win, child.api.nvim_get_current_win())
    end)

    it("submit does not focus it", function()
        open_session()
        take_slot("chat")
        child.lua([[
require("agentic.config").settings.move_cursor_to_chat_on_submit = true
_G.s.widget.on_submit_input = function() return true end
vim.api.nvim_buf_set_lines(_G.s.widget.buf_nrs.input, 0, -1, false, { "hi" })
_G.input_win = _G.s.widget:panel_win("input")
vim.api.nvim_set_current_win(_G.input_win)
_G.s.widget:submit()
]])
        child.flush()

        assert.equal(
            child.lua_get("_G.input_win"),
            child.api.nvim_get_current_win()
        )
    end)

    it("submit does not scroll it", function()
        open_session()
        take_slot("chat")
        child.lua([[
vim.api.nvim_buf_set_lines(
    _G.other, 0, -1, false, vim.tbl_map(tostring, vim.fn.range(1, 200))
)
vim.api.nvim_win_set_cursor(_G.taken, { 1, 0 })
require("agentic.config").settings.move_cursor_to_chat_on_submit = false
_G.s.widget.on_submit_input = function() return true end
vim.api.nvim_buf_set_lines(_G.s.widget.buf_nrs.input, 0, -1, false, { "hi" })
_G.s.widget:submit()
]])
        child.flush()

        assert.same(
            { 1, 0 },
            child.api.nvim_win_get_cursor(child.lua_get("_G.taken"))
        )
    end)

    it("attention does not count it as the focused chat", function()
        open_session()
        take_slot("chat")
        child.lua([[
_G.rang = false
require("agentic.session_manager")._ring_bell = function()
    _G.rang = true
end
_G.s:_notify_attention("[done]", true)
]])

        assert.is_true(child.lua_get("_G.rang"))
    end)
end)
