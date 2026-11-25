local AgentClient = require("agentic.agent_client")
local Json = require("agentic.utils.json")
local Logger = require("agentic.utils.logger")
local PiDialogs = require("agentic.pi.pi_dialogs")
local PiPermission = require("agentic.pi.pi_permission")
local PiProcess = require("agentic.pi.pi_process")
local PiToolCalls = require("agentic.pi.pi_tool_calls")
local PiTurns = require("agentic.pi.pi_turns")
local UsageLimit = require("agentic.acp.usage_limit")

--- The pi extension that sends every tool call for a permission decision.
local EXTENSION = vim.fs.joinpath(
    assert(vim.fs.root(debug.getinfo(1, "S").source:sub(2), "lua")),
    "pi",
    "agentic.ts"
)

--- How long `load_session` waits for the resumed process to answer.
local LOAD_TIMEOUT_MS = 10000

--- A prompt sent and not yet taken in.
--- @class agentic.pi.PiClient.Prompt
--- @field callback fun(result: table|nil, err: agentic.AgentClient.Error|nil)
--- @field data? table pi's answer to the `prompt` command
--- @field done? boolean `callback` has run

--- The model and thinking level choices of a session.
--- @class agentic.pi.PiClient.Options
--- @field models table[] pi `Model` objects
--- @field model? string `<provider>/<id>` of the current model
--- @field levels string[]
--- @field level? string

--- One pi session and its process.
--- @class agentic.pi.PiClient.Session
--- @field process agentic.pi.PiProcess
--- @field cwd string
--- @field turns agentic.pi.PiTurns
--- @field message_count integer Assistant messages started
--- @field options agentic.pi.PiClient.Options

--- The client of pi in RPC mode (`pi --mode rpc`). Every session runs its own
--- pi process, so `unsubscribe` stops that process.
--- See https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md
--- @class agentic.pi.PiClient : agentic.AgentClient
--- @field _sessions table<string, agentic.pi.PiClient.Session> By session id
--- @field _stopping table<string, agentic.pi.PiProcess> Processes of given-up sessions until they exit, by session id
local PiClient = AgentClient.extend()

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.AgentClient)
--- @return agentic.pi.PiClient
function PiClient:new(config, on_ready)
    local client = setmetatable({
        state = "ready",
        subscribers = {},
        provider_config = config,
        agent_capabilities = { loadSession = true },
        agent_info = { name = "pi", version = "" },
        auth_methods = {},
        usage_limit = UsageLimit:new(function() end),
        _sessions = {},
        _stopping = {},
    }, self) --[[@as agentic.pi.PiClient]]

    -- An optional probe: a missing pi fails visibly at the first spawn.
    pcall(
        vim.system,
        { config.command or "pi", "--version" },
        { text = true },
        function(result)
            if result.code == 0 then
                client.agent_info.version = vim.trim(result.stdout or "")
            end
        end
    )
    client:when_ready(on_ready)
    return client
end

--- @param on_ready fun(client: agentic.AgentClient)
function PiClient:when_ready(on_ready)
    vim.schedule(function()
        on_ready(self)
    end)
end

--- @param on_ready fun(client: agentic.AgentClient)|nil
function PiClient:restart(on_ready)
    for session_id, subscriber in pairs(self.subscribers) do
        self:unsubscribe(session_id)
        if subscriber.on_disconnect then
            subscriber.on_disconnect()
        end
    end
    if on_ready then
        self:when_ready(on_ready)
    end
end

function PiClient:stop()
    for session_id in pairs(self._sessions) do
        self:unsubscribe(session_id)
    end
end

