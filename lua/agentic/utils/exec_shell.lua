local Config = require("agentic.config")

--- Single source of truth for which shell the provider's execute tool runs
--- commands in. Replicates the SDK's `findSuitableShell()` *precedence only*
--- (`src/utils/Shell.ts`, documented in the `claude` skill's
--- `references/execute-tool.md` § Shell): the shell is `$CLAUDE_CODE_SHELL`,
--- else `$SHELL`, else a path search preferring zsh then bash. We resolve the
--- first two env-var branches and return `nil` for the residual path-search
--- branch — that case is unprovable client-side, so callers decide their own
--- `nil` policy (cosmetic fallback vs fail-closed at the security gate).
--- @class agentic.utils.ExecShell
local M = {}

local KNOWN_SHELLS = { bash = true, zsh = true }

--- The value the SDK child actually receives for `key`, mirroring the
--- transport's env composition (`acp_transport.lua`: parent `vim.fn.environ()`
--- overlaid by the provider's `config.env`). Detection must equal what the
--- child gets — a provider `env = { SHELL = "/bin/bash" }` override makes the
--- child run bash even while `vim.env.SHELL` is still zsh, so reading raw
--- `vim.env` alone would mis-detect the shell and fail OPEN at the gate.
--- @param key string
--- @return string|nil
local function child_env(key)
    local provider = Config.acp_providers[Config.provider]
    local override = provider and provider.env and provider.env[key]
    if override ~= nil then
        return override
    end
    return vim.env[key]
end

--- The basename of `path` if it names a known shell (bash/zsh) AND `path` is
--- executable, mirroring the SDK's two conditions on each env-var branch.
--- @param path string|nil
--- @return "bash"|"zsh"|nil
local function known_executable_shell(path)
    if not path or path == "" then
        return nil
    end
    local base = vim.fs.basename(path)
    if not KNOWN_SHELLS[base] or vim.fn.executable(path) == 0 then
        return nil
    end
    return base
end

--- Resolve the exec shell from the effective child env, per SDK precedence.
--- @return "bash"|"zsh"|nil "nil" = path-search branch (unprovable client-side)
function M.resolve()
    return known_executable_shell(child_env("CLAUDE_CODE_SHELL"))
        or known_executable_shell(child_env("SHELL"))
end

return M
