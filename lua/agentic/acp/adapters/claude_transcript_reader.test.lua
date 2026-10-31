local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("ClaudeTranscriptReader", function()
    --- @type table
    local ClaudeTranscriptReader
    --- @type table
    local Logger
    local SESSION_ID = "5bcf246d-0000-0000-0000-000000000000"
    --- @type string
    local dir
    --- @type string
    local transcript

    before_each(function()
        package.loaded["agentic.acp.adapters.claude_transcript_reader"] = nil
        ClaudeTranscriptReader =
            require("agentic.acp.adapters.claude_transcript_reader")
        Logger = require("agentic.utils.logger")
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, "p")
        transcript = vim.fs.joinpath(dir, SESSION_ID .. ".jsonl")
    end)

    after_each(function()
        vim.fs.rm(dir, { recursive = true })
    end)

    --- The reader keeps records at or after its construction time; these sit
    --- unambiguously on either side of it.
    local BEFORE = "2000-01-01T00:00:00.000Z"
    local AFTER = "2999-01-01T00:00:00.000Z"

    --- @param entries table[]
    local function append(entries)
        local f = io.open(transcript, "ab")
        assert.is_not_nil(f)
        ---@cast f -nil
        for _, entry in ipairs(entries) do
            f:write(vim.json.encode(entry) .. "\n")
        end
        f:close()
    end

    --- @param uuid string
    --- @param command string
    --- @param timestamp string|nil
    --- @return table
    local function ran(uuid, command, timestamp)
        return {
            type = "attachment",
            uuid = uuid,
            timestamp = timestamp or AFTER,
            attachment = {
                type = "hook_success",
                hookEvent = "PreToolUse",
                command = command,
                content = "",
                stdout = vim.json.encode({
                    hookSpecificOutput = { permissionDecision = "allow" },
                }),
                stderr = "",
                exitCode = 0,
            },
        }
    end

    --- @param uuid string
    --- @param parent_uuid string|nil
    --- @param text string
    --- @param timestamp string|nil
    --- @return table
    local function injected(uuid, parent_uuid, text, timestamp)
        return {
            type = "attachment",
            uuid = uuid,
            parentUuid = parent_uuid,
            timestamp = timestamp or AFTER,
            attachment = {
                type = "hook_additional_context",
                hookEvent = "PreToolUse",
                content = { text },
            },
        }
    end

    --- The hook records among drained side records, in order.
    --- @param records agentic.acp.SideRecord[]
    --- @return agentic.acp.HookRecord[]
    local function hooks(records)
        local out = {}
        for _, record in ipairs(records) do
            if record.kind == "hook" then
                table.insert(out, record.hook)
            end
        end
        return out
    end

    --- The loaded files among drained side records, in order.
    --- @param records agentic.acp.SideRecord[]
    --- @return agentic.acp.LoadedFile[]
    local function loaded_files(records)
        local out = {}
        for _, record in ipairs(records) do
            if record.kind == "loaded_file" then
                table.insert(out, record.loaded_file)
            end
        end
        return out
    end

    --- A conversation entry of the transcript.
    --- @param type_ string
    --- @param uuid string
    --- @param parent_uuid string|nil
    --- @param fields table|nil
    --- @return table
    local function transcript_entry(type_, uuid, parent_uuid, fields)
        return vim.tbl_extend("force", {
            type = type_,
            uuid = uuid,
            parentUuid = parent_uuid,
            timestamp = AFTER,
        }, fields or {})
    end

    --- @param uuid string
    --- @param parent_uuid string
    --- @param tool_use_id string
    --- @return table
    local function tool_result(uuid, parent_uuid, tool_use_id)
        return transcript_entry("user", uuid, parent_uuid, {
            message = {
                content = {
                    { type = "tool_result", tool_use_id = tool_use_id },
                },
            },
        })
    end

    --- @param uuid string
    --- @param parent_uuid string|nil
    --- @param text string
    --- @param timestamp string|nil
    --- @return table
    local function prompt(uuid, parent_uuid, text, timestamp)
        return transcript_entry("user", uuid, parent_uuid, {
            message = { content = text },
            timestamp = timestamp or AFTER,
        })
    end

    --- @param uuid string
    --- @param parent_uuid string
    --- @param source_tool_use_id string|nil
    --- @return table
    local function skill_body(uuid, parent_uuid, source_tool_use_id)
        return transcript_entry("user", uuid, parent_uuid, {
            isMeta = true,
            sourceToolUseID = source_tool_use_id,
            message = { content = { { type = "text", text = "skill body" } } },
        })
    end

    --- @param uuid string
    --- @param parent_uuid string
    --- @param path string
    --- @return table
    local function rule(uuid, parent_uuid, path)
        return transcript_entry("attachment", uuid, parent_uuid, {
            attachment = { type = "nested_memory", path = path },
        })
    end

    --- @param uuid string
    --- @param parent_uuid string
    --- @param path string
    --- @return table
    local function mention(uuid, parent_uuid, path)
        return transcript_entry("attachment", uuid, parent_uuid, {
            attachment = { type = "file", filename = path },
        })
    end

    --- @param path string
    --- @return table
    local function reader_at(path)
        local reader = ClaudeTranscriptReader:new()
        reader:set_transcript_path(path)
        return reader
    end

    it("drains nothing before a transcript path is known", function()
        assert.same({}, ClaudeTranscriptReader:new():drain())
    end)

    it("returns injected context appended after construction", function()
        local reader = reader_at(transcript)
        append({ injected("c-1", nil, "two\nlines") })

        local records = hooks(reader:drain())

        assert.equal(1, #records)
        assert.equal("context", records[1].group)
        assert.same({ "two", "lines" }, records[1].body)
    end)

    it("skips records the transcript already held", function()
        append({ injected("c-0", nil, "from an earlier session", BEFORE) })
        local reader = reader_at(transcript)
        append({ injected("c-1", nil, "this turn") })

        local records = hooks(reader:drain())

        assert.equal(1, #records)
        assert.same({ "this turn" }, records[1].body)
    end)

    it("returns each record once across drains", function()
        local reader = reader_at(transcript)
        append({ injected("c-1", nil, "first") })
        reader:drain()

        append({ injected("c-2", nil, "second") })
        local records = hooks(reader:drain())

        assert.equal(1, #records)
        assert.same({ "second" }, records[1].body)
    end)

    it(
        "returns a hook run as passed and names the context it produced",
        function()
            local reader = reader_at(transcript)
            append({
                ran("h-1", "/hooks/shell-guard.sh"),
                injected("c-1", "h-1", "guard says hi"),
            })

            local records = hooks(reader:drain())

            assert.equal(2, #records)
            assert.equal("passed", records[1].group)
            assert.equal("shell-guard.sh", records[1].script)
            assert.equal("context", records[2].group)
            assert.equal("shell-guard.sh", records[2].script)
        end
    )

    it("consumes a run the turn's cancellation stopped", function()
        local reader = reader_at(transcript)
        append({
            {
                type = "attachment",
                uuid = "h-1",
                timestamp = AFTER,
                attachment = {
                    type = "hook_cancelled",
                    hookEvent = "PreToolUse",
                    command = "/hooks/shell-guard.sh",
                    timedOut = false,
                },
            },
            injected("c-1", "h-1", "guard says hi"),
        })

        local records = hooks(reader:drain())

        assert.equal(1, #records)
        assert.equal("shell-guard.sh", records[1].script)
    end)

    it("attributes context to a run that predates construction", function()
        append({ ran("h-1", "/hooks/shell-guard.sh", BEFORE) })
        local reader = reader_at(transcript)
        append({ injected("c-1", "h-1", "guard says hi") })

        local records = hooks(reader:drain())

        assert.equal("shell-guard.sh", records[1].script)
    end)

    it("attributes context to a run drained earlier", function()
        local reader = reader_at(transcript)
        append({ ran("h-1", "/hooks/shell-guard.sh") })
        reader:drain()

        append({ injected("c-1", "h-1", "guard says hi") })
        local records = hooks(reader:drain())

        assert.equal("shell-guard.sh", records[1].script)
    end)

    it("names stop hook feedback after its own command", function()
        local reader = reader_at(transcript)
        append({
            {
                type = "system",
                subtype = "stop_hook_summary",
                uuid = "s-1",
                timestamp = AFTER,
                hookErrors = { "[/hooks/review.sh]: two files changed" },
            },
        })

        local records = hooks(reader:drain())

        assert.equal(1, #records)
        assert.equal("review.sh", records[1].script)
    end)

    it("names a record with no command after its hook", function()
        local reader = reader_at(transcript)
        local entry = injected("c-1", nil, "from a prompt submit hook")
        entry.attachment.hookName = "UserPromptSubmit"
        append({ entry })

        assert.equal("UserPromptSubmit", hooks(reader:drain())[1].script)
    end)

    it("prefers the command to the hook name", function()
        local reader = reader_at(transcript)
        append({
            {
                type = "attachment",
                uuid = "e-1",
                timestamp = AFTER,
                attachment = {
                    type = "hook_non_blocking_error",
                    hookEvent = "PreToolUse",
                    hookName = "PreToolUse:Bash",
                    command = "/hooks/shell-guard.sh",
                    stderr = "boom",
                    exitCode = 2,
                },
            },
        })

        assert.equal("shell-guard.sh", hooks(reader:drain())[1].script)
    end)

    it("leaves the script unnamed when no run produced the body", function()
        local reader = reader_at(transcript)
        append({ injected("c-1", nil, "from a prompt submit hook") })

        assert.is_nil(hooks(reader:drain())[1].script)
    end)

    it("names a failure after its own command", function()
        local reader = reader_at(transcript)
        append({
            {
                type = "attachment",
                uuid = "e-1",
                timestamp = AFTER,
                attachment = {
                    type = "hook_cancelled",
                    hookEvent = "PreToolUse",
                    command = "/hooks/permission_hook.sh",
                    timedOut = true,
                    timeoutMs = 600000,
                    durationMs = 600001,
                },
            },
        })

        local records = hooks(reader:drain())

        assert.equal("failure", records[1].group)
        assert.equal("permission_hook.sh", records[1].script)
    end)

    it("drops an unparseable line the transcript already held", function()
        -- A verbatim record has no timestamp to place it, so the catch-up read
        -- is what places it: those bytes predate this reader.
        local f = io.open(transcript, "ab")
        assert.is_not_nil(f)
        ---@cast f -nil
        f:write("{ truncated\n")
        f:close()
        local reader = reader_at(transcript)

        assert.same({}, reader:drain())
    end)

    it("keeps an unparseable line appended after the catch-up", function()
        append({ injected("c-1", nil, "this turn") })
        local reader = reader_at(transcript)
        reader:drain()

        local f = io.open(transcript, "ab")
        assert.is_not_nil(f)
        ---@cast f -nil
        f:write("{ truncated\n")
        f:close()

        local records = hooks(reader:drain())

        assert.equal(1, #records)
        assert.equal("verbatim", records[1].group)
    end)

    it("drops an unparseable line from a replaced transcript", function()
        -- Reading a shorter file restarts at the top, so those bytes are on the
        -- same footing as catch-up: they can predate the reader.
        append({ injected("c-1", nil, "a long first line, then some more") })
        local reader = reader_at(transcript)
        reader:drain()

        local f = io.open(transcript, "wb")
        assert.is_not_nil(f)
        ---@cast f -nil
        f:write("{ trunc\n")
        f:close()

        assert.same({}, reader:drain())
    end)

    describe("loaded files", function()
        it("names a Skill's call for everything its body loads", function()
            local reader = reader_at(transcript)
            append({
                transcript_entry("assistant", "a-1", "p-0"),
                tool_result("r-1", "a-1", "toolu_skill"),
                skill_body("m-1", "r-1", "toolu_skill"),
                mention("f-1", "m-1", "/repo/notes/plan.md"),
                rule("n-1", "f-1", "/repo/.claude/rules/a.md"),
                rule("n-2", "n-1", "/repo/.claude/rules/b.md"),
            })

            assert.same({
                { path = "/repo/notes/plan.md", tool_call_id = "toolu_skill" },
                {
                    path = "/repo/.claude/rules/a.md",
                    tool_call_id = "toolu_skill",
                },
                {
                    path = "/repo/.claude/rules/b.md",
                    tool_call_id = "toolu_skill",
                },
            }, loaded_files(reader:drain()))
        end)

        it("names the Bash call whose result a rule loads under", function()
            local reader = reader_at(transcript)
            append({
                tool_result("r-1", "a-1", "toolu_bash"),
                rule("n-1", "r-1", "/repo/.claude/rules/a.md"),
            })

            assert.equal(
                "toolu_bash",
                loaded_files(reader:drain())[1].tool_call_id
            )
        end)

        it("drops an @ file under the user's text, keeping its rule", function()
            local reader = reader_at(transcript)
            append({
                prompt("p-1", nil, "read @notes/plan.md"),
                mention("f-1", "p-1", "/repo/notes/plan.md"),
                rule("n-1", "f-1", "/repo/.claude/rules/a.md"),
            })

            assert.same(
                { { path = "/repo/.claude/rules/a.md", after_prompt = true } },
                loaded_files(reader:drain())
            )
        end)

        it(
            "keeps an @ file of a skill run as /name, after the prompt",
            function()
                local reader = reader_at(transcript)
                append({
                    prompt(
                        "p-1",
                        nil,
                        "<command-name>/implement</command-name>"
                    ),
                    skill_body("m-1", "p-1", nil),
                    mention("f-1", "m-1", "/repo/notes/plan.md"),
                })

                assert.same(
                    { { path = "/repo/notes/plan.md", after_prompt = true } },
                    loaded_files(reader:drain())
                )
            end
        )

        it("places a file under a compaction's output after it", function()
            local reader = reader_at(transcript)
            append({
                transcript_entry("user", "c-1", "x-0", {
                    repeatsCompactSummary = true,
                    message = { content = "This session is being continued" },
                }),
                mention("f-1", "c-1", "/repo/lua/a.lua"),
            })

            assert.same(
                { { path = "/repo/lua/a.lua", after_compaction = true } },
                loaded_files(reader:drain())
            )
        end)

        it("resolves a load whose prompt predates the reader", function()
            append({ prompt("p-1", nil, "go", BEFORE) })
            local reader = reader_at(transcript)
            append({ rule("n-1", "p-1", "/repo/.claude/rules/a.md") })

            assert.is_true(loaded_files(reader:drain())[1].after_prompt)
        end)

        it("resolves a load whose prompt came in an earlier drain", function()
            local reader = reader_at(transcript)
            append({ prompt("p-1", nil, "go") })
            reader:drain()
            append({ rule("n-1", "p-1", "/repo/.claude/rules/a.md") })

            assert.is_true(loaded_files(reader:drain())[1].after_prompt)
        end)

        it("leaves a load with no known chain end unplaced", function()
            local reader = reader_at(transcript)
            append({ rule("n-1", "gone", "/repo/.claude/rules/a.md") })

            assert.same(
                { { path = "/repo/.claude/rules/a.md" } },
                loaded_files(reader:drain())
            )
        end)

        it("returns hooks and loads mixed, in transcript order", function()
            local reader = reader_at(transcript)
            append({
                tool_result("r-1", "a-1", "toolu_1"),
                rule("n-1", "r-1", "/repo/.claude/rules/a.md"),
                injected("c-1", "n-1", "ctx"),
            })

            local kinds = vim.tbl_map(function(record)
                return record.kind
            end, reader:drain())

            assert.same({ "loaded_file", "hook" }, kinds)
        end)
    end)

    describe("hook placement", function()
        it("places a UserPromptSubmit record after the prompt", function()
            local reader = reader_at(transcript)
            local hook = injected("c-1", "p-1", "remember this")
            hook.attachment.hookEvent = "UserPromptSubmit"
            hook.attachment.toolUseID = "hook-1b2c"
            append({ prompt("p-1", nil, "go"), hook })

            local record = hooks(reader:drain())[1]

            assert.is_true(record.after_prompt)
            assert.is_nil(record.tool_call_id)
        end)

        it("keeps a PreToolUse record's call id", function()
            local reader = reader_at(transcript)
            local hook = injected("c-1", "p-1", "guard says hi")
            hook.attachment.toolUseID = "toolu_1"
            append({ prompt("p-1", nil, "go"), hook })

            local record = hooks(reader:drain())[1]

            assert.equal("toolu_1", record.tool_call_id)
            assert.is_nil(record.after_prompt)
        end)

        it("leaves an @ file in Stop hook feedback unplaced", function()
            local reader = reader_at(transcript)
            append({
                prompt("p-1", nil, "go"),
                transcript_entry("assistant", "a-1", "p-1"),
                transcript_entry("user", "m-1", "a-1", {
                    isMeta = true,
                    message = { content = "Stop hook feedback: see @x.md" },
                }),
                mention("f-1", "m-1", "/repo/x.md"),
            })

            assert.same(
                { { path = "/repo/x.md" } },
                loaded_files(reader:drain())
            )
        end)

        it("leaves a Stop record after the agent's reply unplaced", function()
            local reader = reader_at(transcript)
            append({
                prompt("p-1", nil, "go"),
                transcript_entry("assistant", "a-1", "p-1"),
                {
                    type = "system",
                    subtype = "stop_hook_summary",
                    uuid = "s-1",
                    parentUuid = "a-1",
                    timestamp = AFTER,
                    hookErrors = { "[/hooks/review.sh]: two files changed" },
                },
            })

            local record = hooks(reader:drain())[1]

            assert.is_nil(record.after_prompt)
            assert.is_nil(record.tool_call_id)
        end)
    end)

    it("notifies once when the transcript cannot be read", function()
        local notify = spy.stub(Logger, "notify")
        local reader = reader_at(transcript)
        os.remove(transcript)

        reader:drain()
        reader:drain()

        assert.equal(1, notify.call_count)
        notify:revert()
    end)
end)
