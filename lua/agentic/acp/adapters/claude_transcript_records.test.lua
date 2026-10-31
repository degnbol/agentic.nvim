local assert = require("tests.helpers.assert")

describe("ClaudeTranscriptRecords", function()
    --- @type table
    local ClaudeTranscriptRecords

    before_each(function()
        package.loaded["agentic.acp.adapters.claude_transcript_records"] = nil
        ClaudeTranscriptRecords =
            require("agentic.acp.adapters.claude_transcript_records")
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

    --- The records of one transcript line.
    --- @param raw string
    --- @return table[]
    local function decode(raw)
        local entry = ClaudeTranscriptRecords.parse(raw)
        assert.is_not_nil(entry)
        ---@cast entry -nil
        return ClaudeTranscriptRecords.records(entry)
    end

    --- The record a line decodes to, asserting it is the only one.
    --- @param raw string
    --- @return table
    local function decode_one(raw)
        local records = decode(raw)
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
            assert.equal("hook", record.kind)
            assert.equal("context", record.group)
            assert.same({ "first line", "second line" }, record.body)
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
        it("passes on empty content", function()
            local record =
                decode_one(line(success({ permissionDecision = "allow" })))

            assert.equal("passed", record.group)
            assert.same({}, record.body)
        end)

        it("treats content on UserPromptSubmit as context", function()
            local record = decode_one(line(success(nil, {
                hookEvent = "UserPromptSubmit",
                hookName = "UserPromptSubmit",
                stdout = "remember this",
                content = "remember this",
            })))

            assert.equal("context", record.group)
            assert.same({ "remember this" }, record.body)
        end)

        it("treats content on PreToolUse as stray", function()
            local record = decode_one(
                line(success(nil, { stdout = "oops", content = "leaked" }))
            )

            assert.equal("stray", record.group)
            assert.same({ "leaked" }, record.body)
        end)

        it("carries the command and hook name for attribution", function()
            local record = decode_one(line(success(nil)))

            assert.equal("/hooks/shell-guard.sh", record.command)
            assert.equal("PreToolUse:Bash", record.hook_name)
            assert.equal(12, record.duration_ms)
        end)
    end)

    describe("failures", function()
        it("passes on a non-zero exit that wrote no stderr", function()
            local record = decode_one(line({
                type = "hook_non_blocking_error",
                hookEvent = "PreToolUse",
                command = "/hooks/path-skill-guard.sh",
                stdout = "",
                stderr = "Failed with non-blocking status code: No stderr output",
                exitCode = 1,
                durationMs = 8,
            }))

            assert.equal("passed", record.group)
        end)

        it("leads a non-zero exit's stderr with its exit code", function()
            local record = decode_one(line({
                type = "hook_non_blocking_error",
                hookEvent = "PreToolUse",
                command = "/hooks/plan-reminder.sh",
                stdout = "",
                stderr = "Failed with non-blocking status code: "
                    .. "sh: plan-reminder.sh: not found\nsecond line",
                exitCode = 127,
                durationMs = 8,
            }))

            assert.equal("failure", record.group)
            assert.same({
                "exited 127",
                "sh: plan-reminder.sh: not found",
                "second line",
            }, record.body)
        end)

        it("keeps an unprefixed stderr as it is", function()
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

        it("names the seconds a timeout waited", function()
            local record = decode_one(line({
                type = "hook_cancelled",
                hookEvent = "PreToolUse",
                command = "/hooks/permission_hook.sh",
                timedOut = true,
                timeoutMs = 600000,
                durationMs = 600001,
            }))

            assert.equal("failure", record.group)
            assert.same({ "timed out after 600 s" }, record.body)
        end)

        it("is silent for a hook skipped inside a hook's agent", function()
            local record = decode_one(line({
                type = "hook_cancelled",
                hookEvent = "PreToolUse",
                hookName = "PreToolUse:Bash",
            }))

            assert.equal("silent", record.group)
        end)

        it("says a failure wrote no stderr when it has none", function()
            local record = decode_one(line({
                type = "hook_non_blocking_error",
                hookEvent = "PreToolUse",
                stderr = "",
                exitCode = 1,
            }))

            assert.equal("failure", record.group)
            assert.same({ "failed with no stderr" }, record.body)
        end)

        it("omits the exit line when no exit code is recorded", function()
            local record = decode_one(line({
                type = "hook_non_blocking_error",
                hookEvent = "PreToolUse",
                stderr = "Failed with non-blocking status code: boom",
            }))

            assert.same({ "boom" }, record.body)
        end)

        it("is silent for a hook stopped by the turn's cancellation", function()
            local record = decode_one(line({
                type = "hook_cancelled",
                hookEvent = "PreToolUse",
                command = "/hooks/permission_hook.sh",
                timedOut = false,
                durationMs = 1200,
            }))

            assert.equal("silent", record.group)
        end)
    end)

    describe("stop hook feedback", function()
        it("gives each blocking hook a context record of its own", function()
            local records = decode(stop_summary({
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
            assert.is_nil(records[1].tool_call_id)
        end)

        it("ends the body at the trailing newline", function()
            local records =
                decode(stop_summary({ "[~/hooks/review.sh]: one line\n" }))

            assert.same({ "one line" }, records[1].body)
        end)

        it("gives none when no hook blocked", function()
            assert.same({}, decode(stop_summary({})))
        end)

        it("drops a non-blocking error, which has no command", function()
            assert.same(
                {},
                decode(stop_summary({
                    "Failed with non-blocking status code: No stderr output",
                }))
            )
        end)

        it("drops an entry that is not a string", function()
            assert.same({}, decode(stop_summary({ { command = "x" } })))
        end)
    end)

    describe("loaded files", function()
        it("gives a rule record for a nested_memory attachment", function()
            local record = decode_one(line({
                type = "nested_memory",
                path = "/repo/.claude/rules/tests.md",
                content = { type = "Project", content = "…" },
            }))

            assert.same({
                kind = "loaded_file",
                path = "/repo/.claude/rules/tests.md",
                is_mention = false,
                timestamp = "2026-08-28T10:00:00.000Z",
            }, record)
        end)

        it("gives a mention record for a file attachment", function()
            local record = decode_one(line({
                type = "file",
                filename = "/repo/notes/plan.md",
                content = { type = "text" },
            }))

            assert.equal("loaded_file", record.kind)
            assert.equal("/repo/notes/plan.md", record.path)
            assert.is_true(record.is_mention)
        end)

        it("gives none for a file attachment without a path", function()
            assert.same({}, decode(line({ type = "file", content = "…" })))
        end)
    end)

    describe("lines that carry nothing", function()
        it("ignores a conversation entry", function()
            assert.same(
                {},
                decode(vim.json.encode({ type = "assistant", uuid = "u-9" }))
            )
        end)

        it("ignores another attachment type", function()
            assert.same({}, decode(line({ type = "skill_listing" })))
        end)

        it("ignores an unknown hook attachment type", function()
            assert.same(
                {},
                decode(line({ type = "hook_future", hookEvent = "PreToolUse" }))
            )
        end)
    end)

    describe("parse", function()
        it("gives nil for a line that is not JSON", function()
            assert.is_nil(ClaudeTranscriptRecords.parse("{ truncated"))
        end)

        it("gives nil for JSON that is not an object", function()
            assert.is_nil(ClaudeTranscriptRecords.parse("42"))
        end)
    end)

    it("surfaces an unparseable line verbatim", function()
        assert.same(
            { kind = "hook", group = "verbatim", body = { "{ truncated" } },
            ClaudeTranscriptRecords.verbatim("{ truncated")
        )
    end)

    describe("link", function()
        --- @param entry table
        --- @return agentic.acp.TranscriptLink
        local function link_of(entry)
            local link = ClaudeTranscriptRecords.link(
                vim.tbl_extend(
                    "force",
                    { uuid = "u-1", parentUuid = "u-0" },
                    entry
                )
            )
            assert.is_not_nil(link)
            ---@cast link -nil
            return link
        end

        it("gives nil for an entry without a uuid", function()
            assert.is_nil(ClaudeTranscriptRecords.link({ type = "user" }))
        end)

        it("ends the chain at a tool result, naming its call", function()
            local link = link_of({
                type = "user",
                message = {
                    content = {
                        { type = "tool_result", tool_use_id = "toolu_1" },
                    },
                },
            })

            assert.same({
                uuid = "u-1",
                parent_uuid = "u-0",
                ends_chain = true,
                tool_call_id = "toolu_1",
                after_prompt = false,
                after_compaction = false,
                user_text = false,
                injected = false,
            }, link)
        end)

        it("ends the chain at a Skill body, naming its call", function()
            local link = link_of({
                type = "user",
                isMeta = true,
                sourceToolUseID = "toolu_2",
                message = { content = { { type = "text", text = "body" } } },
            })

            assert.is_true(link.ends_chain)
            assert.equal("toolu_2", link.tool_call_id)
            assert.is_false(link.after_prompt)
            assert.is_false(link.user_text)
        end)

        it("passes the chain on through a skill run as /name", function()
            local link = link_of({
                type = "user",
                isMeta = true,
                message = { content = { { type = "text", text = "body" } } },
            })

            assert.is_false(link.ends_chain)
            assert.is_true(link.injected)
            assert.is_nil(link.tool_call_id)
        end)

        it("ends the chain at no place on the agent's output", function()
            local link = link_of({
                type = "assistant",
                message = { content = { { type = "text", text = "done" } } },
            })

            assert.is_true(link.ends_chain)
            assert.is_nil(link.tool_call_id)
            assert.is_false(link.after_prompt)
            assert.is_false(link.after_compaction)
        end)

        it("ends the chain at the user's own text", function()
            local link =
                link_of({ type = "user", message = { content = "fix it" } })

            assert.is_true(link.ends_chain)
            assert.is_true(link.after_prompt)
            assert.is_true(link.user_text)
        end)

        it("reads a <command-message> record as the user's text", function()
            local link = link_of({
                type = "user",
                message = {
                    content = "<command-message>implement</command-message>\n"
                        .. "<command-args>@./notes/plan.md</command-args>",
                },
            })

            assert.is_true(link.after_prompt)
            assert.is_true(link.user_text)
        end)

        it("ends the chain at a compaction's output", function()
            local link = link_of({
                type = "user",
                repeatsCompactSummary = true,
                message = { content = "This session is being continued…" },
            })

            assert.is_true(link.ends_chain)
            assert.is_true(link.after_compaction)
            assert.is_false(link.after_prompt)
            assert.is_false(link.user_text)
        end)

        it("ends the chain at a queued_command attachment", function()
            local link = link_of({
                type = "attachment",
                attachment = { type = "queued_command", prompt = { "next" } },
            })

            assert.is_true(link.ends_chain)
            assert.is_true(link.after_prompt)
            assert.is_true(link.user_text)
        end)

        it("leaves an attachment to inherit from its parent", function()
            local link = link_of({
                type = "attachment",
                attachment = { type = "nested_memory", path = "/r.md" },
            })

            assert.is_false(link.ends_chain)
            assert.equal("u-0", link.parent_uuid)
        end)

        it("carries a hook attachment's command", function()
            local link = link_of({
                type = "attachment",
                attachment = {
                    type = "hook_success",
                    hookEvent = "PreToolUse",
                    command = "/hooks/guard.sh",
                },
            })

            assert.is_false(link.ends_chain)
            assert.equal("/hooks/guard.sh", link.command)
        end)

        it("leaves a null parent unset", function()
            local link = ClaudeTranscriptRecords.link(
                vim.json.decode('{"uuid":"u-1","parentUuid":null}')
            )
            ---@cast link -nil

            assert.is_nil(link.parent_uuid)
        end)
    end)
end)