--- `ConfigOption`s for a session's model and thinking level.
--- @param options agentic.pi.PiClient.Options
--- @return agentic.acp.ConfigOption[]
local function config_options(options)
    --- @type agentic.acp.ConfigOption.Option[]
    local models = {}
    for _, model in ipairs(options.models) do
        table.insert(models, {
            value = model.provider .. "/" .. model.id,
            name = model.name or model.id,
            description = model.provider,
        })
    end
    --- @type agentic.acp.ConfigOption.Option[]
    local levels = {}
    for _, level in ipairs(options.levels) do
        table.insert(levels, { value = level, name = level, description = "" })
    end
    --- @type agentic.acp.ConfigOption[]
    local result = {
        {
            id = "model",
            category = "model",
            name = "Model",
            description = "",
            currentValue = options.model or "",
            options = models,
        },
        {
            id = "thought_level",
            category = "thought_level",
            name = "Thinking level",
            description = "",
            currentValue = options.level or "",
            options = levels,
        },
    }
    return result
end

--- `<provider>/<id>` of a pi `Model`.
--- @param model table|nil
--- @return string|nil
local function model_value(model)
    return model and model.provider .. "/" .. model.id or nil
end

--- Read a session's state, models, thinking levels and commands, one
--- request after another.
--- @param process agentic.pi.PiProcess
--- @param callback fun(setup: { state: table, options: agentic.pi.PiClient.Options, commands: table[] }|nil, err: agentic.AgentClient.Error|nil)
local function read_setup(process, callback)
    process:request({ type = "get_state" }, function(state, err)
        if not state then
            return callback(nil, err)
        end
        process:request(
            { type = "get_available_models" },
            function(models, err2)
                if not models then
                    return callback(nil, err2)
                end
                process:request(
                    { type = "get_available_thinking_levels" },
                    function(levels, err3)
                        if not levels then
                            return callback(nil, err3)
                        end
                        process:request(
                            { type = "get_commands" },
                            function(commands, err4)
                                if not commands then
                                    return callback(nil, err4)
                                end
                                callback({
                                    state = state,
                                    options = {
                                        models = models.models or {},
                                        model = model_value(state.model),
                                        levels = levels.levels or {},
                                        level = state.thinkingLevel,
                                    },
                                    commands = commands.commands or {},
                                }, nil)
                            end
                        )
                    end
                )
            end
        )
    end)
end

--- Start a pi process in `cwd`, read its session setup and record the
--- session. A failure stops the process, as does a session another process
--- already has open: two processes on one session file would both write it.
--- @param cwd string
--- @param extra_args string[]
--- @param timeout_ms integer|nil Fail when the setup takes longer
--- @param callback fun(session_id: string|nil, setup: table|nil, err: agentic.AgentClient.Error|nil)
function PiClient:_open(cwd, extra_args, timeout_ms, callback)
    local config = self.provider_config
    local args = { "--mode", "rpc", "--extension", EXTENSION }
    vim.list_extend(args, config.args or {})
    vim.list_extend(args, extra_args)

    --- @type string|nil
    local session_id
    local finished = false
    --- @type agentic.pi.PiProcess
    local process
    process = PiProcess:new({
        command = config.command or "pi",
        args = args,
        env = config.env or {},
        cwd = cwd,
        on_event = function(event)
            if session_id then
                self:_on_event(session_id, process, event)
            end
        end,
        on_ui_request = function(request)
            self:_on_ui_request(session_id, process, request)
        end,
        on_exit = function()
            if session_id then
                self:_on_process_exit(session_id, process)
            end
        end,
    })

    --- @param err agentic.AgentClient.Error
    local function fail(err)
        if finished then
            return
        end
        finished = true
        process:stop()
        callback(nil, nil, err)
    end

    if timeout_ms then
        vim.defer_fn(function()
            fail({
                code = AgentClient.ERROR_CODES.TRANSPORT_ERROR,
                message = "pi did not answer within "
                    .. timeout_ms / 1000
                    .. " s",
            })
        end, timeout_ms)
    end

    read_setup(process, function(setup, err)
        if not setup then
            fail(err --[[@as agentic.AgentClient.Error]])
            return
        end
        local opened_id = setup.state.sessionId
        if self._sessions[opened_id] then
            fail({
                code = AgentClient.ERROR_CODES.INTERNAL_ERROR,
                message = "pi session " .. opened_id .. " is already open",
            })
            return
        end
        if finished then
            return
        end
        finished = true
        session_id = opened_id
        self._sessions[session_id] = {
            process = process,
            cwd = cwd,
            turns = PiTurns:new(),
            message_count = 0,
            options = setup.options,
        }
        callback(session_id, setup, nil)
    end)
