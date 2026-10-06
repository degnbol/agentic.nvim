local Treesitter = require("agentic.utils.treesitter")
local assert = require("tests.helpers.assert")

--- Check whether a parser for `lang` is installed. Skips tests otherwise.
--- @param lang string
--- @return boolean
local function has_parser(lang)
    return pcall(vim.treesitter.language.add, lang)
end

describe("Treesitter", function()
    describe("highlight_map_in_context", function()
        it("returns nil when no parser is installed", function()
            local map = Treesitter.highlight_map_in_context(
                { "hello" },
                "nonexistent_lang",
                0,
                1,
                { "x" }
            )
            assert.is_nil(map)
        end)

        it(
            "treats keywords inside a multi-line string as string content",
            function()
                if not has_parser("lua") then
                    return
                end

                local file_lines = {
                    "local M = {}",
                    "M.doc = [[",
                    "placeholder",
                    "]]",
                    "return M",
                }

                local map = Treesitter.highlight_map_in_context(
                    file_lines,
                    "lua",
                    2,
                    3,
                    { "for_helper = 1" }
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
            end
        )

        it("highlights real code outside strings as code", function()
            if not has_parser("lua") then
                return
            end

            local map = Treesitter.highlight_map_in_context(
                { "local M = {}", "return M" },
                "lua",
                1,
                1,
                { "local x = 1" }
            )
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
        end)

        it(
            "treats keywords inside a python docstring as string content",
            function()
                if not has_parser("python") then
                    return
                end

                local file_lines = {
                    "def explain():",
                    '    """',
                    "    placeholder",
                    '    """',
                    "    return None",
                }

                local map = Treesitter.highlight_map_in_context(
                    file_lines,
                    "python",
                    2,
                    3,
                    { "    for item in items: return item" }
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
            end
        )
    end)
end)
