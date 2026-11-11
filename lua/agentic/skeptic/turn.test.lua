--- @diagnostic disable: missing-fields, assign-type-mismatch
local assert = require("tests.helpers.assert")

local ChatHistory = require("agentic.ui.chat_history")
local Turn = require("agentic.skeptic.turn")

--- Assert that `text` holds a match of the Lua `pattern`.
--- @param pattern string
--- @param text string
local function assert_matches(pattern, text)
    assert.truthy(text:find(pattern), ("%q in %q"):format(pattern, text))
end

--- @param text string
--- @param author string|nil
--- @return agentic.ui.ChatHistory.UserMessage
local function prompt(text, author)
    return {
        type = "user",
        text = text,
        timestamp = 0,
        provider_name = "p",
        author = author,
    }
end

--- @param text string
--- @return agentic.ui.ChatHistory.AgentMessage
local function agent(text)
    return { type = "agent", text = text, provider_name = "p" }
end

--- A completed edit of `path` from `old` to `new`.
--- @param id string
--- @param path string
--- @param old string[]
--- @param new string[]
--- @return agentic.ui.ChatHistory.ToolCall
local function edit(id, path, old, new)
    return {
        type = "tool_call",
        tool_call_id = id,
        kind = "edit",
        status = "completed",
        argument = path,
        diff = { old = old, new = new },
    }
end

--- @param id string
--- @param status string
--- @param body string[]
--- @return agentic.ui.ChatHistory.ToolCall
local function spawn(id, status, body)
    return {
        type = "tool_call",
        tool_call_id = id,
        kind = "SubAgent",
        status = status,
        argument = "agentic://1/subagent/" .. id,
        body = body,
        subagent = { label = "map", mode = "background", confirmed = true },
    }
end

--- @param messages agentic.ui.ChatHistory.Message[]
--- @return agentic.ui.ChatHistory
local function history_of(messages)
    local history = ChatHistory:new()
    for _, msg in ipairs(messages) do
        history:add_message(msg)
    end
    return history
end

--- @return agentic.skeptic.Seen
local function fresh()
    return { mark = 1, ids = {} }
end