end

--- Give `callback` the session's creation response, then send the session's
--- commands to its subscriber as an `available_commands_update`.
--- @param session_id string
--- @param setup table
--- @param callback fun(result: table|nil, err: agentic.AgentClient.Error|nil)
function PiClient:_finish_setup(session_id, setup, callback)
    --- @type agentic.acp.SessionCreationResponse
    local result = {
        sessionId = session_id,
        configOptions = config_options(setup.options),
    }
    callback(result, nil)
    local subscriber = self.subscribers[session_id]
    if not subscriber then
        return
    end
    --- @type agentic.acp.AvailableCommand[]
    local commands = {}
    for _, command in ipairs(setup.commands) do
        table.insert(commands, {
            name = command.name,
            description = command.description or "",
        })
    end
    subscriber.on_session_update({
        sessionUpdate = "available_commands_update",
        availableCommands = commands,
    }, session_id)
end

--- @param cwd string
--- @param handlers agentic.AgentClient.ClientHandlers
--- @param callback fun(result: agentic.acp.SessionCreationResponse|nil, err: agentic.AgentClient.Error|nil)
function PiClient:create_session(cwd, handlers, callback)
    self:_open(cwd, {}, nil, function(session_id, setup, err)
        if not session_id then
            Logger.notify(
                "Failed to create session: " .. (err and err.message or ""),
                vim.log.levels.ERROR,
                { title = "🐞 Session creation error" }
            )
            callback(nil, err)
            return
        end
        self.subscribers[session_id] = handlers
        self:_finish_setup(session_id, setup --[[@as table]], callback)
    end)
end

--- Resume `session_id` in a new pi process. pi does not replay the session's
--- messages.
--- @param session_id string
--- @param cwd string
--- @param _mcp_servers table[]|nil
--- @param handlers agentic.AgentClient.ClientHandlers
--- @param callback fun(result: table|nil, err: agentic.AgentClient.Error|nil)
function PiClient:load_session(
    session_id,
    cwd,
    _mcp_servers,
    handlers,
    callback
)
    local function start()
        self.subscribers[session_id] = handlers
        -- pi waits on stdin when the id matches only another directory's
        -- session, so a load that gets no answer fails.
        self:_open(
            cwd,
            { "--session", session_id },
            LOAD_TIMEOUT_MS,
            function(opened_id, setup, err)
                if not opened_id then
                    if
                        not self._sessions[session_id]
                        and self.subscribers[session_id] == handlers
                    then
                        self.subscribers[session_id] = nil
                    end
                    callback(nil, err)
                    return
                end
                self:_finish_setup(opened_id, setup --[[@as table]], callback)
            end
        )
    end

    -- Two processes on one session file would both write it.
    local stopping = self._stopping[session_id]
    if stopping then
        stopping:stop(start)
    else
        start()
    end
end

--- The text of a prompt and its images, in pi's `prompt` shape.
--- @param prompt agentic.acp.Content[]
--- @return table|nil command
--- @return string|nil err
local function prompt_command(prompt)
    local texts = {}
    local images = {}
    for _, block in ipairs(prompt) do
        if block.type == "text" then
            table.insert(texts, block.text)
        elseif block.type == "resource_link" then
            table.insert(texts, (block.uri:gsub("^file://", "")))
        elseif block.type == "image" then
            table.insert(images, {
                type = "image",
                data = block.data,
                mimeType = block.mimeType,
            })
        else
            return nil, "pi takes no " .. block.type .. " content"
        end
    end
    local command = {
        type = "prompt",
        message = table.concat(texts, "\n\n"),
        -- Queues the prompt while a run streams; pi ignores it when idle.
        streamingBehavior = "followUp",
    }
    if #images > 0 then
        command.images = images
    end
    return command, nil
