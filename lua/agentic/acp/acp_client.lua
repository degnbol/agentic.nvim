local AcpKind = require("agentic.utils.acp_kind")
local ClaudeUtils = require("agentic.acp.adapters.claude_utils")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local Json = require("agentic.utils.json")
local LogLine = require("agentic.utils.log_line")
local Logger = require("agentic.utils.logger")
local PermissionRules = require("agentic.utils.permission_rules")
local SkillPath = require("agentic.utils.skill_path")
local ToolCallKinds = require("agentic.acp.tool_call_kinds")
local transport_module = require("agentic.acp.acp_transport")
local UsageLimit = require("agentic.acp.usage_limit")

--[[
CRITICAL: Type annotations in this file are essential for Lua Language Server support.
DO NOT REMOVE them. Only update them if the underlying types change.
--]]

--- @alias agentic.acp.ClientConnectionState
--- | "disconnected"
--- | "connecting"
--- | "connected"
--- | "initializing"
--- | "ready"
--- | "error"

--- @alias agentic.acp.ClientHandlers.on_session_update fun(update: agentic.acp.SessionUpdateMessage, source_session_id: string|nil): nil
--- @alias agentic.acp.ClientHandlers.on_request_permission fun(request: agentic.acp.RequestPermission, callback: fun(option_id: string | nil)): nil

--- Handlers for a specific session. Each session subscribes with its own handlers.
--- @class agentic.acp.ClientHandlers
--- @field on_session_update agentic.acp.ClientHandlers.on_session_update
--- @field on_request_permission agentic.acp.ClientHandlers.on_request_permission
--- @field on_tool_call fun(tool_call: agentic.ui.MessageWriter.ToolCallBlock, source_session_id: string|nil): nil
--- @field on_tool_call_update fun(tool_call: agentic.ui.MessageWriter.ToolCallBase, source_session_id: string|nil): nil
--- @field on_disconnect? fun(): nil The provider process died or failed
--- @field on_usage_lifted? fun(): nil The provider account's usage limit lifted
--- @field on_turn_state? fun(state: agentic.acp.TurnState): nil The root session's foreground work changed state
--- @field on_prompt_taken? fun(): nil The agent took in the oldest prompt sent to the root session and not yet taken

--- @class agentic.acp.ACPProviderConfig
--- @field name? string Provider name
--- @field transport_type? agentic.acp.TransportType
--- @field command? string Command to spawn agent (for stdio)
--- @field args? string[] Arguments for agent command
--- @field env? table<string, string|nil> Environment variables
--- @field timeout? number Request timeout in milliseconds
--- @field reconnect? boolean Enable auto-reconnect
--- @field max_reconnect_attempts? number Maximum reconnection attempts
--- @field auth_method? string Preferred auth method id. An `agent` method runs at startup. An advertised method of either type is what `/login` runs without asking.
--- @field default_mode? string Default mode ID to set on session creation

--- Data fields set in the constructor. Separated from the full class
--- so LuaLS validates instance fields without requiring methods that
--- live on the prototype via __index.
--- @class agentic.acp.ACPClientData
--- @field provider_config agentic.acp.ACPProviderConfig
--- @field id_counter number
--- @field state agentic.acp.ClientConnectionState
--- @field protocol_version number The ACP version `initialize` asks for, then the one the agent answered with
--- @field client_info agentic.acp.ClientInfo
--- @field capabilities agentic.acp.ClientCapabilities
--- @field agent_capabilities? agentic.acp.AgentCapabilities
--- @field agent_info? agentic.acp.AgentInfo
--- @field auth_methods? agentic.acp.AuthMethod[]
--- @field login_job? vim.SystemObj|table The running login: a terminal method's process, or a token while an authenticate request is out
--- @field auth_status? agentic.acp.AuthStatus Identity the agent process authenticates with; nil while none is reported, which is distinct from a reported `kind = "none"`
--- @field callbacks table<number, fun(result: table|nil, err: agentic.acp.ACPError|nil)>
--- @field transport? agentic.acp.ACPTransportInstance
--- @field subscribers table<string, agentic.acp.ClientHandlers>

--- @class agentic.acp.ACPClient : agentic.acp.ACPClientData
--- @field provider_name agentic.UserConfig.ProviderName Config key of the provider this client runs
--- @field usage_limit agentic.acp.UsageLimit This process's usage limit. A restart keeps it
--- @field _on_ready fun(client: agentic.acp.ACPClient) Ready callback passed to `new`, run again when a reconnect of a client that was ready reaches ready
--- @field _ready_waiters fun(client: agentic.acp.ACPClient)[] Callbacks of `when_ready` that wait for the next ready, in order
--- @field _connection integer Number of connections started. Callbacks of an earlier connection are ignored
--- @field _was_ready? boolean Whether any connection has reached `ready`
--- @field _notified_output table<string, true> Process output summaries already shown as a notification by this client
--- @field _loading_sessions table<string, boolean> Session IDs currently being loaded via session/load
--- @field _children table<string, string> Child session id → the subscribed root session that spawned it, directly or through other children
--- @field _session_roots table<string, string[]> Skill-search roots per session, from the cwd and additional directories that session was opened with
--- @field _tool_call_kinds agentic.acp.ToolCallKinds
--- @field _v2_states table<string, agentic.acp.ClaudeV2Codec.State> Per session id, the codec state of the current connection while it speaks v2
--- @field _unanswered table<string, integer> ACP v1: per session id, the prompts sent and not yet answered
--- @field v2_codec? agentic.acp.ClaudeV2Codec The ACP v2 codec of the class's provider. A client whose class has one asks for v2 in `initialize`, and translates every message it then gets and sends
local ACPClient = {}
ACPClient.__index = ACPClient

--- ACP Error codes
ACPClient.ERROR_CODES = {
    -- ACP / JSON-RPC codes
    AUTH_REQUIRED = -32000,
    INVALID_PARAMS = -32602,
    INTERNAL_ERROR = -32603,
    REQUEST_CANCELLED = -32800,
    -- Client-side only, never sent: outside the JSON-RPC reserved range
    TRANSPORT_ERROR = -1,
    PROTOCOL_ERROR = -2,
}

--- Set up a child adapter class with proper ACPClient inheritance chain.
--- The child inherits ACPClient:new() — no need to override unless adding
--- extra instance fields (e.g. CursorACPAdapter).
--- @return table child_class
function ACPClient.extend()
    local Child = setmetatable({}, { __index = ACPClient })
    Child.__index = Child
    return Child
end

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.ACPClient
function ACPClient:new(config, on_ready)
    --- @type agentic.acp.ACPClientData
    local instance = {
        provider_config = config,
        subscribers = {},
        id_counter = 0,
        protocol_version = self.v2_codec and 2 or 1,
        client_info = {
            name = "Agentic.nvim",
            version = "0.0.1",
        },
        capabilities = {
            fs = {
                readTextFile = false,
                writeTextFile = false,
            },
            terminal = false,
            auth = { terminal = true },
            _meta = self:capability_meta(),
            -- Each subagent becomes a child session, announced and tracked by
            -- `subagent_update`, its messages sent as `session_message`.
            subagents = vim.empty_dict(),
        },
        callbacks = {},
        transport = nil,
        state = "disconnected",
    }

    local client = setmetatable(instance, self) --[[@as agentic.acp.ACPClient]]
    client._on_ready = on_ready
    client._ready_waiters = {}
    client._connection = 0
    client._loading_sessions = {}
    client._children = {}
    client._session_roots = {}
    client._tool_call_kinds = ToolCallKinds:new()
    client._v2_states = {}
    client._unanswered = {}
    client._notified_output = {}
    client:_setup_usage_limit()

    client:_setup_transport()
    client:when_ready(on_ready)
    client:_connect()
    return client
