local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local OptionParse = require("agentic.utils.option_parse")

--- Structured option matcher for compound-Bash auto-approval. Consumes a
--- ParsedLeaf produced by the walker (an ordered word list, each word tagged
--- only with whether it expands at runtime) and decides allow / ask / deny /
--- nil against a cmd-keyed table of StructuredCmdEntry rules. The walker has
--- already quote-stripped tokens, joined literal concatenations, and excluded
--- redirects / env-prefixes / substitution; this module trusts that input shape.
---
--- A dash word may or may not take the next word as its value, and the two
--- directions read that ambiguity dually:
---   * deny/ask are EXISTENTIAL — a gate fires if *any* absorption parse (plus
---     dynamic-token wildcarding) exposes the gated subcommand/option. An
---     over-match only over-prompts.
---   * allow is UNIVERSAL — a gate approves only if it holds in *every* parse.
---     An entry's `arity` hints cut the parses. An absent hint never
---     under-guards (it only adds a prompt). A present one is trusted.
--- A short letter hinted as a taker in every scope also ends a cluster for
--- deny/ask (`-o/dev/null` carries only `o`). An `unless` swaps the readings
--- of its gates, so an ask's `unless` is universal. So a present hint can
--- also suppress a deny or an ask.
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
--- `unless` negates, which with AND and OR gives full propositional logic.
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
--- @field unless? agentic.PermGate[] -- the gate holds only if none of these
---        holds. Not on deny gates.
--- @field option_values? agentic.PermOptionValues -- must also hold. Not on
---        deny gates.

--- Some listed option occurs, and every occurrence of any listed option has
--- a value that matches a glob. The options are one group: `-X GET --method
--- POST` fails `{ options = { "X", "method" }, values = { "GET" } }`.
--- @class agentic.PermOptionValues
--- @field options string[] dashless identifiers, one group
--- @field values string[] globs a value must match (`*` crosses `/`)

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

--- Convert a settings.json glob to an anchored Lua pattern. `*` matches any
--- run of characters, `|`, `;` and `&` included; every other character is
--- literal.
--- @param glob string
--- @return string lua_pattern
function M.glob_to_lua_pattern(glob)
    local pieces = vim.tbl_map(vim.pesc, vim.split(glob, "*", { plain = true }))
    return "^" .. table.concat(pieces, ".*") .. "$"
end

