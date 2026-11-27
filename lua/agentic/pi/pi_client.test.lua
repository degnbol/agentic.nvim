--- @diagnostic disable: invisible, missing-fields
local assert = require("tests.helpers.assert")
local deferred_helper = require("tests.helpers.deferred")
local spy = require("tests.helpers.spy")

describe("agentic.pi.PiClient", function()
    local AgentClient = require("agentic.agent_client")
    local PiClient = require("agentic.pi.pi_client")
    local PiPermission = require("agentic.pi.pi_permission")
    local PiProcess = require("agentic.pi.pi_process")
    local Logger = require("agentic.utils.logger")

    --- A pi process that records each command and answers only when told.
    --- @class tests.FakePiProcess
    --- @field opts agentic.pi.PiProcess.Opts
    --- @field requests { command: table, callback: fun(data: table|nil, err: table|nil) }[]
    --- @field ui_responses { id: string, response: table }[]
    --- @field stopped boolean
    --- @field exit_waiters fun()[]
    --- @field request fun(self: tests.FakePiProcess, command: table, callback: function)
    --- @field respond_ui fun(self: tests.FakePiProcess, id: string, response: table)
    --- @field stop fun(self: tests.FakePiProcess, on_exit: fun()|nil)

    --- @type tests.FakePiProcess[]
    local processes
    --- @type tests.helpers.Deferred
    local deferred
    --- @type TestStub
    local new_stub
    --- @type TestStub
    local notify_stub
    --- @type TestStub
    local system_stub
    --- @type TestStub
    local defer_stub
    --- @type fun()[]
    local timers
    --- @type agentic.pi.PiClient
    local client

    before_each(function()
        deferred = deferred_helper.capture()
        processes = {}
        timers = {}
        new_stub = spy.stub(PiProcess, "new")
        new_stub:invokes(function(_self, opts)
            --- @type tests.FakePiProcess
            local process = {
                opts = opts,
                requests = {},
                ui_responses = {},
                stopped = false,
                exit_waiters = {},
            }
            function process:request(command, callback)
                table.insert(
                    self.requests,
                    { command = command, callback = callback }
                )
            end
            function process:respond_ui(id, response)
                table.insert(
                    self.ui_responses,
                    { id = id, response = response }
                )
            end
            function process:stop(on_exit)
                self.stopped = true
                table.insert(self.exit_waiters, on_exit)
            end
            table.insert(processes, process)
            return process
        end)
        notify_stub = spy.stub(Logger, "notify")
        system_stub = spy.stub(vim, "system")
        defer_stub = spy.stub(vim, "defer_fn")
        defer_stub:invokes(function(fn)
            table.insert(timers, fn)
        end)
        client = PiClient:new(
            { command = "pi", args = {}, env = {} },
            function() end
        )
        deferred.drain()
    end)

    after_each(function()
        defer_stub:revert()
        system_stub:revert()
        notify_stub:revert()
        new_stub:revert()
        deferred.revert()
    end)

    --- The oldest unanswered request of `process` of type `type`.
    --- @param process tests.FakePiProcess
    --- @param type string
    --- @return { command: table, callback: function }
    local function take(process, type)
        for i, request in ipairs(process.requests) do
            if request.command.type == type then
                table.remove(process.requests, i)
                return request
            end
        end
        error("no " .. type .. " request")
    end

    --- Answer the setup requests of `process`.
    --- @param process tests.FakePiProcess
    --- @param session_id string
    local function answer_setup(process, session_id)
        take(process, "get_state").callback({
            sessionId = session_id,
            model = { provider = "litellm", id = "glm-5.3" },
            thinkingLevel = "medium",
        })
        take(process, "get_available_models").callback({
            models = {
                { provider = "litellm", id = "glm-5.3", name = "GLM" },
                { provider = "litellm", id = "kimi-k3", name = "Kimi" },
            },
        })
        take(process, "get_available_thinking_levels").callback({
            levels = { "off", "medium", "high" },
        })
        take(process, "get_commands").callback({
            commands = { { name = "skill:review", description = "Review" } },
        })
    end

    --- Handlers that record what they get, in order.
    --- @return agentic.AgentClient.ClientHandlers handlers
    --- @return table[] log
    local function recording()
        local log = {}
        --- @type agentic.AgentClient.ClientHandlers
        local handlers = {
            on_session_update = function(update)
                table.insert(log, { "update", update })
            end,
            on_tool_call = function(block)
                table.insert(log, { "tool_call", block })
            end,
            on_tool_call_update = function(update)
                table.insert(log, { "tool_call_update", update })
            end,
            on_request_permission = function(request, callback)
                table.insert(log, { "permission", request, callback })
            end,
            on_turn_state = function(state)
                table.insert(log, { "turn", state })
            end,
            on_prompt_taken = function()
                table.insert(log, { "taken" })
            end,
            on_disconnect = function()
                table.insert(log, { "disconnect" })
            end,
        }
        return handlers, log
    end

    --- The entries of `log` named `name`.
    --- @param log table[]
    --- @param name string
    --- @return table[]
    local function named(log, name)
        return vim.tbl_filter(function(entry)
            return entry[1] == name
        end, log)
    end

    --- A created session "s1".
    --- @return tests.FakePiProcess process
    --- @return table[] log
    local function created()
        local handlers, log = recording()
        client:create_session("/w", handlers, function() end)
        local process = processes[#processes]
        answer_setup(process, "s1")
        return process, log
    end

    --- @param process tests.FakePiProcess
    --- @param events table[]
    local function emit(process, events)
        for _, event in ipairs(events) do
            process.opts.on_event(event)
        end
    end

    local USER = { type = "message_start", message = { role = "user" } }
    local ASSISTANT =
        { type = "message_start", message = { role = "assistant" } }

    it("starts pi in the session's cwd with the extension", function()
        local result
        client:create_session("/w", recording(), function(r)
            result = r
        end)
        local process = processes[1]
        assert.equal("/w", process.opts.cwd)
        assert.same({ "--mode", "rpc", "--extension" }, {
            unpack(process.opts.args, 1, 3),
        })
        assert.is_true(process.opts.args[4]:match("/pi/agentic%.ts$") ~= nil)
        answer_setup(process, "s1")
        assert.equal("s1", result.sessionId)
        local model = result.configOptions[1]
        assert.equal("litellm/glm-5.3", model.currentValue)
        assert.equal("litellm/kimi-k3", model.options[2].value)
        assert.equal("medium", result.configOptions[2].currentValue)
    end)

    it("advertises pi's commands", function()
        local _, log = created()
        local update = named(log, "update")[1][2]
        assert.equal("available_commands_update", update.sessionUpdate)
        assert.equal("skill:review", update.availableCommands[1].name)
    end)

    it("runs a turn with text, thinking and a bash call", function()
        local process, log = created()
        local answered
        client:send_prompt(
            "s1",
            { { type = "text", text = "hi" } },
            function(r, e)
                answered = { r, e }
            end
        )
        local prompt = take(process, "prompt")
        assert.equal("hi", prompt.command.message)
        assert.equal("followUp", prompt.command.streamingBehavior)
        prompt.callback({ disposition = "started" })
        emit(process, {
            { type = "agent_start" },
            USER,
            ASSISTANT,
            {
                type = "message_update",
                assistantMessageEvent = {
                    type = "thinking_delta",
                    delta = "hm",
                },
            },
            {
                type = "message_update",
                assistantMessageEvent = { type = "text_delta", delta = "ok" },
            },
            {
                type = "tool_execution_start",
                toolCallId = "c1",
                toolName = "bash",
                args = { command = "ls" },
            },
            {
                type = "tool_execution_end",
                toolCallId = "c1",
                toolName = "bash",
                isError = false,
                durationMs = 2,
                result = { content = { { type = "text", text = "a" } } },
            },
            {
                type = "message_end",
                message = { role = "assistant", stopReason = "stop" },
            },
            { type = "agent_settled", aborted = false },
        })
        assert.same({ { disposition = "started" } }, { answered[1] })
        local kinds = vim.tbl_map(function(entry)
            local update = entry[2]
            return entry[1] == "update" and update.sessionUpdate
                or entry[1] == "turn" and "turn:" .. update.state
                or entry[1]
        end, log)
        assert.same({
            "available_commands_update",
            "turn:running",
            "taken",
            "agent_thought_chunk",
            "agent_message_chunk",
            "tool_call",
            "tool_call_update",
            "turn:idle",
        }, kinds)
        local chunk = named(log, "update")[3][2]
        assert.equal("s1:1", chunk.messageId)
        assert.equal("end_turn", named(log, "turn")[2][2].stop_reason)

        take(process, "get_session_stats").callback({
            cost = 0.5,
            contextUsage = { tokens = 100, contextWindow = 1000 },
        })
        local usage = log[#log][2]
        assert.same({
            sessionUpdate = "usage_update",
            used = 100,
            size = 1000,
            cost = { amount = 0.5, currency = "USD" },
        }, usage)
    end)

    it("skips usage while pi has no context estimate", function()
        local process, log = created()
        client:send_prompt(
            "s1",
            { { type = "text", text = "hi" } },
            function() end
        )
        emit(process, {
            { type = "agent_start" },
            USER,
            { type = "agent_settled", aborted = false },
        })
        local count = #log
        take(process, "get_session_stats").callback({
            contextUsage = { tokens = vim.NIL, contextWindow = 1000 },
        })
        assert.equal(count, #log)
    end)

    it("ends a turn when a prompt sent mid-turn is taken in", function()
        local process, log = created()
        client:send_prompt(
            "s1",
            { { type = "text", text = "a" } },
            function() end
        )
        emit(process, { { type = "agent_start" }, USER })
        client:send_prompt(
            "s1",
            { { type = "text", text = "b" } },
            function() end
        )
        emit(process, {
            {
                type = "message_end",
                message = { role = "assistant", stopReason = "stop" },
            },
            USER,
        })
        local turns = named(log, "turn")
        assert.equal(3, #turns)
        assert.same(
            { state = "idle", stop_reason = "end_turn", more = true },
            turns[2][2]
        )
        assert.equal("running", turns[3][2].state)
        assert.equal(2, #named(log, "taken"))
    end)

    it(
        "shows a multi-replacement edit's diff before asking, then rejects",
        function()
            local dir = vim.fn.tempname()
            vim.fn.mkdir(dir, "p")
            vim.fn.writefile({ "one", "two", "three" }, dir .. "/f.txt")
            local handlers, log = recording()
            client:create_session(dir, handlers, function() end)
            local process = processes[1]
            answer_setup(process, "s1")

            process.opts.on_ui_request({
                type = "extension_ui_request",
                id = "u1",
                method = "select",
                title = PiPermission.TITLE_PREFIX
                    .. vim.json.encode({
                        toolCallId = "c1",
                        toolName = "edit",
                        input = {
                            path = "f.txt",
                            edits = {
                                { oldText = "one", newText = "1" },
                                { oldText = "three", newText = "3" },
                            },
                        },
                    }),
                options = PiPermission.OPTION_IDS,
            })
            vim.fs.rm(dir, { recursive = true })

            local update = named(log, "tool_call_update")[1][2]
            assert.same({
                old = { "one", "two", "three" },
                new = { "1", "two", "3" },
            }, update.diff)
            local permission = named(log, "permission")[1]
            assert.equal(dir .. "/f.txt", permission[2].toolCall.rawInput.path)
            permission[3]("reject_once")
            assert.same(
                { { id = "u1", response = { value = "reject_once" } } },
                process.ui_responses
            )
            assert.equal(1, #named(log, "tool_call_update"))
        end
    )

    it("takes a handled prompt in a turn of its own", function()
        local process, log = created()
        local answered
        client:send_prompt("s1", { { type = "text", text = "/x" } }, function(r)
            answered = r
        end)
        take(process, "prompt").callback({ disposition = "handled" })
        assert.same({ disposition = "handled" }, answered)
        assert.equal(1, #named(log, "taken"))
        local turns = named(log, "turn")
        assert.equal("running", turns[1][2].state)
        assert.equal("idle", turns[2][2].state)
    end)

    it("returns a rejected prompt with pi's error", function()
        local process, log = created()
        local err
        client:send_prompt(
            "s1",
            { { type = "text", text = "x" } },
            function(_, e)
                err = e
            end
        )
        take(process, "prompt").callback(nil, {
            code = AgentClient.ERROR_CODES.INTERNAL_ERROR,
            message = "No API key",
        })
        assert.equal("No API key", err.message)
        assert.same({}, named(log, "taken"))
    end)

    it("fails an audio prompt without sending it", function()
        local process = created()
        local err
        client:send_prompt(
            "s1",
            { { type = "audio", data = "", mimeType = "a" } },
            function(_, e)
                err = e
            end
        )
        deferred.drain()
        assert.equal(AgentClient.ERROR_CODES.INVALID_PARAMS, err.code)
        assert.equal(0, #vim.tbl_filter(function(r)
            return r.command.type == "prompt"
        end, process.requests))
    end)

    it("clears the queue before aborting and cancels queued prompts", function()
        local process = created()
        local errs = {}
        for _, prompt in ipairs({
            { "a", "started" },
            { "b", "queued" },
            { "c", "started" },
        }) do
            client:send_prompt(
                "s1",
                { { type = "text", text = prompt[1] } },
                function(_, e)
                    table.insert(errs, e or false)
                end
            )
            take(process, "prompt").callback({ disposition = prompt[2] })
        end
        -- "c" is still in pi's preflight: pi may take it in after the abort.
        emit(process, { { type = "agent_start" }, USER })
        client:stop_generation("s1")
        assert.same(
            { "clear_queue" },
            vim.tbl_map(function(r)
                return r.command.type
            end, process.requests)
        )
        take(process, "clear_queue").callback({ followUp = { "b" } })
        assert.equal(2, #errs)
        assert.is_false(errs[1])
        assert.equal(AgentClient.ERROR_CODES.REQUEST_CANCELLED, errs[2].code)
        take(process, "abort")
        emit(process, { USER })
        assert.equal(3, #errs)
        assert.is_false(errs[3])
    end)

    it("refuses a second process for a session already open", function()
        local handlers = recording()
        local results = {}
        for _ = 1, 2 do
            client:load_session("s1", "/w", nil, handlers, function(r, e)
                table.insert(results, { r, e })
            end)
        end
        answer_setup(processes[2], "s1")
        answer_setup(processes[1], "s1")
        assert.equal("s1", results[1][1].sessionId)
        assert.equal(AgentClient.ERROR_CODES.INTERNAL_ERROR, results[2][2].code)
        assert.is_true(processes[1].stopped)
        assert.is_false(processes[2].stopped)
        assert.equal(handlers, client.subscribers.s1)
    end)

    it("fails a load that pi never answers, without a disconnect", function()
        local handlers, log = recording()
        local err
        client:load_session("s9", "/w", nil, handlers, function(_, e)
            err = e
        end)
        local process = processes[1]
        assert.same({ "--session", "s9" }, { unpack(process.opts.args, 5, 6) })
        timers[#timers]()
        assert.equal(AgentClient.ERROR_CODES.TRANSPORT_ERROR, err.code)
        assert.is_true(process.stopped)
        assert.is_nil(client.subscribers.s9)
        process.opts.on_exit(nil)
        assert.same({}, named(log, "disconnect"))
    end)

    it("stops the process of a session given up during its creation", function()
        local result
        client:create_session("/w", recording(), function(r)
            result = r
            client:unsubscribe("s1")
        end)
        local process = processes[1]
        answer_setup(process, "s1")
        assert.equal("s1", result.sessionId)
        assert.is_true(process.stopped)
        assert.is_nil(client.subscribers.s1)
    end)

    it("waits for a stopping process before loading its session", function()
        local process = created()
        client:unsubscribe("s1")
        client:load_session("s1", "/w", nil, recording(), function() end)
        assert.equal(1, #processes)
        process.exit_waiters[#process.exit_waiters]()
        assert.equal(2, #processes)
    end)

    it("ends the running turn, then reports a process exit", function()
        local process, log = created()
        client:send_prompt(
            "s1",
            { { type = "text", text = "a" } },
            function() end
        )
        take(process, "prompt").callback({ disposition = "started" })
        emit(process, { { type = "agent_start" }, USER })
        process.opts.on_exit(nil)
        local idle = log[#log - 1]
        assert.equal("turn", idle[1])
        assert.equal("error", idle[2].stop_reason)
        assert.equal(
            AgentClient.ERROR_CODES.TRANSPORT_ERROR,
            idle[2].error.code
        )
        assert.same({ "disconnect" }, log[#log])
        assert.is_nil(client.subscribers.s1)
    end)

    it("rejects a call with invalid arguments before it runs", function()
        local process, log = created()
        emit(process, {
            {
                type = "tool_execution_start",
                toolCallId = "c1",
                toolName = "edit",
                args = { path = 3 },
            },
            {
                type = "tool_execution_end",
                toolCallId = "c1",
                toolName = "edit",
                isError = true,
                result = { content = { { type = "text", text = "bad" } } },
            },
        })
        local update = named(log, "tool_call_update")[1][2]
        assert.equal("bad", update.rejection)
        assert.equal("failed", update.status)
    end)

    it("sets the model and reads the thinking levels again", function()
        local process = created()
        local result
        client:set_config_option("s1", "model", "litellm/kimi-k3", function(r)
            result = r
        end)
        local set = take(process, "set_model")
        assert.equal("litellm", set.command.provider)
        assert.equal("kimi-k3", set.command.modelId)
        set.callback({ provider = "litellm", id = "kimi-k3" })
        take(process, "get_available_thinking_levels").callback({
            levels = { "off" },
        })
        take(process, "get_state").callback({ thinkingLevel = "off" })
        assert.equal("litellm/kimi-k3", result.configOptions[1].currentValue)
        assert.equal("off", result.configOptions[2].currentValue)
        assert.equal(1, #result.configOptions[2].options)
    end)
end)
