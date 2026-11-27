--- The client of one provider: its processes, sessions and prompts. Methods
--- without a default raise until a subclass overrides them.
--- @class agentic.AgentClient
--- @field state agentic.AgentClient.ClientConnectionState
--- @field subscribers table<string, agentic.AgentClient.ClientHandlers> Handlers per root session id
--- @field provider_name agentic.UserConfig.ProviderName Config key of the provider this client runs
--- @field provider_config agentic.UserConfig.Pi
--- @field agent_info? agentic.acp.AgentInfo
--- @field agent_capabilities? agentic.acp.AgentCapabilities
--- @field auth_methods? agentic.acp.AuthMethod[]
--- @field auth_status? agentic.acp.AuthStatus Identity the agent process authenticates with; nil while none is reported, which is distinct from a reported `kind = "none"`
--- @field login_job? vim.SystemObj|table The running login: a terminal method's process, or a token while an authenticate request is out
--- @field usage_limit agentic.acp.UsageLimit The provider account's usage limit. A restart keeps it
local AgentClient = {}
AgentClient.__index = AgentClient

--- The state of a session's foreground work, as a client reports it to a
--- subscriber.
--- @class agentic.AgentClient.TurnState
--- @field state "running"|"requires_action"|"idle"
--- @field stop_reason? agentic.acp.StopReason|"error" With `idle` at a turn's end; nil on a resume snapshot
--- @field usage? table
--- @field error? agentic.AgentClient.Error With `idle` when the work failed
--- @field more? boolean With `idle`: other prompts are still waiting, and the next turn starts at once

--- @class agentic.AgentClient.Error
--- @field code number
--- @field message string
--- @field data? any

--- A new subclass of `AgentClient`. It inherits every method it does not
--- override, `new` included.
--- @return table child_class
function AgentClient.extend()
    local Child = setmetatable({}, { __index = AgentClient })
    Child.__index = Child
    return Child
end

--- Fail `callback` with `METHOD_NOT_FOUND` on a later event-loop iteration,
--- as a provider answer would arrive.
--- @param callback fun(result: nil, err: agentic.AgentClient.Error)
local function not_supported(callback)
    vim.schedule(function()
        callback(nil, {
            code = AgentClient.ERROR_CODES.METHOD_NOT_FOUND,
            message = "Not supported by this provider",
        })
    end)
end

--- @param name string
local function not_implemented(name)
    error("AgentClient:" .. name .. " is not implemented by this client")
end

--- @param _config agentic.UserConfig.Pi
--- @param _on_ready fun(client: agentic.AgentClient)
--- @return agentic.AgentClient
function AgentClient:new(_config, _on_ready)
    not_implemented("new")
    return self
end

--- Stop the provider processes and start again in this same client object.
--- No session survives the restart: every subscriber gets `on_disconnect`,
--- then is unsubscribed.
--- @param _on_ready fun(client: agentic.AgentClient)|nil Runs once the client is ready again
function AgentClient:restart(_on_ready)
    not_implemented("restart")
end

--- Run `on_ready` once the client is ready: at once when it is, else at the
--- next start that reaches ready.
--- @param _on_ready fun(client: agentic.AgentClient)
function AgentClient:when_ready(_on_ready)
    not_implemented("when_ready")
end

--- Stop the provider processes.
function AgentClient:stop()
    not_implemented("stop")
end

--- Start a session in `cwd` and subscribe `handlers` to it.
--- @param _cwd string Working directory of the session
--- @param _handlers agentic.AgentClient.ClientHandlers
--- @param _callback fun(result: agentic.acp.SessionCreationResponse|nil, err: agentic.AgentClient.Error|nil)
function AgentClient:create_session(_cwd, _handlers, _callback)
    not_implemented("create_session")
end

--- Resume the provider's session `session_id` with `handlers` subscribed to
--- it. A failure unsubscribes them.
--- @param _session_id string
--- @param _cwd string
--- @param _mcp_servers table[]|nil
--- @param _handlers agentic.AgentClient.ClientHandlers
--- @param _callback fun(result: table|nil, err: agentic.AgentClient.Error|nil)
function AgentClient:load_session(
    _session_id,
    _cwd,
    _mcp_servers,
    _handlers,
    _callback
)
    not_implemented("load_session")
end

--- Whether the provider can fork a session cut after the response
--- `response_id`. The default cannot.
--- @param _response_id string
--- @return boolean
function AgentClient:can_fork(_response_id)
    return false
end

