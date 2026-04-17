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
            local cap = row0[0]
            assert.is_not_nil(cap)
            --- @cast cap -nil
            assert.is_true(
                cap:match("keyword") ~= nil,
                "expected keyword capture, got " .. tostring(cap)
            )

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it(
            "treats keywords inside a python docstring as string content",
            function()
                if not has_parser("python") then
                    return
                end

                local src = {
                    "def explain():",
                    '    """',
                    "    placeholder",
                    '    """',
                    "    return None",
                }
                local bufnr = make_buf(src, "python")

                local new_lines = {
                    "    for item in items: return item",
                }
                local map = Treesitter.build_highlight_map(
                    bufnr,
                    "python",
                    2,
                    3,
                    new_lines
                )
                assert.is_not_nil(map)
                --- @cast map -nil

                local row0 = map[0] or {}
                -- Column 4 (after the leading spaces) is the `f` of `for`.
                -- Inside the docstring it must map to a content-class
                -- capture (string/spell — Python's grammar marks docstring
                -- content as @spell for spellcheck), not @keyword/@variable.
                local cap = row0[4]
                assert.is_not_nil(cap)
                --- @cast cap -nil
                assert.is_true(
                    cap:match("string") ~= nil or cap:match("spell") ~= nil,
                    "expected string/spell capture, got " .. tostring(cap)
                )

                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )
    end)
end)
