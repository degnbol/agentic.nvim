local assert = require("tests.helpers.assert")
local StepLine = require("agentic.ui.step_line")

describe("agentic.ui.StepLine", function()
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
            vim.api.nvim_get_namespaces().agentic_step_line,
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
        local step_line = StepLine:new(bufnr)

        step_line:show("loading session")

        local row, text = shown()
        assert.equal(1, row)
        assert.equal("loading session", text)
    end)

    it("replaces the text it shows", function()
        local step_line = StepLine:new(bufnr)
        step_line:show("loading session")

        step_line:show("starting session")

        local _, text = shown()
        assert.equal("starting session", text)
    end)

    it("moves to the new last line on reposition", function()
        local step_line = StepLine:new(bufnr)
        step_line:show("forking")
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "c" })

        step_line:reposition()

        assert.equal(2, shown())
    end)

    it("shows nothing after clear, and reposition keeps it so", function()
        local step_line = StepLine:new(bufnr)
        step_line:show("forking")

        step_line:clear()
        step_line:reposition()

        assert.is_nil(shown())
    end)
end)
