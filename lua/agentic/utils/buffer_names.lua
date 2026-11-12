--- Names of session buffers: `agentic://<key>[/<sub_id>][/<part>]`.
--- @class agentic.BufferNames
local BufferNames = {}

local SCHEME = "agentic://"

--- The panels below a chat, each a `part` of a name.
--- @type agentic.ui.ChatWidget.StackPanel[]
BufferNames.PANELS = {
    "agents",
    "todos",
    "code",
    "files",
    "diagnostics",
    "activity",
    "info",
    "input",
}

--- @class agentic.BufferNames.Parts
--- @field key string The chat id (`ChatHistory.chat_id`), or for `background` the session's short key
--- @field sub_id? string The short key of a subagent's session id
--- @field part? string A `PANELS` value; `input` after a `sub_id`; or `background`

--- A short key that stands for `id`: the first 8 hex digits of its SHA-256.
--- @param id string
--- @return string key
function BufferNames.short_key(id)
    return vim.fn.sha256(id):sub(1, 8)
end

--- The name of the buffer `parts` stand for.
--- @param parts agentic.BufferNames.Parts No `part` for a chat or a transcript
--- @return string name
function BufferNames.format(parts)
    local name = SCHEME .. parts.key
    if parts.sub_id then
        name = name .. "/" .. parts.sub_id
    end
    if parts.part then
        name = name .. "/" .. parts.part
    end
    return name
end

--- Whether a second segment is a part rather than a subagent's key. No
--- short key (8 hex digits) is a part.
--- @param segment string
--- @return boolean
local function is_part(segment)
    return segment == "background"
        or vim.list_contains(BufferNames.PANELS, segment)
end

--- Parts of a name `format` makes.
--- @param name string
--- @return agentic.BufferNames.Parts|nil parts Nil for any other name
function BufferNames.parse(name)
    if not vim.startswith(name, SCHEME) then
        return nil
    end
    local segments = vim.split(name:sub(#SCHEME + 1), "/", { plain = true })
    if vim.list_contains(segments, "") then
        return nil
    end
    local key, second, third = unpack(segments)
    if #segments == 1 then
        return { key = key }
    elseif #segments == 2 then
        if is_part(second) then
            return { key = key, part = second }
        end
        return { key = key, sub_id = second }
    elseif #segments == 3 and third == "input" and not is_part(second) then
        return { key = key, sub_id = second, part = third }
    end
    return nil
end

return BufferNames
