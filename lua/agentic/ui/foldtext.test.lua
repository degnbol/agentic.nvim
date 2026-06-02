local assert = require("tests.helpers.assert")

describe("agentic.ui.foldtext", function()
    --- @type number
    local bufnr
    --- @type number
    local winid

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 60,
            height = 20,
            row = 0,
            col = 0,
        })
    end)

    after_each(function()
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @param n integer
    local function fill_lines(n)
        local lines = {}
        for i = 1, n do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end

    describe("foldtext", function()
        it("summarises the inclusive line count of a closed fold", function()
            -- foldtext reads vim.v.foldstart/foldend, which vim only sets while
            -- rendering a closed fold. foldtextresult() evaluates the window's
            -- 'foldtext' with those set, so it exercises the real arithmetic
            -- (a direct call leaves the v: vars unset). The fold source is
            -- irrelevant — a manual fold stands in for the runtime treesitter
            -- fold. 5,11fold spans 7 inclusive lines (foldend - foldstart + 1),
            -- matching the body-only treesitter fold's inclusive count.
            fill_lines(20)
            vim.wo[winid].foldmethod = "manual"
            vim.wo[winid].foldenable = true
            vim.wo[winid].foldtext =
                'v:lua.require("agentic.ui.foldtext").foldtext()'
            vim.api.nvim_win_call(winid, function()
                vim.cmd("5,11fold")
            end)

            local text = vim.api.nvim_win_call(winid, function()
                return vim.fn.foldtextresult(5)
            end)
            assert.is_not_nil(text:match("··· 7 lines ···"))

            -- The highlight group is fixed regardless of the v: vars, so a
            -- direct call covers it.
            local chunks = require("agentic.ui.foldtext").foldtext()
            assert.equal("Comment", chunks[1][2])
        end)
    end)
end)
