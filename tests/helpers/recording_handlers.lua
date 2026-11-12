local M = {}

--- ACP client handlers that record each call in order.
--- @return agentic.acp.ClientHandlers handlers
--- @return table[] calls `{ method, payload, source }` per call
function M.new()
    local calls = {}
    local function record(method)
        return function(payload, source)
            table.insert(calls, { method, payload, source })
        end
    end
    return {
        on_session_update = record("on_session_update"),
        on_tool_call = record("on_tool_call"),
        on_tool_call_update = record("on_tool_call_update"),
        on_request_permission = record("on_request_permission"),
    },
        calls
end

return M
