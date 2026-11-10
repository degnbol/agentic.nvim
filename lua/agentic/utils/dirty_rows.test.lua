local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local DirtyRows = require("agentic.utils.dirty_rows")

describe("agentic.utils.DirtyRows", function()
    local bufnr

    --- Paragraphs "p1".."p<n>", each followed by a blank line.
    --- @param n integer
    --- @return string[]
    local function paragraphs(n)
        local lines = {}
        for i = 1, n do
            vim.list_extend(lines, { "p" .. i, "" })
        end
        return lines
    end

    --- A markdown buffer of `lines`, parsed, and watched.
    --- @param lines string[]
    --- @return agentic.utils.DirtyRows
    local function watched(lines)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.treesitter.get_parser(bufnr, "markdown"):parse()
        return DirtyRows.watch(bufnr)
    end

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].filetype = "markdown"
    end)

    after_each(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it("an edit marks its rows", function()
        local dirty = watched(paragraphs(10))

        vim.api.nvim_buf_set_text(bufnr, 10, 0, 10, 2, { "q6" })

        assert.same({ { 10, 10 } }, dirty:take())
        assert.is_nil(dirty:take())
    end)

    it("a later edit above shifts them", function()
        local dirty = watched(paragraphs(10))

        vim.api.nvim_buf_set_text(bufnr, 10, 0, 10, 2, { "q6" })
        vim.api.nvim_buf_set_lines(bufnr, 2, 2, false, { "x", "" })

        assert.same({ { 2, 4 }, { 12, 12 } }, dirty:take())
    end)

    it("a root-tree change far from the edit widens the span", function()
        local dirty = watched(paragraphs(10))
        local last = vim.api.nvim_buf_line_count(bufnr) - 1

        vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "```" })

        local spans = dirty:take() or {}
        assert.equal(0, spans[1][1])
        assert.equal(last + 1, spans[#spans][2])
    end)

    it("a new parser returns the whole buffer", function()
        local dirty = watched(paragraphs(10))
        vim.treesitter.get_parser(bufnr, "markdown_inline")

        vim.api.nvim_buf_set_text(bufnr, 10, 0, 10, 2, { "q6" })

        assert.same(
            { { 0, vim.api.nvim_buf_line_count(bufnr) - 1 } },
            dirty:take()
        )
    end)

    it("sees edits again after the buffer is unloaded", function()
        local path = vim.fn.tempname() .. ".md"
        vim.fn.writefile(paragraphs(10), path)
        vim.api.nvim_buf_delete(bufnr, { force = true })
        bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)
        vim.bo[bufnr].filetype = "markdown"
        vim.treesitter.get_parser(bufnr):parse()
        local dirty = DirtyRows.watch(bufnr)

        vim.cmd.bunload(bufnr)
        vim.fn.bufload(bufnr)
        vim.api.nvim_buf_set_text(bufnr, 10, 0, 10, 2, { "q6" })
        local line_count = vim.api.nvim_buf_line_count(bufnr)
        assert.same({ { 0, line_count - 1 } }, dirty:take())

        vim.api.nvim_buf_set_text(bufnr, 4, 0, 4, 2, { "q3" })
        assert.same({ { 4, 4 } }, dirty:take())
        vim.bo[bufnr].modified = false
    end)

    it("a clean take does not look up the parser", function()
        local dirty = watched(paragraphs(3))
        local get_parser = spy.on(vim.treesitter, "get_parser")

        local spans = dirty:take()
        get_parser:revert()

        assert.is_nil(spans)
        assert.equal(0, get_parser.call_count)
    end)
end)