--- Fork `session_id` cut after the response `response_id`, and subscribe
--- `handlers` to the new session. The default fails with
--- `METHOD_NOT_FOUND`.
--- @param _session_id string
--- @param _cwd string Working directory of the new session
--- @param _response_id string
--- @param _handlers agentic.AgentClient.ClientHandlers
--- @param callback fun(result: agentic.acp.ForkSessionResponse|nil, err: agentic.AgentClient.Error|nil)
function AgentClient:fork_session(
    _session_id,
    _cwd,
    _response_id,
    _handlers,
    callback
)
    not_supported(callback)
end

--- Send `prompt` to the session `session_id`. The subscriber's
--- `on_prompt_taken` and `on_turn_state` report what becomes of it.
--- @param _session_id string A root session
--- @param _prompt agentic.acp.Content[]
--- @param _callback fun(result: table|nil, err: agentic.AgentClient.Error|nil) Gets the answer, or an error when the prompt is never taken in (`REQUEST_CANCELLED` when a stop ended it before)
function AgentClient:send_prompt(_session_id, _prompt, _callback)
    not_implemented("send_prompt")
end

--- Set a config option value of a session.
--- @param _session_id string
--- @param _config_id string
--- @param _config_value string
--- @param _callback fun(result: table|nil, err: agentic.AgentClient.Error|nil)
function AgentClient:set_config_option(
    _session_id,
    _config_id,
    _config_value,
    _callback
)
    not_implemented("set_config_option")
end

--- Stop the session's current work.
--- @param _session_id string A main session, or a subagent
function AgentClient:stop_generation(_session_id)
    not_implemented("stop_generation")
end

--- Unsubscribe the session and stop its work. Updates the stop provokes are
--- not delivered.
--- @param _session_id string
function AgentClient:cancel_session(_session_id)
    not_implemented("cancel_session")
end

--- End a session: unsubscribe it and stop its work.
--- @param _session_id string
--- @param _on_closed fun() Runs once the provider has finished with the session
function AgentClient:close_session(_session_id, _on_closed)
    not_implemented("close_session")
end

--- Stop routing this session's updates, and drop the state kept for it.
--- @param _session_id string
function AgentClient:unsubscribe(_session_id)
    not_implemented("unsubscribe")
end

--- Ask the agent to authenticate with one of its `agent` methods. The
--- default fails with `METHOD_NOT_FOUND`.
--- @param _method_id string
--- @param callback fun(err: agentic.AgentClient.Error|nil)
function AgentClient:authenticate(_method_id, callback)
    not_supported(function(_, err)
        callback(err)
    end)
end

--- An interactive process that runs a terminal auth method.
--- @class agentic.acp.TerminalAuthInvocation
--- @field cmd string[] The provider command, its configured args, then the method's args
--- @field env table<string, string> Variables to add to nvim's environment: the provider env with the method's env on top

--- How to run a terminal auth method. The default has none.
--- @param _method agentic.acp.AuthMethod A `terminal` method
--- @return agentic.acp.TerminalAuthInvocation|nil
function AgentClient:terminal_auth_invocation(_method)
    return nil
end

--- Directories a skill loaded in this session may live under, in precedence
--- order (see `SkillPath.roots`). The default knows none.
--- @param _session_id string|nil
--- @return string[] roots
function AgentClient:session_roots(_session_id)
    return {}
end

--- @alias agentic.AgentClient.ClientConnectionState
--- | "disconnected"
--- | "connecting"
--- | "connected"
--- | "initializing"
--- | "ready"
--- | "error"

--- @alias agentic.AgentClient.ClientHandlers.on_session_update fun(update: agentic.acp.SessionUpdateMessage, source_session_id: string|nil): nil
--- @alias agentic.AgentClient.ClientHandlers.on_request_permission fun(request: agentic.acp.RequestPermission, callback: fun(option_id: string | nil)): nil

--- Handlers for a specific session. Each session subscribes with its own handlers.
--- @class agentic.AgentClient.ClientHandlers
--- @field on_session_update agentic.AgentClient.ClientHandlers.on_session_update
--- @field on_request_permission agentic.AgentClient.ClientHandlers.on_request_permission
--- @field on_tool_call fun(tool_call: agentic.ui.MessageWriter.ToolCallBlock, source_session_id: string|nil): nil
--- @field on_tool_call_update fun(tool_call: agentic.ui.MessageWriter.ToolCallBase, source_session_id: string|nil): nil
--- @field on_disconnect? fun(): nil The provider process died or failed
--- @field on_usage_lifted? fun(): nil The provider account's usage limit lifted
--- @field on_turn_state? fun(state: agentic.AgentClient.TurnState): nil The root session's foreground work changed state
--- @field on_prompt_taken? fun(): nil The agent took in the oldest prompt sent to the root session and not yet taken

