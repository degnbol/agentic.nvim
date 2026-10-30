local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local PermissionRules = require("agentic.utils.permission_rules")

--- Structured option matcher for compound-Bash auto-approval. Consumes a
--- ParsedLeaf produced by the walker (an ordered word list, each word tagged
--- only with whether it expands at runtime) and decides allow / ask / deny /
--- nil against a cmd-keyed table of StructuredCmdEntry rules. The walker has
--- already quote-stripped tokens, joined literal concatenations, and excluded
--- redirects / env-prefixes / substitution; this module trusts that input shape.
---
--- The matcher needs no getopt arity table for soundness. A dash word may or
--- may not take the next word as its value, and the two directions read that
--- ambiguity dually:
---   * deny/ask are EXISTENTIAL — a gate fires if *any* absorption parse (plus
---     dynamic-token wildcarding) exposes the gated subcommand/option. An
---     over-match only over-prompts.
---   * allow is UNIVERSAL — a gate approves only if it holds in *every* parse.
---     An entry's `arity` hints cut the parses. An absent hint never
---     under-guards (it only adds a prompt). A present one is trusted.
---
--- See the `permissions` project skill § "Shell command parsing" for the
--- cross-file overview; this module's functions are the authoritative algorithm.
--- @class agentic.utils.PermissionStructured
local M = {}

--- The highest structured allow kind that auto-approves. Every safer kind
--- approves too.
--- @alias agentic.PermAutoApproveTier "safe_write" | "read_only" | nil
--- @alias agentic.PermDecision "allow" | "ask" | "deny" | nil
--- @alias agentic.PermKind "read_only" | "safe_write" | "ask" | "deny"
--- @alias agentic.PermAllowKind "read_only" | "safe_write"

--- Composition: a gate's present fields are ANDed; identifiers within one
--- `options`/`leading_options` list are ORed; gates within a kind-array are ORed.
--- To require two distinct flags *together*, split them across `options` and
--- `leading_options` — listing both in one `options` array matches either.
--- @class agentic.PermGate
--- @field options?     string[] -- flag identifiers (dashless), matched
---        order-free over every flag anywhere in the command: a letter for a
---        short option (`o`, also inside a cluster `-uo`), a name for a long
---        option (`output` for `--output`). Deny/ask also match an
---        abbreviation; allow matches only the exact identifier of a word
---        that is an option in every parse.
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
---        On allow, for a mode flag that counts only before the operand
---        (`command -v`): the word must precede the first positional in
---        every parse.

--- One value of the cmd-keyed schema. The kind name encodes the policy:
--- `read_only` approves at either non-nil tier, `safe_write` only at
--- "safe_write", `ask` withholds approval and prompts, `deny` rejects immediately (no prompt,
--- the command never runs — see `PermissionRules.should_auto_reject`). Each is an
--- array of gates.
--- @class agentic.StructuredCmdEntry
--- @field read_only?  agentic.PermGate[]
--- @field safe_write? agentic.PermGate[]
--- @field ask?        agentic.PermGate[]
--- @field deny?       agentic.PermGate[]
--- @field arity?      agentic.PermArity

--- Arity hints of one scope, as literal tokens (`-C`, `--file`; a short
--- letter is written `-x` and also applies inside a cluster, so it asserts
--- that the command clusters). A hint outside scope `""` also asserts that the
--- command reads the token as an option after a positional.
--- @class agentic.PermArityScope
--- @field takers?   string[] -- take the next word as their value
--- @field booleans? string[] -- take no value

--- Scope key: `""` = before the first positional; a literal first
--- positional (`config`) = after it; `"*"` = every scope.
--- @alias agentic.PermArity table<string, agentic.PermArityScope>

--- @alias agentic.PermArityKind "taker" | "boolean"
--- @alias agentic.PermTakesNext "always" | "never" | "maybe"

--- Cmd-keyed table (`"*"` is the literal wildcard key). A `vim.NIL` value is
--- treated as "no entry" so a user can disable a bundled cmd via
--- `Config.permissions.structured` (the `vim.NIL` sentinel is untyped here;
--- `decide_leaf` and the loader both filter it).
--- @alias agentic.StructuredEntries table<string, agentic.StructuredCmdEntry>

