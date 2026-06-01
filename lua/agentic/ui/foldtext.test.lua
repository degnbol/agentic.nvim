local assert = require("tests.helpers.assert")

describe("agentic.ui.foldtext", function()
    --- @type number
    local bufnr
    --- @type number
    local winid
    local NS_FOLDS

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 60,
            height = 20,
            row = 0,
            col = 0,
        })
        NS_FOLDS = vim.api.nvim_create_namespace("agentic_tool_folds")

        vim.wo[winid].foldmethod = "expr"
        vim.wo[winid].foldexpr =
            'v:lua.require("agentic.ui.foldtext").foldexpr()'
        vim.wo[winid].foldenable = true
        vim.wo[winid].foldlevel = 0
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

    describe("foldexpr", function()
        it("creates a fold across an NS_FOLDS extmark range", function()
            fill_lines(20)
            -- Extmark rows 4..10 (0-indexed) cover lines 5..11 (1-indexed)
            vim.api.nvim_buf_set_extmark(
                bufnr,
                NS_FOLDS,
                4,
                0,
                { end_row = 10 }
            )
            vim.cmd("normal! zX")

            assert.equal(5, vim.fn.foldclosed(5))
            assert.equal(5, vim.fn.foldclosed(8))
            assert.equal(5, vim.fn.foldclosed(11))

            assert.equal(-1, vim.fn.foldclosed(4))
            assert.equal(-1, vim.fn.foldclosed(12))
        end)

        it(
            "creates two distinct folds for adjacent NS_FOLDS extmarks",
            function()
                fill_lines(20)
                -- A merged fold would have foldclosed(8) == 3 (first fold
                -- start), two distinct folds give 8 for the second range.
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_FOLDS,
                    2,
                    0,
                    { end_row = 5 }
                )
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    NS_FOLDS,
                    7,
                    0,
                    { end_row = 10 }
                )
                vim.cmd("normal! zX")

                assert.equal(3, vim.fn.foldclosed(3))
                assert.equal(3, vim.fn.foldclosed(6))
                assert.equal(8, vim.fn.foldclosed(8))
                assert.equal(8, vim.fn.foldclosed(11))
            end
        )

        it("does not fold rows without an NS_FOLDS extmark", function()
            fill_lines(20)
            vim.cmd("normal! zX")

            for i = 1, 20 do
                assert.equal(-1, vim.fn.foldclosed(i))
            end
        end)

        it(
            "does not fold lines that contain literal fold-marker text",
            function()
                -- The old foldmarker-based approach folded any line
                -- containing `{{{`/`}}}` as a substring. NS_FOLDS-driven
                -- folding ignores buffer content entirely.
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                    "search hit: {{{",
                    "matched body line",
                    "}}}",
                    "another line",
                })
                vim.cmd("normal! zX")

                for i = 1, 4 do
                    assert.equal(-1, vim.fn.foldclosed(i))
                end
            end
        )
    end)

    describe("foldtext", function()
        it("returns a Comment-styled line-count summary", function()
            -- Drive foldtext through a real closed fold so vim.v.foldstart
            -- and vim.v.foldend are set by vim, not mocked.
            local foldtext = require("agentic.ui.foldtext").foldtext
            fill_lines(20)
            vim.api.nvim_buf_set_extmark(
                bufnr,
                NS_FOLDS,
                4,
                0,
                { end_row = 10 }
            )
            vim.cmd("normal! zX")
            vim.fn.cursor(5, 1)

            local result = vim.api.nvim_win_call(winid, foldtext)
            assert.is_table(result)
            assert.equal("Comment", result[1][2])
            assert.is_not_nil(result[1][1]:match("%d+ lines"))
        end)
    end)
end)
