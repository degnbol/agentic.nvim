local assert = require("tests.helpers.assert")
local ZshParse = require("agentic.utils.zsh_parse")

describe("zsh_parse", function()
    describe("parse", function()
        it("keeps parsing backticks the tree represents", function()
            local rejected = {}
            for _, src in ipairs({
                "echo `id`",
                "echo $(echo `id`)",
                "echo 'a`b'",
                "echo $'a`b'",
                "echo a\\`b",
                'echo "a\\`b"',
                "echo hi # `x`",
                "cat <<'EOF'\n```lua\n`id`\nEOF",
                "cat << 'EOF'\n```lua\n`id`\nEOF",
                'cat <<"EOF"\n```lua\n`id`\nEOF',
                "cat <<\\EOF\n```lua\n`id`\nEOF",
                "git commit -m \"$(cat <<'EOF'\nfix\n\n```\ncode\n```\nEOF\n)\"",
            }) do
                if ZshParse.parse(src) == nil then
                    table.insert(rejected, src)
                end
            end
            assert.same({}, rejected)
        end)

        it("keeps parsing a line continuation between words", function()
            assert.is_not_nil(ZshParse.parse("cmd a \\\n  --flag"))
            assert.is_not_nil(ZshParse.parse("echo a |\\\ngrep a"))
            assert.is_not_nil(ZshParse.parse("echo a &&\\\necho b"))
        end)

        it("rejects parameter flags that run code from the value", function()
            local parsed = {}
            for _, src in ipairs({
                "echo ${(e)x}",
                "echo ${(P)x}",
                "echo ${(#)x}",
                "echo ${(%%)x}",
                "echo ${(l:n:)x}",
                "echo ${(r:n:)x}",
                "echo ${(I:n:)x#a}",
                "echo ${(fe)x}",
                "echo ${~x}",
                "ls $~x",
            }) do
                if ZshParse.parse(src) ~= nil then
                    table.insert(parsed, src)
                end
            end
            assert.same({}, parsed)
        end)

        it("rejects glob qualifiers that run code", function()
            local parsed = {}
            for _, src in ipairs({
                "echo d/*(+pwd)",
                "echo *(.+f)",
                "echo *(oe:x:)",
                "echo *(Y$n)",
            }) do
                if ZshParse.parse(src) ~= nil then
                    table.insert(parsed, src)
                end
            end
            assert.same({}, parsed)
        end)

        it("rejects arithmetic that reads a value", function()
            local parsed = {}
            for _, src in ipairs({
                "echo $((n))",
                "echo $(($n + 1))",
                "echo $(($1)) $((${1})) $(($@)) $(($*))",
                "echo $(($(cat f)))",
                "echo ${x[$1]}",
                "echo ${x:$n} ${x:0:$n}",
                'echo "${x:1:$n}"',
                "y=([n]=Q)",
                "[[ $1 -eq 1 ]]",
                "echo $[n]",
                "echo ${x[n]}",
                "echo $x[n]",
                'echo "${x[i]:-d}"',
                "echo ${x[n,2]}",
                "x[n]=b",
                "[[ n -eq 1 ]]",
                "[[ 1 -lt $a ]]",
            }) do
                if ZshParse.parse(src) ~= nil then
                    table.insert(parsed, src)
                end
            end
            assert.same({}, parsed)
        end)

        it("keeps parsing arithmetic on numbers only", function()
            local rejected = {}
            for _, src in ipairs({
                "echo $((1 + 2 * 3)) $[4] $(($# - 1)) $(($? + 1))",
                "echo ${x[1]} ${x[-1]} ${x[1,2]} ${#x} ${x:1:2}",
                "y=([2]=a b)",
                "[[ $# -gt 0 ]]",
                "[ n -eq 1 ]",
                "[ -f foo ] && [[ -n $x ]]",
                "echo ${x//[a-z]/} ${x#[ab]}",
            }) do
                if ZshParse.parse(src) == nil then
                    table.insert(rejected, src)
                end
            end
            assert.same({}, rejected)
        end)

        it("keeps parsing flags and qualifiers that only reshape", function()
            local rejected = {}
            for _, src in ipairs({
                "echo ${(f)x} ${(U)x} ${(@)x} ${(k)x} ${(j:,:)x}",
                "echo ${(@ps:\\t:)x} ${(s:/:)x} ${(j: OR :)x}",
                "echo ${=x} ${#x} ${^x}",
                "echo *(.) *(N) *(.N) *(/) *(om) *(Lk+5)",
            }) do
                if ZshParse.parse(src) == nil then
                    table.insert(rejected, src)
                end
            end
            assert.same({}, rejected)
        end)

        describe("assigning expansions", function()
            it("fail the parse", function()
                local parsed = {}
                for _, cmd in ipairs({
                    "echo ${x::=y}",
                    ": ${x:=y}",
                    "echo ${x=y}",
                    "echo ${(A)x::=y}",
                }) do
                    if ZshParse.parse(cmd) then
                        table.insert(parsed, cmd)
                    end
                end
                assert.same({}, parsed)
            end)

            it("leave non-assigning defaults parseable", function()
                assert.is_not_nil(ZshParse.parse("echo ${x:-y} ${x+y}"))
            end)
        end)
    end)

    describe("zsh-hang trigger (must not reach parse())", function()
        -- parse() never returns on this input and no in-process mechanism can
        -- interrupt the C loop, so `ZshParse.parse` must bail before parsing. If the
        -- guard regressed, this test would hang the whole suite rather than fail.
        it("returns nil without hanging", function()
            assert.equal(nil, ZshParse.parse("c=${x//[^)]}"))
        end)
    end)

    describe("parse_untrusted (subprocess termination guard)", function()
        it("returns a walkable root for a normal script body", function()
            -- Exercises the full oracle round-trip: subprocess proves the parse
            -- terminates, then it is re-parsed in-process.
            local root = ZshParse.parse_untrusted("ls /tmp\ngrep foo bar\n")
            assert.is_not_nil(root)
            assert.equal("program", root:type())
        end)

        it(
            "returns nil on the hang trigger (never reaches the oracle)",
            function()
                assert.equal(nil, ZshParse.parse_untrusted("c=${x//[^)]}"))
            end
        )
    end)

    describe("parse_command", function()
        it("is nil for a non-string, empty or over-cap command", function()
            assert.is_nil(ZshParse.parse_command(nil))
            assert.is_nil(ZshParse.parse_command(42))
            assert.is_nil(ZshParse.parse_command(""))
            assert.is_nil(
                ZshParse.parse_command(("x"):rep(ZshParse.MAX_SOURCE_BYTES + 1))
            )
        end)

        it("parses a command at the cap", function()
            assert.equal(65536, ZshParse.MAX_SOURCE_BYTES)
            assert.is_not_nil(ZshParse.parse_command(("x"):rep(65536)))
        end)
    end)
end)