-- ponytail: fixed cap, raise it if a legitimate command ever trips it.
--- Multi-element-positional existential matching enumerates absorption parses
--- (DFS over each flag's 0/1 choice). Real commands carry a handful of
--- absorbable flags; cap the enumeration so a pathological generated command
--- cannot blow up. Over the cap the gate conservatively MATCHES — for deny/ask
--- that only over-prompts, never an unsound approval.
local MULTI_ELEMENT_FLAG_CAP = 24

--- Option-identifier candidates of one dash word with no whitespace:
--- letters and the one-dash long name for `-abc`, the name for
--- `--name[=value]`. Returns `{}` for `-` and `--`. In `-abc`, a letter in
--- `takers` ends the letters: the rest of the word is its value.
--- @param word string
--- @param takers table<string, true> letters that take a value
--- @return string[] candidates
--- @return boolean valued the rest of the word is a value
local function dash_word_candidates(word, takers)
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

    local valued = head ~= word

    -- End-of-options / stdin sentinels.
    if head == "-" or head == "--" then
        return {}, valued
    end

    if head:sub(1, 2) == "--" then
        local name = head:sub(3)
        if name == "" then
            return {}, valued
        end
        return { name }, valued
    end

    -- Short-flag branch: head starts with "-" but not "--".
    local body = head:sub(2)
    if body == "" then
        return {}, false
    end

    local seen = {}
    local out = {}
    for i = 1, #body do
        local ch = body:sub(i, i)
        if not seen[ch] then
            seen[ch] = true
            table.insert(out, ch)
        end
        if takers[ch] then
            return out, true
        end
    end
    if not seen[body] then
        table.insert(out, body)
    end
    return out, false
end

--- Build the set of option-identifier candidates for a single token. The
--- output is over-approximate: extra candidates can only widen a deny/ask
--- match, and miss a real one only when `takers` is wrong. Each whitespace-separated segment that
--- starts with `-` is read as its own dash word, since perl parses `-p -i`
--- in one word as two switches. Other segments, and all segments after a
--- `--name=value` segment, are dropped: getopt exits at the whitespace or
--- has already taken it as a value. Returns `{}` for positionals and for
--- dash words with no dash segment that has a body (`-`, `--`, `- x`).
--- @param token string
--- @param takers table<string, true>|nil short letters that take a value in
---        every scope (`o` for `-o`): in a cluster, the rest of the token is
---        that letter's value
--- @return string[]
function M.extract_option_candidates(token, takers)
    if token:sub(1, 1) ~= "-" then
        return {}
    end
    local seen = {}
    local out = {}
    for segment in token:gmatch("%S+") do
        if segment:sub(1, 1) == "-" then
            local cands, valued = dash_word_candidates(segment, takers or {})
            for _, cand in ipairs(cands) do
                if not seen[cand] then
                    seen[cand] = true
                    table.insert(out, cand)
                end
            end
            if valued then
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

--- Option candidates of every dash word that is a flag in some absorption
--- parse: every flag before the first `--` that ends options in every parse.
--- @param words string[]
--- @param dashdash_value boolean `--` may be the value of the flag before it
--- @param takers table<string, true> see `M.extract_option_candidates`
--- @return table<integer, string[]> candidates by word index
local function flag_candidates_at(words, dashdash_value, takers)
    local cands_at = {}
    for i, w in ipairs(words) do
        if ends_options(words, i, dashdash_value) then
            break
        end
        if is_flag(w) then
            cands_at[i] = M.extract_option_candidates(w, takers)
        end
    end
    return cands_at
end

--- Whether the candidates of some word match `rule_options`.
--- @param cands_at table<integer, string[]> candidates by word index
--- @param rule_options string[]
--- @return boolean
local function some_word_matches(cands_at, rule_options)
    for _, cands in pairs(cands_at) do
        if M.match_options(cands, rule_options) then
            return true
        end
    end
    return false
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
                if
                    i + 1 <= n and absorbs_value(words[i + 1], dashdash_value)
                then
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
--- @param takers table<string, true> see `M.extract_option_candidates`
--- @return string[]
local function candidates_at(words, set, takers)
    local cands = {}
    for i in pairs(set) do
        vim.list_extend(cands, M.extract_option_candidates(words[i], takers))
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
    local lua_pat = M.glob_to_lua_pattern(pattern)
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
                local pat = M.glob_to_lua_pattern(patterns[pos])
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
            if i + 1 <= nw and absorbs_value(words[i + 1], dashdash_value) then
                return rec(i + 2, pos) -- absorb 1
            end
            return false
        else
            if dynamic[i] then
                return true -- wildcards this element and all later
            end
            local pat = M.glob_to_lua_pattern(patterns[pos])
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
--- @field flag_cands_at table<integer, string[]> option candidates of each word that is a flag in some parse, by word index
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
                some_word_matches(ctx.flag_cands_at, gate.options)
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
--- @return table<string, agentic.OptionKind> kind per literal token. A
---         token listed as both kinds is absent (unknown).
local function arity_kinds(arity, scope)
    --- @type table<string, agentic.OptionKind|false>
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
    --- @type table<string, agentic.OptionKind>
    local kinds = {}
    for token, kind in pairs(listed) do
        if kind then
            kinds[token] = kind
        end
    end
    return kinds
end

--- The short letters that take a value in every scope.
--- @param arity agentic.PermArity|nil hints of one command
--- @return table<string, true> takers letters, `o` for `-o`
local function every_scope_takers(arity)
    local scopes = vim.list_extend({ "", "*" }, vim.tbl_keys(arity or {}))
    local kinds_per_scope = vim.tbl_map(function(scope)
        return arity_kinds(arity, scope)
    end, scopes)
    --- @type table<string, true>
    local takers = {}
    for token in pairs(kinds_per_scope[1]) do
        local letter = token:match("^%-([^%-])$")
        if
            letter
            and vim.iter(kinds_per_scope):all(function(kinds)
                return kinds[token] == "taker"
            end)
        then
            takers[letter] = true
        end
    end
    return takers
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
--- @field kinds        table<string, table<string, agentic.OptionKind>> hinted kind per token, per scope class, filled lazily
--- @field sure_flags   string[] identifiers that are options in every parse
--- @field sure_leading string[] those also before every parse's first positional
--- @field word_values  table<integer, agentic.OptionValue> option value of an option word, by word index, when every parse gives the same one

--- Hinted kind per token in a scope class. Caches into `ctx.kinds`.
--- @param ctx agentic.PermStructured.ForallCtx
--- @param scope string
--- @return table<string, agentic.OptionKind>
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
    local takes = OptionParse.takes_next(word, kinds_in(ctx, state.scope))
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

--- The option value an option word gives under every one of several hint
--- sets.
--- @param word string a dash word other than `-` and `--`
--- @param next_word string|nil
--- @param kinds_list table<string, agentic.OptionKind>[] non-empty
--- @return agentic.OptionValue|nil occurrence nil when some hint set gives
---         none or two give different ones
local function option_value_in_every(word, next_word, kinds_list)
    local first = OptionParse.option_value(word, next_word, kinds_list[1])
    if first == nil then
        return nil
    end
    for i = 2, #kinds_list do
        local occurrence =
            OptionParse.option_value(word, next_word, kinds_list[i])
        if occurrence == nil or not vim.deep_equal(occurrence, first) then
            return nil
        end
    end
    return first
end

--- Context over every parse of a word list, with the identifiers that are
--- options in every parse and the option value each such word gives. A word
--- contributes when no parse takes it as a value, every parse that reaches
--- it has options open, and no dynamic word
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
        word_values = {},
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
                return OptionParse.sure_identifiers(
                    words[i],
                    kinds_in(ctx, s.scope)
                )
            end, states))
            vim.list_extend(ctx.sure_flags, ids)
            ctx.word_values[i] = option_value_in_every(
                words[i],
                words[i + 1],
                vim.tbl_map(function(s)
                    return kinds_in(ctx, s.scope)
                end, states)
            )
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
    local lua_patterns = vim.tbl_map(M.glob_to_lua_pattern, patterns)
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

