--- Last-seen kind of each open tool call, per session. Fills `kind` on a
--- `tool_call_update` that leaves it out, since a provider may send only the
--- fields that changed.
--- @class agentic.acp.ToolCallKinds
--- @field _kinds table<string, table<string, agentic.acp.ToolKind>> session id -> tool call id -> kind
local ToolCallKinds = {}
ToolCallKinds.__index = ToolCallKinds

--- @return agentic.acp.ToolCallKinds
function ToolCallKinds:new()
    return setmetatable({ _kinds = {} }, self)
end

--- Record the kind a notification carries, and set the recorded kind on a
--- `tool_call_update` that has none (mutates `update`). Forget the call once
--- the update reports `completed` or `failed`.
--- @param session_id string
--- @param update agentic.acp.ToolCallMessage|agentic.acp.ToolCallUpdate
function ToolCallKinds:apply(session_id, update)
    local session = self._kinds[session_id]
    if not session then
        session = {}
        self._kinds[session_id] = session
    end

    local id = update.toolCallId
    if update.kind then
        session[id] = update.kind
    else
        update.kind = session[id]
    end

    if update.status == "completed" or update.status == "failed" then
        session[id] = nil
    end
end

--- @param session_id string
function ToolCallKinds:forget_session(session_id)
    self._kinds[session_id] = nil
end

return ToolCallKinds