end

--- Run a prompt's callback once.
--- @param entry agentic.pi.PiClient.Prompt
--- @param result table|nil
--- @param err agentic.AgentClient.Error|nil
local function settle(entry, result, err)
    if entry.done then
        return
    end
    entry.done = true
    entry.callback(result, err)
end

--- Send `prompt`. The callback runs when pi takes it in, or with the error
--- when pi rejects it or a stop cancels it first.
--- @param session_id string
--- @param prompt agentic.acp.Content[]
--- @param callback fun(result: table|nil, err: agentic.AgentClient.Error|nil)
function PiClient:send_prompt(session_id, prompt, callback)
    local session = self._sessions[session_id]
    local command, reason = prompt_command(prompt)
    if not session or not command then
        vim.schedule(function()
            callback(nil, {
                code = session and AgentClient.ERROR_CODES.INVALID_PARAMS
                    or AgentClient.ERROR_CODES.TRANSPORT_ERROR,
                message = reason or "No pi process for this session",
            })
        end)
        return
    end

    --- @type agentic.pi.PiClient.Prompt
    local entry = { callback = callback }
    session.turns:on_send(entry)
    session.process:request(command, function(data, err)
        if self._sessions[session_id] ~= session then
            return
        end
        entry.data = data
        self:_apply_signals(
            session_id,
            session,
            session.turns:on_answer(entry, data, err)
        )
        if err then
            settle(entry, nil, err)
        end
    end)
end

--- Report turn signals to the subscriber, in order. A taken prompt also runs
--- its callback, and an `idle` state also sends the session's usage.
--- @param session_id string
--- @param session agentic.pi.PiClient.Session
--- @param signals agentic.pi.TurnSignal[]
function PiClient:_apply_signals(session_id, session, signals)
    local subscriber = self.subscribers[session_id] or {}
    for _, signal in ipairs(signals) do
        if signal.taken then
            local entry = signal.taken --[[@as agentic.pi.PiClient.Prompt]]
            if subscriber.on_prompt_taken then
                subscriber.on_prompt_taken()
            end
            settle(entry, entry.data or {}, nil)
        else
            local state = signal.turn
            if subscriber.on_turn_state then
                subscriber.on_turn_state(state)
            end
            if state.state == "idle" then
                self:_send_usage(session_id, session)
            end
        end
    end
end

--- Send the session's context use and cost as a `usage_update`.
--- @param session_id string
--- @param session agentic.pi.PiClient.Session
function PiClient:_send_usage(session_id, session)
    session.process:request({ type = "get_session_stats" }, function(stats)
        local subscriber = self.subscribers[session_id]
        if not (stats and subscriber) then
            return
        end
        local context = Json.present(stats.contextUsage)
        local used = context and Json.present(context.tokens)
        local size = context and Json.present(context.contextWindow)
        if not (used and size) then
            return
        end
        --- @type agentic.acp.UsageUpdate
        local update = {
            sessionUpdate = "usage_update",
            used = used,
            size = size,
        }
        local cost = Json.present(stats.cost)
        if cost then
            update.cost = { amount = cost, currency = "USD" }
        end
        subscriber.on_session_update(update, session_id)
    end)
end

