local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- The test table, aligned after conceal, its third row holding a link.
local TABLE = {
    "| ab | v |",
    "| -- | - |",
    "| [ab](http://example.com/long) | x |",
    "| cd | y |",
}

describe("Horizontal scroll in the chat", function()
    local child = Child:new()

    --- Replace the chat with `lines` and parse it.
    --- @param lines string[]
    local function set_chat(lines)
        child.lua(
            [[
local lines = ...
_G.s.message_writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end)
vim.treesitter.get_parser(_G.s.widget.buf_nrs.agent):parse(true)
]],
            { lines }
        )
    end

    before_each(function()
        child.setup()
        child.cmd("Agentic")
        child.flush()
        child.lua([[
_G.s = require("agentic.session_registry").current()
_G.win = _G.s.widget:home_win()
vim.api.nvim_set_current_win(_G.win)
]])
        -- Row 5: a long row for the cursor, so `leftcol` is not clamped by it.
        set_chat(vim.list_extend(vim.deepcopy(TABLE), { string.rep("z", 200) }))
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    --- Scroll a window to `leftcol` with the cursor at (`lnum`, `col`), then
    --- redraw.
    --- @param leftcol integer
    --- @param opts { win?: string, lnum?: integer, col?: integer }|nil `win` is a child expression for the window (`_G.win`); the cursor defaults to row 5, just right of `leftcol`
    local function scroll_to(leftcol, opts)
        opts = opts or {}
        child.lua([[
local winid = ]] .. (opts.win or "_G.win") .. [[

local leftcol, lnum, col = ...
vim.api.nvim_win_call(winid, function()
    vim.fn.winrestview({ lnum = lnum, col = col, leftcol = leftcol, topline = 1 })
end)
vim.cmd("redraw")
]], { leftcol, opts.lnum or 5, opts.col or leftcol + 2 })
    end

    --- Screen text of four window rows from `first`, text area only, trimmed.
    --- @param win string Lua expression that gives the window id in the child
    --- @param first integer|nil 1-based first window row; 1 when nil
    --- @return string[] rows
    local function table_rows(win, first)
        return child.lua([[
local winid = ]] .. win .. [[

local first = ...
local info = vim.fn.getwininfo(winid)[1]
local rows = {}
for i = 1, 4 do
    local cells = {}
    for col = 1, info.width - info.textoff do
        cells[col] = vim.fn.screenstring(
            info.winrow + first + i - 2,
            info.wincol + info.textoff + col - 1
        )
    end
    rows[i] = vim.trim(table.concat(cells))
end
return rows
]], { first or 1 })
    end

    --- 1-based positions of `|` in `text`.
    --- @param text string
    --- @return integer[]
    local function pipes(text)
        local positions = {}
        for i = 1, #text do
            if text:sub(i, i) == "|" then
                positions[#positions + 1] = i
            end
        end
        return positions
    end

    it("keeps every table row aligned at any leftcol", function()
        for _, leftcol in ipairs({ 1, 3, 8, 11, 20 }) do
            scroll_to(leftcol)
            local rows = table_rows("_G.win")
            assert.equal(
                leftcol,
                child.lua_get("vim.fn.getwininfo(_G.win)[1].leftcol")
            )
            for i = 2, 4 do
                assert.same(pipes(rows[1]), pipes(rows[i]))
            end
        end
    end)

    it("moves every row by leftcol displayed columns", function()
        scroll_to(3)
        assert.same(
            { "b | v |", "- | - |", "b | x |", "d | y |" },
            table_rows("_G.win")
        )
    end)

    it("aligns the cursor row after zl pushes the cursor right", function()
        child.lua([[vim.api.nvim_win_set_cursor(_G.win, { 3, 0 })]])
        child.type_keys("3zl")
        child.cmd("redraw")
        assert.same(
            { "b | v |", "- | - |", "b | x |", "d | y |" },
            table_rows("_G.win")
        )
    end)

    it("keeps the cursor character when the row would go blank", function()
        -- leftcol 30 is past the link row's displayed length; the cursor
        -- sits on its closing `|` at byte 36.
        scroll_to(30, { lnum = 3, col = 36 })
        assert.same({ "", "", "|", "" }, table_rows("_G.win"))
    end)

    it("shifts each window on the buffer by its own leftcol", function()
        child.lua([[
vim.cmd("split")
_G.other = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(_G.win)
]])
        scroll_to(5, { win = "_G.other" })
        scroll_to(3)
        assert.same(
            { "b | v |", "- | - |", "b | x |", "d | y |" },
            table_rows("_G.win")
        )
        assert.same(
            { "| v |", "| - |", "| x |", "| y |" },
            table_rows("_G.other")
        )
    end)

    it("leaves a window at conceallevel 1 alone", function()
        child.lua([[vim.wo[_G.win].conceallevel = 1]])
        scroll_to(3)
        assert.is_not.equal("b | x |", table_rows("_G.win")[3])
    end)

    it("does no work for rows inside a closed fold", function()
        local lines = {}
        for i = 1, 500 do
            lines[i] = "filler " .. i
        end
        set_chat(vim.list_extend(lines, TABLE))
        child.lua([[
vim.wo[_G.win].foldmethod = "manual"
vim.api.nvim_win_call(_G.win, function()
    vim.cmd("normal! zE")
    vim.cmd("1,500fold")
end)
local Conceal = require("agentic.utils.conceal")
local columns = Conceal.columns
_G.n_columns = 0
Conceal.columns = function(...)
    _G.n_columns = _G.n_columns + 1
    return columns(...)
end
]])
        scroll_to(3, { lnum = 503, col = 3 })
        assert.same(
            { "b | v |", "- | - |", "b | x |", "d | y |" },
            table_rows("_G.win", 2)
        )
        assert.is_true(
            child.lua_get("_G.n_columns")
                <= child.lua_get("vim.api.nvim_win_get_height(_G.win)")
        )
    end)
end)