end

--- Give the client its provider account's usage limit, whose lift calls
--- every subscriber's `on_usage_lifted`.
function ACPClient:_setup_usage_limit()
    self.usage_limit = UsageLimit:new(function()
        self:_broadcast("on_usage_lifted")
    end)
end

--- @param session_id string
--- @param handlers agentic.acp.ClientHandlers
function ACPClient:_subscribe(session_id, handlers)
    self.subscribers[session_id] = handlers
end

--- Route this session's notifications to `handlers`, and record the
--- directories its skill names resolve against. `unsubscribe` undoes it.
--- @param session_id string
--- @param handlers agentic.acp.ClientHandlers
--- @param cwd string Working directory of the session
--- @param additional_dirs string[] Directories the session may reach beyond its cwd
function ACPClient:_attach_session(session_id, handlers, cwd, additional_dirs)
    self:_subscribe(session_id, handlers)
    self._session_roots[session_id] = SkillPath.roots(cwd, additional_dirs)
end

--- Give the subscriber of `session_id` the commands a session setup result
--- lists, as an `available_commands_update`. An agent that sends the update
--- itself lists none in the result.
--- @param session_id string
--- @param result table The result of `session/new`, `session/load` or `session/fork`
function ACPClient:_emit_setup_commands(session_id, result)
    local commands = result.availableCommands
    if not commands then
        return
    end
    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_session_update({
            sessionUpdate = "available_commands_update",
            availableCommands = commands,
        })
    end)
end

--- Stop routing this session's notifications, and drop the per-session state
--- that exists only to serve them. Every caller that abandons a session goes
--- through here, so the parallel maps cannot drift apart.
--- @param session_id string
function ACPClient:unsubscribe(session_id)
    self.subscribers[session_id] = nil
    self._session_roots[session_id] = nil
    self._unanswered[session_id] = nil
    self._tool_call_kinds:forget_session(session_id)
    for child, root in pairs(self._children) do
        if root == session_id then
            self._children[child] = nil
        end
    end
end

--- What a provider recorded about a subagent's spawn.
--- @class agentic.acp.SubagentRecord
--- @field agent_type string Subagent type the agent was spawned as
--- @field background boolean The agent runs in the background rather than blocking its spawner
--- @field task_id string Id of the tool call that spawned the agent

--- What the provider recorded about a subagent's spawn. Adapters for
--- providers that keep such a record override this.
--- @param _session_id string The root session
--- @param _child_id string The subagent's child session id
--- @return agentic.acp.SubagentRecord|nil record Nil while there is none
function ACPClient:subagent_record(_session_id, _child_id)
    return nil
end

--- The provider's name for the session. Adapters for providers that name
--- sessions override this.
--- @param _session_id string
--- @return string|nil name Nil when the provider has none for the session
function ACPClient:name(_session_id)
    return nil
end

--- @alias agentic.acp.HookRecordGroup
--- | "context" context a hook delivered to the model
--- | "passed" ran to completion with nothing to report; the body is empty
--- | "stray" stdout the model did not see
--- | "message" text the hook addressed to the user, which the model did not receive
--- | "failure" timed out, exited non-zero with an error, or its output was rejected
--- | "verbatim" the provider's own record of it did not parse; the body is that record

--- Where a record the provider wrote outside the ACP feed belongs: right
--- after what it happened with. None set: nowhere in particular.
--- @class agentic.acp.Anchor
--- @field tool_call_id? string After this tool call; may name a call the client never saw
--- @field after_prompt? boolean After the last prompt
--- @field after_compaction? boolean After the last compaction

--- Hook activity a provider recorded outside the ACP feed.
--- @class agentic.acp.HookRecord : agentic.acp.Anchor
--- @field group agentic.acp.HookRecordGroup
--- @field body string[]
--- @field hook_name? string The hook's configured name, e.g. `PreToolUse:Bash`
--- @field command? string The hook's invocation, when the record is of one run
--- @field duration_ms? number How long that run took
--- @field outcome? agentic.acp.HookOutcome What the hook did, when it did more than report

--- @alias agentic.acp.HookOutcome
--- | "blocked" the hook returned a blocking error; the model received its reason
--- | "stopped" the hook ended the turn
--- | "allowed" the hook approved the tool call
--- | "denied" the hook refused the tool call
--- | "asked" the hook sent the tool call to a permission prompt
--- | "deferred" the hook deferred the tool call to the host

--- A file the provider added to the model's context without a tool call.
--- @class agentic.acp.LoadedFile : agentic.acp.Anchor
--- @field path string Absolute

--- Skills the provider made available to the model during the session.
--- @class agentic.acp.DiscoveredSkills : agentic.acp.Anchor
--- @field title string The row announcing the skills
--- @field body string[] One row per skill

--- A message the session received from another session or a subagent.
--- @class agentic.acp.ReceivedMessage
--- @field message_id string
--- @field text string
--- @field sender_id? string The sending subagent's id, as the provider names it
--- @field sender_name? string The display name the provider gave the sender

--- `tool_call` carries fields of a tool call that the ACP feed left out.
---
--- Stored in the chat history as drained, so renaming a field needs a
--- migration in `ChatHistory.from_data`.
--- @alias agentic.acp.SideRecord
--- | { kind: "hook", hook: agentic.acp.HookRecord }
--- | { kind: "loaded_file", loaded_file: agentic.acp.LoadedFile }
--- | { kind: "discovered_skills", discovered_skills: agentic.acp.DiscoveredSkills }
--- | { kind: "tool_call", tool_call: agentic.ui.MessageWriter.ToolCallBase }
--- | { kind: "received_message", received_message: agentic.acp.ReceivedMessage }

--- Records the provider wrote outside the ACP feed since the last call, for
--- the session or for one of its subagents. Adapters for providers that keep
--- such records override this.
--- @param _session_id string The root session
--- @param _child_id string|nil A subagent's child session id
--- @return agentic.acp.SideRecord[]
function ACPClient:drain_side_records(_session_id, _child_id)
    return {}
end

--- The subagent that sent a received message.
--- @param sender_id string The sender's id, as the provider names it
--- @param child_ids string[] Child session ids of the session's subagents
--- @return string|nil child_id nil when none of them sent it
function ACPClient:sender_session(sender_id, child_ids)
    return vim.tbl_contains(child_ids, sender_id) and sender_id or nil
end

--- The task id an update is tagged with: the id of the tool call that gave
--- its subagent its current work, the one that spawned it or one that
--- resumed it. Adapters for providers that tag subagent updates override this.
--- @param _update agentic.acp.SessionUpdateMessage
--- @return string|nil task_id Nil for an update that is not a subagent's
function ACPClient:subagent_task_id(_update)
    return nil
end

