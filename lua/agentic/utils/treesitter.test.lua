local MarkdownConceal = require("tests.helpers.markdown_conceal")
local Treesitter = require("agentic.utils.treesitter")
local ZshParseGuard = require("agentic.utils.zsh_parse_guard")
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

--- Check whether a parser for `lang` is installed. Skips tests otherwise.
--- @param lang string
--- @return boolean
local function has_parser(lang)
    return pcall(vim.treesitter.language.add, lang)
end

describe("Treesitter", function()
    describe("strip_conceal_lines", function()
        it("removes conceal_lines directives in both forms", function()
            local text = table.concat({
                '((a) @x (#set! conceal "") (#set! conceal_lines ""))',
                '((b) @y (#set! @y conceal_lines ""))',
                "((c) @z (#set! priority 1))",
            }, "\n")
            assert.equal(
                table.concat({
                    '((a) @x (#set! conceal "") )',
                    "((b) @y )",
                    "((c) @z (#set! priority 1))",
                }, "\n"),
                Treesitter.strip_conceal_lines(text)
            )
        end)

        it("leaves a markdown query with no conceal_lines", function()
            local text = table.concat(
                vim.tbl_map(function(path)
                    return table.concat(vim.fn.readfile(path), "\n")
                end, vim.treesitter.query.get_files(
                    "markdown",
                    "highlights"
                )),
                "\n"
            )
            assert.is_true(
                vim.treesitter.query.parse("markdown", text).has_conceal_line
            )
            local stripped = vim.treesitter.query.parse(
                "markdown",
                Treesitter.strip_conceal_lines(text)
            )
            assert.is_false(stripped.has_conceal_line == true)
        end)
    end)

    describe("resolve_lang", function()
        it("lowercases the name", function()
            assert.equal("markdown", Treesitter.resolve_lang("Markdown"))
        end)

        it("resolves a filetype registered to a language", function()
            assert.is_nil(Treesitter.resolve_lang("pandoc"))
            vim.treesitter.language.register("markdown", "pandoc")
            assert.equal("markdown", Treesitter.resolve_lang("pandoc"))
        end)

        it("is nil for a name with no parser", function()
            assert.is_nil(Treesitter.resolve_lang("md"))
            assert.is_nil(Treesitter.resolve_lang(""))
        end)

        it("keeps a language name", function()
            if not has_parser("zsh") then
                return
            end
            assert.equal("zsh", Treesitter.resolve_lang("zsh"))
        end)
    end)

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

        describe("with a zsh hang trigger in the file", function()
            local trigger = "${x//[^)]}"
            local get_string_parser = vim.treesitter.get_string_parser
            --- @type TestStub
            local parser_stub

            -- A trigger that reaches the parser hangs this process, which
            -- has no timeout. Fail the case instead.
            before_each(function()
                parser_stub = spy.stub(vim.treesitter, "get_string_parser")
                parser_stub:invokes(function(source, ...)
                    if ZshParseGuard.contains_hang_trigger(source) then
                        error("hang trigger reached the parser")
                    end
                    return get_string_parser(source, ...)
                end)
            end)

            after_each(function()
                parser_stub:revert()
            end)

            it("highlights rows below a trigger on a context row", function()
                if not has_parser("lua") then
                    return
                end

                local map = Treesitter.highlight_map_in_context(
                    { 'local s = "' .. trigger .. '"', "local y = 1" },
                    "lua",
                    1,
                    2,
                    { "local z = 2" }
                )
                assert.is_not_nil(map)
            end)

            it("highlights a trigger on the target row in place", function()
                if not has_parser("lua") then
                    return
                end

                local line = 'local s = "' .. trigger .. '"'
                local map = Treesitter.highlight_map_in_context(
                    { line },
                    "lua",
                    0,
                    1,
                    { line }
                )
                assert.is_not_nil(map)
                --- @cast map -nil

                local cap = (map[0] or {})[line:find("$", 1, true) - 1]
                assert.is_true(
                    cap ~= nil and cap:match("string") ~= nil,
                    "expected string capture, got " .. tostring(cap)
                )
            end)

            it("highlights a zsh file that holds a trigger", function()
                if not has_parser("zsh") then
                    return
                end

                local map = Treesitter.highlight_map_in_context(
                    { "c=" .. trigger, "echo hi" },
                    "zsh",
                    1,
                    2,
                    { "echo bye" }
                )
                assert.is_not_nil(map)
            end)
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

    describe("string_highlight_trees", function()
        it("returns nothing without a parser for the language", function()
            assert.same(
                {},
                Treesitter.string_highlight_trees("text", "no_such_lang")
            )
        end)

        it("returns the root tree with its highlights query", function()
            local trees =
                Treesitter.string_highlight_trees("[a](b)", "markdown_inline")
            assert.equal(1, #trees)
            assert.equal("inline", trees[1].root:type())
        end)
    end)

    describe("concealed_width", function()
        local restore

        before_each(function()
            restore = MarkdownConceal.pin()
        end)

        after_each(function()
            restore()
        end)

        local CELLS = {
            "**bold**",
            "[txt](http://x.y)",
            "&lt;x&gt;",
            "\\*esc",
            "`code`",
            "_em_",
            "~~st~~",
            "![alt](i.png)",
            "[txt][ref]",
            "***bi***",
            "plain",
        }

        --- Width of each of `CELLS` at a conceallevel.
        --- @param conceallevel integer
        --- @return integer[]
        local function widths(conceallevel)
            return vim.tbl_map(function(cell)
                return Treesitter.concealed_width(
                    cell,
                    "markdown_inline",
                    conceallevel
                )
            end, CELLS)
        end

        it("counts every byte at level 0", function()
            assert.same(vim.tbl_map(vim.api.nvim_strwidth, CELLS), widths(0))
        end)

        it("counts one cell per concealed node at level 1", function()
            assert.same({ 8, 8, 3, 5, 6, 4, 6, 9, 6, 8, 5 }, widths(1))
        end)

        it("hides empty conceals and keeps replacements at level 2", function()
            assert.same({ 4, 3, 3, 5, 4, 2, 2, 3, 3, 2, 5 }, widths(2))
        end)

        it("hides every concealed byte at level 3", function()
            assert.same({ 4, 3, 1, 4, 4, 2, 2, 3, 3, 2, 5 }, widths(3))
        end)

        it("counts the shown text at level 2", function()
            local shown = {
                { "__init__", "init" },
                { "[x]", "x" },
                { '[t](u "ti")', 't "ti"' },
                { "&amp;", "&" },
                { "snake_case", "snake_case" },
                { "*.lua, *.md", "*.lua, *.md" },
                { "2 * 3 * 4", "2 * 3 * 4" },
                { "\\_x\\_", "\\_x\\_" },
                { "日本", "日本" },
            }
            for _, pair in ipairs(shown) do
                assert.equal(
                    vim.api.nvim_strwidth(pair[2]),
                    Treesitter.concealed_width(pair[1], "markdown_inline", 2)
                )
            end
        end)

        it("counts the text unchanged without a parser", function()
            assert.equal(
                4,
                Treesitter.concealed_width("**a*", "no_such_lang", 2)
            )
        end)
    end)

    describe("code_block_rows", function()
        --- Rows `first..last` of `lines` that `code_block_rows` covers, sorted.
        --- @param lines string[]
        --- @param first integer|nil 0-indexed, default 0
        --- @param last integer|nil 0-indexed, default the last row
        --- @return integer[]
        local function covered(lines, first, last)
            local parser = vim.treesitter.get_string_parser(
                table.concat(lines, "\n"),
                "markdown"
            )
            parser:parse()
            first = first or 0
            local rows = vim.tbl_map(
                function(offset)
                    return first + offset - 1
                end,
                vim.tbl_keys(
                    Treesitter.code_block_rows(
                        parser,
                        first,
                        last or #lines - 1
                    )
                )
            )
            table.sort(rows)
            return rows
        end

        it("covers a block holding a shorter fence row", function()
            assert.same(
                { 1, 2, 3, 4, 5 },
                covered({ "a", "````text", "```", "x", "```", "````", "b" })
            )
        end)

        it("covers a tilde fence", function()
            assert.same({ 1, 2, 3 }, covered({ "a", "~~~", "x", "~~~", "b" }))
        end)

        it("covers a fence indented 2", function()
            assert.same(
                { 1, 2, 3 },
                covered({ "a", "  ```lua", "  x", "  ```", "b" })
            )
        end)

        it("covers a fence under a nested list item indented 4", function()
            assert.same(
                { 4, 5, 6 },
                covered({
                    "- a",
                    "",
                    "  - b",
                    "",
                    "    ```lua",
                    "    x",
                    "    ```",
                })
            )
        end)

        it("covers an unclosed block to the end", function()
            assert.same({ 1, 2, 3 }, covered({ "a", "```lua", "x", "y" }))
        end)

        it("covers nothing in prose", function()
            assert.same({}, covered({ "a", "", "b" }))
        end)

        it("covers only the window inside a block", function()
            assert.same(
                { 2, 3 },
                covered({ "a", "```", "x", "y", "z", "```" }, 2, 3)
            )
        end)
    end)
end)
