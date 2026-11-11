--- @diagnostic disable: invisible, missing-fields
local assert = require("tests.helpers.assert")
local deferred_helper = require("tests.helpers.deferred")
local spy = require("tests.helpers.spy")

describe("agentic.BackgroundSession", function()
    local AgentInstance = require("agentic.acp.agent_instance")
    local BackgroundSession = require("agentic.background_session")
    local ChatHistory = require("agentic.ui.chat_history")
    local ChatWidget = require("agentic.ui.chat_widget")
    local Logger = require("agentic.utils.logger")
    local SessionRegistry = require("agentic.session_registry")

    --- A client that records each request and answers only when told.
    --- @class tests.FakeClient
    --- @field handlers? agentic.acp.ClientHandlers
    --- @field on_created? fun(result: table|nil, err: table|nil)
    --- @field prompts { text: string, callback: fun(result: table|nil, err: table|nil) }[]
    --- @field config_sets { id: string, value: string }[]
    --- @field model_sets string[]
    --- @field stops string[]
    --- @field closes string[]
    local client

    --- @type tests.helpers.Deferred
    local deferred
    --- @type TestStub
    local instance_stub
    --- @type TestStub
    local notify_stub
    --- @type TestStub
    local defer_stub
    --- @type TestStub
    local save_stub
    --- @type { fn: fun(), timer: table }[]
    local timers
    --- @type agentic.ui.ChatWidget
    local widget
    --- @type agentic.BackgroundSession[]
    local sessions
    local owner_id = 5240

    before_each(function()
        deferred = deferred_helper.capture()
        timers = {}
        sessions = {}
        client = {
            provider_config = { name = "OpenCode" },
            prompts = {},
            config_sets = {},
            model_sets = {},
            stops = {},
            closes = {},
        }
        function client:create_session(_cwd, handlers, callback)
            self.handlers = handlers
            self.on_created = callback
        end
        function client:send_prompt(_sid, prompt, callback)
            table.insert(
                self.prompts,
                { text = prompt[1].text, callback = callback }
            )
        end
        function client:set_config_option(_sid, id, value, callback)
            table.insert(self.config_sets, { id = id, value = value })
            callback({}, nil)
        end
        function client:set_model(_sid, model, callback)
            table.insert(self.model_sets, model)
            callback({}, nil)
        end
        function client:stop_generation(sid)
            table.insert(self.stops, sid)
        end
        function client:close_session(sid, on_closed)
            table.insert(self.closes, sid)
            on_closed()
        end

        instance_stub = spy.stub(AgentInstance, "get_instance")
        instance_stub:invokes(function(_provider, on_ready)
            on_ready(client)
            return client
        end)
        notify_stub = spy.stub(Logger, "notify")
        save_stub = spy.stub(ChatHistory, "save")
        defer_stub = spy.stub(vim, "defer_fn")
        defer_stub:invokes(function(fn)
            local timer = {
                is_closing = function()
                    return false
                end,
                stop = function() end,
                close = function() end,
            }
            table.insert(timers, { fn = fn, timer = timer })
            return timer
        end)

        owner_id = owner_id + 1
        widget = ChatWidget:new(owner_id, function()
            return true
        end)
    end)

    after_each(function()
        for _, session in ipairs(sessions) do
            session:destroy()
        end
        widget:destroy()
        defer_stub:revert()
        save_stub:revert()
        notify_stub:revert()
        instance_stub:revert()
        deferred.revert()
    end)

    --- @param overrides table|nil
    --- @return agentic.BackgroundSession|nil
    local function new_session(overrides)
        --- @type agentic.BackgroundSession.Opts
        local opts = vim.tbl_extend("force", {
            provider = "opencode-acp",
            label = "skeptic",
            cwd = vim.fn.getcwd(),
            widget = widget,
            get_config_dir = function()
                return vim.fn.tempname()
            end,
            turn_timeout_ms = 1000,
            max_refusals = 1,
            refusal_text = "Refused:\n%s",
        }, overrides or {}) --[[@as agentic.BackgroundSession.Opts]]
        local session = BackgroundSession:new(opts)
        if session then
            table.insert(sessions, session)
        end
        deferred.drain()
        return session
    end

    --- Answer session/new.
    --- @param config_options table[]|nil
    local function create(config_options)
        client.on_created({ sessionId = "bg-1", configOptions = config_options })
    end

    --- Answer the latest prompt.
    --- @param err table|nil
    local function answer(err)
        client.prompts[#client.prompts].callback(
            err == nil and { stopReason = "end_turn" } or nil,
            err
        )
    end

    --- @param text string
    local function message(text)
        client.handlers.on_session_update({
            sessionUpdate = "agent_message_chunk",
            content = { type = "text", text = text },
        })
    end

    --- @param id string
    --- @param command string
    --- @return agentic.acp.RequestPermission
    local function shell_request(id, command)
        return {
            sessionId = "bg-1",
            toolCall = {
                toolCallId = id,
                kind = "execute",
                rawInput = { command = command },
            },
            options = {
                { optionId = "once", kind = "allow_once", name = "Allow" },
                { optionId = "no", kind = "reject_once", name = "Reject" },
            },
        }
    end

    --- Record what `on_done` gets.
    --- @return { text: string|nil, err: string|nil }[] results
    --- @return agentic.BackgroundSession.OnDone on_done
    local function collector()
        local results = {}
        return results,
            function(text, err)
                table.insert(results, { text = text, err = err })
            end
    end

    it("refuses another provider", function()
        assert.is_nil(new_session({ provider = "claude-agent-acp" }))
        assert.equal(1, notify_stub.call_count)
        assert.equal(0, instance_stub.call_count)
    end)

    it("asks for the unattended client", function()
        new_session()
        assert.is_true(instance_stub.calls[1][3])
    end)

    it("is nil and starts no timer without a client", function()
        instance_stub:invokes(function() end)
        assert.is_nil(new_session())
        assert.equal(0, #timers)
    end)

    it("is no registry session and saves no history", function()
        local session = new_session() --[[@as agentic.BackgroundSession]]
        create()
        local results, on_done = collector()
        session:prompt("hi", on_done)
        message("hello")
        answer()
        assert.same({ { text = "hello" } }, results)
        assert.same({}, SessionRegistry.by_id)
        assert.equal(0, save_stub.call_count)
    end)

    it("sets the model through its config option before prompting", function()
        local session = new_session({ model = "litellm/glm" }) --[[@as agentic.BackgroundSession]]
        session:prompt("hi", function() end)
        assert.equal(0, #client.prompts)
        create({ { id = "model-opt", category = "model" } })
        assert.same(
            { { id = "model-opt", value = "litellm/glm" } },
            client.config_sets
        )
        assert.equal(1, #client.prompts)
    end)

    it("sets the model by session/set_model without the option", function()
        local session = new_session({ model = "litellm/glm" }) --[[@as agentic.BackgroundSession]]
        session:prompt("hi", function() end)
        create({})
        assert.same({ "litellm/glm" }, client.model_sets)
        assert.equal(1, #client.prompts)
    end)

    it("fails queued prompts when the model set fails", function()
        function client:set_model(_sid, _model, callback)
            callback(nil, { message = "no such model" })
        end
        local session = new_session({ model = "x" }) --[[@as agentic.BackgroundSession]]
        local results, on_done = collector()
        session:prompt("hi", on_done)
        create()
        assert.same({ { err = "no such model" } }, results)
        assert.equal(0, #client.prompts)
        assert.same({ "bg-1" }, client.closes)
    end)

    describe("permissions", function()
        --- @type agentic.BackgroundSession
        local session
        local results, on_done

        before_each(function()
            session = new_session() --[[@as agentic.BackgroundSession]]
            create()
            results, on_done = collector()
            session:prompt("check", on_done)
        end)

        it("rejects and retries with the reasons", function()
            local sent = {}
            client.handlers.on_request_permission(
                shell_request("t1", "git add x"),
                function(option_id)
                    table.insert(sent, option_id)
                end
            )
            assert.same({ "no" }, sent)

            answer()
            assert.equal(2, #client.prompts)
            assert.equal(
                "Refused:\ngit add x: no allow rule matches it",
                client.prompts[2].text
            )
            message("done")
            answer()
            assert.same({ { text = "done" } }, results)
        end)

        it("approves what the read-only policy allows", function()
            local sent = {}
            client.handlers.on_request_permission(
                shell_request("t1", "cat x"),
                function(option_id)
                    table.insert(sent, option_id)
                end
            )
            assert.same({ "once" }, sent)
        end)

        it("gives up after max_refusals", function()
            for _ = 1, 2 do
                client.handlers.on_request_permission(
                    shell_request("t" .. #client.prompts, "rm y"),
                    function() end
                )
                answer()
            end
            assert.equal(2, #client.prompts)
            assert.same({ { err = "refused" } }, results)
        end)

        it("cancels a request with no reject option", function()
            local request = shell_request("t1", "rm y")
            request.options = { request.options[1] }
            local sent = {}
            client.handlers.on_request_permission(request, function(option_id)
                table.insert(sent, option_id or "cancelled")
            end)
            assert.same({ "cancelled" }, sent)
            answer()
            assert.equal(
                "Refused:\nt1: cancelled, the request offers no option to answer it",
                client.prompts[2].text
            )
        end)

        it("fails on a stop, with no refusal retry", function()
            client.handlers.on_request_permission(
                shell_request("t1", "rm y"),
                function() end
            )
            client.prompts[1].callback({ stopReason = "cancelled" }, nil)
            assert.equal(1, #client.prompts)
            assert.same({ { err = "interrupted" } }, results)
        end)
    end)

    describe("tripwire", function()
        --- @type agentic.BackgroundSession
        local session

        before_each(function()
            session = new_session() --[[@as agentic.BackgroundSession]]
            create()
            session:prompt("check", function() end)
        end)

        --- @param id string
        --- @param argument string
        --- @param status string|nil Its end; default completed
        --- @param kind string|nil Default execute
        local function run_unasked(id, argument, status, kind)
            client.handlers.on_tool_call({
                tool_call_id = id,
                kind = kind or "execute",
                status = "pending",
                argument = argument,
            })
            client.handlers.on_tool_call_update({
                tool_call_id = id,
                status = status or "completed",
            })
        end

        it("stops on an unasked write", function()
            run_unasked("t1", "rm -r src")
            assert.equal(1, notify_stub.call_count)
            assert.same({ "bg-1" }, client.closes)
        end)

        it("stops on an unasked write that failed after it ran", function()
            run_unasked("t1", "rm -r src; false", "failed")
            assert.same({ "bg-1" }, client.closes)
        end)

        it("stops on an unasked edit outside the temp dirs", function()
            run_unasked("t1", vim.fn.getcwd() .. "/README.md", nil, "edit")
            assert.same({ "bg-1" }, client.closes)
        end)

        it("ignores an unasked command the policy approves", function()
            run_unasked("t1", "cat a")
            assert.equal(0, notify_stub.call_count)
            assert.same({}, client.closes)
        end)

        it("ignores a call that asked", function()
            client.handlers.on_request_permission(
                shell_request("t1", "rm -r src"),
                function() end
            )
            run_unasked("t1", "rm -r src")
            assert.same({}, client.closes)
        end)
    end)

    describe("timeout", function()
        it(
            "stops the turn, keeps the session and ignores a late answer",
            function()
                local session = new_session() --[[@as agentic.BackgroundSession]]
                create()
                local results, on_done = collector()
                session:prompt("slow", on_done)
                local late = client.prompts[1]
                timers[#timers].fn()
                assert.same({ "bg-1" }, client.stops)
                assert.same({ { err = "timeout" } }, results)

                session:prompt("next", on_done)
                -- The cancelled turn's output counts for no job.
                message("stale")
                client.handlers.on_request_permission(
                    shell_request("t1", "rm y"),
                    function() end
                )
                assert.equal(1, #client.prompts)
                late.callback({ stopReason = "cancelled" }, nil)
                assert.equal(2, #client.prompts)
                assert.equal(1, #results)
                message("ok")
                answer()
                assert.same({ { err = "timeout" }, { text = "ok" } }, results)
                assert.same({}, client.closes)
            end
        )

        it("destroys when the cancel goes unanswered", function()
            local session = new_session() --[[@as agentic.BackgroundSession]]
            create()
            session:prompt("slow", function() end)
            timers[#timers].fn()
            timers[#timers].fn()
            assert.same({ "bg-1" }, client.closes)
        end)

        it("fails queued prompts when the start never ends", function()
            instance_stub:invokes(function()
                return client
            end)
            local session = new_session() --[[@as agentic.BackgroundSession]]
            local results, on_done = collector()
            session:prompt("hi", on_done)
            timers[1].fn()
            assert.same({ { err = "timeout" } }, results)
        end)
    end)

    describe("start and end", function()
        it("answers queued prompts with a session/new error", function()
            local session = new_session() --[[@as agentic.BackgroundSession]]
            local results, on_done = collector()
            session:prompt("hi", on_done)
            client.on_created(nil, { message = "boom" })
            assert.same({ { err = "boom" } }, results)
        end)

        it("closes a session created after its destroy", function()
            local session = new_session() --[[@as agentic.BackgroundSession]]
            session:destroy()
            create()
            assert.same({ "bg-1" }, client.closes)
        end)

        it("answers a pending prompt with closed on disconnect", function()
            local session = new_session() --[[@as agentic.BackgroundSession]]
            create()
            local results, on_done = collector()
            session:prompt("hi", on_done)
            client.handlers.on_disconnect()
            assert.same({ { err = "closed" } }, results)
        end)
    end)

    describe("transcript", function()
        --- @type agentic.BackgroundSession
        local session

        before_each(function()
            session = new_session() --[[@as agentic.BackgroundSession]]
            create()
        end)

        it("binds the stop key to the background session only", function()
            vim.api.nvim_buf_call(session.bufnr, function()
                local map = vim.fn.maparg("<C-c>", "n", false, true)
                assert.equal(1, map.buffer)
                map.callback()
            end)
            assert.same({ "bg-1" }, client.stops)
        end)

        it("destroys the session on wipeout", function()
            local results, on_done = collector()
            session:prompt("hi", on_done)
            vim.api.nvim_buf_delete(session.bufnr, { force = true })
            assert.same({ "bg-1" }, client.closes)
            assert.same({ { err = "closed" } }, results)
        end)

        it("replays the history on :e", function()
            session:prompt("question", function() end)
            message("answer text")
            answer()
            local bufnr = session.bufnr --[[@as integer]]
            vim.cmd.sbuffer(bufnr)
            vim.cmd("edit")
            vim.cmd.close()
            local text = table.concat(
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                "\n"
            )
            assert.truthy(text:find("question", 1, true))
            assert.truthy(text:find("answer text", 1, true))
        end)
    end)
end)
