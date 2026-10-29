local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

--- Check whether a parser for `lang` is installed.
--- @param lang string
--- @return boolean
local function has_parser(lang)
    return pcall(vim.treesitter.language.add, lang)
end

describe("ToolCallRenderer", function()
    local Renderer = require("agentic.ui.tool_call_renderer")
    local Layout = require("agentic.ui.tool_call_layout")
    local FileSystem
    local read_stub
    local disk_stub
    local path_stub

    before_each(function()
        FileSystem = require("agentic.utils.file_system")
        path_stub = spy.stub(FileSystem, "to_absolute_path")
        path_stub:invokes(function(path)
            return path
        end)
        read_stub = spy.stub(FileSystem, "read_from_buffer_or_disk")
        -- extract_diff_blocks retries against real disk when the first match
        -- fails, so a fixture path that happens to exist would supply content
        -- no test declared.
        disk_stub = spy.stub(FileSystem, "read_from_disk")
    end)

    after_each(function()
        read_stub:revert()
        disk_stub:revert()
        path_stub:revert()
    end)

    --- Every NS_DIFF_HIGHLIGHTS mark in `bufnr`, `{ row, col, details }` each.
    --- @param bufnr integer
    --- @return table[]
    local function highlight_marks(bufnr)
        local found = {}
        for _, mark in
            ipairs(
                vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    Renderer.NS_DIFF_HIGHLIGHTS,
                    0,
                    -1,
                    { details = true }
                )
            )
        do
            table.insert(found, { mark[2], mark[3], mark[4] })
        end
        return found
    end

    --- Lay out `block` in a fresh buffer, with its highlights applied.
    --- @param block agentic.ui.MessageWriter.ToolCallBlock
    --- @return integer bufnr
    --- @return agentic.ui.ToolCallLayout.Layout layout
    local function paint(block)
        local layout = Layout.build(block, 80)
        local bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, layout.lines)
        Renderer.apply_block_highlights(bufnr, 0, layout)
        return bufnr, layout
    end

    --- 0-indexed row of `text` in `lines`.
    --- @param lines string[]
    --- @param text string
    --- @return integer|nil
    local function row_of(lines, text)
        for i, line in ipairs(lines) do
            if line == text then
                return i - 1
            end
        end
        return nil
    end

    it("applies a priority-200 extmark for a context capture", function()
        if not has_parser("python") then
            return
        end

        read_stub:invokes(function()
            return { 'doc = """', "placeholder", '"""' }, nil
        end)
        local bufnr, layout = paint({
            tool_call_id = "edit-extmark",
            status = "pending",
            kind = "edit",
            argument = "/context.py",
            diff = { old = { "placeholder" }, new = { "for_helper = 1" } },
        })

        -- Find a HighlightRange with block_col_hl, then verify an extmark
        -- exists at one of its cols with priority 200.
        local target_line, target_col
        for _, hr in ipairs(layout.highlights) do
            for c, h in pairs(hr.block_col_hl or {}) do
                if h:match("string") or h:match("spell") then
                    target_line, target_col = hr.line_index, c
                end
            end
        end
        assert.is_not_nil(target_line)

        -- The extmark's hl_group is a derived clean-typography group
        -- (AgenticClean_*) keyed off the original capture name.
        local matched = false
        for _, mark in ipairs(highlight_marks(bufnr)) do
            local details = mark[3]
            matched = matched
                or (
                    mark[1] == target_line
                    and mark[2] <= target_col
                    and (details.end_col or 0) > target_col
                    and type(details.hl_group) == "string"
                    and details.hl_group:match("^AgenticClean_") ~= nil
                    and details.priority == 200
                )
        end
        assert.is_true(matched)
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    describe("block highlights", function()
        --- Rows of the marks whose hl_group starts with `prefix`.
        --- @param bufnr integer
        --- @param prefix string
        --- @return integer[] rows 0-indexed
        local function rows_with(bufnr, prefix)
            local rows = {}
            for _, mark in ipairs(highlight_marks(bufnr)) do
                local hl = mark[3].hl_group
                if hl and vim.startswith(hl, prefix) then
                    table.insert(rows, mark[1])
                end
            end
            return rows
        end

        it("lands execute colour on the content row", function()
            local bufnr, layout = paint({
                tool_call_id = "exec-ansi",
                status = "completed",
                kind = "execute",
                argument = "echo hi",
                body = { "\27[31mred\27[0m green" },
            })

            assert.same(
                { row_of(layout.lines, "red green") },
                rows_with(bufnr, "AgenticAnsi")
            )
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("lands a folded search's colour on its body rows", function()
            local Config = require("agentic.config")
            local original = Config.tool_call_display.search_max_lines
            Config.tool_call_display.search_max_lines = 1
            local bufnr, layout = paint({
                tool_call_id = "search-ansi-fold",
                status = "completed",
                kind = "search",
                argument = "rg 'foo'",
                body = { "\27[31mone\27[0m", "\27[31mtwo\27[0m" },
            })
            Config.tool_call_display.search_max_lines = original

            assert.equal("```console-fold", layout.lines[5])
            assert.same(
                { row_of(layout.lines, "one"), row_of(layout.lines, "two") },
                rows_with(bufnr, "AgenticAnsi")
            )
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("gives a match span priority over an ANSI span", function()
            local bufnr = paint({
                tool_call_id = "search-ansi-match",
                status = "completed",
                kind = "search",
                argument = "rg 'foo'",
                body = { "a.lua:3:\27[31mfoo\27[0m" },
            })

            local match_priority, ansi_priority
            for _, mark in ipairs(highlight_marks(bufnr)) do
                local hl = mark[3].hl_group
                if hl == "AgenticSearchMatch" then
                    match_priority = mark[3].priority
                elseif vim.startswith(hl, "AgenticAnsi") then
                    ansi_priority = mark[3].priority
                end
            end
            assert.is_true(match_priority > ansi_priority)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("status footer", function()
        --- @type agentic.ui.ToolCallStatus[]
        local statuses = {
            "pending",
            "in_progress",
            "completed",
            "failed",
            "cancelled",
        }

        --- @param status string
        --- @return string footer
        local function render_footer(status)
            local bufnr = vim.api.nvim_create_buf(false, true)
            Renderer.apply_status_footer(bufnr, 0, status)
            local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
            vim.api.nvim_buf_delete(bufnr, { force = true })
            return line
        end

        for _, status in ipairs(statuses) do
            it("gives " .. status .. " an icon", function()
                local icon, label =
                    render_footer(status):match("^ (%S+) (%S+) $")

                assert.equal(status, label)
                assert.truthy(icon)
            end)
        end

        describe("without a configured icon", function()
            local Config = require("agentic.config")
            local original_icons

            before_each(function()
                original_icons = vim.deepcopy(Config.status_icons)
                Config.status_icons = {}
            end)

            after_each(function()
                Config.status_icons = original_icons
            end)

            it("drops the glyph column", function()
                assert.equal(" pending ", render_footer("pending"))
            end)
        end)

        describe("with a note", function()
            local Config = require("agentic.config")
            local Theme = require("agentic.theme")
            local original_icons
            local bufnr

            before_each(function()
                original_icons = vim.deepcopy(Config.status_icons)
                Config.status_icons = {}
                bufnr = vim.api.nvim_create_buf(false, true)
            end)

            after_each(function()
                Config.status_icons = original_icons
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end)

            --- Each status extmark on the footer as `{ start_col, end_col, hl_group }`.
            --- @return table[]
            local function marks()
                local found = {}
                for _, m in
                    ipairs(
                        vim.api.nvim_buf_get_extmarks(
                            bufnr,
                            Renderer.NS_STATUS,
                            0,
                            -1,
                            { details = true }
                        )
                    )
                do
                    table.insert(found, { m[3], m[4].end_col, m[4].hl_group })
                end
                return found
            end

            it("writes the note after the status in its own group", function()
                Renderer.apply_status_footer(bufnr, 0, "completed", "grant")

                local line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
                assert.equal(" completed · grant ", line)
                assert.same({
                    { 0, 11, Theme.HL_GROUPS.STATUS_COMPLETED },
                    { 11, #line, Theme.HL_GROUPS.FOOTER_NOTE },
                }, marks())
            end)

            it("replaces the marks of an earlier footer", function()
                Renderer.apply_status_footer(bufnr, 0, "pending", "grant")
                Renderer.apply_status_footer(bufnr, 0, "completed")

                assert.equal(
                    " completed ",
                    vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
                )
                assert.same(
                    { { 0, 11, Theme.HL_GROUPS.STATUS_COMPLETED } },
                    marks()
                )
            end)
        end)
    end)
end)
