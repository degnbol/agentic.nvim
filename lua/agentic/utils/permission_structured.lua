local PermissionRules = require("agentic.utils.permission_rules")

--- Structured option matcher for compound-Bash auto-approval. Consumes a
--- ParsedLeaf produced by the walker (chunk 6) and decides allow / ask / deny /
--- nil against a list of StructuredEntry rules. The walker has already
--- quote-stripped tokens, joined literal concatenations, and excluded redirects
--- / env-prefixes / substitution; this module trusts that input shape.
---
--- See notes/perm-treesitter-plan.md § Matcher API spec for the authoritative
--- algorithm.
--- @class agentic.utils.PermissionStructured
local M = {}

--- @alias agentic.PermCategory "read_only" | "safe_write"
--- @alias agentic.PermAutoApprove "allow" | "read-only" | nil
--- @alias agentic.PermDecision "allow" | "ask" | "deny" | nil

--- @class agentic.PermGate
--- @field options?     string[] -- literal flag identifiers, no globs
--- @field positionals? string[] -- per element literal or glob

--- @class agentic.StructuredEntry
--- @field cmd       string      -- literal cmd name or exact "*"
--- @field allow?    agentic.PermGate
--- @field ask?      agentic.PermGate
--- @field deny?     agentic.PermGate
--- @field category? agentic.PermCategory  -- default "read_only"

--- @class agentic.ParsedLeaf
--- @field cmd_name string    after strip_command_path / wrapper strip
--- @field args     string[]  quote-stripped, env-prefix/redirect-excluded

--- @class agentic.ResolvedArgs
--- @field positionals   string[]    non-option tokens, in source order
--- @field option_tokens string[]    leading option tokens + consumed values

--- Per-command flags that consume the following token as their argument. The
--- option walker uses this to keep `-C path` together when locating the first
--- positional. Without an entry, every option token is treated as taking no
--- value, so the first non-`-`-prefixed token is the first positional.
--- @type table<string, table<string, true>>
local OPTION_VALUE_TAKERS = {
    git = {
        ["-C"] = true,
        ["-c"] = true,
        ["--git-dir"] = true,
        ["--work-tree"] = true,
        ["--namespace"] = true,
        ["--exec-path"] = true,
        ["--super-prefix"] = true,
    },
    gh = {
        ["-R"] = true,
        ["--repo"] = true,
        ["--hostname"] = true,
    },
    aws = {
        ["--region"] = true,
        ["--profile"] = true,
        ["--endpoint-url"] = true,
        ["--output"] = true,
        ["--cli-binary-format"] = true,
        ["--ca-bundle"] = true,
        ["--cli-read-timeout"] = true,
        ["--cli-connect-timeout"] = true,
    },
    flytectl = {
        ["--config"] = true,
        ["--admin-endpoint"] = true,
    },
}

--- Build the set of option-identifier candidates for a single token. The output
--- is over-approximate: extra candidates can only widen a deny/ask match, never
--- miss a real one. Returns `{}` for positionals and end-of-options sentinels.
--- @param token string
--- @return string[]
function M.extract_option_candidates(token)
    if token == "" then
        return {}
    end
    if token:sub(1, 1) ~= "-" then
        return {}
    end

    -- Long-only =value strip: only fires for `--`-prefixed tokens. Short
    -- tokens keep their full body, so `-=x` stays a short cluster. A
    -- `=` at position 3 (`--=value`) strips to just `--`, which the
    -- sentinel check then rejects.
    local head = token
    if token:sub(1, 2) == "--" then
        local eq = token:find("=", 1, true)
        if eq and eq >= 3 then
            head = token:sub(1, eq - 1)
        end
    end

    -- End-of-options / stdin sentinels.
    if head == "-" or head == "--" then
        return {}
    end

    if head:sub(1, 2) == "--" then
        local name = head:sub(3)
        if name == "" then
            return {}
        end
        return { name }
    end

    -- Short-flag branch: head starts with "-" but not "--".
    local body = head:sub(2)
    if body == "" then
        return {}
    end

    local seen = {}
    local out = {}
    for i = 1, #body do
        local ch = body:sub(i, i)
        if not seen[ch] then
            seen[ch] = true
            table.insert(out, ch)
        end
    end
    if not seen[body] then
        table.insert(out, body)
    end
    return out
end

