local PermissionRules = require("agentic.utils.permission_rules")

--- Structured option matcher for compound-Bash auto-approval. Consumes a
--- ParsedLeaf produced by the walker (an ordered word list, each word tagged
--- only with whether it expands at runtime) and decides allow / ask / deny /
--- nil against a cmd-keyed table of StructuredCmdEntry rules. The walker has
--- already quote-stripped tokens, joined literal concatenations, and excluded
--- redirects / env-prefixes / substitution; this module trusts that input shape.
---
--- The matcher carries no getopt arity table for soundness. Each leading
--- dash-word can absorb 0 or 1 following plain word, and the two directions
--- read that ambiguity differently:
---   * deny/ask are EXISTENTIAL — a gate fires if *any* absorption parse (plus
---     dynamic-token wildcarding) exposes the gated subcommand/option. Owns
---     soundness; an over-match only over-prompts.
---   * allow is a SINGLE list-resolved parse — a leading flag absorbs its next
---     word iff it is a known `value_taking_options` value-taker. Convenience only:
---     the existential pass has already cleared every parse before allow runs.
---
--- See the `permissions` project skill § "Compound Bash commands" for the
--- cross-file overview; this module's functions are the authoritative algorithm.
--- @class agentic.utils.PermissionStructured
local M = {}

--- @alias agentic.PermAutoApprove "allow" | "read-only" | nil
--- @alias agentic.PermDecision "allow" | "ask" | "deny" | nil
--- @alias agentic.PermKind "read_only" | "safe_write" | "ask" | "deny"

--- @class agentic.PermGate
--- @field options?     string[] -- flag identifiers (dashless), matched
---        order-free over every flag anywhere in the command.
--- @field positionals? string[] -- per element literal or glob, matched
---        contiguously from the subcommand (stream index 1).
--- @field leading_options? string[] -- like `options`, but matched only against
---        the leading option region (before the first positional) and
---        wildcard-reachable only by a dynamic token that can occupy that region
---        (a dynamic leading flag / absorbed value, or a dynamic first
---        positional that could word-split into a leading flag). For a leading
---        global whose danger is position-specific — git's `-c x.y=z` (a code
---        channel) is dangerous before the subcommand but inert after it, and a
---        trailing token like the `$ref` in `git log $ref` can never inject it.

--- One value of the cmd-keyed schema. The kind name encodes the policy:
--- `read_only` approves at "read-only"|"allow", `safe_write` only at "allow",
--- `ask` always prompts, `deny` always vetoes. Each is an array of gates.
--- @class agentic.StructuredCmdEntry
--- @field read_only?  agentic.PermGate[]
--- @field safe_write? agentic.PermGate[]
--- @field ask?        agentic.PermGate[]
--- @field deny?       agentic.PermGate[]

--- Cmd-keyed table (`"*"` is the literal wildcard key). A `vim.NIL` value is
--- treated as "no entry" so a user can disable a bundled cmd via
--- `Config.permissions.structured` (the `vim.NIL` sentinel is untyped here;
--- `decide_leaf` and the loader both filter it).
--- @alias agentic.StructuredEntries table<string, agentic.StructuredCmdEntry>

--- @class agentic.ParsedLeaf
--- @field cmd_name string    after strip_command_path / wrapper strip
--- @field args     string[]  ordered word list, quote-stripped,
---        env-prefix/redirect-excluded. `--` is the literal end-of-options
---        sentinel; `-` is a positional (stdin/stdout). No role tagging.
--- @field args_dynamic? boolean[] parallel to `args`: token expands at runtime
---        (variable/glob/quoted-expansion) so its value is unknown. Absent =
---        all-static (back-compat for direct callers).

