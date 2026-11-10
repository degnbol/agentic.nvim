local PermissionHighlight = require("agentic.ui.permission_highlight")
local Renderer = require("agentic.ui.tool_call_renderer")
local assert = require("tests.helpers.assert")

describe("agentic.ui.PermissionHighlight", function()
    local ns = vim.api.nvim_create_namespace("permission_highlight_test")
    local bufnr

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
    end)

    after_each(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    --- Write `lines` as one tool call block and apply the highlight.
    --- @param lines string[]
    --- @return table<integer, true> rows 0-indexed rows carrying a wash
    local function washed_rows(lines)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        local extmark_id = vim.api.nvim_buf_set_extmark(
            bufnr,
            Renderer.NS_TOOL_BLOCKS,
            0,
            0,
            { end_row = #lines - 1 }
        )
        PermissionHighlight.apply(
            bufnr,
            ns,
            --- @diagnostic disable-next-line: missing-fields
            { extmark_id = extmark_id },
            vim.fn.tempname(),
            {},
            nil
        )
        local rows = {}
        for _, mark in
            ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
        do
            rows[mark[2]] = true
        end
        return rows
    end

    it("reaches past a fence row inside the command", function()
        local rows = washed_rows({
            "### echo",
            "````bash",
            'echo "',
            "```",
            '"; rm -rf /tmp/x',
            "````",
        })

        assert.is_true(rows[4])
    end)

    it("finds a plain command fence", function()
        local rows = washed_rows({
            "### rm",
            "```bash",
            "rm -rf /tmp/x",
            "```",
        })

        assert.is_true(rows[2])
    end)
end)