--- @class agentic.ParsedLeaf
--- @field cmd_name string    after strip_command_path / wrapper strip
--- @field args     string[]  ordered word list, quote-stripped,
---        env-prefix/redirect-excluded. `--` is the end-of-options sentinel,
---        or the value of a flag before it; `-` is a positional
---        (stdin/stdout). No role tagging.
--- @field args_dynamic? boolean[] parallel to `args`: token expands at runtime
---        (variable/glob/quoted-expansion) so its value is unknown. Absent =
---        all-static (back-compat for direct callers).

-- ponytail: fixed cap, raise it if a legitimate command ever trips it.
--- Multi-element-positional existential matching enumerates absorption parses
--- (DFS over each flag's 0/1 choice). Real commands carry a handful of
--- absorbable flags; cap the enumeration so a pathological generated command
--- cannot blow up. Over the cap the gate conservatively MATCHES — for deny/ask
--- that only over-prompts, never an unsound approval.
local MULTI_ELEMENT_FLAG_CAP = 24

--- Option-identifier candidates of one dash word with no whitespace:
--- letters and the one-dash long name for `-abc`, the name for
--- `--name[=value]`. Returns `{}` for `-` and `--`.
--- @param word string
--- @return string[]
local function dash_word_candidates(word)
    -- Long-only =value strip: only fires for `--`-prefixed tokens. Short
    -- tokens keep their full body, so `-=x` stays a short cluster. A
    -- `=` at position 3 (`--=value`) strips to just `--`, which the
    -- sentinel check then rejects.
    local head = word
    if word:sub(1, 2) == "--" then
        local eq = word:find("=", 1, true)
        if eq and eq >= 3 then
            head = word:sub(1, eq - 1)
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

--- Build the set of option-identifier candidates for a single token. The
--- output is over-approximate: extra candidates can only widen a deny/ask
--- match, never miss a real one. Each whitespace-separated segment that
--- starts with `-` is read as its own dash word, since perl parses `-p -i`
--- in one word as two switches. Other segments, and all segments after a
--- `--name=value` segment, are dropped: getopt exits at the whitespace or
--- has already taken it as a value. Returns `{}` for positionals and for
--- dash words with no dash segment that has a body (`-`, `--`, `- x`).
--- @param token string
--- @return string[]
function M.extract_option_candidates(token)
    if token:sub(1, 1) ~= "-" then
        return {}
    end
    local seen = {}
    local out = {}
    for segment in token:gmatch("%S+") do
        if segment:sub(1, 1) == "-" then
            for _, cand in ipairs(dash_word_candidates(segment)) do
                if not seen[cand] then
                    seen[cand] = true
                    table.insert(out, cand)
                end
            end
            if segment:sub(1, 2) == "--" and segment:find("=", 3, true) then
                break
            end
        end
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
--- stdin/stdout sentinel and `--`, which is a region terminator or a value.
--- @param word string
--- @return boolean
local function is_flag(word)
    return word:sub(1, 1) == "-" and word ~= "-" and word ~= "--"
end

--- A non-flag word: a plain word or the `-` sentinel. `--` is excluded (a
--- region terminator or a value, never a positional).
--- @param word string
--- @return boolean
local function is_plain(word)
    return word ~= "--" and not is_flag(word)
end

--- Whether a word can be the value of the flag before it: a plain word, or
--- `--` when `dashdash_value` is set.
--- @param word string
--- @param dashdash_value boolean
--- @return boolean
local function absorbs_value(word, dashdash_value)
    return is_plain(word) or (dashdash_value and word == "--")
end

--- Whether `words[i]` ends the option region in every parse: it is `--` and,
--- when `dashdash_value` is set, does not directly follow a flag (which may
--- take it as its value).
--- @param words string[]
--- @param i integer
--- @param dashdash_value boolean
--- @return boolean
local function ends_options(words, i, dashdash_value)
    if words[i] ~= "--" then
        return false
    end
    return not (dashdash_value and i > 1 and is_flag(words[i - 1]))
end

--- Option-identifier candidates from every dash word that is a flag in some
--- absorption parse: every flag before the first `--` that ends options in
--- every parse.
--- @param words string[]
--- @param dashdash_value boolean `--` may be the value of the flag before it
--- @return string[]
local function flag_candidates(words, dashdash_value)
    local cands = {}
    for i, w in ipairs(words) do
        if ends_options(words, i, dashdash_value) then
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
--- Each leading flag absorbs 0 or 1 immediately-following plain word (or `--`
--- when `dashdash_value` is set); the DFS explores both. The walk stops at each
--- plain word (a first-positional candidate), so a post-subcommand flag never
--- enters leading_flag_idx. A `--` the walk reaches unabsorbed ends the option
--- region — the following word is the subcommand.
--- @param words string[]
--- @param dashdash_value boolean `--` may be the value of the flag before it
--- @return table<integer, boolean> subcommand_idx
--- @return table<integer, boolean> leading_flag_idx
local function prefix_walk(words, dashdash_value)
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
                if i + 1 <= n and absorbs_value(words[i + 1], dashdash_value) then
                    table.insert(stack, i + 2) -- absorb 1
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
local function some_first_positional_matches(
    pattern,
    words,
    dynamic,
    subcommand_idx
)
    local lua_pat = PermissionRules.glob_to_lua_pattern(pattern)
    for i in pairs(subcommand_idx) do
        if dynamic[i] or words[i]:match(lua_pat) then
            return true
        end
    end
    return false
end

--- Number of flags that could absorb a following word — the branching factor
--- of the parse enumeration. Used only to cap multi-element matching.
--- @param words string[]
--- @param dashdash_value boolean `--` may be the value of the flag before it
--- @return integer
local function absorbable_flag_count(words, dashdash_value)
    local n, count = #words, 0
    for i = 1, n do
        local w = words[i]
        if ends_options(words, i, dashdash_value) then
            break
        end
        if
            is_flag(w)
            and i + 1 <= n
            and absorbs_value(words[i + 1], dashdash_value)
        then
            count = count + 1
        end
    end
    return count
end

--- Existential multi-element positional match: does some absorption parse's
--- positional stream match `patterns` contiguously from the subcommand
--- (stream index 1)? Trailing stream tokens are allowed; a dynamic stream word
--- wildcards its element and every later one. DFS over each flag's 0/1
--- absorption of the following plain word (or `--` when `dashdash_value` is
--- set); a flag never enters the stream. A `--` reached unabsorbed ends the
--- option region.
--- @param patterns string[]
--- @param words string[]
--- @param dynamic boolean[]
--- @param dashdash_value boolean `--` may be the value of the flag before it
--- @return boolean
local function some_stream_matches(patterns, words, dynamic, dashdash_value)
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
            if
                i + 1 <= nw and absorbs_value(words[i + 1], dashdash_value)
            then
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
--- @field dashdash_value boolean `--` may be the value of the flag before it
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
        elseif
            absorbable_flag_count(ctx.words, ctx.dashdash_value)
            > MULTI_ELEMENT_FLAG_CAP
        then
            return true -- enumeration cap: over-prompt rather than blow up
        elseif
            not some_stream_matches(
                patterns,
                ctx.words,
                ctx.dynamic,
                ctx.dashdash_value
            )
        then
            return false
        end
    end
    return true
end

--- Hinted arity of each option token in a scope.
--- @param arity agentic.PermArity|nil hints of one command
--- @param scope string scope key, read together with `"*"`
--- @return table<string, agentic.PermArityKind> kind per literal token. A
---         token listed as both kinds is absent (unknown).
local function arity_kinds(arity, scope)
    --- @type table<string, agentic.PermArityKind|false>
    local listed = {}
    for _, key in ipairs({ scope, "*" }) do
        local hints = arity and arity[key] or {}
        for kind, tokens in pairs({
            taker = hints.takers or {},
            boolean = hints.booleans or {},
        }) do
            for _, token in ipairs(tokens) do
                local prev = listed[token]
                listed[token] = (prev == nil or prev == kind) and kind or false
            end
        end
    end
    --- @type table<string, agentic.PermArityKind>
    local kinds = {}
    for token, kind in pairs(listed) do
        if kind then
            kinds[token] = kind
        end
    end
    return kinds
end

--- Whether an option word takes the next word as its value.
--- @param word string a dash word other than `-` and `--`
--- @param kinds table<string, agentic.PermArityKind> hinted kind per token
--- @return agentic.PermTakesNext takes `"never"` for `--x=v`. A bare
---         `--x` follows its hinted kind, else `"maybe"`. A cluster `-abc`
---         follows its first letter that is not a hinted boolean: a taker
---         gives `"always"` as the last letter, else `"never"` (the rest is
---         its value). An unhinted letter gives `"maybe"`. All hinted
---         booleans give `"never"`.
local function option_takes_next(word, kinds)
    if word:sub(1, 2) == "--" then
        if word:find("=", 3, true) then
            return "never"
        end
        local kind = kinds[word]
        if kind == nil then
            return "maybe"
        end
        return kind == "taker" and "always" or "never"
    end
    local letters = word:sub(2)
    for i = 1, #letters do
        local kind = kinds["-" .. letters:sub(i, i)]
        if kind == "taker" then
            return i == #letters and "always" or "never"
        end
        if kind ~= "boolean" then
            return "maybe"
        end
    end
    return "never"
end

--- Identifiers an option word carries in every cluster reading. Only the
--- text before its first whitespace counts.
--- @param word string a dash word
--- @param kinds table<string, agentic.PermArityKind> hinted kind per token
--- @return string[] ids `name` for `--name[=v]`. For `-abc`, the letters up
---         to and including the first that is not a hinted boolean (a later
---         letter may be its value).
local function sure_identifiers(word, kinds)
    local head = word:match("^%S*")
    if head:sub(1, 2) == "--" then
        local name = head:sub(3):match("^[^=]+")
        return name and { name } or {}
    end
    local ids = {}
    for letter in head:sub(2):gmatch(".") do
        table.insert(ids, letter)
        if kinds["-" .. letter] ~= "boolean" then
            break
        end
    end
    return ids
end

--- The scope class of a parse after it reads a positional.
--- @param scope string scope class before `positional`. `""` before the
---        first positional.
--- @param positional string
--- @param arity agentic.PermArity|nil hints of the command
--- @return string scope `scope` when it is not `""`. Else `positional` when
---         `arity` has it as a key, else `"*"` (only every-scope hints apply).
local function scope_after(scope, positional, arity)
    if scope ~= "" then
        return scope
    end
    if positional ~= "" and arity and arity[positional] then
        return positional
    end
    return "*"
end

--- Whether `word` is a positional in a parse.
--- @param word string
--- @param open boolean options have not ended in the parse
--- @return boolean
local function is_positional(word, open)
    return not open or is_plain(word)
end

--- One parse, at a word boundary.
--- @class agentic.PermStructured.ParseState
--- @field i integer index of the next word
--- @field scope string scope class: `""` before the first positional, else
---        the arity key that applies after it
--- @field open boolean options not yet ended

--- Key that is equal for two states at the same word index iff the rest of
--- their parses are the same.
--- @param state agentic.PermStructured.ParseState
--- @return string key of `scope` and `open`
local function state_key(state)
    return (state.open and "+" or "-") .. state.scope
end

--- Every parse of one word list, for universal matching.
--- @class agentic.PermStructured.ForallCtx
--- @field words        string[]
--- @field n_static     integer number of words before the first dynamic one
--- @field arity?       agentic.PermArity
--- @field kinds        table<string, table<string, agentic.PermArityKind>> hinted kind per token, per scope class, filled lazily
--- @field sure_flags   string[] identifiers that are options in every parse
--- @field sure_leading string[] those also before every parse's first positional

--- Hinted kind per token in a scope class. Caches into `ctx.kinds`.
--- @param ctx agentic.PermStructured.ForallCtx
--- @param scope string
--- @return table<string, agentic.PermArityKind>
local function kinds_in(ctx, scope)
    local kinds = ctx.kinds[scope]
    if kinds == nil then
        kinds = arity_kinds(ctx.arity, scope)
        ctx.kinds[scope] = kinds
    end
    return kinds
end

--- The states one parse step over the word at `state.i` leads to: past a
--- positional (which may set the scope class), past `--` (closing options),
--- or past an option word without and/or with its value, per its hinted
--- arity. A taker that is the last word leads nowhere (getopt errors), so
--- every condition on the rest of that parse holds vacuously.
--- @param ctx agentic.PermStructured.ForallCtx
--- @param state agentic.PermStructured.ParseState at a static word
--- @return agentic.PermStructured.ParseState[] states
local function parse_steps(ctx, state)
    local i, word = state.i, ctx.words[state.i]
    if is_positional(word, state.open) then
        local scope = scope_after(state.scope, word, ctx.arity)
        return { { i = i + 1, scope = scope, open = state.open } }
    end
    if word == "--" then
        return { { i = i + 1, scope = state.scope, open = false } }
    end
    local takes = option_takes_next(word, kinds_in(ctx, state.scope))
    --- @type agentic.PermStructured.ParseState[]
    local states = {}
    if takes ~= "always" then
        table.insert(states, { i = i + 1, scope = state.scope, open = true })
    end
    if takes ~= "never" and i < #ctx.words then
        table.insert(states, { i = i + 2, scope = state.scope, open = true })
    end
    return states
end

--- Intersection of lists.
--- @param lists string[][] non-empty
--- @return string[] elements of `lists[1]` in every list, in their order
local function intersection(lists)
    return vim.iter(lists[1])
        :filter(function(id)
            return vim.iter(lists):all(function(list)
                return vim.tbl_contains(list, id)
            end)
        end)
        :totable()
end

--- Context over every parse of a word list, with the identifiers that are
--- options in every parse. A word contributes when no parse takes it as a
--- value, every parse that reaches it has options open, and no dynamic word
--- comes before it (one may expand to an option, `--`, or several words).
--- Its identifiers are those it carries in every cluster reading, in every
--- scope class it is reached in.
--- @param words string[]
--- @param dynamic boolean[] parallel to `words`: expands at runtime
--- @param arity agentic.PermArity|nil hints of the command
--- @return agentic.PermStructured.ForallCtx
local function build_forall_ctx(words, dynamic, arity)
    local n_static = #words
    for i = 1, #words do
        if dynamic[i] then
            n_static = i - 1
            break
        end
    end
    --- @type agentic.PermStructured.ForallCtx
    local ctx = {
        words = words,
        n_static = n_static,
        arity = arity,
        kinds = {},
        sure_flags = {},
        sure_leading = {},
    }
    --- @type agentic.PermStructured.ParseState
    local start = { i = 1, scope = "", open = true }
    --- @type table<integer, table<string, agentic.PermStructured.ParseState>>
    local reached = { { [state_key(start)] = start } }
    --- @type table<integer, true>
    local absorbed = {}
    for i = 1, n_static do
        local states = vim.tbl_values(reached[i] or {})
        local options_word = #states > 0
            and not absorbed[i]
            and is_flag(words[i])
            and vim.iter(states):all(function(s)
                return s.open
            end)
        if options_word then
            local ids = intersection(vim.tbl_map(function(s)
                return sure_identifiers(words[i], kinds_in(ctx, s.scope))
            end, states))
            vim.list_extend(ctx.sure_flags, ids)
            if
                vim.iter(states):all(function(s)
                    return s.scope == ""
                end)
            then
                vim.list_extend(ctx.sure_leading, ids)
            end
        end
        for _, state in ipairs(states) do
            for _, next_state in ipairs(parse_steps(ctx, state)) do
                if next_state.i == i + 2 then
                    absorbed[i + 1] = true
                end
                reached[next_state.i] = reached[next_state.i] or {}
                reached[next_state.i][state_key(next_state)] = next_state
            end
        end
    end
    return ctx
end

--- Whether the positional stream of every parse matches `patterns`
--- contiguously from the first positional, trailing words allowed. A parse
--- fails when it reaches the end, reaches a dynamic word, or takes one as a
--- value, with elements left.
--- @param patterns string[] one glob per element
--- @param ctx agentic.PermStructured.ForallCtx
--- @return boolean
local function every_stream_matches(patterns, ctx)
    local lua_patterns =
        vim.tbl_map(PermissionRules.glob_to_lua_pattern, patterns)
    --- @type table<string, boolean>
    local memo = {}

    --- @param state agentic.PermStructured.ParseState
    --- @param pos integer index into `patterns`
    --- @return boolean
    local function holds(state, pos)
        if pos > #patterns then
            return true
        end
        -- Past the static words: at the end, or at or past a dynamic word
        -- (every parse beyond it reached it or took it as a value).
        local i = state.i
        if i > ctx.n_static then
            return false
        end
        local key = i .. ":" .. pos .. ":" .. state_key(state)
        if memo[key] == nil then
            local word = ctx.words[i]
            local positional = is_positional(word, state.open)
            if positional and not word:match(lua_patterns[pos]) then
                memo[key] = false
            else
                local next_pos = positional and pos + 1 or pos
                memo[key] = vim.iter(parse_steps(ctx, state)):all(function(s)
                    return holds(s, next_pos)
                end)
            end
        end
        return memo[key]
    end

    return holds({ i = 1, scope = "", open = true }, 1)
end

--- True iff the two lists share an element.
--- @param a string[]
--- @param b string[]
--- @return boolean
local function intersects(a, b)
    for _, x in ipairs(a) do
        if vim.tbl_contains(b, x) then
            return true
        end
    end
    return false
end

--- Whether `gate` holds in every parse of `ctx`. Absent fields are
--- wildcards. Option identifiers match exactly (no abbreviation).
--- @param gate agentic.PermGate
--- @param ctx agentic.PermStructured.ForallCtx
--- @return boolean
local function gate_matches_universal(gate, ctx)
    if gate.options ~= nil and not intersects(ctx.sure_flags, gate.options) then
        return false
    end
    if
        gate.leading_options ~= nil
        and not intersects(ctx.sure_leading, gate.leading_options)
    then
        return false
    end
    if gate.positionals ~= nil and #gate.positionals > 0 then
        return every_stream_matches(gate.positionals, ctx)
    end
    return true
end

--- The allow kinds that approve at `tier`. Deny/ask gates
--- are unconditional and do not consult this.
--- @param tier agentic.PermAutoApproveTier
--- @return agentic.PermAllowKind[]
local function eligible_allow_kinds(tier)
    if tier == "safe_write" then
        return { "read_only", "safe_write" }
    end
    if tier == "read_only" then
        return { "read_only" }
    end
    return {}
end

--- Reset `Config.permissions.auto_approve_tier` to nil, with a warning, when
--- it is not an `agentic.PermAutoApproveTier` value. Any other string is
--- truthy, so it would let settings.json allow patterns count while no
--- structured kind does.
function M.validate_auto_approve_tier()
    local tier = Config.permissions.auto_approve_tier
    if tier == nil or #eligible_allow_kinds(tier) > 0 then
        return
    end
    Logger.notify(
        'permissions.auto_approve_tier must be "safe_write", "read_only" or nil, got '
            .. vim.inspect(tier)
            .. "; using nil: no allow rule auto-approves.",
        vim.log.levels.WARN,
        { title = "Agentic" }
    )
    Config.permissions.auto_approve_tier = nil
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

--- Build the existential-match context from a leaf's word list and dynamic mask.
--- @param words string[]
--- @param dynamic boolean[]
--- @param dashdash_value boolean `--` may be the value of the flag before it
--- @return agentic.PermStructured.ExistCtx
local function build_exist_ctx(words, dynamic, dashdash_value)
    local has_dynamic = false
    for _, d in ipairs(dynamic) do
        if d then
            has_dynamic = true
            break
        end
    end

    local subcommand_idx, leading_flag_idx = prefix_walk(words, dashdash_value)
    --- @type agentic.PermStructured.ExistCtx
    local ctx = {
        words = words,
        dynamic = dynamic,
        dashdash_value = dashdash_value,
        has_dynamic = has_dynamic,
        flag_cands = flag_candidates(words, dashdash_value),
        leading_cands = candidates_at(words, leading_flag_idx),
        leading_dynamic = any_dynamic(subcommand_idx, dynamic)
            or any_dynamic(leading_flag_idx, dynamic),
        subcommand_idx = subcommand_idx,
    }
    return ctx
end

--- The entries at `keys`, in order, skipping absent or `vim.NIL` values. Built
--- explicitly (not via a `{a, b}` literal of entries) so an absent entry does
--- not truncate ipairs and silently drop the ones after it.
--- @param entries agentic.StructuredEntries
--- @param keys string[]
--- @return agentic.StructuredCmdEntry[]
local function entries_at(entries, keys)
    --- @type agentic.StructuredCmdEntry[]
    local present = {}
    for _, key in ipairs(keys) do
        local entry = entries[key]
        if entry ~= nil and entry ~= vim.NIL then
            table.insert(present, entry)
        end
    end
    return present
end

--- The arity hints of `cmd_name`'s own entry, never of the `"*"` entry.
--- @param entries agentic.StructuredEntries
--- @param cmd_name string
--- @return agentic.PermArity|nil arity nil when the entry or its hints are absent
local function arity_of(entries, cmd_name)
    local entry = entries_at(entries, { cmd_name })[1]
    return entry and entry.arity
end

--- The cmd entry plus the `"*"` wildcard entry (see `entries_at`).
--- @param entries agentic.StructuredEntries
--- @param cmd_name string
--- @return agentic.StructuredCmdEntry[]
local function relevant_entries(entries, cmd_name)
    return entries_at(entries, { cmd_name, "*" })
end

--- The entries whose allow gates apply to `cmd_name`: its own entry and the
--- `"*"` wildcard (see `entries_at`). A path-named command (`./deploy.sh`)
--- gets no wildcard: its gates assume a program that parses options, which a
--- script may not.
--- @param entries agentic.StructuredEntries
--- @param cmd_name string
--- @return agentic.StructuredCmdEntry[]
local function allow_entries(entries, cmd_name)
    if cmd_name:find("/", 1, true) then
        return entries_at(entries, { cmd_name })
    end
    return relevant_entries(entries, cmd_name)
end

--- Resolve the structured decision for one parsed leaf. Looks up the cmd entry
--- and the `"*"` wildcard entry (either may be absent or `vim.NIL`) and
--- resolves deny > ask > allow across both. Allow gates count only for the
--- kinds `tier` admits, and a path-named command (`./deploy.sh`) gets no `"*"`
--- allow gates.
--- @param entries agentic.StructuredEntries
--- @param parsed agentic.ParsedLeaf
--- @param tier agentic.PermAutoApproveTier
--- @return agentic.PermDecision decision
--- @return agentic.PermAllowKind|nil kind Kind of the matching allow gate; nil unless decision is "allow". On several matches the command's own entry wins over `"*"`, then `read_only` over `safe_write`
function M.decide_leaf(entries, parsed, tier)
    local words = parsed.args
    local dynamic = parsed.args_dynamic or {}
    local ctx = build_exist_ctx(words, dynamic, true)
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

    local forall =
        build_forall_ctx(words, dynamic, arity_of(entries, parsed.cmd_name))
    local function allow(gate)
        return gate_matches_universal(gate, forall)
    end
    local kinds = eligible_allow_kinds(tier)
    for _, e in ipairs(allow_entries(entries, parsed.cmd_name)) do
        for _, kind in ipairs(kinds) do
            if any_gate(e[kind], allow) then
                return "allow", kind
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

--- Category-level classification of a leaf, independent of `auto_approve_tier`.
--- Where `decide_leaf` resolves a single mode-gated decision, this reports
--- which of the four gate kinds match — the highlight layer needs the
--- intrinsic category ("is this known-safe") not "was this auto-approved", so
--- a `safe_write` like `git add` reads as safe even at the `read_only` tier.
--- deny/ask use existential matching; read_only/safe_write universal
--- matching, with no `"*"` gates for a path-named command.
--- @param entries agentic.StructuredEntries
--- @param parsed agentic.ParsedLeaf
--- @return agentic.PermClassification
function M.classify_leaf(entries, parsed)
    local words = parsed.args
    local dynamic = parsed.args_dynamic or {}
    local ctx = build_exist_ctx(words, dynamic, true)
    local forall =
        build_forall_ctx(words, dynamic, arity_of(entries, parsed.cmd_name))
    local relevant = relevant_entries(entries, parsed.cmd_name)

    local function exist(gate)
        return gate_matches_existential(gate, ctx)
    end
    local function allow(gate)
        return gate_matches_universal(gate, forall)
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
    end
    for _, e in ipairs(allow_entries(entries, parsed.cmd_name)) do
        if any_gate(e.read_only, allow) then
            result.read_only = true
        end
        if any_gate(e.safe_write, allow) then
            result.safe_write = true
        end
    end
    return result
end

--- Concrete-only deny check for the reject pass. True iff some deny gate matches
--- under CONCRETE matching — a dynamic token NEVER satisfies a deny gate here.
--- This deliberately diverges from `decide_leaf`/`classify_leaf`, which wildcard
--- dynamic tokens so a laundered payload (`rm $flags x`) escalates to a prompt:
--- the reject pass runs first and its fallback is a hard reject with no prompt,
--- so a maybe-deny must fall through to the approve walk (where the dynamic token
--- withholds approval and prompts) rather than hard-reject here. For the same
--- reason `--` stays the end of options even directly after a flag: a deny that
--- matches only when that `--` is the flag's value does not reject, because
--- `rm -r -- -f` removes a file named `-f`.
--- @param entries agentic.StructuredEntries
--- @param parsed agentic.ParsedLeaf
--- @return boolean
function M.deny_leaf(entries, parsed)
    local ctx = build_exist_ctx(parsed.args, {}, false)
    local relevant = relevant_entries(entries, parsed.cmd_name)
    local function exist(gate)
        return gate_matches_existential(gate, ctx)
    end
    for _, e in ipairs(relevant) do
        if any_gate(e.deny, exist) then
            return true
        end
    end
    return false
end

return M