--- The task id of the launch a session message replies to. Nil by default: a
--- launch's reply and a subagent's hand-back both go from child to parent,
--- and only a provider's message ids can tell them apart.
--- @param _update agentic.acp.SessionMessage
--- @return string|nil task_id Nil when it is not a launch's reply
function ACPClient:launch_reply_task(_update)
    return nil
end

--- A message id without its `:reply` suffix.
--- @param message_id string
--- @return string|nil task_id Nil without the suffix
function ACPClient.strip_reply_suffix(message_id)
    return message_id:match("^(.+):reply$")
end

--- Whether a replayed prompt is one the provider adds itself during a
--- session/load replay, not one the user sent.
--- @param _text string
--- @return boolean
function ACPClient:is_replay_only_prompt(_text)
    return false
end

--- The shell the provider's execute tool runs commands in, when the client
--- can prove it. Reaches only blocks built by the base `__build_tool_call_message`.
--- @return "bash"|"zsh"|nil
function ACPClient:exec_shell()
    return nil
end

--- One usage-limit window the provider reported.
--- @class agentic.acp.BudgetWindow
--- @field label string Short name of the window, e.g. "5h", "7d"
--- @field utilization number Fraction 0-1 of the window used
--- @field resets_at number Epoch seconds when the window refills
--- @field window_s number Length of the window in seconds
--- @field state "ok"|"warning"|"exhausted"

--- The usage-limit windows a usage update reports, shortest window first.
--- @param _update agentic.acp.UsageUpdate
--- @return agentic.acp.BudgetWindow[]|nil windows Nil when the update reports none
function ACPClient:budget_windows(_update)
    return nil
end

--- Whether to send "continue" once a usage limit resets.
--- @return boolean
function ACPClient:auto_continue_on_usage_limit()
    return false
end

--- Provider-specific `_meta` for session/new and session/load.
--- @param _additional_dirs string[] Directories the session may reach beyond its cwd
--- @return table|nil meta
function ACPClient:session_meta(_additional_dirs)
    return nil
end

--- The `_meta` that tells the agent to end a `session/fork` copy after the
--- model response `response_id`. ACP defines no fork point, so the default
--- is nil: the provider cannot cut a fork.
--- @param _response_id string `messageId` of the response
--- @return table|nil meta
function ACPClient:fork_point_meta(_response_id)
    return nil
end

--- Provider-specific `_meta` of the client capabilities sent in initialize.
--- Called on the class, not an instance, so overrides must not read
--- instance fields.
--- @return table|nil meta
function ACPClient:capability_meta()
    return nil
end

--- The env entries that make the provider leave every tool call's permission
--- to the client, over any rule of the user's that allows it. Called on the
--- class, not an instance. The default has none to give.
--- @param _env table<string, string|nil> The env the process starts with
--- @return table<string, string>|nil env
--- @return string|nil err Why no env could be built
function ACPClient:unattended_env(_env)
    return nil, "no way to send every tool call for a permission decision"
end

--- Claude's config directory for the environment this client runs with:
--- the directory whose settings.json holds the permission rules.
--- @return string
function ACPClient:claude_config_dir()
    return ClaudeUtils.config_dir(self.provider_config.env)
end

--- The plan file a permission request asks approval for.
--- @param _request agentic.acp.RequestPermission
--- @return string|nil path Absolute path; nil when the request names none
function ACPClient:plan_file(_request)
    return nil
end

--- The mode a subagent is expected to run in until the provider's record of
--- its spawn confirms one. Adapters for providers that can force a mode
--- override this.
--- @return "background"|"blocking"
function ACPClient:subagent_predicted_mode()
    return "blocking"
end

--- A prompt for the main agent to pass a message to a background subagent.
--- Adapters for providers whose main agent can message one override this.
--- @param _agent_id string Id addressing the subagent
--- @param _label string Display name of the subagent
--- @param _message string Text for the subagent to receive
--- @return string|nil instruction Nil when the main agent cannot message it
function ACPClient:subagent_message_instruction(_agent_id, _label, _message)
    return nil
end

--- The subscribed session a session belongs to: the root that spawned a child
--- session, else the session itself.
--- @protected
--- @param session_id string
--- @return string root_id
function ACPClient:__root_session(session_id)
    return self._children[session_id] or session_id
end

--- Run `callback` on the main loop with the subscriber of `session_id`'s root
--- session. The handlers it gets pass `session_id` on to the session-update and
--- tool-call handlers as their second argument, so the subscriber can tell a
--- child session's updates from its own.
--- @protected
--- @param session_id string
--- @param callback fun(sub: agentic.acp.ClientHandlers): nil
function ACPClient:__with_subscriber(session_id, callback)
    local subscriber = self.subscribers[self:__root_session(session_id)]

    if not subscriber then
        Logger.debug("No subscriber found for session_id: " .. session_id)
        return
    end

    local handlers = setmetatable({
        on_session_update = function(update)
            subscriber.on_session_update(update, session_id)
        end,
        on_tool_call = function(tool_call)
            subscriber.on_tool_call(tool_call, session_id)
        end,
        on_tool_call_update = function(tool_call_update)
            subscriber.on_tool_call_update(tool_call_update, session_id)
        end,
    }, { __index = subscriber }) --[[@as agentic.acp.ClientHandlers]]

    vim.schedule(function()
        local ok, err = pcall(callback, handlers)
        if not ok then
            Logger.notify(
                "Subscriber callback error:\n" .. tostring(err),
                vim.log.levels.ERROR,
                { title = "Agentic sync error" }
            )
        end
    end)
end

--- Whether a line the provider process wrote outside the protocol is known
--- noise. Overrides add their provider's patterns and call the base.
--- @protected
--- @param line string
--- @return boolean
function ACPClient:ignores_output(line)
    return line:find("Session not found", 1, true) ~= nil
        or line:find("session/prompt", 1, true) ~= nil
        or line:find("does not appear in the file:", 1, true) ~= nil
end

--- Handle a line the provider process wrote outside the protocol. Every line
--- goes to the log file. A line not ignored also goes to `:messages`, and its
--- `LogLine.summary` is shown as a warning the first time this client sees it.
--- Never written to a chat: the process serves every session, and its output
--- has no order relative to the protocol stream. Safe in a luv callback.
--- @param stream "stdout"|"stderr"
--- @param line string
function ACPClient:_on_process_output(stream, line)
    local config = self.provider_config
    local label = (config.name or config.command)
        .. (self.agent_info and " " .. self.agent_info.version or "")
        .. " "
        .. stream

    Logger.debug_to_file(label .. ":", line)
    if self:ignores_output(line) then
        return
    end
    Logger.debug(label .. ":", line)

    local summary = LogLine.summary(line)
    if not summary or self._notified_output[summary] then
        return
    end
    self._notified_output[summary] = true

    local suffix = Config.log and " (logs in " .. Logger.LOG_DIR .. ")" or ""
    Logger.notify(label .. ": " .. summary .. suffix, vim.log.levels.WARN)
end

