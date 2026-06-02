local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

--- Check whether a parser for `lang` is installed.
--- @param lang string
--- @return boolean
local function has_parser(lang)
    return pcall(vim.treesitter.language.add, lang)
end

describe("ToolCallRenderer", function()
    --- @type agentic.ui.ToolCallRenderer
    local Renderer
    local FileSystem
    local read_stub
    local path_stub

    before_each(function()
        Renderer = require("agentic.ui.tool_call_renderer")
        FileSystem = require("agentic.utils.file_system")
        path_stub = spy.stub(FileSystem, "to_absolute_path")
        path_stub:invokes(function(path)
            return path
        end)
        read_stub = spy.stub(FileSystem, "read_from_buffer_or_disk")
    end)

    after_each(function()
        read_stub:revert()
        path_stub:revert()
    end)

    describe("context-aware diff highlights", function()
        it(
            "tags edits inside a multi-line string with a string capture",
            function()
                if not has_parser("python") then
                    return
                end

                -- Real on-disk file required so bufadd+bufload can resolve
                -- it and treesitter can parse the surrounding context.
                local path = vim.fn.tempname() .. ".py"
                local file_lines = {
                    'doc = """',
                    "placeholder",
                    '"""',
                }
                vim.fn.writefile(file_lines, path)

                read_stub:invokes(function()
                    return file_lines, nil
                end)

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "edit-string",
                    status = "pending",
                    kind = "edit",
                    argument = path,
                    diff = {
                        old = { "placeholder" },
                        new = { "for_helper = 1" },
                    },
                }

                local _, highlight_ranges =
                    Renderer.prepare_block_lines(block, 0)

                local found
                for _, hr in ipairs(highlight_ranges) do
                    if
                        (hr.type == "new" or hr.type == "new_modification")
                        and hr.block_col_hl
                    then
                        local cap = hr.block_col_hl[0]
                        if
                            cap
                            and (cap:match("string") or cap:match("spell"))
                        then
                            found = cap
                            break
                        end
                    end
                end
                assert.is_not_nil(found)

                vim.fn.delete(path)
                local b = vim.fn.bufnr(path)
                if b ~= -1 then
                    pcall(vim.api.nvim_buf_delete, b, { force = true })
                end
            end
        )

        it("applies a priority-200 extmark for the context capture", function()
            if not has_parser("python") then
                return
            end

            local path = vim.fn.tempname() .. ".py"
            local file_lines = {
                'doc = """',
                "placeholder",
                '"""',
            }
            vim.fn.writefile(file_lines, path)
            read_stub:invokes(function()
                return file_lines, nil
            end)

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "edit-extmark",
                status = "pending",
                kind = "edit",
                argument = path,
                diff = {
                    old = { "placeholder" },
                    new = { "for_helper = 1" },
                },
            }

            local lines, highlight_ranges =
                Renderer.prepare_block_lines(block, 0)

            local chat_buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, lines)

            Renderer.apply_diff_highlights(chat_buf, 0, highlight_ranges)

            -- Find a HighlightRange with block_col_hl, then verify an
            -- extmark exists at one of its cols with priority 200.
            local target_line, target_col
            for _, hr in ipairs(highlight_ranges) do
                if
                    (hr.type == "new" or hr.type == "new_modification")
                    and hr.block_col_hl
                then
                    for c, h in pairs(hr.block_col_hl) do
                        if h:match("string") or h:match("spell") then
                            target_line = hr.line_index
                            target_col = c
                            break
                        end
                    end
                    if target_line then
                        break
                    end
                end
            end
            assert.is_not_nil(target_line)
            --- @cast target_line -nil
            --- @cast target_col -nil

            local marks = vim.api.nvim_buf_get_extmarks(
                chat_buf,
                Renderer.NS_DIFF_HIGHLIGHTS,
                { target_line, 0 },
                { target_line, -1 },
                { details = true }
            )

            -- The extmark's hl_group is a derived clean-typography group
            -- (AgenticClean_*) keyed off the original capture name. Match
            -- by prefix rather than exact equality.
            local matched
            for _, m in ipairs(marks) do
                local row = m[2]
                local col = m[3]
                local details = m[4]
                if
                    details
                    and row == target_line
                    and col <= target_col
                    and details.end_col
                    and details.end_col > target_col
                    and type(details.hl_group) == "string"
                    and details.hl_group:match("^AgenticClean_")
                    and details.priority == 200
                then
                    matched = true
                    break
                end
            end
            assert.is_true(matched)

            pcall(vim.api.nvim_buf_delete, chat_buf, { force = true })
            vim.fn.delete(path)
            local b = vim.fn.bufnr(path)
            if b ~= -1 then
                pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
        end)

        it("falls back silently when no parser is available", function()
            -- Use an extension neovim has no parser/filetype for so
            -- get_parser returns nothing and target_lang stays nil.
            local path = vim.fn.tempname() .. ".agentic_no_parser_xyz"
            vim.fn.writefile({ "placeholder" }, path)

            read_stub:invokes(function()
                return { "placeholder" }, nil
            end)

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "edit-no-parser",
                status = "pending",
                kind = "edit",
                argument = path,
                diff = {
                    old = { "placeholder" },
                    new = { "replacement" },
                },
            }

            local _, highlight_ranges = Renderer.prepare_block_lines(block, 0)

            for _, hr in ipairs(highlight_ranges) do
                assert.is_nil(hr.block_col_hl)
            end

            vim.fn.delete(path)
            local b = vim.fn.bufnr(path)
            if b ~= -1 then
                pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
        end)
    end)

    describe("failure_reason rendering", function()
        it(
            "replaces Read's 'Read N lines' summary with the failure reason",
            function()
                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "tc-1",
                    kind = "read",
                    argument = "/tmp/foo.lua",
                    status = "failed",
                    body = { "```", "Read hooks.md first.", "```" },
                    failure_reason = { "Read hooks.md first." },
                }

                local lines, _ = Renderer.prepare_block_lines(block, 0)

                -- "Read N lines" must not appear when failed
                for _, line in ipairs(lines) do
                    assert.is_nil(line:match("^Read %d+ lines"))
                end
                -- Reason text must be in the rendered lines
                local found = false
                for _, line in ipairs(lines) do
                    if line == "Read hooks.md first." then
                        found = true
                        break
                    end
                end
                assert.is_true(found)
            end
        )

        it("bypasses diff rendering when Edit fails", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "tc-2",
                kind = "edit",
                argument = "/tmp/foo.lua",
                status = "failed",
                diff = {
                    old = { "old content" },
                    new = { "new content" },
                },
                failure_reason = { "Permission denied." },
            }

            local lines, _ = Renderer.prepare_block_lines(block, 0)

            for _, line in ipairs(lines) do
                assert.is_nil(line:match("old content"))
                assert.is_nil(line:match("new content"))
            end
            local found = false
            for _, line in ipairs(lines) do
                if line == "Permission denied." then
                    found = true
                    break
                end
            end
            assert.is_true(found)
        end)

        it(
            "renders execute failure as plain console without red tint",
            function()
                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "tc-exec-1",
                    kind = "execute",
                    argument = "ls /missing",
                    status = "failed",
                    failure_reason = {
                        "ls: /missing: No such file or directory",
                    },
                }

                local lines, ranges = Renderer.prepare_block_lines(block, 0)

                for _, range in ipairs(ranges) do
                    assert.are_not.equal("error", range.type)
                end
                local found = false
                for _, line in ipairs(lines) do
                    if line == "ls: /missing: No such file or directory" then
                        found = true
                        break
                    end
                end
                assert.is_true(found)
            end
        )

        it("does not fold execute failure at the threshold", function()
            local Config = require("agentic.config")
            local reason = {}
            for i = 1, Config.tool_call_display.execute_max_lines do
                table.insert(reason, "err line " .. i)
            end
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "tc-exec-2",
                kind = "execute",
                argument = "make build",
                status = "failed",
                failure_reason = reason,
            }

            local lines, _ = Renderer.prepare_block_lines(block, 0)

            for _, line in ipairs(lines) do
                assert.are_not.equal("{{{", line)
                assert.are_not.equal("}}}", line)
            end
        end)

        it(
            "emits no fold markers even past the fold threshold",
            function()
                local Config = require("agentic.config")
                local reason = {}
                for i = 1, Config.tool_call_display.execute_max_lines + 1 do
                    table.insert(reason, "err line " .. i)
                end
                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "tc-exec-3",
                    kind = "execute",
                    argument = "make build",
                    status = "failed",
                    failure_reason = reason,
                }

                local lines, _ = Renderer.prepare_block_lines(block, 0)

                for _, line in ipairs(lines) do
                    assert.are_not.equal("{{{", line)
                    assert.are_not.equal("}}}", line)
                end
            end
        )

        it("keeps red error highlight on non-execute failures", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "tc-edit-fail",
                kind = "edit",
                argument = "/tmp/foo.lua",
                status = "failed",
                failure_reason = { "Permission denied." },
            }

            local _, ranges = Renderer.prepare_block_lines(block, 0)

            local has_error = false
            for _, range in ipairs(ranges) do
                if range.type == "error" then
                    has_error = true
                    break
                end
            end
            assert.is_true(has_error)
        end)

        it("keeps kind-specific rendering for non-failed status", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "tc-3",
                kind = "read",
                argument = "/tmp/foo.lua",
                status = "completed",
                body = { "line a", "line b", "line c" },
            }

            local lines, _ = Renderer.prepare_block_lines(block, 0)

            local found = false
            for _, line in ipairs(lines) do
                if line == "Read 3 lines" then
                    found = true
                    break
                end
            end
            assert.is_true(found)
        end)
    end)

    describe("no fold markers in rendered output", function()
        --- @param lines string[]
        local function assert_no_markers(lines)
            for _, line in ipairs(lines) do
                assert.are_not.equal("{{{", line)
                assert.are_not.equal("}}}", line)
            end
        end

        it("execute body past the threshold has no markers", function()
            local Config = require("agentic.config")
            local body = {}
            for i = 1, Config.tool_call_display.execute_max_lines + 5 do
                table.insert(body, "out " .. i)
            end
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-fold",
                kind = "execute",
                argument = "ls",
                status = "completed",
                body = body,
            }

            local lines, _ = Renderer.prepare_block_lines(block, 0)
            assert_no_markers(lines)
        end)

        it("search body past the threshold has no markers", function()
            local Config = require("agentic.config")
            local body = {}
            for i = 1, Config.tool_call_display.search_max_lines + 5 do
                table.insert(body, "match " .. i)
            end
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "search-fold",
                kind = "search",
                argument = "rg foo",
                status = "completed",
                body = body,
            }

            local lines, _ = Renderer.prepare_block_lines(block, 0)
            assert_no_markers(lines)
        end)

        it("fetch body has no markers", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "fetch-fold",
                kind = "fetch",
                argument = "https://example.com prompt",
                status = "completed",
                body = { "page content line 1", "page content line 2" },
            }

            local lines, _ = Renderer.prepare_block_lines(block, 0)
            assert_no_markers(lines)
        end)

        it("WebSearch body has no markers", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "websearch-fold",
                kind = "WebSearch",
                argument = "lua tables",
                status = "completed",
                body = { "result snippet" },
            }

            local lines, _ = Renderer.prepare_block_lines(block, 0)
            assert_no_markers(lines)
        end)

        it("SubAgent body has no markers", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "subagent-fold",
                kind = "SubAgent",
                argument = "general-purpose",
                status = "completed",
                body = { "subagent output line" },
            }

            local lines, _ = Renderer.prepare_block_lines(block, 0)
            assert_no_markers(lines)
        end)
    end)

    describe("execute ANSI highlight placement", function()
        --- Find the row of the extmark whose hl_group starts with prefix.
        --- @param bufnr integer
        --- @param prefix string
        --- @return integer|nil row 0-indexed
        local function ansi_extmark_row(bufnr, prefix)
            local ns = vim.api.nvim_get_namespaces()["agentic_diff_highlights"]
            local marks =
                vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
            for _, mark in ipairs(marks) do
                local hl = mark[4] and mark[4].hl_group
                if hl and vim.startswith(hl, prefix) then
                    return mark[2]
                end
            end
            return nil
        end

        it("lands the colour on the content line, not the console fence", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-ansi",
                status = "completed",
                kind = "execute",
                argument = "echo hi",
                body = { "\27[31mred\27[0m green" },
            }

            local lines, highlight_ranges, ansi_highlights =
                Renderer.prepare_block_lines(block, 80)

            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

            Renderer.apply_block_highlights(
                bufnr,
                0,
                #lines,
                "execute",
                highlight_ranges,
                ansi_highlights
            )

            local content_row
            for i, line in ipairs(lines) do
                if line == "red green" then
                    content_row = i - 1
                    break
                end
            end
            assert.is_not_nil(content_row)
            assert.equal(content_row, ansi_extmark_row(bufnr, "AgenticAnsi"))

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)
end)
