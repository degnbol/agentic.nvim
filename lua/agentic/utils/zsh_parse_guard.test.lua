local ZshParseGuard = require("agentic.utils.zsh_parse_guard")
local assert = require("tests.helpers.assert")

describe("zsh_parse_guard", function()
    -- Boundary from notes/bug-zsh-parser-hang.md, verified headless: the hang
    -- fires for any bare `)` in a bracket class inside a `${…/…}` substitution.
    local hangs = {
        "c=${x//[^)]}", -- the minimal reproducer
        "${x/[)]}", -- bare `)`, single slash
        "${x//[)]}", -- bare `)`, double slash
        "${x//[a)b]}", -- `)` among other class chars
        "${x/[)]/replacement}", -- class in the search half of `s/a/b`
        "prefix ${v//[^)]} suffix", -- embedded in a larger line
    }

    local safe = {
        "${x//[^(]}", -- open-paren in class is safe
        "${x//[^\\)]}", -- escaped close-paren is safe
        "${x//foo/bar}", -- substitution without a bracket class
        "ls [)]", -- paren-in-class outside any substitution (glob)
        "case $x in [)]) echo hi ;; esac", -- case pattern, not a substitution
        "${a}/${b}[)]", -- bracket class after the closing `}`
        "echo hello world",
    }

    for _, src in ipairs(hangs) do
        it("flags the hang trigger: " .. src, function()
            assert.is_true(ZshParseGuard.contains_hang_trigger(src))
        end)
    end

    for _, src in ipairs(safe) do
        it("passes safe input: " .. src, function()
            assert.is_false(ZshParseGuard.contains_hang_trigger(src))
        end)
    end
end)