--- Error codes: JSON-RPC's, and the client's own
AgentClient.ERROR_CODES = {
    -- ACP / JSON-RPC codes
    AUTH_REQUIRED = -32000,
    METHOD_NOT_FOUND = -32601,
    INVALID_PARAMS = -32602,
    INTERNAL_ERROR = -32603,
    REQUEST_CANCELLED = -32800,
    -- Client-side only, never sent: outside the JSON-RPC reserved range
    TRANSPORT_ERROR = -1,
    PROTOCOL_ERROR = -2,
}

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
function AgentClient:subagent_record(_session_id, _child_id)
    return nil
end

--- The provider's name for the session. Adapters for providers that name
--- sessions override this.
--- @param _session_id string
--- @return string|nil name Nil when the provider has none for the session
function AgentClient:name(_session_id)
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
function AgentClient:drain_side_records(_session_id, _child_id)
    return {}
end

--- The subagent that sent a received message.
--- @param sender_id string The sender's id, as the provider names it
--- @param child_ids string[] Child session ids of the session's subagents
--- @return string|nil child_id nil when none of them sent it
function AgentClient:sender_session(sender_id, child_ids)
    return vim.tbl_contains(child_ids, sender_id) and sender_id or nil
end

--- The task id an update is tagged with: the id of the tool call that gave
--- its subagent its current work, the one that spawned it or one that
--- resumed it. Adapters for providers that tag subagent updates override this.
--- @param _update agentic.acp.SessionUpdateMessage
--- @return string|nil task_id Nil for an update that is not a subagent's
function AgentClient:subagent_task_id(_update)
    return nil
end

--- The task id of the launch a session message replies to. Nil by default: a
--- launch's reply and a subagent's hand-back both go from child to parent,
--- and only a provider's message ids can tell them apart.
--- @param _update agentic.acp.SessionMessage
--- @return string|nil task_id Nil when it is not a launch's reply
function AgentClient:launch_reply_task(_update)
    return nil
end

--- Whether a replayed prompt is one the provider adds itself during a
--- session/load replay, not one the user sent.
--- @param _text string
--- @return boolean
function AgentClient:is_replay_only_prompt(_text)
    return false
end

--- The shell the provider's execute tool runs commands in, when the client
--- can prove it. Reaches only blocks built by the base `__build_tool_call_message`.
--- @return "bash"|"zsh"|nil
function AgentClient:exec_shell()
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
function AgentClient:budget_windows(_update)
    return nil
end

--- Whether to send "continue" once a usage limit resets.
--- @return boolean
function AgentClient:auto_continue_on_usage_limit()
    return false
end

--- The env entries that make the provider leave every tool call's permission
--- to the client, over any rule of the user's that allows it. Called on the
--- class, not an instance. The default has none to give.
--- @param _env table<string, string|nil> The env the process starts with
--- @return table<string, string>|nil env
--- @return string|nil err Why no env could be built
function AgentClient:unattended_env(_env)
    return nil, "no way to send every tool call for a permission decision"
end

--- Claude's config directory for the environment this client runs with:
--- the directory whose settings.json holds the permission rules.
--- @return string
function AgentClient:claude_config_dir()
    local env = self.provider_config.env
    return (env and env.CLAUDE_CONFIG_DIR)
        or vim.env.CLAUDE_CONFIG_DIR
        or vim.fs.normalize("~/.claude")
end

--- The plan file a permission request asks approval for.
--- @param _request agentic.acp.RequestPermission
--- @return string|nil path Absolute path; nil when the request names none
function AgentClient:plan_file(_request)
    return nil
end

--- The mode a subagent is expected to run in until the provider's record of
--- its spawn confirms one. Adapters for providers that can force a mode
--- override this.
--- @return "background"|"blocking"
function AgentClient:subagent_predicted_mode()
    return "blocking"
end

--- A prompt for the main agent to pass a message to a background subagent.
--- Adapters for providers whose main agent can message one override this.
--- @param _agent_id string Id addressing the subagent
--- @param _label string Display name of the subagent
--- @param _message string Text for the subagent to receive
--- @return string|nil instruction Nil when the main agent cannot message it
function AgentClient:subagent_message_instruction(_agent_id, _label, _message)
    return nil
end

--- How an auth method runs: in the agent through `authenticate`, or in the
--- client as an interactive process.
--- @param method agentic.acp.AuthMethod
--- @return "agent"|"terminal"|nil kind Nil for a type this client does not run
function AgentClient.auth_method_kind(method)
    local kind = method.type or "agent"
    if kind == "agent" or kind == "terminal" then
        return kind
    end
    return nil
end

return AgentClient
