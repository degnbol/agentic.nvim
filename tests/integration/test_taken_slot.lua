local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- A panel window that shows a buffer of the user's (`:e`, `gf`, `:b`) is the
--- user's window: closing panels and moving focus leave it alone.
describe("Panel window showing another buffer", function()
    local child = Child:new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        pcall(child.stop)
    end)

    --- Show a used session's chat with its code and input panels open, as
    --- `_G.s`.
    local function open_session()
        child.cmd("Agentic")
        child.flush()
        child.lua([[
_G.s = require("agentic.session_registry").owner_of_buf(
    vim.api.nvim_get_current_buf()
)
table.insert(_G.s.chat_history.messages, { type = "user", text = "hi" })
_G.s.code_selection:add({
    lines = { "local x = 1" },
    start_line = 1,
    end_line = 1,
    file_path = "/tmp/a.lua",
    file_type = "lua",
})
_G.s.widget:input_win()
]])
        child.flush()
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

    it("close leaves it open, and sync opens the panel elsewhere", function()
        open_session()
        take_slot("code")

        child.lua([[_G.s.widget:close_panels()]])
        child.flush()
        assert.is_true(taken_shows_other())

        child.lua([[_G.s.widget:sync_panels()]])
        child.flush()
        assert.is_true(taken_shows_other())
        local code_win = child.lua_get([[_G.s.widget:panel_win("code")]])
        assert.is_not.equal(vim.NIL, code_win)
        assert.are_not.equal(child.lua_get("_G.taken"), code_win)
    end)

    it(":bd in the input window opens one input on the next use", function()
        open_session()
        child.lua([[
vim.api.nvim_set_current_win(_G.s.widget:panel_win("input"))
vim.cmd.bdelete()
_G.s.widget:input_win()
]])
        child.flush()
        local n_wins = #child.api.nvim_tabpage_list_wins(0)

        child.lua([[_G.s.widget:input_win()]])
        child.flush()

        assert.equal(n_wins, #child.api.nvim_tabpage_list_wins(0))
    end)

    it("p in the chat pastes into a reopened input, not into it", function()
        open_session()
        take_slot("input")
        child.lua([[
vim.fn.setreg('"', "pasted")
vim.api.nvim_set_current_win(_G.s.widget:home_win())
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
        local chat_win = child.lua_get([[_G.s.widget:home_win()]])
        child.api.nvim_set_current_win(chat_win)

        child.lua([[_G.s.widget:move_cursor_to("input")]])
        child.flush()

        assert.equal(chat_win, child.api.nvim_get_current_win())
    end)
end)
