local AcpKind = require("agentic.utils.acp_kind")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local LogLine = require("agentic.utils.log_line")
local Logger = require("agentic.utils.logger")
local PermissionRules = require("agentic.utils.permission_rules")
local SkillPath = require("agentic.utils.skill_path")
local ToolCallKinds = require("agentic.acp.tool_call_kinds")
local transport_module = require("agentic.acp.acp_transport")

--[[
CRITICAL: Type annotations in this file are essential for Lua Language Server support.
DO NOT REMOVE them. Only update them if the underlying types change.
--]]

--- Data fields set in the constructor. Separated from the full class
--- so LuaLS validates instance fields without requiring methods that
--- live on the prototype via __index.
--- @class agentic.acp.ACPClientData
--- @field provider_config agentic.acp.ACPProviderConfig
--- @field id_counter number
--- @field state agentic.acp.ClientConnectionState
--- @field protocol_version number
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
--- @field _on_ready fun(client: agentic.acp.ACPClient)
--- @field _notified_output table<string, true> Process output summaries already shown as a notification by this client
--- @field _loading_sessions table<string, boolean> Session IDs currently being loaded via session/load
--- @field _children table<string, string> Child session id → the subscribed root session that spawned it, directly or through other children
--- @field _session_roots table<string, string[]> Skill-search roots per session, from the cwd and additional directories that session was opened with
--- @field _tool_call_kinds agentic.acp.ToolCallKinds
local ACPClient = {}
ACPClient.__index = ACPClient

--- ACP Error codes
ACPClient.ERROR_CODES = {
    -- ACP / JSON-RPC codes
    AUTH_REQUIRED = -32000,
    INVALID_PARAMS = -32602,
    INTERNAL_ERROR = -32603,
    -- Client-side only, never sent: outside the JSON-RPC reserved range
    TRANSPORT_ERROR = -1,
    PROTOCOL_ERROR = -2,
}

--- Set up a child adapter class with proper ACPClient inheritance chain.
--- Returns a new class table with __index set for method lookup.
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
        protocol_version = 1,
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
            -- Opt into claude-agent-acp forwarding subagent (Task) assistant
            -- text/thinking as parentToolUseId-tagged notifications (bridge
            -- filters them out for clients that don't advertise this).
            _meta = { ["subagent-transcript"] = true },
            -- Each subagent becomes a child session, announced and tracked by
            -- `subagent_update`, its messages sent as `session_message`.
            subagents = vim.empty_dict(),
        },
        callbacks = {},
        transport = nil,
        state = "disconnected",
        reconnect_count = 0,
    }

    local client = setmetatable(instance, self) --[[@as agentic.acp.ACPClient]]
    client._on_ready = on_ready
    client._loading_sessions = {}
    client._children = {}
    client._session_roots = {}
    client._tool_call_kinds = ToolCallKinds:new()
    client._notified_output = {}

    client:_setup_transport()
    client:_connect()
    return client
end

--- @param session_id string
--- @param handlers agentic.acp.ClientHandlers
function ACPClient:_subscribe(session_id, handlers)
    self.subscribers[session_id] = handlers
end

--- Stop routing this session's notifications, and drop the per-session state
--- that exists only to serve them. Every caller that abandons a session goes
--- through here, so the parallel maps cannot drift apart.
--- @param session_id string
function ACPClient:unsubscribe(session_id)
    self.subscribers[session_id] = nil
    self._session_roots[session_id] = nil
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
--- @field task_id string Id of the tool use that spawned the agent

--- What the provider recorded about a subagent's spawn. Adapters for
--- providers that keep such a record override this.
--- @param _session_id string The root session
--- @param _child_id string The subagent's child session id
--- @return agentic.acp.SubagentRecord|nil record Nil while there is none
function ACPClient:subagent_record(_session_id, _child_id)
    return nil
end

--- The id of the tool use that spawned the subagent an update belongs to.
--- Adapters for providers that tag subagent updates override this.
--- @param _update agentic.acp.SessionUpdateMessage
--- @return string|nil task_id Nil for an update that is not a subagent's
function ACPClient:subagent_task_id(_update)
    return nil
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

