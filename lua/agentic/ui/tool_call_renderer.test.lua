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
end)