--- Send a pi session event to the subscriber as turn signals, session
--- updates and tool calls. Events from a replaced process are dropped.
--- @param session_id string
--- @param process agentic.pi.PiProcess
--- @param event table
function PiClient:_on_event(session_id, process, event)
    local session = self._sessions[session_id]
    if not session or session.process ~= process then
        return
    end
    if event.type == "message_start" and event.message.role == "assistant" then
        session.message_count = session.message_count + 1
    end
    self:_apply_signals(session_id, session, session.turns:on_event(event))

    local subscriber = self.subscribers[session_id]
    if not subscriber then
        return
    end
    if event.type == "message_update" then
        local delta = event.assistantMessageEvent or {}
        local update_type = delta.type == "text_delta" and "agent_message_chunk"
            or delta.type == "thinking_delta" and "agent_thought_chunk"
        if update_type then
            subscriber.on_session_update({
                sessionUpdate = update_type,
                content = { type = "text", text = delta.delta },
                messageId = session_id .. ":" .. session.message_count,
            }, session_id)
        end
    elseif event.parentToolCallId then
        -- A nested call (`codemode`): no block of its own.
        return
    elseif event.type == "tool_execution_start" then
        subscriber.on_tool_call(
            PiToolCalls.from_start(event, session.cwd),
            session_id
        )
    elseif event.type == "tool_execution_end" then
        subscriber.on_tool_call_update(PiToolCalls.from_end(event), session_id)
    elseif event.type == "thinking_level_changed" then
        session.options.level = event.level
        subscriber.on_session_update({
            sessionUpdate = "config_option_update",
            configOptions = config_options(session.options),
        }, session_id)
    elseif event.type == "extension_error" then
        Logger.notify(
            string.format(
                "pi extension %s failed on %s: %s",
                event.extensionPath,
                event.event,
                event.error
            ),
            vim.log.levels.WARN
        )
    elseif event.type == "auto_retry_start" then
        Logger.notify(
            string.format(
                "pi retries (attempt %d of %d): %s",
                event.attempt,
                event.maxAttempts,
                event.errorMessage
            ),
            vim.log.levels.WARN
        )
    end
end

--- Answer an extension UI request. A permission request goes to the
--- subscriber, and is rejected when the session has none. Other dialogs go
--- to the user.
--- @param session_id string|nil Nil while the session is being set up
--- @param process agentic.pi.PiProcess
--- @param request table An `extension_ui_request`
function PiClient:_on_ui_request(session_id, process, request)
    local session = session_id and self._sessions[session_id]
    local subscriber = session_id and self.subscribers[session_id]
    local call = PiPermission.parse(request)
    if not call then
        PiDialogs.show(request, function(response)
            process:respond_ui(request.id, response)
        end)
        return
    end
    if not (session and subscriber and session.process == process) then
        process:respond_ui(request.id, PiPermission.to_response(nil))
        return
    end

    if call.toolName == "edit" then
        local diff = PiToolCalls.edit_diff(call.input, session.cwd)
        if diff then
            subscriber.on_tool_call_update({
                tool_call_id = call.toolCallId,
                status = "pending",
                diff = diff,
            }, session_id)
        end
    end
    subscriber.on_request_permission(
        PiPermission.to_request(session_id, call, session.cwd),
        function(option_id)
            process:respond_ui(request.id, PiPermission.to_response(option_id))
            local allowed = option_id and option_id:match("^allow_")
            if allowed and self.subscribers[session_id] == subscriber then
                subscriber.on_tool_call_update({
                    tool_call_id = call.toolCallId,
                    status = "in_progress",
                }, session_id)
            end
        end
    )
end

--- A session's process exited while the session was in use: the running
--- turn ends with an error, the untaken prompts fail, then the subscriber
--- gets `on_disconnect`.
--- @param session_id string
--- @param process agentic.pi.PiProcess
function PiClient:_on_process_exit(session_id, process)
    local session = self._sessions[session_id]
    if not session or session.process ~= process then
        return
    end
    local subscriber = self.subscribers[session_id] or {}
    for _, signal in ipairs(session.turns:on_exit()) do
        if subscriber.on_turn_state then
            subscriber.on_turn_state(signal.turn)
        end
    end
    self._sessions[session_id] = nil
    self.subscribers[session_id] = nil
    for _, entry in ipairs(session.turns:cancel_untaken()) do
        --- @cast entry agentic.pi.PiClient.Prompt
        settle(entry, nil, {
            code = AgentClient.ERROR_CODES.TRANSPORT_ERROR,
            message = "pi exited",
        })
    end
    if subscriber and subscriber.on_disconnect then
        subscriber.on_disconnect()
    end
