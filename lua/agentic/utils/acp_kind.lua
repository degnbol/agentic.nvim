--- Canonical form of an ACP tool-kind value.
local M = {}

--- Normalise an ACP-sourced kind value: strip whitespace, lowercase.
---
--- Use at every ACP kind comparison or table lookup. The protocol's own kind
--- vocabulary is lowercase, but this plugin's adapters mint CamelCase kinds
--- alongside it (`SubAgent`, `WebSearch`, `SlashCommand`, `TodoWrite`,
--- `Skill`), so a raw `kind` is only comparable once it has been through here.
--- `nil` normalises to the empty string, which matches no kind, so callers need
--- no nil check of their own.
--- @param kind string|nil
--- @return string
function M.normalise(kind)
    if not kind then
        return ""
    end
    return vim.trim(kind):lower()
end

return M