--- A prompt for the main agent to stop a background subagent. Adapters for
--- providers whose main agent can stop one override this.
--- @param _agent_id string Id addressing the subagent
--- @param _label string Display name of the subagent
--- @return string|nil instruction Nil when the main agent cannot stop it
function ACPClient:subagent_stop_instruction(_agent_id, _label)
    return nil
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
--- @param session_id string
--- @return string root_id
function ACPClient:_root_session(session_id)
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
    local subscriber = self.subscribers[self:_root_session(session_id)]

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

    local suffix = Config.log
            and " (logs in " .. Logger.LOG_DIR .. ")"
        or ""
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
                if self.state == "disconnected" then
                    self:_connect()
                end
            end,
            on_stdout_line = function(line)
                self:_on_process_output("stdout", line)
            end,
            on_stderr_line = function(line)
                self:_on_process_output("stderr", line)
            end,
            get_reconnect_count = function()
                return self.reconnect_count
            end,
            increment_reconnect_count = function()
                self.reconnect_count = self.reconnect_count + 1
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
        for session_id in pairs(self.subscribers) do
            self:__with_subscriber(session_id, function(subscriber)
                if subscriber.on_disconnect then
                    subscriber.on_disconnect()
                end
            end)
        end
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

--- @param method string
--- @param params table|nil
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:_send_request(method, params, callback)
    local id = self:_next_id()
    local message = {
        jsonrpc = "2.0",
        id = id,
        method = method,
        params = params or {},
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

    -- Check if this is a notification (has method but no id, or has both method and id for notifications)
    if message.method and not message.result and not message.error then
        -- This is a notification
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
    if method == "session/update" then
        self:__handle_session_update(params)
    elseif method == "session/request_permission" then
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
    local root = self:_root_session(session_id)
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
    local root = self:_root_session(session_id)

    -- Recorded here rather than by the subscriber: the child's own updates
    -- follow at once, and the subscriber runs a tick later.
    if
        session_update_type == "subagent_update"
        and update.sessionId ~= session_id
        and self.subscribers[root]
    then
        self._children[update.sessionId] = root
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
--- For failed tool calls this is the unwrapped error/denial text — preferable
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
--- client serves every tabpage using the provider, and a restored session
--- carries the cwd it was saved with, not the editor's current one.
--- @param session_id string|nil
--- @return string[] roots Empty for a session this client neither created nor loaded
function ACPClient:session_roots(session_id)
    return session_id and self._session_roots[self:_root_session(session_id)]
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
        parent_tool_use_id = self:subagent_task_id(update),
        -- On every kind, as a later update or the adapter can re-kind a call.
        shell = self:exec_shell(),
    }

    return message
end

