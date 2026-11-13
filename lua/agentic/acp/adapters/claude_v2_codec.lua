local Json = require("agentic.utils.json")
local UnifiedDiff = require("agentic.utils.unified_diff")

--- Translation between claude-agent-acp's draft ACP v2 surface (`dist/v2/`)
--- and the v1 shapes, with the claude extensions, that the bridge sends a v1
--- client like this plugin.
--- @class agentic.acp.ClaudeV2Codec
local M = {}

--- @class agentic.acp.ClaudeV2Codec.Call
--- @field meta table The call's merged `_meta`, without the terminal keys
--- @field name? string The tool name the first report gave
--- @field started boolean A `tool_call` went out for it since the last resume

--- What decoding one session's messages remembers.
--- @class agentic.acp.ClaudeV2Codec.State
--- @field calls table<string, agentic.acp.ClaudeV2Codec.Call> Per tool call id
--- @field held_start? table A replayed start whose `_meta` is `null`, held for the patch that follows it

--- A session's state before any message.
--- @return agentic.acp.ClaudeV2Codec.State
function M.state()
    --- @type agentic.acp.ClaudeV2Codec.State
    local state = { calls = {} }
    return state
end

--- The call `id` of `state`, created on first use.
--- @param state agentic.acp.ClaudeV2Codec.State
--- @param id string
--- @return agentic.acp.ClaudeV2Codec.Call
local function call_of(state, id)
    local call = state.calls[id]
    if not call then
        call = { meta = {}, started = false }
        state.calls[id] = call
    end
    return call
end

--- Merge a v2 report's `name` and `_meta` into its call. `_meta` patches the
--- stored one by top-level key: a `null` key deletes it, a `null` `_meta`
--- deletes all.
--- @param call agentic.acp.ClaudeV2Codec.Call
--- @param report table
local function apply_report(call, report)
    call.name = report.name or call.name
    if report._meta == vim.NIL then
        call.meta = {}
        return
    end
    for key, value in pairs(report._meta or {}) do
        call.meta[key] = Json.present(value)
    end
end

--- The `_meta` a v1 report of the call carries: the stored keys, and the
--- tool name in `claudeCode`, where v1 has it.
--- @param call agentic.acp.ClaudeV2Codec.Call
--- @return table|nil meta Nil when it would be empty
local function v1_meta(call)
    local meta = vim.tbl_extend("force", {}, call.meta)
    if call.name then
        meta.claudeCode = vim.tbl_extend(
            "force",
            {},
            meta.claudeCode or {},
            { toolName = call.name }
        )
    end
    return next(meta) and meta or nil
end

--- The v1 diff items of a v2 diff: one per hunk of its patch, none without
--- a patch.
--- @param diff table
--- @return table[] items
local function v1_diffs(diff)
    local change = diff.changes[1]
    local patch = Json.present(diff.patch)
    if not (change and patch) then
        return {}
    end
    local items = {}
    for _, hunk in ipairs(UnifiedDiff.hunks(patch.text)) do
        table.insert(items, {
            type = "diff",
            path = change.path,
            oldText = change.operation == "add" and vim.NIL
                or table.concat(hunk.old_lines, "\n"),
            newText = table.concat(hunk.new_lines, "\n"),
        })
    end
    return items
end

--- The v1 items of v2 tool call content. A v2 diff becomes its v1 diffs, other
--- items stay as they are.
--- @param content table[]
--- @return table[]
local function v1_content(content)
    local items = {}
    for _, item in ipairs(content) do
        if item.type == "diff" and item.changes then
            vim.list_extend(items, v1_diffs(item))
        else
            table.insert(items, item)
        end
    end
    return items
end

--- The v1 fields of the v2 fields of a tool call.
--- @param call agentic.acp.ClaudeV2Codec.Call The call, with `fields` applied
--- @param fields table
--- @return table
local function v1_tool_call(call, fields)
    local v1 = vim.tbl_extend("force", {}, fields)
    v1.name = nil
    v1._meta = v1_meta(call)
    if fields.content then
        v1.content = v1_content(fields.content)
    end
    return v1
end

--- The v1 report of a v2 report of `call`: a `tool_call` while the call is
--- not started, which starts it, else a `tool_call_update`.
--- @param call agentic.acp.ClaudeV2Codec.Call
--- @param report table
--- @return table
local function start_or_update(call, report)
    local v1 = v1_tool_call(call, report)
    v1.sessionUpdate = call.started and "tool_call_update" or "tool_call"
    call.started = true
    return v1
end

--- The `tool_call` of the held start, if any, which it stops holding.
--- @param state agentic.acp.ClaudeV2Codec.State
--- @return table[] updates
local function flush_held(state)
    local held = state.held_start
    if not held then
        return {}
    end
    state.held_start = nil
    return { start_or_update(call_of(state, held.toolCallId), held) }
end

