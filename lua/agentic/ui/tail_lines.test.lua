local assert = require("tests.helpers.assert")
local TailLines = require("agentic.ui.tail_lines")

describe("agentic.ui.TailLines", function()
    --- @type integer
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b" })
    end)

    after_each(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    --- The row and text of the step line's virtual line, nil when none shows.
    --- @return integer|nil row
    --- @return string|nil text
    local function shown()
        local marks = vim.api.nvim_buf_get_extmarks(
            bufnr,
            vim.api.nvim_get_namespaces().agentic_tail_lines,
            0,
            -1,
            { details = true }
        )
        local mark = marks[1]
        if not mark then
            return nil, nil
        end
        return mark[2], vim.trim(mark[4].virt_lines[1][1][1])
    end

    it("shows its text below the last line", function()
        local tail_lines = TailLines:new(bufnr)

        tail_lines:show_step("loading session")

        local row, text = shown()
        assert.equal(1, row)
        assert.equal("loading session", text)
    end)

    it("replaces the text it shows", function()
        local tail_lines = TailLines:new(bufnr)
        tail_lines:show_step("loading session")

        tail_lines:show_step("starting session")

        local _, text = shown()
        assert.equal("starting session", text)
    end)

    it("moves to the new last line on reposition", function()
        local tail_lines = TailLines:new(bufnr)
        tail_lines:show_step("forking")
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "c" })

        tail_lines:reposition()

        assert.equal(2, shown())
    end)

    it("shows nothing after clear, and reposition keeps it so", function()
        local tail_lines = TailLines:new(bufnr)
        tail_lines:show_step("forking")

        tail_lines:clear_step()
        tail_lines:reposition()

        assert.is_nil(shown())
    end)

    it(
        "shows each prompt dimmed from the sign column, oldest first, above the step",
        function()
            local tail_lines = TailLines:new(bufnr)
            tail_lines:show_step("forking")

            tail_lines:show_prompts({
                { sign = "> ", text = "first\nsecond" },
                { sign = "/ ", text = "third" },
            })

            local details = vim.api.nvim_buf_get_extmarks(
                bufnr,
                vim.api.nvim_get_namespaces().agentic_tail_lines,
                0,
                -1,
                { details = true }
            )[1][4] --[[@as vim.api.keyset.extmark_details]]
            assert.is_true(details.virt_lines_leftcol)
            assert.same({
                { { "> first", "AgenticUntakenPrompt" } },
                { { "  second", "AgenticUntakenPrompt" } },
                { { "/ third", "AgenticUntakenPrompt" } },
                { { "   forking", "NonText" } },
            }, details.virt_lines)
        end
    )

    it("shows nothing once the prompts and the step are gone", function()
        local tail_lines = TailLines:new(bufnr)
        tail_lines:show_prompts({ { sign = "> ", text = "first" } })

        tail_lines:show_prompts({})

        assert.is_nil(shown())
    end)
end)
