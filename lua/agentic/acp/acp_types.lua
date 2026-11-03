-- LuaCATS types of ACP messages; annotation only, never required.

--[[
CRITICAL: Type annotations in this file are essential for Lua Language Server support.
DO NOT REMOVE them. Only update them if the underlying types change.
--]]

--- @class agentic.acp.ClientInfo
--- @field name string
--- @field version string

--- @class agentic.acp.ClientCapabilities
--- @field fs agentic.acp.FileSystemCapability
--- @field terminal boolean
--- @field auth { terminal: boolean } `terminal`: the client runs `terminal` auth methods
--- @field _meta? table
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
--- @field sessionCapabilities? { close?: table }

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

--- @class agentic.acp.ToolCallMessage
--- @field sessionUpdate "tool_call"
--- @field toolCallId string
--- @field title string most likely the command to be executed
--- @field kind agentic.acp.ToolKind
--- @field status agentic.acp.ToolCallStatus
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field locations? agentic.acp.ToolCallLocation[]
--- @field rawInput? agentic.acp.RawInput
--- @field public _meta? table

--- @class agentic.acp.ToolCallUpdate
--- @field sessionUpdate "tool_call_update"
--- @field toolCallId string
--- @field kind? agentic.acp.ToolKind
--- @field status? agentic.acp.ToolCallStatus
--- @field content? agentic.acp.ACPToolCallContent[]
--- @field locations? agentic.acp.ToolCallLocation[]
--- @field rawOutput? string|table Plain string or array of content blocks (`{type="text",text=...}`). claude-agent-acp forwards `ToolResultBlockParam.content` here. Non-standard across providers.
--- @field public _meta? table

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

--- @class agentic.acp.ACPError
--- @field code number
--- @field message string
--- @field data? any