--- Default handler for tool_call session updates.
--- Builds a generic ToolCallBlock from standard ACP fields.
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
--- Reads the file from disk and sends the content back. This lets the provider
--- read files outside cwd without hitting the ignore library's ../ rejection.
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
--- Writes content to disk and sends an empty result back.
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
        -- Use write_file's reload pattern (same as FileSystem.write_file)
        local abs = FileSystem.to_absolute_path(path)
        local bufnr = nil
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if
                vim.api.nvim_buf_is_loaded(b)
                and vim.api.nvim_buf_get_name(b) == abs
            then
                bufnr = b
                break
            end
        end
        if not bufnr then
            return
        end
        local reload_ok, reload_err = pcall(function()
            local disk_lines = FileSystem.read_from_disk(path)
            if disk_lines then
                local was_modifiable =
                    vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
                vim.api.nvim_set_option_value(
                    "modifiable",
                    true,
                    { buf = bufnr }
                )
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, disk_lines)
                vim.api.nvim_set_option_value(
                    "modifiable",
                    was_modifiable,
                    { buf = bufnr }
                )
                vim.api.nvim_set_option_value(
                    "modified",
                    false,
                    { buf = bufnr }
                )
            end
        end)
        if not reload_ok then
            Logger.debug("Buffer reload error after fs/write:", reload_err)
        end
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

    local subscriber = self.subscribers[self:_root_session(request.sessionId)]

    if not subscriber then
        -- No subscriber (session already cancelled) — send cancel immediately
        -- so the provider doesn't wait forever for a permission response.
        Logger.debug("No subscriber for permission request, cancelling")
        self:__send_result(message_id, { outcome = { outcome = "cancelled" } })
        return
    end

    vim.schedule(function()
        -- Every change to this block MUST be reflected in Gemini's ACP Adapter, as it has custom implementation @see gemini_acp_adapter.lua
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

function ACPClient:stop()
    if self.transport then
        self.transport:stop()
    end
end

function ACPClient:_connect()
    if self.state ~= "disconnected" or not self.transport then
        return
    end

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
        if not result or err then
            self:_set_state("error")
            Logger.notify(
                "Failed to initialize\n\n" .. vim.inspect(err),
                vim.log.levels.ERROR
            )
            return
        end

        --- @cast result agentic.acp.InitializeResponse
        self:_apply_initialize_result(result)

        local function go_ready()
            self:_set_state("ready")
            self._on_ready(self)
        end

        -- No notice for an unadvertised `auth_method`: the advertised set can
        -- vary by environment (claude-agent-acp's differs over SSH).
        local startup_method = self:_startup_auth_method()
        if not startup_method then
            go_ready()
            return
        end
        self:authenticate(startup_method.id, function(auth_err)
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
        if method.id == id and ACPClient.auth_method_kind(method) == "agent" then
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
    local additional_dirs = PermissionRules.get_additional_directories()

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
            self:_subscribe(result.sessionId, handlers)
            self._session_roots[result.sessionId] =
                SkillPath.roots(cwd, additional_dirs)
        end

        --- @cast result agentic.acp.SessionCreationResponse
        callback(result, nil)
    end)
end

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

    self:_subscribe(session_id, handlers)
    self._loading_sessions[session_id] = true

    local additional_dirs = PermissionRules.get_additional_directories()
    -- Before the request: the bridge replays the session's tool calls as
    -- notifications, which must not outrun the roots they resolve against.
    self._session_roots[session_id] = SkillPath.roots(cwd, additional_dirs)

    self:_send_request("session/load", {
        sessionId = session_id,
        cwd = cwd,
        mcpServers = mcp_servers or {},
        _meta = self:session_meta(additional_dirs),
    }, function(result, err)
        self._loading_sessions[session_id] = nil
        callback(result, err)
    end)
end

--- @param session_id string
--- @param prompt agentic.acp.Content[]
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function ACPClient:send_prompt(session_id, prompt, callback)
    local params = {
        sessionId = session_id,
        prompt = prompt,
    }

    self:_send_request("session/prompt", params, callback)
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

--- Send `session/cancel` for the session. The session stays subscribed and
--- can take the next prompt.
--- @param session_id string
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

return ACPClient

--- @class agentic.acp.ClientInfo
--- @field name string
--- @field version string

--- @class agentic.acp.ClientCapabilities
--- @field fs agentic.acp.FileSystemCapability
--- @field terminal boolean
--- @field auth { terminal: boolean } `terminal`: the client runs `terminal` auth methods
--- @field _meta? { ["subagent-transcript"]?: boolean }
--- @field subagents? table Empty object that opts into native subagent sessions, unstable in the ACP schema

--- @class agentic.acp.InitializeParams
--- @field protocolVersion number
--- @field clientInfo agentic.acp.ClientInfo
--- @field clientCapabilities agentic.acp.ClientCapabilities

--- @class agentic.acp.AgentInfo
--- @field name string
--- @field title? string
--- @field version string

--- @class agentic.acp.InitializeResponse
--- @field protocolVersion number
--- @field agentCapabilities? agentic.acp.AgentCapabilities
--- @field agentInfo? agentic.acp.AgentInfo
--- @field authMethods? agentic.acp.AuthMethod[]

--- @class agentic.acp.FileSystemCapability
--- @field readTextFile boolean
--- @field writeTextFile boolean

--- @class agentic.acp.AgentCapabilities
--- @field loadSession boolean
--- @field promptCapabilities agentic.acp.PromptCapabilities

--- @class agentic.acp.PromptCapabilities
--- @field image boolean
--- @field audio boolean
--- @field embeddedContext boolean

--- @class agentic.acp.AuthMethod
--- @field id string
--- @field name string
--- @field description? string
--- @field type? string "agent" (also when absent), "terminal", or a type this client does not run
--- @field args? string[]
--- @field env? table<string, string>

--- Which credential resolved, as the agent reports it. `kind` follows the
--- agent's own credential precedence, which need not match how the user
--- logged in — claude-agent-acp ranks an `apiKeyHelper` above a subscription.
--- `detail` and `vendor` populate only for the non-subscription kinds.
--- @class agentic.acp.AuthStatus
--- @field kind "account"|"api_key"|"gateway"|"external"|"none"
--- @field label string UI-ready name, e.g. "Claude Team", "Anthropic API key"
--- @field detail? string Second line, e.g. key source or gateway host
--- @field account? agentic.acp.AuthAccount
--- @field vendor? table<string, table> Namespaced extras, e.g. `claudeCode`

--- @class agentic.acp.AuthAccount
--- @field email? string
--- @field organization? string
--- @field plan? string

--- @class agentic.acp.McpServer
--- @field name string
--- @field command string
--- @field args string[]
--- @field env agentic.acp.EnvVariable[]

--- @class agentic.acp.EnvVariable
--- @field name string
--- @field value string

--- @alias agentic.acp.StopReason
--- | "end_turn"
--- | "max_tokens"
--- | "max_turn_requests"
--- | "refusal"
--- | "cancelled"

--- A tool kind on the wire (`AcpKind.PROTOCOL_KINDS`) or one an adapter minted
--- on top of it. The minted half is deliberately left as `string` rather than
--- enumerated: `ClaudeUtils.TOOL_KINDS` is where those live, and a second copy
--- here is a second thing to drift.
--- @alias agentic.acp.ToolKind
--- | "read"
--- | "edit"
--- | "delete"
--- | "move"
--- | "search"
--- | "execute"
--- | "think"
--- | "fetch"
--- | "other"
--- | "create"
--- | "write"
--- | "switch_mode"
--- | string

--- @alias agentic.acp.ToolCallStatus
--- | "pending"
--- | "in_progress"
--- | "completed"
--- | "failed"

--- @alias agentic.acp.PlanEntryStatus
--- | "pending"
--- | "in_progress"
--- | "completed"

--- @alias agentic.acp.PlanEntryPriority
--- | "high"
--- | "medium"
--- | "low"

--- @class agentic.acp.RawInput
--- @field file_path? string
--- @field new_string? string
--- @field old_string? string
--- @field replace_all? boolean
--- @field description? string
--- @field command? string
--- @field pattern? string Search pattern from Grep/search tools
--- @field url? string Usually from the fetch tool
--- @field prompt? string Usually accompanying the fetch tool, not the web_search
--- @field query? string Usually from the web_search tool
--- @field timeout? number

--- @class agentic.acp.ToolCall
--- @field toolCallId string
--- @field kind? agentic.acp.ToolKind
--- @field rawInput? agentic.acp.RawInput

--- @class agentic.acp.ToolCallRegularContent
--- @field type "content"
--- @field content agentic.acp.Content

--- @class agentic.acp.ToolCallDiffContent
--- @field type "diff"
--- @field path string
--- @field oldText string|vim.NIL Null for a Write, which sends no old side
--- @field newText string

--- @alias agentic.acp.ACPToolCallContent
--- | agentic.acp.ToolCallRegularContent
--- | agentic.acp.ToolCallDiffContent

--- @class agentic.acp.ToolCallLocation
--- @field path string
--- @field line? number

--- @class agentic.acp.PlanEntry
--- @field content string
--- @field priority agentic.acp.PlanEntryPriority
--- @field status agentic.acp.PlanEntryStatus

--- @class agentic.acp.AvailableCommand
--- @field name string
--- @field description string
--- @field input? table<string, any>

--- @class agentic.acp.AgentMode
--- @field id string
--- @field name string
--- @field description? string

--- @class agentic.acp.Model
--- @field modelId string
--- @field name string
--- @field description string

--- @class agentic.acp.ModesInfo
--- @field availableModes agentic.acp.AgentMode[]
--- @field currentModeId string

--- @class agentic.acp.ModelsInfo
--- @field availableModels agentic.acp.Model[]
--- @field currentModelId string

--- @class agentic.acp.ConfigOption.Option
--- @field description string
--- @field name string
--- @field value string

--- @alias agentic.acp.ConfigOption.Category
--- | "mode"
--- | "model"
--- | "thought_level"

--- @class agentic.acp.ConfigOption
--- @field id string
--- @field category agentic.acp.ConfigOption.Category
--- @field currentValue string
--- @field description string
--- @field name string
--- @field options agentic.acp.ConfigOption.Option[]

--- @class agentic.acp.SessionCreationResponse
--- @field sessionId string
--- @field modes? agentic.acp.ModesInfo
--- @field models? agentic.acp.ModelsInfo
--- @field configOptions? agentic.acp.ConfigOption[]

--- @class agentic.acp.ResponseRaw
--- @field id? number
--- @field jsonrpc string
--- @field method string
--- @field result? table
--- @field params? { sessionId: string, update: agentic.acp.SessionUpdateMessage }
--- @field error? agentic.acp.ACPError

--- One hunk of a `structuredPatch`. Line numbers and counts are of the
--- post-edit file; `newLines` is 0 for a hunk that only deletes.
--- @class agentic.acp.ClaudePatchHunk
--- @field newStart integer
--- @field newLines integer

--- A tool's own return value, forwarded verbatim. Only the Edit/Write and Agent
--- shapes are modelled, since those are the ones the client reads: `type` is
--- Write-only and says whether the file was created or overwritten, Edit omits
--- it entirely.
--- @class agentic.acp.ClaudeToolResponse
--- @field filePath? string
--- @field type? "create"|"update"
--- @field structuredPatch? agentic.acp.ClaudePatchHunk[]
--- @field status? string Outcome of an Agent call: `completed`, `async_launched` or `remote_launched`
--- @field agentId? string Id of the agent an Agent call launched in the background

--- claude-agent-acp per-notification metadata. `parentToolUseId` is set on
--- subagent (Task) notifications — present ⟺ subagent content. `toolName` is
--- the provider's internal tool name, set on every tool-call notification.
--- @class agentic.acp.ClaudeCodeMeta
--- @field parentToolUseId? string
--- @field toolName? string
--- @field toolResponse? agentic.acp.ClaudeToolResponse
--- @field skill? string Skill name, on a Skill tool call
--- @field skillPath? string The skill's SKILL.md, resolved by the bridge against `cwd` and `$HOME` only — absent for a skill discovered under any other root

--- @class agentic.acp.ClaudeMeta
--- @field claudeCode? agentic.acp.ClaudeCodeMeta

--- @class agentic.acp.ToolCallMessage
--- @field sessionUpdate "tool_call"
--- @field toolCallId string
--- @field title string most likely the command to be executed
--- @field kind agentic.acp.ToolKind
--- @field status agentic.acp.ToolCallStatus
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field locations? agentic.acp.ToolCallLocation[]
--- @field rawInput? agentic.acp.RawInput
--- @field public _meta? agentic.acp.ClaudeMeta

--- @class agentic.acp.ToolCallUpdate
--- @field sessionUpdate "tool_call_update"
--- @field toolCallId string
--- @field kind? agentic.acp.ToolKind
--- @field status? agentic.acp.ToolCallStatus
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field locations? agentic.acp.ToolCallLocation[]
--- @field rawOutput? string|table Plain string or array of content blocks (`{type="text",text=...}`). claude-agent-acp forwards `ToolResultBlockParam.content` here. Non-standard across providers.
--- @field public _meta? agentic.acp.ClaudeMeta

--- @class agentic.acp.PlanUpdate
--- @field sessionUpdate "plan"
--- @field entries agentic.acp.PlanEntry[]

--- @class agentic.acp.AvailableCommandsUpdate
--- @field sessionUpdate "available_commands_update"
--- @field availableCommands agentic.acp.AvailableCommand[]

--- @class agentic.acp.CurrentModeUpdate
--- @field sessionUpdate "current_mode_update"
--- @field currentModeId string

--- @class agentic.acp.UsageUpdate
--- @field sessionUpdate "usage_update"
--- @field used number Tokens currently in context
--- @field size number Total context window size in tokens
--- @field cost? { amount: number, currency: string } Cumulative session cost. Omitted on rate-limit-triggered updates.
--- @field public _meta? table

--- @class agentic.acp.ConfigOptionsUpdate
--- @field sessionUpdate "config_option_update"
--- @field configOptions agentic.acp.ConfigOption[]

--- @class agentic.acp.SessionInfoUpdateMessage
--- @field sessionUpdate "session_info_update"
--- @field title string SDK-maintained title (`/rename`'d or auto-generated)
--- @field updatedAt? string ISO 8601 timestamp of the session file

--- The work state of a subagent: `running` or `requires_action` while it
--- works, `idle` once its work ended (no `stopReason` when the reason is not
--- known), `unknown` when it can no longer be observed. A `_`-prefixed state
--- is a custom one.
--- @class agentic.acp.SubagentWorkState
--- @field state "running"|"requires_action"|"idle"|"unknown"|string
--- @field stopReason? "end_turn"|"cancelled"|"error"|"max_tokens"|"max_turn_requests"|"refusal"|vim.NIL
--- @field error? { code: integer, message: string }|vim.NIL

--- A child session of the session it arrives on, announced or changed.
--- Patch semantics: an omitted field keeps its value, `vim.NIL` clears it.
--- @class agentic.acp.SubagentUpdate
--- @field sessionUpdate "subagent_update"
--- @field sessionId string The child session
--- @field title? string|vim.NIL
--- @field description? string|vim.NIL
--- @field capabilities? { cancel?: table }|vim.NIL
--- @field state? agentic.acp.SubagentWorkState|vim.NIL

--- One view of a message between two sessions: the sender's on the sender's
--- session, the recipient's on the recipient's.
--- @class agentic.acp.SessionMessage
--- @field sessionUpdate "session_message"
--- @field messageId string
--- @field senderSessionId? string
--- @field recipientSessionId? string
--- @field content? agentic.acp.Content[]|vim.NIL
--- @field recipientMessageId? string
--- @field senderMessageId? string

--- @alias agentic.acp.SessionUpdateMessage
--- | agentic.acp.SubagentUpdate
--- | agentic.acp.SessionMessage
--- | agentic.acp.UserMessageChunk
--- | agentic.acp.AgentMessageChunk
--- | agentic.acp.AgentThoughtChunk
--- | agentic.acp.ToolCallMessage
--- | agentic.acp.ToolCallUpdate
--- | agentic.acp.PlanUpdate
--- | agentic.acp.AvailableCommandsUpdate
--- | agentic.acp.CurrentModeUpdate
--- | agentic.acp.UsageUpdate
--- | agentic.acp.ConfigOptionsUpdate
--- | agentic.acp.SessionInfoUpdateMessage

--- @class agentic.acp.PermissionOption
--- @field optionId string
--- @field name string
--- @field kind "allow_once" | "allow_always" | "reject_once" | "reject_always"

--- @class agentic.acp.RequestPermission
--- @field options agentic.acp.PermissionOption[]
--- @field sessionId string
--- @field toolCall agentic.acp.ToolCall

--- @class agentic.acp.RequestPermissionOutcome
--- @field outcome "cancelled" | "selected"
--- @field optionId? string

--- @alias agentic.acp.ClientConnectionState
--- | "disconnected"
--- | "connecting"
--- | "connected"
--- | "initializing"
--- | "ready"
--- | "error"

--- @class agentic.acp.ACPError
--- @field code number
--- @field message string
--- @field data? any

--- @alias agentic.acp.ClientHandlers.on_session_update fun(update: agentic.acp.SessionUpdateMessage, source_session_id: string|nil): nil
--- @alias agentic.acp.ClientHandlers.on_request_permission fun(request: agentic.acp.RequestPermission, callback: fun(option_id: string | nil)): nil

--- @class agentic.Selection
--- @field lines string[] The selected code lines
--- @field start_line integer Starting line number (1-indexed)
--- @field end_line integer Ending line number (1-indexed, inclusive)
--- @field file_path string Relative file path
--- @field file_type string File type/extension

--- Handlers for a specific session. Each session subscribes with its own handlers.
--- @class agentic.acp.ClientHandlers
--- @field on_session_update agentic.acp.ClientHandlers.on_session_update
--- @field on_request_permission agentic.acp.ClientHandlers.on_request_permission
--- @field on_tool_call fun(tool_call: agentic.ui.MessageWriter.ToolCallBlock, source_session_id: string|nil): nil
--- @field on_tool_call_update fun(tool_call: agentic.ui.MessageWriter.ToolCallBase, source_session_id: string|nil): nil
--- @field on_disconnect? fun(): nil The provider process died or failed

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
