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

    --- A hook run that delivered `context` as JSON `additionalContext`.
    --- @param uuid string
    --- @param command string
    --- @param context string
    --- @param attachment table|nil fields to override on the attachment
    --- @return table
    local function json_run(uuid, command, context, attachment)
        return {
            type = "attachment",
            uuid = uuid,
            timestamp = AFTER,
            attachment = vim.tbl_extend("force", {
                type = "hook_success",
                hookEvent = "PreToolUse",
                command = command,
                content = "",
                stdout = vim.json.encode({
                    hookSpecificOutput = { additionalContext = context },
                }),
                stderr = "",
                exitCode = 0,
            }, attachment or {}),
        }
    end

    --- A `hook_additional_context` entry with one `content` element per text.
    --- @param uuid string
    --- @param texts string[]
    --- @param attachment table|nil fields to override on the attachment
    --- @return table
    local function merged(uuid, texts, attachment)
        local entry = injected(uuid, nil, "")
        entry.attachment = vim.tbl_extend(
            "force",
            entry.attachment,
            { content = texts },
            attachment or {}
        )
        return entry
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

    describe("tool input", function()
        --- @param uuid string
        --- @param name string
        --- @param input table
        --- @param timestamp string|nil
        --- @return table
        local function tool_use(uuid, name, input, timestamp)
            return transcript_entry("assistant", uuid, nil, {
                timestamp = timestamp or AFTER,
                message = {
                    content = {
                        {
                            type = "tool_use",
                            id = "toolu_" .. uuid,
                            name = name,
                            input = input,
                        },
                    },
                },
            })
        end

        it("returns a SendMessage call's head and message", function()
            local reader = reader_at(transcript)
            append({
                tool_use("a-1", "SendMessage", {
                    to = "peer",
                    summary = "Tell peer",
                    message = "hi",
                }),
            })

            assert.same({
                {
                    kind = "tool_call",
                    tool_call = {
                        tool_call_id = "toolu_a-1",
                        argument = "peer: Tell peer",
                        body = { "hi" },
                    },
                },
            }, reader:drain())
        end)

        it("returns nothing for another tool", function()
            local reader = reader_at(transcript)
            append({ tool_use("a-1", "Bash", { command = "ls" }) })

            assert.same({}, reader:drain())
        end)

        it("skips a call the transcript already held", function()
            append({
                tool_use("a-0", "SendMessage", { to = "peer" }, BEFORE),
            })
            local reader = reader_at(transcript)

            assert.same({}, reader:drain())
        end)
    end)

    it("drops a run the turn's cancellation stopped", function()
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
        })

        assert.same({}, reader:drain())
    end)

    describe("context pairing", function()
        it("returns no record for a JSON context run", function()
            local reader = reader_at(transcript)
            append({ json_run("h-1", "/hooks/guard.sh", "guard says hi") })

            assert.same({}, reader:drain())
        end)

        it("names and times a context after its run", function()
            local reader = reader_at(transcript)
            append({
                json_run("h-1", "/hooks/guard.sh", "guard says hi", {
                    toolUseID = "toolu_1",
                    hookName = "PreToolUse:Bash",
                    durationMs = 28,
                }),
                merged("c-1", { "guard says hi" }, { toolUseID = "toolu_1" }),
            })

            local records = hooks(reader:drain())

            assert.equal(1, #records)
            assert.equal("context", records[1].group)
            assert.equal("/hooks/guard.sh", records[1].command)
            assert.equal(28, records[1].duration_ms)
        end)

        it("pairs by text when the ids differ", function()
            local reader = reader_at(transcript)
            local start = { hookEvent = "SessionStart" }
            append({
                json_run(
                    "h-1",
                    "/hooks/a.sh",
                    "from a",
                    vim.tbl_extend("force", start, { toolUseID = "3f2a-uuid" })
                ),
                json_run(
                    "h-2",
                    "/hooks/b.sh",
                    "from b",
                    vim.tbl_extend("force", start, { toolUseID = "3f2a-uuid" })
                ),
                merged(
                    "c-1",
                    { "from b", "from a" },
                    vim.tbl_extend(
                        "force",
                        start,
                        { toolUseID = "SessionStart" }
                    )
                ),
            })

            local commands = vim.tbl_map(function(record)
                return record.command
            end, hooks(reader:drain()))

            assert.same({ "/hooks/b.sh", "/hooks/a.sh" }, commands)
        end)

        it("pairs by event and id when the text differs", function()
            local reader = reader_at(transcript)
            local post = { hookEvent = "PostToolUse", toolUseID = "toolu_1" }
            append({
                json_run("h-1", "/hooks/big.sh", "a large context", post),
                merged("c-1", { "<persisted-output>…" }, post),
            })

            assert.equal("/hooks/big.sh", hooks(reader:drain())[1].command)
        end)

        it("leaves a run of another event unpaired", function()
            local reader = reader_at(transcript)
            append({
                json_run("h-1", "/hooks/guard.sh", "same", {
                    hookEvent = "SessionStart",
                }),
                merged("c-1", { "same" }),
            })

            assert.is_nil(hooks(reader:drain())[1].command)
        end)

        it("forgets unpaired runs on a new transcript path", function()
            local reader = reader_at(transcript)
            append({ json_run("h-1", "/hooks/guard.sh", "guard says hi") })
            reader:drain()

            local other = vim.fs.joinpath(dir, "other.jsonl")
            transcript = other
            append({ merged("c-1", { "guard says hi" }) })
            reader:set_transcript_path(other)

            assert.is_nil(hooks(reader:drain())[1].command)
        end)

        it("pairs two runs with the same text in order", function()
            local reader = reader_at(transcript)
            append({
                json_run("h-1", "/hooks/guard.sh", "same", { durationMs = 1 }),
                json_run("h-2", "/hooks/guard.sh", "same", { durationMs = 2 }),
                merged("c-1", { "same" }),
                merged("c-2", { "same" }),
            })

            local durations = vim.tbl_map(function(record)
                return record.duration_ms
            end, hooks(reader:drain()))

            assert.same({ 1, 2 }, durations)
        end)

        it("takes text matches before the id fallback", function()
            local reader = reader_at(transcript)
            local post = { hookEvent = "PostToolUse", toolUseID = "toolu_1" }
            append({
                json_run("h-1", "/hooks/a.sh", "from a", post),
                json_run("h-2", "/hooks/big.sh", "a large context", post),
                json_run("h-3", "/hooks/c.sh", "from c", post),
                merged(
                    "c-1",
                    { "<persisted-output>…", "from a", "from c" },
                    post
                ),
            })

            local commands = vim.tbl_map(function(record)
                return record.command
            end, hooks(reader:drain()))

            assert.same(
                { "/hooks/big.sh", "/hooks/a.sh", "/hooks/c.sh" },
                commands
            )
        end)

        it("pairs a run in one drain with a context in the next", function()
            local reader = reader_at(transcript)
            append({ json_run("h-1", "/hooks/guard.sh", "guard says hi") })
            reader:drain()

            append({ merged("c-1", { "guard says hi" }) })

            assert.equal("/hooks/guard.sh", hooks(reader:drain())[1].command)
        end)

        it("pairs a context with a run that predates the reader", function()
            local run = json_run("h-1", "/hooks/guard.sh", "guard says hi")
            run.timestamp = BEFORE
            append({ run })
            local reader = reader_at(transcript)
            append({ merged("c-1", { "guard says hi" }) })

            assert.equal("/hooks/guard.sh", hooks(reader:drain())[1].command)
        end)

        it("lets a context before the reader consume its run", function()
            local run = json_run("h-1", "/hooks/guard.sh", "guard says hi")
            local old = merged("c-0", { "guard says hi" })
            run.timestamp = BEFORE
            old.timestamp = BEFORE
            append({ run, old })
            local reader = reader_at(transcript)
            append({ merged("c-1", { "guard says hi" }) })

            local records = hooks(reader:drain())

            assert.equal(1, #records)
            assert.is_nil(records[1].command)
        end)
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
        assert.equal("/hooks/review.sh", records[1].command)
    end)

    it("carries the hook name of a record with no command", function()
        local reader = reader_at(transcript)
        local entry = injected("c-1", nil, "from a prompt submit hook")
        entry.attachment.hookName = "UserPromptSubmit"
        append({ entry })

        local record = hooks(reader:drain())[1]
        assert.is_nil(record.command)
        assert.equal("UserPromptSubmit", record.hook_name)
    end)

    it("carries both the command and the hook name", function()
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

        local record = hooks(reader:drain())[1]
        assert.equal("/hooks/shell-guard.sh", record.command)
        assert.equal("PreToolUse:Bash", record.hook_name)
    end)

    it("leaves the command unknown when no run produced the body", function()
        local reader = reader_at(transcript)
        append({ injected("c-1", nil, "from a prompt submit hook") })

        assert.is_nil(hooks(reader:drain())[1].command)
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
        assert.equal("/hooks/permission_hook.sh", records[1].command)
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

        it("places a SessionStart record after the prompt", function()
            local reader = reader_at(transcript)
            local start = { hookEvent = "SessionStart" }
            append({
                json_run(
                    "h-1",
                    "/hooks/guard.sh",
                    "ctx",
                    vim.tbl_extend("force", start, {
                        hookName = "SessionStart:startup",
                    })
                ),
                merged("c-1", { "ctx" }, start),
            })

            local record = hooks(reader:drain())[1]

            assert.is_true(record.after_prompt)
            assert.is_nil(record.after_compaction)
        end)

        it(
            "places a SessionStart:compact record after the compaction",
            function()
                local reader = reader_at(transcript)
                local start = { hookEvent = "SessionStart" }
                append({
                    json_run(
                        "h-1",
                        "/hooks/guard.sh",
                        "ctx",
                        vim.tbl_extend("force", start, {
                            hookName = "SessionStart:compact",
                        })
                    ),
                    merged("c-1", { "ctx" }, start),
                })

                local record = hooks(reader:drain())[1]

                assert.is_true(record.after_compaction)
                assert.is_nil(record.after_prompt)
            end
        )

        it(
            "places an unpaired SessionStart context after the prompt",
            function()
                local reader = reader_at(transcript)
                append({
                    merged("c-1", { "ctx" }, {
                        hookEvent = "SessionStart",
                        hookName = "SessionStart",
                    }),
                })

                assert.is_true(hooks(reader:drain())[1].after_prompt)
            end
        )

        it("places a SessionStart failure after the prompt", function()
            local reader = reader_at(transcript)
            append({
                transcript_entry("attachment", "e-1", nil, {
                    attachment = {
                        type = "hook_non_blocking_error",
                        hookEvent = "SessionStart",
                        hookName = "SessionStart:startup",
                        command = "/hooks/init.sh",
                        stderr = "boom",
                        exitCode = 2,
                    },
                }),
            })

            local record = hooks(reader:drain())[1]

            assert.equal("failure", record.group)
            assert.is_true(record.after_prompt)
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
