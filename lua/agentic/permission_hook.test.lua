local assert = require("tests.helpers.assert")
local Deferred = require("tests.helpers.deferred")

local PermissionHook = require("agentic.permission_hook")
local SessionRegistry = require("agentic.session_registry")

--- Encode a hook payload the way the shell script does before RPC.
--- @param payload table
--- @return string
local function encode(payload)
    return vim.base64.encode(vim.json.encode(payload))
end

describe("agentic.permission_hook", function()
    --- Args captured from the stubbed `decide`.
    local last_call
    --- `allow` of the verdict the stubbed `decide` returns.
    --- @type boolean|nil
    local verdict_to_return
    --- `causes` of the verdict the stubbed `decide` returns.
    --- @type agentic.PermissionCause[]
    local causes_to_return

    before_each(function()
        last_call = nil
        verdict_to_return = true
        causes_to_return = {}
        SessionRegistry.session_for_acp_id = function(_)
            return {
                permission_manager = {
                    decide = function(_, kind, tool_call, diff)
                        last_call =
                            { kind = kind, tool_call = tool_call, diff = diff }
                        return {
                            allow = verdict_to_return,
                            causes = causes_to_return,
                        }
                    end,
                    record_causes = function() end,
                },
            }
        end
    end)

    describe("fail-open", function()
        it("returns empty for an unmatched tool name", function()
            assert.equal(
                "",
                PermissionHook.evaluate(encode({
                    session_id = "s1",
                    tool_name = "Read",
                    tool_input = {},
                }))
            )
            assert.is_nil(last_call)
        end)

        it("returns empty when no session matches", function()
            SessionRegistry.session_for_acp_id = function(_)
                return nil
            end
            assert.equal(
                "",
                PermissionHook.evaluate(encode({
                    session_id = "gone",
                    tool_name = "Bash",
                    tool_input = { command = "ls" },
                }))
            )
        end)

        it("returns empty on undecodable input", function()
            assert.equal("", PermissionHook.evaluate("not base64 !!!"))
        end)
    end)

    describe("verdict passthrough", function()
        it("maps a rejecting verdict to deny", function()
            verdict_to_return = false
            assert.equal(
                "deny",
                PermissionHook.evaluate(encode({
                    session_id = "s1",
                    tool_name = "Bash",
                    tool_input = { command = "rm -rf /" },
                }))
            )
        end)

        it("maps a nil verdict to empty", function()
            verdict_to_return = nil
            assert.equal(
                "",
                PermissionHook.evaluate(encode({
                    session_id = "s1",
                    tool_name = "Bash",
                    tool_input = { command = "ls" },
                }))
            )
        end)

        --- @param permission_mode string|nil
        --- @return string verdict
        local function evaluate_ask(permission_mode)
            verdict_to_return = nil
            causes_to_return = {
                { code = "no-allow", subject = "make x" },
                { code = "ask", subject = "git commit -m x" },
            }
            return PermissionHook.evaluate(encode({
                session_id = "s1",
                tool_name = "Bash",
                tool_input = { command = "git commit -m x" },
                permission_mode = permission_mode,
            }))
        end

        it("maps an ask cause to ask in auto mode", function()
            assert.equal("ask", evaluate_ask("auto"))
        end)

        it("maps an undecided verdict with no ask cause to empty", function()
            verdict_to_return = nil
            causes_to_return = { { code = "dynamic", subject = "git $x" } }
            assert.equal(
                "",
                PermissionHook.evaluate(encode({
                    session_id = "s1",
                    tool_name = "Bash",
                    tool_input = { command = "git $x" },
                    permission_mode = "auto",
                }))
            )
        end)

        it("maps an ask cause to empty in another mode", function()
            assert.equal("", evaluate_ask("default"))
            assert.equal("", evaluate_ask("bypassPermissions"))
            assert.equal("", evaluate_ask(nil))
        end)
    end)

    describe("kind + diff reconstruction", function()
        it("threads a Bash command as execute with no diff", function()
            PermissionHook.evaluate(encode({
                session_id = "s1",
                tool_name = "Bash",
                tool_input = { command = "grep foo bar" },
            }))
            assert.equal("execute", last_call.kind)
            assert.equal("grep foo bar", last_call.tool_call.rawInput.command)
            assert.is_nil(last_call.diff)
        end)

        it("reconstructs an Edit diff from old/new strings", function()
            PermissionHook.evaluate(encode({
                session_id = "s1",
                tool_name = "Edit",
                tool_input = {
                    file_path = "/tmp/f.lua",
                    old_string = "old a\nold b",
                    new_string = "new a",
                    replace_all = true,
                },
            }))
            assert.equal("edit", last_call.kind)
            assert.same({ "old a", "old b" }, last_call.diff.old)
            assert.same({ "new a" }, last_call.diff.new)
            assert.is_true(last_call.diff.all)
        end)

        it("reconstructs a Write diff from content with empty old", function()
            PermissionHook.evaluate(encode({
                session_id = "s1",
                tool_name = "Write",
                tool_input = {
                    file_path = "/tmp/new.lua",
                    content = "line 1\nline 2",
                },
            }))
            assert.equal("edit", last_call.kind)
            assert.same({}, last_call.diff.old)
            assert.same({ "line 1", "line 2" }, last_call.diff.new)
            assert.is_false(last_call.diff.all)
        end)
    end)

    describe("causes", function()
        local PermissionManager = require("agentic.ui.permission_manager")
        local deferred
        local pm
        local decided
        local GLOB_ALLOW = { { code = "glob-allow" } }

        before_each(function()
            deferred = Deferred.capture()
            decided = {}
            pm = setmetatable({
                _causes = {},
                decide = function()
                    return { allow = verdict_to_return, causes = GLOB_ALLOW }
                end,
                on_decided = function(id, causes)
                    table.insert(decided, { id, causes })
                end,
            }, { __index = PermissionManager })
            SessionRegistry.session_for_acp_id = function(_)
                return { permission_manager = pm }
            end
        end)

        after_each(function()
            deferred.revert()
        end)

        --- @param tool_use_id string|nil
        --- @return string verdict
        local function evaluate(tool_use_id)
            return PermissionHook.evaluate(encode({
                session_id = "s1",
                tool_name = "Bash",
                tool_input = { command = "make test" },
                tool_use_id = tool_use_id,
            }))
        end

        it("records a decided call against its tool_use_id", function()
            assert.equal("allow", evaluate("toolu_1"))
            assert.same({}, decided)
            assert.same(GLOB_ALLOW, pm._causes.toolu_1)

            deferred.drain()
            assert.same({ { "toolu_1", GLOB_ALLOW } }, decided)
        end)

        it("records nothing for an undecided call", function()
            verdict_to_return = nil
            assert.equal("", evaluate("toolu_1"))
            deferred.drain()
            assert.same({}, pm._causes)
            assert.same({}, decided)
        end)

        it("records nothing without a tool_use_id", function()
            assert.equal("allow", evaluate(nil))
            deferred.drain()
            assert.same({}, pm._causes)
        end)
    end)

    describe("bash cwd", function()
        local PermissionManager = require("agentic.ui.permission_manager")
        local pm
        local decided_cwd

        before_each(function()
            decided_cwd = nil
            pm = setmetatable({
                _bash_cwds = {},
                decide = function(_, _, _, _, cwd)
                    decided_cwd = cwd
                    return nil
                end,
            }, { __index = PermissionManager })
            SessionRegistry.session_for_acp_id = function(_)
                return { permission_manager = pm }
            end
        end)

        --- @param tool_name string
        local function evaluate(tool_name)
            PermissionHook.evaluate(encode({
                session_id = "s1",
                tool_name = tool_name,
                tool_input = { command = "ls", file_path = "/tmp/f" },
                tool_use_id = "toolu_1",
                cwd = "/work",
            }))
        end

        it("records a Bash call's cwd, whatever the verdict", function()
            evaluate("Bash")
            assert.equal("/work", pm:bash_cwd("toolu_1"))
            assert.equal("/work", decided_cwd)
        end)

        it("records no cwd for another tool", function()
            evaluate("Edit")
            assert.is_nil(pm:bash_cwd("toolu_1"))
        end)
    end)
end)
