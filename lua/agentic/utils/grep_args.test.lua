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

describe("GrepArgs.search_terms", function()
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
        { name = "ag", argv = { "-G", "lua$", "foo" }, patterns = { "foo" } },
        { name = "ack", argv = { "-m", "1", "foo" }, patterns = { "foo" } },
    }

    for _, c in ipairs(cases) do
        local label = c.name .. " " .. table.concat(c.argv, " ")
        it(label, function()
            local terms = GrepArgs.search_terms(
                c.name,
                c.argv,
                c.dynamic or all_static(c.argv)
            )
            assert.same({
                patterns = c.patterns,
                ignore_case = c.ignore_case == true,
                line_numbers = c.line_numbers == true,
            }, terms)
        end)
    end

    it("returns nil for a git subcommand other than grep", function()
        assert.is_nil(GrepArgs.search_terms("git", { "log" }, { false }))
    end)

    it("returns nil for a non-grep command", function()
        assert.is_nil(GrepArgs.search_terms("cat", { "f" }, { false }))
    end)
end)
