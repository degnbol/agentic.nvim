--- Detects and defuses the input shape that hangs the tree-sitter-zsh C parser forever.
---
--- An unescaped close-paren inside a bracket class within a `${var/pat}` or
--- `${var//pat}` substitution (`c=${x//[^)]}`) sends the GLR reduce loop into a
--- non-terminating spin (`ts_parser__reduce` → `stack_node_release`). The loop
--- is at the C level, so neither `pcall`, `timeout`'s SIGTERM, nor neovim's
--- async-parse chunk timeout can interrupt it — the editor freezes and is
--- eventually SIGKILLed. The canonical regex also lives in the
--- `bash-pitfall-guard.sh` Claude hook (`paren_bracket_class`).
--- Bug is in `georgeharker/tree-sitter-zsh` (no fixed upstream release as of
--- 2026-07-08).
---
--- Check or defuse untrusted text before it reaches the zsh grammar, including
--- through an injection from another language.
---
--- @class agentic.utils.ZshParseGuard
local M = {}

--- Lua translation of the canonical regex `\$\{[^}]*/[^}]*\[[^]}\]*\)`. Each
--- `[^}]*` cannot cross a `}`, so the `/`, `[`, and `)` must all fall inside a
--- single `${…}`; the class `[^%]}\]` stops at an escaping `\`, so `\)` (escaped
--- close-paren) does not match. Verified against the danger boundary in the
--- module test: blocks `[)]`/`[^)]`/`[a)b]` (single- and double-slash), allows
--- escaped `\)`, open-paren `[^(]`, and paren-in-class outside a substitution.
local HANG_TRIGGER = "%${[^}]*/[^}]*%[[^%]}\\]*%)"

--- Whether `src` contains the catastrophic zsh substitution shape above.
--- @param src string
--- @return boolean
function M.contains_hang_trigger(src)
    return string.find(src, HANG_TRIGGER) ~= nil
end

--- `src` with the `$` of every hang-trigger `${` replaced by `_`. No other
--- byte changes, so byte offsets are kept. The result contains no trigger,
--- because a removed opener cannot form a new match.
--- @param src string
--- @return string defused
function M.defuse_hang_triggers(src)
    local defused = src
    local init = 1
    while true do
        local s = string.find(defused, HANG_TRIGGER, init)
        if not s then
            return defused
        end
        defused = defused:sub(1, s - 1) .. "_" .. defused:sub(s + 1)
        -- Resume past the opener only: a nested `${` inside this match
        -- can be a trigger of its own.
        init = s + 1
    end
end

return M
