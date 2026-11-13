local assert = require("tests.helpers.assert")
local FenceRows = require("agentic.ui.fence_rows")
local MessageWriter = require("agentic.ui.message_writer")

describe("agentic.ui.FenceRows", function()
    local bufnr

    before_each(function()
        -- As bootstrap.lua registers it.
        vim.treesitter.language.add("agentic", {
            path = vim.api.nvim_get_runtime_file("parser/markdown.so", false)[1],
            symbol_name = "markdown",
        })
        vim.treesitter.language.register("agentic", "AgenticChat")
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].filetype = "AgenticChat"
    end)

    after_each(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    --- 0-indexed rows of the marks, one entry per mark.
    --- @return integer[]
    local function marked_rows()
        return vim.tbl_map(function(mark)
            return mark[2]
        end, vim.api.nvim_buf_get_extmarks(
            bufnr,
            FenceRows.NS,
            0,
            -1,
            {}
        ))
    end

    --- @param first integer 0-indexed
    --- @param last integer 0-indexed, exclusive; -1 for the end
    --- @param lines string[]
    local function set_lines(first, last, lines)
        vim.api.nvim_buf_set_lines(bufnr, first, last, false, lines)
    end

    it("marks exactly the delimiter rows", function()
        local fence_rows = FenceRows:new(bufnr)
        set_lines(0, -1, {
            "text",
            "```lua",
            "x = 1",
            "```",
            "",
            "more",
            "```bash",
            "ls",
            "```",
        })

        fence_rows:sync()

        assert.same({ 1, 3, 6, 8 }, marked_rows())
    end)

    it("marks a closer written after its opener", function()
        local fence_rows = FenceRows:new(bufnr)
        set_lines(0, -1, { "a", "```lua" })
        fence_rows:sync()
        set_lines(-1, -1, { "x", "y" })
        fence_rows:sync()
        assert.same({ 1 }, marked_rows())

        set_lines(-1, -1, { "```", "", "b" })
        fence_rows:sync()

        assert.same({ 1, 4 }, marked_rows())
    end)

    it("unmarks the rows that replace a deleted block", function()
        local fence_rows = FenceRows:new(bufnr)
        set_lines(0, -1, { "a", "```lua", "x", "```", "b" })
        fence_rows:sync()

        set_lines(1, 4, { "c", "d", "e" })
        fence_rows:sync()

        assert.same({}, marked_rows())
    end)

    it("leaves a shorter fence inside a longer one", function()
        local fence_rows = FenceRows:new(bufnr)
        set_lines(0, -1, { "````text", "```", "x", "```", "````" })

        fence_rows:sync()

        assert.same({ 0, 4 }, marked_rows())
    end)

    it("marks again only the fenced block an edit meets", function()
        local fence_rows = FenceRows:new(bufnr)
        set_lines(
            0,
            -1,
            { "```lua", "x", "```", "", "```bash", "a", "b", "```" }
        )
        fence_rows:sync()
        vim.api.nvim_buf_clear_namespace(bufnr, FenceRows.NS, 0, -1)

        set_lines(6, 7, { "c" })
        fence_rows:sync()

        assert.same({ 4, 7 }, marked_rows())
    end)

    describe("in a markdown body", function()
        local lines = {
            "````markdown-fold",
            "## h",
            "```lua",
            "x",
            "```",
            "```bash",
            "y",
            "```",
            "````",
        }

        it("marks the nested delimiters", function()
            local fence_rows = FenceRows:new(bufnr)
            set_lines(0, -1, lines)

            fence_rows:sync()

            assert.same({ 0, 2, 4, 5, 7, 8 }, marked_rows())
        end)

        it(
            "unmarks a nested opener a deleted closer turns to content",
            function()
                local fence_rows = FenceRows:new(bufnr)
                set_lines(0, -1, lines)
                fence_rows:sync()

                set_lines(4, 5, {})
                fence_rows:sync()

                assert.same({ 0, 2, 6, 7 }, marked_rows())
            end
        )
    end)

    describe("marked", function()
        it("answers for rows set without a sync", function()
            local fence_rows = FenceRows:new(bufnr)
            set_lines(0, -1, { "a", "```lua", "x", "```" })

            assert.is_true(fence_rows:marked(1))
            assert.is_false(fence_rows:marked(2))
        end)

        it("leaves an inner fence row of a text block unmarked", function()
            local fence_rows = FenceRows:new(bufnr)
            set_lines(0, -1, { "````text", "x", "```", "````" })

            assert.is_false(fence_rows:marked(2))
            assert.is_true(fence_rows:marked(3))
        end)

        it("marks an inner fence row of a markdown block", function()
            local fence_rows = FenceRows:new(bufnr)
            set_lines(0, -1, { "````markdown", "```", "x", "```", "````" })

            assert.is_true(fence_rows:marked(3))
        end)
    end)

    describe("through a MessageWriter", function()
        it("marks several edits in one write", function()
            local writer = MessageWriter:new(bufnr)
            set_lines(0, -1, { "a", "", "b", "", "c" })

            writer:_own_edit(function(buf)
                vim.api.nvim_buf_set_lines(buf, -1, -1, false, {
                    "```lua",
                    "x",
                    "```",
                })
                vim.api.nvim_buf_set_lines(buf, 0, 0, false, {
                    "```bash",
                    "ls",
                    "```",
                })
            end)

            assert.same({ 0, 2, 8, 10 }, marked_rows())
        end)

        it("marks the kept text again after a reset", function()
            local writer = MessageWriter:new(bufnr)
            writer:_own_edit(function(buf)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                    "```lua",
                    "x",
                    "```",
                })
            end)

            writer:reset()
            assert.same({}, marked_rows())
            writer:_own_edit(function(buf)
                vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "" })
            end)

            assert.same({ 0, 2 }, marked_rows())
        end)
    end)
end)
