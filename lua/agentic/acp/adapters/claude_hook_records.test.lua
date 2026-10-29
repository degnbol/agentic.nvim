local assert = require("tests.helpers.assert")

describe("ClaudeHookRecords", function()
    --- @type table
    local ClaudeHookRecords

    before_each(function()
        package.loaded["agentic.acp.adapters.claude_hook_records"] = nil
        ClaudeHookRecords = require("agentic.acp.adapters.claude_hook_records")
    end)

    --- One transcript line wrapping a hook attachment.
    --- @param attachment table
    --- @param envelope table|nil
    --- @return string
    local function line(attachment, envelope)
        local entry = vim.tbl_extend("force", {
            type = "attachment",
            uuid = "u-1",
            parentUuid = "u-0",
            timestamp = "2026-08-28T10:00:00.000Z",
            sessionId = "s-1",
        }, envelope or {})
        entry.attachment = attachment
        return vim.json.encode(entry)
    end

    --- The record a line decodes to, asserting it is the only one.
    --- @param raw string
    --- @return agentic.acp.HookRecord
    local function decode_one(raw)
        local records = ClaudeHookRecords.decode(raw)
        assert.equal(1, #records)
        return records[1]
    end

    --- One transcript line summarising a turn's Stop hooks.
    --- @param hook_errors table
    --- @return string
    local function stop_summary(hook_errors)
        return vim.json.encode({
            type = "system",
            subtype = "stop_hook_summary",
            uuid = "u-1",
            parentUuid = "u-0",
            timestamp = "2026-08-28T10:00:00.000Z",
            toolUseID = "3f2a9c1e-0000-0000-0000-000000000000",
            hookErrors = hook_errors,
        })
    end

    --- @param hook_specific_output table|nil
    --- @param overrides table|nil
    --- @return table
    local function success(hook_specific_output, overrides)
        return vim.tbl_extend("force", {
            type = "hook_success",
            hookName = "PreToolUse:Bash",
            hookEvent = "PreToolUse",
            toolUseID = "toolu_1",
            command = "/hooks/shell-guard.sh",
            content = "",
            stdout = hook_specific_output
                    and vim.json.encode({
                        hookSpecificOutput = hook_specific_output,
                    })
                or "",
            stderr = "",
            exitCode = 0,
            durationMs = 12,
        }, overrides or {})
    end

    describe("injected context", function()
        it("renders the single content element as body lines", function()
            local record = decode_one(line({
                type = "hook_additional_context",
                content = { "first line\nsecond line" },
                hookName = "UserPromptSubmit",
                hookEvent = "UserPromptSubmit",
                toolUseID = "hook-abc",
            }))

            assert.is_not_nil(record)
            assert.equal("context", record.group)
            assert.same({ "first line", "second line" }, record.body)
            assert.equal("u-1", record.uuid)
            assert.equal("u-0", record.parent_uuid)
            assert.equal("2026-08-28T10:00:00.000Z", record.timestamp)
            assert.equal("hook-abc", record.tool_call_id)
        end)

        it("carries toolUseID as the tool call the hook fired on", function()
            local record = decode_one(line({
                type = "hook_additional_context",
                content = { "injected" },
                hookName = "PreToolUse:Write",
                hookEvent = "PreToolUse",
                toolUseID = "toolu_01W2Ve",
            }))

            assert.equal("toolu_01W2Ve", record.tool_call_id)
        end)

        it("leaves the tool call unset when the event names none", function()
            local record = decode_one(line({
                type = "hook_additional_context",
                content = { "injected" },
                hookName = "UserPromptSubmit",
                hookEvent = "UserPromptSubmit",
            }))

            assert.is_nil(record.tool_call_id)
        end)

        it("leaves JSON-looking content as text", function()
            local record = decode_one(line({
                type = "hook_additional_context",
                content = { '{"not":"parsed"}' },
                hookEvent = "PreToolUse",
            }))

            assert.same({ '{"not":"parsed"}' }, record.body)
        end)
    end)

    describe("completed hooks", function()
        it("is silent for a permission decision", function()
            local record = decode_one(
                line(success({ permissionDecision = "allow" }))
            )

            assert.equal("silent", record.group)
        end)

        it("is silent for additional context, which repeats", function()
            local record = decode_one(
                line(success({ additionalContext = "already its own record" }))
            )

            assert.equal("silent", record.group)
        end)

        it("is silent for a rewritten input", function()
            local record = decode_one(
                line(success({ updatedInput = { command = "rg foo" } }))
            )

            assert.equal("silent", record.group)
        end)

        it("surfaces output whose stdout is not JSON", function()
            local record = decode_one(
                line(success(nil, { stdout = "oops", content = "leaked" }))
            )

            assert.equal("unrecognised", record.group)
            assert.same({ "leaked" }, record.body)
        end)

        it("surfaces output with no hookSpecificOutput", function()
            local record = decode_one(
                line(success(nil, { stdout = '{"continue":true}' }))
            )

            assert.equal("unrecognised", record.group)
        end)

        it("surfaces output in an unknown schema", function()
            local record = decode_one(line(success({ futureKey = 1 })))

            assert.equal("unrecognised", record.group)
        end)

        it("surfaces an empty-stdout hook with no body", function()
            local record = decode_one(line(success(nil)))

            assert.equal("unrecognised", record.group)
            assert.same({}, record.body)
        end)

        it("carries the command for attribution", function()
            local record = decode_one(line(success(nil)))

            assert.equal("/hooks/shell-guard.sh", record.command)
        end)
    end)

    describe("failures", function()
        it("is silent for a non-zero exit that wrote no stderr", function()
            local record = decode_one(line({
                type = "hook_non_blocking_error",
                hookEvent = "PreToolUse",
                command = "/hooks/path-skill-guard.sh",
                stdout = "",
                stderr = "Failed with non-blocking status code: No stderr output",
                exitCode = 1,
                durationMs = 8,
            }))

            assert.equal("silent", record.group)
        end)

        it("surfaces a non-zero exit that wrote real stderr", function()
            local record = decode_one(line({
                type = "hook_non_blocking_error",
                hookEvent = "PreToolUse",
                command = "/hooks/path-skill-guard.sh",
                stdout = "",
                stderr = "jq: parse error\nat line 3",
                exitCode = 1,
                durationMs = 8,
            }))

            assert.equal("failure", record.group)
            assert.same({ "jq: parse error", "at line 3" }, record.body)
        end)

        it("gives a timeout a body of its own, having no output", function()
            local record = decode_one(line({
                type = "hook_cancelled",
                hookEvent = "PreToolUse",
                command = "/hooks/permission_hook.sh",
                timedOut = true,
                timeoutMs = 600000,
                durationMs = 600001,
            }))

            assert.equal("failure", record.group)
            assert.equal(1, #record.body)
            assert.is_not_nil(record.body[1]:match("600 s"))
        end)
    end)

    describe("stop hook feedback", function()
        it("gives each blocking hook a context record of its own", function()
            local records = ClaudeHookRecords.decode(stop_summary({
                "[~/hooks/review.sh]: Two files changed\nsince the review",
                "[~/hooks/lint.sh]: lint failed",
            }))

            assert.equal(2, #records)
            assert.equal("context", records[1].group)
            assert.equal("~/hooks/review.sh", records[1].command)
            assert.same(
                { "Two files changed", "since the review" },
                records[1].body
            )
            assert.equal("~/hooks/lint.sh", records[2].command)
            assert.same({ "lint failed" }, records[2].body)
            assert.equal("2026-08-28T10:00:00.000Z", records[1].timestamp)
            assert.is_nil(records[1].uuid)
            assert.is_nil(records[1].tool_call_id)
        end)

        it("ends the body at the trailing newline", function()
            local records = ClaudeHookRecords.decode(
                stop_summary({ "[~/hooks/review.sh]: one line\n" })
            )

            assert.same({ "one line" }, records[1].body)
        end)

        it("gives none when no hook blocked", function()
            assert.same({}, ClaudeHookRecords.decode(stop_summary({})))
        end)

        it("drops a non-blocking error, which has no command", function()
            assert.same(
                {},
                ClaudeHookRecords.decode(stop_summary({
                    "Failed with non-blocking status code: No stderr output",
                }))
            )
        end)

        it("drops an entry that is not a string", function()
            assert.same(
                {},
                ClaudeHookRecords.decode(stop_summary({ { command = "x" } }))
            )
        end)
    end)

    describe("lines that carry no hook activity", function()
        it("ignores a blank line", function()
            assert.same({}, ClaudeHookRecords.decode(""))
            assert.same({}, ClaudeHookRecords.decode("   "))
        end)

        it("ignores a conversation entry", function()
            assert.same(
                {},
                ClaudeHookRecords.decode(
                    vim.json.encode({ type = "assistant", uuid = "u-9" })
                )
            )
        end)

        it("ignores an attachment that is not a hook record", function()
            assert.same(
                {},
                ClaudeHookRecords.decode(line({ type = "file", content = "…" }))
            )
        end)

        it("ignores an unknown hook attachment type", function()
            assert.same(
                {},
                ClaudeHookRecords.decode(
                    line({ type = "hook_future", hookEvent = "PreToolUse" })
                )
            )
        end)

        it("surfaces an unparseable line verbatim", function()
            local record = decode_one("{ truncated")

            assert.equal("verbatim", record.group)
            assert.same({ "{ truncated" }, record.body)
        end)
    end)
end)