describe("agentic.skeptic.Turn", function()
    describe("collect", function()
        it("takes user prompts and main agent text since the mark", function()
            local history = history_of({
                prompt("first"),
                agent("one"),
                { type = "thought", text = "hmm", provider_name = "p" },
                agent("two"),
            })
            local seen = fresh()

            local turn = Turn.collect(history, seen)

            assert.same({ "first" }, turn.prompts)
            assert.equal("one\n\ntwo", turn.text)
            assert.equal(5, seen.mark)
        end)

        it("takes nothing twice", function()
            local history = history_of({ prompt("first"), agent("one") })
            local seen = fresh()
            Turn.collect(history, seen)
            history:add_message(prompt("second"))

            local turn = Turn.collect(history, seen)

            assert.same({ "second" }, turn.prompts)
            assert.equal("", turn.text)
        end)

        it("leaves out authored and synthetic prompts", function()
            local continue = prompt("continue")
            continue.synthetic = true
            local history = history_of({
                prompt("check", "skeptic"),
                continue,
                prompt("go"),
            })

            assert.same({ "go" }, Turn.collect(history, fresh()).prompts)
        end)

        -- A prompt sent mid-turn adds its row while the earlier turn still
        -- writes: the rows interleave, and both turns' text counts once.
        it("takes a mid-turn prompt row interleaved with text", function()
            local history = history_of({
                prompt("first"),
                agent("one"),
                prompt("second"),
                agent("two"),
            })

            local turn = Turn.collect(history, fresh())

            assert.same({ "first", "second" }, turn.prompts)
            assert.equal("one\n\ntwo", turn.text)
        end)

        it("takes a completed diff once, as a unified diff", function()
            local history = history_of({
                edit("e1", "/src/a.lua", { "x = 1" }, { "x = 2" }),
            })
            local seen = fresh()

            local first = Turn.collect(history, seen)
            local second = Turn.collect(history, seen)

            assert.equal(1, #first.diffs)
            assert_matches(
                "^%-%-%- /src/a%.lua\n%+%+%+ /src/a%.lua\n",
                first.diffs[1]
            )
            assert_matches("\n%-x = 1\n%+x = 2\n", first.diffs[1])
            assert.same({}, second.diffs)
        end)

        it("takes a diff that arrives after an earlier collect", function()
            local call = edit("e1", "/src/a.lua", {}, {})
            call.diff = nil
            call.status = "in_progress"
            local history = history_of({ prompt("go"), call })
            local seen = fresh()
            assert.same({}, Turn.collect(history, seen).diffs)

            call.diff = { old = {}, new = { "new file" } }
            call.status = "completed"

            local turn = Turn.collect(history, seen)
            assert.equal(1, #turn.diffs)
            assert_matches("\n%+new file\n", turn.diffs[1])
        end)

        it("takes a subagent's edit", function()
            local history = history_of({ prompt("go") })
            local call = edit("e2", "/src/b.lua", { "a" }, { "b" })
            call.agent_key = "task-1"
            history:add_message(call)

            assert.equal(1, #Turn.collect(history, fresh()).diffs)
        end)

        it("takes a background subagent's report on an old row", function()
            local block = spawn("child-1", "in_progress", { "Find the files." })
            local history = history_of({ prompt("go"), block, agent("ok") })
            local seen = fresh()
            assert.same({}, Turn.collect(history, seen).reports)
            history:add_message(prompt("next"))

            block.status = "completed"
            block.body = { "Found 3 files." }

            assert.same(
                { "Found 3 files." },
                Turn.collect(history, seen).reports
            )
            assert.same({}, Turn.collect(history, seen).reports)
        end)

        -- On opencode the block's body is the subagent's prompt until it
        -- completes.
        it("takes no report from an unfinished block", function()
            local history = history_of({
                spawn("child-1", "in_progress", { "Find the files." }),
            })

            assert.same({}, Turn.collect(history, fresh()).reports)
        end)

        it("takes a result message the main agent received", function()
            local history = history_of({
                prompt("go"),
                {
                    type = "session_message",
                    message_id = "m1",
                    view = "received",
                    kind = "result",
                    text = "Done: 2 bugs.",
                },
                {
                    type = "session_message",
                    message_id = "m2",
                    view = "received",
                    kind = "message",
                    text = "chatter",
                },
            })
            local seen = fresh()

            assert.same(
                { "Done: 2 bugs." },
                Turn.collect(history, seen).reports
            )
            assert.same({}, Turn.collect(history, seen).reports)
        end)

        it("takes a launch's reply as a result", function()
            local history = history_of({
                prompt("go"),
                {
                    type = "session_message",
                    message_id = "toolu_1:reply",
                    view = "received",
                    kind = "result",
                    launch_reply = true,
                    text = "Found 3 files.",
                },
            })

            assert.same(
                { "Found 3 files." },
                Turn.collect(history, fresh()).reports
            )
        end)
    end)

    describe("seen_before", function()
        it("counts every row before the message as seen", function()
            local current = prompt("now")
            local history = history_of({
                prompt("old"),
                edit("e1", "/a", { "a" }, { "b" }),
                spawn("child-1", "completed", { "old report" }),
                current,
                agent("reply"),
                edit("e2", "/b", { "a" }, { "b" }),
            })

            local turn =
                Turn.collect(history, Turn.seen_before(history, current))

            assert.same({ "now" }, turn.prompts)
            assert.equal("reply", turn.text)
            assert.equal(1, #turn.diffs)
            assert_matches("^%-%-%- /b", turn.diffs[1])
            assert.same({}, turn.reports)
        end)

        it(
            "keeps the edits of a subagent spawned from the message on",
            function()
                local current = prompt("now")
                local old_edit = edit("e1", "/a", { "a" }, { "b" })
                old_edit.agent_key = "old-child"
                local new_edit = edit("e2", "/b", { "a" }, { "b" })
                new_edit.agent_key = "task-new"
                local history = history_of({
                    spawn("old-child", "completed", {}),
                    current,
                    spawn("new-child", "in_progress", {}),
                    old_edit,
                    new_edit,
                })
                history.subagents["new-child"] = { task_id = "task-new" }

                local turn =
                    Turn.collect(history, Turn.seen_before(history, current))

                assert.equal(1, #turn.diffs)
                assert_matches("^%-%-%- /b", turn.diffs[1])
            end
        )

        it("counts the whole history without the message", function()
            local history = history_of({ prompt("old"), agent("reply") })

            local turn = Turn.collect(history, Turn.seen_before(history, nil))

            assert.is_true(Turn.is_empty(turn))
        end)
    end)

    describe("merge", function()
        it("appends a later turn", function()
            local merged = Turn.merge({
                prompts = { "a" },
                text = "x",
                diffs = { "d1" },
                reports = {},
            }, {
                prompts = { "b" },
                text = "y",
                diffs = {},
                reports = { "r" },
            })

            assert.same({
                prompts = { "a", "b" },
                text = "x\n\ny",
                diffs = { "d1" },
                reports = { "r" },
            }, merged)
        end)
    end)
end)