--- Whether `cond` holds in every parse. Some flag word must name a listed
--- option. Every flag word that names one, abbreviations included, must give
--- in every parse a value to a listed option spelled in full, and each
--- candidate value must match a glob in `cond.values`. False when the leaf
--- has a dynamic word.
--- @param cond agentic.PermOptionValues
--- @param exist agentic.PermStructured.ExistCtx
--- @param forall agentic.PermStructured.ForallCtx
--- @return boolean
local function option_values_must(cond, exist, forall)
    if exist.has_dynamic then
        return false
    end
    local value_patterns = vim.tbl_map(M.glob_to_lua_pattern, cond.values)
    local function allowed(value)
        return vim.iter(value_patterns):any(function(pattern)
            return value:match(pattern) ~= nil
        end)
    end
    local hit = false
    for i, cands in pairs(exist.flag_cands_at) do
        if M.match_options(cands, cond.options) then
            local occurrence = forall.word_values[i]
            if
                occurrence == nil
                or not vim.list_contains(cond.options, occurrence.id)
                or not vim.iter(occurrence.values):all(allowed)
            then
                return false
            end
            hit = true
        end
    end
    return hit
end

--- Whether `cond` may hold: some listed option may occur. Values are
--- ignored.
--- @param cond agentic.PermOptionValues
--- @param exist agentic.PermStructured.ExistCtx
--- @return boolean
local function option_values_may(cond, exist)
    return some_word_matches(exist.flag_cands_at, cond.options)
        or exist.has_dynamic
