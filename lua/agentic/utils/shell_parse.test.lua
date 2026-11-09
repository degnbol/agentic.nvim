local assert = require("tests.helpers.assert")
local MiniTest = require("mini.test")
local ShellParse = require("agentic.utils.shell_parse")
local ZshParse = require("agentic.utils.zsh_parse")

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

    describe("$'…' is decoded in every position", function()
        it("delivers a bare $'…' argument decoded and static", function()
            local recs = ShellParse.extract_commands([[echo $'a\tb' $'é']])
            assert.same({ "a\tb", "é" }, recs[1].argv)
            assert.same({ false, false }, recs[1].argv_dynamic)
        end)

        it("decodes a $'…' part of a concatenation", function()
            local recs = ShellParse.extract_commands([[rm -del$'ete']])
            assert.same({ "-delete" }, recs[1].argv)
            assert.same({ false }, recs[1].argv_dynamic)
        end)

        it("decodes a $'…' command name", function()
            assert.same({ "rm" }, names([[$'rm' -rf x]]))
            assert.same({ "rm" }, names([[r$'m' -rf x]]))
            assert.same({ "rm" }, names([[zsh -c r$'m -rf x']]))
        end)

        it("decodes a $'…' redirect target and assignment value", function()
            local rec =
                ShellParse.extract_commands([[a=$'x\ty' cmd > $'/tmp/x']])[1]
            assert.same({ value = "x\ty", dynamic = false }, rec.assignments.a)
            assert.equal("/tmp/x", rec.redirects[1].target)
            assert.is_false(rec.redirects[1].dynamic)
        end)

        it("fails on a NUL byte or an unknown escape", function()
            for _, src in ipairs({
                [[echo $'a\0b']],
                [[echo $'a\x00b']],
                [[echo $'a\400b']],
                [[rm -x$'\q']],
                [[$'\q' -rf x]],
            }) do
                assert.equal(nil, ShellParse.extract_commands(src))
            end
        end)

        it("marks an undecodable redirect target dynamic", function()
            local rec = ShellParse.extract_commands([[cmd > $'\q']])[1]
            assert.is_true(rec.redirects[1].dynamic)
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

        it("records the wrappers a command was unwrapped from", function()
            local recs = ShellParse.extract_commands(
                "timeout 5 uv run python x.py; zsh -c 'ls'; pwd"
            )
            assert.same(
                { { "timeout", "uv" }, { "zsh" }, {} },
                vim.tbl_map(function(r)
                    return r.via
                end, recs)
            )
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

        --- `pipe_from` of each record of `src`, as name lists.
        --- @param src string
        --- @return table<string, string[]|false> by record name, false where
        ---         `pipe_from` is nil
        local function upstream_names(src)
            local recs = ShellParse.extract_commands(src) or {}
            local out = {}
            for _, r in ipairs(recs) do
                out[r.name] = r.pipe_from
                        and vim.tbl_map(function(i)
                            return recs[i].name
                        end, r.pipe_from)
                    or false
            end
            return out
        end

        it("links each pipeline element to the one before it", function()
            assert.same(
                { curl = false, grep = { "curl" }, sh = { "grep" } },
                upstream_names("curl x | grep y | sh")
            )
        end)

        it("links every record of a compound element", function()
            assert.same(
                { echo = false, curl = false, sh = { "echo", "curl" } },
                upstream_names("{ echo; curl x; } | sh")
            )
        end)

        it("links through wrappers and nested pipelines", function()
            assert.same(
                { curl = false, a = { "curl" }, b = { "a" } },
                upstream_names("curl x | { a | b; }")
            )
            assert.same(
                { curl = false, sh = { "curl" } },
                upstream_names("curl x | timeout 5 sh")
            )
        end)

        it("leaves commands outside a pipeline unlinked", function()
            assert.same(
                { curl = false, sh = false },
                upstream_names("curl x; sh")
            )
        end)
    end)

    describe("dynamic names and code-taking builtins", function()
        it("gives a dynamic command name no record", function()
            for _, src in ipairs({ "$VAR -rf /", "${CMD} -f x" }) do
                assert.same({}, ShellParse.extract_commands(src))
            end
            assert.same({ "ls" }, names("$VAR -f x; ls"))
        end)

        it("still collects substitutions in a dynamic command", function()
            assert.same({ "echo" }, names("$(echo rm) -rf /"))
            assert.same({ "id" }, names('$cmd "$(id)"'))
        end)

        it("unwraps an eval of static words", function()
            local recs = ShellParse.extract_commands("eval 'rm -f' x")
            assert.same({ "rm -f x" }, render(recs))
            assert.same({ "eval" }, recs[1].via)
        end)

        it("records an eval with a dynamic argument, source and .", function()
            assert.same(
                { 'eval "rm -f $x"' },
                vim.tbl_map(function(r)
                    return r.name .. " " .. r.argv[1]
                end, ShellParse.extract_commands(
                    'eval "rm -f $x"'
                ))
            )
            assert.same({ "source", ".", "ls" }, names("source a; . b; ls"))
        end)
    end)

    describe("launchers", function()
        it("unwraps launchers to the command they run", function()
            for src, want in pairs({
                ["sudo -u bob rm -f x"] = { "sudo" },
                ["env -i A=1 B=2 rm -f x"] = { "env" },
                ["nice -n 5 rm -f x"] = { "nice" },
                ["nohup rm -f x"] = { "nohup" },
                ["exec rm -f x"] = { "exec" },
                ["builtin eval 'rm -f x'"] = { "builtin", "eval" },
                ["noglob rm -f x"] = { "noglob" },
            }) do
                local recs = ShellParse.extract_commands(src)
                assert.same({ "rm -f x" }, render(recs))
                assert.same(want, recs[1].via)
            end
        end)

        it("reports an action host, then its action commands", function()
            for _, src in ipairs({
                "find . -name x -exec rm -f {} \\;",
                "find . -execdir rm -f {} +",
                "find . -exec rm -f {} ';' -print",
            }) do
                local recs = ShellParse.extract_commands(src)
                assert.same({ "find", "rm" }, names(src))
                assert.same({}, recs[1].via)
                assert.same({ "find" }, recs[2].via)
            end
            assert.same(
                { "find", "echo", "rm" },
                names("find . -exec echo {} \\; -exec rm -f {} \\;")
            )
            assert.same({ "find" }, names("find . -name x -print"))
            local recs = ShellParse.extract_commands("fd -x rm {}")
            assert.same({ "fd", "rm" }, names("fd -x rm {}"))
            assert.same({}, recs[1].argv)
            assert.same({ "fd" }, recs[2].via)
        end)

        it("gives an action in the match's directory an unknown cwd", function()
            local recs = ShellParse.extract_commands("find . -execdir rm {} +")
            assert.equal(nil, recs[1].cwd)
            assert.equal(false, recs[2].cwd)
        end)

        it("ends a launcher's options at --", function()
            assert.same(
                { "rm -f x" },
                render(ShellParse.extract_commands("sudo -- rm -f x"))
            )
        end)

        it("marks a command whose code it could not unwrap opaque", function()
            for _, src in ipairs({
                "sudo --frob rm -f x",
                'zsh -c "rm -f $x"',
                'eval "rm -f $x"',
                "find . -exec rm -f {}",
            }) do
                local recs = ShellParse.extract_commands(src)
                assert.equal(1, #recs)
                assert.equal(true, recs[1].opaque)
            end
            for _, src in ipairs({
                "zsh script.zsh",
                "find . -name x",
                "uv pip list",
                "timeout 5",
                "ls -l",
            }) do
                assert.equal(nil, ShellParse.extract_commands(src)[1].opaque)
            end
        end)

        it("lets a same-shell prefix's cd carry over", function()
            local recs = ShellParse.extract_commands("eval 'cd /x'; ls")
            assert.equal("/x", recs[2].cwd)
            recs = ShellParse.extract_commands("nohup cd /x; ls")
            assert.equal(nil, recs[2].cwd)
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
                record("cd /a && cd ./b && python3", "python3").cwd
            )
            assert.equal("./b", record("cd ./b && python3", "python3").cwd)
            assert.equal(
                "/x",
                record("cd /x 2>/dev/null && python3", "python3").cwd
            )
            assert.equal(vim.env.HOME, record("cd; python3", "python3").cwd)
            assert.equal("/x", record("pushd /x; python3", "python3").cwd)
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
                "cd rel; python3",
                "pushd; python3",
                "popd; python3",
                "cd $D; cd ./rel; python3",
            }) do
                assert.equal(false, record(src, "python3").cwd)
            end
        end)

        it("gives a cd record the cwd before it runs", function()
            assert.equal(nil, record("cd /x", "cd").cwd)
        end)
    end)

    describe("redirects", function()
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

        --- @param op string
        --- @param fd integer|nil
        --- @param target string
        --- @return agentic.utils.ShellParse.Redirect
        local function file(op, fd, target)
            return {
                op = op,
                fd = fd,
                target = target,
                target_fd = false,
                dynamic = false,
            }
        end

        it("records each operator, with and without an fd", function()
            for _, op in ipairs({ ">", ">>", ">|", "&>", "&>>", "<", ">&" }) do
                assert.same(
                    { file(op, nil, "f") },
                    record("a " .. op .. " f", "a").redirects
                )
            end
            for _, op in ipairs({ ">", ">>", ">|", "<" }) do
                assert.same(
                    { file(op, 3, "f") },
                    record("a 3" .. op .. " f", "a").redirects
                )
            end
        end)

        it("tells a descriptor target from a file target", function()
            assert.same({
                {
                    op = ">&",
                    target = "2",
                    target_fd = true,
                    dynamic = false,
                },
            }, record("a >&2", "a").redirects)
            assert.same({
                {
                    op = ">&",
                    fd = 2,
                    target = "1",
                    target_fd = true,
                    dynamic = false,
                },
            }, record("a 2>&1", "a").redirects)
            assert.same({
                {
                    op = "<&",
                    fd = 3,
                    target = "0",
                    target_fd = true,
                    dynamic = false,
                },
            }, record("a 3<&0", "a").redirects)
            assert.same({
                {
                    op = ">&",
                    fd = 2,
                    target = "-",
                    target_fd = true,
                    dynamic = false,
                },
            }, record("a 2>&-", "a").redirects)
            assert.same(
                { file(">&", nil, "f") },
                record("a >& f", "a").redirects
            )
        end)

        it("keeps the shell's order", function()
            assert.same({
                file(">", nil, "f"),
                {
                    op = ">&",
                    fd = 2,
                    target = "1",
                    target_fd = true,
                    dynamic = false,
                },
            }, record("a > f 2>&1", "a").redirects)
        end)

        it("records a herestring with its text", function()
            assert.same({
                {
                    op = "<<<",
                    target = "hi x",
                    target_fd = false,
                    dynamic = false,
                },
            }, record('a <<< "hi x"', "a").redirects)
            assert.same({
                {
                    op = "<<<",
                    fd = 3,
                    target = "x",
                    target_fd = false,
                    dynamic = false,
                },
            }, record("a 3<<< x", "a").redirects)
        end)

        it("leaves heredocs out", function()
            assert.equal(nil, record("a <<EOF\nx\nEOF", "a").redirects)
        end)

        it("marks a dynamic target", function()
            assert.same({
                {
                    op = ">",
                    target = "$f",
                    target_fd = false,
                    dynamic = true,
                },
            }, record("a > $f", "a").redirects)
            assert.same({
                {
                    op = ">",
                    target = '"$d/x"',
                    target_fd = false,
                    dynamic = true,
                },
            }, record('a > "$d/x"', "a").redirects)
            assert.same({
                {
                    op = ">&",
                    target = "$fd",
                    target_fd = false,
                    dynamic = true,
                },
            }, record("a >& $fd", "a").redirects)
        end)

        it("delivers a quoted static target unquoted", function()
            assert.same(
                { file(">", nil, "a b") },
                record("a > 'a b'", "a").redirects
            )
        end)

        it("does not read a quoted > as a redirect", function()
            assert.equal(nil, record('echo "2>/dev/null"', "echo").redirects)
        end)

        it(
            "applies a list's or pipeline's redirect to its last command",
            function()
                for _, src in ipairs({
                    "a | b > f",
                    "a && b > f",
                    "! a | b > f",
                }) do
                    assert.equal(nil, record(src, "a").redirects)
                    assert.same(
                        { file(">", nil, "f") },
                        record(src, "b").redirects
                    )
                end
            end
        )

        it(
            "applies a compound statement's redirect to every command inside",
            function()
                for _, src in ipairs({
                    "{ a; b; } > f",
                    "(a; b) > f",
                    "for x in 1; do a; b; done > f",
                    "if a; then b; fi > f",
                    "while a; do b; done > f",
                }) do
                    assert.same(
                        { file(">", nil, "f") },
                        record(src, "a").redirects
                    )
                    assert.same(
                        { file(">", nil, "f") },
                        record(src, "b").redirects
                    )
                end
            end
        )

        it("puts the enclosing redirects first", function()
            assert.same(
                { file(">", nil, "f"), file(">", 2, "e") },
                record("{ a 2> e; } > f", "a").redirects
            )
        end)

        it(
            "does not apply a command's redirect to its substitutions",
            function()
                assert.equal(nil, record("echo $(a) > f", "a").redirects)
            end
        )

        it("carries a launcher's redirects to the command it runs", function()
            for _, src in ipairs({
                "timeout 9 nvim x 2>/dev/null",
                "zsh -c 'nvim x' 2>/dev/null",
                "script -q /dev/null nvim x 2>/dev/null",
            }) do
                assert.same(
                    { file(">", 2, "/dev/null") },
                    record(src, "nvim").redirects
                )
            end
            assert.same(
                { file(">", 2, "/dev/null"), file(">", nil, "f") },
                record("timeout 9 zsh -c 'nvim > f' 2>/dev/null", "nvim").redirects
            )
            assert.same(
                { file(">", 2, "/dev/null") },
                record("find . -exec rm {} \\; 2>/dev/null", "rm").redirects
            )
        end)

        it(
            "gives the words after a redirect target back to the command",
            function()
                local rec = record("rm a.lua 2>/dev/null b.lua", "rm")
                assert.same({ "a.lua", "b.lua" }, rec.argv)
                assert.same({ "a.lua", "b.lua" }, rec.args)
                assert.same({ file(">", 2, "/dev/null") }, rec.redirects)
                rec = record("rm -f a 2>/dev/null -r b > f c", "rm")
                assert.same({ "-f", "a", "-r", "b", "c" }, rec.argv)
                assert.same({ "-f", "-r" }, rec.flags)
                assert.same({ "a", "b", "c" }, rec.args)
                assert.same(
                    { "a", "b" },
                    record("timeout 5 rm a 2>/dev/null b", "rm").argv
                )
                assert.same(
                    { "-l", "x", "$__xargs_stdin" },
                    record("xargs grep -l 2>/dev/null x", "grep").argv
                )
                assert.same({ "c" }, record("a | b 2>/dev/null c", "b").argv)
                assert.same(
                    { "-o", "/etc/x" },
                    record("sort <<'EOF' -o /etc/x\nhi\nEOF", "sort").argv
                )
            end
        )

        it(
            "flattens a substitution in a word after a redirect target once",
            function()
                assert.same({ "a", "b" }, names("a 2>/dev/null $(b)"))
                assert.same({ "a", "b" }, names("a <<'EOF' $(b)\nx\nEOF"))
            end
        )

        it(
            "does not unwrap a launcher whose inner starts after a redirect",
            function()
                for _, src in ipairs({
                    "timeout 2>/dev/null 5 rm a",
                    "nice 2>/dev/null -n 5 rm a",
                }) do
                    local recs = ShellParse.extract_commands(src)
                    assert.equal(1, #recs)
                    assert.equal(true, recs[1].opaque)
                end
            end
        )

        it("flattens a launcher's prefix substitutions", function()
            for _, src in ipairs({
                "> $(rm -rf x) timeout 5 ls",
                "X=$(rm -rf x) timeout 5 ls",
            }) do
                assert.same({ "ls", "rm" }, names(src))
            end
        end)

        it(
            "returns nil for words after a compound statement's redirect",
            function()
                assert.equal(nil, ShellParse.extract_commands("{ a; } > f x"))
            end
        )

        it("records a redirect before the command name first", function()
            local rec = record("> f cmd x", "cmd")
            assert.same({ "x" }, rec.argv)
            assert.same({ file(">", nil, "f") }, rec.redirects)
            assert.same(
                { file(">", nil, "f"), file(">", nil, "g") },
                record("> f cmd > g", "cmd").redirects
            )
        end)

        it("leaves redirects nil when there are none", function()
            assert.equal(nil, record("a x", "a").redirects)
        end)

        describe("zsh clobber forms", function()
            it("reads `!` right after the operator as part of it", function()
                local rec = record("echo a >! /x/a", "echo")
                assert.same({ "a" }, rec.argv)
                assert.same({ file(">!", nil, "/x/a") }, rec.redirects)
                for _, op in ipairs({ ">>", "&>", "&>>" }) do
                    assert.same(
                        { file(op .. "!", nil, "/x/a") },
                        record("echo a " .. op .. "! /x/a", "echo").redirects
                    )
                end
                assert.same(
                    { file(">!", 2, "/x/a") },
                    record("echo a 2>! /x/a", "echo").redirects
                )
            end)

            it("reads a target attached to the `!`", function()
                assert.same(
                    { file(">!", nil, "/x/a") },
                    record("echo a >!/x/a", "echo").redirects
                )
                assert.same({
                    {
                        op = ">!",
                        target = '"$f"',
                        target_fd = false,
                        dynamic = true,
                    },
                }, record('echo a >!"$f"', "echo").redirects)
                assert.same({ "echo", "x" }, names("echo a >!$(x)"))
                assert.same(
                    { file(">!", 2, "/x/a") },
                    record("echo a 2>!/x/a", "echo").redirects
                )
                assert.same(
                    { file("&>>!", nil, "/x/a") },
                    record("echo a &>>!/x/a", "echo").redirects
                )
                assert.same(
                    { file(">!", nil, "f") },
                    record("echo a >!$'f'", "echo").redirects
                )
            end)

            it(
                "reads a substitution right after the `!` as the target",
                function()
                    local rec = record("echo a >!<(x)", "echo")
                    assert.same({ "a" }, rec.argv)
                    assert.equal(">!", rec.redirects[1].op)
                    assert.equal("<(x)", rec.redirects[1].target)
                end
            )

            it(
                "gives the words after the target back to the command",
                function()
                    local rec = record('echo a >! "$f"', "echo")
                    assert.same({ "a" }, rec.argv)
                    assert.is_true(rec.redirects[1].dynamic)
                    assert.same(
                        { "a", "b" },
                        record("echo a >! /x/a b", "echo").argv
                    )
                end
            )

            it("reads a spaced or escaped `!` as a file name", function()
                local rec = record("echo a > ! /x/a", "echo")
                assert.same({ "a", "/x/a" }, rec.argv)
                assert.same({ file(">", nil, "!") }, rec.redirects)
                assert.same(
                    { file(">", nil, "!") },
                    record("echo a >\\! f", "echo").redirects
                )
            end)

            it("reads a clobber redirect before the command name", function()
                local rec = record(">!f cmd", "cmd")
                assert.same({ file(">!", nil, "f") }, rec.redirects)
                -- The grammar takes the spaced target for the command name.
                assert.equal(nil, ShellParse.extract_commands(">! f cmd"))
            end)

            it("records a clobber redirect without a target", function()
                assert.same({
                    {
                        op = ">!",
                        target = "",
                        target_fd = false,
                        dynamic = true,
                    },
                }, record("echo a >!", "echo").redirects)
            end)
        end)
    end)

    describe("assignments", function()
        --- The prefix assignments of the record named `name` in `src`.
        --- @param src string
        --- @param name string
        --- @return table<string, agentic.utils.ShellParse.Assignment>|nil
        local function assignments(src, name)
            for _, r in ipairs(ShellParse.extract_commands(src) or {}) do
                if r.name == name then
                    return r.assignments
                end
            end
            error("no record " .. name .. " in " .. src)
        end

        it("records static values unquoted", function()
            assert.same(
                { IFS = { value = "\t", dynamic = false } },
                assignments("IFS=$'\\t' read x", "read")
            )
            assert.same({
                A = { value = "a b", dynamic = false },
                B = { value = "c", dynamic = false },
                C = { value = "", dynamic = false },
            }, assignments([[A="a b" B='c' C="" cmd]], "cmd"))
        end)

        it("decodes $'…' escapes", function()
            assert.same(
                { A = { value = "a\n\27A\0011'", dynamic = false } },
                assignments([[A=$'a\n\e\x41\0011\'' cmd]], "cmd")
            )
        end)

        it("marks dynamic values", function()
            assert.same({
                A = { value = "$x", dynamic = true },
                B = { value = '"$(y)"', dynamic = true },
                C = { value = "x", dynamic = true },
                D = { value = [[$'\q']], dynamic = true },
            }, assignments(
                [[A=$x B="$(y)" C+=x D=$'\q' cmd]],
                "cmd"
            ))
        end)

        it(
            "carries a launcher's prefix assignments and env operands",
            function()
                assert.same(
                    { FOO = { value = "1", dynamic = false } },
                    assignments("FOO=1 timeout 5 cmd", "cmd")
                )
                assert.same(
                    { IFS = { value = "x", dynamic = false } },
                    assignments("env IFS=x read", "read")
                )
                assert.same(
                    { IFS = { value = '"$x"', dynamic = true } },
                    assignments('env -i IFS="$x" read', "read")
                )
                assert.same({
                    A = { value = "1", dynamic = false },
                    B = { value = "2", dynamic = false },
                }, assignments("A=1 env B=2 cmd", "cmd"))
                assert.same(
                    { A = { value = "2", dynamic = false } },
                    assignments("env A=1 zsh -c 'A=2 cmd'", "cmd")
                )
                assert.same(
                    { C = { value = "d=x", dynamic = false } },
                    assignments("env -C d=x C=d=x cmd", "cmd")
                )
            end
        )

        it(
            "does not apply a command's assignments to its substitutions",
            function()
                assert.equal(nil, assignments("A=1 echo $(b)", "b"))
            end
        )

        it("leaves assignments nil when there are none", function()
            assert.equal(nil, assignments("a x", "a"))
        end)
    end)

    describe("script", function()
        it("unwraps BSD script's command after the transcript file", function()
            local recs =
                ShellParse.extract_commands("script -q /dev/null nvim x")
            assert.same({ "nvim x" }, render(recs))
            assert.same({ "script" }, recs[1].via)
        end)

        it("unwraps util-linux script's -c command", function()
            for _, src in ipairs({
                "script -c 'nvim x' /dev/null",
                "script -q --command 'nvim x' log",
                "script -qc 'nvim x' log",
            }) do
                local recs = ShellParse.extract_commands(src)
                assert.same({ "nvim x" }, render(recs))
                assert.same({ "script" }, recs[1].via)
            end
        end)

        it("is a plain record without a command", function()
            for _, src in ipairs({ "script", "script -q log", "script -p log" }) do
                local recs = ShellParse.extract_commands(src)
                assert.same({ "script" }, names(src))
                assert.equal(nil, recs[1].opaque)
            end
        end)

        it("is opaque when its command does not resolve", function()
            for _, src in ipairs({ 'script -c "$x"', "script -t 0 log nvim" }) do
                assert.equal(true, ShellParse.extract_commands(src)[1].opaque)
            end
        end)
    end)

    describe("fail-closed (nil, not empty)", function()
        it("returns nil on a parse error", function()
            assert.equal(nil, ShellParse.extract_commands("rm -f $("))
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
    end)

    describe("zsh-hang trigger (must not reach parse())", function()
        -- parse() never returns on this input and no in-process mechanism can
        -- interrupt the C loop, so `ZshParse.parse` must bail before parsing. If the
        -- guard regressed, this test would hang the whole suite rather than fail.
        it("extract_commands bails fail-closed on the trigger", function()
            assert.equal(nil, ShellParse.extract_commands("c=${x//[^)]}"))
        end)
    end)

    describe("token_is_dynamic arith_static", function()
        --- First named node of `node_type` (DFS) in the parse of `cmd`.
        --- @param cmd string
        --- @param node_type string
        --- @return TSNode
        local function find_node(cmd, node_type)
            local root = ZshParse.parse(cmd)
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

        -- With arith_static an arithmetic-only token is static; without it,
        -- dynamic.
        it("classifies a bare arithmetic expansion by arith_static", function()
            local node = find_node("sed $((40 - 18))", "arithmetic_expansion")
            assert.is_false(ShellParse.token_is_dynamic(node, true))
            assert.is_true(ShellParse.token_is_dynamic(node, false))
        end)

        it("classifies an arithmetic-only string by arith_static", function()
            local node = find_node('sed "$((40))p"', "string")
            assert.is_false(ShellParse.token_is_dynamic(node, true))
            assert.is_true(ShellParse.token_is_dynamic(node, false))
        end)

        it("classifies an arithmetic concatenation by arith_static", function()
            local node = find_node("sed -$((5))", "concatenation")
            assert.is_false(ShellParse.token_is_dynamic(node, true))
            assert.is_true(ShellParse.token_is_dynamic(node, false))
        end)

        -- Whitelist fail-closed: a var- or command-sub-bearing string stays
        -- dynamic either way — the arithmetic-only carve-out must
        -- not widen to a string with any other expansion child.
        it("keeps a var+arithmetic string dynamic under both", function()
            local node = find_node('sed "$f$((5))"', "string")
            assert.is_true(ShellParse.token_is_dynamic(node, true))
            assert.is_true(ShellParse.token_is_dynamic(node, false))
        end)

        it("keeps a command-sub string dynamic under both", function()
            local node = find_node('sed "x$(ls)"', "string")
            assert.is_true(ShellParse.token_is_dynamic(node, true))
            assert.is_true(ShellParse.token_is_dynamic(node, false))
        end)
    end)

    describe("is_safe_var_name", function()
        it("rejects names that change execution", function()
            local safe = {}
            for _, name in ipairs({
                "path",
                "path[1]",
                "functions",
                "options",
                "mapfile",
                "http_proxy",
                "npm_config_x",
                "chpwd_functions",
                "zshexit_functions",
                "_JAVA_OPTIONS",
                "PATH",
            }) do
                if ShellParse.is_safe_var_name(name) then
                    table.insert(safe, name)
                end
            end
            assert.same({}, safe)
        end)

        it("accepts scratch names", function()
            local unsafe = {}
            for _, name in ipairs({
                "f",
                "dir",
                "X",
                "out_file",
                "outDir",
                "x[1]",
                "LANG",
            }) do
                if not ShellParse.is_safe_var_name(name) then
                    table.insert(unsafe, name)
                end
            end
            assert.same({}, unsafe)
        end)
    end)

    describe("builtin_bind_targets", function()
        it("names printf -v targets", function()
            assert.same(
                { "a", "b" },
                ShellParse.builtin_bind_targets(
                    "printf",
                    { "-v", "a", "-vb", "%s", "x" },
                    { false, false, false, false, false }
                )
            )
        end)

        it("names every read operand", function()
            assert.same(
                { "a", "b" },
                ShellParse.builtin_bind_targets(
                    "read",
                    { "-A", "a", "b" },
                    { false, false, false }
                )
            )
        end)

        it("skips read option values", function()
            local cases = {
                { { "-t", "5", "line" }, { "line" } },
                { { "-r", "-d", "", "f" }, { "f" } },
                { { "-rd:", "a" }, { "a" } },
                { { "-u", "3", "line" }, { "line" } },
                -- zsh binds a non-number after `-t` as a name.
                { { "-t", "path" }, { "path" } },
            }
            for _, case in ipairs(cases) do
                assert.same(
                    case[2],
                    ShellParse.builtin_bind_targets(
                        "read",
                        case[1],
                        vim.tbl_map(function()
                            return false
                        end, case[1])
                    )
                )
            end
        end)

        it("names print -v targets past other options", function()
            assert.same(
                { "path" },
                ShellParse.builtin_bind_targets(
                    "print",
                    { "-f", "%s", "-v", "path", "x" },
                    { false, false, false, false, false }
                )
            )
        end)

        it("strips a read prompt", function()
            assert.same(
                { "x" },
                ShellParse.builtin_bind_targets("read", { "x?p" }, { false })
            )
        end)

        it("returns nil for a dynamic target", function()
            assert.is_nil(
                ShellParse.builtin_bind_targets("read", { "$x" }, { true })
            )
            assert.is_nil(
                ShellParse.builtin_bind_targets(
                    "printf",
                    { "-v", "$x", "%s" },
                    { false, true, false }
                )
            )
        end)

        it(
            "returns nil for a dynamic word in printf option position",
            function()
                assert.is_nil(
                    ShellParse.builtin_bind_targets(
                        "printf",
                        { "$x", "path", "y" },
                        { true, false, false }
                    )
                )
            end
        )

        it("returns no targets for other commands", function()
            assert.same(
                {},
                ShellParse.builtin_bind_targets("echo", { "$x" }, { true })
            )
        end)
    end)

    describe("function_names", function()
        --- @param src string a single function definition
        --- @return string[]|nil
        local function names_of(src)
            local root = ZshParse.parse(src) --[[@as TSNode]]
            return ShellParse.function_names(
                root:named_child(0) --[[@as TSNode]],
                src
            )
        end

        it("returns every name of a multi-name definition", function()
            assert.same({ "ls", "cat" }, names_of("function ls cat { :; }"))
        end)

        it("removes quoting like a command word", function()
            assert.same({ "ls" }, names_of("l\\s() { :; }"))
        end)

        it("keeps a path name as written", function()
            assert.same({ "/bin/ls" }, names_of("/bin/ls() { :; }"))
        end)

        it("returns nil for an anonymous function", function()
            assert.is_nil(names_of("() { :; }"))
        end)
    end)

    describe("command_name", function()
        --- @param src string a single command
        --- @return string|nil
        local function name_of(src)
            local root = ZshParse.parse(src) --[[@as TSNode]]
            return ShellParse.command_name(
                root:named_child(0) --[[@as TSNode]],
                src
            )
        end

        it("keeps the path as written", function()
            assert.equal("/usr/bin/timeout", name_of("/usr/bin/timeout 5 ls"))
        end)

        it("is nil for a dynamic name", function()
            assert.is_nil(name_of("$x foo"))
        end)
    end)

    describe("leading_path", function()
        it("resolves a single-quoted path", function()
            assert.equal("/a b/x.sh", ShellParse.leading_path("'/a b/x.sh'"))
        end)

        it("resolves a double-quoted path", function()
            assert.equal(
                "/a b/x.sh",
                ShellParse.leading_path('"/a b/x.sh" --flag')
            )
        end)

        it("resolves an escaped space", function()
            assert.equal("a b/x.sh", ShellParse.leading_path("a\\ b/x.sh"))
        end)

        it("keeps a tilde unexpanded", function()
            assert.equal("~/x.sh", ShellParse.leading_path("~/x.sh"))
        end)

        it("is nil for a name without a slash", function()
            assert.is_nil(ShellParse.leading_path("python3 x.py"))
        end)

        it("is nil for a path built from an expansion", function()
            assert.is_nil(
                ShellParse.leading_path(
                    '"$CLAUDE_PROJECT_DIR"/.claude/hooks/x.sh'
                )
            )
        end)
    end)

    describe("runs_without_call", function()
        it("is true for names zsh calls on its own", function()
            for _, name in ipairs({
                "chpwd",
                "zshexit",
                "precmd",
                "TRAPEXIT",
                "TRAPZERR",
                "command_not_found_handler",
                "zsh_directory_name",
            }) do
                assert.is_true(ShellParse.runs_without_call(name))
            end
        end)

        it("is false for other names", function()
            assert.is_false(ShellParse.runs_without_call("ls"))
            assert.is_false(ShellParse.runs_without_call("chpwd_functions"))
        end)
    end)

    describe("host_actions", function()
        --- `host_actions` of the single command `src`.
        --- @param src string
        --- @return agentic.utils.ShellParse.HostActions|nil
        local function actions_of(src)
            local node = ZshParse.parse(src):named_child(0)
            assert.equal("command", node:type())
            local args, arg_nodes, args_dynamic = {}, {}, {}
            for child in node:iter_children() do
                if child:named() and child:type() ~= "command_name" then
                    table.insert(args, ShellParse.literal_token(child, src))
                    table.insert(arg_nodes, child)
                    table.insert(
                        args_dynamic,
                        ShellParse.token_is_dynamic(child)
                    )
                end
            end
            args, arg_nodes, args_dynamic = ShellParse.join_adjacent_args(
                args,
                arg_nodes,
                args_dynamic,
                src
            )
            local name = ShellParse.command_name(node, src)
            return ShellParse.host_actions(name, args, args_dynamic)
        end

        --- `actions_of`, asserted to resolve.
        --- @param src string
        --- @return agentic.utils.ShellParse.HostActions
        local function resolved(src)
            local actions = actions_of(src)
            assert.is_not_nil(actions)
            return actions --[[@as agentic.utils.ShellParse.HostActions]]
        end

        it("replaces a placeholder word with a dynamic path", function()
            local actions = resolved("find . -exec rm -f {} \\;")
            assert.equal("'rm' '-f' $__exec_path", actions.inner)
            assert.same({ "." }, actions.args)
            assert.same({ false }, actions.args_dynamic)
            assert.is_false(actions.foreign_cwd)
        end)

        it("puts each action on its own line", function()
            local actions =
                resolved("find . -exec echo {} \\; -print -exec wc {} +")
            assert.equal(
                "'echo' $__exec_path\n'wc' $__exec_path",
                actions.inner
            )
            assert.same({ ".", "-print" }, actions.args)
        end)

        it("ends a find action at + only directly after {}", function()
            assert.equal(
                "'sort' '+' '-o' 'out' $__exec_path",
                resolved("find . -exec sort + -o out {} \\;").inner
            )
            local actions = resolved("find . -exec rm {} + -print")
            assert.equal("'rm' $__exec_path", actions.inner)
            assert.same({ ".", "-print" }, actions.args)
        end)

        it("single-quotes each action word as delivered", function()
            assert.equal(
                "'grep' '-n' 'a b' $__exec_path",
                resolved("find . -exec grep -n 'a b' {} +").inner
            )
            assert.equal(
                [['cat' 'it'\''s' 'X=1']],
                resolved([[find . -exec cat "it's" X=1 \;]]).inner
            )
        end)

        it("appends fd's path to an action without a placeholder", function()
            assert.equal("'file' $__exec_path", resolved("fd -x file").inner)
            assert.equal(
                "'mv' $__exec_path $__exec_path",
                resolved("fd -x mv {} {.}.bak").inner
            )
            local actions = resolved("fd -x echo \\; -H")
            assert.equal("'echo' $__exec_path", actions.inner)
            assert.same({ "-H" }, actions.args)
            assert.equal(
                "'wc' '-l' $__exec_path",
                resolved("fd -t f -X wc -l").inner
            )
        end)

        it("makes an option token inside a fd action a word of it", function()
            assert.equal(
                "'echo' '-x' 'rm' $__exec_path",
                resolved("fd -x echo -x rm").inner
            )
        end)

        it("marks an action outside the cwd", function()
            for _, src in ipairs({
                "find . -execdir rm {} \\;",
                "find . -okdir rm {} \\;",
                "fd --base-directory d -x rm foo",
                "fd --base-directory=d -x rm foo",
                "fd -C d -x rm foo",
                "fd -HC d -x rm foo",
            }) do
                assert.is_true(resolved(src).foreign_cwd)
            end
        end)

        it("is nil when the slice does not resolve", function()
            for _, src in ipairs({
                "find . -name x",
                "ls -exec rm {} \\;",
                "find . -exec rm {}",
                "find . -exec \\;",
                "fd -x",
                "fd -x echo $t -x rm {}",
                "fd --exec=echo",
                "fd -Hx echo",
                "find . -exec cat ';x' -delete -exec cat {} \\;",
                "find . -exec cat {} +x -delete -exec cat {} \\;",
                "fd --and -x cat -x rm {}",
                "find -f -exec cat -exec rm {} \\;",
                "find . -fprintf /dev/null -exec -delete -exec true \\;",
                "find . $x -exec cat {} \\;",
                "fd -- -x echo",
                "fd -x echo '{{}}'",
                "fd -x echo '{{x}}'",
                "find . -exec zsh ~/x \\;",
            }) do
                assert.is_nil(actions_of(src))
            end
        end)

        it("lets an action follow a self-contained --opt=value", function()
            assert.equal(
                "'cat' $__exec_path",
                resolved("fd --type=f -x cat").inner
            )
        end)
    end)
end)

describe("ShellParse.cd_target", function()
    local home = vim.env.HOME

    it("knows the operands that name one directory", function()
        assert.equal(home, ShellParse.cd_target("cd", {}, {}))
        assert.equal(home, ShellParse.cd_target("cd", { "~" }, { false }))
        assert.equal(
            home .. "/a",
            ShellParse.cd_target("chdir", { "~/a" }, { false })
        )
        assert.equal("/b", ShellParse.cd_target("cd", { "/a/../b" }, { false }))
        assert.equal("./a", ShellParse.cd_target("cd", { "./a" }, { false }))
        assert.equal(
            "../a",
            ShellParse.cd_target("pushd", { "../a" }, { false })
        )
    end)

    it("is false for operands it cannot pin", function()
        for _, case in ipairs({
            { "cd", { "-" } },
            { "cd", { "-P", "/x" } },
            { "cd", { "name" } },
            { "cd", { "" } },
            { "cd", { "~u" } },
            { "cd", { "~+" } },
            { "cd", { "~-" } },
            { "cd", { "~1" } },
            { "cd", { "/a", "/b" } },
            { "pushd", {} },
        }) do
            local dynamic = vim.tbl_map(function()
                return false
            end, case[2])
            assert.is_false(ShellParse.cd_target(case[1], case[2], dynamic))
        end
        assert.is_false(ShellParse.cd_target("cd", { "$d" }, { true }))
    end)
end)

describe("ShellParse.command_cwds", function()
    --- @type agentic.utils.ShellParse.Cwds
    local START = { dirs = { "/s/t" }, unknown = false }
    --- @type agentic.utils.ShellParse.Cwds
    local UNKNOWN = { dirs = {}, unknown = true }

    --- The first node in `root` (pre-order) passing `pred`; errors when none
    --- does.
    --- @param root TSNode
    --- @param pred fun(node: TSNode): boolean
    --- @return TSNode
    local function find(root, pred)
        local function visit(node)
            if pred(node) then
                return node
            end
            for child in node:iter_children() do
                local hit = visit(child)
                if hit then
                    return hit
                end
            end
        end
        return visit(root) or error("no matching node")
    end

    --- The sorted possible cwds of the first command named `name` in `src`,
    --- or "unknown".
    --- @param src string
    --- @param name string
    --- @param start agentic.utils.ShellParse.Cwds|nil default START
    --- @param source_cwds (fun(path: string, before: agentic.utils.ShellParse.Cwds): agentic.utils.ShellParse.Cwds)|nil
    --- @return string[]|"unknown"
    local function dirs_of(src, name, start, source_cwds)
        local root = ZshParse.parse(src) --[[@as TSNode]]
        local cwd_of =
            ShellParse.command_cwds(root, src, start or START, source_cwds)
        local node = find(root, function(n)
            return n:type() == "command"
                and ShellParse.command_name(n, src) == name
        end)
        local cwds = cwd_of[node:id()]
        if cwds.unknown then
            return "unknown"
        end
        local dirs = vim.deepcopy(cwds.dirs)
        table.sort(dirs)
        return dirs
    end

    it("follows && and || to the branch that runs", function()
        assert.same({ "/x" }, dirs_of("cd /x && r", "r"))
        assert.same({ "/s/t" }, dirs_of("cd /x || r", "r"))
        assert.same({ "/s/t", "/x" }, dirs_of("cd /x; r", "r"))
        assert.same({ "/s/t", "/x" }, dirs_of("cd /x && false || r", "r"))
        assert.same({ "/x" }, dirs_of("! cd /x || r", "r"))
    end)

    it("joins a ./ or ../ target to each possible cwd", function()
        assert.same({ "/s/t/sub" }, dirs_of("cd ./sub && r", "r"))
        assert.same({ "/s/u" }, dirs_of("cd ../u && r", "r"))
        assert.same({ "/s/t/a", "/x/a" }, dirs_of("cd /x; cd ./a && r", "r"))
        assert.equal("unknown", dirs_of("cd ./sub && r", "r", UNKNOWN))
        assert.same({ "/x" }, dirs_of("cd /x && r", "r", UNKNOWN))
    end)

    it("expands a home target", function()
        assert.same({ vim.env.HOME }, dirs_of("cd && r", "r"))
        assert.same({ vim.env.HOME .. "/p" }, dirs_of("cd ~/p && r", "r"))
    end)

    it("is unknown after a cd it cannot pin", function()
        for _, src in ipairs({
            "cd sub && r",
            'cd "$d" && r',
            "cd - && r",
            "cd -P /x && r",
            "cd ~u && r",
            "pushd && r",
            "popd; r",
            "cd 2>/dev/null /x; r",
        }) do
            assert.equal("unknown", dirs_of(src, "r"))
        end
    end)

    it("reads cd through a same-shell prefix", function()
        assert.same({ "/x" }, dirs_of("command cd /x && r", "r"))
        assert.same({ "/s/t/y" }, dirs_of("builtin cd ./y && r", "r"))
        assert.equal("unknown", dirs_of("command -p cd /x; r", "r"))
    end)

    it("starts each if branch from its condition's outcome", function()
        assert.same({ "/x" }, dirs_of("if cd /x; then r; fi", "r"))
        assert.same({ "/s/t" }, dirs_of("if cd /x; then :; else r; fi", "r"))
        assert.same(
            { "/s/t" },
            dirs_of("if cd /x; then :; elif r; then :; fi", "r")
        )
        assert.same({ "/s/t", "/x" }, dirs_of("if a; then cd /x; fi; r", "r"))
        assert.same(
            { "/s/t", "/x", "/y" },
            dirs_of("if a; then cd /x; else cd /y; fi; r", "r")
        )
    end)

    it("joins every case body with the set before it", function()
        assert.same(
            { "/s/t", "/x", "/y" },
            dirs_of("case $v in a) cd /x;; b) cd /y;; esac; r", "r")
        )
    end)

    it("flows through a brace group", function()
        assert.same({ "/x" }, dirs_of("{ cd /x; } && r", "r"))
    end)

    it("does not leak a child shell's cd", function()
        for _, src in ipairs({
            "(cd /x); r",
            "echo $(cd /x); r",
            "cat <(cd /x); r",
            "cd /x | cat; r",
            "cd /x & r",
        }) do
            assert.same({ "/s/t" }, dirs_of(src, "r"))
        end
        -- bash and sh run every pipeline element in a subshell.
        assert.same({ "/s/t", "/x" }, dirs_of("echo | cd /x && r", "r"))
    end)

    it("reads a quoted ~ as a directory named ~", function()
        assert.same({ "/s/t/~" }, dirs_of("cd '~' && r", "r"))
    end)

    it("starts a case body at every earlier body's exit", function()
        assert.same(
            { "/s/t", "/x" },
            dirs_of("case v in v) cd /x ;& w) :;; *) r;; esac", "r")
        )
    end)

    it("gives a substitution the set of the command holding it", function()
        assert.same({ "/x" }, dirs_of("cd /x && cat $(r)", "r"))
    end)

    it("widens a loop that changes directory", function()
        assert.same(
            { "/s/t", "/x" },
            dirs_of("while a; do cd /x; done; r", "r")
        )
        assert.same(
            { "/s/t", "/x" },
            dirs_of("for i in a; do r; cd /x; done", "r")
        )
        assert.equal("unknown", dirs_of("for i in a; do cd ./x; done; r", "r"))
        assert.same({ "/s/t" }, dirs_of("for i in a; do b; done; r", "r"))
    end)

    it("judges a function body from an unknown cwd", function()
        assert.equal("unknown", dirs_of("f() { r; }", "r"))
        assert.same({ "/s/t", "/x" }, dirs_of("f() { cd /x; }; r", "r"))
        assert.equal("unknown", dirs_of("f() { cd ./x; }; r", "r"))
    end)

    it("takes a sourced file's exit set from the callback", function()
        assert.equal("unknown", dirs_of("source ./a.sh; r", "r"))
        local calls = {}
        local exit = dirs_of(
            "cd /x && source ./a.sh && r",
            "r",
            nil,
            function(path, before)
                table.insert(calls, { path, before })
                return { dirs = { "/z" }, unknown = false }
            end
        )
        assert.same({ "/z" }, exit)
        assert.same(
            { { "./a.sh", { dirs = { "/x" }, unknown = false } } },
            calls
        )
    end)

    it("gives up past 8 possible directories", function()
        local items = {}
        for i = 1, 9 do
            table.insert(items, ("%d) cd /%d;;"):format(i, i))
        end
        local src = "case $v in " .. table.concat(items, " ") .. " esac; r"
        assert.equal("unknown", dirs_of(src, "r"))
    end)

    it("maps a redirected statement to its redirect target's set", function()
        local src = "cd /x && cat > f"
        local root = ZshParse.parse(src) --[[@as TSNode]]
        local cwd_of = ShellParse.command_cwds(root, src, START)
        local stmt = find(root, function(n)
            return n:type() == "redirected_statement"
        end)
        assert.same({ dirs = { "/x" }, unknown = false }, cwd_of[stmt:id()])
    end)

    it("returns the set after the whole tree", function()
        local src = "cd /x"
        local _, exit = ShellParse.command_cwds(
            ZshParse.parse(src) --[[@as TSNode]],
            src,
            START
        )
        assert.same({ "/s/t", "/x" }, vim.fn.sort(exit.dirs))
    end)
end)

describe("ShellParse.resolve_against_cwd", function()
    it("joins a relative path to the given cwd", function()
        assert.equal(
            "/nonexistent-root/a/b",
            ShellParse.resolve_against_cwd("b", "/nonexistent-root/a")
        )
        assert.equal(
            "/nonexistent-root/b",
            ShellParse.resolve_against_cwd("/nonexistent-root/b", "/elsewhere")
        )
    end)

    it("resolves .. after a symlink physically", function()
        local base = vim.fn.resolve(vim.fn.tempname())
        vim.fn.mkdir(base .. "/real/sub", "p")
        vim.uv.fs_symlink(base .. "/real/sub", base .. "/link")
        MiniTest.finally(function()
            vim.fs.rm(base, { recursive = true })
        end)
        assert.equal(
            base .. "/real/x",
            ShellParse.resolve_against_cwd("link/../x", base)
        )
    end)
end)
