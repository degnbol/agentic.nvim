local assert = require("tests.helpers.assert")
local PermissionRules = require("agentic.utils.permission_rules")

describe("PermissionRules", function()
    describe("glob_to_lua_pattern", function()
        it("converts simple glob with trailing *", function()
            local pat = PermissionRules.glob_to_lua_pattern("grep *")
            assert.equal("^grep [^|;&]*$", pat)
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
            assert.equal("^cd [^|;&]* && git [^|;&]*log[^|;&]*$", pat)
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

    describe("strip_devnull_redirects", function()
        it("strips >/dev/null", function()
            assert.equal(
                "cmd arg",
                PermissionRules.strip_devnull_redirects("cmd arg >/dev/null")
            )
        end)

        it("strips 2>/dev/null", function()
            assert.equal(
                "cmd arg",
                PermissionRules.strip_devnull_redirects("cmd arg 2>/dev/null")
            )
        end)

        it("strips &>/dev/null", function()
            assert.equal(
                "cmd arg",
                PermissionRules.strip_devnull_redirects("cmd arg &>/dev/null")
            )
        end)

        it("strips 2>&1", function()
            assert.equal(
                "cmd arg",
                PermissionRules.strip_devnull_redirects("cmd arg 2>&1")
            )
        end)

        it("strips multiple redirects", function()
            assert.equal(
                "cmd arg",
                PermissionRules.strip_devnull_redirects(
                    "cmd arg 2>/dev/null >/dev/null"
                )
            )
        end)

        it("does not strip non-devnull redirects", function()
            assert.equal(
                "cmd arg >/tmp/out",
                PermissionRules.strip_devnull_redirects("cmd arg >/tmp/out")
            )
        end)

        it("strips >&N fd duplication", function()
            assert.equal(
                "echo hi",
                PermissionRules.strip_devnull_redirects("echo hi >&2")
            )
        end)

        it("strips N>&M fd duplication", function()
            assert.equal(
                "cmd",
                PermissionRules.strip_devnull_redirects("cmd 2>&1")
            )
        end)

        it("does not strip >&filename (non-digit target)", function()
            assert.equal(
                "cmd >&output",
                PermissionRules.strip_devnull_redirects("cmd >&output")
            )
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
    end)

    describe("split_command", function()
        it("splits on pipe", function()
            local segs = PermissionRules.split_command("grep foo | head -5")
            assert.is_not_nil(segs)
            assert.equal(2, #segs)
            assert.equal("grep foo ", segs[1])
            assert.equal(" head -5", segs[2])
        end)

        it("splits on &&", function()
            local segs = PermissionRules.split_command("cd /tmp && ls -la")
            assert.is_not_nil(segs)
            assert.equal(2, #segs)
        end)

        it("splits on ||", function()
            local segs = PermissionRules.split_command("cmd1 || cmd2")
            assert.is_not_nil(segs)
            assert.equal(2, #segs)
        end)

        it("splits on semicolon", function()
            local segs = PermissionRules.split_command("cmd1; cmd2")
            assert.is_not_nil(segs)
            assert.equal(2, #segs)
        end)

        it("handles multi-line pipe commands", function()
            local segs =
                PermissionRules.split_command("grep -r 'foo' .\n|\n  head -40")
            assert.is_not_nil(segs)
            assert.equal(2, #segs)
        end)

        it("returns nil for subshell $(...)", function()
            local segs = PermissionRules.split_command("echo $(whoami)")
            assert.is_nil(segs)
        end)

        it("returns nil for backticks", function()
            local segs = PermissionRules.split_command("echo `whoami`")
            assert.is_nil(segs)
        end)

        it("returns nil for process substitution <()", function()
            local segs = PermissionRules.split_command("diff <(cmd1) <(cmd2)")
            assert.is_nil(segs)
        end)

        it("returns nil for unbalanced single quotes", function()
            local segs = PermissionRules.split_command("echo 'unbalanced")
            assert.is_nil(segs)
        end)

        it("returns nil for unbalanced double quotes", function()
            local segs = PermissionRules.split_command('echo "unbalanced')
            assert.is_nil(segs)
        end)

        it("preserves operators inside single quotes", function()
            local segs = PermissionRules.split_command("grep 'a|b' file | head")
            assert.is_not_nil(segs)
            assert.equal(2, #segs)
            assert.equal("grep 'a|b' file ", segs[1])
        end)

        it("preserves operators inside double quotes", function()
            local segs = PermissionRules.split_command('grep "a&&b" file && ls')
            assert.is_not_nil(segs)
            assert.equal(2, #segs)
        end)

        it("handles single command with no operators", function()
            local segs = PermissionRules.split_command("ls -la /tmp")
            assert.is_not_nil(segs)
            assert.equal(1, #segs)
            assert.equal("ls -la /tmp", segs[1])
        end)
    end)

    describe("mask_quoted_operators", function()
        it("masks | inside double quotes", function()
            assert.equal(
                'grep "axb" file',
                PermissionRules.mask_quoted_operators('grep "a|b" file')
            )
        end)

        it("masks | inside single quotes", function()
            assert.equal(
                "grep 'axb' file",
                PermissionRules.mask_quoted_operators("grep 'a|b' file")
            )
        end)

        it("masks ; and & inside quotes", function()
            assert.equal(
                'echo "axbxc"',
                PermissionRules.mask_quoted_operators('echo "a;b&c"')
            )
        end)

        it("leaves unquoted operators alone", function()
            assert.equal(
                "grep foo | head",
                PermissionRules.mask_quoted_operators("grep foo | head")
            )
        end)

        it("handles mixed quoted and unquoted regions", function()
            assert.equal(
                'grep "axb" | head',
                PermissionRules.mask_quoted_operators('grep "a|b" | head')
            )
        end)

        it("treats single quotes as literal inside double quotes", function()
            assert.equal(
                [["a 'bxc' d"]],
                PermissionRules.mask_quoted_operators([["a 'b|c' d"]])
            )
        end)

        it("treats double quotes as literal inside single quotes", function()
            assert.equal(
                [['a "bxc" d']],
                PermissionRules.mask_quoted_operators([['a "b|c" d']])
            )
        end)

        it("handles adjacent quoted regions of different types", function()
            assert.equal(
                [["axb"'cxd']],
                PermissionRules.mask_quoted_operators([["a|b"'c|d']])
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

        it("matches after stripping /dev/null redirect", function()
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
            -- Disable Config.read_only_commands so settings.json is the
            -- only source — the test verifies the empty-settings path.
            local Config = require("agentic.config")
            local orig_flag = Config.auto_approve_read_only_commands
            Config.auto_approve_read_only_commands = false

            local orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function()
                return nil
            end
            PermissionRules.invalidate_cache()

            local result = PermissionRules.should_auto_approve("ls -la")
            assert.is_false(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
            Config.auto_approve_read_only_commands = orig_flag
        end)

        it("handles newlines in compound commands", function()
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
                "grep -r 'pattern' src\n|\n  head -40"
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
                "stdbuf -oL ls /Users/cmadsen/dotfiles/shell/"
            )
            assert.is_true(result)

            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it(
            "falls through when same-type escaped quote unbalances segment",
            function()
                -- Splitter doesn't model backslash-escapes, so `"a\"b|c"` looks
                -- unbalanced — split_command returns nil and we don't auto-approve.
                -- The `\` here must be a literal backslash char, not a lua escape.
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
                assert.is_false(result)

                PermissionRules.read_json = orig_read_json
                PermissionRules.invalidate_cache()
            end
        )

        it(
            "falls through on bash quote-reopening idiom with outer pipe",
            function()
                -- Bash 'can'\''t|x' would concatenate as can't|x (pipe quoted).
                -- Our state machine (and the splitter) see the `|` as unquoted;
                -- splitter fragments the command, no segment matches, fall through.
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
                assert.is_false(result)

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

    describe("has_unsafe_redirect", function()
        it("detects > file", function()
            assert.is_true(PermissionRules.has_unsafe_redirect("cat foo > bar"))
        end)

        it("detects >> file (append)", function()
            assert.is_true(
                PermissionRules.has_unsafe_redirect("echo x >> /tmp/log")
            )
        end)

        it("detects 2> file", function()
            assert.is_true(
                PermissionRules.has_unsafe_redirect("cat foo 2>/tmp/err")
            )
        end)

        it("detects &> file", function()
            assert.is_true(
                PermissionRules.has_unsafe_redirect("cat foo &>/tmp/all")
            )
        end)

        it("allows >&N (fd duplication)", function()
            assert.is_false(
                PermissionRules.has_unsafe_redirect("echo error >&2")
            )
        end)

        it("allows 2>&1", function()
            assert.is_false(
                PermissionRules.has_unsafe_redirect("cmd 2>&1")
            )
        end)

        it("ignores > inside single quotes", function()
            assert.is_false(
                PermissionRules.has_unsafe_redirect("grep 'a > b' file")
            )
        end)

        it("ignores > inside double quotes", function()
            assert.is_false(
                PermissionRules.has_unsafe_redirect([[grep "a > b" file]])
            )
        end)

        it("returns false for plain command", function()
            assert.is_false(PermissionRules.has_unsafe_redirect("ls -la /tmp"))
        end)
    end)

    describe("should_auto_approve with redirect", function()
        local Config
        local orig_flag
        local orig_read_json

        before_each(function()
            Config = require("agentic.config")
            orig_flag = Config.auto_approve_read_only_commands
            Config.auto_approve_read_only_commands = true

            orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function()
                return nil
            end
            PermissionRules.invalidate_cache()
        end)

        after_each(function()
            Config.auto_approve_read_only_commands = orig_flag
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

    describe("config read_only_commands", function()
        --- @type agentic.UserConfig
        local Config
        local orig_flag
        local orig_allow
        local orig_deny
        local orig_read_json

        before_each(function()
            Config = require("agentic.config")
            orig_flag = Config.auto_approve_read_only_commands
            orig_allow = Config.read_only_commands
            orig_deny = Config.read_only_commands_deny

            -- Stub settings.json to empty so only Config patterns apply
            orig_read_json = PermissionRules.read_json
            PermissionRules.read_json = function()
                return nil
            end
            PermissionRules.invalidate_cache()
        end)

        after_each(function()
            Config.auto_approve_read_only_commands = orig_flag
            Config.read_only_commands = orig_allow
            Config.read_only_commands_deny = orig_deny
            PermissionRules.read_json = orig_read_json
            PermissionRules.invalidate_cache()
        end)

        it("approves command from default list when flag enabled", function()
            Config.auto_approve_read_only_commands = true
            assert.is_true(PermissionRules.should_auto_approve("ls -la /tmp"))
        end)

        it("rejects when flag disabled even with default match", function()
            Config.auto_approve_read_only_commands = false
            assert.is_false(PermissionRules.should_auto_approve("ls -la /tmp"))
        end)

        it("approves compound of two default-list commands", function()
            Config.auto_approve_read_only_commands = true
            assert.is_true(
                PermissionRules.should_auto_approve("cat foo.txt | head -5")
            )
        end)

        it("rejects find -exec via default deny list", function()
            Config.auto_approve_read_only_commands = true
            assert.is_false(
                PermissionRules.should_auto_approve(
                    "find . -name '*.lua' -exec rm {} +"
                )
            )
        end)

        it("approves find without -exec", function()
            Config.auto_approve_read_only_commands = true
            assert.is_true(
                PermissionRules.should_auto_approve("find . -name '*.lua'")
            )
        end)

        it("rejects command not in default list", function()
            Config.auto_approve_read_only_commands = true
            assert.is_false(
                PermissionRules.should_auto_approve("rm -rf /tmp/foo")
            )
        end)

        it("recompiles when Config.read_only_commands is replaced", function()
            Config.auto_approve_read_only_commands = true
            Config.read_only_commands = { "Bash(custom *)" }
            -- Default `ls` no longer in list
            assert.is_false(PermissionRules.should_auto_approve("ls -la"))
            assert.is_true(
                PermissionRules.should_auto_approve("custom thing")
            )
        end)

        it("merges Config patterns with settings.json patterns", function()
            Config.auto_approve_read_only_commands = true
            Config.read_only_commands = { "Bash(ls *)" }
            Config.read_only_commands_deny = {}

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
end)