function ACPClient:_setup_transport()
    local transport_type = self.provider_config.transport_type or "stdio"

    if transport_type == "stdio" then
        --- @type agentic.acp.StdioTransportConfig
        local transport_config = {
            command = self.provider_config.command,
            args = self.provider_config.args,
            env = self.provider_config.env,
            enable_reconnect = self.provider_config.reconnect,
            max_reconnect_attempts = self.provider_config.max_reconnect_attempts,
        }

        --- @type agentic.acp.TransportCallbacks
        local callbacks = {
            on_state_change = function(state)
                self:_set_state(state)
            end,
            on_message = function(message)
                self:_handle_message(message)
            end,
            on_reconnect = function()
                -- A client that was never ready still holds `_on_ready` as a
                -- waiter.
                if self.state == "disconnected" then
                    self:_connect(self._was_ready and self._on_ready or nil)
                end
            end,
            on_stdout_line = function(line)
                self:_on_process_output("stdout", line)
            end,
            on_stderr_line = function(line)
                self:_on_process_output("stderr", line)
            end,
        }

        self.transport =
            transport_module.create_stdio_transport(transport_config, callbacks)
    else
        error("Unsupported transport type: " .. transport_type)
    end
end

--- @param state agentic.acp.ClientConnectionState
function ACPClient:_set_state(state)
    self.state = state

    -- When the provider dies or errors, fail all pending request callbacks
    -- so callers (e.g. SessionManager) can reset their state instead of
    -- hanging forever with orphaned callbacks.
    if state == "disconnected" or state == "error" then
        self:_fail_pending_callbacks(state)
        -- A fresh subprocess probes its identity asynchronously, so an
        -- identity must not outlive the subprocess that reported it.
        self.auth_status = nil
        self:_broadcast("on_disconnect")
    end
end

--- Call the handler `handler_name` of every subscriber that has it, each on
--- the main loop.
--- @param handler_name "on_disconnect"|"on_usage_lifted"
function ACPClient:_broadcast(handler_name)
    for session_id in pairs(self.subscribers) do
        self:__with_subscriber(session_id, function(subscriber)
            local handler = subscriber[handler_name]
            if handler then
                handler()
            end
        end)
    end
end

--- Fail all pending request callbacks with a transport error.
--- Called when the provider subprocess exits or the connection breaks.
--- @param state agentic.acp.ClientConnectionState
function ACPClient:_fail_pending_callbacks(state)
    local pending = self.callbacks
    if not next(pending) then
        return
    end

    -- Snapshot and clear before invoking — callbacks may trigger new sends
    self.callbacks = {}

    local err = self:__create_error(
        self.ERROR_CODES.TRANSPORT_ERROR,
        "Provider " .. state .. " — request lost"
    )

    for _, callback in pairs(pending) do
        vim.schedule(function()
            callback(nil, err)
        end)
    end
end

--- @protected
--- @param code number
--- @param message string
--- @param data any|nil
--- @return agentic.acp.ACPError
function ACPClient:__create_error(code, message, data)
    return {
        code = code,
        message = message,
        data = data,
    }
end

--- @return number
function ACPClient:_next_id()
    self.id_counter = self.id_counter + 1
    return self.id_counter
end

--- The codec state of `session_id` on the current connection, created on
--- first use.
--- @param session_id string
--- @return agentic.acp.ClaudeV2Codec.State
function ACPClient:_v2_state(session_id)
    local codec = self.v2_codec --[[@as agentic.acp.ClaudeV2Codec]]
    local state = self._v2_states[session_id] or codec.state()
    self._v2_states[session_id] = state
    return state
end

--- The v2 form of a v1 request, and a callback that gives `callback` the v1
--- form of its result. An `initialize` answered with another version fails:
--- the request went out in v2 form, without the v1 capabilities.
--- @param method string
--- @param params table
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
--- @return string method
--- @return table params
--- @return fun(result: table|nil, err: agentic.acp.ACPError|nil) callback
function ACPClient:_encode_v2_request(method, params, callback)
    local codec = self.v2_codec --[[@as agentic.acp.ClaudeV2Codec]]
    -- Not `_v2_state`: a request leaves nothing to decode later, so a
    -- session the client holds no state for needs none kept.
    local state = self._v2_states[params.sessionId] or codec.state()
    local v2_method, v2_params = codec.encode_request(state, method, params)
    return v2_method,
        v2_params,
        function(result, err)
            local version = result and result.protocolVersion
            if result and v2_method == "initialize" and version ~= 2 then
                err = self:__create_error(
                    self.ERROR_CODES.PROTOCOL_ERROR,
                    "The agent answered an ACP v2 initialize with version "
                        .. tostring(version)
                )
                result = nil
            elseif result then
                result = codec.decode_result(v2_method, result)
            end
            callback(result, err)
        end
end

--- @param method string
--- @param params table|nil
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:_send_request(method, params, callback)
    params = params or {}
    if self.protocol_version == 2 then
        method, params, callback =
            self:_encode_v2_request(method, params, callback)
    end
    local id = self:_next_id()
    local message = {
        jsonrpc = "2.0",
        id = id,
        method = method,
        params = params,
    }

    local data = vim.json.encode(message)

    Logger.debug_to_file("request: ", message)

    if not self.transport then
        Logger.debug("Cannot send request: transport not initialised")
        vim.schedule(function()
            callback(
                nil,
                self:__create_error(
                    self.ERROR_CODES.TRANSPORT_ERROR,
                    "Cannot send request: transport not initialised"
                )
            )
        end)
        return
    end

    local sent = self.transport:send(data)
    if not sent then
        Logger.debug("Transport send failed for method: ", method)
        vim.schedule(function()
            callback(
                nil,
                self:__create_error(
                    self.ERROR_CODES.TRANSPORT_ERROR,
                    "Provider not connected — send failed"
                )
            )
        end)
        return
    end

    self.callbacks[id] = callback
end

--- @param method string
--- @param params table|nil
function ACPClient:_send_notification(method, params)
    local message = {
        jsonrpc = "2.0",
        method = method,
        params = params or {},
    }

    local data = vim.json.encode(message)

    Logger.debug_to_file("notification: ", message, "\n\n")

    if not self.transport then
        Logger.debug("Cannot send notification: transport not initialised")
        return
    end
    self.transport:send(data)
end

--- @protected
--- @param id number
--- @param result table | string | vim.NIL | nil
--- @return nil
function ACPClient:__send_result(id, result)
    local message = { jsonrpc = "2.0", id = id, result = result }

    local data = vim.json.encode(message)
    Logger.debug_to_file("request:", message)

    if not self.transport then
        Logger.debug("Cannot send result: transport not initialised")
        return
    end
    self.transport:send(data)
end

--- @param id number
--- @param message string
--- @param code number|nil
--- @return nil
function ACPClient:_send_error(id, message, code)
    if not self.transport then
        Logger.debug("Cannot send error: transport not initialised")
        return
    end

    code = code or self.ERROR_CODES.INTERNAL_ERROR
    local msg =
        { jsonrpc = "2.0", id = id, error = { code = code, message = message } }

    local data = vim.json.encode(msg)
    self.transport:send(data)
end

