local assert = require("tests.helpers.assert")
local StatusIndicator = require("agentic.ui.status_indicator")

describe("agentic.ui.StatusIndicator", function()
    --- @type integer
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    --- The text of the indicator's virtual line, nil when none shows.
    --- @return string|nil
    local function shown_state()
        local marks = vim.api.nvim_buf_get_extmarks(
            bufnr,
            vim.api.nvim_get_namespaces().agentic_status,
            0,
            -1,
            { details = true }
        )
        local mark = marks[1]
        return mark and vim.trim(mark[4].virt_lines[1][1][1])
    end

    describe("switch", function()
        it("changes the state of an active indicator", function()
            local indicator = StatusIndicator:new(bufnr)
            indicator:start("generating")

            indicator:switch("thinking")

            assert.equal("thinking", shown_state())
        end)

        it("does nothing when stopped", function()
            local indicator = StatusIndicator:new(bufnr)

            indicator:switch("thinking")

            assert.is_false(indicator:is_active())
            assert.is_nil(shown_state())
        end)
    end)
end)