end

local gate_must

--- Whether `gate` holds in some parse: its plain fields match
--- existentially, its `option_values` may hold, and no `unless` gate holds
--- in every parse.
--- @param gate agentic.PermGate
--- @param exist agentic.PermStructured.ExistCtx
--- @param get_forall fun(): agentic.PermStructured.ForallCtx
--- @return boolean
local function gate_may(gate, exist, get_forall)
    return gate_matches_existential(gate, exist)
        and (gate.option_values == nil or option_values_may(
            gate.option_values,
            exist
        ))
        and not any_gate(gate.unless, function(g)
            return gate_must(g, exist, get_forall)
        end)
end

--- Whether `gate` holds in every parse: its plain fields match
--- universally, its `option_values` holds in every parse, and every
--- `unless` gate fails in every parse.
--- @param gate agentic.PermGate
--- @param exist agentic.PermStructured.ExistCtx
--- @param get_forall fun(): agentic.PermStructured.ForallCtx
--- @return boolean
gate_must = function(gate, exist, get_forall)
    return gate_matches_universal(gate, get_forall())
        and (gate.option_values == nil or option_values_must(
            gate.option_values,
            exist,
            get_forall()
        ))
        and not any_gate(gate.unless, function(g)
            return gate_may(g, exist, get_forall)
        end)
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

--- Build the existential-match context from a leaf's word list and dynamic mask.
--- @param words string[]
--- @param dynamic boolean[]
--- @param dashdash_value boolean `--` may be the value of the flag before it
--- @param takers table<string, true> see `M.extract_option_candidates`
--- @return agentic.PermStructured.ExistCtx
local function build_exist_ctx(words, dynamic, dashdash_value, takers)
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
        flag_cands_at = flag_candidates_at(words, dashdash_value, takers),
        leading_cands = candidates_at(words, leading_flag_idx, takers),
        leading_dynamic = any_dynamic(subcommand_idx, dynamic)
            or any_dynamic(leading_flag_idx, dynamic),
        subcommand_idx = subcommand_idx,
    }
    return ctx
end

--- A getter that builds the universal-match context on its first call and
--- returns the same one after.
--- @param words string[]
--- @param dynamic boolean[]
--- @param arity agentic.PermArity|nil hints of the command
--- @return fun(): agentic.PermStructured.ForallCtx
local function forall_getter(words, dynamic, arity)
    --- @type agentic.PermStructured.ForallCtx|nil
    local ctx
    return function()
        ctx = ctx or build_forall_ctx(words, dynamic, arity)
        return ctx
    end
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
    local arity = arity_of(entries, parsed.cmd_name)
    local ctx = build_exist_ctx(words, dynamic, true, every_scope_takers(arity))
    local relevant = relevant_entries(entries, parsed.cmd_name)
    local get_forall = forall_getter(words, dynamic, arity)

    local function exist(gate)
        return gate_matches_existential(gate, ctx)
    end
    for _, e in ipairs(relevant) do
        if any_gate(e.deny, exist) then
            return "deny"
        end
    end
    local function may(gate)
        return gate_may(gate, ctx, get_forall)
    end
    for _, e in ipairs(relevant) do
        if any_gate(e.ask, may) then
            return "ask"
        end
    end

    local function allow(gate)
        return gate_must(gate, ctx, get_forall)
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
    local arity = arity_of(entries, parsed.cmd_name)
    local ctx = build_exist_ctx(words, dynamic, true, every_scope_takers(arity))
    local get_forall = forall_getter(words, dynamic, arity)
    local relevant = relevant_entries(entries, parsed.cmd_name)

    local function exist(gate)
        return gate_matches_existential(gate, ctx)
    end
    local function may(gate)
        return gate_may(gate, ctx, get_forall)
    end
    local function allow(gate)
        return gate_must(gate, ctx, get_forall)
    end

    --- @type agentic.PermClassification
    local result =
        { read_only = false, safe_write = false, ask = false, deny = false }
    for _, e in ipairs(relevant) do
        if any_gate(e.deny, exist) then
            result.deny = true
        end
        if any_gate(e.ask, may) then
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
    local ctx = build_exist_ctx(
        parsed.args,
        {},
        false,
        every_scope_takers(arity_of(entries, parsed.cmd_name))
    )
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

