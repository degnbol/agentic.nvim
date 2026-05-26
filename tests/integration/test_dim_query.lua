local assert = require("tests.helpers.assert")

describe("AgenticDimmedBlock query", function()
    --- Returns the start lines (0-indexed) of all @AgenticDimmedBlock
    --- captures in `bufnr`'s markdown tree.
    --- @param bufnr number
    --- @return integer[] starts
    local function dim_capture_starts(bufnr)
        local q = vim.treesitter.query.get("markdown", "highlights")
        assert.is_not_nil(q)
        ---@cast q -nil

        local parser = vim.treesitter.get_parser(bufnr, "markdown")
        assert.is_not_nil(parser)
        ---@cast parser -nil
        local tree = parser:parse()[1]
        local starts = {}
        for id, node in q:iter_captures(tree:root(), bufnr) do
            if q.captures[id] == "AgenticDimmedBlock" then
                local sr = node:range()
                table.insert(starts, sr)
            end
        end
        return starts
    end

    --- Build a scratch buffer with `lines` and filetype `markdown`.
    --- @param lines string[]
    --- @return number bufnr
    local function make_markdown_buf(lines)
        local b = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
        vim.bo[b].filetype = "markdown"
        return b
    end

    setup(function()
        local b = vim.api.nvim_create_buf(false, true)
        vim.bo[b].filetype = "AgenticChat"
        vim.api.nvim_buf_delete(b, { force = true })
    end)

    it("dims ```markdown blocks whose body starts with {{{", function()
        local buf = make_markdown_buf({
            "```markdown",
            "{{{",
            "sidecar content",
            "}}}",
            "```",
        })
        local starts = dim_capture_starts(buf)
        assert.equal(1, #starts)
        assert.equal(0, starts[1])
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does not dim ```markdown blocks without leading {{{", function()
        local buf = make_markdown_buf({
            "```markdown",
            "# heading",
            "diff content",
            "```",
        })
        local starts = dim_capture_starts(buf)
        assert.equal(0, #starts)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("does not dim non-markdown fences with leading {{{", function()
        local buf = make_markdown_buf({
            "```console",
            "{{{",
            "log output",
            "}}}",
            "```",
        })
        local starts = dim_capture_starts(buf)
        assert.equal(0, #starts)
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)
