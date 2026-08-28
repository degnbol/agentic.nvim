local assert = require("tests.helpers.assert")

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
    local verdict_to_return

    before_each(function()
        last_call = nil
        verdict_to_return = "allow"
        SessionRegistry.session_for_acp_id = function(_)
            return {
                permission_manager = {
                    decide = function(_, kind, tool_call, diff)
                        last_call =
                            { kind = kind, tool_call = tool_call, diff = diff }
                        return verdict_to_return
                    end,
                },
                note_hook_transcript = function() end,
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

    describe("transcript path", function()
        it("hands the reported path to the session", function()
            local noted
            SessionRegistry.session_for_acp_id = function(_)
                return {
                    permission_manager = {
                        decide = function() end,
                    },
                    note_hook_transcript = function(_self, path)
                        noted = path
                    end,
                }
            end

            PermissionHook.evaluate(encode({
                session_id = "s1",
                transcript_path = "/projects/slug/s1.jsonl",
                tool_name = "Bash",
                tool_input = { command = "ls" },
            }))

            assert.equal("/projects/slug/s1.jsonl", noted)
        end)

        it("still decides for a tool the reader never hears about", function()
            -- Verdicts must not depend on a transcript path being present.
            assert.equal(
                "allow",
                PermissionHook.evaluate(encode({
                    session_id = "s1",
                    tool_name = "Bash",
                    tool_input = { command = "ls" },
                }))
            )
        end)
    end)

    describe("verdict passthrough", function()
        it("returns the ladder verdict verbatim", function()
            verdict_to_return = "deny"
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
end)