-- ── Loading ─────────────────────────────────────────────────────────────────

--- @type agentic.StructuredEntries|nil
local cached_bundled_entries
--- mtime of the bundled file at the last load; nil when that load failed
--- @type number|nil
local cached_bundled_mtime
--- `Config.permissions.use_plugin_defaults` at the last load of the bundled entries
--- @type boolean|nil
local cached_bundled_used

--- @type table|nil, agentic.StructuredEntries
local cached_user_ref, cached_user_entries = nil, {}

--- Merge of the two layers; nil when either changed since the merge.
--- @type agentic.StructuredEntries|nil
local cached_entries

--- Path to bundled permissions.json
--- @return string
local function bundled_permissions_path()
    local mod_path = debug.getinfo(1, "S").source:sub(2)
    local mod_dir = vim.fn.fnamemodify(mod_path, ":h:h")
    return mod_dir .. "/permissions.json"
end

--- Strip leading dashes from a rule option so `"--exec"`, `"-exec"`, and
--- `"exec"` all canonicalise to the dashless candidate-space form. Idempotent.
--- @param s string
--- @return string
local function normalise_option(s)
    return (s:gsub("^%-+", ""))
end

local STRUCTURED_KINDS = { "read_only", "safe_write", "ask", "deny" }

--- Keys a gate may have.
local GATE_KEYS = {
    options = true,
    leading_options = true,
    positionals = true,
    unless = true,
    option_values = true,
}

--- Nesting of `unless` beyond this is a defect, so a cyclic table ends.
local MAX_UNLESS_DEPTH = 8

--- Whether `value` is a list.
--- @param value any
--- @return boolean
local function is_list(value)
    return type(value) == "table" and vim.islist(value)
end

--- Copy of a list of strings.
--- @param value any
--- @return string[]|nil strings nil unless `value` is a list of strings only
local function string_list(value)
    if
        is_list(value)
        and vim.iter(value):all(function(element)
            return type(element) == "string"
        end)
    then
        return vim.list_slice(value)
    end
    return nil
end

