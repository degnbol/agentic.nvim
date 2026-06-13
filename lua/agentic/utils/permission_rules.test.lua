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

    describe("strip_wrapper_prefixes", function()
        it("strips stdbuf -oL prefix", function()
            assert.equal(
                "ls -la /tmp",
                PermissionRules.strip_wrapper_prefixes("stdbuf -oL ls -la /tmp")
            )
        end)

        it("strips stdbuf with other flags", function()
            assert.equal(
                "grep foo",
                PermissionRules.strip_wrapper_prefixes("stdbuf -eL grep foo")
            )
        end)

        it("does not strip unknown wrappers", function()
            assert.equal(
                "timeout 5 ls",
                PermissionRules.strip_wrapper_prefixes("timeout 5 ls")
            )
        end)

        it("returns unchanged when no wrapper present", function()
            assert.equal(
                "grep -r 'foo' .",
                PermissionRules.strip_wrapper_prefixes("grep -r 'foo' .")
            )
        end)

        -- Variable-assignment prefixes (env vars, data vars, hijackers) are no
        -- longer handled here — the walker validates and excludes them
        -- structurally. Their behaviour is covered by the should_auto_approve
        -- env-prefix tests below.
        it("leaves a variable-assignment prefix in place", function()
            assert.equal(
                "PYTHONUNBUFFERED=1 git log",
                PermissionRules.strip_wrapper_prefixes(
                    "PYTHONUNBUFFERED=1 git log"
                )
            )
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

        it("rejects subshell commands", function()
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

        it("blocks a write hidden after a newline-joined safe command", function()
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
        end)

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

        it(
            "approves an escaped quote with a pipe inside the string",
            function()
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
            end
        )

        it(
            "approves a quote-reopening idiom with a quoted pipe",
            function()
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

                local result = PermissionRules.should_auto_approve(
                    [[echo 'can'\''t|here']]
                )
                assert.is_true(result)

                PermissionRules.read_json = orig_read_json
                PermissionRules.invalidate_cache()
            end
        )

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

        before_each(function()
            Config = require("agentic.config")
            orig_plugin = Config.permissions.use_plugin_defaults
            orig_claude = Config.permissions.use_claude_settings
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false

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
            assert.is_true(
                PermissionRules.should_auto_approve("echo hi >&2")
            )
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

        it("approves command from plugin defaults when auto_approve=allow", function()
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = "allow"
            PermissionRules.invalidate_cache()
            assert.is_true(PermissionRules.should_auto_approve("ls -la /tmp"))
        end)

        it("approves command from plugin defaults when auto_approve=read-only", function()
            Config.permissions.use_plugin_defaults = true
            Config.permissions.use_claude_settings = false
            Config.permissions.auto_approve = "read-only"
            PermissionRules.invalidate_cache()
            assert.is_true(PermissionRules.should_auto_approve("ls -la /tmp"))
        end)

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

        it("recompiles when Config.permissions.read_only is replaced", function()
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
        end)

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
            assert.is_true(
                PermissionRules.should_auto_approve("make test foo")
            )
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

        describe("bails on substitution anywhere", function()
            for _, cmd in ipairs({
                "$(echo rm) -rf /",
                "$(rm -rf /)",
                "grep $(cat list) f",
                'echo "$(rm -rf x)"',
                "echo a$(whoami)b",
                "ec$(echo ho) hi",
                "cat > $(echo out)",
                "cat <<< $(rm x)",
                "echo `whoami`",
                "foo=$(rm x) ls",
                "f=$(echo hi)",
            }) do
                it("rejects " .. cmd, function()
                    assert.is_false(decide(cmd, ALLOW))
                end)
            end
        end)

        describe("bails on control flow and compound structure", function()
            for _, cmd in ipairs({
                "! rm x",
                "{ rm x; }",
                "[[ -f x ]] && rm y",
                "( rm -rf x )",
                "cat <(ls)",
                "for f in *.txt; do cat \"$f\"; done",
                "while read l; do echo \"$l\"; done",
            }) do
                it("rejects " .. cmd, function()
                    assert.is_false(decide(cmd, ALLOW))
                end)
            end
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
    end)
end)
