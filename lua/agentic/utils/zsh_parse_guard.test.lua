local ZshParseGuard = require("agentic.utils.zsh_parse_guard")
local assert = require("tests.helpers.assert")

describe("zsh_parse_guard", function()
    -- Boundary verified headless: the hang
    -- fires for any bare `)` in a bracket class inside a `${…/…}` substitution.
    local hangs = {
        "c=${x//[^)]}", -- the minimal reproducer
        "${x/[)]}", -- bare `)`, single slash
        "${x//[)]}", -- bare `)`, double slash
        "${x//[a)b]}", -- `)` among other class chars
        "${x/[)]/replacement}", -- class in the search half of `s/a/b`
        "prefix ${v//[^)]} suffix", -- embedded in a larger line
        'echo "${a:-${x//[^)]}}"', -- nested: the inner opener also matches
        "${a//[)]} ${b//[)]}", -- two triggers side by side
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

    describe("defuse_hang_triggers", function()
        for _, src in ipairs(hangs) do
            it(
                "removes the trigger, changing only `$` to `_`: " .. src,
                function()
                    local defused = ZshParseGuard.defuse_hang_triggers(src)
                    assert.is_false(
                        ZshParseGuard.contains_hang_trigger(defused)
                    )
                    assert.equal(#defused, #src)
                    for i = 1, #src do
                        local before, after = src:sub(i, i), defused:sub(i, i)
                        assert.is_true(
                            before == after or (before == "$" and after == "_"),
                            "byte " .. i
                        )
                    end
                end
            )
        end

        for _, src in ipairs(safe) do
            it("returns safe input unchanged: " .. src, function()
                assert.equal(ZshParseGuard.defuse_hang_triggers(src), src)
            end)
        end
    end)
end)
