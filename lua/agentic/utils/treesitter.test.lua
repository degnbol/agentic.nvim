local Treesitter = require("agentic.utils.treesitter")
local assert = require("tests.helpers.assert")

--- Create a scratch buffer with the given lines and filetype.
--- @param lines string[]
--- @param filetype string
--- @return integer bufnr
local function make_buf(lines, filetype)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = filetype
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, filetype)
    if ok and parser then
        parser:parse(true)
    end
    return bufnr
end

--- Check whether a parser for `lang` is installed. Skips tests otherwise.
--- @param lang string
--- @return boolean
local function has_parser(lang)
    return pcall(vim.treesitter.language.add, lang)
end

describe("Treesitter", function()
    describe("top_level_ancestor", function()
        it("returns direct child of root for a deeply nested node", function()
            if not has_parser("python") then
                return
            end

            local src = {
                "def foo():",
                "    x = 1",
                "    return x",
            }
            local bufnr = make_buf(src, "python")
            local parser = vim.treesitter.get_parser(bufnr, "python")
            local trees = parser:parse()
            local root = trees[1]:root()
            local inner = root:named_descendant_for_range(2, 11, 2, 12)
            assert.is_not_nil(inner)

            local top = Treesitter.top_level_ancestor(inner, root)
            local s, _, _, _ = top:range()
            assert.equal(0, s)
            assert.equal("function_definition", top:type())

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("get_context_range", function()
        it("returns nil when no parser available", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
            local s, e =
                Treesitter.get_context_range(bufnr, "nonexistent_lang", 0, 1)
            assert.is_nil(s)
            assert.is_nil(e)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("spans the full function containing the edit", function()
            if not has_parser("python") then
                return
            end

            local src = {
                "def foo():",
                "    x = 1",
                "    y = 2",
                "    return x + y",
                "",
                "def bar():",
                "    pass",
            }
            local bufnr = make_buf(src, "python")

            -- Edit targets row 2 (y = 2). Context should be the full foo() def.
            local ctx_start, ctx_end =
                Treesitter.get_context_range(bufnr, "python", 2, 3)
            assert.equal(0, ctx_start)
            assert.is_true((ctx_end or 0) >= 4)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("build_highlight_map", function()
        it("returns nil when no parser is installed", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
            local map = Treesitter.build_highlight_map(
                bufnr,
                "nonexistent_lang",
                0,
                1,
                { "x" }
            )
            assert.is_nil(map)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it(
            "treats keywords inside a multi-line string as string content",
            function()
                if not has_parser("lua") then
                    return
                end

                -- A module with a multi-line string; we splice `for_helper = 1`
                -- inside the [[ ]] block. The keyword `for` would normally be
                -- `@keyword.lua` but inside a string it must be `@string.lua`.
                local src = {
                    "local M = {}",
                    "M.doc = [[",
                    "placeholder",
                    "]]",
                    "return M",
                }
                local bufnr = make_buf(src, "lua")

                local new_lines = { "for_helper = 1" }
                local map = Treesitter.build_highlight_map(
                    bufnr,
                    "lua",
                    2,
                    3,
                    new_lines
                )
                assert.is_not_nil(map)
                --- @cast map -nil

                local row0 = map[0] or {}
                -- Column 0 corresponds to `f` of `for_helper`. Inside the
                -- multi-line string it should map to a string-ish capture.
                local cap = row0[0]
                assert.is_not_nil(cap)
                --- @cast cap -nil
                assert.is_true(
                    cap:match("string") ~= nil,
                    "expected string capture, got " .. tostring(cap)
                )

                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )

        it("highlights real code outside strings as code", function()
            if not has_parser("lua") then
                return
            end

            local src = {
                "local M = {}",
                "return M",
            }
            local bufnr = make_buf(src, "lua")

            local new_lines = { "local x = 1" }
            local map =
                Treesitter.build_highlight_map(bufnr, "lua", 1, 1, new_lines)
            assert.is_not_nil(map)
            --- @cast map -nil

            local row0 = map[0] or {}
            -- Column 0 is `l` of `local` — should map to a keyword capture.
            local cap = row0[0]
            assert.is_not_nil(cap)
            --- @cast cap -nil
            assert.is_true(
                cap:match("keyword") ~= nil,
                "expected keyword capture, got " .. tostring(cap)
            )

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)
end)