--- Leading flags that consume the following word as their argument. Used by the
--- ALLOW single-parse only (deny/ask branch arity existentially, so they need
--- no table — see the module doc). A fail-safe optimisation: an unlisted leading
--- flag absorbs nothing, which only constrains allow (over-prompts), never an
--- unsound approval. Keyed by the full flag token (`-C`, `--region`).
--- @type table<string, table<string, true>>
local value_taking_options = {
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

-- ponytail: fixed cap, raise it if a legitimate command ever trips it.
--- Multi-element-positional existential matching enumerates absorption parses
--- (DFS over each flag's 0/1 choice). Real commands carry a handful of
--- absorbable flags; cap the enumeration so a pathological generated command
--- cannot blow up. Over the cap the gate conservatively MATCHES — for deny/ask
--- that only over-prompts, never an unsound approval.
local MULTI_ELEMENT_FLAG_CAP = 24

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

--- A dash-token that acts as an option in the getopt sense — excludes the `-`
--- stdin/stdout sentinel and the `--` end-of-options marker, both positionals
--- (or, for `--`, a region terminator) rather than flags.
--- @param word string
--- @return boolean
local function is_flag(word)
    return word:sub(1, 1) == "-" and word ~= "-" and word ~= "--"
end

--- A non-flag word: a plain word or the `-` sentinel. `--` is excluded (it is
--- the option-region terminator, neither flag nor positional).
--- @param word string
--- @return boolean
local function is_plain(word)
    return word ~= "--" and not is_flag(word)
end

--- Whether a flag carries its value inline (`--opt=val`, or a glued short
--- cluster `-Cval`/`-uo`), so it absorbs no following word in the allow parse.
--- A bare flag (`-C`, `--opt`) does not.
--- @param flag string
--- @return boolean
local function has_inline_value(flag)
    if flag:sub(1, 2) == "--" then
        return flag:find("=", 1, true) ~= nil
    end
    return #flag > 2
end

--- Option-identifier candidates from every flag in the command (stopping at
--- `--`, after which dash-words are positionals). A flag is a flag in every
--- absorption parse, so this is parse-independent — feeds the order-free
--- `options` gate field.
--- @param words string[]
--- @return string[]
local function flag_candidates(words)
    local cands = {}
    for _, w in ipairs(words) do
        if w == "--" then
            break
        end
        if is_flag(w) then
            vim.list_extend(cands, M.extract_option_candidates(w))
        end
    end
    return cands
end

--- Walk the absorption parses far enough to collect, as index sets:
---   subcommand_idx — indices that can be the first positional (subcommand)
---     in some parse
---   leading_flag_idx — indices of flags that precede the first positional
---     in some parse
--- Each leading flag absorbs 0 or 1 of the immediately-following plain word; the
--- DFS explores both. The walk stops at each plain word (a first-positional
--- candidate), so a post-subcommand flag never enters leading_flag_idx. A `--`
--- ends the option region — the following word is the subcommand.
--- @param words string[]
--- @return table<integer, boolean> subcommand_idx
--- @return table<integer, boolean> leading_flag_idx
local function prefix_walk(words)
    local n = #words
    local subcommand_idx, leading_flag_idx, seen = {}, {}, {}
    local stack = { 1 }
    while #stack > 0 do
        local i = table.remove(stack)
        if i <= n and not seen[i] then
            seen[i] = true
            local w = words[i]
            if w == "--" then
                if i + 1 <= n then
                    subcommand_idx[i + 1] = true
                end
            elseif is_flag(w) then
                leading_flag_idx[i] = true
                table.insert(stack, i + 1) -- absorb 0
                if i + 1 <= n and is_plain(words[i + 1]) then
                    table.insert(stack, i + 2) -- absorb 1 (plain word only)
                end
            else
                subcommand_idx[i] = true
            end
        end
    end
    return subcommand_idx, leading_flag_idx
end

--- Whether any index in `set` carries a dynamic word.
--- @param set table<integer, boolean>
--- @param dynamic boolean[]
--- @return boolean
local function any_dynamic(set, dynamic)
    for i in pairs(set) do
        if dynamic[i] then
            return true
        end
    end
    return false
end

--- Flatten option candidates from the flags at the given indices.
--- @param words string[]
--- @param set table<integer, boolean>
--- @return string[]
local function candidates_at(words, set)
    local cands = {}
    for i in pairs(set) do
        vim.list_extend(cands, M.extract_option_candidates(words[i]))
    end
    return cands
end

--- Existential single-element positional match: does `pattern` match the
--- first-positional candidate at some subcommand index? A dynamic candidate
--- wildcards (it could expand to anything, including the gated subcommand).
--- @param pattern string
--- @param words string[]
--- @param dynamic boolean[]
--- @param subcommand_idx table<integer, boolean>
--- @return boolean
local function some_first_positional_matches(pattern, words, dynamic, subcommand_idx)
    local lua_pat = PermissionRules.glob_to_lua_pattern(pattern)
    for i in pairs(subcommand_idx) do
        if dynamic[i] or words[i]:match(lua_pat) then
            return true
        end
    end
    return false
end

--- Number of flags that could absorb a following plain word — the branching
--- factor of the parse enumeration. Used only to cap multi-element matching.
--- @param words string[]
--- @return integer
local function absorbable_flag_count(words)
    local n, count = #words, 0
    for i = 1, n do
        local w = words[i]
        if w == "--" then
            break
        end
        if is_flag(w) and i + 1 <= n and is_plain(words[i + 1]) then
            count = count + 1
        end
    end
    return count
end

--- Existential multi-element positional match: does some absorption parse's
--- positional stream match `patterns` contiguously from the subcommand
--- (stream index 1)? Trailing stream tokens are allowed; a dynamic stream word
--- wildcards its element and every later one. DFS over each flag's 0/1
--- absorption of the following plain word; a flag never enters the stream.
--- @param patterns string[]
--- @param words string[]
--- @param dynamic boolean[]
--- @return boolean
local function some_stream_matches(patterns, words, dynamic)
    local n = #patterns
    local nw = #words

    --- @param i integer index into words
    --- @param pos integer 1-based index into the positional stream / patterns
    --- @return boolean
    local function rec(i, pos)
        if pos > n then
            return true -- every pattern element matched
        end
        if i > nw then
            return false -- ran out of words first
        end
        local w = words[i]
        if w == "--" then
            for j = i + 1, nw do
                if pos > n then
                    return true
                end
                if dynamic[j] then
                    return true
                end
                local pat = PermissionRules.glob_to_lua_pattern(patterns[pos])
                if not words[j]:match(pat) then
                    return false
                end
                pos = pos + 1
            end
            return pos > n
        elseif is_flag(w) then
            if rec(i + 1, pos) then -- absorb 0
                return true
            end
            if i + 1 <= nw and is_plain(words[i + 1]) then
                return rec(i + 2, pos) -- absorb 1
            end
            return false
        else
            if dynamic[i] then
                return true -- wildcards this element and all later
            end
            local pat = PermissionRules.glob_to_lua_pattern(patterns[pos])
            if words[i]:match(pat) then
                return rec(i + 1, pos + 1)
            end
            return false
        end
    end

    return rec(1, 1)
end

--- @class agentic.PermStructured.ExistCtx
--- @field words string[]
--- @field dynamic boolean[]
--- @field has_dynamic boolean
--- @field flag_cands string[]
--- @field leading_cands string[]
--- @field leading_dynamic boolean
--- @field subcommand_idx table<integer, boolean>

--- Evaluate a gate existentially (deny/ask). Absent fields are wildcards. A
--- dynamic token satisfies `options` (could expand to any flag); `positionals`
--- and `leading_options` get the per-position dynamic treatment documented on
--- their match helpers.
--- @param gate agentic.PermGate
--- @param ctx agentic.PermStructured.ExistCtx
--- @return boolean
local function gate_matches_existential(gate, ctx)
    if gate.options ~= nil then
        if
            not (
                M.match_options(ctx.flag_cands, gate.options)
                or ctx.has_dynamic
            )
        then
            return false
        end
    end
    if gate.leading_options ~= nil then
        if
            not (
                M.match_options(ctx.leading_cands, gate.leading_options)
                or ctx.leading_dynamic
            )
        then
            return false
        end
    end
    if gate.positionals ~= nil and #gate.positionals > 0 then
        local patterns = gate.positionals
        --- @cast patterns string[]
        if #patterns == 1 then
            if
                not some_first_positional_matches(
                    patterns[1],
                    ctx.words,
                    ctx.dynamic,
                    ctx.subcommand_idx
                )
            then
                return false
            end
        elseif absorbable_flag_count(ctx.words) > MULTI_ELEMENT_FLAG_CAP then
            return true -- enumeration cap: over-prompt rather than blow up
        elseif not some_stream_matches(patterns, ctx.words, ctx.dynamic) then
            return false
        end
    end
    return true
end

--- @class agentic.PermStructured.AllowParse
--- @field stream string[]          positional stream (subcommand at index 1)
--- @field stream_dynamic boolean[] parallel to `stream`
--- @field flag_cands string[]      candidates from every flag
--- @field leading_cands string[]   candidates from flags before the subcommand

--- The single deterministic parse used for ALLOW matching: each flag absorbs
--- its following plain word iff it is bare AND a known `value_taking_options`
--- value-taker for `cmd` (inline-value and unlisted flags absorb 0). `--` ends
--- the option region. No wildcarding — allow stays concrete.
--- @param words string[]
--- @param dynamic boolean[]
--- @param cmd string
--- @return agentic.PermStructured.AllowParse
local function allow_parse(words, dynamic, cmd)
    local takers = value_taking_options[cmd] or {}
    --- @type agentic.PermStructured.AllowParse
    local p = { stream = {}, stream_dynamic = {}, flag_cands = {}, leading_cands = {} }
    local options_ended = false
    local i, n = 1, #words
    while i <= n do
        local w = words[i]
        if not options_ended and w == "--" then
            options_ended = true
            i = i + 1
        elseif not options_ended and is_flag(w) then
            local cands = M.extract_option_candidates(w)
            vim.list_extend(p.flag_cands, cands)
            if #p.stream == 0 then
                vim.list_extend(p.leading_cands, cands)
            end
            if
                not has_inline_value(w)
                and takers[w]
                and i + 1 <= n
                and is_plain(words[i + 1])
            then
                i = i + 2 -- absorb the value word
            else
                i = i + 1
            end
        else
            table.insert(p.stream, w)
            table.insert(p.stream_dynamic, dynamic[i] or false)
            i = i + 1
        end
    end
    return p
end

--- Single-parse positional match for ALLOW. Each pattern matches the stream
--- token at the same index (trailing stream tokens allowed). A dynamic stream
--- word is a concrete unknown — it satisfies a `*` element but never a literal.
--- @param patterns string[]
--- @param parse agentic.PermStructured.AllowParse
--- @return boolean
local function allow_positionals_match(patterns, parse)
    for k, pat in ipairs(patterns) do
        local w = parse.stream[k]
        if w == nil then
            return false
        end
        if parse.stream_dynamic[k] then
            if pat ~= "*" then
                return false
            end
        elseif not w:match(PermissionRules.glob_to_lua_pattern(pat)) then
            return false
        end
    end
    return true
end

--- Evaluate a gate against the single allow parse. Absent fields are wildcards.
--- `leading_options` (not carried by bundled allow gates) is matched concretely
--- against the leading flags — no wildcarding, since allow must stay concrete.
--- @param gate agentic.PermGate
--- @param parse agentic.PermStructured.AllowParse
--- @return boolean
local function gate_matches_allow(gate, parse)
    if gate.options ~= nil then
        if not M.match_options(parse.flag_cands, gate.options) then
            return false
        end
    end
    if gate.leading_options ~= nil then
        if not M.match_options(parse.leading_cands, gate.leading_options) then
            return false
        end
    end
    if gate.positionals ~= nil and #gate.positionals > 0 then
        if not allow_positionals_match(gate.positionals, parse) then
            return false
        end
    end
    return true
end

--- The allow-kind names eligible for approval under the active auto_approve
--- mode. `"allow"` admits read_only ∪ safe_write; `"read-only"` admits
--- read_only only; `nil` admits none (no allow gate can fire). Deny/ask gates
--- are unconditional and do not consult this.
--- @param auto_approve agentic.PermAutoApprove
--- @return agentic.PermKind[]
local function eligible_allow_kinds(auto_approve)
    if auto_approve == "allow" then
        return { "read_only", "safe_write" }
    end
    if auto_approve == "read-only" then
        return { "read_only" }
    end
    return {}
end

--- True iff some gate in `gates` matches under `predicate`. A nil or empty
--- array matches nothing.
--- @param gates agentic.PermGate[]|nil
--- @param predicate fun(gate: agentic.PermGate): boolean
--- @return boolean
local function any_gate(gates, predicate)
    if gates == nil then
        return false
    end
    for _, gate in ipairs(gates) do
        if predicate(gate) then
            return true
        end
    end
    return false
end

--- Build the existential-match context shared by `decide_leaf` and
--- `classify_leaf` from a leaf's word list and dynamic mask.
--- @param words string[]
--- @param dynamic boolean[]
--- @return agentic.PermStructured.ExistCtx
local function build_exist_ctx(words, dynamic)
    local has_dynamic = false
    for _, d in ipairs(dynamic) do
        if d then
            has_dynamic = true
            break
        end
    end

    local subcommand_idx, leading_flag_idx = prefix_walk(words)
    --- @type agentic.PermStructured.ExistCtx
    local ctx = {
        words = words,
        dynamic = dynamic,
        has_dynamic = has_dynamic,
        flag_cands = flag_candidates(words),
        leading_cands = candidates_at(words, leading_flag_idx),
        leading_dynamic = any_dynamic(subcommand_idx, dynamic)
            or any_dynamic(leading_flag_idx, dynamic),
        subcommand_idx = subcommand_idx,
    }
    return ctx
end

--- Collect the cmd entry plus the `"*"` wildcard entry, skipping absent or
--- `vim.NIL` values. Built explicitly (not via a `{a, b}` literal) so a nil
--- cmd entry does not truncate ipairs and silently drop the wildcard after it.
--- @param entries agentic.StructuredEntries
--- @param cmd_name string
--- @return agentic.StructuredCmdEntry[]
local function relevant_entries(entries, cmd_name)
    --- @type agentic.StructuredCmdEntry[]
    local relevant = {}
    for _, e in ipairs({ cmd_name, "*" }) do
        local entry = entries[e]
        if entry ~= nil and entry ~= vim.NIL then
            table.insert(relevant, entry)
        end
    end
    return relevant
end

--- Resolve the structured decision for one parsed leaf. Looks up the cmd entry
--- and the `"*"` wildcard entry (either may be absent or `vim.NIL`) and
--- resolves deny > ask > allow across both. Allow gates are restricted to the
--- kind set eligible under `auto_approve` (see `eligible_allow_kinds`).
--- @param entries agentic.StructuredEntries
--- @param parsed agentic.ParsedLeaf
--- @param auto_approve agentic.PermAutoApprove
--- @return agentic.PermDecision
function M.decide_leaf(entries, parsed, auto_approve)
    local words = parsed.args
    local dynamic = parsed.args_dynamic or {}
    local ctx = build_exist_ctx(words, dynamic)
    local relevant = relevant_entries(entries, parsed.cmd_name)

    local function exist(gate)
        return gate_matches_existential(gate, ctx)
    end
    for _, e in ipairs(relevant) do
        if any_gate(e.deny, exist) then
            return "deny"
        end
    end
    for _, e in ipairs(relevant) do
        if any_gate(e.ask, exist) then
            return "ask"
        end
    end

    local parse = allow_parse(words, dynamic, parsed.cmd_name)
    local function allow(gate)
        return gate_matches_allow(gate, parse)
    end
    local kinds = eligible_allow_kinds(auto_approve)
    for _, e in ipairs(relevant) do
        for _, kind in ipairs(kinds) do
            if any_gate(e[kind], allow) then
                return "allow"
            end
        end
    end

    return nil
end

--- @class agentic.PermClassification
--- @field read_only boolean
--- @field safe_write boolean
--- @field ask boolean
--- @field deny boolean

--- Category-level classification of a leaf, independent of `auto_approve`.
--- Where `decide_leaf` resolves a single mode-gated decision, this reports
--- which of the four gate kinds match — the highlight layer needs the
--- intrinsic category ("is this known-safe") not "was this auto-approved", so
--- a `safe_write` like `git add` reads as safe even in `read-only` mode.
--- deny/ask use existential matching; read_only/safe_write use the allow parse.
--- @param entries agentic.StructuredEntries
--- @param parsed agentic.ParsedLeaf
--- @return agentic.PermClassification
function M.classify_leaf(entries, parsed)
    local words = parsed.args
    local dynamic = parsed.args_dynamic or {}
    local ctx = build_exist_ctx(words, dynamic)
    local parse = allow_parse(words, dynamic, parsed.cmd_name)
    local relevant = relevant_entries(entries, parsed.cmd_name)

    local function exist(gate)
        return gate_matches_existential(gate, ctx)
    end
    local function allow(gate)
        return gate_matches_allow(gate, parse)
    end

    --- @type agentic.PermClassification
    local result =
        { read_only = false, safe_write = false, ask = false, deny = false }
    for _, e in ipairs(relevant) do
        if any_gate(e.deny, exist) then
            result.deny = true
        end
        if any_gate(e.ask, exist) then
            result.ask = true
        end
        if any_gate(e.read_only, allow) then
            result.read_only = true
        end
        if any_gate(e.safe_write, allow) then
            result.safe_write = true
        end
    end
    return result
end

return M
