local assert = require("tests.helpers.assert")
local GrepArgs = require("agentic.utils.grep_args")

--- @param argv string[]
--- @return boolean[]
local function all_static(argv)
    local dynamic = {}
    for i = 1, #argv do
        dynamic[i] = false
    end
    return dynamic
end

describe("GrepArgs.parse", function()
    --- @type { name: string, argv: string[], dynamic?: boolean[], patterns: string[], ignore_case?: boolean, line_numbers?: boolean }[]
    local cases = {
        {
            name = "grep",
            argv = { "-rn", "x", "." },
            patterns = { "x" },
            line_numbers = true,
        },
        {
            name = "grep",
            argv = { "-nA", "3", "foo", "f" },
            patterns = { "foo" },
            line_numbers = true,
        },
        {
            name = "grep",
            argv = { "--line-number", "foo" },
            patterns = { "foo" },
            line_numbers = true,
        },
        {
            name = "rg",
            argv = { "--vimgrep", "foo" },
            patterns = { "foo" },
            line_numbers = true,
        },
        { name = "grep", argv = { "-A3", "foo", "f" }, patterns = { "foo" } },
        {
            name = "grep",
            argv = { "-ie", "foo", "f" },
            patterns = { "foo" },
            ignore_case = true,
        },
        {
            name = "grep",
            argv = { "-e", "a", "-e", "b", "f" },
            patterns = { "a", "b" },
        },
        {
            name = "grep",
            argv = { "foo", "f", "-e", "bar" },
            patterns = { "bar" },
        },
        { name = "grep", argv = { "--regexp=a", "f" }, patterns = { "a" } },
        { name = "grep", argv = { "-f", "pats.txt", "f" }, patterns = {} },
        { name = "grep", argv = { "--", "-foo", "f" }, patterns = { "-foo" } },
        {
            name = "grep",
            argv = { "--ignore-case", "foo" },
            patterns = { "foo" },
            ignore_case = true,
        },
        {
            name = "rg",
            argv = { "-g", "*.lua", "-r", "$1", "foo" },
            patterns = { "foo" },
        },
        { name = "rg", argv = { "--files", "src" }, patterns = {} },
        {
            name = "git",
            argv = { "-C", "dir", "grep", "-n", "foo" },
            patterns = { "foo" },
            line_numbers = true,
        },
        {
            name = "grep",
            argv = { "$pat", "f" },
            dynamic = { true, false },
            patterns = {},
        },
        {
            name = "grep",
            argv = { "-l", "x", "$__xargs_stdin" },
            dynamic = { false, false, true },
            patterns = { "x" },
        },
        {
            name = "grep",
            argv = { "$__xargs_stdin" },
            dynamic = { true },
            patterns = {},
        },
        { name = "grep", argv = { "-A" }, patterns = {} },
        { name = "grep", argv = { "foo", "-e" }, patterns = {} },
        {
            name = "grep",
            argv = { "--regexp=$p", "f" },
            dynamic = { true, false },
            patterns = {},
        },
        { name = "rg", argv = { "--type-list" }, patterns = {} },
        {
            name = "rg",
            argv = { "--color", "never", "foo" },
            patterns = { "foo" },
        },
        {
            name = "git",
            argv = { "--git-dir", "x", "grep", "foo" },
            patterns = { "foo" },
        },
        { name = "ugrep", argv = { "-A", "2", "foo" }, patterns = { "foo" } },
        {
            name = "ag",
            argv = { "-G", "lua$", "foo" },
            patterns = { "foo" },
            ignore_case = true,
        },
        { name = "ack", argv = { "-m", "1", "foo" }, patterns = { "foo" } },
        { name = "ugrep", argv = { "-t", "lua", "foo" }, patterns = { "foo" } },
        { name = "ugrep", argv = { "-N", "bar", "foo" }, patterns = { "foo" } },
        {
            name = "ag",
            argv = { "-g", "foo" },
            patterns = {},
            ignore_case = true,
        },
        -- case: last flag wins
        {
            name = "grep",
            argv = { "-i", "--no-ignore-case", "foo" },
            patterns = { "foo" },
        },
        { name = "rg", argv = { "-i", "-s", "foo" }, patterns = { "foo" } },
        {
            name = "rg",
            argv = { "-s", "-i", "foo" },
            patterns = { "foo" },
            ignore_case = true,
        },
        { name = "ack", argv = { "-i", "-I", "foo" }, patterns = { "foo" } },
        -- smart case
        {
            name = "rg",
            argv = { "-S", "foo" },
            patterns = { "foo" },
            ignore_case = true,
        },
        {
            name = "rg",
            argv = { "-S", "-e", "Foo", "-e", "bar" },
            patterns = { "Foo", "bar" },
        },
        { name = "rg", argv = { "-S", "É" }, patterns = { "É" } },
        { name = "rg", argv = { "-S", [[\x41]] }, patterns = { [[\x41]] } },
        -- an unknown pattern can take a known one's match
        {
            name = "rg",
            argv = { "-e", "foo", "-e", "$p" },
            dynamic = { false, false, false, true },
            patterns = {},
        },
        { name = "rg", argv = { "-e", "foo", "-f", "pats" }, patterns = {} },
        -- value options shared with grep
        { name = "rg", argv = { "-A", "2", "foo" }, patterns = { "foo" } },
        { name = "rg", argv = { "-m", "1", "foo" }, patterns = { "foo" } },
        {
            name = "rg",
            argv = { "--max-count", "1", "foo" },
            patterns = { "foo" },
        },
        {
            name = "rg",
            argv = { "--include", "x", "foo" },
            patterns = { "foo" },
        },
        -- ag and ack take a context count only when it is a number
        {
            name = "ag",
            argv = { "-C", "foo", "src" },
            patterns = { "foo" },
            ignore_case = true,
        },
        {
            name = "ag",
            argv = { "-C", "3", "foo" },
            patterns = { "foo" },
            ignore_case = true,
        },
        {
            name = "ag",
            argv = { "-C3", "foo" },
            patterns = { "foo" },
            ignore_case = true,
        },
        { name = "ack", argv = { "--context", "foo" }, patterns = { "foo" } },
        { name = "ack", argv = { "-A", "2", "foo" }, patterns = { "foo" } },
        {
            name = "rg",
            argv = { "-N", "--column", "foo" },
            patterns = { "foo" },
        },
        {
            name = "ugrep",
            argv = { "-j", "foo" },
            patterns = { "foo" },
            ignore_case = true,
        },
        { name = "ag", argv = { "Foo" }, patterns = { "Foo" } },
        { name = "ag", argv = { "-s", "foo" }, patterns = { "foo" } },
        {
            name = "ack",
            argv = { "-S", "foo" },
            patterns = { "foo" },
            ignore_case = true,
        },
        -- line-number flags
        {
            name = "rg",
            argv = { "--column", "foo" },
            patterns = { "foo" },
            line_numbers = true,
        },
        { name = "rg", argv = { "-n", "-N", "foo" }, patterns = { "foo" } },
        {
            name = "ag",
            argv = { "--numbers", "foo" },
            patterns = { "foo" },
            line_numbers = true,
            ignore_case = true,
        },
        { name = "ack", argv = { "-n", "foo" }, patterns = { "foo" } },
    }

    for _, c in ipairs(cases) do
        local label = c.name .. " " .. table.concat(c.argv, " ")
        it(label, function()
            local inv =
                GrepArgs.parse(c.name, c.argv, c.dynamic or all_static(c.argv))
            assert.is_not_nil(inv)
            --- @cast inv -nil
            assert.same({
                patterns = c.patterns,
                ignore_case = c.ignore_case == true,
                line_numbers = c.line_numbers == true,
            }, {
                patterns = inv.patterns,
                ignore_case = inv.ignore_case,
                line_numbers = inv.line_numbers,
            })
        end)
    end

    it("returns nil for a git subcommand other than grep", function()
        assert.is_nil(GrepArgs.parse("git", { "log" }, { false }))
    end)

    it("returns nil for a non-grep command", function()
        assert.is_nil(GrepArgs.parse("cat", { "f" }, { false }))
    end)
end)