--- Letter-vs-long-name aware prefix match. A candidate of length 1 must equal
--- the rule option exactly; a multi-char candidate matches when it is a
--- (possibly improper) prefix of the rule option. GNU long-option abbreviation
--- justifies the prefix direction (user types `--out` for `--output`).
--- @param candidate string
--- @param rule string
--- @return boolean
local function match_one(candidate, rule)
    if #candidate == 1 then
        return candidate == rule
    end
    return rule:sub(1, #candidate) == candidate
end

--- True iff any element of `candidates` matches any element of `rule_options`
--- under the asymmetric prefix rule. Returns false for either side empty.
--- @param candidates string[]
--- @param rule_options string[]
--- @return boolean
function M.match_options(candidates, rule_options)
    if #candidates == 0 or #rule_options == 0 then
        return false
    end
    for _, c in ipairs(candidates) do
        for _, r in ipairs(rule_options) do
            if match_one(c, r) then
                return true
            end
        end
    end
    return false
end

--- Split args into leading option tokens (with their consumed values for
--- commands listed in `OPTION_VALUE_TAKERS`) and the remaining positional
--- tokens. A bare `--` terminates the option block. The first positional is
--- whatever role the command treats it as (subcommand, file path, …) — gates
--- match it via `positionals[1]`, so the matcher has one uniform concept.
--- @param args string[]
--- @param cmd_name string
--- @return agentic.ResolvedArgs
function M.resolve_args(args, cmd_name)
    local globals = OPTION_VALUE_TAKERS[cmd_name] or {}
    local option_tokens = {}
    local i = 1

    while i <= #args do
        local tok = args[i]
        if tok == "--" then
            i = i + 1
            break
        elseif tok:sub(1, 1) == "-" then
            table.insert(option_tokens, tok)
            if globals[tok] then
                if args[i + 1] ~= nil then
                    table.insert(option_tokens, args[i + 1])
                    i = i + 2
                else
                    -- Malformed: arg-taking global with no value following.
                    i = i + 1
                end
            else
                i = i + 1
            end
        else
            break
        end
    end

    local positionals = {}
    for j = i, #args do
        table.insert(positionals, args[j])
    end

    return {
        positionals = positionals,
        option_tokens = option_tokens,
    }
end

--- Match a positional pattern list left-to-right against the positionals list.
--- Each pattern matches the token at the same 1-based index. Trailing tokens
--- beyond the pattern list are allowed.
--- @param patterns string[]
--- @param positionals string[]
--- @return boolean
local function positionals_match(patterns, positionals)
    if #patterns > #positionals then
        return false
    end
    for k, pat in ipairs(patterns) do
        local lua_pat = PermissionRules.glob_to_lua_pattern(pat)
        if not positionals[k]:match(lua_pat) then
            return false
        end
    end
    return true
end

--- Evaluate a single gate against the resolved args + option candidates.
--- Absent gate fields are wildcards.
--- @param gate agentic.PermGate
--- @param resolved agentic.ResolvedArgs
--- @param opt_cands string[]
--- @return boolean
local function gate_matches(gate, resolved, opt_cands)
    if gate.options ~= nil then
        if not M.match_options(opt_cands, gate.options) then
            return false
        end
    end
    if gate.positionals ~= nil then
        if not positionals_match(gate.positionals, resolved.positionals) then
            return false
        end
    end
    return true
end

--- Whether an allow-gate's category is permitted under the active
--- auto_approve mode. Deny/ask gates are unconditional and skip this check at
--- the call site.
--- @param entry agentic.StructuredEntry
--- @param auto_approve agentic.PermAutoApprove
--- @return boolean
local function allow_category_ok(entry, auto_approve)
    local cat = entry.category or "read_only"
    if auto_approve == "allow" then
        return true
    end
    if auto_approve == "read-only" then
        return cat == "read_only"
    end
    return false
end

--- Collect option candidates from every option token AND every positional
--- whose first byte is `-` (so `gh api -X POST` lets a rule listing `X` match
--- even though `-X` lives after the first positional).
--- @param resolved agentic.ResolvedArgs
--- @return string[]
local function collect_option_candidates(resolved)
    local cands = {}
    for _, tok in ipairs(resolved.option_tokens) do
        for _, c in ipairs(M.extract_option_candidates(tok)) do
            table.insert(cands, c)
        end
    end
    for _, tok in ipairs(resolved.positionals) do
        if tok:sub(1, 1) == "-" then
            for _, c in ipairs(M.extract_option_candidates(tok)) do
                table.insert(cands, c)
            end
        end
    end
    return cands
end

--- Resolve the structured decision for one parsed leaf against the merged
--- entry list. Precedence is deny > ask > allow across the *union* of all
--- entries whose `cmd` matches `parsed.cmd_name` (literal or `*`). Allow gates
--- are additionally filtered by category against `auto_approve`.
--- @param entries agentic.StructuredEntry[]
--- @param parsed agentic.ParsedLeaf
--- @param auto_approve agentic.PermAutoApprove
--- @return agentic.PermDecision
function M.decide_leaf(entries, parsed, auto_approve)
    local resolved = M.resolve_args(parsed.args, parsed.cmd_name)
    local opt_cands = collect_option_candidates(resolved)

    --- @type agentic.StructuredEntry[]
    local relevant = {}
    for _, e in ipairs(entries) do
        if e.cmd == parsed.cmd_name or e.cmd == "*" then
            table.insert(relevant, e)
        end
    end

    for _, e in ipairs(relevant) do
        if e.deny ~= nil and gate_matches(e.deny, resolved, opt_cands) then
            return "deny"
        end
    end
    for _, e in ipairs(relevant) do
        if e.ask ~= nil and gate_matches(e.ask, resolved, opt_cands) then
            return "ask"
        end
    end
    for _, e in ipairs(relevant) do
        if
            e.allow ~= nil
            and allow_category_ok(e, auto_approve)
            and gate_matches(e.allow, resolved, opt_cands)
        then
            return "allow"
        end
    end

    return nil
end

return M