--- Handles raw JSON-RPC message received from the transport
--- @param message agentic.acp.ResponseRaw
function ACPClient:_handle_message(message)
    -- NOT log agent messages chunk to avoid huge logs file
    if
        not (
            message.params
            and message.params.update
            and (
                message.params.update.sessionUpdate == "agent_message_chunk"
                or message.params.update.sessionUpdate
                    == "agent_thought_chunk"
            )
        )
    then
        Logger.debug_to_file(self.provider_config.name, "response: ", message)
    end

    if message.method and not message.result and not message.error then
        self:_handle_notification(message.id, message.method, message.params)
    elseif message.id and (message.result or message.error) then
        local callback = self.callbacks[message.id]
        if callback then
            self.callbacks[message.id] = nil
            -- Schedule response callbacks onto the main loop — _handle_message
            -- runs from a libuv read_start callback where vim API calls are
            -- unsafe. Notification handlers already go through __with_subscriber
            -- which schedules; response callbacks must do the same.
            vim.schedule(function()
                callback(message.result, message.error)
            end)
        else
            Logger.notify(
                "No callback found for response id: "
                    .. tostring(message.id)
                    .. "\n\n"
                    .. vim.inspect(message)
            )
        end
    else
        Logger.notify("Unknown message type: " .. vim.inspect(message))
    end
end

--- @param message_id number
--- @param method string
--- @param params table
function ACPClient:_handle_notification(message_id, method, params)
    local codec = self.v2_codec --[[@as agentic.acp.ClaudeV2Codec]]
    local v2 = self.protocol_version == 2
        and type(params) == "table"
        and params.sessionId ~= nil
    if method == "session/update" and v2 and params.update then
        local state = self:_v2_state(params.sessionId)
        for _, update in ipairs(codec.decode_update(state, params.update)) do
            self:__handle_session_update({
                sessionId = params.sessionId,
                update = update,
            })
        end
    elseif method == "session/update" then
        self:__handle_session_update(params)
    elseif method == "session/request_permission" then
        if v2 then
            params = codec.decode_permission(
                self:_v2_state(params.sessionId),
                params
            )
        end
        --- @diagnostic disable-next-line: param-type-mismatch
        self:__handle_request_permission(message_id, params)
    elseif method == "fs/read_text_file" then
        self:_handle_fs_read(message_id, params)
    elseif method == "fs/write_text_file" then
        self:_handle_fs_write(message_id, params)
    elseif method == "_auth/status_update" then
        self.auth_status = params.authStatus
    else
        Logger.notify("Unknown notification method: " .. method)
    end
end

--- `ToolCallKinds:apply` for a subscribed session. A provider keeps sending
--- updates after `unsubscribe` (the tail of a cancelled turn, background
--- subagents); they are dropped, and recording their kinds would rebuild the
--- map `unsubscribe` freed.
--- @param session_id string
--- @param update agentic.acp.ToolCallMessage|agentic.acp.ToolCallUpdate
function ACPClient:_apply_tool_call_kind(session_id, update)
    local root = self:__root_session(session_id)
    if self.subscribers[root] then
        self._tool_call_kinds:apply(root, update)
    end
end

--- @protected
--- @param params table
function ACPClient:__handle_session_update(params)
    local session_id = params.sessionId
    local update = params.update

    if not session_id then
        Logger.notify("Received session/update without sessionId")
        return
    end

    if not update then
        Logger.notify("Received session/update without update data")
        return
    end

    local session_update_type = update.sessionUpdate
    local root = self:__root_session(session_id)

    -- Recorded here rather than by the subscriber: the child's own updates
    -- follow at once, and the subscriber runs a tick later.
    if
        session_update_type == "subagent_update"
        and update.sessionId ~= session_id
        and self.subscribers[root]
    then
        self._children[update.sessionId] = root
    end

    if
        session_update_type == "state_update"
        or session_update_type == "user_message"
    then
        -- A child's state comes on the parent's `subagent_update`.
        if not self._children[session_id] then
            self:__with_subscriber(session_id, function(subscriber)
                if session_update_type == "user_message" then
                    if subscriber.on_prompt_taken then
                        subscriber.on_prompt_taken()
                    end
                elseif subscriber.on_turn_state then
                    subscriber.on_turn_state({
                        state = update.state,
                        stop_reason = Json.present(update.stopReason),
                        usage = Json.present(update.usage),
                        error = Json.present(update.error),
                    })
                end
            end)
        end
        return
    end

    if session_update_type == "user_message_chunk" then
        if self._loading_sessions[root] then
            -- During session/load replay, the provider sends user messages
            -- that we don't have locally — forward them to the subscriber.
            self:__with_subscriber(session_id, function(subscriber)
                subscriber.on_session_update(update)
            end)
        end
        -- During normal operation, ignore — Agentic writes its own user
        -- messages on prompt submit and these would cause duplication.
        return
    end

    if session_update_type == "tool_call" then
        if not AcpKind.PROTOCOL_KINDS[update.kind] then
            -- Using notify intentionally so users of providers
            -- we don't use daily report unknown kinds as issues
            Logger.notify(
                "Unknown ACP tool call kind: "
                    .. tostring(update.kind)
                    .. "\n\n"
                    .. "Please report this so we can add support for it!\n\n"
                    .. "https://github.com/carlos-algms/agentic.nvim/issues/new",
                vim.log.levels.WARN
            )
        end

        self:_apply_tool_call_kind(session_id, update)
        self:__handle_tool_call(session_id, update)
    elseif session_update_type == "tool_call_update" then
        self:_apply_tool_call_kind(session_id, update)
        self:__handle_tool_call_update(session_id, update)
    else
        self:__with_subscriber(session_id, function(subscriber)
            subscriber.on_session_update(update)
        end)
    end
end

--- Resolve fetch/WebSearch fields from rawInput.
--- Sets kind and argument on the given message table.
--- @protected
--- @param message agentic.ui.MessageWriter.ToolCallBlock|agentic.ui.MessageWriter.ToolCallBase
--- @param rawInput agentic.acp.RawInput
function ACPClient:__resolve_fetch_fields(message, rawInput)
    if rawInput.query then
        message.kind = "WebSearch"
        message.argument = rawInput.query
    elseif rawInput.url then
        message.argument = rawInput.url
        if rawInput.prompt then
            message.argument =
                string.format("%s %s", message.argument, rawInput.prompt)
        end
    else
        message.argument = "unknown fetch"
    end
end

--- Coerce a command value to a string (providers may send a table of args).
--- @protected
--- @param command string|string[]|nil
--- @return string|nil
function ACPClient:__ensure_command_string(command)
    if type(command) == "table" then
        return table.concat(command, " ")
    end
    return command
end

--- Extract body text from standard ACP content field.
--- Adapters should use this to avoid duplicating content extraction logic.
--- @param update agentic.acp.ToolCallMessage|agentic.acp.ToolCallUpdate
--- @return string[]|nil body
function ACPClient:extract_content_body(update)
    local content = update.content and update.content[1]

    if
        content
        and content.type == "content"
        and content.content
        and content.content.text
    then
        return self:safe_split(content.content.text)
    end

    return nil
end

--- Find the diff entry in a tool call's standard ACP `content` array.
--- Scans rather than reading `content[1]`: opencode precedes the diff with a
--- status-text entry on write/edit completion.
--- @param update agentic.acp.ToolCallMessage|agentic.acp.ToolCallUpdate
--- @return agentic.acp.ToolCallDiffContent|nil content
function ACPClient:find_content_diff(update)
    for _, entry in ipairs(update.content or {}) do
        if entry.type == "diff" then
            return entry --[[@as agentic.acp.ToolCallDiffContent]]
        end
    end

    return nil
end

