--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, param-type-mismatch, need-check-nil
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local MiniTest = require("mini.test")

local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local SessionResume = require("agentic.session_resume")
local Subagents = require("agentic.subagents")

--- The host spies a test reads.
--- @class tests.SubagentsHostSpies
--- @field sync_modified TestSpy
--- @field write_chat_row TestSpy
--- @field return_prompt TestSpy
--- @field agents_changed TestSpy

--- A host of stubs over `history`, with `overrides` replacing any of them.
--- @param history agentic.ui.ChatHistory
--- @param overrides table|nil
--- @return agentic.Subagents.Host host
--- @return tests.SubagentsHostSpies spies
local function make_host(history, overrides)
    local noop = function() end
    --- @type tests.SubagentsHostSpies
    local spies = {
        sync_modified = spy.new(noop),
        write_chat_row = spy.new(noop),
        return_prompt = spy.new(noop),
        agents_changed = spy.new(noop),
    }
    local host = vim.tbl_extend("force", {
        agent = function()
            return {
                launch_reply_task = function()
                    return nil
                end,
            }
        end,
        history = function()
            return history
        end,
        session_id = function()
            return "root"
        end,
        history_changed = noop,
        setup_buf = noop,
        write = noop,
        end_side_records = noop,
        relay = noop,
    }, spies, overrides or {}) --[[@as agentic.Subagents.Host]]
    return host, spies
end

--- @param host agentic.Subagents.Host
--- @param main_view agentic.ui.AgentView|nil
--- @return agentic.Subagents
local function make_subagents(host, main_view)
    return Subagents:new({ buf_nrs = {} }, main_view or {}, host)
end

