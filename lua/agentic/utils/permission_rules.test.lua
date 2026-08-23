local assert = require("tests.helpers.assert")
local PermissionRules = require("agentic.utils.permission_rules")

describe("PermissionRules", function()
    describe("glob_to_lua_pattern", function()
        it("converts simple glob with trailing *", function()
            local pat = PermissionRules.glob_to_lua_pattern("grep *")
            assert.equal("^grep .*$", pat)
        end)

        it("converts glob with no wildcard", function()
            local pat = PermissionRules.glob_to_lua_pattern("ls")
            assert.equal("^ls$", pat)
        end)

        it("escapes Lua magic characters", function()
            local pat = PermissionRules.glob_to_lua_pattern("git (status)")
            assert.equal("^git %(status%)$", pat)
        end)

        it("converts glob with multiple wildcards", function()
            local pat = PermissionRules.glob_to_lua_pattern("cd * && git *log*")
            assert.equal("^cd .* && git .*log.*$", pat)
        end)
    end)

    describe("extract_bash_patterns", function()
        it("extracts Bash(...) entries from allow list", function()
            local permissions = {
                allow = {
                    "Bash(grep *)",
                    "Bash(ls)",
                    "Read(**)",
                    "WebSearch",
                },
            }
            local patterns =
                PermissionRules.extract_bash_patterns(permissions, "allow")
            assert.equal(2, #patterns)
            assert.equal("grep *", patterns[1].original)
            assert.equal("ls", patterns[2].original)
        end)

        it("returns empty for missing list", function()
            local patterns = PermissionRules.extract_bash_patterns({}, "allow")
            assert.equal(0, #patterns)
        end)

        it("skips non-Bash entries", function()
            local permissions = {
                allow = { "Read(**)", "Glob(**)" },
            }
            local patterns =
                PermissionRules.extract_bash_patterns(permissions, "allow")
            assert.equal(0, #patterns)
        end)
    end)

    describe("strip_command_path", function()
        it("strips /usr/bin/ prefix", function()
            assert.equal(
                "grep foo",
                PermissionRules.strip_command_path("/usr/bin/grep foo")
            )
        end)

        it("strips /bin/ prefix", function()
            assert.equal(
                "ls -la",
                PermissionRules.strip_command_path("/bin/ls -la")
            )
        end)

        it("strips /opt/homebrew/bin/ prefix", function()
            assert.equal(
                "rg foo",
                PermissionRules.strip_command_path("/opt/homebrew/bin/rg foo")
            )
        end)

        it("leaves a non-system path intact", function()
            assert.equal(
                "/tmp/evil/grep foo",
                PermissionRules.strip_command_path("/tmp/evil/grep foo")
            )
        end)

        it("leaves a bare command unchanged", function()
            assert.equal(
                "grep foo",
                PermissionRules.strip_command_path("grep foo")
            )
        end)
    end)

    describe("matches_any_pattern", function()
        it("matches simple command", function()
            local patterns = {
                {
                    original = "grep *",
                    lua_pattern = PermissionRules.glob_to_lua_pattern("grep *"),
                },
            }
            assert.is_true(
                PermissionRules.matches_any_pattern("grep -r 'foo' .", patterns)
            )
        end)

        it("does not match unrelated command", function()
            local patterns = {
                {
                    original = "grep *",
                    lua_pattern = PermissionRules.glob_to_lua_pattern("grep *"),
                },
            }
            assert.is_false(
                PermissionRules.matches_any_pattern("rm -rf /", patterns)
            )
        end)

        it("matches exact command (no wildcard)", function()
            local patterns = {
                {
                    original = "ls",
                    lua_pattern = PermissionRules.glob_to_lua_pattern("ls"),
                },
            }
            assert.is_true(PermissionRules.matches_any_pattern("ls", patterns))
        end)

        it("exact pattern does not match with args", function()
            local patterns = {
                {
                    original = "ls",
                    lua_pattern = PermissionRules.glob_to_lua_pattern("ls"),
                },
            }
            assert.is_false(
                PermissionRules.matches_any_pattern("ls -la", patterns)
            )
        end)

        it("matches a leaf with a trailing redirect via *", function()
            -- The walker strips redirects before the matcher sees the leaf, but
            -- a stray redirect in the text is matched by `*` (`.*`) anyway.
            local patterns = {
                {
                    original = "grep *",
                    lua_pattern = PermissionRules.glob_to_lua_pattern("grep *"),
                },
            }
            assert.is_true(
                PermissionRules.matches_any_pattern(
                    "grep foo 2>/dev/null",
                    patterns
                )
            )
        end)

        it("matches grep command with quoted alternation", function()
            local patterns = {
                {
                    original = "grep *",
                    lua_pattern = PermissionRules.glob_to_lua_pattern("grep *"),
                },
            }
            assert.is_true(
                PermissionRules.matches_any_pattern(
                    [[grep -n "export function query\|function query\|^export " /tmp/file.mjs]],
                    patterns
                )
            )
        end)

        it("returns false for empty segment", function()
            local patterns = {
                {
                    original = "ls *",
                    lua_pattern = PermissionRules.glob_to_lua_pattern("ls *"),
                },
            }
            assert.is_false(PermissionRules.matches_any_pattern("", patterns))
        end)

        it("matches a system absolute-path invocation", function()
            local patterns = {
                {
                    original = "grep *",
                    lua_pattern = PermissionRules.glob_to_lua_pattern("grep *"),
                },
            }
            assert.is_true(
                PermissionRules.matches_any_pattern(
                    "/usr/bin/grep -r 'foo' .",
                    patterns
                )
            )
        end)

        it("does not match a non-system absolute-path invocation", function()
            local patterns = {
                {
                    original = "grep *",
                    lua_pattern = PermissionRules.glob_to_lua_pattern("grep *"),
                },
            }
            assert.is_false(
                PermissionRules.matches_any_pattern(
                    "/tmp/evil/grep -r 'foo' .",
                    patterns
                )
            )
        end)
    end)

    describe("should_auto_approve", function()
        it("approves compound command when all segments match", function()
            -- Override read_json to return test data
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = {
                                "Bash(grep *)",
                                "Bash(head *)",
                                "Bash(sort *)",
                            },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result =
                PermissionRules.should_auto_approve("grep -r 'foo' . | head -5")
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves a lowercase assignment followed by a use", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = { allow = { "Bash(ls *)" } },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            assert.is_true(
                PermissionRules.should_auto_approve('f=path/to/file; ls "$f"')
            )

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves a lowercase env-prefix assignment", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = { allow = { "Bash(ls *)" } },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            assert.is_true(
                PermissionRules.should_auto_approve('f=/path/to/file ls "$f"')
            )

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("rejects an uppercase env assignment hijacking a use", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = { allow = { "Bash(grep *)" } },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            assert.is_false(
                PermissionRules.should_auto_approve("PATH=/evil/bin; grep foo")
            )

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("rejects when one segment has no matching pattern", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = {
                                "Bash(grep *)",
                            },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result =
                PermissionRules.should_auto_approve("grep foo | rm -rf /")
            assert.is_false(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("rejects when segment matches deny pattern", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = {
                                "Bash(grep *)",
                                "Bash(rm *)",
                            },
                            deny = {
                                "Bash(rm *)",
                            },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result =
                PermissionRules.should_auto_approve("grep foo | rm -rf /")
            assert.is_false(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("rejects when segment matches ask pattern", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = {
                                "Bash(grep *)",
                                "Bash(git push*)",
                            },
                            ask = {
                                "Bash(git push*)",
                            },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve(
                "grep foo && git push origin main"
            )
            assert.is_false(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("rejects a bare command substitution argument", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = { "Bash(echo *)" },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve("echo $(whoami)")
            assert.is_false(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves single command matching allow pattern", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = { "Bash(ls *)" },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve("ls -la /tmp")
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("returns false with no allow patterns", function()
            -- Disable all sources so no patterns are loaded
            local Config = require("agentic.config")
            local orig_plugin = Config.permissions.use_plugin_defaults
            local orig_claude = Config.permissions.use_claude_settings
            Config.permissions.use_plugin_defaults = false
            Config.permissions.use_claude_settings = false

            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve("ls -la")
            assert.is_false(result)

            PermissionRules.invalidate_cache()
            Config.permissions.use_plugin_defaults = orig_plugin
            Config.permissions.use_claude_settings = orig_claude
        end)

        it("approves a multi-line pipe (trailing-pipe continuation)", function()
            -- A pipe at end of line continues to the next — valid shell that
            -- parses as one pipeline. The isolated-pipe form (`src\n|\n head`)
            -- is invalid shell and is rejected (see the walker block below).
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = {
                                "Bash(grep *)",
                                "Bash(head *)",
                            },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve(
                "grep -r 'pattern' src |\n  head -40"
            )
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it(
            "blocks a write hidden after a newline-joined safe command",
            function()
                -- Without newline splitting, `rm -rf bar` would be swallowed by
                -- echo's trailing `*` wildcard and silently auto-approved.
                local orig_read_json = PermissionRules.read_json
                PermissionRules.read_json = function(path)
                    if path:find("settings%.json$") then
                        return {
                            permissions = {
                                allow = { "Bash(echo *)" },
                            },
                        }
                    end
                    return nil
                end
                PermissionRules.invalidate_cache()

                local result =
                    PermissionRules.should_auto_approve("echo hi\nrm -rf bar")
                assert.is_false(result)

                PermissionRules.read_json = orig_read_json
                PermissionRules.invalidate_cache()
            end
        )

        it("approves newline-joined read-only statements", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = {
                                "Bash(cd *)",
                                "Bash(echo *)",
                                "Bash(grep *)",
                            },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve(
                "cd /tmp\necho looking\ngrep -rn foo src"
            )
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves a named function definition (body never runs)", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return { permissions = { allow = { "Bash(echo *)" } } }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            -- The body holds `rm -rf /`, which is not allowed, but defining the
            -- function does not execute it.
            assert.is_true(
                PermissionRules.should_auto_approve("foo() { rm -rf / }")
            )
            assert.is_true(
                PermissionRules.should_auto_approve("function foo { rm -rf / }")
            )

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        describe("calls to locally-defined functions", function()
            local orig_read_json
            before_each(function()
                orig_read_json = PermissionRules.read_json
                PermissionRules.read_json = function(path)
                    if path:find("settings%.json$") then
                        return {
                            permissions = { allow = { "Bash(echo *)" } },
                        }
                    end
                    return nil
                end
                PermissionRules.invalidate_cache()
            end)
            after_each(function()
                PermissionRules.read_json = orig_read_json
                PermissionRules.invalidate_cache()
            end)

            it("resolves a call to a clean function body", function()
                assert.is_true(
                    PermissionRules.should_auto_approve(
                        "foo() { echo hi }; foo"
                    )
                )
            end)

            it("approves a call regardless of its arguments", function()
                -- Body treats `$1` as dynamic at definition time, so the
                -- recorded function is safe for any call args.
                assert.is_true(
                    PermissionRules.should_auto_approve(
                        "foo() { echo $1 }; foo whatever"
                    )
                )
            end)

            it("does not record a function whose body bails", function()
                -- `rm -rf /` is not allowed, so the body never walks clean and
                -- the name is not recorded — the call bails.
                assert.is_false(
                    PermissionRules.should_auto_approve(
                        "foo() { rm -rf / }; foo"
                    )
                )
            end)

            it("un-records on redefinition to an unsafe body", function()
                -- The safe first definition must not leave a stale record that
                -- would approve the call that now runs the unsafe second body.
                assert.is_false(
                    PermissionRules.should_auto_approve(
                        "foo() { echo hi }; foo() { rm -rf / }; foo"
                    )
                )
            end)

            it("records on redefinition to a clean body", function()
                assert.is_true(
                    PermissionRules.should_auto_approve(
                        "foo() { rm -rf / }; foo() { echo hi }; foo"
                    )
                )
            end)

            it("bails on a call before its definition", function()
                -- Left-to-right: `foo` is not yet recorded at the call site.
                assert.is_false(
                    PermissionRules.should_auto_approve(
                        "foo; foo() { echo hi }"
                    )
                )
            end)

            it("still vets a side-effecting call argument", function()
                -- The `$(rm x)` argument runs at the call site to produce
                -- foo's input, so it is walked and bails before resolution.
                assert.is_false(
                    PermissionRules.should_auto_approve(
                        "foo() { echo hi }; foo $(rm x)"
                    )
                )
            end)

            it(
                "does not leak a function name into a nested sequence",
                function()
                    -- funcs is per-sequence (same scoping as the per-sequence `known`): the
                    -- `if` body is a fresh sequence, so a parent definition does not
                    -- resolve there. Accepted residual — over-prompts, never under.
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "foo() { echo hi }; if true; then foo; fi"
                        )
                    )
                end
            )
        end)

        it("blocks an anonymous function (runs immediately)", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return { permissions = { allow = { "Bash(echo *)" } } }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            assert.is_false(
                PermissionRules.should_auto_approve("() { rm -rf / }")
            )

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves three-segment pipeline", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = {
                                "Bash(grep *)",
                                "Bash(sort *)",
                                "Bash(head *)",
                            },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve(
                "grep -r 'foo' . | sort -u | head -20"
            )
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves stdbuf-wrapped command", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = { "Bash(ls *)" },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve(
                "stdbuf -oL ls /tmp/example/"
            )
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves env-var-prefixed compound command", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = { "Bash(cd *)", "Bash(git log *)" },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve(
                "PYTHONUNBUFFERED=1 cd /tmp && git log --oneline -- foo.py"
            )
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves an escaped quote with a pipe inside the string", function()
            -- The walker sees `"a\"b|c"` is one double-quoted argument, so
            -- the `|` is string data, not an operator. One safe `grep`
            -- command — approve. (The old regex splitter saw an apparent
            -- quote imbalance and bailed.) The `\` here is a literal
            -- backslash char, not a lua escape.
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = { "Bash(grep *)" },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result =
                PermissionRules.should_auto_approve([[grep "a\"b|c" file]])
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves a quote-reopening idiom with a quoted pipe", function()
            -- zsh `'can'\''t|here'` concatenates to the literal can't|here,
            -- so the `|` is inside the argument. The walker parses it as one
            -- safe `echo` command — approve. (The old splitter saw the `|`
            -- as unquoted and fragmented the command, bailing.)
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = { "Bash(echo *)" },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result =
                PermissionRules.should_auto_approve([[echo 'can'\''t|here']])
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves pipeline with quoted pipe in grep pattern", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = {
                                "Bash(grep *)",
                                "Bash(head *)",
                            },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve(
                [[grep -n "export function\|^export " /tmp/file.mjs | head -30]]
            )
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves stdbuf-wrapped compound command", function()
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = {
                                "Bash(grep *)",
                                "Bash(head *)",
                            },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve(
                "stdbuf -oL grep -r 'foo' . | head -5"
            )
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)
    end)

    describe("should_auto_approve with redirect", function()
        local Config
        local orig_plugin
        local orig_claude
        local orig_read_json
        local orig_cleanup

        before_each(function()
            Config = require("agentic.config")
            orig_plugin = Config.permissions.use_plugin_defaults
            orig_claude = Config.permissions.use_claude_settings
            orig_cleanup = Config.permissions.tmp_cleanup
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.tmp_cleanup = false

            orig_read_json = PermissionRules.read_json
            -- Only stub settings.json paths, let plugin permissions.json load
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return nil
                end
                return orig_read_json(path)
            end
            PermissionRules.invalidate_cache()
        end)

        after_each(function()
            Config.permissions.use_plugin_defaults = orig_plugin
            Config.permissions.use_claude_settings = orig_claude
            Config.permissions.tmp_cleanup = orig_cleanup
            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("rejects allowed command with output redirect", function()
            -- `cat *` is in the default allow list; redirect must override.
            assert.is_false(
                PermissionRules.should_auto_approve("cat /etc/hosts > /tmp/x")
            )
        end)

        it("rejects allowed command with append redirect", function()
            assert.is_false(
                PermissionRules.should_auto_approve("echo x >> /tmp/log")
            )
        end)

        it("approves allowed command with stderr fd dup", function()
            assert.is_true(PermissionRules.should_auto_approve("echo hi >&2"))
        end)

        it("approves allowed command with /dev/null redirect", function()
            assert.is_true(
                PermissionRules.should_auto_approve("ls /tmp 2>/dev/null")
            )
        end)

        it("rejects redirect in middle of pipeline", function()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "cat /etc/hosts | head -3 > /tmp/x"
                )
            )
        end)

        it("approves allowed command reading from input redirect", function()
            -- `<file` is a pure read; it must not force a prompt.
            assert.is_true(
                PermissionRules.should_auto_approve("wc -l </tmp/x.txt")
            )
        end)

        it("rejects input-redirect target built by substitution", function()
            assert.is_false(
                PermissionRules.should_auto_approve("wc -l <$(echo /tmp/x)")
            )
        end)

        -- `env` is a launcher, not an effect-neutral wrapper (it can set PATH /
        -- LD_PRELOAD), so it must carry no blanket read-only entry — otherwise it
        -- would launder whatever it launches. `cat *` is allowed; `env cat …`
        -- must still prompt because the matcher does not recurse into `env`.
        it("rejects env launching an otherwise-allowed command", function()
            assert.is_false(
                PermissionRules.should_auto_approve("env cat /etc/hosts")
            )
        end)

        -- evaluate() surfaces a concrete file-write redirect as an effect (ok,
        -- but needs a /trust tmp scope to clear) instead of bailing. The policy
        -- layer (permission_manager) then decides; should_auto_approve, which
        -- has no scope, stays false for these.
        it("evaluate: emits a write effect for an output redirect", function()
            local ok, effects =
                PermissionRules.evaluate("cat /etc/hosts > /tmp/x")
            assert.is_true(ok)
            assert.equal(1, #effects)
            assert.equal("write", effects[1].kind)
            assert.equal("/tmp/x", effects[1].path)
        end)

        it("evaluate: emits a write effect for an append redirect", function()
            local ok, effects = PermissionRules.evaluate("echo x >> /tmp/log")
            assert.is_true(ok)
            assert.equal("/tmp/log", effects[1].path)
        end)

        it("evaluate: a nested redirect inside $() emits an effect", function()
            local ok, effects = PermissionRules.evaluate("cat $(ls > /tmp/o)")
            assert.is_true(ok)
            assert.equal("/tmp/o", effects[1].path)
        end)

        it("evaluate: no effect for /dev/null or fd dup", function()
            local ok, effects = PermissionRules.evaluate("ls /tmp 2>/dev/null")
            assert.is_true(ok)
            assert.equal(0, #effects)
        end)

        it("evaluate: a dynamic redirect target bails (no effect)", function()
            -- A target the walker cannot pin to a literal stays a structural
            -- bail — over-prompt, never a launderable effect.
            local ok, effects = PermissionRules.evaluate("cat > $(echo out)")
            assert.is_false(ok)
            assert.equal(0, #effects)
        end)

        -- A redirect target is resolved to a literal the same way an `rm`
        -- operand is, so a write and a later delete on the same path correlate.
        it(
            "evaluate: a quoted-literal redirect target is quote-stripped",
            function()
                local ok, effects =
                    PermissionRules.evaluate([[echo x > "/tmp/x"]])
                assert.is_true(ok)
                assert.equal("/tmp/x", effects[1].path)
            end
        )

        it(
            "evaluate: a redirect target resolves through a known literal",
            function()
                local ok, effects =
                    PermissionRules.evaluate("f=/tmp/x; echo y > $f")
                assert.is_true(ok)
                assert.equal("/tmp/x", effects[1].path)
            end
        )

        it("evaluate: a quoted known-var redirect target resolves", function()
            local ok, effects =
                PermissionRules.evaluate([[f=/tmp/x; echo y > "$f"]])
            assert.is_true(ok)
            assert.equal("/tmp/x", effects[1].path)
        end)

        it(
            "evaluate: an unbound-var redirect target bails (no effect)",
            function()
                -- Previously emitted the raw `$f` as the path (never matched a tmp
                -- root, never correlated). Now bails like any dynamic target.
                local ok, effects = PermissionRules.evaluate("echo y > $f")
                assert.is_false(ok)
                assert.equal(0, #effects)
            end
        )

        it(
            "evaluate: known-var write then rm correlate on the resolved path",
            function()
                Config.permissions.tmp_cleanup = true
                local ok, effects = PermissionRules.evaluate(
                    [[f=/tmp/x; echo y > "$f"; rm "$f"]]
                )
                assert.is_true(ok)
                assert.equal(2, #effects)
                assert.equal("write", effects[1].kind)
                assert.equal("/tmp/x", effects[1].path)
                assert.equal("delete", effects[2].kind)
                assert.equal("/tmp/x", effects[2].path)
            end
        )

        it(
            "evaluate: an unapproved command with a redirect is not ok",
            function()
                local ok = PermissionRules.evaluate("danger > /tmp/x")
                assert.is_false(ok)
            end
        )

        -- Under tmp_cleanup, rm emits ordered delete effects instead
        -- of bailing to the structured `ask`; the policy layer correlates them
        -- against earlier writes and the tmp scope.
        it("evaluate: rm emits a delete effect under tmp_cleanup", function()
            Config.permissions.tmp_cleanup = true
            local ok, effects = PermissionRules.evaluate("rm /tmp/x")
            assert.is_true(ok)
            assert.equal(1, #effects)
            assert.equal("delete", effects[1].kind)
            assert.equal("/tmp/x", effects[1].path)
        end)

        it("evaluate: rm bails to a prompt without tmp_cleanup", function()
            local ok, effects = PermissionRules.evaluate("rm /tmp/x")
            assert.is_false(ok)
            assert.equal(0, #effects)
        end)

        it(
            "evaluate: redirect-write then rm emits write then delete",
            function()
                Config.permissions.tmp_cleanup = true
                local ok, effects =
                    PermissionRules.evaluate("echo x > /tmp/f; rm /tmp/f")
                assert.is_true(ok)
                assert.equal(2, #effects)
                assert.equal("write", effects[1].kind)
                assert.equal("delete", effects[2].kind)
                assert.equal("/tmp/f", effects[2].path)
            end
        )

        it(
            "evaluate: rm flags are options, only operands emit effects",
            function()
                Config.permissions.tmp_cleanup = true
                local ok, effects = PermissionRules.evaluate("rm -rf /tmp/d")
                assert.is_true(ok)
                assert.equal(1, #effects)
                assert.equal("/tmp/d", effects[1].path)
            end
        )

        it("evaluate: a dynamic rm operand bails (no effect)", function()
            Config.permissions.tmp_cleanup = true
            local ok, effects = PermissionRules.evaluate("rm $x")
            assert.is_false(ok)
            assert.equal(0, #effects)
        end)

        it(
            "evaluate: rm -- treats a trailing dash-word as an operand",
            function()
                Config.permissions.tmp_cleanup = true
                local ok, effects = PermissionRules.evaluate("rm -- -weird")
                assert.is_true(ok)
                assert.equal("-weird", effects[1].path)
            end
        )

        it("should_auto_reject: rm -f always rejects", function()
            assert.is_true(PermissionRules.should_auto_reject("rm -f /tmp/x"))
            Config.permissions.tmp_cleanup = true
            assert.is_true(PermissionRules.should_auto_reject("rm -f /tmp/x"))
        end)
    end)

    describe("config permissions", function()
        --- @type agentic.UserConfig
        local Config
        local orig_plugin
        local orig_claude
        local orig_read_only
        local orig_safe_write
        local orig_deny
        local orig_auto_approve
        local orig_read_json

        before_each(function()
            Config = require("agentic.config")
            orig_plugin = Config.permissions.use_plugin_defaults
            orig_claude = Config.permissions.use_claude_settings
            orig_read_only = Config.permissions.read_only
            orig_safe_write = Config.permissions.safe_write
            orig_deny = Config.permissions.deny
            orig_auto_approve = Config.permissions.auto_approve

            -- Stub settings.json to empty so only plugin defaults apply
            orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return nil
                end
                return orig_read_json(path)
            end
            PermissionRules.invalidate_cache()
        end)

        after_each(function()
            Config.permissions.use_plugin_defaults = orig_plugin
            Config.permissions.use_claude_settings = orig_claude
            Config.permissions.read_only = orig_read_only
            Config.permissions.safe_write = orig_safe_write
            Config.permissions.deny = orig_deny
            Config.permissions.auto_approve = orig_auto_approve
            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        --- Resolve auto-approval of `cmd` against the plugin defaults at `tier`.
        --- @param tier agentic.PermAutoApprove
        --- @param cmd string
        --- @return boolean
        local function approves_at(tier, cmd)
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = tier
            PermissionRules.invalidate_cache()
            return PermissionRules.should_auto_approve(cmd)
        end

        describe("uv run wrapper (safe_write tier)", function()
            it(
                "approves a bare `uv run <checker>` at the allow tier",
                function()
                    assert.is_true(
                        approves_at("allow", "uv run basedpyright probe.py")
                    )
                end
            )

            it(
                "prompts the same command at the read-only tier (env sync writes)",
                function()
                    assert.is_false(
                        approves_at("read-only", "uv run basedpyright probe.py")
                    )
                end
            )

            it("prompts when the inner command is not approved", function()
                assert.is_false(approves_at("allow", "uv run rm -rf /"))
            end)

            it("prompts when a code-injecting option is present", function()
                assert.is_false(
                    approves_at(
                        "allow",
                        "uv run --with=evil basedpyright probe.py"
                    )
                )
            end)

            it("approves a non-`run` subcommand by its own rule", function()
                assert.is_true(approves_at("allow", "uv pip list"))
            end)
        end)

        describe("checker and formatter commands", function()
            it("approves a no-write checker at the read-only tier", function()
                assert.is_true(approves_at("read-only", "basedpyright src.py"))
                assert.is_true(approves_at("read-only", "selene src.lua"))
                assert.is_true(approves_at("read-only", "shellcheck script.sh"))
            end)

            it("prompts on a checker's write/exec option", function()
                -- basedpyright --writebaseline / --createstub / --gitlabcodequality
                -- write files; mypy --install-types runs pip (arbitrary code).
                assert.is_false(
                    approves_at("allow", "basedpyright --writebaseline")
                )
                assert.is_false(
                    approves_at(
                        "allow",
                        "basedpyright --gitlabcodequality out.json"
                    )
                )
                assert.is_false(approves_at("allow", "mypy --install-types"))
            end)

            it(
                "treats a cache/file writer as safe_write, not read-only",
                function()
                    -- mypy writes .mypy_cache by default; formatters rewrite files.
                    for _, cmd in ipairs({
                        "mypy src.py",
                        "stylua init.lua",
                        "ruff format src.py",
                    }) do
                        assert.is_true(approves_at("allow", cmd))
                        assert.is_false(approves_at("read-only", cmd))
                    end
                end
            )
        end)

        describe("process substitution", function()
            it(
                "approves a read-only command with read-only procsub inners",
                function()
                    -- `<(…)` expands to a /dev/fd path; the inner `sort`s
                    -- recurse-approve, so the whole command auto-approves.
                    assert.is_true(
                        approves_at(
                            "read-only",
                            "diff <(sort a.tsv) <(sort b.tsv)"
                        )
                    )
                end
            )

            it(
                "prompts when a procsub inner is not in any allow list",
                function()
                    assert.is_false(
                        approves_at("allow", "diff <(sort a.tsv) <(rm -rf /)")
                    )
                end
            )

            it("rejects when a procsub inner hits a deny gate", function()
                assert.is_false(
                    approves_at(
                        "allow",
                        "diff <(find . -exec rm {} +) <(sort b)"
                    )
                )
            end)
        end)

        it(
            "approves command from plugin defaults when auto_approve=allow",
            function()
                Config.permissions.use_plugin_defaults = true
                Config.permissions.use_claude_settings = false
                Config.permissions.auto_approve = "allow"
                PermissionRules.invalidate_cache()
                assert.is_true(
                    PermissionRules.should_auto_approve("ls -la /tmp")
                )
            end
        )

        it(
            "approves command from plugin defaults when auto_approve=read-only",
            function()
                Config.permissions.use_plugin_defaults = true
                Config.permissions.use_claude_settings = false
                Config.permissions.auto_approve = "read-only"
                PermissionRules.invalidate_cache()
                assert.is_true(
                    PermissionRules.should_auto_approve("ls -la /tmp")
                )
            end
        )

        it("rejects when auto_approve is nil", function()
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = nil
            PermissionRules.invalidate_cache()
            assert.is_false(PermissionRules.should_auto_approve("ls -la /tmp"))
        end)

        it("rejects when both sources disabled", function()
            Config.permissions.use_plugin_defaults = false
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
            assert.is_false(PermissionRules.should_auto_approve("ls -la /tmp"))
        end)

        it("approves compound of two plugin-default commands", function()
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
            assert.is_true(
                PermissionRules.should_auto_approve("cat foo.txt | head -5")
            )
        end)

        it("rejects find -exec via plugin deny list", function()
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "find . -name '*.lua' -exec rm {} +"
                )
            )
        end)

        it("rejects find -okdir via plugin deny list", function()
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "find . -name '*.lua' -okdir rm {} +"
                )
            )
        end)

        it("approves find without -exec", function()
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
            assert.is_true(
                PermissionRules.should_auto_approve("find . -name '*.lua'")
            )
        end)

        it("rejects awk system() via plugin deny list", function()
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "awk 'BEGIN{system(\"rm -rf /\")}'"
                )
            )
        end)

        -- sed stays in read_only. The s///e flag and `e` command can run a
        -- shell, but those forms have no soundly-globbable anchor (GNU sed
        -- needs no space after `e`, accepts a bare `e`, and allows any s///
        -- delimiter and flag order), so a carve-out would either bypass the
        -- dangerous forms or deny most real sed. That exec residual is an
        -- accepted, documented limitation. The common benign case is approved.
        it("approves benign sed substitution", function()
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
            assert.is_true(
                PermissionRules.should_auto_approve("sed 's/a/b/' file")
            )
        end)

        it("rejects command not in any allow list", function()
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
            assert.is_false(
                PermissionRules.should_auto_approve("rm -rf /tmp/foo")
            )
        end)

        it(
            "recompiles when Config.permissions.read_only is replaced",
            function()
                Config.permissions.use_plugin_defaults = false
                Config.permissions.use_claude_settings = false
                Config.permissions.auto_approve = "read-only"
                Config.permissions.read_only = { "Bash(custom *)" }
                PermissionRules.invalidate_cache()
                -- Default `ls` no longer in list
                assert.is_false(PermissionRules.should_auto_approve("ls -la"))
                assert.is_true(
                    PermissionRules.should_auto_approve("custom thing")
                )
            end
        )

        it("merges Config patterns with settings.json patterns", function()
            Config.permissions.use_plugin_defaults = false
            Config.permissions.use_claude_settings = true
            Config.permissions.auto_approve = "read-only"
            Config.permissions.read_only = { "Bash(ls *)" }
            Config.permissions.deny = {}

            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = { "Bash(make test*)" },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            assert.is_true(PermissionRules.should_auto_approve("ls -la"))
            assert.is_true(PermissionRules.should_auto_approve("make test foo"))
            assert.is_true(
                PermissionRules.should_auto_approve("ls /tmp && make test x")
            )
        end)
    end)

    -- Phase 1a walker: structural decomposition via the zsh treesitter parse
    -- tree. Reject-by-default — substitution, control flow, file-writing
    -- redirects, dynamic command names, and parse errors all bail to a prompt.
    describe("should_auto_approve (treesitter walker)", function()
        --- Decide a command with the given allow/deny/ask Bash patterns sourced
        --- from a stubbed settings.json (plugin defaults are not loaded — the
        --- stub returns nil for any non-settings path).
        --- @param command string
        --- @param perms { allow?: string[], deny?: string[], ask?: string[] }
        --- @return boolean
        local function decide(command, perms)
            local orig = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return { permissions = perms }
                end
                return nil
            end
            PermissionRules.invalidate_cache()
            local result = PermissionRules.should_auto_approve(command)
            PermissionRules.read_json = orig
            PermissionRules.invalidate_cache()
            return result
        end

        -- A broad allow list so a bail is provably about structure, not a
        -- missing entry.
        local ALLOW = {
            allow = {
                "Bash(grep *)",
                "Bash(echo *)",
                "Bash(cat *)",
                "Bash(ls *)",
                "Bash(rm *)",
                "Bash(head *)",
                "Bash(seq *)",
            },
        }

        describe("bails on substitution in non-recursed positions", function()
            -- Bare `$(...)` (argument / for-list) and quoted `"$(...)"`
            -- (see the dedicated blocks below) are recursed. These
            -- remaining positions either hide the substitution from the matcher
            -- or splice its output somewhere the dynamic-token machinery cannot
            -- guard, so they still bail: substitution as the command name, in a
            -- concatenation, as a redirect target, in a here-string, or in a
            -- command-prefix assignment value.
            for _, cmd in ipairs({
                "$(echo rm) -rf /",
                "$(rm -rf /)",
                "echo a$(whoami)b",
                "ec$(echo ho) hi",
                "cat > $(echo out)",
                "cat <<< $(rm x)",
                "foo=$(rm x) ls",
            }) do
                it("rejects " .. cmd, function()
                    assert.is_false(decide(cmd, ALLOW))
                end)
            end
        end)

        describe("bails on control flow and compound structure", function()
            -- Loops and if/case control flow recurse (see the dedicated
            -- describe blocks below); a top-level `test_command` is a
            -- side-effect-free predicate that walks; brace groups and
            -- subshells run their body sequentially so they walk like a
            -- `list` (covered separately below). The remaining case (`!`)
            -- stays rejected. Process substitution recurses (see the
            -- command-substitution block).
            for _, cmd in ipairs({
                "! rm x",
            }) do
                it("rejects " .. cmd, function()
                    assert.is_false(decide(cmd, ALLOW))
                end)
            end
        end)

        describe("brace group walks like a sequence", function()
            -- A `{ …; }` brace group runs its contents in the current shell,
            -- so its decision equals that of the contained list (the node that
            -- also forms a function body).
            it("approves when every contained command is allowed", function()
                assert.is_true(decide("{ echo hi; rm x; }", ALLOW))
            end)
            it("bails when any contained command is not allowed", function()
                assert.is_false(decide("{ echo hi; danger x; }", ALLOW))
            end)
        end)

        describe("subshell walks like a sequence", function()
            -- A `( … )` command group runs its body in a child shell, which
            -- changes only variable scope and cwd persistence — never leaf
            -- safety — so its decision equals that of the contained body.
            local perms = {
                allow = {
                    "Bash(echo *)",
                    "Bash(ls *)",
                    "Bash(printf *)",
                },
            }
            it("approves a single contained command", function()
                assert.is_true(decide("( echo hi )", perms))
            end)
            it("approves when every contained command is allowed", function()
                assert.is_true(decide("( echo a && echo b )", perms))
            end)
            it("bails when any contained command is not allowed", function()
                assert.is_false(decide("( echo a; rm x )", perms))
            end)
            it("approves the safe compound example", function()
                assert.is_true(
                    decide(
                        'for p in a b; do ( ls "$p" >/dev/null 2>&1 && printf \'%s\\n\' "$p" ) || printf \'%s\\n\' "$p"; done',
                        perms
                    )
                )
            end)
        end)

        describe("bails on file-writing and unmodelled redirects", function()
            for _, cmd in ipairs({
                "cat foo &> out",
                "cat foo &>> out",
                "cat /etc/hosts > /tmp/x",
                "echo x >> /tmp/log",
            }) do
                it("rejects " .. cmd, function()
                    assert.is_false(decide(cmd, ALLOW))
                end)
            end
        end)

        describe("bails on a parse error (fail-closed)", function()
            for _, cmd in ipairs({
                "rm -rf / |", -- truncated pipeline
                "grep src\n| head", -- isolated pipe — invalid shell
            }) do
                it("rejects " .. vim.inspect(cmd), function()
                    assert.is_false(decide(cmd, ALLOW))
                end)
            end
        end)

        it("bails on code-taking builtins even when allowed", function()
            local perms = {
                allow = {
                    "Bash(eval *)",
                    "Bash(source *)",
                    "Bash(. *)",
                },
            }
            assert.is_false(decide("eval rm -rf /", perms))
            assert.is_false(decide("source script", perms))
            assert.is_false(decide(". script", perms))
        end)

        it("bails on a dynamic (arithmetic) command name", function()
            assert.is_false(decide("$((1+2))", ALLOW))
        end)

        it("normalises a quoted command name for deny matching", function()
            -- `"rm"` must resolve to `rm` so it cannot evade the deny rule.
            assert.is_false(decide('"rm" -rf /', {
                allow = { "Bash(rm *)" },
                deny = { "Bash(rm *)" },
            }))
        end)

        it("approves inert variable assignments", function()
            assert.is_true(decide("a=1 b=2", ALLOW))
            assert.is_true(decide("arr=(a b c)", ALLOW))
        end)

        it("approves an assignment followed by a use", function()
            assert.is_true(decide('f=path/to/file; ls "$f"', ALLOW))
        end)

        it("approves a raw string that looks like substitution", function()
            -- Single quotes — `$(foo)` is literal data, not a substitution.
            assert.is_true(decide("echo '$(foo)'", ALLOW))
        end)

        it("ignores a trailing comment", function()
            assert.is_true(decide("ls # rm -rf /", {
                allow = { "Bash(ls)", "Bash(ls *)" },
            }))
        end)

        it("approves a quoted operator as string data", function()
            assert.is_true(decide('grep "a|b" file', ALLOW))
        end)

        it("returns false when the zsh parser is unavailable", function()
            local orig = vim.treesitter.get_string_parser
            --- @diagnostic disable-next-line: duplicate-set-field
            vim.treesitter.get_string_parser = function()
                error("no zsh parser")
            end
            local result = decide("ls -la", ALLOW)
            vim.treesitter.get_string_parser = orig
            assert.is_false(result)
        end)

        -- Phase 1b composition: a structured-entry decision (deny / ask /
        -- allow) feeds into the same walk through `M.get_structured_entries`.
        -- Tests stub the accessor directly to avoid coupling to the bundled
        -- permissions.json (which is still in the legacy glob format).
        describe("structured matcher composition", function()
            --- Run should_auto_approve with stubbed structured entries AND
            --- stubbed settings.json. Restores both on exit.
            --- @param command string
            --- @param perms { allow?: string[], deny?: string[], ask?: string[] }
            --- @param entries agentic.StructuredEntries
            --- @return boolean
            local function decide_with_entries(command, perms, entries)
                local orig_read = PermissionRules.read_json
                local orig_get = PermissionRules.get_structured_entries
                PermissionRules.read_json = function(path)
                    if path:find("settings%.json$") then
                        return { permissions = perms }
                    end
                    return nil
                end
                --- @diagnostic disable-next-line: duplicate-set-field
                PermissionRules.get_structured_entries = function()
                    return entries
                end
                PermissionRules.invalidate_cache()
                local result = PermissionRules.should_auto_approve(command)
                PermissionRules.read_json = orig_read
                PermissionRules.get_structured_entries = orig_get
                PermissionRules.invalidate_cache()
                return result
            end

            local ALLOW_FIND = { allow = { "Bash(find *)" } }
            local ALLOW_ECHO = { allow = { "Bash(echo *)" } }
            local ALLOW_GREP = { allow = { "Bash(grep *)" } }

            it(
                'denies a literal concatenation in option position (-ex"e"c)',
                function()
                    assert.is_false(
                        decide_with_entries(
                            'find . -ex"e"c rm \\;',
                            ALLOW_FIND,
                            { find = { deny = { { options = { "exec" } } } } }
                        )
                    )
                end
            )

            it(
                "bails on a substitution-bearing concatenation in option position",
                function()
                    assert.is_false(
                        decide_with_entries(
                            'find . -ex"$x"c rm',
                            ALLOW_FIND,
                            { find = { deny = { { options = { "exec" } } } } }
                        )
                    )
                end
            )

            it(
                "denies find -exec when {} joins to a literal placeholder",
                function()
                    assert.is_false(
                        decide_with_entries(
                            "find . -exec rm {} \\;",
                            ALLOW_FIND,
                            { find = { deny = { { options = { "exec" } } } } }
                        )
                    )
                end
            )

            it(
                "approves a literal {} positional with no matching deny",
                function()
                    assert.is_true(
                        decide_with_entries(
                            "find . -name {}",
                            ALLOW_FIND,
                            { find = { deny = { { options = { "exec" } } } } }
                        )
                    )
                end
            )

            it("approves a brace_expression argument", function()
                assert.is_true(
                    decide_with_entries(
                        "echo {1..3}",
                        ALLOW_ECHO,
                        { echo = { read_only = { {} } } }
                    )
                )
            end)

            it(
                "approves a literal concatenation in command-name position",
                function()
                    assert.is_true(
                        decide_with_entries(
                            'gr"e"p foo file',
                            ALLOW_GREP,
                            { grep = { read_only = { {} } } }
                        )
                    )
                end
            )

            it(
                "matches the same option whether the rule lists -exec or exec (post-normalisation)",
                function()
                    -- Stubs bypass `get_structured_entries`, so the test
                    -- supplies already-normalised entries. Round-tripping
                    -- through the accessor is covered by the
                    -- `get_structured_entries normalisation` describe block.
                    assert.is_false(
                        decide_with_entries(
                            "find . -exec rm {} \\;",
                            ALLOW_FIND,
                            { find = { deny = { { options = { "exec" } } } } }
                        )
                    )
                end
            )
        end)

        -- get_structured_entries returns dashless-normalised entries even when
        -- the input rule uses --foo / -foo forms.
        describe("get_structured_entries normalisation", function()
            it("strips leading dashes from option strings", function()
                local Config = require("agentic.config")
                local original_structured = Config.permissions.structured
                Config.permissions.structured = {
                    find = {
                        deny = { { options = { "--exec", "-x", "okdir" } } },
                    },
                }
                PermissionRules.invalidate_cache()
                local entries = PermissionRules.get_structured_entries()
                Config.permissions.structured = original_structured
                PermissionRules.invalidate_cache()

                local find_entry = entries.find
                assert.is_not_nil(find_entry)
                assert.same(
                    { "exec", "x", "okdir" },
                    find_entry and find_entry.deny[1].options
                )
            end)
        end)

        -- Phase 2: assignment-position command substitution and loops.
        -- (Argument / for-list substitution is now recursed too — see the
        -- "argument-position command substitution" block below.) These
        -- tests focus on the assignment positives and on the negatives that
        -- remain unsafe.
        describe(
            "Phase 2 (assignment-position substitution and loops)",
            function()
                local ALLOW_ECHO_CAT = {
                    allow = { "Bash(echo *)", "Bash(echo)", "Bash(cat *)" },
                }
                local ALLOW_ECHO = {
                    allow = { "Bash(echo *)", "Bash(echo)" },
                }
                local ALLOW_READ_ECHO = {
                    allow = { "Bash(read *)", "Bash(echo *)", "Bash(echo)" },
                }
                local ALLOW_GREP_SLEEP = {
                    allow = { "Bash(grep *)", "Bash(sleep *)" },
                }

                it("approves f=$(echo hi) when echo is allowed", function()
                    assert.is_true(decide("f=$(echo hi)", ALLOW_ECHO))
                end)

                it(
                    "approves f=$(echo a; echo b) — multi-statement inner list",
                    function()
                        assert.is_true(
                            decide("f=$(echo a; echo b)", ALLOW_ECHO)
                        )
                    end
                )

                it("approves f=$(echo a | head) — inner pipeline", function()
                    assert.is_true(decide("f=$(echo a | head)", {
                        allow = { "Bash(echo *)", "Bash(head)" },
                    }))
                end)

                it(
                    "approves arr=(a $(echo b) c) — safe substitution in array element",
                    function()
                        assert.is_true(
                            decide("arr=(a $(echo b) c)", ALLOW_ECHO)
                        )
                    end
                )

                it(
                    "approves a for-loop over a glob with allowed body",
                    function()
                        assert.is_true(
                            decide(
                                'for f in *.txt; do cat "$f"; done',
                                ALLOW_ECHO_CAT
                            )
                        )
                    end
                )

                it("approves a for-loop over literal items", function()
                    assert.is_true(
                        decide(
                            'for f in a b c; do cat "$f"; done',
                            ALLOW_ECHO_CAT
                        )
                    )
                end)

                it(
                    "approves a while-loop with allowed condition and body",
                    function()
                        assert.is_true(
                            decide(
                                'while read l; do echo "$l"; done',
                                ALLOW_READ_ECHO
                            )
                        )
                    end
                )

                it(
                    "approves an until-loop with allowed condition and body",
                    function()
                        assert.is_true(
                            decide(
                                "until grep done log; do sleep 1; done",
                                ALLOW_GREP_SLEEP
                            )
                        )
                    end
                )

                it("rejects f=$(rm x) — inner command not allowed", function()
                    assert.is_false(decide("f=$(rm x)", ALLOW_ECHO))
                end)

                it(
                    "rejects f=$(foo > bar) — inner file_redirect fires",
                    function()
                        assert.is_false(decide("f=$(foo > bar)", {
                            allow = { "Bash(foo *)", "Bash(foo)" },
                        }))
                    end
                )

                it(
                    "rejects arr=($(rm x)) — array element with disallowed inner",
                    function()
                        assert.is_false(decide("arr=($(rm x))", ALLOW_ECHO))
                    end
                )

                it(
                    "rejects foo=$(rm x) ls — command-prefix assignment with substitution",
                    function()
                        assert.is_false(
                            decide("foo=$(rm x) ls", ALLOW_ECHO_CAT)
                        )
                    end
                )
            end
        )

        -- a bare `$(...)` in argument or for-list position is recursed —
        -- the inner command must approve on its own, and its output splices
        -- into the surrounding stream as a dynamic token (so a gated outer
        -- command still wildcard-prompts; see the use-site blocks below).
        describe("argument-position command substitution", function()
            local ALLOW_CAT_LS = {
                allow = {
                    "Bash(cat *)",
                    "Bash(cat)",
                    "Bash(ls *)",
                    "Bash(ls)",
                    "Bash(echo *)",
                    "Bash(echo)",
                },
            }

            it("approves cat $(ls) — inner and outer both allowed", function()
                assert.is_true(decide("cat $(ls)", ALLOW_CAT_LS))
            end)

            it(
                "approves cat foo $(ls) bar — substitution among literals",
                function()
                    assert.is_true(decide("cat foo $(ls) bar", ALLOW_CAT_LS))
                end
            )

            it("approves a backtick substitution", function()
                assert.is_true(decide("cat `ls`", ALLOW_CAT_LS))
            end)

            it("rejects cat $(nope) — inner command not allowed", function()
                assert.is_false(decide("cat $(nope)", ALLOW_CAT_LS))
            end)

            it(
                "rejects cat $(ls > out) — inner write redirect fires",
                function()
                    assert.is_false(decide("cat $(ls > out)", ALLOW_CAT_LS))
                end
            )

            it("rejects cat $() — empty substitution", function()
                assert.is_false(decide("cat $()", ALLOW_CAT_LS))
            end)

            it("approves two substitutions in one command", function()
                assert.is_true(decide("cat $(ls) $(echo hi)", ALLOW_CAT_LS))
            end)

            it("approves nested substitution — inner recurses", function()
                assert.is_true(decide("cat $(echo $(ls))", ALLOW_CAT_LS))
            end)

            it(
                "rejects nested substitution with a disallowed innermost command",
                function()
                    assert.is_false(decide("cat $(echo $(rm x))", ALLOW_CAT_LS))
                end
            )

            it(
                "approves process substitution — inner recurses, arg is a /dev/fd path",
                function()
                    assert.is_true(decide("cat <(ls)", ALLOW_CAT_LS))
                end
            )

            it(
                "rejects process substitution with a disallowed inner",
                function()
                    assert.is_false(decide("cat <(rm x)", ALLOW_CAT_LS))
                end
            )

            it("approves a for-loop over a substitution list", function()
                assert.is_true(
                    decide('for f in $(ls); do cat "$f"; done', ALLOW_CAT_LS)
                )
            end)

            it(
                "approves a for-loop with substitution among literals",
                function()
                    assert.is_true(
                        decide(
                            'for f in a $(ls) b; do cat "$f"; done',
                            ALLOW_CAT_LS
                        )
                    )
                end
            )

            it(
                "rejects a for-loop over a substitution with disallowed inner",
                function()
                    assert.is_false(
                        decide(
                            'for f in $(nope); do cat "$f"; done',
                            ALLOW_CAT_LS
                        )
                    )
                end
            )
        end)

        -- a quoted `"$(cmd)"` argument is unwrapped to its inner
        -- substitution and walked like the bare `$(cmd)` form — inner must
        -- approve standalone, output splices as a dynamic token. Only a `string`
        -- whose single named child is the substitution qualifies; concatenation
        -- with `$var` and process substitution stay bailed. The generalised
        -- form — literal text + one or more substitutions — is covered below.
        describe("quoted command substitution", function()
            local ALLOW_CAT_LS = {
                allow = {
                    "Bash(cat *)",
                    "Bash(cat)",
                    "Bash(ls *)",
                    "Bash(ls)",
                    "Bash(echo *)",
                    "Bash(echo)",
                },
            }

            it('approves cat "$(ls)" — the gate-free flip', function()
                assert.is_true(decide('cat "$(ls)"', ALLOW_CAT_LS))
            end)

            it('rejects cat "$(nope)" — inner command not allowed', function()
                assert.is_false(decide('cat "$(nope)"', ALLOW_CAT_LS))
            end)

            it(
                'rejects cat "$(ls > out)" — inner write redirect fires',
                function()
                    assert.is_false(decide('cat "$(ls > out)"', ALLOW_CAT_LS))
                end
            )

            it(
                'approves cat "pre$(ls)" — literal prefix, see generalised block',
                function()
                    assert.is_true(decide('cat "pre$(ls)"', ALLOW_CAT_LS))
                end
            )

            it(
                'approves cat "$(echo $(ls))" — nested inner recurses',
                function()
                    assert.is_true(decide('cat "$(echo $(ls))"', ALLOW_CAT_LS))
                end
            )

            it(
                'prompts on find "$(echo -exec rm)" — dynamic token wildcards find\'s -exec deny',
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            'find "$(echo -exec rm)"'
                        )
                    )
                end
            )
        end)

        -- a quoted string mixing literal text with one or more
        -- command substitutions. Every inner is vetted; the whole quoted arg
        -- splices as a single dynamic token (quotes kept). A `$var` child or any
        -- non-substitution expansion is out of scope and bails.
        describe("string-embedded command substitution", function()
            local ALLOW_SUBST = {
                allow = {
                    "Bash(echo *)",
                    "Bash(echo)",
                    "Bash(ls *)",
                    "Bash(ls)",
                    "Bash(wc *)",
                    "Bash(wc)",
                },
            }

            it('approves echo "count: $(ls)" — literal prefix', function()
                assert.is_true(decide('echo "count: $(ls)"', ALLOW_SUBST))
            end)

            it('approves echo "$(ls) done" — literal suffix', function()
                assert.is_true(decide('echo "$(ls) done"', ALLOW_SUBST))
            end)

            it(
                'approves echo "a $(ls) b $(wc -l) c" — multiple substitutions',
                function()
                    assert.is_true(
                        decide('echo "a $(ls) b $(wc -l) c"', ALLOW_SUBST)
                    )
                end
            )

            it(
                'rejects echo "x $(rm y)" — inner command not allowed',
                function()
                    assert.is_false(decide('echo "x $(rm y)"', ALLOW_SUBST))
                end
            )

            it(
                'prompts on find . "x$(echo -exec rm)" — dynamic token wildcards find\'s -exec deny',
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            'find . "x$(echo -exec rm)"'
                        )
                    )
                end
            )

            it(
                'bails on echo "x $y $(ls)" — $var child is out of scope',
                function()
                    assert.is_false(decide('echo "x $y $(ls)"', ALLOW_SUBST))
                end
            )
        end)

        describe("control flow (if / case)", function()
            local ALLOW_CF = {
                allow = {
                    "Bash(cat *)",
                    "Bash(echo *)",
                    "Bash(echo)",
                    "Bash(grep *)",
                },
            }

            it("approves if with a test-command condition", function()
                assert.is_true(
                    decide("if [[ -f x ]]; then cat x; fi", ALLOW_CF)
                )
            end)

            it("approves if with a command condition", function()
                assert.is_true(
                    decide("if grep -q foo x; then cat x; fi", ALLOW_CF)
                )
            end)

            it("approves if/elif/else with allowed bodies", function()
                assert.is_true(
                    decide(
                        "if [ -f x ]; then cat x; "
                            .. "elif grep y z; then echo a; "
                            .. "else echo b; fi",
                        ALLOW_CF
                    )
                )
            end)

            it("rejects a disallowed command in an if body", function()
                assert.is_false(
                    decide("if [[ -f x ]]; then rm x; fi", ALLOW_CF)
                )
            end)

            it("rejects a disallowed command in an elif body", function()
                assert.is_false(
                    decide(
                        "if [ -f x ]; then cat x; elif grep y z; then rm a; fi",
                        ALLOW_CF
                    )
                )
            end)

            it("rejects a disallowed command condition", function()
                assert.is_false(decide("if rm x; then cat x; fi", ALLOW_CF))
            end)

            it(
                "rejects substitution inside a test-command condition",
                function()
                    -- `[[ -f $(rm y) ]]` runs `rm y` during the predicate.
                    assert.is_false(
                        decide("if [[ -f $(rm y) ]]; then cat x; fi", ALLOW_CF)
                    )
                end
            )

            it("approves case with allowed item bodies", function()
                assert.is_true(
                    decide("case $x in a) cat x;; b|c) echo y;; esac", ALLOW_CF)
                )
            end)

            it("rejects a disallowed command in a case item body", function()
                assert.is_false(decide("case $x in a) rm x;; esac", ALLOW_CF))
            end)

            it("rejects substitution in the case value", function()
                -- `case $(rm x) in …` runs `rm x` to compute the value.
                assert.is_false(
                    decide("case $(rm x) in a) cat x;; esac", ALLOW_CF)
                )
            end)

            it("rejects substitution in a case item pattern", function()
                -- `$(rm y)` in a pattern runs during the match attempt.
                assert.is_false(
                    decide("case $x in $(rm y)) cat x;; esac", ALLOW_CF)
                )
            end)
        end)
    end)

    -- End-to-end exercise of the real bundled permissions.json (post-Phase 1b
    -- migration) through the structured matcher. Settings.json is stubbed to
    -- nil so user-side rules cannot pollute results; the bundled file is
    -- read from disk via the real read_json path.
    describe("bundled permissions.json (end-to-end)", function()
        local Config = require("agentic.config")
        local orig_read_json
        local orig_auto_approve
        local orig_use_plugin
        local orig_use_claude

        before_each(function()
            orig_read_json = PermissionRules.read_json
            --- @diagnostic disable-next-line: duplicate-set-field
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return nil
                end
                return orig_read_json(path)
            end
            orig_auto_approve = Config.permissions.auto_approve
            orig_use_plugin = Config.permissions.use_plugin_defaults
            orig_use_claude = Config.permissions.use_claude_settings
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = true
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
        end)

        after_each(function()
            PermissionRules.read_json = orig_read_json
            Config.permissions.auto_approve = orig_auto_approve
            Config.permissions.use_plugin_defaults = orig_use_plugin
            Config.permissions.use_claude_settings = orig_use_claude
            PermissionRules.invalidate_cache()
        end)

        it("denies sort -uo out (short cluster)", function()
            assert.is_false(PermissionRules.should_auto_approve("sort -uo out"))
        end)

        it("denies sort --out=x (GNU abbreviation)", function()
            assert.is_false(PermissionRules.should_auto_approve("sort --out=x"))
        end)

        it("denies sort -oFILE (glued arg)", function()
            assert.is_false(PermissionRules.should_auto_approve("sort -oFILE"))
        end)

        it("does not auto-approve git -C diff push", function()
            -- option walker consumes `-C diff`, positionals = ["push"]; no
            -- entry matches positionals[1]="push" as allow.
            assert.is_false(
                PermissionRules.should_auto_approve("git -C diff push")
            )
        end)

        it("auto-approves git -C path config --get foo", function()
            assert.is_true(
                PermissionRules.should_auto_approve(
                    "git -C path config --get foo"
                )
            )
        end)

        it("auto-approves git stash list", function()
            assert.is_true(
                PermissionRules.should_auto_approve("git stash list")
            )
        end)

        it("does not auto-approve bare git stash (unlisted)", function()
            assert.is_false(PermissionRules.should_auto_approve("git stash"))
        end)

        it("does not auto-approve git stash drop (explicit ask)", function()
            assert.is_false(
                PermissionRules.should_auto_approve("git stash drop stash@{0}")
            )
        end)

        it("auto-approves pdftotext foo.pdf -", function()
            assert.is_true(
                PermissionRules.should_auto_approve("pdftotext foo.pdf -")
            )
        end)

        it("does not auto-approve tee out", function()
            -- tee is intentionally absent from permissions.json.
            assert.is_false(PermissionRules.should_auto_approve("tee out"))
        end)

        it("does not auto-approve curl -K config.txt", function()
            assert.is_false(
                PermissionRules.should_auto_approve("curl -K config.txt")
            )
        end)

        it("auto-approves ls --help", function()
            assert.is_true(PermissionRules.should_auto_approve("ls --help"))
        end)

        it(
            "does not auto-approve mlr -I foo even at auto_approve = 'allow' (ask wins)",
            function()
                Config.permissions.auto_approve = "allow"
                PermissionRules.invalidate_cache()
                assert.is_false(
                    PermissionRules.should_auto_approve("mlr -I foo")
                )
            end
        )

        it(
            "auto-approves mlr foo at read-only (mlr writes to stdout)",
            function()
                Config.permissions.auto_approve = "read-only"
                PermissionRules.invalidate_cache()
                assert.is_true(PermissionRules.should_auto_approve("mlr foo"))
            end
        )

        it(
            "does not auto-approve a safe_write command at read-only (stylua)",
            function()
                Config.permissions.auto_approve = "read-only"
                PermissionRules.invalidate_cache()
                assert.is_false(
                    PermissionRules.should_auto_approve("stylua foo.lua")
                )
            end
        )

        it("auto-approves a safe_write command at allow (stylua)", function()
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
            assert.is_true(
                PermissionRules.should_auto_approve("stylua foo.lua")
            )
        end)

        -- Write carve-outs: a read-only base command prompts only on the
        -- options/verbs that actually write (local file, upload, or remote
        -- mutation). Plain invocations still auto-approve.
        it("auto-approves a plain curl GET", function()
            assert.is_true(
                PermissionRules.should_auto_approve("curl https://example.com")
            )
        end)

        it("asks curl -X POST -d (remote mutation)", function()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "curl -X POST -d @body https://example.com"
                )
            )
        end)

        it("asks curl -o (writes a file)", function()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "curl -o out https://example.com"
                )
            )
        end)

        it("asks yq --inplace (long-form write)", function()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "yq --inplace '.a=1' f.yaml"
                )
            )
        end)

        it("asks qalc -s (persists settings)", function()
            assert.is_false(
                PermissionRules.should_auto_approve("qalc -s 'prec 5'")
            )
        end)

        it("auto-approves mlr cat (stdout)", function()
            assert.is_true(
                PermissionRules.should_auto_approve("mlr --icsv cat foo")
            )
        end)

        it("asks mlr split (writes files)", function()
            assert.is_false(
                PermissionRules.should_auto_approve("mlr split -n 1000 foo")
            )
        end)

        it("asks mlr tee (writes a file)", function()
            assert.is_false(
                PermissionRules.should_auto_approve("mlr tee out.csv")
            )
        end)

        it("auto-approves a plain httpie GET", function()
            assert.is_true(
                PermissionRules.should_auto_approve("http https://example.com")
            )
        end)

        it("asks httpie POST (remote mutation, any case)", function()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "http post https://example.com a=b"
                )
            )
        end)

        it("asks httpie --download (writes a file)", function()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "http --download https://example.com"
                )
            )
        end)

        -- Cluster-bypass closure rules: a destructive short letter sharing a
        -- cluster with an allow-listed letter must still prompt.
        it("asks pacman -QR foo (R shares the -Q cluster)", function()
            assert.is_false(
                PermissionRules.should_auto_approve("pacman -QR foo")
            )
        end)

        it("auto-approves pacman -Q kitty", function()
            assert.is_true(
                PermissionRules.should_auto_approve("pacman -Q kitty")
            )
        end)

        it("asks luac -lo evil.luac (o writes bytecode)", function()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "luac -lo evil.luac foo.lua"
                )
            )
        end)

        it("auto-approves luac -l foo.lua", function()
            assert.is_true(
                PermissionRules.should_auto_approve("luac -l foo.lua")
            )
        end)

        it("asks zsh -nc 'rm -rf x' (body command not allowed)", function()
            assert.is_false(
                PermissionRules.should_auto_approve("zsh -nc 'rm -rf x'")
            )
        end)

        it("auto-approves zsh -n script.zsh", function()
            assert.is_true(
                PermissionRules.should_auto_approve("zsh -n script.zsh")
            )
        end)

        -- An inline `<shell> -c '<literal body>'` is re-parsed and walked
        -- recursively (the body is verbatim in rawInput, no file read), so it
        -- approves iff the body approves — instead of firing the `c`-flag ask.
        describe("inline shell -c body", function()
            it("auto-approves zsh -c 'rg foo' (allowed body)", function()
                assert.is_true(
                    PermissionRules.should_auto_approve("zsh -c 'rg foo'")
                )
            end)

            it('auto-approves bash -c "echo hi"', function()
                assert.is_true(
                    PermissionRules.should_auto_approve('bash -c "echo hi"')
                )
            end)

            it("auto-approves a compound body (rg foo | head)", function()
                assert.is_true(
                    PermissionRules.should_auto_approve(
                        "sh -c 'rg foo | head -5'"
                    )
                )
            end)

            it("handles -c as a trailing flag-cluster letter (-lc)", function()
                assert.is_true(
                    PermissionRules.should_auto_approve("zsh -lc 'rg foo'")
                )
            end)

            it("asks when the body holds a non-allowed command", function()
                assert.is_false(
                    PermissionRules.should_auto_approve("zsh -c 'rm foo'")
                )
            end)

            it("asks on a dynamic (opaque) body", function()
                assert.is_false(
                    PermissionRules.should_auto_approve('zsh -c "$x"')
                )
            end)

            it("recurses into a nested -c body", function()
                assert.is_true(
                    PermissionRules.should_auto_approve(
                        [[zsh -c 'zsh -c "rg foo"']]
                    )
                )
            end)
        end)

        it("denies curl --remote-name-all", function()
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "curl --remote-name-all https://x"
                )
            )
        end)

        -- Use-site gate fix: a dynamic token (`$var`, unquoted glob, quoted
        -- expansion) acts as a wildcard for the structured ask/deny gates, so a
        -- gated command cannot launder a payload past them through an opaque
        -- token. Scoped to commands that have a reachable gate — `find`'s danger
        -- is option-keyed (any slot reaches it), `git`'s is keyed to the
        -- subcommand positional (a token after it cannot reach it), and `ls`
        -- has no gate at all.
        describe("use-site dynamic-token gate", function()
            it("prompts on find . $f (-exec gate reachable)", function()
                assert.is_false(
                    PermissionRules.should_auto_approve("find . $f")
                )
            end)

            it('prompts on find "$f" (quoting does not help)', function()
                assert.is_false(
                    PermissionRules.should_auto_approve('find "$f"')
                )
            end)

            it("prompts on sort $f in (-o gate reachable)", function()
                assert.is_false(
                    PermissionRules.should_auto_approve("sort $f in")
                )
            end)

            it("prompts on git $sub (dynamic subcommand)", function()
                assert.is_false(PermissionRules.should_auto_approve("git $sub"))
            end)

            it(
                "prompts on git branch $x (ask gate options wildcard)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("git branch $x")
                    )
                end
            )

            it(
                "auto-approves git log $ref (token after pinned positional)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve("git log $ref")
                    )
                end
            )

            it("auto-approves ls $f (no gate to evade)", function()
                assert.is_true(PermissionRules.should_auto_approve("ls $f"))
            end)

            it(
                "auto-approves find . -name '*.lua' (quoted glob is literal)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "find . -name '*.lua'"
                        )
                    )
                end
            )

            it(
                "prompts on find . -name *.lua (unquoted glob is dynamic)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "find . -name *.lua"
                        )
                    )
                end
            )
        end)

        -- The two phase-2 carve-outs (assignment substitution, loops) defer or
        -- multiply a use site; the gate fix guards that use site, so a payload
        -- routed through them is still caught.
        describe(
            "use-site fix closes the carve-out laundering chains",
            function()
                it(
                    "prompts on f=$(printf …); find . $f (assignment-deferred)",
                    function()
                        assert.is_false(
                            PermissionRules.should_auto_approve(
                                "f=$(printf -- '-exec rm {} ;'); find . $f"
                            )
                        )
                    end
                )

                it(
                    "prompts on for f in *.txt; do find . $f; done (loop-multiplied)",
                    function()
                        assert.is_false(
                            PermissionRules.should_auto_approve(
                                "for f in *.txt; do find . $f; done"
                            )
                        )
                    end
                )

                it(
                    "prompts on find . $(echo -exec rm {} ;) (arg-substitution spliced)",
                    function()
                        -- The inner echo approves, but its output splices in as a
                        -- dynamic token that wildcards find's -exec deny gate.
                        assert.is_false(
                            PermissionRules.should_auto_approve(
                                "find . $(echo -exec rm {} \\;)"
                            )
                        )
                    end
                )

                it(
                    'prompts on g=-exec; find . "$g" echo X {} \\; (flag in a var)',
                    function()
                        assert.is_false(
                            PermissionRules.should_auto_approve(
                                'g=-exec; find . "$g" echo X {} \\;'
                            )
                        )
                    end
                )

                it(
                    "still auto-approves for r in a b; do git show $r; done",
                    function()
                        assert.is_true(
                            PermissionRules.should_auto_approve(
                                "for r in a b; do git show $r; done"
                            )
                        )
                    end
                )

                it(
                    "still auto-approves the git-rev-parse capture idiom",
                    function()
                        assert.is_true(
                            PermissionRules.should_auto_approve(
                                "branch=$(git rev-parse --abbrev-ref HEAD)"
                            )
                        )
                    end
                )

                it("still auto-approves capture-then-cd", function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            'root=$(git rev-parse --git-dir); cd "$root"'
                        )
                    )
                end)
            end
        )

        -- A dynamic token consumed as an option value (only the value-taking
        -- flags of git/gh/aws/flytectl) is removed from the positional stream,
        -- but unquoted it can word-split at runtime and inject a positional
        -- ahead of the visible ones — so it must wildcard positional-keyed
        -- gates too.
        describe("option-value injection wildcards positional gates", function()
            it(
                "prompts on git -C $repo log (dynamic value word-splits)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("git -C $repo log")
                    )
                end
            )

            it(
                "auto-approves git -C /repo log (static value, no injection)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve("git -C /repo log")
                    )
                end
            )

            it("prompts on git -c $x log (dynamic config value)", function()
                assert.is_false(
                    PermissionRules.should_auto_approve("git -c $x log")
                )
            end)
        end)

        -- git's leading `-c x.y=z` is a code channel (`core.pager=!cmd`), so it
        -- is gated even with a static value. The gate is direction-aware: it
        -- matches only in the leading option region, so the dominant `git log
        -- $ref` (dynamic ref after the pinned subcommand, which can never inject
        -- a leading flag) stays AUTO, and a post-subcommand `-c` (the harmless
        -- combined-diff flag) is not flagged.
        describe("git -c leading-option gate", function()
            it(
                "prompts on git -c core.pager=x log (static code channel)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "git -c core.pager=x log"
                        )
                    )
                end
            )

            it(
                "auto-approves git log $ref (trailing token can't inject -c)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve("git log $ref")
                    )
                end
            )

            it(
                "auto-approves git log -c (post-subcommand -c is harmless)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve("git log -c")
                    )
                end
            )

            -- `--config-env=<name>=<envvar>` is git's other leading config
            -- channel ("Like -c <name>=<value>"), so it is the same code
            -- channel as `-c` and must be in `leading_options`. (`--config`
            -- is not a real git option.)
            it(
                "prompts on git --config-env=core.pager=X log (env code channel)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "git --config-env=core.pager=X log"
                        )
                    )
                end
            )
        end)

        -- Correction step: deny/ask branch each leading flag's 0/1 absorption
        -- existentially (no getopt arity table), allow resolves a single parse
        -- via value_options. git's gates are subcommand-keyed, so a leading
        -- flag that shifts the subcommand in the took-0 parse exposes it.
        describe("absorption matching", function()
            it(
                "auto-approves git -C /repo log (value-taker absorbs /repo)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve("git -C /repo log")
                    )
                end
            )

            it(
                "prompts on git -p push (zero-arity global can't hide push)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("git -p push")
                    )
                end
            )

            it("prompts on git --no-pager push", function()
                assert.is_false(
                    PermissionRules.should_auto_approve("git --no-pager push")
                )
            end)

            it(
                "prompts on git --new-global val push (unknown value-taker)",
                function()
                    -- The old silent OPTION_VALUE_TAKERS hole: an unlisted
                    -- value-taker mis-split the args and hid the real subcommand.
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "git --new-global val push"
                        )
                    )
                end
            )

            it(
                "prompts on git --foo ci log (single-parse allow: unknown subcommand)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("git --foo ci log")
                    )
                end
            )

            it(
                "prompts on git -C push log (accepted false-positive)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("git -C push log")
                    )
                end
            )

            it(
                "auto-approves xargs -0 ls (unlisted leading flag absorbs 0)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve("xargs -0 ls")
                    )
                end
            )
        end)

        -- a `$var` bound to a splitting-proof literal earlier in the same
        -- straight-line sequence resolves to that literal (static), so a benign
        -- value no longer wildcard-fires a gate — while the literal feeds the
        -- SAME gates, and any non-inert sibling clears the binding (over-prompt).
        describe("constant-literal propagation", function()
            it(
                "approves f=/safe/dir; find $f (benign value recovered)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "f=/safe/dir; find $f"
                        )
                    )
                end
            )

            it("approves f=/safe; find ${f} (braced reference)", function()
                assert.is_true(
                    PermissionRules.should_auto_approve("f=/safe; find ${f}")
                )
            end)

            it(
                'approves base=/safe/dir; find "$base" (quoted reference recovered)',
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            'base=/safe/dir; find "$base"'
                        )
                    )
                end
            )

            it(
                'approves base=/safe; find "${base}" (braced quoted reference)',
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            'base=/safe; find "${base}"'
                        )
                    )
                end
            )

            it(
                'prompts on base=--exec; find "$base" (deny resolves through quoting)',
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            'base=--exec; find "$base"'
                        )
                    )
                end
            )

            it('prompts on find "$base" (unbound quoted var)', function()
                assert.is_false(
                    PermissionRules.should_auto_approve('find "$base"')
                )
            end)

            it(
                'prompts on base=/safe; find "$base/x" (concatenation not resolved)',
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            'base=/safe; find "$base/x"'
                        )
                    )
                end
            )

            it(
                'prompts on base=/safe; find "${base:-x}" (richer expansion not resolved)',
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            'base=/safe; find "${base:-x}"'
                        )
                    )
                end
            )

            -- With quoted-substitution handling the quoted `"$(echo x)"` is walked
            -- and spliced as a dynamic token; it prompts because that token
            -- wildcard-fires find's `-exec` deny (the gate wildcard), not because
            -- the substitution bails. The bare `find $(echo x)` already prompts
            -- the same way, so quoted-substitution handling never flipped this boolean.
            it(
                'prompts on base=/safe; find "$(echo x)" (dynamic token wildcards find\'s -exec deny)',
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            'base=/safe; find "$(echo x)"'
                        )
                    )
                end
            )

            it(
                "approves d=/repo; git -C $d log (resolved option value)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "d=/repo; git -C $d log"
                        )
                    )
                end
            )

            it(
                "approves f=data.txt; sort $f (benign positional recovered)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "f=data.txt; sort $f"
                        )
                    )
                end
            )

            it(
                "approves f=/safe; ls; find $f (inert command preserves binding)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "f=/safe; ls; find $f"
                        )
                    )
                end
            )

            it(
                "prompts on f=--exec; find $f (literal feeds the same deny gate)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("f=--exec; find $f")
                    )
                end
            )

            it(
                "prompts on f='-exec rm'; find $f (multi-word literal not propagated)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "f='-exec rm'; find $f"
                        )
                    )
                end
            )

            it(
                "prompts on f=*.txt; find $f (glob value not propagated)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("f=*.txt; find $f")
                    )
                end
            )

            it(
                "prompts on f=/safe; f=$x; find $f (reassignment to dynamic drops it)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "f=/safe; f=$x; find $f"
                        )
                    )
                end
            )

            it(
                "prompts on f=/safe; printf -v f -- -exec; find $f (printf -v rebinds)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "f=/safe; printf -v f -- -exec; find $f"
                        )
                    )
                end
            )

            it(
                "approves f=/safe; printf 'msg'; find $f (plain printf is inert)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "f=/safe; printf 'msg'; find $f"
                        )
                    )
                end
            )

            it(
                "approves f=/safe; printf -v g x; find $f (printf -v drops only its target)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "f=/safe; printf -v g x; find $f"
                        )
                    )
                end
            )

            -- capable grade: a control-flow sibling drops only the names it
            -- could rebind, not all of `known`.
            it(
                "approves f=/safe; if true; then echo hi; fi; find $f (binding-free if preserves)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "f=/safe; if true; then echo hi; fi; find $f"
                        )
                    )
                end
            )

            it(
                "approves f=/safe; [[ -n x ]] && echo ok; find $f (test guard preserves)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "f=/safe; [[ -n x ]] && echo ok; find $f"
                        )
                    )
                end
            )

            it(
                "approves f=/safe; for x in a b; do echo $x; done; find $f (loop over other var preserves)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "f=/safe; for x in a b; do echo $x; done; find $f"
                        )
                    )
                end
            )

            it(
                "prompts on f=/safe; if true; then f=/danger; fi; find $f (if-body rebinds the var)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "f=/safe; if true; then f=/danger; fi; find $f"
                        )
                    )
                end
            )

            it(
                "prompts on f=/safe; for f in a b; do echo $f; done; find $f (loop rebinds the var)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "f=/safe; for f in a b; do echo $f; done; find $f"
                        )
                    )
                end
            )

            it(
                "prompts on f=/safe; if c; then printf -v f -- -exec; fi; find $f (printf -v in if-body rebinds)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "f=/safe; if true; then printf -v f -- -exec; fi; find $f"
                        )
                    )
                end
            )

            it(
                "approves f=/safe; find $f; printf x (resolved before the clearing sibling)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "f=/safe; find $f; printf x"
                        )
                    )
                end
            )

            it(
                "does not leak across statements — bare find $f still prompts",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("find $f")
                    )
                end
            )
        end)

        describe("concatenation token shape", function()
            it(
                "approves head -40 $d/SKILL.md (dynamic token, empty read_only gate)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "head -40 $d/SKILL.md"
                        )
                    )
                end
            )

            it(
                "approves ls -la $d (bare dynamic unchanged — regression guard)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve("ls -la $d")
                    )
                end
            )

            it(
                "prompts on find . $d/x (dynamic wildcard fires find's -exec deny)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("find . $d/x")
                    )
                end
            )

            it(
                "approves base=/safe; head $base/x (static resolution)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "base=/safe; head $base/x"
                        )
                    )
                end
            )

            -- A dangerous literal still hits the gate after static resolution.
            -- `-o` glues its value (`-o/x`), so short-flag clustering extracts the
            -- `o` candidate and sort's write gate fires. This is the sound
            -- symmetry with `f=--exec; find $f`.
            it(
                "prompts on base=-o; sort $base/x (resolved literal hits sort's write gate)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "base=-o; sort $base/x"
                        )
                    )
                end
            )

            -- A concatenation suffix (`/x`) can never reconstruct a bare gate flag:
            -- the resolved `--exec/x` is a single long token that does not
            -- prefix-match find's `exec` option (long options need `=` to split a
            -- value), and `find --exec/x` is an unknown predicate at runtime, not
            -- the `-exec` action. So it approves — safe, unlike the bare
            -- `f=--exec; find $f` where `$f` resolves to exactly `-exec`.
            it(
                "approves base=--exec; find $base/x (suffix neutralises — cannot be a bare flag)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "base=--exec; find $base/x"
                        )
                    )
                end
            )

            it(
                "approves head $d/*.js (glob part keeps it dynamic, empty gate)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve("head $d/*.js")
                    )
                end
            )

            it(
                "prompts on rm $d/*.js (glob part → dynamic wildcards rm's gate)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("rm $d/*.js")
                    )
                end
            )

            it(
                "prompts on cat a$(b)c (command-sub concatenation stays bailed)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("cat a$(b)c")
                    )
                end
            )

            it(
                "prompts on echo x > $d/f (dynamic redirect target still bails)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve("echo x > $d/f")
                    )
                end
            )
        end)

        -- a for-loop over an all-literal list unrolls the body once per value
        -- with the loop var pre-bound (concatenation resolution resolves the body
        -- concatenation against it), so a gated body command is checked per value;
        -- the loop approves iff every value approves. A non-literal list or an
        -- over-budget value count falls back to the single dynamic walk (the
        -- dynamic-token floor).
        describe("for-loop literal unroll", function()
            it(
                "approves for d in acp permissions provider-system; do find . $d/SKILL.md; done (all values are positional paths)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "for d in acp permissions provider-system; do find . $d/SKILL.md; done"
                        )
                    )
                end
            )

            it(
                "prompts on for d in acp -delete; do find . $d; done (one value trips find's deny)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "for d in acp -delete; do find . $d; done"
                        )
                    )
                end
            )

            it(
                "approves for d in acp permissions; do head $d/SKILL.md; done (also passes via concatenation resolution alone)",
                function()
                    assert.is_true(
                        PermissionRules.should_auto_approve(
                            "for d in acp permissions; do head $d/SKILL.md; done"
                        )
                    )
                end
            )

            it(
                "prompts on for f in $(ls); do find . $f; done (non-literal list → dynamic fallback)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "for f in $(ls); do find . $f; done"
                        )
                    )
                end
            )

            -- Nested literal loops multiply: outer 9 values (≤64) divides the
            -- budget to floor(64/9)=7, so the inner 9-value loop exceeds it and
            -- falls back to the dynamic walk, where the gated body prompts.
            it(
                "prompts on nested literal loops beyond the product cap with a gated body",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "for a in 1 2 3 4 5 6 7 8 9; do for b in 1 2 3 4 5 6 7 8 9; do find . $b; done; done"
                        )
                    )
                end
            )

            -- A body that rebinds the loop var drops the seed (update_known runs
            -- per body statement), so the subsequent use is dynamic again.
            it(
                "prompts on for d in acp; do d=$x; find . $d; done (body rebinds the loop var to dynamic)",
                function()
                    assert.is_false(
                        PermissionRules.should_auto_approve(
                            "for d in acp; do d=$x; find . $d; done"
                        )
                    )
                end
            )
        end)

        -- Reject pass: a concrete deny gate rejects outright (no prompt). ask
        -- and unknown commands fall through to should_auto_reject == false (the
        -- approve walk then decides prompt vs approve).
        describe("should_auto_reject", function()
            local rejected = {
                "find . -delete",
                "fd -x rm",
                "date -s '2020-01-01'",
                "awk 'BEGIN{system(\"rm -rf /\")}'",
                "rm -f x",
                "rm -rf x", -- clustered force flag
                "ls | find . -delete", -- deny leaf in a pipeline
                "ls && find . -delete", -- deny leaf in an && chain
                "echo $(find . -delete)", -- deny leaf in a substitution
                "( find . -delete )", -- deny leaf inside a subshell
                "timeout 5 rm -f x", -- deny survives a transparent wrapper
            }
            for _, cmd in ipairs(rejected) do
                it("rejects: " .. cmd, function()
                    assert.is_true(PermissionRules.should_auto_reject(cmd))
                end)
            end

            local not_rejected = {
                "ls -la", -- clean read-only
                "rm x", -- plain rm is ask, not deny
                "sed -i 's/a/b/' f", -- in-place edit is ask, not deny
                "mlr -I foo", -- in-place edit is ask, not deny
                "rm $flags x", -- concrete-only: dynamic token does not reject
                "rm -rf / |", -- parse failure: fail-closed to prompt, not reject
            }
            for _, cmd in ipairs(not_rejected) do
                it("does not reject: " .. cmd, function()
                    assert.is_false(PermissionRules.should_auto_reject(cmd))
                end)
            end
        end)
    end)

    describe("tally_unapproved", function()
        local Config = require("agentic.config")

        --- Run `fn` with settings.json permissions stubbed and plugin defaults
        --- disabled, so only the injected globs (plus any `config` overrides on
        --- Config.permissions) classify leaves. Structured entries stay empty.
        local function with_perms(permissions, config, fn)
            local orig_read_json = PermissionRules.read_json
            local orig_plugin = Config.permissions.use_plugin_defaults
            local orig_config = {}
            for k, v in pairs(config or {}) do
                orig_config[k] = Config.permissions[k]
                Config.permissions[k] = v
            end
            Config.permissions.use_plugin_defaults = false
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return { permissions = permissions }
                end
                return nil
            end
            PermissionRules.invalidate_cache()

            local ok, err = pcall(fn)

            PermissionRules.read_json = orig_read_json
            Config.permissions.use_plugin_defaults = orig_plugin
            for k in pairs(config or {}) do
                Config.permissions[k] = orig_config[k]
            end
            PermissionRules.invalidate_cache()
            if not ok then
                error(err)
            end
        end

        --- The byte substring of a single-line `command` covered by `range`.
        --- @param command string
        --- @param range agentic.utils.PermissionRules.Range
        local function span_text(command, range)
            return command:sub(range[2] + 1, range[4])
        end

        it("returns only the unapproved leaf of a mixed pipeline", function()
            with_perms(
                { allow = { "Bash(grep *)" }, deny = { "Bash(rm *)" } },
                nil,
                function()
                    local cmd = "grep foo | rm bar"
                    local ranges = PermissionRules.tally_unapproved(cmd)
                    assert.equal(1, #ranges)
                    assert.equal("rm bar", span_text(cmd, ranges[1]))
                end
            )
        end)

        it("records nothing for a fully-approved subshell", function()
            with_perms({ allow = { "Bash(echo *)" } }, nil, function()
                local ranges =
                    PermissionRules.tally_unapproved("( echo a && echo b )")
                assert.equal(0, #ranges)
            end)
        end)

        it("washes only the gated leaf of a subshell", function()
            with_perms({ allow = { "Bash(echo *)" } }, nil, function()
                local cmd = "( echo a; rm b )"
                local ranges = PermissionRules.tally_unapproved(cmd)
                assert.equal(1, #ranges)
                assert.equal("rm b", span_text(cmd, ranges[1]))
            end)
        end)

        it(
            "returns only the unapproved inner of a single-quoted -c body",
            function()
                with_perms(
                    { allow = { "Bash(grep *)" }, deny = { "Bash(rm *)" } },
                    nil,
                    function()
                        local cmd = "zsh -c 'rm -rf /'"
                        local ranges = PermissionRules.tally_unapproved(cmd)
                        assert.equal(1, #ranges)
                        assert.equal("rm -rf /", span_text(cmd, ranges[1]))
                    end
                )
            end
        )

        it("highlights the whole leaf for a double-quoted -c body", function()
            with_perms(
                { allow = { "Bash(grep *)" }, deny = { "Bash(rm *)" } },
                nil,
                function()
                    local cmd = 'zsh -c "rm -rf /"'
                    local ranges = PermissionRules.tally_unapproved(cmd)
                    assert.equal(1, #ranges)
                    assert.equal(cmd, span_text(cmd, ranges[1]))
                end
            )
        end)

        it(
            "pinpoints the inner row of a multi-line single-quoted -c body",
            function()
                with_perms(
                    { allow = { "Bash(grep *)" }, deny = { "Bash(rm *)" } },
                    nil,
                    function()
                        local cmd = "zsh -c 'grep foo\nrm bar'"
                        local ranges = PermissionRules.tally_unapproved(cmd)
                        assert.equal(1, #ranges)
                        local r = ranges[1]
                        assert.equal(1, r[1]) -- row 1 (rm bar), not row 0 (grep foo)
                        assert.equal(
                            "rm bar",
                            vim.split(cmd, "\n")[r[1] + 1]:sub(r[2] + 1, r[4])
                        )
                    end
                )
            end
        )

        it("does not return a safe_write leaf (intrinsically safe)", function()
            with_perms(
                { allow = { "Bash(echo *)" } },
                { safe_write = { "Bash(git add *)" } },
                function()
                    local ranges = PermissionRules.tally_unapproved("git add x")
                    assert.equal(0, #ranges)
                end
            )
        end)

        it("returns an unknown command", function()
            with_perms({ allow = { "Bash(grep *)" } }, nil, function()
                local cmd = "frobnicate x"
                local ranges = PermissionRules.tally_unapproved(cmd)
                assert.equal(1, #ranges)
                assert.equal("frobnicate x", span_text(cmd, ranges[1]))
            end)
        end)

        it(
            "returns only the unapproved inner of an arg substitution",
            function()
                with_perms(
                    { allow = { "Bash(echo *)" }, deny = { "Bash(rm *)" } },
                    nil,
                    function()
                        local cmd = "echo $(rm -rf /)"
                        local ranges = PermissionRules.tally_unapproved(cmd)
                        assert.equal(1, #ranges)
                        assert.equal("rm -rf /", span_text(cmd, ranges[1]))
                    end
                )
            end
        )

        it(
            "highlights the whole leaf when the command name is denied",
            function()
                with_perms(
                    { allow = { "Bash(echo *)" }, deny = { "Bash(rm *)" } },
                    nil,
                    function()
                        local cmd = "rm $(rm -rf /)"
                        local ranges = PermissionRules.tally_unapproved(cmd)
                        assert.equal(1, #ranges)
                        assert.equal(cmd, span_text(cmd, ranges[1]))
                    end
                )
            end
        )

        it(
            "returns nothing when an arg substitution's inner is approved",
            function()
                with_perms({ allow = { "Bash(echo *)" } }, nil, function()
                    local ranges =
                        PermissionRules.tally_unapproved("echo $(echo hi)")
                    assert.equal(0, #ranges)
                end)
            end
        )

        it(
            "returns nothing for a for-loop over an approved substitution",
            function()
                with_perms({ allow = { "Bash(echo *)" } }, nil, function()
                    local ranges = PermissionRules.tally_unapproved(
                        'for f in $(echo x); do echo "$f"; done'
                    )
                    assert.equal(0, #ranges)
                end)
            end
        )

        it(
            "returns only the unapproved inner of a quoted substitution",
            function()
                with_perms(
                    { allow = { "Bash(echo *)" }, deny = { "Bash(rm *)" } },
                    nil,
                    function()
                        local cmd = 'echo "$(rm -rf /)"'
                        local ranges = PermissionRules.tally_unapproved(cmd)
                        assert.equal(1, #ranges)
                        assert.equal("rm -rf /", span_text(cmd, ranges[1]))
                    end
                )
            end
        )

        it("pinpoints the inner of a string-embedded substitution", function()
            with_perms(
                { allow = { "Bash(echo *)" }, deny = { "Bash(rm *)" } },
                nil,
                function()
                    local cmd = 'echo "x $(rm y)"'
                    local ranges = PermissionRules.tally_unapproved(cmd)
                    assert.equal(1, #ranges)
                    assert.equal("rm y", span_text(cmd, ranges[1]))
                end
            )
        end)

        it(
            "returns only the unapproved inner of an assignment substitution",
            function()
                with_perms(
                    { allow = { "Bash(echo *)" }, deny = { "Bash(rm *)" } },
                    nil,
                    function()
                        local cmd = "f=$(rm -rf /)"
                        local ranges = PermissionRules.tally_unapproved(cmd)
                        assert.equal(1, #ranges)
                        assert.equal("rm -rf /", span_text(cmd, ranges[1]))
                    end
                )
            end
        )

        it(
            "returns only the unapproved inner of a for-list substitution",
            function()
                with_perms(
                    { allow = { "Bash(echo *)" }, deny = { "Bash(rm *)" } },
                    nil,
                    function()
                        local cmd = "for f in $(rm -rf /); do echo hi; done"
                        local ranges = PermissionRules.tally_unapproved(cmd)
                        assert.equal(1, #ranges)
                        assert.equal("rm -rf /", span_text(cmd, ranges[1]))
                    end
                )
            end
        )

        it("pinpoints a substitution inside a transparent prefix", function()
            with_perms(
                {
                    allow = { "Bash(echo *)", "Bash(timeout *)" },
                    deny = { "Bash(rm *)" },
                },
                nil,
                function()
                    local cmd = "timeout 5 echo $(rm -rf /)"
                    local ranges = PermissionRules.tally_unapproved(cmd)
                    assert.equal(1, #ranges)
                    assert.equal("rm -rf /", span_text(cmd, ranges[1]))
                end
            )
        end)

        it("returns an unsafe redirect", function()
            with_perms({ allow = { "Bash(grep *)" } }, nil, function()
                local cmd = "grep foo > out.txt"
                local ranges = PermissionRules.tally_unapproved(cmd)
                assert.equal(1, #ranges)
                assert.is_true(span_text(cmd, ranges[1]):find("out.txt") ~= nil)
            end)
        end)

        it(
            "does not highlight a constant-resolved benign $var (bundled defaults)",
            function()
                -- `find $f` resolves to /safe (known-safe via the bundled find rule),
                -- so only the unknown command highlights. Without the constant-
                -- propagation mirror, $f would wildcard-fire find's -exec deny and
                -- light up too. Needs the structured (bundled) gate — a glob deny
                -- cannot get the dynamic-token wildcard treatment.
                local orig_read_json = PermissionRules.read_json
                local orig_plugin = Config.permissions.use_plugin_defaults
                Config.permissions.use_plugin_defaults = true
                PermissionRules.read_json = function(path)
                    if path:find("settings%.json$") then
                        return nil
                    end
                    return orig_read_json(path)
                end
                PermissionRules.invalidate_cache()
                local ok, err = pcall(function()
                    local cmd = "f=/safe; find $f; frobnicate x"
                    local ranges = PermissionRules.tally_unapproved(cmd)
                    assert.equal(1, #ranges)
                    assert.equal("frobnicate x", span_text(cmd, ranges[1]))
                end)
                PermissionRules.read_json = orig_read_json
                Config.permissions.use_plugin_defaults = orig_plugin
                PermissionRules.invalidate_cache()
                if not ok then
                    error(err)
                end
            end
        )

        it("returns every unapproved leaf (record-and-continue)", function()
            with_perms({ allow = {} }, nil, function()
                local ranges =
                    PermissionRules.tally_unapproved("frob a | nope b")
                assert.equal(2, #ranges)
            end)
        end)

        it("returns nil on parse failure", function()
            with_perms({ allow = { "Bash(echo *)" } }, nil, function()
                assert.is_nil(
                    PermissionRules.tally_unapproved("echo 'unterminated")
                )
            end)
        end)

        it("returns nil for empty input", function()
            assert.is_nil(PermissionRules.tally_unapproved(""))
        end)

        it("returns nothing for a wrapper with a known-safe inner", function()
            with_perms({ allow = { "Bash(grep *)" } }, nil, function()
                local ranges =
                    PermissionRules.tally_unapproved("timeout 5 grep foo")
                assert.equal(0, #ranges)
            end)
        end)

        it("pinpoints only the unapproved inner of a wrapper", function()
            with_perms(
                { allow = { "Bash(grep *)" }, deny = { "Bash(rm *)" } },
                nil,
                function()
                    local cmd = "timeout 5 rm -rf /"
                    local ranges = PermissionRules.tally_unapproved(cmd)
                    assert.equal(1, #ranges)
                    assert.equal("rm -rf /", span_text(cmd, ranges[1]))
                end
            )
        end)

        -- The deny case above reaches the sub-range via the deny matcher; an
        -- inner that is merely not-allowed reaches it through the recursive
        -- leaf `record` instead. Both must translate to the same pinpoint.
        it("pinpoints a not-allowed (non-deny) wrapper inner", function()
            with_perms({ allow = { "Bash(grep *)" } }, nil, function()
                local cmd = "timeout 5 curl x"
                local ranges = PermissionRules.tally_unapproved(cmd)
                assert.equal(1, #ranges)
                assert.equal("curl x", span_text(cmd, ranges[1]))
            end)
        end)

        describe("leaves / complete", function()
            it("collects both no-allow-rule leaves, complete", function()
                with_perms({ allow = {} }, nil, function()
                    local ranges, leaves, complete =
                        PermissionRules.tally_unapproved("frob a | nope b")
                    assert.equal(2, #ranges)
                    assert.same({ "frob a", "nope b" }, leaves)
                    assert.is_true(complete)
                end)
            end)

            it("is incomplete for a write redirect", function()
                with_perms({ allow = { "Bash(grep *)" } }, nil, function()
                    local _, leaves, complete =
                        PermissionRules.tally_unapproved("grep foo > out.txt")
                    assert.same({}, leaves)
                    assert.is_false(complete)
                end)
            end)

            it("is incomplete for a dirty-substitution leaf", function()
                with_perms(
                    { allow = { "Bash(echo *)" }, deny = { "Bash(rm *)" } },
                    nil,
                    function()
                        local _, leaves, complete =
                            PermissionRules.tally_unapproved("echo $(rm -rf /)")
                        assert.same({}, leaves)
                        assert.is_false(complete)
                    end
                )
            end)

            -- Q2: an ask-gated leaf is NOT rememberable — it must drop `complete`
            -- so the manager keeps the whole-command fallback (else the identical
            -- block re-prompts forever, the injected allow being gated by `ask`).
            it("is incomplete for an ask-gated leaf", function()
                with_perms(
                    { allow = { "Bash(echo *)" }, ask = { "Bash(rm *)" } },
                    nil,
                    function()
                        local _, leaves, complete =
                            PermissionRules.tally_unapproved("echo hi; rm x")
                        assert.same({}, leaves)
                        assert.is_false(complete)
                    end
                )
            end)

            it(
                "collects the clean leaf but is incomplete alongside a redirect",
                function()
                    with_perms({ allow = { "Bash(grep *)" } }, nil, function()
                        local _, leaves, complete =
                            PermissionRules.tally_unapproved("frob a > out.txt")
                        assert.same({ "frob a" }, leaves)
                        assert.is_false(complete)
                    end)
                end
            )

            it(
                "returns empty leaves and incomplete on parse failure",
                function()
                    with_perms({ allow = { "Bash(echo *)" } }, nil, function()
                        local ranges, leaves, complete =
                            PermissionRules.tally_unapproved(
                                "echo 'unterminated"
                            )
                        assert.is_nil(ranges)
                        assert.same({}, leaves)
                        assert.is_false(complete)
                    end)
                end
            )
        end)
    end)

    describe("literal_pattern / remembered-leaf injection", function()
        local Config = require("agentic.config")

        --- Evaluate `cmd` with only the injected allow globs active (plugin
        --- defaults off, settings.json stubbed empty), passing `extra_allow`
        --- through to the decision walk.
        local function approves(allow, deny, cmd, extra_allow)
            local orig_read_json = PermissionRules.read_json
            local orig_plugin = Config.permissions.use_plugin_defaults
            Config.permissions.use_plugin_defaults = false
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return { permissions = { allow = allow, deny = deny } }
                end
                return nil
            end
            PermissionRules.invalidate_cache()
            local ok, result =
                pcall(PermissionRules.should_auto_approve, cmd, extra_allow)
            PermissionRules.read_json = orig_read_json
            Config.permissions.use_plugin_defaults = orig_plugin
            PermissionRules.invalidate_cache()
            if not ok then
                error(result)
            end
            return result
        end

        it("matches its own occurrence (path-stripped)", function()
            local pat = PermissionRules.literal_pattern("/usr/bin/foo --x")
            assert.is_true(approves({}, nil, "/usr/bin/foo --x", { pat }))
        end)

        it("does not widen to a different invocation", function()
            local pat = PermissionRules.literal_pattern("foo --x")
            assert.is_false(approves({}, nil, "foo --y", { pat }))
        end)

        it("approves only when every leaf is remembered or ruled", function()
            assert.is_false(
                approves(
                    {},
                    nil,
                    "a; b",
                    { PermissionRules.literal_pattern("b") }
                )
            )
            assert.is_true(approves({}, nil, "a; b", {
                PermissionRules.literal_pattern("a"),
                PermissionRules.literal_pattern("b"),
            }))
        end)

        it("never overrides a deny gate", function()
            assert.is_false(
                approves(
                    {},
                    { "Bash(rm *)" },
                    "rm x",
                    { PermissionRules.literal_pattern("rm x") }
                )
            )
        end)

        -- Merge-before-guard: an empty remembered set leaves #allow == 0, so the
        -- evaluate guard still short-circuits (bails) exactly as before.
        it("is a no-op with an empty remembered set", function()
            assert.is_false(approves({}, nil, "a", {}))
            assert.is_false(approves({}, nil, "a"))
        end)
    end)

    describe("should_auto_approve exec-wrappers", function()
        --- Run `fn` with grep/cat/head allowed and rm/sed-i denied, so the
        --- inner-command recursion is what decides each wrapped case.
        local function with_wrapper_perms(fn)
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = {
                                "Bash(grep *)",
                                "Bash(cat *)",
                                "Bash(head *)",
                            },
                            deny = { "Bash(rm *)", "Bash(sed * -i*)" },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()
            local ok, err = pcall(fn)
            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
            if not ok then
                error(err)
            end
        end

        local approve = {
            "timeout 5 grep foo",
            "timeout -s KILL -k 1 5 grep foo",
            "time grep foo",
            "time -p grep foo",
            "/usr/bin/time grep foo",
            "stdbuf -oL grep foo",
            "stdbuf -i0 -o0 grep foo",
            "stdbuf -oL timeout 5 grep foo", -- nested wrappers
            "PYTHONUNBUFFERED=1 timeout 5 grep foo", -- assignment + wrapper
            "timeout 5 grep foo | head -5", -- compound
            "timeout 5 grep $(cat list)", -- vetted substitution under a wrapper
        }
        for _, cmd in ipairs(approve) do
            it("approves: " .. cmd, function()
                with_wrapper_perms(function()
                    assert.is_true(PermissionRules.should_auto_approve(cmd))
                end)
            end)
        end

        local prompt = {
            "timeout 5 rm -rf /", -- inner not allowed (deny)
            "time rm x",
            "timeout 5 sed -i 's/x/y/' f", -- ask survives wrapper
            "timeout 5 PATH=/evil grep foo", -- inner env hijacker
            "/usr/bin/time -o out grep foo", -- write option
            "timeout 5 grep foo > out", -- write redirect
            "timeout 5 grep $(rm list)", -- substitution with a denied inner
            "timeout 5 $(echo rm) -rf /",
            "timeout grep foo", -- grep skipped as DURATION; inner `foo` not allowed
            "timeout 5", -- empty inner
            "timeout --unknown-opt 5 grep foo", -- unrecognised option
        }
        for _, cmd in ipairs(prompt) do
            it("prompts: " .. cmd, function()
                with_wrapper_perms(function()
                    assert.is_false(PermissionRules.should_auto_approve(cmd))
                end)
            end)
        end
    end)

    describe("script file walk (Step A)", function()
        local written = {}

        --- Write `content` to file `path` (Lua's `assert` is shadowed by the
        --- luassert helper here, so error explicitly on open failure).
        local function write_file(path, content)
            local f = io.open(path, "w")
            if not f then
                error("could not open " .. path)
            end
            f:write(content)
            f:close()
        end

        --- Write `content` to a fresh temp `.sh` and return its absolute path.
        local function script(content)
            local path = vim.fn.tempname() .. ".sh"
            write_file(path, content)
            table.insert(written, path)
            return path
        end

        local orig_read_json
        before_each(function()
            orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            allow = { "Bash(ls *)", "Bash(grep *)" },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()
        end)
        after_each(function()
            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
            for _, path in ipairs(written) do
                os.remove(path)
            end
            written = {}
        end)

        it("approves `zsh <file>` whose body is all-allowed", function()
            local path = script("ls -la\ngrep foo bar\n")
            assert.is_true(PermissionRules.should_auto_approve("zsh " .. path))
        end)

        it("does not approve a body with a non-allowed command", function()
            local path = script("ls /tmp\nmake build\n")
            assert.is_false(PermissionRules.should_auto_approve("zsh " .. path))
        end)

        it("approves `source <file>` / `. <file>` on a slash path", function()
            local path = script("ls /tmp\n")
            assert.is_true(
                PermissionRules.should_auto_approve("source " .. path)
            )
            assert.is_true(PermissionRules.should_auto_approve(". " .. path))
        end)

        it("bails `source <name>` without a slash", function()
            assert.is_false(PermissionRules.should_auto_approve("source foo"))
        end)

        it("`eval` still bails", function()
            assert.is_false(PermissionRules.should_auto_approve("eval 'ls'"))
        end)

        it("bails a dynamic script path", function()
            assert.is_false(
                PermissionRules.should_auto_approve("zsh $UNBOUND_SCRIPT")
            )
        end)

        it("recurses a sourced helper transitively", function()
            local helper = script("ls /tmp\n")
            local main = script("ls /tmp\nsource " .. helper .. "\n")
            assert.is_true(PermissionRules.should_auto_approve("zsh " .. main))
        end)

        it("bails `source` when a sibling .zwc shadows the file", function()
            local path = script("ls /tmp\n")
            write_file(path .. ".zwc", "compiled")
            table.insert(written, path .. ".zwc")
            assert.is_false(
                PermissionRules.should_auto_approve("source " .. path)
            )
            -- `zsh <file>` runs the text, ignoring the .zwc.
            assert.is_true(PermissionRules.should_auto_approve("zsh " .. path))
        end)

        it("a self-sourcing cycle terminates and bails", function()
            local path = vim.fn.tempname() .. ".sh"
            write_file(path, "ls /tmp\nsource " .. path .. "\n")
            table.insert(written, path)
            assert.is_false(PermissionRules.should_auto_approve("zsh " .. path))
        end)

        it("bails an oversize body (> 64 KB)", function()
            local path = script(string.rep("ls /tmp\n", 9000))
            assert.is_false(PermissionRules.should_auto_approve("zsh " .. path))
        end)

        it(
            "surfaces a body's write effect; no scope → not approved",
            function()
                local path = script("ls /tmp > /tmp/scratch_step_a\n")
                local ok, effects = PermissionRules.evaluate("zsh " .. path)
                assert.is_true(ok)
                assert.equal("write", effects[1].kind)
                assert.equal("/tmp/scratch_step_a", effects[1].path)
                assert.is_false(
                    PermissionRules.should_auto_approve("zsh " .. path)
                )
            end
        )

        it(
            "taint: bails reading a path written earlier in the command",
            function()
                -- Disk holds safe bytes, but the in-block redirect overwrites the
                -- file before it runs — walking disk would judge stale content.
                local path = script("ls /tmp\n")
                local ok = PermissionRules.evaluate(
                    "ls /tmp > " .. path .. "; zsh " .. path
                )
                assert.is_false(ok)
            end
        )

        it(
            "taint: a write AFTER the execute does not bail (reads disk)",
            function()
                local path = script("ls /tmp\n")
                local ok, effects = PermissionRules.evaluate(
                    "zsh " .. path .. "; ls /tmp > " .. path
                )
                assert.is_true(ok)
                assert.equal("write", effects[1].kind)
            end
        )

        it(
            "taint: bails when write target and script path differ only by a parent symlink",
            function()
                -- Producer writes via the symlinked dir, executor reads via the
                -- real dir — same inode, two name strings. A lexical-only resolver
                -- would miss the correlation and approve stale disk bytes.
                local real_dir = vim.fn.tempname()
                vim.uv.fs_mkdir(real_dir, 493) -- 0755
                local link_dir = vim.fn.tempname()
                vim.uv.fs_symlink(real_dir, link_dir)
                write_file(real_dir .. "/f.sh", "ls /tmp\n")
                table.insert(written, real_dir .. "/f.sh")
                table.insert(written, link_dir)
                table.insert(written, real_dir)
                local ok = PermissionRules.evaluate(
                    "ls /tmp > "
                        .. link_dir
                        .. "/f.sh; zsh "
                        .. real_dir
                        .. "/f.sh"
                )
                assert.is_false(ok)
            end
        )

        it("tally: a clean body yields no ranges", function()
            local path = script("ls /tmp\n")
            local ranges = PermissionRules.tally_unapproved("zsh " .. path)
            assert.equal(0, #ranges)
        end)

        it(
            "tally: an unsafe body washes the whole leaf, not rememberable",
            function()
                local path = script("make build\n")
                local ranges, leaves, complete =
                    PermissionRules.tally_unapproved("zsh " .. path)
                assert.equal(1, #ranges)
                assert.equal(0, #leaves)
                assert.is_false(complete)
            end
        )
    end)

    describe("script file walk (Step B — heredoc reconstruction)", function()
        local written = {}

        local function write_file(path, content)
            local f = io.open(path, "w")
            if not f then
                error("could not open " .. path)
            end
            f:write(content)
            f:close()
        end

        --- Write `content` to a fresh temp `.sh` and return its absolute path.
        local function script(content)
            local path = vim.fn.tempname() .. ".sh"
            write_file(path, content)
            table.insert(written, path)
            return path
        end

        --- A temp `.sh` path that is NOT created on disk — a script generated
        --- inline by the command under test, so reconstruction is the only way
        --- its body can be walked.
        local function ghost()
            return vim.fn.tempname() .. ".sh"
        end

        --- `cat > path <<'DELIM' … DELIM\nzsh path` for a quoted (literal) heredoc.
        local function create_run(path, body, op, delim)
            op = op or ">"
            delim = delim or "'EOF'"
            return ("cat %s %s <<%s\n%sEOF\nzsh %s"):format(
                op,
                path,
                delim,
                body,
                path
            )
        end

        local orig_read_json
        before_each(function()
            orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return {
                        permissions = {
                            -- `Bash(cat)` (bare, no args) so a heredoc passthrough
                            -- body approves; the reconstructed body uses `ls`.
                            allow = {
                                "Bash(ls *)",
                                "Bash(grep *)",
                                "Bash(cat)",
                            },
                        },
                    }
                end
                return nil
            end
            PermissionRules.invalidate_cache()
        end)
        after_each(function()
            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
            for _, path in ipairs(written) do
                os.remove(path)
            end
            written = {}
        end)

        it(
            "approves a create-then-run whose heredoc body is all-allowed",
            function()
                -- The script never touches disk; only the reconstructed heredoc body
                -- can clear the `zsh` leaf.
                local path = ghost()
                local ok =
                    PermissionRules.evaluate(create_run(path, "ls /tmp\n"))
                assert.is_true(ok)
            end
        )

        it(
            "bails a create-then-run whose heredoc body is not allowed",
            function()
                local path = ghost()
                local ok =
                    PermissionRules.evaluate(create_run(path, "make build\n"))
                assert.is_false(ok)
            end
        )

        it("walks reconstructed bytes, not stale disk content", function()
            -- Disk holds a disallowed body; the heredoc rewrites it to an allowed
            -- one. Approving proves the walk reads the reconstruction, not disk.
            local path = script("make build\n")
            local ok = PermissionRules.evaluate(create_run(path, "ls /tmp\n"))
            assert.is_true(ok)
            -- And the inverse: an allowed disk body cannot rescue a disallowed
            -- reconstruction.
            local path2 = script("ls /tmp\n")
            local ok2 =
                PermissionRules.evaluate(create_run(path2, "make build\n"))
            assert.is_false(ok2)
        end)

        it(
            "taint: a non-`cat` producer (grep) is not reconstructable",
            function()
                local path = ghost()
                local ok = PermissionRules.evaluate(
                    ("grep x > %s <<'EOF'\nls /tmp\nEOF\nzsh %s"):format(
                        path,
                        path
                    )
                )
                assert.is_false(ok)
            end
        )

        it("taint: a `>>` append is not reconstructable", function()
            local path = ghost()
            local ok =
                PermissionRules.evaluate(create_run(path, "ls /tmp\n", ">>"))
            assert.is_false(ok)
        end)

        it(
            "bails an expanding heredoc (substitution runs at write time)",
            function()
                -- An unquoted `<<EOF` with `$(…)` runs the substitution when the file
                -- is written, so the redirect itself must bail.
                local path = ghost()
                local ok = PermissionRules.evaluate(
                    ("cat > %s <<EOF\n$(make build)\nEOF\nzsh %s"):format(
                        path,
                        path
                    )
                )
                assert.is_false(ok)
            end
        )

        it(
            "taint: a second write to the same path drops the reconstruction",
            function()
                -- The heredoc records reconstructable bytes; a later redirect to the
                -- same path (before the `zsh`) overwrites them → the path taints and
                -- the `zsh` leaf bails rather than walking the now-stale bytes.
                local path = ghost()
                local ok = PermissionRules.evaluate(
                    ("cat > %s <<'EOF'\nls /tmp\nEOF\nls /tmp > %s\nzsh %s"):format(
                        path,
                        path,
                        path
                    )
                )
                assert.is_false(ok)
            end
        )

        it("approves a pure-text heredoc as stdin with no write", function()
            -- No redirect to a file, so no write effect — fully auto-approvable.
            local ok =
                PermissionRules.should_auto_approve("cat <<'EOF'\nls /tmp\nEOF")
            assert.is_true(ok)
        end)
    end)

    describe("arithmetic argument gate", function()
        local Config = require("agentic.config")
        local orig_shell
        local orig_code_shell
        local orig_provider

        --- Pin the exec-shell gate for the duration of a test.
        --- @param shell string
        --- @param provider string
        local function gate(shell, provider)
            vim.env.SHELL = shell
            Config.provider = provider
        end

        before_each(function()
            orig_shell = vim.env.SHELL
            orig_code_shell = vim.env.CLAUDE_CODE_SHELL
            orig_provider = Config.provider
            vim.env.CLAUDE_CODE_SHELL = nil
            PermissionRules.invalidate_cache()
        end)

        after_each(function()
            vim.env.SHELL = orig_shell
            vim.env.CLAUDE_CODE_SHELL = orig_code_shell
            Config.provider = orig_provider
            PermissionRules.invalidate_cache()
        end)

        local SED = 'sed -n "$((l - 18)),$((l))p" f'

        it("approves an arithmetic sed range under the zsh gate", function()
            gate("/bin/zsh", "claude-agent-acp")
            assert.is_true(PermissionRules.should_auto_approve(SED))
        end)

        it("prompts under a bash exec shell (gate off)", function()
            gate("/bin/bash", "claude-agent-acp")
            assert.is_false(PermissionRules.should_auto_approve(SED))
        end)

        it("prompts under a non-capable provider (gate off)", function()
            gate("/bin/zsh", "opencode-acp")
            assert.is_false(PermissionRules.should_auto_approve(SED))
        end)

        it("keeps a redirect target dynamic even under the gate", function()
            gate("/bin/zsh", "claude-agent-acp")
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return { permissions = { allow = { "Bash(echo *)" } } }
                end
                return nil
            end
            PermissionRules.invalidate_cache()
            -- `> $((n))` resolves to no literal path — the redirect write bails.
            assert.is_false(
                PermissionRules.should_auto_approve("echo hi > $((n))")
            )
            PermissionRules.read_json = orig_read_json
        end)

        it("does not spuriously deny-reject a benign arithmetic arg", function()
            gate("/bin/zsh", "claude-agent-acp")
            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function(path)
                if path:find("settings%.json$") then
                    return { permissions = { deny = { "Bash(rm *)" } } }
                end
                return nil
            end
            PermissionRules.invalidate_cache()
            assert.is_false(PermissionRules.should_auto_reject(SED))
            PermissionRules.read_json = orig_read_json
        end)

        it("does not auto-approve a functions -M registration", function()
            gate("/bin/zsh", "claude-agent-acp")
            assert.is_false(
                PermissionRules.should_auto_approve("functions -M foo 1 1")
            )
        end)

        it("still prompts a $var-bearing string under the gate", function()
            gate("/bin/zsh", "claude-agent-acp")
            assert.is_false(
                PermissionRules.should_auto_approve('sed -n "$v p" f')
            )
        end)

        -- The gate is the OUTER exec shell. A `bash -c`/`sh -c` wrapper switches
        -- the inner evaluating shell to a non-zsh one, where arithmetic
        -- re-evaluates a variable's value (RCE laundering) — the gate MUST clear
        -- for that inner body or a single-quoted assignment launders past sed.
        it("clears the gate inside a bash -c body", function()
            gate("/bin/zsh", "claude-agent-acp")
            assert.is_false(
                PermissionRules.should_auto_approve(
                    [[bash -c 'sed -n "$((l))p" f']]
                )
            )
        end)

        it("clears the gate inside an sh -c body", function()
            gate("/bin/zsh", "claude-agent-acp")
            assert.is_false(
                PermissionRules.should_auto_approve(
                    [[sh -c 'sed -n "$((l))p" f']]
                )
            )
        end)

        it("preserves the gate inside a zsh -c body", function()
            gate("/bin/zsh", "claude-agent-acp")
            assert.is_true(
                PermissionRules.should_auto_approve(
                    [[zsh -c 'sed -n "$((l))p" f']]
                )
            )
        end)

        it("preserves the gate through a benign exec-wrapper", function()
            gate("/bin/zsh", "claude-agent-acp")
            assert.is_true(
                PermissionRules.should_auto_approve(
                    'env FOO=1 sed -n "$((l))p" f'
                )
            )
        end)

        -- A command substitution *inside* arithmetic is opaque; the whitelist
        -- must never treat it as static (belt to the subtree_has_substitution
        -- bail that catches it first).
        it("does not approve command-sub inside arithmetic", function()
            gate("/bin/zsh", "claude-agent-acp")
            assert.is_false(
                PermissionRules.should_auto_approve('sed -n "$(( $(id) ))p" f')
            )
        end)
    end)
end)
