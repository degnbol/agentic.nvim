--- Finds where one model response ends and the next begins in a stream of
--- message chunks, from the change of their `messageId`. No end-of-message
--- event exists, so the verdict lands on the first chunk of the next response.
--- @class agentic.acp.ResponseBoundary
--- @field _last_id? string Last non-nil messageId seen
--- @field _stripping boolean Dropping the leading newlines of a response that owes a break
local ResponseBoundary = {}
ResponseBoundary.__index = ResponseBoundary

--- @return agentic.acp.ResponseBoundary
function ResponseBoundary:new()
    return setmetatable({ _stripping = false }, self)
end

--- Classify one chunk. A chunk with no id never marks an id change, and is
--- compared past: the next id is checked against the last one seen.
---
--- The leading newlines of a new response are dropped, so the break written
--- at `starts_response` is its only separation. They can arrive split over
--- several chunks, so the start of the response is the first chunk left with
--- text, whatever its id; that chunk carries the verdict.
--- @param message_id string|nil
--- @param text string
--- @return string text `text` without leading newlines while a break is pending
--- @return boolean starts_response The chunk is the first text of a new response
function ResponseBoundary:filter(message_id, text)
    if message_id and self._last_id and message_id ~= self._last_id then
        self._stripping = true
    end
    if message_id then
        self._last_id = message_id
    end

    if not self._stripping then
        return text, false
    end
    text = text:gsub("^\n+", "")
    if text == "" then
        return text, false
    end
    self._stripping = false
    return text, true
end

return ResponseBoundary