describe("agentic.Subagents", function()
    describe("record_writer", function()
        it("gives a main-chat record the main view's writer", function()
            local writer = {}
            local subagents = make_subagents(
                (make_host(ChatHistory:new())),
                { writer = writer } --[[@as agentic.ui.AgentView]]
            )

            assert.equal(
                writer,
                subagents:record_writer({ type = "tool_call" }, true)
            )
        end)
    end)

    describe("set_config_options", function()
        --- @param model_id string
        --- @return agentic.acp.ConfigOption[]
        local function model_options(model_id)
            return {
                {
                    id = "model",
                    category = "model",
                    currentValue = model_id,
                    name = "Model",
                    options = { { value = model_id, name = model_id } },
                },
            }
        end

        local root_options = { "root's options" }

        --- Subagents with one agent `c1`, its transcript loaded unless
        --- `loaded` is false.
        --- @param open boolean
        --- @param loaded boolean|nil
        --- @return agentic.Subagents subagents
        --- @return TestSpy announce
        local function make(open, loaded)
            local host = make_host(ChatHistory:new(), {
                config_options = function()
                    return root_options
                end,
            })
            local subagents = make_subagents(host)
            local announce = spy.new(function() end)
            subagents._agents.c1 = {
                open = open,
                record_read = true,
                transcript = {
                    view = { announce_model = announce },
                    is_loaded = function()
                        return loaded ~= false
                    end,
                },
            } --[[@as agentic.Subagents.Agent]]
            return subagents, announce
        end

        it("announces a working subagent's first model", function()
            local subagents, announce = make(true)

            subagents:set_config_options("c1", model_options("m"))

            assert.spy(announce).was.called(1)
            local call = announce.calls[1]
            assert.equal(subagents._agents.c1.config_options, call[2])
            assert.equal("m", call[3])
            assert.equal(root_options, call[4])
        end)

        it("announces no later model", function()
            local subagents, announce = make(true)
            subagents:set_config_options("c1", model_options("m"))

            subagents:set_config_options("c1", model_options("n"))

            assert.spy(announce).was.called(1)
        end)

        it("announces nothing for an unloaded transcript", function()
            local subagents, announce = make(true, false)

            subagents:set_config_options("c1", model_options("m"))

            assert.spy(announce).was.called(0)
        end)

        it("announces nothing for a subagent not working", function()
            local subagents, announce = make(false)

            subagents:set_config_options("c1", model_options("m"))

            assert.spy(announce).was.called(0)
        end)
    end)

    describe("_set_open", function()
        it("sets the transcript's running", function()
            local host, spies = make_host(ChatHistory:new())
            local subagents = make_subagents(host)
            local set_running = spy.new(function() end)
            local transcript = { set_running = set_running }
            local agent = { transcript = transcript, open = false } --[[@as agentic.Subagents.Agent]]

            subagents:_set_open(agent, true)

            assert.is_true(agent.open)
            assert.spy(set_running).was.called_with(transcript, true)
            assert.spy(spies.sync_modified).was.called(1)
        end)

        it("accepts a wiped transcript", function()
            local host, spies = make_host(ChatHistory:new())
            local subagents = make_subagents(host)
            local agent = { open = true } --[[@as agentic.Subagents.Agent]]

            subagents:_set_open(agent, false)

            assert.is_false(agent.open)
            assert.spy(spies.sync_modified).was.called(1)
        end)

        it("tells the host the agents changed", function()
            local host, spies = make_host(ChatHistory:new())
            local subagents = make_subagents(host)

            subagents:_set_open(
                { open = false } --[[@as agentic.Subagents.Agent]],
                true
            )

            assert.spy(spies.agents_changed).was.called(1)
        end)
    end)

    describe("agents panel", function()
        --- @type integer[]
        local bufs
        --- @type agentic.ui.MessageWriter.SubagentInfo
        local info = { label = "x", mode = "blocking", confirmed = true }

        before_each(function()
            bufs = {}
        end)

        after_each(function()
            for _, bufnr in ipairs(bufs) do
                if vim.api.nvim_buf_is_valid(bufnr) then
                    vim.api.nvim_buf_delete(bufnr, { force = true })
                end
            end
        end)

        --- A stand-in transcript over a new buffer, listed or not.
        --- @param listed boolean
        --- @return agentic.ui.SubagentTranscript
        local function fake_transcript(listed)
            local bufnr = vim.api.nvim_create_buf(listed, true)
            table.insert(bufs, bufnr)
            local noop = function() end
            return {
                bufnr = bufnr,
                view = { status_indicator = { start = noop, stop = noop } },
                set_running = noop,
                set_context = noop,
                is_loaded = function()
                    return true
                end,
                destroy = noop,
            } --[[@as agentic.ui.SubagentTranscript]]
        end

        --- @param history agentic.ui.ChatHistory
        --- @param overrides table|nil
        --- @return agentic.Subagents subagents
        --- @return tests.SubagentsHostSpies spies
        --- @return TestSpy open_panel
        local function make(history, overrides)
            local host, spies = make_host(history, overrides)
            local open_panel = spy.new(function() end)
            local widget = {
                buf_nrs = {},
                open_panel = open_panel,
                buffer_name = function(_, child_id)
                    return "agentic://c1/" .. child_id
                end,
            }
            return Subagents:new(widget, {}, host), spies, open_panel
        end

        describe("entries", function()
            it("lists working and listed agents in start order", function()
                local history = ChatHistory:new()
                history:add_message({
                    type = "tool_call",
                    tool_call_id = "b",
                    kind = "SubAgent",
                    subagent = info,
                })
                history:add_message({
                    type = "subagent_end",
                    state = "cancelled",
                    agent_key = "b",
                })
                local subagents = make(history)
                subagents._agents = {
                    a = { open = true, transcript = fake_transcript(false) },
                    b = { open = false, transcript = fake_transcript(true) },
                    c = { open = false, transcript = fake_transcript(true) },
                    d = { open = false, transcript = fake_transcript(false) },
                    e = { open = true },
                }
                subagents._order = { "c", "a", "b", "d", "e" }

                local entries = subagents:entries()

                assert.same({
                    {
                        child_id = "c",
                        state = "ended",
                        name = "agentic://c1/c",
                    },
                    {
                        child_id = "a",
                        state = "working",
                        name = "agentic://c1/a",
                    },
                    {
                        child_id = "b",
                        state = "interrupted",
                        subagent = info,
                        name = "agentic://c1/b",
                    },
                    {
                        child_id = "e",
                        state = "working",
                        name = "agentic://c1/e",
                    },
                }, entries)
            end)
        end)

        it("orders transcripts from history by their blocks", function()
            local history = ChatHistory:new()
            for _, id in ipairs({ "z", "y" }) do
                history:set_subagent_task(id, nil)
                history:add_message({
                    type = "tool_call",
                    tool_call_id = id,
                    kind = "SubAgent",
                    subagent = info,
                })
            end
            local subagents = make(history)
            subagents._new_transcript = function()
                local transcript = fake_transcript(true)
                transcript.unload = function() end
                return transcript
            end

            subagents:add_history_transcripts()

            assert.same({ "z", "y" }, subagents._order)
        end)

        it("tells the host on reset", function()
            local subagents, spies = make(ChatHistory:new())
            subagents:reset()
            assert.spy(spies.agents_changed).was.called(1)
        end)

        it("tells the host once a working agent's end row is in", function()
            local write_row_stub = spy.stub(SessionResume, "write_row")
            MiniTest.finally(function()
                write_row_stub:revert()
            end)
            --- @type agentic.Subagents
            local subagents
            --- @type string[]
            local seen = {}
            subagents = make(ChatHistory:new(), {
                agents_changed = function()
                    table.insert(seen, subagents:entries()[1].state)
                end,
            })
            local transcript = fake_transcript(true)
            local noop = function() end
            transcript.view = {
                writer = {
                    stamp_open_calls = function()
                        return {}
                    end,
                },
                status_indicator = { stop = noop, reposition = noop },
            }
            subagents._agents.c1 = { open = true, transcript = transcript }
            subagents._order = { "c1" }

            subagents:end_agent("c1", { state = "failed" })

            assert.equal("failed", seen[#seen])
        end)

        describe("start", function()
            local original_auto_open

            before_each(function()
                original_auto_open = Config.windows.agents.auto_open
            end)

            after_each(function()
                Config.windows.agents.auto_open = original_auto_open
            end)

            --- Subagents with `c1` not working, its transcript unlisted.
            --- @return agentic.Subagents subagents
            --- @return TestSpy open_panel
            --- @return integer bufnr
            local function make_closed()
                local subagents, _, open_panel = make(ChatHistory:new(), {
                    agent = function()
                        return {}
                    end,
                })
                local transcript = fake_transcript(false)
                subagents._agents.c1 = { open = false, transcript = transcript }
                return subagents, open_panel, transcript.bufnr
            end

            it("lists the transcript and opens the panel", function()
                Config.windows.agents.auto_open = true
                local subagents, open_panel, bufnr = make_closed()

                subagents:_start_agent("c1", false)

                assert.is_true(vim.bo[bufnr].buflisted)
                assert.spy(open_panel).was.called(1)
                assert.equal("agents", open_panel.calls[1][2])
            end)

            it("opens no panel in a replay", function()
                Config.windows.agents.auto_open = true
                local subagents, open_panel, bufnr = make_closed()

                subagents:_start_agent("c1", true)

                assert.is_true(vim.bo[bufnr].buflisted)
                assert.spy(open_panel).was.called(0)
            end)

            it("opens no panel without auto_open", function()
                Config.windows.agents.auto_open = false
                local subagents, open_panel = make_closed()

                subagents:_start_agent("c1", false)

                assert.spy(open_panel).was.called(0)
            end)
        end)
    end)

    describe("return of a subagent message", function()
        --- Subagents with a background subagent `c1` whose message input is
        --- buffer 42, and the `on_returned` the relay was given.
        --- @return agentic.Subagents subagents
        --- @return tests.SubagentsHostSpies spies
        --- @return { on_returned: fun(reason: agentic.ReturnReason)|nil } relayed
        local function make_relaying()
            local history = ChatHistory:new()
            history:add_message({
                type = "tool_call",
                tool_call_id = "c1",
                kind = "SubAgent",
                status = "completed",
                subagent = {
                    label = "x",
                    mode = "background",
                    confirmed = false,
                },
            })
            local relayed = {}
            local host, spies = make_host(history, {
                agent = function()
                    return {
                        subagent_message_instruction = function(_, _, _, text)
                            return "relay: " .. text
                        end,
                    }
                end,
                relay = function(_instruction, on_returned)
                    relayed.on_returned = on_returned
                    return nil
                end,
            })
            local subagents = make_subagents(host)
            subagents._inputs = { c1 = { bufnr = 42 } }
            return subagents, spies, relayed
        end

        it("returns it to the subagent's input, as a draft", function()
            for _, reason in ipairs({ "refusal", "usage_limit" }) do
                local subagents, spies, relayed = make_relaying()

                assert.is_true(subagents:_relay_to_agent("c1", "hi"))
                relayed.on_returned(reason)

                assert.is_true(
                    spies.return_prompt:called_with("hi", 42, reason)
                )
            end
        end)

        it("returns it to the main input once that is gone", function()
            local subagents, spies, relayed = make_relaying()

            subagents:_relay_to_agent("c1", "hi")
            subagents._inputs.c1 = nil
            relayed.on_returned("refusal")

            assert.equal(1, spies.return_prompt.call_count)
            assert.equal("hi", spies.return_prompt.calls[1][1])
            assert.is_nil(spies.return_prompt.calls[1][2])
        end)
    end)

    describe("message", function()
        --- @type TestStub
        local write_row_stub

        before_each(function()
            write_row_stub = spy.stub(SessionResume, "write_row")
        end)

        after_each(function()
            write_row_stub:revert()
        end)

        --- @param message_id string
        --- @return agentic.acp.SessionMessage
        local function view(message_id)
            return {
                sessionUpdate = "session_message",
                messageId = message_id,
                senderSessionId = "root",
                recipientSessionId = "c1",
                content = { { type = "text", text = "go" } },
            }
        end

        it("sends a root view to the main chat", function()
            local host, spies = make_host(ChatHistory:new())
            local subagents = make_subagents(host)
            subagents._agents.c1 = { open = true, record_read = true }

            subagents:message(view("m1"), "root")

            assert.equal(1, spies.write_chat_row.call_count)
            local row = spies.write_chat_row.calls[1][1]
            assert.equal("m1", row.message_id)
            assert.equal("sent", row.view)
            assert.equal(0, write_row_stub.call_count)
        end)

        it("writes a subagent view to its transcript", function()
            local history = ChatHistory:new()
            local host, spies = make_host(history)
            local subagents = make_subagents(host)
            local transcript = {
                view = {
                    writer = {},
                    status_indicator = { reposition = function() end },
                },
            }
            subagents._agents.c1 = { open = true, record_read = true }
            subagents.transcript = function()
                return transcript
            end

            subagents:message(view("m1"), "c1")

            assert.equal(0, spies.write_chat_row.call_count)
            assert.equal(1, write_row_stub.call_count)
            assert.equal(transcript.view.writer, write_row_stub.calls[1][1])
            -- The delegation's message id became c1's task id, its key.
            local row = history:messages_for_agent("m1")[1]
            assert.equal("received", row.view)
        end)
    end)

    describe("launch settling", function()
        --- @type TestStub
        local write_row_stub

        before_each(function()
            write_row_stub = spy.stub(SessionResume, "write_row")
        end)

        after_each(function()
            write_row_stub:revert()
        end)

        --- Subagents with `c1`, launched by Task `toolu_1` from the root and
        --- not working, its block `pending`, under an agent whose replies
        --- are `<task id>:reply`.
        --- @return agentic.Subagents subagents
        --- @return agentic.ui.ChatHistory history
        --- @return tests.SubagentsHostSpies spies
        local function make_launched()
            local history = ChatHistory:new()
            history:add_message({
                type = "tool_call",
                tool_call_id = "c1",
                kind = "SubAgent",
                status = "pending",
                subagent = { label = "x", mode = "blocking", confirmed = true },
            })
            local host, spies = make_host(history, {
                agent = function()
                    return {
                        launch_reply_task = function(_, update)
                            return update.messageId:match("^(.+):reply$")
                        end,
                    }
                end,
            })
            local subagents = make_subagents(
                host,
                { writer = { tool_call_blocks = {} } } --[[@as agentic.ui.AgentView]]
            )
            subagents._agents.c1 = {
                open = false,
                record_read = true,
                parent_session_id = "root",
            }
            subagents._agent_by_task.toolu_1 = "c1"
            return subagents, history, spies
        end

        --- @param message_id string
        --- @return agentic.acp.SessionMessage
        local function result(message_id)
            return {
                sessionUpdate = "session_message",
                messageId = message_id,
                senderSessionId = "c1",
                recipientSessionId = "root",
                content = { { type = "text", text = "Found it." } },
            }
        end

        it(
            "settles the block on the launch's reply, and flags its row",
            function()
                local subagents, history, spies = make_launched()

                subagents:message(result("toolu_1:reply"), "root")

                assert.equal("completed", history:tool_call("c1").status)
                local row = spies.write_chat_row.calls[1][1]
                assert.equal("result", row.kind)
                assert.is_true(row.launch_reply)
            end
        )

        it("leaves the block pending on a hand-back", function()
            local subagents, history, spies = make_launched()

            subagents:message(result("toolu_h"), "root")

            assert.equal("pending", history:tool_call("c1").status)
            assert.is_nil(spies.write_chat_row.calls[1][1].launch_reply)
        end)

        it("settles the block at any end of an agent not open", function()
            for _, state in ipairs({
                { state = "idle", stopReason = "end_turn" },
                { state = "unknown" },
            }) do
                local subagents, history = make_launched()

                subagents:end_agent("c1", state)

                assert.equal("completed", history:tool_call("c1").status)
            end
        end)

        it("settles the block at a working agent's failed end", function()
            local subagents, history = make_launched()
            subagents._agents.c1.open = true
            local transcript = {
                view = {
                    writer = {
                        stamp_open_calls = function()
                            return {}
                        end,
                    },
                    status_indicator = {
                        stop = function() end,
                        reposition = function() end,
                    },
                },
                set_running = function() end,
                set_context = function() end,
            }
            subagents.transcript = function()
                return transcript
            end

            subagents:end_agent("c1", { state = "failed" })

            assert.equal("completed", history:tool_call("c1").status)
        end)

        it("settles once", function()
            local subagents, history = make_launched()
            local merge = spy.on(subagents, "_merge_block_fields")

            subagents:message(result("toolu_1:reply"), "root")
            subagents:end_agent("c1", { state = "unknown" })

            assert.equal(1, merge.call_count)
            assert.equal("completed", history:tool_call("c1").status)
            merge:revert()
        end)
    end)

    describe("seed_message_infos", function()
        it("takes the saved kinds and marks recipients delegated", function()
            local history = ChatHistory:new()
            for _, msg in ipairs({
                {
                    message_id = "m1",
                    kind = "task",
                    summary = "Find",
                    recipient_session_id = "c1",
                },
                {
                    message_id = "m2",
                    kind = "result",
                    recipient_session_id = "root",
                    agent_key = "c1",
                },
            }) do
                msg.type = "session_message"
                history:add_message(msg)
            end
            local subagents = make_subagents(make_host(ChatHistory:new()))

            subagents:seed_message_infos(history)

            assert.same(
                { kind = "task", summary = "Find" },
                subagents._message_infos.m1
            )
            assert.same({ kind = "result" }, subagents._message_infos.m2)
            assert.same({ c1 = true }, subagents._delegated)
        end)
    end)

    describe("_message_info", function()
        --- Subagents of the main agent `root`: its child `c1` and that
        --- child's child `c2`, and a sibling `c3` of `c1`.
        --- @return agentic.Subagents
        --- @return agentic.ui.ChatHistory
        local function make_session()
            local history = ChatHistory:new()
            local subagents = make_subagents(make_host(history))
            subagents._agents = {
                c1 = {
                    open = false,
                    record_read = true,
                    parent_session_id = "root",
                    description = "Find the files",
                },
                c2 = {
                    open = false,
                    record_read = true,
                    parent_session_id = "c1",
                },
                c3 = {
                    open = false,
                    record_read = true,
                    parent_session_id = "root",
                },
            }
            return subagents, history
        end

        --- Add a row of type `type` to c1's history.
        --- @param history agentic.ui.ChatHistory
        --- @param type string
        local function add_c1_row(history, type)
            history:add_message({
                type = type,
                state = "completed",
                text = "x",
                provider_name = "p",
                agent_key = "c1",
            })
        end

        it("classes the first delegation to an agent a task", function()
            local subagents = make_session()

            assert.equal(
                "task",
                subagents:_message_info("m1", "root", "c1").kind
            )
        end)

        it(
            "summarises only the first delegation, by the agent's description",
            function()
                local subagents, history = make_session()

                local first = subagents:_message_info("m1", "root", "c1")
                assert.equal("Find the files", first.summary)
                -- Its second view keeps the summary.
                assert.equal(
                    "Find the files",
                    subagents:_message_info("m1", "root", "c1").summary
                )

                add_c1_row(history, "subagent_end")
                local later = subagents:_message_info("m2", "root", "c1")
                assert.equal("task", later.kind)
                assert.is_nil(later.summary)
            end
        )

        it("classes a later delegation to a working agent a message", function()
            local subagents, history = make_session()
            subagents:_message_info("m1", "root", "c1")
            add_c1_row(history, "agent")

            assert.equal(
                "message",
                subagents:_message_info("m2", "root", "c1").kind
            )
        end)

        it("classes a delegation after an end row a task", function()
            local subagents, history = make_session()
            subagents:_message_info("m1", "root", "c1")
            add_c1_row(history, "subagent_end")

            assert.equal(
                "task",
                subagents:_message_info("m2", "root", "c1").kind
            )
            -- Its received row now follows the end.
            add_c1_row(history, "session_message")
            assert.equal(
                "message",
                subagents:_message_info("m3", "root", "c1").kind
            )
        end)

        it("classes a delegation after a saved end row a task", function()
            -- After a load, the history and the delegations come from the file.
            local subagents, history = make_session()
            subagents._delegated.c1 = true
            add_c1_row(history, "subagent_end")

            assert.equal(
                "task",
                subagents:_message_info("m1", "root", "c1").kind
            )
        end)

        it("classes a child's message to its parent a result", function()
            local subagents = make_session()

            assert.equal(
                "result",
                subagents:_message_info("m1", "c1", "root").kind
            )
            assert.equal(
                "result",
                subagents:_message_info("m2", "c2", "c1").kind
            )
            assert.is_nil(subagents._delegated.root)
        end)

        it("classes a message to a sibling a delegation to it", function()
            local subagents = make_session()

            assert.equal("task", subagents:_message_info("m1", "c1", "c3").kind)
            assert.equal(
                "message",
                subagents:_message_info("m2", "c1", "c3").kind
            )
        end)

        it("classes a message to an unknown session a message", function()
            local subagents = make_session()

            assert.equal(
                "message",
                subagents:_message_info("m1", "c1", "x").kind
            )
            assert.equal(
                "message",
                subagents:_message_info("m2", nil, nil).kind
            )
        end)

        it("reuses the kind decided at the first view", function()
            local subagents = make_session()
            assert.equal(
                "task",
                subagents:_message_info("m1", "root", "c1").kind
            )

            -- The second view keeps its kind, where a new message would not.
            assert.equal(
                "task",
                subagents:_message_info("m1", "root", "c1").kind
            )
            assert.equal(
                "message",
                subagents:_message_info("m2", "root", "c1").kind
            )
        end)
    end)
end)
