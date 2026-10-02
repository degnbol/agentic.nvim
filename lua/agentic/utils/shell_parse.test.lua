local assert = require("tests.helpers.assert")
local ShellParse = require("agentic.utils.shell_parse")

--- Render extracted records as `name -flags args` strings for compact asserts.
--- @param recs agentic.ShellCommand[]|nil
--- @return string[]|nil
local function render(recs)
    if recs == nil then
        return nil
    end
    local out = {}
    for _, r in ipairs(recs) do
        local parts = { r.name }
        vim.list_extend(parts, r.flags)
        vim.list_extend(parts, r.args)
        table.insert(out, table.concat(parts, " "))
    end
    return out
end

--- @return string[] command names in extraction order
local function names(src)
    local recs = ShellParse.extract_commands(src)
    local out = {}
    for _, r in ipairs(recs or {}) do
        table.insert(out, r.name)
    end
    return out
end

describe("ShellParse.extract_commands", function()
    describe("record shape", function()
        it("splits short flag clusters, keeps long flags whole", function()
            assert.same(
                { "rm -r -f x" },
                render(ShellParse.extract_commands("rm -rf x"))
            )
            assert.same(
                { "rm --force x" },
                render(ShellParse.extract_commands("rm --force x"))
            )
        end)

        it("strips a system binary-dir prefix from the name", function()
            assert.same({ "rm" }, names("/usr/bin/rm -f x"))
        end)

        it("keeps argv in source order with flags unsplit", function()
            local recs = ShellParse.extract_commands('grep -rn -A 3 "x" .')
            assert.same({ "-rn", "-A", "3", "x", "." }, recs[1].argv)
            assert.same(
                { false, false, false, false, false },
                recs[1].argv_dynamic
            )
        end)

        it("marks expansion tokens dynamic in argv_dynamic", function()
            local recs = ShellParse.extract_commands('grep "$p" f')
            assert.same({ true, false }, recs[1].argv_dynamic)
        end)

        it("gives xargs' inner grep a dynamic stdin token", function()
            local recs = ShellParse.extract_commands("xargs grep -l x")
            assert.same("grep", recs[1].name)
            assert.same({ "-l", "x", "$__xargs_stdin" }, recs[1].argv)
            assert.same({ false, false, true }, recs[1].argv_dynamic)
        end)
    end)

    describe("argv is the delivered word", function()
        it("removes an unquoted backslash", function()
            assert.same(
                { "-e", "x" },
                ShellParse.extract_commands([[rg \-e x]])[1].argv
            )
        end)

        it(
            "removes double-quote escapes and keeps other backslashes",
            function()
                local recs = ShellParse.extract_commands(
                    [[rg "a\$" "a\"b" "a\\b" "a\qb"]]
                )
                assert.same({ "a$", 'a"b', "a\\b", "a\\qb" }, recs[1].argv)
            end
        )

        it("keeps a dollar before the closing quote", function()
            assert.same(
                { "a$", "$" },
                ShellParse.extract_commands([[rg "a$" "$"]])[1].argv
            )
        end)

        it("keeps the newline of a multi-line string", function()
            assert.same(
                { "a\nb" },
                ShellParse.extract_commands('rg "a\nb"')[1].argv
            )
        end)

        it("joins a word and an adjacent brace glob into one token", function()
            local recs =
                ShellParse.extract_commands("grep --include=*.{ts,tsx} foo")
            assert.same({ "--include=*.{ts,tsx}", "foo" }, recs[1].argv)
            assert.same({ true, false }, recs[1].argv_dynamic)
        end)

        it("names \\rm as rm", function()
            assert.same({ "rm" }, names([[\rm x]]))
        end)

        it("unescapes a double-quoted -c body before re-parsing it", function()
            local recs = ShellParse.extract_commands([[zsh -c "echo \"hi\""]])
            assert.equal("echo", recs[1].name)
            assert.same({ "hi" }, recs[1].argv)
        end)

        it("sees a backtick substitution in a double-quoted -c body", function()
            assert.same({ "echo", "id" }, names([[zsh -c "echo \`id\`"]]))
        end)

        it("unescapes a double-quoted python -c body", function()
            local recs = ShellParse.extract_commands(
                [[python3 -c "open(\"/x\", \"w\")"]]
            )
            assert.same({ "-c", 'open("/x", "w")' }, recs[1].argv)
        end)
    end)

    describe("the headline false positive", function()
        it("does not see rm inside a quoted git commit message", function()
            -- the `rm -f` text is string content, not a command
            assert.same(
                { "git" },
                names('git commit -m "remove the rm -f guard"')
            )
        end)

        it("does not see rm inside a raw-string echo", function()
            assert.same({ "echo", "ls" }, names("echo 'rm -f x' ; ls"))
        end)
    end)

    describe("flattening live substitutions", function()
        it("sees the command inside a $() argument", function()
            assert.same(
                { "git", "printf" },
                names('git commit -m "$(printf rm)"')
            )
        end)

        it("sees rm laundered through a substitution", function()
            assert.same({ "git", "rm" }, names('git commit -m "$(rm -rf /)"'))
        end)
    end)

    describe("transparent prefixes", function()
        it("unwraps an exec-wrapper to the inner command", function()
            assert.same(
                { "rm -f x" },
                render(ShellParse.extract_commands("timeout 5 rm -f x"))
            )
        end)

        it("walks an inline shell -c body", function()
            assert.same(
                { "rm -f y" },
                render(ShellParse.extract_commands("zsh -c 'rm -f y'"))
            )
        end)

        it("unwraps a bare `uv run` to the inner command", function()
            assert.same(
                { "basedpyright probe.py" },
                render(
                    ShellParse.extract_commands("uv run basedpyright probe.py")
                )
            )
        end)

        it("unwraps `uv run` with a code-injecting option", function()
            assert.same(
                { "basedpyright probe.py" },
                render(
                    ShellParse.extract_commands(
                        "uv run --with=evil basedpyright probe.py"
                    )
                )
            )
            assert.same(
                { "rm -f y" },
                render(ShellParse.extract_commands("uv run --with x rm -f y"))
            )
        end)

        it("does not unwrap `uv run --script`", function()
            assert.same({ "uv" }, names("uv run --script s.py"))
        end)

        it("leaves non-`run` uv subcommands as a leaf", function()
            assert.same(
                { "uv pip list" },
                render(ShellParse.extract_commands("uv pip list"))
            )
        end)
    end)

    describe("control flow and pipelines", function()
        it("collects every leaf of a pipeline", function()
            assert.same({ "grep", "head" }, names("grep foo | head -20"))
        end)

        it("recurses into loop bodies", function()
            assert.same({ "rm" }, names("for f in a b; do rm -f $f; done"))
        end)
    end)

    describe("stdin and cwd", function()
        --- The record named `name` in the extraction of `src`.
        --- @param src string
        --- @param name string
        --- @return agentic.ShellCommand
        local function record(src, name)
            for _, r in ipairs(ShellParse.extract_commands(src) or {}) do
                if r.name == name then
                    return r
                end
            end
            error("no record " .. name .. " in " .. src)
        end

        local HEREDOC = { text = "x\n", dynamic = false }

        it("feeds a statement's heredoc to its last command", function()
            local src = "a && b <<EOF\nx\nEOF"
            assert.equal(nil, record(src, "a").stdin)
            assert.same(HEREDOC, record(src, "b").stdin)
        end)

        it("feeds a heredoc before `&&` to the command it follows", function()
            local src = "a <<EOF && b\nx\nEOF"
            assert.same(HEREDOC, record(src, "a").stdin)
            assert.equal(nil, record(src, "b").stdin)
        end)

        it("marks an expanding heredoc body dynamic", function()
            assert.same(
                { text = "$x\n", dynamic = true },
                record("python3 - <<EOF\n$x\nEOF", "python3").stdin
            )
        end)

        it("feeds a pipeline's heredoc to its last command", function()
            local src = "a | b <<EOF\nx\nEOF"
            assert.equal(nil, record(src, "a").stdin)
            assert.same(HEREDOC, record(src, "b").stdin)
        end)

        it("feeds a heredoc inside a -c body", function()
            assert.same(
                HEREDOC,
                record("zsh -c 'python3 - <<EOF\nx\nEOF'", "python3").stdin
            )
        end)

        it("gives no stdin to a non-command statement body", function()
            for _, src in ipairs({
                "{ python3 -; } <<EOF\nx\nEOF",
                "(python3 -) <<EOF\nx\nEOF",
                "! python3 - <<EOF\nx\nEOF",
            }) do
                assert.equal(nil, record(src, "python3").stdin)
            end
        end)

        it("gives no stdin for a heredoc on another fd", function()
            assert.equal(
                nil,
                record("python3 - 3<<EOF\nx\nEOF", "python3").stdin
            )
        end)

        it("passes stdin through an exec-wrapper to its inner", function()
            local src = "timeout 5 a && python3 - <<EOF\nx\nEOF"
            assert.equal(nil, record(src, "a").stdin)
            assert.same(HEREDOC, record(src, "python3").stdin)
            assert.same(
                HEREDOC,
                record("timeout 5 python3 - <<EOF\nx\nEOF", "python3").stdin
            )
            assert.same(
                HEREDOC,
                record("uv run --no-project python - <<EOF\nx\nEOF", "python").stdin
            )
        end)

        it("does not pass stdin through xargs", function()
            assert.equal(
                nil,
                record("xargs python3 - <<EOF\nx\nEOF", "python3").stdin
            )
        end)

        it("tracks literal cds in the same shell", function()
            assert.equal(
                "/a/b",
                record("cd /a && cd b && python3", "python3").cwd
            )
            assert.equal("b", record("cd b && python3", "python3").cwd)
            assert.equal(
                "/x",
                record("cd /x 2>/dev/null && python3", "python3").cwd
            )
            assert.equal("~", record("cd; python3", "python3").cwd)
            assert.equal(
                "/abs",
                record("cd $D; cd /abs; python3", "python3").cwd
            )
            assert.equal("/x", record("echo | cd /x; python3", "python3").cwd)
        end)

        it("gives a child shell the parent's cwd", function()
            assert.equal("/a", record("cd /a; zsh -c python3", "python3").cwd)
            assert.equal("/a", record("cd /a; (python3)", "python3").cwd)
        end)

        it("walks a cd's own substitutions with the cwd before it", function()
            assert.equal("/a", record("cd /a; cd $(cat f)", "cat").cwd)
        end)

        it("does not leak a child shell's cd", function()
            for _, src in ipairs({
                "(cd /x); python3",
                "cd /x | cat; python3",
                "zsh -c 'cd /x'; python3",
                "f() { cd /x; }; python3",
                "echo $(cd /x); python3",
                "cat <(cd /x); python3",
                "cd /x & python3",
                "cd /x &! python3",
                "cd /x &| python3",
                "cd /x && b & python3",
                "timeout 5 cd /x; python3",
            }) do
                assert.equal(nil, record(src, "python3").cwd)
            end
        end)

        it("marks the cwd unknown after an unresolvable cd", function()
            for _, src in ipairs({
                "cd -; python3",
                "cd $D; python3",
                "cd a b; python3",
                "cd ''; python3",
                "pushd /x; python3",
                "cd $D; cd rel; python3",
            }) do
                assert.equal(false, record(src, "python3").cwd)
            end
        end)

        it("gives a cd record the cwd before it runs", function()
            assert.equal(nil, record("cd /x", "cd").cwd)
        end)
    end)

    describe("fail-closed (nil, not empty)", function()
        it("returns nil on a parse error", function()
            assert.equal(nil, ShellParse.extract_commands("rm -f $("))
        end)

        it("returns nil on a substitution command name", function()
            assert.equal(nil, ShellParse.extract_commands("$(echo rm) -rf /"))
        end)

        it("returns nil on an expansion command name", function()
            -- `$R` could resolve to anything; a record named `$R` matches no
            -- block rule, so bail rather than emit a name no guard can catch.
            assert.equal(nil, ShellParse.extract_commands("$VAR -rf /"))
            assert.equal(nil, ShellParse.extract_commands("R=rm; $R -f /"))
            assert.equal(nil, ShellParse.extract_commands("${CMD} -f x"))
        end)

        it("returns nil on a code-taking builtin", function()
            assert.equal(nil, ShellParse.extract_commands('eval "rm -f x"'))
        end)

        it("returns empty for a bare string (parsed, no command)", function()
            assert.same({}, ShellParse.extract_commands("# just a comment"))
        end)

        it("returns nil on a backtick substitution the tree hides", function()
            local parsed = {}
            for _, src in ipairs({
                "echo a`id`b",
                'echo "a`id`"',
                'x="a`id`"',
                'for f in "a`id`"; do :; done',
                'case "a`id`" in *) :;; esac',
                "cat <<EOF\nx `id` y\nEOF",
                "cat <<-EOF\n\t`id`\nEOF",
                "echo `echo \\`id\\``",
                "echo `echo 'a`b'`",
            }) do
                if ShellParse.extract_commands(src) ~= nil then
                    table.insert(parsed, src)
                end
            end
            assert.same({}, parsed)
        end)

        it("returns nil on a line continuation inside a word", function()
            assert.equal(nil, ShellParse.extract_commands("find . -del\\\nete"))
            assert.equal(
                nil,
                ShellParse.extract_commands('echo "$(find . -del\\\nete)"')
            )
        end)

        it(
            "returns nil on a line continuation before an indented line",
            function()
                -- zsh runs `find . -name x -delete`; the tree ends at the newline.
                assert.equal(
                    nil,
                    ShellParse.extract_commands("find . -name\\\n  x -delete")
                )
            end
        )

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
                if ShellParse.parse_zsh(src) == nil then
                    table.insert(rejected, src)
                end
            end
            assert.same({}, rejected)
        end)

        it("keeps parsing a line continuation between words", function()
            assert.is_not_nil(ShellParse.parse_zsh("cmd a \\\n  --flag"))
            assert.is_not_nil(ShellParse.parse_zsh("echo a |\\\ngrep a"))
            assert.is_not_nil(ShellParse.parse_zsh("echo a &&\\\necho b"))
        end)
    end)

    describe("zsh-hang trigger (must not reach parse())", function()
        -- parse() never returns on this input and no in-process mechanism can
        -- interrupt the C loop, so parse_zsh must bail before parsing. If the
        -- guard regressed, this test would hang the whole suite rather than fail.
        it("parse_zsh returns nil without hanging", function()
            assert.equal(nil, ShellParse.parse_zsh("c=${x//[^)]}"))
        end)

        it("extract_commands bails fail-closed on the trigger", function()
            assert.equal(nil, ShellParse.extract_commands("c=${x//[^)]}"))
        end)
    end)

    describe("parse_zsh_untrusted (subprocess termination guard)", function()
        it("returns a walkable root for a normal script body", function()
            -- Exercises the full oracle round-trip: subprocess proves the parse
            -- terminates, then it is re-parsed in-process.
            local root =
                ShellParse.parse_zsh_untrusted("ls /tmp\ngrep foo bar\n")
            assert.is_not_nil(root)
            assert.equal("program", root:type())
        end)

        it(
            "returns nil on the hang trigger (never reaches the oracle)",
            function()
                assert.equal(
                    nil,
                    ShellParse.parse_zsh_untrusted("c=${x//[^)]}")
                )
            end
        )
    end)

    describe("token_is_dynamic arithmetic gate", function()
        --- First named node of `node_type` (DFS) in the parse of `cmd`.
        --- @param cmd string
        --- @param node_type string
        --- @return TSNode
        local function find_node(cmd, node_type)
            local root = ShellParse.parse_zsh(cmd)
            local found
            local function walk(n)
                if found then
                    return
                end
                if n:type() == node_type then
                    found = n
                    return
                end
                for c in n:iter_children() do
                    walk(c)
                end
            end
            walk(root)
            assert.is_not_nil(found)
            return found
        end

        -- Under the gate (arith_static=true) an arithmetic-only token is static;
        -- with the gate off it is dynamic (today's always-dynamic baseline).
        it("classifies a bare arithmetic expansion by the gate", function()
            local node = find_node("sed $((l - 18))", "arithmetic_expansion")
            assert.is_false(ShellParse.token_is_dynamic(node, true))
            assert.is_true(ShellParse.token_is_dynamic(node, false))
        end)

        it("classifies an arithmetic-only string by the gate", function()
            local node = find_node('sed "$((l))p"', "string")
            assert.is_false(ShellParse.token_is_dynamic(node, true))
            assert.is_true(ShellParse.token_is_dynamic(node, false))
        end)

        it("classifies an arithmetic concatenation by the gate", function()
            local node = find_node("sed -$((n))", "concatenation")
            assert.is_false(ShellParse.token_is_dynamic(node, true))
            assert.is_true(ShellParse.token_is_dynamic(node, false))
        end)

        -- Whitelist fail-closed: a var- or command-sub-bearing string stays
        -- dynamic under both gate states — the arithmetic-only carve-out must
        -- not widen to a string with any other expansion child.
        it("keeps a var+arithmetic string dynamic under both", function()
            local node = find_node('sed "$f$((n))"', "string")
            assert.is_true(ShellParse.token_is_dynamic(node, true))
            assert.is_true(ShellParse.token_is_dynamic(node, false))
        end)

        it("keeps a command-sub string dynamic under both", function()
            local node = find_node('sed "x$(ls)"', "string")
            assert.is_true(ShellParse.token_is_dynamic(node, true))
            assert.is_true(ShellParse.token_is_dynamic(node, false))
        end)
    end)
end)