--- Extract plain text from a tool_call_update's rawOutput field.
--- claude-agent-acp sets `rawOutput = chunk.content`, which per the Anthropic
--- API is a string or an array of content blocks (`{type="text", text=...}`).
--- For failed tool calls this is the unfenced error/denial text — preferable
--- to `content`, which `toAcpContentUpdate` wraps in ``` fences.
--- @param raw_output any
--- @return string[]|nil body
function ACPClient:extract_failure_reason(raw_output)
    if type(raw_output) == "string" then
        if raw_output == "" then
            return nil
        end
        return self:safe_split(raw_output)
    end
    if type(raw_output) == "table" then
        local parts = {}
        for _, block in ipairs(raw_output) do
            if
                type(block) == "table"
                and block.type == "text"
                and type(block.text) == "string"
                and block.text ~= ""
            then
                table.insert(parts, block.text)
            end
        end
        if #parts > 0 then
            return self:safe_split(table.concat(parts, "\n"))
        end
    end
    return nil
end

--- Safely split a string into an array of lines
--- Some agents send `nil` other send `vim.NIL` for empty content
--- @param possible_string string|nil|vim.NIL
--- @return string[] lines
function ACPClient:safe_split(possible_string)
    if type(possible_string) == "string" then
        return vim.split(possible_string, "\n")
    end

    return {}
end

--- Directories a skill loaded in this session may live under, in precedence
--- order (see `SkillPath.roots`). Per session rather than per client: one
--- client serves every tabpage using the provider, and a resumed session
--- carries the cwd it was saved with, not the editor's current one.
--- @param session_id string|nil
--- @return string[] roots Empty for a session this client neither created nor loaded
function ACPClient:session_roots(session_id)
    return session_id and self._session_roots[self:__root_session(session_id)]
        or {}
end

--- Build the message for a tool_call. it's usually the first update received for a tool call
--- Adapters override this to add provider-specific fields or transformations.
--- @protected
--- @param update agentic.acp.ToolCallMessage
--- @param _session_id string|nil Unused here. For overrides that resolve session-scoped state such as `session_roots`
--- @return agentic.ui.MessageWriter.ToolCallBlock message
function ACPClient:__build_tool_call_message(update, _session_id)
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = update.kind,
        status = update.status,
        argument = update.title,
        body = self:extract_content_body(update),
        -- Read only on the initial tool_call: updates can omit it.
        task_id = self:subagent_task_id(update),
        -- On every kind, as a later update or the adapter can re-kind a call.
        shell = self:exec_shell(),
    }

    return message
end

--- Default handler for tool_call session updates.
--- Adapters override this for provider-specific transformations.
--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallMessage
function ACPClient:__handle_tool_call(session_id, update)
    local message = self:__build_tool_call_message(update, session_id)

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- Build the message for a tool_call_update.
--- Adapters override this to add provider-specific fields.
--- @protected
--- @param update agentic.acp.ToolCallUpdate
--- @param _session_id string|nil Unused here. For overrides that resolve session-scoped state such as `session_roots`
--- @return agentic.ui.MessageWriter.ToolCallBase message
function ACPClient:__build_tool_call_update(update, _session_id)
    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
        body = self:extract_content_body(update),
    }
    if update.status == "failed" then
        message.failure_reason = self:extract_failure_reason(update.rawOutput)
    end
    return message
end

--- Default handler for tool_call_update session updates.
--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function ACPClient:__handle_tool_call_update(session_id, update)
    if not update.status then
        return
    end

    local message = self:__build_tool_call_update(update, session_id)

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

--- Handle fs/read_text_file request from the provider.
--- Lets the provider read files outside cwd without hitting the ignore
--- library's ../ rejection.
--- @param message_id number
--- @param params table {sessionId, path, line?, limit?}
function ACPClient:_handle_fs_read(message_id, params)
    local path = params.path
    if not path then
        self:_send_error(
            message_id,
            "Missing 'path' parameter",
            self.ERROR_CODES.INVALID_PARAMS
        )
        return
    end

    local lines, err = FileSystem.read_from_disk(path)
    if not lines then
        self:_send_error(message_id, err or ("Failed to read file: " .. path))
        return
    end

    local start_line = 1
    local end_line = #lines

    if params.line and params.line > 1 then
        start_line = math.min(params.line, #lines + 1)
    end
    if params.limit and params.limit > 0 then
        end_line = math.min(start_line + params.limit - 1, #lines)
    end

    local selected = {}
    for i = start_line, end_line do
        selected[#selected + 1] = lines[i]
    end

    self:__send_result(message_id, { content = table.concat(selected, "\n") })
end

--- Handle fs/write_text_file request from the provider.
--- @param message_id number
--- @param params table {sessionId, path, content}
function ACPClient:_handle_fs_write(message_id, params)
    local path = params.path
    local content = params.content

    if not path or not content then
        self:_send_error(
            message_id,
            "Missing 'path' or 'content' parameter",
            self.ERROR_CODES.INVALID_PARAMS
        )
        return
    end

    local ok, err = FileSystem.save_to_disk(path, content)
    if not ok then
        self:_send_error(message_id, err or ("Failed to write file: " .. path))
        return
    end

    self:__send_result(message_id, {})

    -- Reload the buffer if loaded so the user sees the change.
    -- Must schedule — this runs from a libuv read callback where vim APIs
    -- are unsafe.
    vim.schedule(function()
        FileSystem.reload_buffer(path)
    end)
end

--- @protected
--- @param message_id number
--- @param request agentic.acp.RequestPermission
function ACPClient:__handle_request_permission(message_id, request)
    if not request.sessionId or not request.toolCall then
        error("Invalid request_permission")
        return
    end

    local subscriber = self.subscribers[self:__root_session(request.sessionId)]

    if not subscriber then
        -- No subscriber (session already cancelled) — send cancel immediately
        -- so the provider doesn't wait forever for a permission response.
        Logger.debug("No subscriber for permission request, cancelling")
        self:__send_result(message_id, { outcome = { outcome = "cancelled" } })
        return
    end

    vim.schedule(function()
        local ok, err = pcall(
            subscriber.on_request_permission,
            request,
            function(option_id)
                if option_id then
                    self:__send_result(
                        message_id,
                        { --- @type agentic.acp.RequestPermissionOutcome
                            outcome = {
                                outcome = "selected",
                                optionId = option_id,
                            },
                        }
                    )
                else
                    self:__send_result(
                        message_id,
                        { --- @type agentic.acp.RequestPermissionOutcome
                            outcome = {
                                outcome = "cancelled",
                            },
                        }
                    )
                end
                self:__on_permission_resolved(request, option_id)
            end
        )
        if not ok then
            Logger.notify(
                "Permission handler error, cancelling:\n" .. tostring(err),
                vim.log.levels.ERROR
            )
            self:__send_result(
                message_id,
                { outcome = { outcome = "cancelled" } }
            )
        end
    end)
end

--- Called with the option a permission request was resolved with, after the
--- result is sent. Default: no-op.
--- @protected
--- @param _request agentic.acp.RequestPermission
--- @param _option_id string|nil Nil when the request was cancelled
function ACPClient:__on_permission_resolved(_request, _option_id) end

function ACPClient:stop()
    if self.transport then
        self.transport:stop()
    end
end

--- Stop the provider subprocess and start a new one in this same client
--- object. No ACP session survives the restart: every subscriber gets
--- `on_disconnect`, then is unsubscribed.
--- @param on_ready fun(client: agentic.acp.ACPClient)|nil Runs once the new subprocess is ready, after the waiters of `when_ready`. Dropped when this start does not reach ready
function ACPClient:restart(on_ready)
    self:stop()
    for session_id in pairs(self.subscribers) do
        self:unsubscribe(session_id)
    end
    self:_connect(on_ready)
end

--- Run `on_ready` once the client is ready: at once when it is, else at
--- the next start that reaches ready.
--- @param on_ready fun(client: agentic.acp.ACPClient)
function ACPClient:when_ready(on_ready)
    if self.state == "ready" then
        on_ready(self)
    else
        table.insert(self._ready_waiters, on_ready)
    end
end

--- Start the subprocess and initialize it.
--- @param on_start fun(client: agentic.acp.ACPClient)|nil Runs once this start reaches ready, after the waiters of `when_ready`
function ACPClient:_connect(on_start)
    if self.state ~= "disconnected" or not self.transport then
        return
    end

    -- A stop fails the old subprocess's pending requests after this
    -- connection has started. Their callbacks must not act on the new one.
    self._connection = self._connection + 1
    local connection = self._connection
    -- A new process holds none of the old one's tool call `_meta`.
    self._v2_states = {}

    self.transport:start()

    if self.state ~= "connected" then
        local error = self:__create_error(
            self.ERROR_CODES.PROTOCOL_ERROR,
            "Cannot initialize: client not connected"
        )
        return error
    end

    self:_set_state("initializing")

    --- @type agentic.acp.InitializeParams
    local init_params = {
        protocolVersion = self.protocol_version,
        clientInfo = self.client_info,
        clientCapabilities = self.capabilities,
    }

    self:_send_request("initialize", init_params, function(result, err)
        if connection ~= self._connection then
            return
        end
        -- A process that died also fails this request. It stays
        -- `disconnected`, so a reconnect can start it again.
        if not result or err then
            Logger.notify(
                "Failed to initialize\n\n" .. vim.inspect(err),
                vim.log.levels.ERROR
            )
            if self.state == "initializing" then
                self:_set_state("error")
            end
            return
        end

        --- @cast result agentic.acp.InitializeResponse
        self:_apply_initialize_result(result)

        local function go_ready()
            -- The process can die or stop while `authenticate` waits.
            if self.state ~= "initializing" then
                return
            end
            self:_set_state("ready")
            self._was_ready = true
            -- A waiter that stops or restarts the client leaves the rest
            -- queued for the next ready.
            while self.state == "ready" and self._ready_waiters[1] do
                table.remove(self._ready_waiters, 1)(self)
            end
            if on_start and self.state == "ready" then
                on_start(self)
            end
        end

        -- No notice for an unadvertised `auth_method`: the advertised set can
        -- vary by environment (claude-agent-acp's differs over SSH).
        local startup_method = self:_startup_auth_method()
        if not startup_method then
            go_ready()
            return
        end
        self:authenticate(startup_method.id, function(auth_err)
            if connection ~= self._connection then
                return
            end
            if auth_err then
                Logger.notify(
                    string.format(
                        "Authentication with %s failed: %s",
                        startup_method.name,
                        auth_err.message
                    ),
                    vim.log.levels.WARN
                )
            end
            go_ready()
        end)
    end)
end

--- The configured `auth_method`, when the agent advertises it as an `agent`
--- method, the only kind the client runs unasked.
--- @return agentic.acp.AuthMethod|nil method
function ACPClient:_startup_auth_method()
    local id = self.provider_config.auth_method
    for _, method in ipairs(self.auth_methods or {}) do
        if
            method.id == id
            and ACPClient.auth_method_kind(method) == "agent"
        then
            return method
        end
    end
    return nil
end

--- How an auth method runs: in the agent through `authenticate`, or in the
--- client as an interactive process.
--- @param method agentic.acp.AuthMethod
--- @return "agent"|"terminal"|nil kind Nil for a type this client does not run
function ACPClient.auth_method_kind(method)
    local kind = method.type or "agent"
    if kind == "agent" or kind == "terminal" then
        return kind
    end
    return nil
end

--- Record what the agent reported about itself in the initialize response.
---
--- `agent_info.version` is the provider binary's own version (for
--- claude-agent-acp, its package version). It is persisted with the session
--- so a rendering or protocol regression can be dated to a provider version.
---
--- @protected
--- @param result agentic.acp.InitializeResponse
function ACPClient:_apply_initialize_result(result)
    self.protocol_version = result.protocolVersion
    self.agent_capabilities = result.agentCapabilities
    self.agent_info = result.agentInfo
    self.auth_methods = result.authMethods or {}
end

--- Ask the agent to authenticate with one of its `agent` methods.
--- @param method_id string
--- @param callback fun(err: agentic.acp.ACPError|nil)
function ACPClient:authenticate(method_id, callback)
    self:_send_request("authenticate", {
        methodId = method_id,
    }, function(_result, err)
        callback(err)
    end)
end

--- An interactive process that runs a terminal auth method.
--- @class agentic.acp.TerminalAuthInvocation
--- @field cmd string[] The provider command, its configured args, then the method's args
--- @field env table<string, string> Variables to add to nvim's environment: the provider env with the method's env on top

--- How to run a terminal auth method: the configured agent invocation
--- with the method's args and env added.
--- @param method agentic.acp.AuthMethod A `terminal` method
--- @return agentic.acp.TerminalAuthInvocation
function ACPClient:terminal_auth_invocation(method)
    local config = self.provider_config
    local cmd = { config.command }
    vim.list_extend(cmd, config.args or {})
    vim.list_extend(cmd, method.args or {})

    --- @type agentic.acp.TerminalAuthInvocation
    local invocation = {
        cmd = cmd,
        env = vim.tbl_extend("force", config.env or {}, method.env or {}),
    }
    return invocation
end

--- @param cwd string Working directory of the session
--- @param handlers agentic.acp.ClientHandlers
--- @param callback fun(result: agentic.acp.SessionCreationResponse|nil, err: agentic.acp.ACPError|nil)
function ACPClient:create_session(cwd, handlers, callback)
    local additional_dirs =
        PermissionRules.get_additional_directories(self:claude_config_dir())

    self:_send_request("session/new", {
        cwd = cwd,
        mcpServers = {},
        _meta = self:session_meta(additional_dirs),
    }, function(result, err)
        if err then
            Logger.notify(
                "Failed to create session: "
                    .. (err.message or vim.inspect(err)),
                vim.log.levels.ERROR,
                { title = "🐞 Session creation error" }
            )

            callback(nil, err)
            return
        end

        if not result then
            err = self:__create_error(
                self.ERROR_CODES.PROTOCOL_ERROR,
                "Failed to create session: missing result"
            )

            callback(nil, err)
            return
        end

        if result.sessionId then
            self:_attach_session(
                result.sessionId,
                handlers,
                cwd,
                additional_dirs
            )
            self:_emit_setup_commands(result.sessionId, result)
        end

        --- @cast result agentic.acp.SessionCreationResponse
        callback(result, nil)
    end)
end

--- Send session/load with `handlers` subscribed to `session_id`. An error
--- response unsubscribes them. An agent that does not advertise
--- `loadSession` gets no request, and `callback` gets an error.
--- @param session_id string
--- @param cwd string
--- @param mcp_servers table[]|nil
--- @param handlers agentic.acp.ClientHandlers
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:load_session(
    session_id,
    cwd,
    mcp_servers,
    handlers,
    callback
)
    if
        not self.agent_capabilities or not self.agent_capabilities.loadSession
    then
        -- Scheduled like every response callback, so no caller sees its
        -- callback run before `load_session` returns.
        vim.schedule(function()
            callback(nil, {
                code = self.ERROR_CODES.PROTOCOL_ERROR,
                message = "Agent does not support loading sessions",
            })
        end)
        return
    end

    self._loading_sessions[session_id] = true

    local additional_dirs =
        PermissionRules.get_additional_directories(self:claude_config_dir())
    -- Before the request: the bridge replays the session's tool calls as
    -- notifications, which must not outrun the roots they resolve against.
    self:_attach_session(session_id, handlers, cwd, additional_dirs)

    self:_send_request("session/load", {
        sessionId = session_id,
        cwd = cwd,
        mcpServers = mcp_servers or {},
        _meta = self:session_meta(additional_dirs),
    }, function(result, err)
        self._loading_sessions[session_id] = nil
        if err then
            self:unsubscribe(session_id)
        elseif result then
            self:_emit_setup_commands(session_id, result)
        end
        callback(result, err)
    end)
end

--- Whether the agent can fork a session cut after the response
--- `response_id`: it advertises `session/fork` and the provider has a fork
--- point (`fork_point_meta`).
--- @param response_id string
--- @return boolean
function ACPClient:can_fork(response_id)
    local session_caps = self.agent_capabilities
        and self.agent_capabilities.sessionCapabilities
    return session_caps ~= nil
        and session_caps.fork ~= nil
        and self:fork_point_meta(response_id) ~= nil
end

--- Send `session/fork` for `session_id`, the copy cut after the response
--- `response_id`, and subscribe `handlers` to the new session. Sends nothing
--- when `can_fork(response_id)` is false, and `callback` gets an error.
--- @param session_id string
--- @param cwd string Working directory of the new session
--- @param response_id string
--- @param handlers agentic.acp.ClientHandlers
--- @param callback fun(result: agentic.acp.ForkSessionResponse|nil, err: agentic.acp.ACPError|nil)
function ACPClient:fork_session(
    session_id,
    cwd,
    response_id,
    handlers,
    callback
)
    if not self:can_fork(response_id) then
        -- Scheduled like every response callback, so no caller sees its
        -- callback run before `fork_session` returns.
        vim.schedule(function()
            callback(nil, {
                code = self.ERROR_CODES.PROTOCOL_ERROR,
                message = "Agent cannot fork sessions at a response",
            })
        end)
        return
    end

    local additional_dirs =
        PermissionRules.get_additional_directories(self:claude_config_dir())

    self:_send_request("session/fork", {
        sessionId = session_id,
        cwd = cwd,
        mcpServers = {},
        _meta = vim.tbl_deep_extend(
            "force",
            self:session_meta(additional_dirs) or {},
            self:fork_point_meta(response_id) --[[@as table]]
        ),
    }, function(result, err)
        if err or not (result and result.sessionId) then
            callback(
                nil,
                err
                    or self:__create_error(
                        self.ERROR_CODES.PROTOCOL_ERROR,
                        "Failed to fork session: missing result"
                    )
            )
            return
        end
        self:_attach_session(result.sessionId, handlers, cwd, additional_dirs)
        self:_emit_setup_commands(result.sessionId, result)
        --- @cast result agentic.acp.ForkSessionResponse
        callback(result, nil)
    end)
end

--- Send `prompt` to the session `session_id`. The subscriber's
--- `on_prompt_taken` and `on_turn_state` report what becomes of it. ACP v2
--- sends both; for ACP v1 they are derived here: the prompt is taken in when
--- sent, which starts a turn when none runs, and each answer ends the turn
--- `idle` with the answer's stop reason, then starts the next while prompts
--- are still unanswered.
--- @param session_id string A root session
--- @param prompt agentic.acp.Content[]
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil) Gets the answer. ACP v2 answers `{messageId}` once the prompt is taken in, or an error when it never is (`REQUEST_CANCELLED` when a cancel ended it before)
function ACPClient:send_prompt(session_id, prompt, callback)
    local params = {
        sessionId = session_id,
        prompt = prompt,
    }

    if self.protocol_version == 2 then
        self:_send_request("session/prompt", params, callback)
        return
    end

    -- Called directly, not through `__with_subscriber`: a later update must
    -- not reach the subscriber ahead of these.
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
        -- Looked up again: the session may have been unsubscribed meanwhile.
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

--- Set the agent mode for a session
--- @param session_id string
--- @param mode_id string
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:set_mode(session_id, mode_id, callback)
    local params = {
        sessionId = session_id,
        modeId = mode_id,
    }

    self:_send_request("session/set_mode", params, callback)
end

--- Set a config option value for a session
--- @param session_id string
--- @param config_id string
--- @param config_value string
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:set_config_option(
    session_id,
    config_id,
    config_value,
    callback
)
    local params = {
        sessionId = session_id,
        configId = config_id,
        value = config_value,
    }

    self:_send_request("session/set_config_option", params, callback)
end

--- Set the provided model to the session
--- @param session_id string
--- @param model_id string
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:set_model(session_id, model_id, callback)
    local params = {
        sessionId = session_id,
        modelId = model_id,
    }

    self:_send_request("session/set_model", params, callback)
end

--- Send `session/cancel`, which stops the session's current work.
--- @param session_id string A main session, or a subagent
function ACPClient:stop_generation(session_id)
    self:_send_notification("session/cancel", {
        sessionId = session_id,
    })
end

--- Unsubscribe the session, then send `session/cancel` for it. Updates that
--- the cancel provokes are not delivered.
--- @param session_id string
function ACPClient:cancel_session(session_id)
    self:unsubscribe(session_id)

    self:_send_notification("session/cancel", {
        sessionId = session_id,
    })
end

--- End a session. Unsubscribe it, then send `session/close` when the agent
--- advertises it, else `session/cancel`. A failed close is shown as a
--- warning.
--- @param session_id string
--- @param on_closed fun() Runs after the agent answers `session/close`, so
--- after the session's cancelled turns have answered. Without the capability,
--- runs on the next event loop tick
function ACPClient:close_session(session_id, on_closed)
    local session_caps = self.agent_capabilities
        and self.agent_capabilities.sessionCapabilities
    if not (session_caps and session_caps.close) then
        self:cancel_session(session_id)
        vim.schedule(on_closed)
        return
    end

    self:unsubscribe(session_id)
    -- Not in `unsubscribe`: claude-agent-acp keeps a session's tool call
    -- `_meta` until `session/close`, and replays a later load as patches
    -- against it.
    self._v2_states[session_id] = nil
    self:_send_request("session/close", {
        sessionId = session_id,
    }, function(_result, err)
        if err then
            Logger.notify(
                "Failed to close session: " .. (err.message or vim.inspect(err)),
                vim.log.levels.WARN
            )
        end
        on_closed()
    end)
end

return ACPClient
