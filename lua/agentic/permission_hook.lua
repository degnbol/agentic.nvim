local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")

--- PreToolUse hook entry point: runs the deterministic permission ladder
--- (`PermissionManager:decide`) inside the live nvim on behalf of a
--- claude-agent-acp PreToolUse hook, so the ladder gates the SDK's auto-mode
--- classifier. The hook script (`hooks/permission_hook.sh`) RPCs into here via
--- `nvim --server $AGENTIC_SOCK --remote-expr`. See
--- notes/PLAN-auto-mode-integration.md.
local M = {}

--- Claude SDK tool name -> ACP tool kind. Only the names the hook matcher
--- forwards (`Bash|Write|Edit`) need mapping; everything else is either
--- SDK-auto-allowed before the classifier or has no `decide` verdict.
--- `Write` maps to `edit` (not `create`/`write`) to match the live
--- claude-agent-acp path, whose adapter treats a whole-file `content` write as
--- an `edit`-kind diff — keeps hook and canUseTool verdicts identical.
local NAME_TO_KIND = {
    Bash = "execute",
    Edit = "edit",
    Write = "edit",
}

--- @param s string|nil
--- @return string[]
local function split(s)
    if type(s) ~= "string" then
        return {}
    end
    return vim.split(s, "\n")
end

--- Reconstruct the edit diff `decide`'s trust path needs from the hook's raw
--- tool_input (the SDK sends no ACP diff to a hook). Mirrors the claude
--- adapter's `edit`-kind branch: `Edit` carries old_string/new_string, `Write`
--- carries content with no old_string (pure-addition path).
--- @param tool_input table
--- @return { old: string[], new: string[], all: boolean }
local function build_edit_diff(tool_input)
    return {
        new = split(tool_input.content or tool_input.new_string),
        old = split(tool_input.old_string),
        all = tool_input.replace_all or false,
    }
end

--- Run the permission ladder for one PreToolUse call.
--- Fail-open: any decode error, unknown tool, missing session, or `decide`
--- error returns "" (empty) — the caller emits no permissionDecision and the
--- call falls through to the classifier. Never returns a spurious verdict.
--- @param b64 string base64-encoded JSON: `{session_id, tool_name, tool_input}`
--- @return string verdict "allow" | "deny" | "" (undecided / fall-through)
function M.evaluate(b64)
    local ok, verdict = pcall(function()
        local payload = vim.json.decode(vim.base64.decode(b64))
        local tool = payload.tool_name

        local kind = NAME_TO_KIND[tool]
        if not kind then
            Logger.debug_to_file("permission_hook:", tool, "→ unmatched tool")
            return ""
        end

        local pm =
            SessionRegistry.permission_manager_for_session(payload.session_id)
        if not pm then
            Logger.debug_to_file("permission_hook:", tool, "→ no session")
            return ""
        end

        local tool_input = payload.tool_input or {}
        --- @type agentic.acp.ToolCall
        local tool_call = {
            toolCallId = "hook",
            kind = kind,
            rawInput = tool_input --[[@as agentic.acp.RawInput]],
        }
        local diff = kind == "edit" and build_edit_diff(tool_input) or nil

        local decision = pm:decide(kind, tool_call, diff)
        Logger.debug_to_file(
            "permission_hook:",
            tool,
            "→",
            decision or "undecided (falls through to classifier)"
        )
        return decision or ""
    end)

    if not ok then
        Logger.debug_to_file("permission_hook: error:", tostring(verdict))
        return ""
    end
    return verdict
end

return M
