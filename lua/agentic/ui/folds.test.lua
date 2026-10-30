local assert = require("tests.helpers.assert")
local NS_CHAR_COUNT = require("agentic.ui.folds").NS_CHAR_COUNT

describe("agentic.ui.folds", function()
    --- @type number
    local bufnr
    --- @type number
    local winid

    before_each(function()
        -- The chat buffer parses as the private `agentic` clone of markdown so
        -- queries/agentic/ applies to it alone; Bootstrap.ensure registers it
        -- for the first session, and nothing in this file starts one.
        local md = vim.api.nvim_get_runtime_file("parser/markdown.so", false)[1]
        assert.is_not_nil(md)
        vim.treesitter.language.add("agentic", {
            path = md,
            symbol_name = "markdown",
        })
        vim.treesitter.language.register("agentic", "AgenticChat")

        bufnr = vim.api.nvim_create_buf(false, true)
        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 60,
            height = 20,
            row = 0,
            col = 0,
        })
    end)

    after_each(function()
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @param n integer
    local function fill_lines(n)
        local lines = {}
        for i = 1, n do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    end

    --- Render `lines` as a chat buffer and return its `Folds.levels`.
    --- @param lines string[]
    --- @return string[] levels
    --- @return table<integer, true> joined
    local function levels_of(lines)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.bo[bufnr].filetype = "AgenticChat"
        vim.treesitter.start(bufnr)
        return require("agentic.ui.folds").levels(bufnr)
    end

    describe("levels", function()
        it("folds the body of a `-fold` fence, not its delimiters", function()
            local levels = levels_of({
                "### block",
                "```console-fold",
                "out 1",
                "out 2",
                "out 3",
                "```",
                "after",
            })

            assert.same({ "0", "0", ">1", "1", "1", "0", "0" }, levels)
        end)

        it("folds a `-difffold` fence the same way", function()
            local levels = levels_of({
                "```lua-difffold",
                "local a = 1",
                "local b = 2",
                "```",
            })

            assert.same({ "0", ">1", "1", "0" }, levels)
        end)

        it("leaves an unmarked fence unfolded", function()
            local levels = levels_of({
                "```console",
                "out 1",
                "out 2",
                "```",
            })

            assert.same({ "0", "0", "0", "0" }, levels)
        end)

        it(
            "keeps a marked body's fold while dropping the injected one",
            function()
                -- The reported symptom is zsh's `heredoc_redirect` fold inside an
                -- execute block's command fence running to the end of the buffer.
                -- lua's bundled folds.scm stands in for it: a language whose own
                -- folds query matches inside the fence. `-fold` both marks the body
                -- foldable AND injects lua (injections.scm strips the suffix), so
                -- this is the production shape — the body's own fold must survive
                -- at exactly level 1 while `function_declaration` contributes
                -- nothing. Core's foldexpr surfaces the latter (it queries every
                -- injected tree); ours reads the root tree only.
                local lines = {
                    "```lua-fold",
                    "local function f()",
                    "    return 1",
                    "end",
                    "```",
                    "after",
                }
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
                vim.bo[bufnr].filetype = "AgenticChat"
                vim.treesitter.start(bufnr)

                -- Materialise the injection, so this asserts on absent folds rather
                -- than on an absent tree.
                local parser = vim.treesitter.get_parser(bufnr)
                local lua_folds = vim.treesitter.query.get("lua", "folds")
                assert.is_not_nil(parser)
                assert.is_not_nil(lua_folds)
                --- @cast parser -nil
                --- @cast lua_folds -nil
                parser:parse(true)
                local injected = 0
                parser:for_each_tree(function(tree, ltree)
                    if ltree:lang() ~= "lua" then
                        return
                    end
                    for _ in lua_folds:iter_captures(tree:root(), bufnr, 0, -1) do
                        injected = injected + 1
                    end
                end)
                assert.is_true(injected > 0)

                assert.same(
                    { "0", ">1", "1", "1", "0", "0" },
                    require("agentic.ui.folds").levels(bufnr)
                )
            end
        )

        it(
            "nests a `console-fold` fold in a `-foldnext` fold before it",
            function()
                local levels, joined = levels_of({
                    "### block",
                    "```zsh-foldnext",
                    "rg foo",
                    "```",
                    "```console-fold",
                    "out 1",
                    "out 2",
                    "```",
                    "after",
                })

                assert.same(
                    { "0", "0", ">1", "1", "1", ">2", "2", "0", "0" },
                    levels
                )
                assert.same({ [3] = true }, joined)
            end
        )

        it(
            "folds a `-foldnext` fence through a one-row `console` fence",
            function()
                local levels, joined = levels_of({
                    "```zsh-foldnext",
                    "rg foo",
                    "```",
                    "```console",
                    "out 1",
                    "```",
                })

                assert.same({ "0", ">1", "1", "1", "1", "0" }, levels)
                assert.same({ [2] = true }, joined)
            end
        )

        it("forms no fold for a `-foldnext` fence alone", function()
            local levels = levels_of({
                "```zsh-foldnext",
                "git add a",
                "git commit",
                "```",
                "after",
            })

            assert.same({ "0", "0", "0", "0", "0" }, levels)
        end)

        it("does not join a `console` fence after a blank line", function()
            local levels, joined = levels_of({
                "```zsh-foldnext",
                "git add a",
                "git commit",
                "```",
                "",
                "```console",
                "out 1",
                "out 2",
                "```",
            })

            assert.same({ "0", "0", "0", "0", "0", "0", "0", "0", "0" }, levels)
            assert.same({}, joined)
        end)

        it("does not join a `-fold` fence to a `console` fence", function()
            local levels, joined = levels_of({
                "```markdown-fold",
                "thought 1",
                "thought 2",
                "```",
                "```console",
                "out 1",
                "out 2",
                "```",
            })

            assert.same({ "0", ">1", "1", "0", "0", "0", "0", "0" }, levels)
            assert.same({}, joined)
        end)

        it("does not join a `-difffold` fence to a `console` fence", function()
            local levels, joined = levels_of({
                "```lua-difffold",
                "local a = 1",
                "local b = 2",
                "```",
                "```console",
                "reason 1",
                "reason 2",
                "```",
            })

            assert.same({ "0", ">1", "1", "0", "0", "0", "0", "0" }, levels)
            assert.same({}, joined)
        end)

        it("skips a one-line body, which vim cannot close", function()
            local levels = levels_of({
                "```console-fold",
                "out 1",
                "```",
            })

            assert.same({ "0", "0", "0" }, levels)
        end)

        it("returns all-zero levels for a buffer with no parser", function()
            fill_lines(3)

            assert.same(
                { "0", "0", "0" },
                require("agentic.ui.folds").levels(bufnr)
            )
        end)
    end)

    describe("levels_of_ranges", function()
        local levels_of_ranges = require("agentic.ui.folds").levels_of_ranges

        it("gives disjoint ranges level 1", function()
            assert.same(
                { ">1", "1", "0", ">1", "1", "0" },
                levels_of_ranges({ { 4, 5 }, { 1, 2 } }, 6)
            )
        end)

        it("gives a range inside another one level more", function()
            assert.same(
                { "0", ">1", "1", ">2", "2", "1", "0" },
                levels_of_ranges({ { 4, 5 }, { 2, 6 } }, 7)
            )
        end)

        it("restarts a fold on the first line of an adjacent range", function()
            assert.same(
                { ">1", "1", ">1", "1" },
                levels_of_ranges({ { 1, 2 }, { 3, 4 } }, 4)
            )
        end)
    end)

    describe("foldexpr", function()
        it("recomputes after the buffer changes", function()
            local Folds = require("agentic.ui.folds")
            levels_of({
                "```console-fold",
                "out 1",
                "out 2",
                "```",
            })
            local function level_at(lnum)
                return vim.api.nvim_win_call(winid, function()
                    vim.v.lnum = lnum
                    return Folds.foldexpr()
                end)
            end

            assert.equal(">1", level_at(2))

            -- Prepending shifts the block down; a level cache keyed on the old
            -- content would report the fold at the wrong row.
            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "prose" })

            assert.equal("0", level_at(2))
            assert.equal(">1", level_at(3))
        end)

        it("computes levels once per changedtick", function()
            local Folds = require("agentic.ui.folds")
            levels_of({
                "```console-fold",
                "out 1",
                "out 2",
                "```",
            })
            local real_levels = Folds.levels
            local calls = 0
            Folds.levels = function(buf)
                calls = calls + 1
                return real_levels(buf)
            end

            vim.api.nvim_win_call(winid, function()
                for lnum = 1, 4 do
                    vim.v.lnum = lnum
                    Folds.foldexpr()
                end
            end)
            Folds.levels = real_levels

            assert.equal(1, calls)
        end)

        it("keeps levels per buffer", function()
            local Folds = require("agentic.ui.folds")
            levels_of({
                "```console-fold",
                "out 1",
                "out 2",
                "```",
            })

            local other = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(other, 0, -1, false, {
                "plain",
                "```console",
                "out 1",
                "out 2",
                "```",
            })
            vim.bo[other].filetype = "AgenticChat"
            vim.treesitter.start(other)

            --- @param buf integer
            --- @param lnum integer
            local function level_at(buf, lnum)
                return vim.api.nvim_buf_call(buf, function()
                    vim.v.lnum = lnum
                    return Folds.foldexpr()
                end)
            end

            -- Interleaved so a single shared level array would leak across.
            assert.equal(">1", level_at(bufnr, 2))
            assert.equal("0", level_at(other, 2))
            assert.equal(">1", level_at(bufnr, 2))

            vim.api.nvim_buf_delete(other, { force = true })
        end)

        it("returns a level for a line past the computed range", function()
            local Folds = require("agentic.ui.folds")
            levels_of({ "prose", "more prose" })

            local level = vim.api.nvim_win_call(winid, function()
                vim.v.lnum = 99
                return Folds.foldexpr()
            end)

            assert.equal("0", level)
        end)
    end)

    describe("foldtext", function()
        it("summarises the inclusive line count of a closed fold", function()
            -- foldtext reads vim.v.foldstart/foldend, which vim only sets while
            -- rendering a closed fold. foldtextresult() evaluates the window's
            -- 'foldtext' with those set, so it exercises the real arithmetic
            -- (a direct call leaves the v: vars unset). The fold source is
            -- irrelevant — a manual fold stands in for the runtime treesitter
            -- fold. 5,11fold spans 7 inclusive lines (foldend - foldstart + 1),
            -- matching the body-only treesitter fold's inclusive count.
            fill_lines(20)
            vim.wo[winid].foldmethod = "manual"
            vim.wo[winid].foldenable = true
            vim.wo[winid].foldtext =
                'v:lua.require("agentic.ui.folds").foldtext()'
            vim.api.nvim_win_call(winid, function()
                vim.cmd("5,11fold")
            end)

            local text = vim.api.nvim_win_call(winid, function()
                return vim.fn.foldtextresult(5)
            end)
            assert.is_not_nil(text:match("··· 7 lines ···"))

            -- The highlight group is fixed regardless of the v: vars, so a
            -- direct call covers it.
            local chunks = require("agentic.ui.folds").foldtext()
            assert.equal("Comment", chunks[1][2])
        end)

        --- Fold rows `first` to `last` (1-indexed, inclusive) and return the
        --- rendered foldtext.
        --- @param first integer
        --- @param last integer
        --- @return string
        local function foldtext_of(first, last)
            vim.wo[winid].foldmethod = "manual"
            vim.wo[winid].foldenable = true
            vim.wo[winid].foldtext =
                'v:lua.require("agentic.ui.folds").foldtext()'
            return vim.api.nvim_win_call(winid, function()
                vim.cmd(string.format("%d,%dfold", first, last))
                return vim.fn.foldtextresult(first)
            end)
        end

        it("adds a character count when the fence row is marked", function()
            -- The mark on the row above the fold asks for the count; the
            -- count is read back out of the folded rows.
            fill_lines(20)
            vim.api.nvim_buf_set_extmark(bufnr, NS_CHAR_COUNT, 3, 0, {})

            -- "line 5".."line 9" are 6 characters, "line 10".."line 11" are 7,
            -- plus the 6 newlines rejoining them.
            assert.equal(
                "    ··· 7 lines · 50 chars ···",
                foldtext_of(5, 11)
            )
        end)

        it("counts characters, not bytes", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "above",
                "—·—·—",
                "—·—·—",
                "below",
            })
            vim.api.nvim_buf_set_extmark(bufnr, NS_CHAR_COUNT, 0, 0, {})

            -- 10 dashes and middots plus the newline; by bytes it would be 31.
            assert.equal(
                "    ··· 2 lines · 11 chars ···",
                foldtext_of(2, 3)
            )
        end)

        it("leaves an unmarked fold's summary alone", function()
            fill_lines(20)
            -- A mark on the first body row, not the fence row, asks nothing.
            vim.api.nvim_buf_set_extmark(bufnr, NS_CHAR_COUNT, 4, 0, {})

            assert.equal("    ··· 7 lines ···", foldtext_of(5, 11))
        end)

        it("leads with the name the opening fence gives the body", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "above",
                "```markdown-fold shell-guard.sh",
                "injected",
                "context",
                "```",
            })

            assert.equal(
                "    ··· shell-guard.sh · 2 lines ···",
                foldtext_of(3, 4)
            )
        end)

        it("names nothing when the fence carries only a language", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "above",
                "```markdown-fold",
                "injected",
                "context",
                "```",
            })

            assert.equal("    ··· 2 lines ···", foldtext_of(3, 4))
        end)

        describe("of a joined fold", function()
            --- Render an execute block with `command` as the chat buffer
            --- under its own foldexpr, and return the foldtext of its fold.
            --- @param command string
            --- @return string
            local function joined_foldtext(command)
                levels_of({
                    "### block",
                    "```zsh-foldnext",
                    command,
                    "```",
                    "```console",
                    "out 1",
                    "out 2",
                    "```",
                })
                vim.wo[winid].foldmethod = "expr"
                vim.wo[winid].foldexpr =
                    'v:lua.require("agentic.ui.folds").foldexpr()'
                vim.wo[winid].foldtext =
                    'v:lua.require("agentic.ui.folds").foldtext()'
                return vim.api.nvim_win_call(winid, function()
                    return vim.fn.foldtextresult(3)
                end)
            end

            it("leads with the first row and counts content rows", function()
                assert.equal(
                    "    ··· rg foo · 3 lines ···",
                    joined_foldtext("rg foo")
                )
            end)

            it("cuts the first row to the window's text width", function()
                vim.api.nvim_win_set_width(winid, 30)
                local text = joined_foldtext(string.rep("x", 40))

                assert.equal(30, vim.fn.strdisplaywidth(text))
                assert.is_not_nil(text:match("x… · 3 lines ···$"))
            end)
        end)
    end)
end)
