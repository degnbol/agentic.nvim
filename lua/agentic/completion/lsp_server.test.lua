local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local LspServer = require("agentic.completion.lsp_server")

--- Helper: call the textDocument/completion handler directly
--- @param handlers table LSP handlers from _make_handlers()
--- @param bufnr integer
--- @param line integer 0-indexed line
--- @param col integer 0-indexed column
--- @param trigger_char string|nil
--- @return table response { isIncomplete, items }
local function complete(handlers, bufnr, line, col, trigger_char)
    -- Set current buffer so the handler reads from the right one
    vim.api.nvim_set_current_buf(bufnr)

    local result
    handlers.request("textDocument/completion", {
        position = { line = line, character = col },
        context = trigger_char and { triggerCharacter = trigger_char } or nil,
    }, function(_err, res)
        result = res
    end)
    return result
end

describe("agentic.completion.LspServer", function()
    --- @type integer
    local bufnr
    local handlers

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_set_current_buf(bufnr)
        handlers = LspServer._make_handlers()
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("initialize", function()
        it("returns completionProvider capabilities", function()
            local result
            handlers.request("initialize", {}, function(_err, res)
                result = res
            end)

            assert.is_not_nil(result)
            assert.is_not_nil(result.capabilities.completionProvider)

            local provider = result.capabilities.completionProvider
            assert.are.same({ "/", "@" }, provider.triggerCharacters)
            assert.is_false(provider.resolveProvider)
        end)
    end)

    describe("slash command completion", function()
        before_each(function()
            local SlashCommands = require("agentic.acp.slash_commands")
            --- @type agentic.acp.AvailableCommand[]
            local commands = {
                { name = "context", description = "Show context usage" },
                { name = "plan", description = "Create a plan" },
            }
            SlashCommands.setCommands(bufnr, commands)
        end)

        it("returns items when typing / on first line", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/c" })
            vim.api.nvim_win_set_cursor(0, { 1, 2 })

            local result = complete(handlers, bufnr, 0, 2, "/")

            assert.is_not_nil(result)
            assert.is_true(#result.items > 0)

            -- Should include /context, /plan, and /new (auto-added)
            local labels = vim.tbl_map(function(item)
                return item.label
            end, result.items)
            assert.is_true(vim.tbl_contains(labels, "/context"))
            assert.is_true(vim.tbl_contains(labels, "/plan"))
            assert.is_true(vim.tbl_contains(labels, "/new"))
        end)

        it("returns items with textEdit covering from col 0", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/con" })
            vim.api.nvim_win_set_cursor(0, { 1, 4 })

            local result = complete(handlers, bufnr, 0, 4, nil)

            local context_item
            for _, item in ipairs(result.items) do
                if item.label == "/context" then
                    context_item = item
                end
            end

            assert.is_not_nil(context_item)
            assert.equal(0, context_item.textEdit.range.start.character)
            assert.equal(4, context_item.textEdit.range["end"].character)
            assert.equal("/context", context_item.textEdit.newText)
        end)

        it("returns items when typing / on line 2", function()
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "first line", "/p" }
            )
            vim.api.nvim_win_set_cursor(0, { 2, 2 })

            local result = complete(handlers, bufnr, 1, 2, "/")

            assert.is_true(#result.items > 0)

            -- textEdit should cover the / on line 1 (0-indexed)
            local first = result.items[1]
            assert.equal(1, first.textEdit.range.start.line)
            assert.equal(0, first.textEdit.range.start.character)
        end)

        it("returns items when / is after whitespace mid-line", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Load /py" })
            vim.api.nvim_win_set_cursor(0, { 1, 8 })

            local result = complete(handlers, bufnr, 0, 8, nil)

            assert.is_true(#result.items > 0)

            -- textEdit should cover from the / position
            local first = result.items[1]
            assert.equal(5, first.textEdit.range.start.character)
            assert.equal(8, first.textEdit.range["end"].character)
        end)

        it("returns empty items when / has spaces after it", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/plan arg" })
            vim.api.nvim_win_set_cursor(0, { 1, 9 })

            local result = complete(handlers, bufnr, 0, 9, nil)

            assert.equal(0, #result.items)
        end)

        it("returns empty items when no commands stored", function()
            -- Use a fresh buffer with no commands
            local buf2 = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_set_current_buf(buf2)
            vim.api.nvim_buf_set_lines(buf2, 0, -1, false, { "/p" })
            vim.api.nvim_win_set_cursor(0, { 1, 2 })

            local result = complete(handlers, buf2, 0, 2, "/")

            assert.equal(0, #result.items)

            vim.api.nvim_buf_delete(buf2, { force = true })
        end)
    end)

    describe("file completion", function()
        local file_picker_stub

        before_each(function()
            local FilePicker = require("agentic.ui.file_picker")
            file_picker_stub = spy.stub(FilePicker, "get_files")
            file_picker_stub:returns({
                { path = "src/main.lua" },
                { path = "src/utils.lua" },
                { path = "README.md" },
            })
        end)

        after_each(function()
            file_picker_stub:revert()
        end)

        it("returns file items when typing @ at line start", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@sr" })
            vim.api.nvim_win_set_cursor(0, { 1, 3 })

            local result = complete(handlers, bufnr, 0, 3, "@")

            assert.is_true(#result.items > 0)
            assert.equal(3, #result.items)
        end)

        it("returns file items when @ is after whitespace", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "add this @sr" })
            vim.api.nvim_win_set_cursor(0, { 1, 12 })

            local result = complete(handlers, bufnr, 0, 12, "@")

            assert.is_true(#result.items > 0)
        end)

        it("returns items with textEdit from @ position", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@src" })
            vim.api.nvim_win_set_cursor(0, { 1, 4 })

            local result = complete(handlers, bufnr, 0, 4, "@")

            local first = result.items[1]
            assert.is_not_nil(first.textEdit)
            assert.equal(0, first.textEdit.range.start.character) -- @ is at col 0
            assert.equal(4, first.textEdit.range["end"].character)
            -- newText includes @ prefix and trailing space
            assert.is_true(first.textEdit.newText:match("^@.*%s$") ~= nil)
        end)

        it("returns empty when @ is mid-word (no whitespace before)", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "foo@bar" })
            vim.api.nvim_win_set_cursor(0, { 1, 7 })

            local result = complete(handlers, bufnr, 0, 7, "@")

            assert.equal(0, #result.items)
        end)

        it("returns empty when file picker returns no files", function()
            file_picker_stub:returns({})

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@sr" })
            vim.api.nvim_win_set_cursor(0, { 1, 3 })

            local result = complete(handlers, bufnr, 0, 3, "@")

            assert.equal(0, #result.items)
        end)
    end)

    describe("shutdown", function()
        it("responds without error", function()
            local called = false
            handlers.request("shutdown", {}, function(err, _res)
                called = true
                assert.is_nil(err)
            end)
            assert.is_true(called)
        end)
    end)
end)
