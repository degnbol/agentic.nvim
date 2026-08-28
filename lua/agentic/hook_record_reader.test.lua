local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("HookRecordReader", function()
    --- @type table
    local HookRecordReader
    --- @type table
    local Logger
    local SESSION_ID = "5bcf246d-0000-0000-0000-000000000000"
    --- @type string
    local dir
    --- @type string
    local transcript

    before_each(function()
        package.loaded["agentic.hook_record_reader"] = nil
        HookRecordReader = require("agentic.hook_record_reader")
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

    --- @param path string
    --- @return table
    local function reader_at(path)
        local reader = HookRecordReader:new()
        reader:set_transcript_path(path, SESSION_ID)
        return reader
    end

    it("drains nothing before a transcript path is known", function()
        assert.same({}, HookRecordReader:new():drain())
    end)

    it("ignores a subagent transcript reported under this session", function()
        local subagent =
            vim.fs.joinpath(dir, SESSION_ID, "subagents", "agent-1.jsonl")
        vim.fn.mkdir(vim.fs.dirname(subagent), "p")
        local reader = reader_at(subagent)

        append({ injected("c-1", nil, "hello") })

        assert.same({}, reader:drain())
    end)

    it("returns injected context appended after construction", function()
        local reader = reader_at(transcript)
        append({ injected("c-1", nil, "two\nlines") })

        local records = reader:drain()

        assert.equal(1, #records)
        assert.equal("context", records[1].group)
        assert.same({ "two", "lines" }, records[1].body)
    end)

    it("skips records the transcript already held", function()
        append({ injected("c-0", nil, "from an earlier session", BEFORE) })
        local reader = reader_at(transcript)
        append({ injected("c-1", nil, "this turn") })

        local records = reader:drain()

        assert.equal(1, #records)
        assert.same({ "this turn" }, records[1].body)
    end)

    it("returns each record once across drains", function()
        local reader = reader_at(transcript)
        append({ injected("c-1", nil, "first") })
        reader:drain()

        append({ injected("c-2", nil, "second") })
        local records = reader:drain()

        assert.equal(1, #records)
        assert.same({ "second" }, records[1].body)
    end)

    it("consumes a hook run but names the context it produced", function()
        local reader = reader_at(transcript)
        append({
            ran("h-1", "/hooks/shell-guard.sh"),
            injected("c-1", "h-1", "guard says hi"),
        })

        local records = reader:drain()

        assert.equal(1, #records)
        assert.equal("shell-guard.sh", records[1].script)
    end)

    it("attributes context to a run that predates construction", function()
        append({ ran("h-1", "/hooks/shell-guard.sh", BEFORE) })
        local reader = reader_at(transcript)
        append({ injected("c-1", "h-1", "guard says hi") })

        local records = reader:drain()

        assert.equal("shell-guard.sh", records[1].script)
    end)

    it("attributes context to a run drained earlier", function()
        local reader = reader_at(transcript)
        append({ ran("h-1", "/hooks/shell-guard.sh") })
        reader:drain()

        append({ injected("c-1", "h-1", "guard says hi") })
        local records = reader:drain()

        assert.equal("shell-guard.sh", records[1].script)
    end)

    it("leaves the script unnamed when no run produced the body", function()
        local reader = reader_at(transcript)
        append({ injected("c-1", nil, "from a prompt submit hook") })

        assert.is_nil(reader:drain()[1].script)
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

        local records = reader:drain()

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

        local records = reader:drain()

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