--- Whether a report carries nothing but `_meta`.
--- @param report table
--- @return boolean
local function is_meta_only(report)
    for key in pairs(report) do
        if
            key ~= "sessionUpdate"
            and key ~= "toolCallId"
            and key ~= "_meta"
        then
            return false
        end
    end
    return true
end

--- The v1 updates of a v2 `tool_call_update`: a `tool_call` for the first
--- report of a call that is not started, else a `tool_call_update`. A start
--- with a `null` `_meta` is held in `state` until its patch or the next update.
--- @param state agentic.acp.ClaudeV2Codec.State
--- @param report table A v2 `tool_call_update`
--- @return table[] updates
local function decode_tool_call_update(state, report)
    local held = state.held_start
    if
        held
        and held.toolCallId == report.toolCallId
        and is_meta_only(report)
    then
        -- The bridge replays a start the client may hold from before as the
        -- start with `_meta = null`, then the current `_meta`
        -- (`V2ToolCallMeta.apply` with `replaying`).
        apply_report(call_of(state, report.toolCallId), report)
        return flush_held(state)
    end
    local updates = flush_held(state)
    local call = call_of(state, report.toolCallId)
    apply_report(call, report)
    if report._meta == vim.NIL and not call.started then
        state.held_start = report
        return updates
    end
    table.insert(updates, start_or_update(call, report))
    return updates
end

--- The status-less v1 `tool_call_update` of a v2 `terminal_update`, whose
--- terminal id is the tool call id, or nil when it carries no output or exit.
--- Neither key is stored: a stored `terminal_exit` would end every later
--- report of the call.
--- @param state agentic.acp.ClaudeV2Codec.State
--- @param update table
--- @return table|nil
local function decode_terminal(state, update)
    local id = update.terminalId
    local meta = {}
    local output = Json.present(update.output)
    if output then
        meta.terminal_output =
            { terminal_id = id, data = vim.base64.decode(output.data) }
    end
    local exit = Json.present(update.exitStatus)
    if exit then
        meta.terminal_exit = {
            terminal_id = id,
            exit_code = Json.present(exit.exitCode),
            signal = Json.present(exit.signal),
        }
    end
    if not next(meta) then
        return nil
    end
    local call = state.calls[id]
    if call and call.name then
        -- Not the stored `claudeCode`: a status-less update with its
        -- `toolResponse` would read as the PostToolUse hook's.
        meta.claudeCode = { toolName = call.name }
    end
    return { sessionUpdate = "tool_call_update", toolCallId = id, _meta = meta }
end

--- v1 config options of v2 ones: `configId` is `id`, a group's `groupId` is
--- `group`, and a boolean option is the `on`/`off` select the bridge gives a
--- v1 client (`createFastModeConfigOption`), whose values it also takes on
--- v2.
--- @param options table[]
--- @return agentic.acp.ConfigOption[]
local function v1_config_options(options)
    return vim.tbl_map(function(option)
        local v1 = vim.tbl_extend("force", {}, option)
        v1.id, v1.configId = option.configId, nil
        if option.type == "boolean" then
            v1.type = "select"
            v1.currentValue = option.currentValue and "on" or "off"
            v1.options = {
                { value = "on", name = "On" },
                { value = "off", name = "Off" },
            }
        elseif option.options then
            v1.options = vim.tbl_map(function(entry)
                if entry.groupId == nil then
                    return entry
                end
                local group = vim.tbl_extend("force", {}, entry)
                group.group, group.groupId = entry.groupId, nil
                return group
            end, option.options)
        end
        return v1
    end, options)
end

--- Message updates whose empty form clears a replayed message.
local MESSAGES =
    { user_message = true, agent_message = true, agent_thought = true }

--- The v1 update of a v2 update other than `tool_call_update`, or nil when it
--- stands for none.
--- @param state agentic.acp.ClaudeV2Codec.State
--- @param update table
--- @return table|nil
local function decode_other(state, update)
    local kind = update.sessionUpdate
    if kind == "terminal_update" then
        return decode_terminal(state, update)
    elseif kind == "terminal_output_chunk" then
        return nil
    elseif kind == "plan_update" then
        -- A markdown or file plan is an approved ExitPlanMode plan
        -- (`planModeUpdate`), which its tool call block already shows.
        if update.plan.type ~= "items" then
            return nil
        end
        return {
            sessionUpdate = "plan",
            entries = update.plan.entries,
            _meta = update._meta,
        }
    elseif kind == "plan_removed" then
        return { sessionUpdate = "plan", entries = {}, _meta = update._meta }
    elseif kind == "config_option_update" then
        local v1 = vim.tbl_extend("force", {}, update)
        v1.configOptions = v1_config_options(update.configOptions)
        return v1
    elseif MESSAGES[kind] and #(Json.present(update.content) or {}) == 0 then
        return nil
    end
    return update
end

