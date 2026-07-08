--- Detects the input shape that hangs the tree-sitter-zsh C parser forever.
---
--- An unescaped close-paren inside a bracket class within a `${var/pat}` or
--- `${var//pat}` substitution (`c=${x//[^)]}`) sends the GLR reduce loop into a
--- non-terminating spin (`ts_parser__reduce` → `stack_node_release`). The loop
--- is at the C level, so neither `pcall`, `timeout`'s SIGTERM, nor neovim's
--- async-parse chunk timeout can interrupt it — the editor freezes and is
--- eventually SIGKILLed. See `notes/bug-zsh-parser-hang.md`; the canonical regex
--- also lives in the `bash-pitfall-guard.sh` Claude hook (`paren_bracket_class`).
--- Bug is in `georgeharker/tree-sitter-zsh` (no fixed upstream release as of
--- 2026-07-08).
---
--- This is a cheap pre-parse tripwire: callers that feed untrusted content to
--- the zsh grammar (the permission walk, diff/tool-call syntax highlighting)
--- check here first and skip the parse — the walk fails closed (prompt), a
--- highlighter fails open (no highlight).
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

return M