end

--- Drop queued prompts, then abort the run. The prompts pi had queued fail
--- with `REQUEST_CANCELLED`; pi may still take in the others, which it was
--- preparing to run.
--- @param session_id string
function PiClient:stop_generation(session_id)
    local session = self._sessions[session_id]
    if not session then
        return
    end
    -- `abort` runs the queued follow-ups after it, so the queue goes first.
    session.process:request({ type = "clear_queue" }, function(_, clear_err)
        if clear_err then
            return
        end
        for _, entry in ipairs(session.turns:cancel_queued()) do
            --- @cast entry agentic.pi.PiClient.Prompt
            settle(entry, nil, {
                code = AgentClient.ERROR_CODES.REQUEST_CANCELLED,
                message = "Cancelled",
            })
        end
        session.process:request({ type = "abort" }, function(_, err)
            if err then
                Logger.notify(
                    "pi failed to abort: " .. err.message,
                    vim.log.levels.WARN
                )
            end
        end)
    end)
end

--- Stop routing the session's events and stop its process.
--- @param session_id string
function PiClient:unsubscribe(session_id)
    self.subscribers[session_id] = nil
    local session = self._sessions[session_id]
    if not session then
        return
    end
    self._sessions[session_id] = nil
    local process = session.process
    self._stopping[session_id] = process
    process:stop(function()
        if self._stopping[session_id] == process then
            self._stopping[session_id] = nil
        end
    end)
end

--- @param session_id string
function PiClient:cancel_session(session_id)
    self:unsubscribe(session_id)
end

--- @param session_id string
--- @param on_closed fun() Runs once the session's process has exited
function PiClient:close_session(session_id, on_closed)
    self:unsubscribe(session_id)
    local stopping = self._stopping[session_id]
    if stopping then
        stopping:stop(on_closed)
    else
        vim.schedule(on_closed)
    end
end

--- Set the model (`model`, value `<provider>/<id>`) or thinking level
--- (`thought_level`). Answers `{ configOptions }`.
--- @param session_id string
--- @param config_id string
--- @param value string
--- @param callback fun(result: table|nil, err: agentic.AgentClient.Error|nil)
function PiClient:set_config_option(session_id, config_id, value, callback)
    local session = self._sessions[session_id]
    if not session then
        vim.schedule(function()
            callback(nil, {
                code = AgentClient.ERROR_CODES.TRANSPORT_ERROR,
                message = "No pi process for this session",
            })
        end)
        return
    end
    local process = session.process
    local options = session.options

    local function answer()
        callback({ configOptions = config_options(options) }, nil)
    end

    if config_id == "thought_level" then
        process:request(
            { type = "set_thinking_level", level = value },
            function(_, err)
                if err then
                    return callback(nil, err)
                end
                options.level = value
                answer()
            end
        )
        return
    end

    local provider, model_id = value:match("^([^/]+)/(.+)$")
    process:request(
        { type = "set_model", provider = provider, modelId = model_id },
        function(model, err)
            if err then
                return callback(nil, err)
            end
            options.model = model_value(model) or value
            -- The model decides which thinking levels exist.
            process:request(
                { type = "get_available_thinking_levels" },
                function(levels)
                    process:request({ type = "get_state" }, function(state)
                        options.levels = levels and levels.levels
                            or options.levels
                        options.level = state and state.thinkingLevel
                            or options.level
                        answer()
                    end)
                end
            )
        end
    )
end

--- @param _env table<string, string|nil>
--- @return table<string, string> env
function PiClient:unattended_env(_env)
    -- The extension already sends every tool call to the client.
    return {}
end

return PiClient