--- The v1-shaped updates one v2 `session/update` stands for.
--- @param state agentic.acp.ClaudeV2Codec.State
--- @param update table The v2 `update` object
--- @return table[] updates v1-shaped; empty when it stands for none
function M.decode_update(state, update)
    if update.sessionUpdate == "tool_call_update" then
        return decode_tool_call_update(state, update)
    end
    -- The `state_update` that ends every resume flushes the last held start.
    local updates = flush_held(state)
    local decoded = decode_other(state, update)
    if decoded then
        table.insert(updates, decoded)
    end
    return updates
end

--- The v1-shaped `session/request_permission` params of v2 ones. The
--- subject's `_meta` is the call's whole `_meta` (`V2ToolCallMeta.subject`),
--- merged into `state` like a report's.
--- @param state agentic.acp.ClaudeV2Codec.State
--- @param params table
--- @return agentic.acp.RequestPermission
function M.decode_permission(state, params)
    local tool_call = params.subject.toolCall
    local call = call_of(state, tool_call.toolCallId)
    apply_report(call, tool_call)
    local v1 = v1_tool_call(call, tool_call)
    v1.title = tool_call.title or params.title
    --- @type agentic.acp.RequestPermission
    local request = {
        sessionId = params.sessionId,
        toolCall = v1 --[[@as agentic.acp.ToolCall]],
        options = params.options,
        _meta = params._meta,
    }
    return request
end

--- @param method table A v2 auth method
--- @return agentic.acp.AuthMethod
local function v1_auth_method(method)
    local v1 = vim.tbl_extend("force", {}, method)
    v1.id, v1.methodId = method.methodId, nil
    if method.env then
        v1.env = {}
        for _, var in ipairs(method.env) do
            v1.env[var.name] = var.value
        end
    end
    return v1 --[[@as agentic.acp.AuthMethod]]
end

--- @param result table A v2 `initialize` result
--- @return agentic.acp.InitializeResponse
local function v1_initialize_result(result)
    local capabilities = Json.present(result.capabilities) or {}
    local session = Json.present(capabilities.session) or {}
    local prompt = Json.present(session.prompt) or {}
    --- @type agentic.acp.InitializeResponse
    local v1 = {
        protocolVersion = result.protocolVersion,
        agentInfo = result.info,
        agentCapabilities = {
            -- v2 resumes with a replay in the session baseline.
            loadSession = true,
            promptCapabilities = {
                image = Json.present(prompt.image) ~= nil,
                audio = Json.present(prompt.audio) ~= nil,
                embeddedContext = Json.present(prompt.embeddedContext) ~= nil,
            },
            -- `session/close` is in the session baseline too.
            sessionCapabilities = {
                close = vim.empty_dict(),
                fork = Json.present(session.fork),
            },
            _meta = capabilities._meta,
        },
        authMethods = vim.tbl_map(v1_auth_method, result.authMethods or {}),
        _meta = result._meta,
    }
    return v1
end

--- The v1 shape of the result of a v2 request: of `initialize`, and of any
--- result with `configOptions`. Other results keep their shape. A session
--- result keeps its `availableCommands`: v2 sends no initial
--- `available_commands_update`.
--- @param method string The v2 method the result answers
--- @param result table
--- @return table
function M.decode_result(method, result)
    if method == "initialize" then
        return v1_initialize_result(result)
    end
    if not result.configOptions then
        return result
    end
    local v1 = vim.tbl_extend("force", {}, result)
    v1.configOptions = v1_config_options(result.configOptions)
    return v1
end

--- @param params agentic.acp.InitializeParams
--- @return table
local function v2_initialize(params)
    local capabilities = params.clientCapabilities
    return {
        protocolVersion = params.protocolVersion,
        info = params.clientInfo,
        -- v2 has no client file system or terminals, and subagents are in
        -- its baseline.
        capabilities = {
            auth = { terminal = vim.empty_dict() },
            _meta = capabilities._meta,
        },
    }
end

--- The v2 method and params of a v1 request. `session/load` becomes
--- `session/resume` with a replay from the start, and marks every call in
--- `state` not started. `session/set_mode` and `session/set_model` pass
--- through unchanged: they have no v2 form, and a v2 session result has no
--- `modes` or `models` to set.
--- @param state agentic.acp.ClaudeV2Codec.State The session's, unused for a request that names none
--- @param method string v1 method name
--- @param params table
--- @return string method
--- @return table params
function M.encode_request(state, method, params)
    if method == "initialize" then
        return method,
            v2_initialize(params --[[@as agentic.acp.InitializeParams]])
    elseif method == "authenticate" then
        return "auth/login", params
    elseif method == "session/load" then
        -- The bridge replays each start as a patch against the `_meta` it
        -- sent before, so the calls keep theirs.
        for _, call in pairs(state.calls) do
            call.started = false
        end
        local v2 = vim.tbl_extend("force", {}, params)
        v2.replayFrom = { type = "start" }
        return "session/resume", v2
    elseif method == "session/set_config_option" then
        return method, vim.tbl_extend("force", { type = "id" }, params)
    end
    return method, params
end

return M
