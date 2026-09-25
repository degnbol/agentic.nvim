local assert = require("tests.helpers.assert")
local GrepRegex = require("agentic.utils.grep_regex")

--- Non-overlapping, non-empty matches of a Vim pattern in a string.
--- @param subject string
--- @param vim_pattern string
--- @param first_only boolean stop after the first match
--- @return string[]
local function matches_of(subject, vim_pattern, first_only)
    local matches = {}
    local start = 0
    while start <= #subject do
        local text, s, e =
            unpack(vim.fn.matchstrpos(subject, vim_pattern, start, 1))
        if s < 0 then
            break
        end
        if e > s then
            table.insert(matches, text)
        end
        if first_only then
            break
        end
        start = e > s and e or e + 1
    end
    return matches
end

local GIT_DIALECTS = { "basic", "extended", "perl", "fixed" }

--- Each row lists, per subject, the matches the tool makes; for a
--- `first_only` row, only the first of them.
--- @type { patterns: string[], dialects: agentic.utils.GrepDialect[], whole?: "word"|"line", matches?: { [1]: string, [2]: string[] }[], first_only?: boolean, ascii_only?: boolean }[]
local cases = {
    -- what each tool matches, in its own dialect
    {
        patterns = { [[tool_call_blocks\b]] },
        dialects = { "rust" },
        matches = {
            { "tool_call_blocks x", { "tool_call_blocks" } },
            { "tool_call_blocksx", {} },
        },
    },
    {
        patterns = { "message_writer =" },
        dialects = { "rust" },
        matches = { { "message_writer = 1", { "message_writer =" } } },
    },
    {
        patterns = { "a|b" },
        dialects = { "basic" },
        matches = { { "a|b a", { "a|b" } } },
    },
    {
        patterns = { [[a\|b]] },
        dialects = { "basic" },
        matches = { { "a|b", { "a" } } },
        first_only = true,
    },
    {
        patterns = { "x+" },
        dialects = { "basic" },
        matches = { { "xx x+", { "x+" } } },
    },
    {
        patterns = { "x?" },
        dialects = { "basic" },
        matches = { { "x x?", { "x?" } } },
    },
    {
        patterns = { "(x)" },
        dialects = { "basic" },
        matches = { { "x (x)", { "(x)" } } },
    },
    {
        patterns = { "(?:x)y" },
        dialects = { "rust" },
        matches = { { "xy", { "xy" } } },
    },
    {
        patterns = { "a.*?b" },
        dialects = { "rust" },
        matches = { { "aXbXb", { "aXb" } } },
    },
    {
        patterns = { [[\s*=]] },
        dialects = { "rust" },
        matches = { { "a  = b", { "  =" } } },
        ascii_only = true,
    },
    {
        patterns = { [[a.b\c]] },
        dialects = { "fixed" },
        matches = { { [[axb\c a.b\c]], { [[a.b\c]] } } },
    },
    -- constructs the binaries read differently
    { patterns = { [[\d]] }, dialects = { "basic" } },
    { patterns = { [[[\d] ]] }, dialects = { "basic" } },
    { patterns = { [[a\=]] }, dialects = { "basic" } },
    { patterns = { [[foo\']] }, dialects = { "basic" } },
    { patterns = { [[\`foo]] }, dialects = { "basic" } },
    { patterns = { [[a\_b]] }, dialects = { "basic" } },
    { patterns = { "(?:a)" }, dialects = { "extended" } },
    { patterns = { "a+?" }, dialects = { "extended" } },
    { patterns = { "a{" }, dialects = { "extended" } },
    { patterns = { [[a\{,2\}]] }, dialects = { "basic" } },
    { patterns = { "*a" }, dialects = { "basic" } },
    { patterns = { "a)" }, dialects = { "extended" } },
    { patterns = { "[[:punct:]]" }, dialects = { "basic" } },
    { patterns = { "[[:punct:]]" }, dialects = { "extended" } },
    -- empty alternatives and groups
    { patterns = { [[a\|\|b]] }, dialects = { "basic" } },
    { patterns = { [[\(\)]] }, dialects = { "basic" } },
    { patterns = { [[\(a\|\)]] }, dialects = { "basic" } },
    { patterns = { [[a\|]] }, dialects = { "basic" } },
    { patterns = { "(|a)b" }, dialects = { "extended" } },
    { patterns = { "|a" }, dialects = { "extended" } },
    {
        patterns = { "(|a)b" },
        dialects = { "rust" },
        matches = { { "ab", { "ab" } } },
    },
    -- classes: spelled as the tools' ASCII members, sure on ASCII text only
    {
        patterns = { "[[:alpha:]]" },
        dialects = { "basic" },
        matches = { { "a1", { "a" } } },
        ascii_only = true,
    },
    {
        patterns = { "[[:punct:]]" },
        dialects = { "perl" },
        matches = { { "a|b", { "|" } } },
        ascii_only = true,
    },
    {
        patterns = { "[[:print:]]+" },
        dialects = { "rust" },
        matches = { { "a b\1", { "a b" } } },
        ascii_only = true,
    },
    {
        patterns = { [[a\sb]] },
        dialects = { "rust" },
        matches = { { "a\rb a\vb", { "a\rb", "a\vb" } } },
        ascii_only = true,
    },
    {
        patterns = { [[\w{2}]] },
        dialects = { "rust" },
        matches = { { "ab c", { "ab" } } },
        ascii_only = true,
    },
    {
        patterns = { "a.b" },
        dialects = { "perl_bytes" },
        matches = { { "axb", { "axb" } } },
        ascii_only = true,
    },
    -- groups, lazy quantifiers, brackets, anchors
    {
        patterns = { "(?:a|b)c" },
        dialects = { "rust" },
        matches = { { "ac bc", { "ac", "bc" } } },
    },
    {
        patterns = { "[a-z]+" },
        dialects = { "rust" },
        matches = { { "abc1", { "abc" } } },
    },
    {
        patterns = { [[[\d] ]] },
        dialects = { "rust" },
        matches = { { "a1 ", { "1 " } } },
        ascii_only = true,
    },
    {
        patterns = { "[]a]" },
        dialects = { "basic" },
        matches = { { "]a", { "]", "a" } } },
    },
    {
        patterns = { "[^]a]" },
        dialects = { "basic" },
        matches = { { "]ab", { "b" } } },
    },
    {
        patterns = { "[[:digit:]]" },
        dialects = { "basic" },
        matches = { { "a1", { "1" } } },
        ascii_only = true,
    },
    {
        patterns = { "[^[:alpha:]]" },
        dialects = { "basic" },
        matches = { { "a1", { "1" } } },
        ascii_only = true,
    },
    {
        patterns = { [[[^\d] ]] },
        dialects = { "rust" },
        matches = { { "1a ", { "a " } } },
        ascii_only = true,
    },
    { patterns = { "[a&&b]" }, dialects = { "rust" } },
    { patterns = { "[a-c-e]" }, dialects = { "basic" } },
    {
        patterns = { [[\<ab]] },
        dialects = { "perl" },
        matches = { { "<ab ab", { "<ab" } } },
    },
    {
        patterns = { [[\<ab]] },
        dialects = { "rust" },
        matches = { { "<ab xab ab", { "ab", "ab" } } },
    },
    {
        patterns = { "^a|^b" },
        dialects = { "extended" },
        matches = { { "a", { "a" } }, { "ba", { "b" } } },
        first_only = true,
    },
    { patterns = { "a^b" }, dialects = { "basic" } },
    { patterns = { "a$b" }, dialects = { "extended" } },
    {
        patterns = { "a^b" },
        dialects = { "rust" },
        matches = { { "a^b", {} } },
    },
    { patterns = { "(?=x)" }, dialects = { "rust" } },
    { patterns = { "(?i)x" }, dialects = { "perl" } },
    { patterns = { [[(a)\1]] }, dialects = { "perl" } },
    { patterns = { [[\Bx]] }, dialects = { "rust" } },
    { patterns = { [[\p{L}]] }, dialects = { "rust" } },
    { patterns = { [[\x41]] }, dialects = { "perl" } },
    { patterns = { "{x}" }, dialects = { "rust" } },
    { patterns = { "a**" }, dialects = { "basic" } },
    { patterns = { "a**" }, dialects = { "rust" } },
    { patterns = { "a*+" }, dialects = { "perl" } },
    { patterns = { "a{3,2}" }, dialects = { "extended" } },
    { patterns = { "a{256}" }, dialects = { "rust" } },
    { patterns = { "a{,2}" }, dialects = { "extended" } },
    { patterns = { "a{,2}" }, dialects = { "perl" } },
    { patterns = { "a{,2}" }, dialects = { "rust" } },
    {
        patterns = { "(ab){2}" },
        dialects = { "extended" },
        matches = { { "ababab", { "abab" } } },
        first_only = true,
    },
    {
        patterns = { "(ab){2}" },
        dialects = { "rust" },
        matches = { { "ababab", { "abab" } } },
    },
    {
        patterns = { [[a\tb]] },
        dialects = { "rust" },
        matches = { { "a\tb", { "a\tb" } } },
    },
    -- a newline: tools that read each line as a pattern get it split
    { patterns = { "a\nb" }, dialects = { "basic" } },
    { patterns = { "a\nb" }, dialects = { "rust" } },
    -- non-ASCII next to a word boundary
    {
        patterns = { [[\bfoo\b]] },
        dialects = { "rust" },
        matches = { { "éfoo", {} }, { "fooé", {} }, { "foo", { "foo" } } },
    },
    {
        patterns = { "foo" },
        dialects = { "basic" },
        whole = "word",
        matches = { { "éfoo", {} }, { "fooé", {} }, { "a foo", { "foo" } } },
    },
    -- match order
    {
        patterns = { [[a\|ab\|bc]] },
        dialects = { "basic" },
        matches = { { "abc", { "a" } } },
        first_only = true,
    },
    {
        patterns = { "a|ab" },
        dialects = { "rust" },
        matches = { { "ab", { "a" } } },
    },
    {
        patterns = { "a", "b" },
        dialects = { "extended" },
        matches = { { "ab", { "a" } } },
        first_only = true,
    },
    {
        patterns = { "a", "b" },
        dialects = { "perl" },
        matches = { { "ab", { "a" } } },
        first_only = true,
    },
    {
        patterns = { "a", "b" },
        dialects = { "rust" },
        matches = { { "ab", { "a", "b" } } },
    },
    -- git grep without a dialect flag
    {
        patterns = { "foo" },
        dialects = GIT_DIALECTS,
        matches = { { "a foo", { "foo" } } },
    },
    { patterns = { "a|b" }, dialects = GIT_DIALECTS },
    { patterns = { "a" }, dialects = {} },
    -- whole words and lines
    {
        patterns = { "foo-" },
        dialects = { "basic" },
        whole = "word",
        matches = { { "foo- bar", { "foo-" } }, { "foo-bar", {} } },
    },
    {
        patterns = { "ab" },
        dialects = { "basic" },
        whole = "line",
        matches = { { "ab", { "ab" } }, { "abc", {} } },
    },
}

describe("GrepRegex.translate", function()
    for _, c in ipairs(cases) do
        local label = table.concat(c.patterns, " ; ")
            .. " ("
            .. table.concat(c.dialects, ",")
            .. (c.whole and ", " .. c.whole or "")
            .. ")"
        it(label, function()
            local translation =
                GrepRegex.translate(c.patterns, c.dialects, c.whole)
            if not c.matches then
                assert.is_nil(translation)
                return
            end
            assert.is_not_nil(translation)
            --- @cast translation -nil
            local first_only = c.first_only == true
            for _, row in ipairs(c.matches) do
                local vim_pattern = "\\C\\V" .. translation.vim_pattern
                assert.same(
                    { row[1], row[2] },
                    { row[1], matches_of(row[1], vim_pattern, first_only) }
                )
            end
            assert.same(
                { first_only = first_only, ascii_only = c.ascii_only == true },
                {
                    first_only = translation.first_only,
                    ascii_only = translation.ascii_only,
                }
            )
        end)
    end
end)