describe("GrepArgs.parse layout", function()
    local BOTH = { 0, 1 }

    --- @type { name: string, argv: string[], names: integer[], fields: integer[] }[]
    local cases = {
        { name = "grep", argv = { "foo" }, names = BOTH, fields = { 0 } },
        {
            name = "grep",
            argv = { "-n", "foo" },
            names = BOTH,
            fields = { 1 },
        },
        {
            name = "grep",
            argv = { "-H", "foo" },
            names = { 1 },
            fields = { 0 },
        },
        {
            name = "grep",
            argv = { "-hn", "foo" },
            names = { 0 },
            fields = { 1 },
        },
        {
            name = "grep",
            argv = { "-n", "-k", "-b", "foo" },
            names = BOTH,
            fields = { 3 },
        },
        {
            name = "ugrep",
            argv = { "-k", "foo" },
            names = BOTH,
            fields = { 1 },
        },
        {
            name = "rg",
            argv = { "-H", "-n", "-b", "--column", "foo" },
            names = { 1 },
            fields = { 3 },
        },
        {
            name = "rg",
            argv = { "--column", "foo" },
            names = BOTH,
            fields = { 2 },
        },
        {
            name = "rg",
            argv = { "--vimgrep", "foo" },
            names = { 1 },
            fields = { 2 },
        },
        {
            name = "rg",
            argv = { "-I", "foo" },
            names = { 0 },
            fields = { 0 },
        },
        {
            name = "rg",
            argv = { "-L", "foo" },
            names = BOTH,
            fields = { 0 },
        },
        { name = "ag", argv = { "foo" }, names = BOTH, fields = { 0, 1 } },
        {
            name = "ag",
            argv = { "--column", "foo" },
            names = BOTH,
            fields = { 2 },
        },
        {
            name = "ag",
            argv = { "--nonumbers", "foo" },
            names = BOTH,
            fields = { 0 },
        },
        {
            name = "ag",
            argv = { "--nofilename", "foo" },
            names = { 0 },
            fields = { 0, 1 },
        },
        {
            name = "ack",
            argv = { "--column", "foo" },
            names = BOTH,
            fields = { 2 },
        },
        {
            name = "ack",
            argv = { "-h", "foo" },
            names = { 0 },
            fields = { 0, 1 },
        },
        {
            name = "git",
            argv = { "grep", "foo" },
            names = { 1 },
            fields = { 0, 1, 2 },
        },
        {
            name = "git",
            argv = { "grep", "-n", "foo" },
            names = { 1 },
            fields = { 1, 2 },
        },
        {
            name = "git",
            argv = { "grep", "-h", "-n", "--column", "foo" },
            names = { 0 },
            fields = { 2 },
        },
        -- heading: no file name, and a numeric field is needed
        {
            name = "grep",
            argv = { "--heading", "-n", "foo" },
            names = { 0 },
            fields = { 1 },
        },
        {
            name = "grep",
            argv = { "--heading", "foo" },
            names = { 0 },
            fields = {},
        },
        {
            name = "rg",
            argv = { "-p", "foo" },
            names = { 0 },
            fields = { 1 },
        },
        {
            name = "rg",
            argv = { "--heading", "--no-heading", "foo" },
            names = BOTH,
            fields = { 0 },
        },
        {
            name = "ag",
            argv = { "-H", "foo" },
            names = { 0 },
            fields = { 1 },
        },
        -- no matched text
        { name = "grep", argv = { "-l", "foo" }, names = BOTH, fields = {} },
        { name = "grep", argv = { "-c", "foo" }, names = BOTH, fields = {} },
        {
            name = "grep",
            argv = { "-vn", "foo" },
            names = BOTH,
            fields = {},
        },
        {
            name = "ugrep",
            argv = { "--format=%f", "foo" },
            names = BOTH,
            fields = {},
        },
        {
            name = "rg",
            argv = { "-r", "X", "foo" },
            names = BOTH,
            fields = {},
        },
        {
            name = "ack",
            argv = { "--output=x", "foo" },
            names = BOTH,
            fields = {},
        },
        {
            name = "git",
            argv = { "grep", "--name-only", "-n", "foo" },
            names = { 1 },
            fields = {},
        },
        -- context
        {
            name = "grep",
            argv = { "-C1", "foo" },
            names = BOTH,
            fields = {},
        },
        { name = "grep", argv = { "-2", "foo" }, names = BOTH, fields = {} },
        {
            name = "grep",
            argv = { "-C1", "-n", "foo" },
            names = BOTH,
            fields = { 1 },
        },
        {
            name = "grep",
            argv = { "-h", "-C1", "foo" },
            names = { 0 },
            fields = { 0 },
        },
        {
            name = "ugrep",
            argv = { "-y", "foo" },
            names = BOTH,
            fields = {},
        },
        {
            name = "rg",
            argv = { "--passthru", "foo" },
            names = BOTH,
            fields = {},
        },
        {
            name = "git",
            argv = { "grep", "-p", "foo" },
            names = { 1 },
            fields = {},
        },
        {
            name = "git",
            argv = { "grep", "-W", "-n", "foo" },
            names = { 1 },
            fields = { 1, 2 },
        },
        -- value options shared with grep
        {
            name = "rg",
            argv = { "-A", "2", "-n", "foo" },
            names = BOTH,
            fields = { 1 },
        },
        -- flag-table cells
        {
            name = "rg",
            argv = { "--no-heading", "foo" },
            names = BOTH,
            fields = { 0 },
        },
        {
            name = "ugrep",
            argv = { "-+", "-n", "foo" },
            names = { 0 },
            fields = { 1 },
        },
        {
            name = "ugrep",
            argv = { "--heading", "--no-heading", "foo" },
            names = BOTH,
            fields = { 0 },
        },
        {
            name = "ag",
            argv = { "--filename", "foo" },
            names = { 1 },
            fields = { 0, 1 },
        },
        {
            name = "ag",
            argv = { "--vimgrep", "foo" },
            names = { 1 },
            fields = { 2 },
        },
        {
            name = "ack",
            argv = { "-H", "foo" },
            names = { 1 },
            fields = { 0, 1 },
        },
        {
            name = "ack",
            argv = { "--heading", "foo" },
            names = { 0 },
            fields = { 1 },
        },
        {
            name = "ack",
            argv = { "--nogroup", "foo" },
            names = BOTH,
            fields = { 0, 1 },
        },
        -- an explicit line-number flag beats --column's, in either order
        {
            name = "rg",
            argv = { "-N", "--column", "foo" },
            names = BOTH,
            fields = { 1 },
        },
        {
            name = "rg",
            argv = { "--column", "-N", "foo" },
            names = BOTH,
            fields = { 1 },
        },
        -- git grep revisions print `rev:path:`
        {
            name = "git",
            argv = { "grep", "-n", "foo", "HEAD" },
            names = { 1, 2 },
            fields = { 1, 2 },
        },
        {
            name = "git",
            argv = { "grep", "-n", "-e", "foo", "HEAD" },
            names = { 1, 2 },
            fields = { 1, 2 },
        },
        {
            name = "git",
            argv = { "grep", "-n", "foo", "--", "a.lua" },
            names = { 1 },
            fields = { 1, 2 },
        },
        {
            name = "git",
            argv = { "grep", "-h", "-n", "foo", "HEAD" },
            names = { 0 },
            fields = { 1, 2 },
        },
        -- summary lines
        { name = "rg", argv = { "--stats", "foo" }, names = BOTH, fields = {} },
        {
            name = "rg",
            argv = { "--stats", "-I", "foo" },
            names = { 0 },
            fields = {},
        },
        {
            name = "rg",
            argv = { "--stats", "-n", "foo" },
            names = BOTH,
            fields = { 1 },
        },
        {
            name = "ag",
            argv = { "--stats", "--nonumbers", "foo" },
            names = BOTH,
            fields = {},
        },
        {
            name = "ugrep",
            argv = { "--stats", "foo" },
            names = BOTH,
            fields = {},
        },
        -- ag and ack take a context count only when it is a number
        {
            name = "ag",
            argv = { "--nofilename", "--numbers", "-C", "foo", "src" },
            names = { 0 },
            fields = { 1 },
        },
    }

    for _, c in ipairs(cases) do
        local label = c.name .. " " .. table.concat(c.argv, " ")
        it(label, function()
            local inv = GrepArgs.parse(c.name, c.argv, all_static(c.argv))
            assert.is_not_nil(inv)
            --- @cast inv -nil
            assert.same({ names = c.names, fields = c.fields }, inv.layout)
        end)
    end

    it("names grep's diagnostics after grep and ugrep", function()
        local inv = GrepArgs.parse("grep", { "foo" }, { false })
        assert.is_not_nil(inv)
        --- @cast inv -nil
        assert.same({ "grep", "ugrep" }, inv.diagnostic_names)
    end)
end)
