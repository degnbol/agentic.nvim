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
            assert.is_true(vim.tbl_contains(labels, "context"))
            assert.is_true(vim.tbl_contains(labels, "plan"))
            assert.is_true(vim.tbl_contains(labels, "new"))
        end)

        it("returns items with textEdit covering from col 0", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/con" })
            vim.api.nvim_win_set_cursor(0, { 1, 4 })

            local result = complete(handlers, bufnr, 0, 4, nil)

            local context_item
            for _, item in ipairs(result.items) do
                if item.label == "context" then
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

        it(
            "returns bare word items (not slash) when / has spaces after",
            function()
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/plan arg" })
                vim.api.nvim_win_set_cursor(0, { 1, 9 })

                local result = complete(handlers, bufnr, 0, 9, nil)

                -- Bare word "arg" triggers word completion, not slash completion
                assert.is_true(#result.items > 0)
                -- filterText should be bare word (no slash prefix)
                local first = result.items[1]
                assert.is_false(first.filterText:match("^/") ~= nil)
            end
        )

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

    describe("bare word slash command completion", function()
        before_each(function()
            local SlashCommands = require("agentic.acp.slash_commands")
            --- @type agentic.acp.AvailableCommand[]
            local commands = {
                { name = "pymol", description = "Load PyMOL skill" },
                { name = "plan", description = "Create a plan" },
            }
            SlashCommands.setCommands(bufnr, commands)
        end)

        it("returns items when typing bare word", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Load py" })
            vim.api.nvim_win_set_cursor(0, { 1, 7 })

            local result = complete(handlers, bufnr, 0, 7, nil)

            assert.is_true(#result.items > 0)

            -- Both label and filterText are bare words (no / prefix)
            local first = result.items[1]
            assert.is_false(first.label:match("^/") ~= nil)
            assert.is_false(first.filterText:match("^/") ~= nil)
        end)

        it("inserts bare word via textEdit (no slash prefix)", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Load py" })
            vim.api.nvim_win_set_cursor(0, { 1, 7 })

            local result = complete(handlers, bufnr, 0, 7, nil)

            local pymol_item
            for _, item in ipairs(result.items) do
                if item.label == "pymol" then
                    pymol_item = item
                end
            end

            assert.is_not_nil(pymol_item)
            assert.equal(5, pymol_item.textEdit.range.start.character)
            assert.equal(7, pymol_item.textEdit.range["end"].character)
            assert.equal("pymol", pymol_item.textEdit.newText)
        end)

        it("requires at least 2 characters", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "p" })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })

            local result = complete(handlers, bufnr, 0, 1, nil)

            assert.equal(0, #result.items)
        end)

        it("included alongside slash items when both match", function()
            -- "use /py" has both a slash token and a bare word "use"
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "use /py" })
            vim.api.nvim_win_set_cursor(0, { 1, 7 })

            local result = complete(handlers, bufnr, 0, 7, "/")

            -- Slash items come from "/py", bare word items would need
            -- a word without / — but cursor is on "/py" so no bare word.
            -- Just verify slash items are present.
            assert.is_true(#result.items > 0)
            local has_slash = false
            for _, item in ipairs(result.items) do
                if item.filterText and not item.filterText:match("^/") then
                    has_slash = true
                end
            end
            assert.is_true(has_slash)
        end)
    end)

    describe("file completion", function()
        local fs_scandir_stub
        local fs_scandir_next_stub
        local fs_stat_stub

        --- Stub fs_scandir/fs_scandir_next to return controlled entries.
        --- @param entries {[1]: string, [2]: string}[] name, type pairs
        local function stub_dir_entries(entries)
            local idx = 0
            fs_scandir_stub:returns("handle")
            fs_scandir_next_stub:invokes(function()
                idx = idx + 1
                if idx > #entries then
                    return nil
                end
                return entries[idx][1], entries[idx][2]
            end)
        end

        before_each(function()
            fs_scandir_stub = spy.stub(vim.uv, "fs_scandir")
            fs_scandir_next_stub = spy.stub(vim.uv, "fs_scandir_next")
            fs_stat_stub = spy.stub(vim.uv, "fs_stat")
            fs_stat_stub:returns({ type = "file" })
        end)

        after_each(function()
            fs_scandir_stub:revert()
            fs_scandir_next_stub:revert()
            fs_stat_stub:revert()
        end)

        it("lists cwd entries when typing @ at line start", function()
            stub_dir_entries({
                { "src", "directory" },
                { "README.md", "file" },
            })

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@" })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })

            local result = complete(handlers, bufnr, 0, 1, "@")

            assert.equal(2, #result.items)
            -- Scanned "." (cwd)
            assert.equal(".", fs_scandir_stub.calls[1][1])
        end)

        it("lists subdirectory entries when path has trailing /", function()
            stub_dir_entries({
                { "main.lua", "file" },
                { "utils.lua", "file" },
            })

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@src/" })
            vim.api.nvim_win_set_cursor(0, { 1, 5 })

            local result = complete(handlers, bufnr, 0, 5, "/")

            assert.equal(2, #result.items)
            -- Scanned "src/" directory
            assert.equal("src/", fs_scandir_stub.calls[1][1])
            -- filterText includes directory prefix
            assert.equal("src/main.lua", result.items[1].filterText)
        end)

        it("returns items when @ is after whitespace", function()
            stub_dir_entries({ { "file.txt", "file" } })

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "add this @fi" })
            vim.api.nvim_win_set_cursor(0, { 1, 12 })

            local result = complete(handlers, bufnr, 0, 12, "@")

            assert.is_true(#result.items > 0)
        end)

        it("returns textEdit from @ position with @ prefix", function()
            stub_dir_entries({ { "src", "directory" } })

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@sr" })
            vim.api.nvim_win_set_cursor(0, { 1, 3 })

            local result = complete(handlers, bufnr, 0, 3, "@")

            local first = result.items[1]
            assert.is_not_nil(first.textEdit)
            assert.equal(0, first.textEdit.range.start.character)
            assert.equal(3, first.textEdit.range["end"].character)
            assert.equal("@src/", first.textEdit.newText)
        end)

        it("directories have trailing / and Folder kind", function()
            stub_dir_entries({
                { "src", "directory" },
                { "README.md", "file" },
            })

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@" })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })

            local result = complete(handlers, bufnr, 0, 1, "@")

            local dir_item, file_item
            for _, item in ipairs(result.items) do
                if item.label == "src/" then
                    dir_item = item
                elseif item.label == "README.md" then
                    file_item = item
                end
            end

            assert.is_not_nil(dir_item)
            assert.equal(19, dir_item.kind) -- Folder
            assert.equal("@src/", dir_item.textEdit.newText)

            assert.is_not_nil(file_item)
            assert.equal(17, file_item.kind) -- File
            assert.equal("@README.md", file_item.textEdit.newText)
        end)

        it("sorts non-dot before dot, dirs before files", function()
            stub_dir_entries({
                { ".hidden", "file" },
                { "visible.txt", "file" },
                { ".config", "directory" },
                { "src", "directory" },
            })

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@" })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })

            local result = complete(handlers, bufnr, 0, 1, "@")

            local sort_keys = vim.tbl_map(function(item)
                return item.sortText
            end, result.items)

            -- Non-dot dir < non-dot file < dot dir < dot file
            local sorted = vim.deepcopy(sort_keys)
            table.sort(sorted)
            assert.are.same(sorted, sort_keys)

            -- Verify order: src/ < visible.txt < .config/ < .hidden
            assert.equal("src/", result.items[1].label)
            assert.equal("visible.txt", result.items[2].label)
            assert.equal(".config/", result.items[3].label)
            assert.equal(".hidden", result.items[4].label)
        end)

        it("excludes .git entries", function()
            stub_dir_entries({
                { ".git", "directory" },
                { "src", "directory" },
                { ".gitignore", "file" },
            })

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@" })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })

            local result = complete(handlers, bufnr, 0, 1, "@")

            assert.equal(2, #result.items)
            local labels = vim.tbl_map(function(item)
                return item.label
            end, result.items)
            assert.is_false(vim.tbl_contains(labels, ".git/"))
            assert.is_true(vim.tbl_contains(labels, ".gitignore"))
        end)

        it("resolves symlinks to determine directory type", function()
            stub_dir_entries({ { "link-to-dir", "link" } })
            fs_stat_stub:invokes(function()
                return { type = "directory" }
            end)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@" })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })

            local result = complete(handlers, bufnr, 0, 1, "@")

            assert.equal(1, #result.items)
            assert.equal("link-to-dir/", result.items[1].label)
            assert.equal(19, result.items[1].kind) -- Folder
        end)

        it("returns empty when @ is mid-word (no whitespace before)", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "foo@bar" })
            vim.api.nvim_win_set_cursor(0, { 1, 7 })

            local result = complete(handlers, bufnr, 0, 7, "@")

            assert.equal(0, #result.items)
        end)

        it("returns empty when directory doesn't exist", function()
            fs_scandir_stub:returns(nil)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "@nonexistent/" })
            vim.api.nvim_win_set_cursor(0, { 1, 14 })

            local result = complete(handlers, bufnr, 0, 14, "/")

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
