local AgentClient = require("agentic.agent_client")
local Json = require("agentic.utils.json")
local UsageLimit = require("agentic.acp.usage_limit")

--- An `AgentClient` that sends its session requests through `_send_request`,
--- in the shape of the ACP methods (`session/new`, `session/load`,
--- `session/prompt`, …). `_send_request` answers nothing by default: a test
--- replaces it to capture a request's params and callback, and answers it.
--- @class tests.mocks.AgentClientMock : agentic.AgentClient
--- @field protocol_version integer 1 derives the turn states from each prompt answer; 2 leaves them to the test
--- @field _ready_waiters fun(client: agentic.AgentClient)[]
--- @field _unanswered table<string, integer> Per session id, the prompts sent and not yet answered
local AgentClientMock = setmetatable({}, { __index = AgentClient })
AgentClientMock.__index = AgentClientMock

--- @param config agentic.UserConfig.Pi
--- @param on_ready fun(client: agentic.AgentClient)|nil
--- @return tests.mocks.AgentClientMock
function AgentClientMock:new(config, on_ready)
    local client = setmetatable({
        provider_config = config,
        subscribers = {},
        state = "connecting",
        protocol_version = 1,
        agent_info = { name = "mock", version = "" },
        auth_methods = {},
        _ready_waiters = {},
        _unanswered = {},
    }, self) --[[@as tests.mocks.AgentClientMock]]
    client.usage_limit = UsageLimit:new(function()
        client:broadcast("on_usage_lifted")
    end)
    if on_ready then
        client:when_ready(on_ready)
    end
    return client
end

--- @param _env table<string, string|nil>
--- @return table<string, string> env
function AgentClientMock:unattended_env(_env)
    return {}
end

--- Answers nothing. Tests replace it.
--- @param _method string
--- @param _params table
--- @param _callback fun(result: table|nil, err: agentic.AgentClient.Error|nil)
function AgentClientMock:_send_request(_method, _params, _callback) end

--- @param session_id string
--- @param handlers agentic.AgentClient.ClientHandlers
function AgentClientMock:_subscribe(session_id, handlers)
    self.subscribers[session_id] = handlers
end

--- @param session_id string
function AgentClientMock:unsubscribe(session_id)
    self.subscribers[session_id] = nil
    self._unanswered[session_id] = nil
end

--- Call the handler `handler_name` of every subscriber that has it, each on
--- the main loop.
--- @param handler_name "on_disconnect"|"on_usage_lifted"
function AgentClientMock:broadcast(handler_name)
    for _, subscriber in pairs(self.subscribers) do
        local handler = subscriber[handler_name]
        if handler then
            vim.schedule(handler)
        end
    end
end

function AgentClientMock:stop()
    self.state = "disconnected"
end

--- @param on_ready fun(client: agentic.AgentClient)|nil
function AgentClientMock:restart(on_ready)
    for session_id in pairs(self.subscribers) do
        self:unsubscribe(session_id)
    end
    if on_ready then
        self:when_ready(on_ready)
    end
end

--- Run `on_ready` at once when the client is ready, else at the next
--- `_ready()`.
--- @param on_ready fun(client: agentic.AgentClient)
function AgentClientMock:when_ready(on_ready)
    if self.state == "ready" then
        on_ready(self)
    else
        table.insert(self._ready_waiters, on_ready)
    end
end

--- Become ready and run the waiters of `when_ready`.
function AgentClientMock:_ready()
    self.state = "ready"
    local waiters = self._ready_waiters
    self._ready_waiters = {}
    for _, waiter in ipairs(waiters) do
        waiter(self)
    end
end

--- Give the subscriber of `session_id` the commands a session setup result
--- lists.
--- @param session_id string
--- @param result table
function AgentClientMock:_emit_setup_commands(session_id, result)
    local subscriber = self.subscribers[session_id]
    if not (subscriber and result.availableCommands) then
        return
    end
    vim.schedule(function()
        subscriber.on_session_update({
            sessionUpdate = "available_commands_update",
            availableCommands = result.availableCommands,
        }, session_id)
    end)
end

function AgentClientMock:create_session(cwd, handlers, callback)
    self:_send_request(
        "session/new",
        { cwd = cwd, mcpServers = {} },
        function(result, err)
            if err or not result then
                callback(nil, err or {
                    code = self.ERROR_CODES.PROTOCOL_ERROR,
                    message = "Failed to create session: missing result",
                })
                return
            end
            --- @cast result agentic.acp.SessionCreationResponse
            if result.sessionId then
                self:_subscribe(result.sessionId, handlers)
                self:_emit_setup_commands(result.sessionId, result)
            end
            callback(result, nil)
        end
    )
end

function AgentClientMock:load_session(
    session_id,
    cwd,
    mcp_servers,
    handlers,
    callback
)
    if
        not self.agent_capabilities or not self.agent_capabilities.loadSession
    then
        vim.schedule(function()
            callback(nil, {
                code = self.ERROR_CODES.PROTOCOL_ERROR,
                message = "Agent does not support loading sessions",
            })
        end)
        return
    end

    self:_subscribe(session_id, handlers)
    self:_send_request("session/load", {
        sessionId = session_id,
        cwd = cwd,
        mcpServers = mcp_servers or {},
    }, function(result, err)
        if err then
            self:unsubscribe(session_id)
        elseif result then
            self:_emit_setup_commands(session_id, result)
        end
        callback(result, err)
    end)
end

--- Send `prompt`. With `protocol_version` 1, the turn states come from the
--- answer: the prompt is taken in when sent, which starts a turn when none
--- runs, and each answer ends the turn `idle`, then starts the next while
--- prompts are still unanswered.
function AgentClientMock:send_prompt(session_id, prompt, callback)
    local params = { sessionId = session_id, prompt = prompt }

    if self.protocol_version == 2 then
        self:_send_request("session/prompt", params, callback)
        return
    end

    local subscriber = self.subscribers[session_id] or {}
    local unanswered = self._unanswered[session_id] or 0
    self._unanswered[session_id] = unanswered + 1
    if subscriber.on_prompt_taken then
        subscriber.on_prompt_taken()
    end
    if unanswered == 0 and subscriber.on_turn_state then
        subscriber.on_turn_state({ state = "running" })
    end

    self:_send_request("session/prompt", params, function(result, err)
        local left = math.max(0, (self._unanswered[session_id] or 0) - 1)
        self._unanswered[session_id] = left > 0 and left or nil
        local on_turn_state = (self.subscribers[session_id] or {}).on_turn_state
        if on_turn_state then
            on_turn_state({
                state = "idle",
                stop_reason = err and "error"
                    or type(result) == "table" and Json.present(
                        result.stopReason
                    )
                    or nil,
                usage = type(result) == "table" and result.usage or nil,
                error = err,
                more = left > 0,
            })
            if left > 0 then
                on_turn_state({ state = "running" })
            end
        end
        callback(result, err)
    end)
end

function AgentClientMock:set_config_option(
    session_id,
    config_id,
    config_value,
    callback
)
    self:_send_request("session/set_config_option", {
        sessionId = session_id,
        configId = config_id,
        value = config_value,
    }, callback)
end

function AgentClientMock:stop_generation(_session_id) end

function AgentClientMock:cancel_session(session_id)
    self:unsubscribe(session_id)
end

function AgentClientMock:close_session(session_id, on_closed)
    self:cancel_session(session_id)
    vim.schedule(on_closed)
end

return AgentClientMock
