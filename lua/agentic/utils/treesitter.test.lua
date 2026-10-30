local Treesitter = require("agentic.utils.treesitter")
local assert = require("tests.helpers.assert")

--- Check whether a parser for `lang` is installed. Skips tests otherwise.
--- @param lang string
--- @return boolean
local function has_parser(lang)
    return pcall(vim.treesitter.language.add, lang)
end

describe("Treesitter", function()
    describe("language_for_path", function()
        it("maps a known extension to its parser name", function()
            assert.equal(Treesitter.language_for_path("foo.py"), "python")
        end)

        it("passes through extensions whose name is the parser name", function()
            assert.equal(Treesitter.language_for_path("foo.lua"), "lua")
            assert.equal(Treesitter.language_for_path("foo.md"), "markdown")
        end)

        it("detects special filenames with no extension", function()
            assert.equal(Treesitter.language_for_path("justfile"), "just")
        end)

        it("returns empty string for an unrecognised file", function()
            assert.equal(Treesitter.language_for_path("script_no_ext"), "")
        end)

        -- A filetype whose parser name differs from it (sh -> bash) resolves
        -- only via a registered filetype<->parser mapping, which nvim-treesitter
        -- installs but bare Neovim does not. Register it here to prove the
        -- function honours registrations rather than a hand-rolled table.
        it("honours a registered filetype-to-parser mapping", function()
            vim.treesitter.language.register("bash", "sh")
            assert.equal(Treesitter.language_for_path("foo.sh"), "bash")
        end)

        it(
            "falls back to contents for content-defined extensionless files",
            function()
                assert.equal(
                    Treesitter.language_for_path(
                        "_brew",
                        { "#compdef brew", "local x" }
                    ),
                    "zsh"
                )
            end
        )

        it("still returns empty when contents are omitted", function()
            assert.equal(Treesitter.language_for_path("_brew"), "")
        end)

        it("prefers extension over a misleading content line", function()
            assert.equal(
                Treesitter.language_for_path("foo.lua", { "#compdef x" }),
                "lua"
            )
        end)
    end)

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

        it("colours rows inside an injection that opens above them", function()
            if not has_parser("lua") or not has_parser("vim") then
                return
            end

            local file_lines = {
                "vim.cmd([[",
                "set number",
                "placeholder",
                "]])",
            }

            local map = Treesitter.highlight_map_in_context(
                file_lines,
                "lua",
                2,
                3,
                { "set nowrap" }
            )
            assert.is_not_nil(map)
            --- @cast map -nil

            local vim_caps = vim.tbl_filter(function(cap)
                return cap:match("%.vim$") ~= nil
            end, vim.tbl_values(map[0] or {}))
            assert.is_true(
                #vim_caps > 0,
                "expected a capture from the vim injection, got "
                    .. vim.inspect(map[0])
            )
        end)
    end)

    describe("conceal_ranges", function()
        local bufnr

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
        end)

        after_each(function()
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        --- Start the markdown highlighter on the buffer and parse it whole.
        local function highlight()
            vim.treesitter.start(bufnr, "markdown")
            vim.treesitter.get_parser(bufnr):parse(true)
        end

        --- Conceal ranges of the buffer's highlighter on rows srow..erow-1.
        --- @param srow integer
        --- @param erow integer exclusive
        --- @return agentic.utils.Conceal.Range[]
        local function conceal(srow, erow)
            return Treesitter.conceal_ranges(
                bufnr,
                Treesitter.highlight_trees(bufnr, srow, erow),
                srow,
                erow
            )
        end

        --- @param ranges agentic.utils.Conceal.Range[]
        --- @return integer[][] positions row, col and end_col of each range
        local function positions(ranges)
            return vim.tbl_map(function(range)
                return { range.row, range.col, range.end_col }
            end, ranges)
        end

        it(
            "returns link conceals in table cells and blockquotes in buffer columns",
            function()
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                    "| a | b |",
                    "| - | - |",
                    "| [x](u) | y |",
                    "",
                    "> see [lab",
                    "> el](url) end",
                })
                highlight()

                assert.same({
                    { 2, 2, 3 },
                    { 2, 4, 5 },
                    { 2, 5, 6 },
                    { 2, 6, 7 },
                    { 2, 7, 8 },
                    { 4, 6, 7 },
                    { 5, 4, 5 },
                    { 5, 5, 6 },
                    { 5, 6, 9 },
                    { 5, 9, 10 },
                }, positions(conceal(0, 6)))
            end
        )

        it("returns only ranges on the requested rows", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "[a](b)",
                "[c](d)",
            })
            highlight()

            local ranges = conceal(1, 2)
            local rows = vim.tbl_map(function(range)
                return range.row
            end, ranges)
            assert.same({ 1, 1, 1, 1, 1 }, rows)
            assert.same({
                row = 1,
                col = 0,
                end_col = 1,
                text = "",
                priority = vim.hl.priorities.treesitter,
                starts_on_row = true,
            }, ranges[1])
        end)

        it("returns only ranges of the given trees", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "[a](b)" })
            highlight()
            assert.same({}, Treesitter.conceal_ranges(bufnr, {}, 0, 1))
        end)
    end)

    describe("highlight_trees", function()
        local bufnr

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "[a](b)",
                "",
                "text",
            })
        end)

        after_each(function()
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("returns the root tree and injected trees on the rows", function()
            vim.treesitter.start(bufnr, "markdown")
            vim.treesitter.get_parser(bufnr):parse(true)
            local trees = Treesitter.highlight_trees(bufnr, 0, 1)
            assert.same(
                { 0, 0 },
                vim.tbl_map(function(tree)
                    return tree.start_row
                end, trees)
            )
        end)

        it("returns nothing for a buffer without a highlighter", function()
            assert.same({}, Treesitter.highlight_trees(bufnr, 0, 1))
        end)

        it("returns nothing when only a parser exists", function()
            vim.treesitter.get_parser(bufnr, "markdown"):parse(true)
            assert.same({}, Treesitter.highlight_trees(bufnr, 0, 1))
        end)
    end)
end)
