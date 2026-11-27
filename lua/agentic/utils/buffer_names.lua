--- Names of session buffers: `agentic://<key>[/<kind>/<sub_id>][/<part>]`.
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

--- What session a transcript below a chat belongs to.
--- @alias agentic.BufferNames.Kind "subagent"|"skeptic"

--- @type agentic.BufferNames.Kind[]
local KINDS = { "subagent", "skeptic" }

--- @class agentic.BufferNames.Parts
--- @field key string The chat id (`ChatHistory.chat_id`)
--- @field kind? agentic.BufferNames.Kind Required with `sub_id`
--- @field sub_id? string The `short_key` of a `kind` session's id
--- @field part? string A `PANELS` value, only `input` with a `subagent` `sub_id`

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
        name = name .. "/" .. parts.kind .. "/" .. parts.sub_id
    end
    if parts.part then
        name = name .. "/" .. parts.part
    end
    return name
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
    local key, second, third, fourth = unpack(segments)
    if #segments == 1 then
        return { key = key }
    elseif #segments == 2 and vim.list_contains(BufferNames.PANELS, second) then
        return { key = key, part = second }
    elseif #segments == 3 and vim.list_contains(KINDS, second) then
        local kind = second --[[@as agentic.BufferNames.Kind]]
        return { key = key, kind = kind, sub_id = third }
    elseif #segments == 4 and second == "subagent" and fourth == "input" then
        return { key = key, kind = second, sub_id = third, part = fourth }
    end
    return nil
end

return BufferNames