--- Copy of an `option_values` condition with dashless options.
--- @param cond any
--- @return agentic.PermOptionValues|nil cond nil unless `options` and
---         `values` are both non-empty lists of strings
local function normalise_option_values(cond)
    if type(cond) ~= "table" then
        return nil
    end
    local options = string_list(cond.options)
    local values = string_list(cond.values)
    if not (options and values and #options > 0 and #values > 0) then
        return nil
    end
    --- @type agentic.PermOptionValues
    local copy =
        { options = vim.tbl_map(normalise_option, options), values = values }
    return copy
end

--- Deep-copy a single gate, normalising every option string (`options`,
--- `leading_options`, `option_values.options`) to the dashless form.
--- Positionals are left raw (glob-compiled at match time).
---
--- A defect is an unknown key, a field of the wrong type, a malformed
--- `option_values`, an `unless` child that is not a table or normalises to
--- `{}`, a defect in an `unless` child, nesting over `MAX_UNLESS_DEPTH`, or
--- `unless`/`option_values` on a deny gate. Lists must be lists, not maps.
--- On a defect, an allow gate is dropped, and an ask or deny gate keeps its
--- valid plain fields but loses a malformed one, `unless` and
--- `option_values`: an absent field matches anything.
--- @param gate any
--- @param kind agentic.PermKind
--- @param depth integer nesting level of `unless`, 1 at the top
--- @return agentic.PermGate|nil gate nil when the gate is dropped
--- @return boolean defect the gate or its `unless` subtree had a defect
local function normalise_gate(gate, kind, depth)
    local is_allow = kind == "read_only" or kind == "safe_write"
    if type(gate) ~= "table" or depth > MAX_UNLESS_DEPTH then
        return not is_allow and {} or nil, true
    end

    local defect = false
    for key in pairs(gate) do
        defect = defect or not GATE_KEYS[key]
    end

    --- @type agentic.PermGate
    local g = {}
    for _, field in ipairs({ "options", "leading_options", "positionals" }) do
        if gate[field] ~= nil then
            local strings = string_list(gate[field])
            defect = defect or strings == nil
            if strings and field ~= "positionals" then
                strings = vim.tbl_map(normalise_option, strings)
            end
            g[field] = strings
        end
    end

    local option_values = normalise_option_values(gate.option_values)
    defect = defect or (gate.option_values ~= nil and option_values == nil)

    --- @type agentic.PermGate[]
    local unless = {}
    if gate.unless ~= nil then
        defect = defect or not is_list(gate.unless)
        for _, child in ipairs(is_list(gate.unless) and gate.unless or {}) do
            local c, child_defect = normalise_gate(child, kind, depth + 1)
            defect = defect or child_defect or c == nil or next(c) == nil
            table.insert(unless, c)
        end
    end

    local conditional = gate.unless ~= nil or gate.option_values ~= nil
    defect = defect or (kind == "deny" and conditional)
    if defect and is_allow then
        return nil, true
    end
    if not defect then
        g.unless = gate.unless ~= nil and unless or nil
        g.option_values = option_values
    end
    return g, defect
end

--- Warn that a gate of `cmd` is malformed.
--- @param cmd string
--- @param kind agentic.PermKind
--- @param kept boolean the gate is kept without its conditions
local function warn_gate_defect(cmd, kind, kept)
    Logger.notify(
        "Structured permission "
            .. kind
            .. " gate of "
            .. cmd
            .. " is malformed; "
            .. (
                kept and "ignoring its unless and option_values"
                or "dropping it"
            ),
        vim.log.levels.WARN,
        { title = "Agentic" }
    )
end

--- Whether `token` is an option token the matcher reads: a short letter
--- `-x` or a long name `--name`.
--- @param token any
--- @return boolean
local function is_arity_token(token)
    return type(token) == "string"
        and (token:match("^%-[^%-%s]$") or token:match("^%-%-[^=%s]+$"))
            ~= nil
end

--- Warn that an arity list element of `cmd` is ignored.
--- @param cmd string
--- @param element any
local function warn_arity_element(cmd, element)
    Logger.notify(
        "Structured permission arity of "
            .. cmd
            .. ": ignoring "
            .. vim.inspect(element)
            .. ', not a list of "-x" or "--name" tokens',
        vim.log.levels.WARN,
        { title = "Agentic" }
    )
end

--- The valid tokens of an arity list, warning about each other element.
--- @param list any
--- @param cmd string command whose entry holds the list, for the warning
--- @return string[]|nil tokens nil when `list` is nil; `{}` when it is not
---         a table
local function arity_tokens(list, cmd)
    if list == nil then
        return nil
    end
    if type(list) ~= "table" then
        warn_arity_element(cmd, list)
        return {}
    end
    local tokens = {}
    for _, element in ipairs(list) do
        if is_arity_token(element) then
            table.insert(tokens, element)
        else
            warn_arity_element(cmd, element)
        end
    end
    return tokens
end

--- Deep-copy an arity table, dropping malformed parts. Tokens stay literal,
--- not dashless: the dashes say whether a token is a short letter or a
--- long name.
--- @param arity any
--- @param cmd string command whose entry holds `arity`, for warnings
--- @return agentic.PermArity|nil arity the string scope keys with a table
---         value, each with the valid tokens of `takers`/`booleans`. nil
---         when `arity` is not a table.
local function normalise_arity(arity, cmd)
    if type(arity) ~= "table" then
        return nil
    end
    --- @type agentic.PermArity
    local out = {}
    for scope, hints in pairs(arity) do
        if type(scope) == "string" and type(hints) == "table" then
            out[scope] = {
                takers = arity_tokens(hints.takers, cmd),
                booleans = arity_tokens(hints.booleans, cmd),
            }
        end
    end
    return out
end

--- Deep-copy a cmd-keyed structured-entries table, normalising every option
--- string to the dashless form. A `vim.NIL` value (the user's "disable a
--- bundled cmd" marker) is preserved so it survives the merge in
--- `get_entries`. `arity` is dropped on `"*"`: an unknown
--- command's arity is unknowable. The output is owned by the caller (safe to
--- mutate) so this caches the normalised view rather than mutating the input.
--- @param entries any
--- @return agentic.StructuredEntries
local function normalise_structured_entries(entries)
    --- @type agentic.StructuredEntries
    local out = {}
    if type(entries) ~= "table" then
        return out
    end
    for cmd, entry in pairs(entries) do
        if type(cmd) == "string" then
            if entry == vim.NIL then
                --- @diagnostic disable-next-line: assign-type-mismatch
                out[cmd] = vim.NIL
            elseif type(entry) == "table" then
                --- @type agentic.StructuredCmdEntry
                local copy = {}
                for _, kind in ipairs(STRUCTURED_KINDS) do
                    local gates = entry[kind]
                    if type(gates) == "table" then
                        local arr = {}
                        for _, gate in ipairs(gates) do
                            local g, defect = normalise_gate(gate, kind, 1)
                            if defect then
                                warn_gate_defect(cmd, kind, g ~= nil)
                            end
                            table.insert(arr, g)
                        end
                        copy[kind] = arr
                    end
                end
                if cmd ~= "*" then
                    copy.arity = normalise_arity(entry.arity, cmd)
                end
                out[cmd] = copy
            end
        end
    end
    return out
end

--- Resolve the merged cmd-keyed structured-entries table from the bundled
--- permissions.json plus any user additions in `Config.permissions.structured`.
--- The two layers merge via `vim.tbl_deep_extend("force", bundled, user)` — a
--- user cmd key wins wholesale (its kind-arrays replace the bundled ones), and
--- a `vim.NIL` value disables the bundled cmd entirely (stripped before return).
--- Re-reads the bundled file when its mtime or `use_plugin_defaults`
--- changes; user additions are recompiled when the table reference changes.
--- The same table is returned until either layer changes.
--- @return agentic.StructuredEntries entries shared with the cache; do not mutate
function M.get_entries()
    local bundled_path = bundled_permissions_path()
    local bundled_mtime = FileSystem.mtime(bundled_path)
    if
        cached_bundled_entries == nil
        or bundled_mtime ~= cached_bundled_mtime
        or Config.permissions.use_plugin_defaults ~= cached_bundled_used
    then
        local data = Config.permissions.use_plugin_defaults
            and FileSystem.read_json_if_present(bundled_path)
        cached_bundled_used = Config.permissions.use_plugin_defaults
        cached_bundled_entries = normalise_structured_entries(data)
        -- A failed read retries on the next call rather than keeping no
        -- bundled rules until the file changes.
        cached_bundled_mtime = (data or not cached_bundled_used)
                and bundled_mtime
            or nil
        cached_entries = nil
    end

    local user_table = Config.permissions.structured
    if user_table ~= cached_user_ref then
        cached_user_ref = user_table
        cached_user_entries = normalise_structured_entries(user_table)
        cached_entries = nil
    end

    if not cached_entries then
        local merged = vim.tbl_deep_extend(
            "force",
            cached_bundled_entries,
            cached_user_entries
        ) or {}
        -- Drop `vim.NIL`-valued entries (the user's disable marker) so the
        -- matcher sees a clean table. decide_leaf also guards against vim.NIL.
        cached_entries = {}
        for cmd, entry in pairs(merged) do
            if entry ~= vim.NIL then
                cached_entries[cmd] = entry
            end
        end
    end
    return cached_entries
end

return M
