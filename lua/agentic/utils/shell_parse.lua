--- Pure structural primitives over the zsh tree-sitter grammar, plus
--- `extract_commands`.
---
--- This is the single home for parse-tree shell decomposition — token
--- extraction, command-name resolution, exec-wrapper / inline-`-c` unwrapping,
--- redirect classification, env-prefix safety, and the node-type sets that
--- decide what counts as safe structure. `permission_rules.lua` requires these
--- (its `walk`/`tally_walk` decide auto-approval on top of them) and
--- `extract_commands` builds the flat command list on the same primitives, so
--- there is exactly one implementation of each.
---
--- No `Config`/runtime requires (only `vim.treesitter` and the pure-Lua
--- `zsh_parse_guard`) so it loads under `nvim -u NONE` with just the plugin on
--- the runtimepath.
---
--- Node-type names are pinned to the installed tree-sitter-zsh grammar (verified
--- 2026-06-18). They can drift across grammar versions — re-verify with a
--- parse-tree dump after upgrading the parser.

local ZshParseGuard = require("agentic.utils.zsh_parse_guard")

local M = {}

-- ── Env-var classification ───────────────────────────────────────────────────

--- Env-var names safe to strip as a leading `VAR=value` assignment.
--- A name is safe only if setting it cannot change which binary runs or
--- inject code into the inner command. Excludes anything that can hijack
--- execution: PATH-likes (PATH, LD_*, DYLD_*), startup files (BASH_ENV,
--- ENV, PYTHONSTARTUP), language module paths (PYTHONPATH, PERL5LIB,
--- RUBYLIB, NODE_PATH), and tool-specific external hooks (GIT_EXTERNAL_*,
--- GIT_PAGER, ...). Keep this list conservative — when in doubt, leave
--- it out and let the command prompt.
local SAFE_ENV_NAMES = {
    PYTHONUNBUFFERED = true,
    PYTHONIOENCODING = true,
    PYTHONHASHSEED = true,
    NODE_NO_WARNINGS = true,
    LANG = true,
    LANGUAGE = true,
    TZ = true,
    TERM = true,
    NO_COLOR = true,
    FORCE_COLOR = true,
    CLICOLOR = true,
    CLICOLOR_FORCE = true,
    COLUMNS = true,
    LINES = true,
    GREP_COLOR = true,
    GREP_COLORS = true,
}

--- @param name string
--- @return boolean
local function is_safe_env_name(name)
    if SAFE_ENV_NAMES[name] then
        return true
    end
    -- LC_ALL, LC_CTYPE, LC_NUMERIC, ... — locale categories, behaviour-only.
    return name:match("^LC_[A-Z_]+$") ~= nil
end

--- Whether a variable name is inert data rather than an execution-influencing
--- env var. The hijacking vars (PATH, LD_PRELOAD, DYLD_INSERT_LIBRARIES, IFS,
--- BASH_ENV, PYTHONPATH) are uppercase by convention, so a name starting with
--- a lowercase letter or underscore cannot be one and is safe to strip or
--- treat as data. A single uppercase letter (`A`..`Z`) is also safe: every
--- execution-hijacking env var in the threat model (PATH, LD_*, DYLD_*, IFS,
--- ENV, BASH_ENV, CDPATH, PYTHON*, ...) is multi-character, so no single
--- letter can hijack.
--- @param name string
--- @return boolean
local function is_inert_var_name(name)
    return name:match("^[a-z_]") ~= nil or name:match("^[A-Z]$") ~= nil
end

-- ── Command-path normalisation ───────────────────────────────────────────────

--- Fixed system binary directories. Restricted to non-arbitrary system
--- locations so an absolute path into a writable directory
--- (`/tmp/evil/grep`) cannot impersonate an allowed command.
local SYSTEM_BIN_DIRS = {
    "/usr/local/bin/",
    "/opt/homebrew/bin/",
    "/usr/bin/",
    "/usr/sbin/",
    "/bin/",
    "/sbin/",
}

--- Strip a leading system binary directory from the command word, so an
--- absolute invocation (`/usr/bin/grep foo`) matches the same allow pattern
--- as the bare command (`grep foo`). Claude routinely uses full paths. Only
--- the directories in `SYSTEM_BIN_DIRS` are stripped. Any other leading path
--- is left intact, so it falls through to a prompt.
--- @param segment string
--- @return string
local function strip_command_path(segment)
    for _, dir in ipairs(SYSTEM_BIN_DIRS) do
        if segment:sub(1, #dir) == dir then
            return segment:sub(#dir + 1)
        end
    end
    return segment
end

-- ── Node-type sets ───────────────────────────────────────────────────────────

--- Container nodes whose every named child must itself pass. `do_group` is
--- dispatched explicitly (it shares the same "every child is a statement"
--- semantics but is only reachable as a loop body). `if_statement`,
--- `elif_clause`, and `else_clause` are containers too: the `condition` child
--- is a `test_command` (substitution-free check, handled in `walk`) or a real
--- statement that walks normally, and every body statement walks. Anonymous
--- keywords/separators (`if`/`then`/`fi`/`;`) carry no field that survives the
--- named-child filter. `case_statement` is dispatched explicitly because its
--- value and its `case_item` patterns must be substitution-checked, not walked.
local CONTAINER_TYPES = {
    program = true,
    list = true,
    pipeline = true,
    variable_assignments = true,
    if_statement = true,
    elif_clause = true,
    else_clause = true,
}

--- Statement types that may appear as the inner content of a
--- `command_substitution` (when reached via assignment value or array
--- element) or as a `do_group` body element. Every other named child
--- inside a substitution bails — e.g. a nested `for_statement` inside
--- `$(...)` is out of scope for Phase 2.
local SUBSTITUTION_INNER_STATEMENT_TYPES = {
    command = true,
    redirected_statement = true,
    pipeline = true,
    list = true,
}

--- Command-substitution node types. An occurrence anywhere in a command subtree
--- launders dangerous tokens past the deny/ask layer (`find $(echo -exec rm)`).
--- Backticks parse as `command_substitution` too.
local SUBSTITUTION_TYPES = {
    command_substitution = true,
    process_substitution = true,
}

--- Node types that make a command NAME dynamic — the matcher cannot tell which
--- binary actually runs, so a dynamic name bails.
local DYNAMIC_NAME_TYPES = {
    command_substitution = true,
    process_substitution = true,
    expansion = true,
    simple_expansion = true,
    variable_ref = true,
    arithmetic_expansion = true,
}

--- Code-taking builtins: the argument is shell code the matcher cannot inspect,
--- so they bail even when the builtin name would match a pattern. Never treated
--- as transparent wrappers.
local CODE_TAKING_BUILTINS = { eval = true, source = true, ["."] = true }

-- ── Structural predicates ────────────────────────────────────────────────────

--- Whether any node in the subtree is a command/process substitution.
--- @param node TSNode
--- @return boolean
local function subtree_has_substitution(node)
    if SUBSTITUTION_TYPES[node:type()] then
        return true
    end
    for child in node:iter_children() do
        if child:named() and subtree_has_substitution(child) then
            return true
        end
    end
    return false
end

--- Whether a `variable_assignment`'s name is safe to ignore as inert data.
--- Uppercase execution hijackers (`PATH`, `LD_PRELOAD`, `BASH_ENV`,
--- `PYTHONPATH`, …) are not — a poisoned var set before a use changes which
--- binary the next command runs.
--- @param va TSNode
--- @param src string
--- @return boolean
local function safe_assignment_name(va, src)
    local name_node = va:field("name")[1]
    if not name_node then
        return false
    end
    local name = vim.treesitter.get_node_text(name_node, src)
    return is_safe_env_name(name) or is_inert_var_name(name)
end

-- ── Token extraction ─────────────────────────────────────────────────────────

--- Quote removal for an unquoted word: `\<newline>` is removed and every other
--- `\x` becomes `x`.
--- @param text string source text of an unquoted word
--- @return string word the word the shell delivers
local function unescape_unquoted(text)
    return (
        text:gsub("\\(.)", function(c)
            return c == "\n" and "" or c
        end)
    )
end

--- Quote removal for the inside of a double-quoted string: `\<newline>` is
--- removed, `\$ \` \" \\` become the escaped character, and any other backslash
--- is kept.
--- @param text string source text between the double quotes
--- @return string word the text the shell delivers
local function unescape_double_quoted(text)
    return (
        text:gsub("\\(.)", function(c)
            if c == "\n" then
                return ""
            end
            if c:match('[$`"\\]') then
                return c
            end
            return "\\" .. c
        end)
    )
end

--- Pattern for the bytes the grammar leaves outside the `string_content`
--- children of a static double-quoted string: the `$` before a closing quote
--- (`"a$"`) and the newline between the lines of a multi-line string.
local STRING_GAP_BYTES = "^[$%s]*$"

--- The text the shell delivers for a double-quoted `string` without
--- expansions.
--- @param node TSNode a `string` whose named children are all `string_content`
--- @param src string
--- @return string|nil text nil when the node is not `"`-delimited, or a byte
---         outside the children is neither `$` nor whitespace (an unknown
---         grammar gap, so fail closed)
local function static_string_text(node, src)
    local _, _, start_byte, _, _, end_byte = node:range(true)
    if
        src:sub(start_byte + 1, start_byte + 1) ~= '"'
        or src:sub(end_byte, end_byte) ~= '"'
    then
        return nil
    end
    local gap_start = start_byte + 1
    for c in node:iter_children() do
        if c:named() then
            local _, _, c_start, _, _, c_end = c:range(true)
            if not src:sub(gap_start + 1, c_start):match(STRING_GAP_BYTES) then
                return nil
            end
            gap_start = c_end
        end
    end
    if not src:sub(gap_start + 1, end_byte - 1):match(STRING_GAP_BYTES) then
        return nil
    end
    -- The source between the quotes, not the joined children: the grammar puts
    -- no child over some delivered bytes (`"a$"`, `"$"`).
    return unescape_double_quoted(src:sub(start_byte + 2, end_byte - 1))
end

--- Whether every named child of a `string` is `string_content` (true for an
--- empty or `"$"` string, which has none).
--- @param node TSNode a `string`
--- @return boolean
local function is_static_string(node)
    for c in node:iter_children() do
        if c:named() and c:type() ~= "string_content" then
            return false
        end
    end
    return true
end

--- Strict literal extraction: every byte of the returned string must be
--- exactly what the shell delivers to the program. Returns nil if any subtree
--- contains a variable expansion or substitution, or a static string's text
--- cannot be read from its source bytes. Used as the recursive step
--- inside `concatenation` — joining `-ex"$x"c` would otherwise launder a
--- dynamic flag past the matcher. `glob_pattern` and `brace_expression` keep
--- their raw text: their backslashes are glob syntax, and the token is dynamic.
--- @param node TSNode
--- @param src string
--- @return string|nil
local function pure_literal_token(node, src)
    local t = node:type()
    if t == "word" then
        return unescape_unquoted(vim.treesitter.get_node_text(node, src))
    end
    if t == "number" or t == "glob_pattern" then
        return vim.treesitter.get_node_text(node, src)
    end
    if t == "string" then
        if not is_static_string(node) then
            return nil
        end
        return static_string_text(node, src)
    end
    if t == "raw_string" then
        local txt = vim.treesitter.get_node_text(node, src)
        return (txt:gsub("^'", ""):gsub("'$", ""))
    end
    if t == "concatenation" then
        if subtree_has_substitution(node) then
            return nil
        end
        local parts = {}
        for c in node:iter_children() do
            if c:named() then
                local part = pure_literal_token(c, src)
                if part == nil then
                    return nil
                end
                table.insert(parts, part)
            end
        end
        return table.concat(parts)
    end
    if t == "brace_expression" then
        if subtree_has_substitution(node) then
            return nil
        end
        return vim.treesitter.get_node_text(node, src)
    end
    -- Variable expansions, substitutions, anything else: not pure.
    return nil
end

--- Extract the token text from one node that appears as a child of a
--- `command` (an argument token) or as the inner of a `command_name`. Returns
--- the joined string, or nil to bail. Lenient for top-level expansion-bearing
--- tokens (`"$f"`, `$bar`) — they're emitted as raw source text, preserving
--- the Phase 1a behaviour where `ls "$f"` matches `Bash(ls *)`. Strict
--- (`pure_literal_token`) inside a concatenation, so an expansion glued into a
--- flag (`-ex"$x"c`) cannot be silently joined to a deny-matching literal.
--- @param node TSNode
--- @param src string
--- @return string|nil
local function literal_token(node, src)
    local t = node:type()
    -- Pure-literal types: delegate to the strict path.
    if
        t == "word"
        or t == "number"
        or t == "glob_pattern"
        or t == "raw_string"
        or t == "brace_expression"
    then
        return pure_literal_token(node, src)
    end
    if t == "string" then
        -- Substitution-bearing strings are caught at the command level. A
        -- string composed only of `string_content` yields its delivered text
        -- (so `"rm"` cannot evade a deny pattern), or nil to bail. A string
        -- that mixes `string_content` with expansions yields the raw quoted
        -- text, preserving Phase 1a glob matching.
        if is_static_string(node) then
            return static_string_text(node, src)
        end
        return vim.treesitter.get_node_text(node, src)
    end
    if t == "concatenation" then
        local pure = pure_literal_token(node, src)
        if pure ~= nil then
            return pure
        end
        -- A concatenation gluing an expansion to literals (`$d/x`) has no pure
        -- form; emit raw text so it splices as one token (flagged dynamic by
        -- token_is_dynamic). A command-substitution part is rejected upstream.
        if subtree_has_substitution(node) then
            return nil
        end
        return vim.treesitter.get_node_text(node, src)
    end
    if DYNAMIC_NAME_TYPES[t] then
        -- A bare expansion as an arg (`ls $f`) — emit raw source text so the
        -- glob layer still sees the original token (`$f`). The structured
        -- matcher's `extract_option_candidates` will not produce option
        -- candidates from a `$`-prefixed token. Substitution is already
        -- rejected at the command level.
        if t == "command_substitution" or t == "process_substitution" then
            return nil
        end
        return vim.treesitter.get_node_text(node, src)
    end
    -- Anything else (heredoc bodies, redirects, unknown future node types):
    -- fail-closed.
    return nil
end

--- Whether an argument token expands at runtime to a value the matcher cannot
--- see — a variable/arithmetic expansion, an unquoted glob, or a quoted string
--- carrying an expansion. Pure literals (`word`, `number`, `raw_string`, an
--- all-`string_content` string, a literal `concatenation`, `brace_expression`)
--- are static. A `~`-prefixed path is a plain `word` in this grammar and
--- expands only to a path (never a flag or subcommand), so it stays static.
--- A `concatenation` bearing an expansion/glob part (`$d/x`, `$d/*.js`) is
--- dynamic: `literal_token` now emits its raw text, so the same post-expansion
--- word-split surface as a bare `$d` must wildcard the deny/ask gates.
--- Command-substitution-bearing nodes (rejected at the command level) never
--- reach here.
---
--- `arith_static` (default false) treats an arithmetic expansion (`$((40))`) as
--- a static numeric token instead of dynamic. Arithmetic output is always an
--- integer — it can never expand to a flag, subcommand, or path — so dropping
--- its deny/ask wildcard only removes a prompt. Arithmetic that reads a value
--- fails `parse_zsh`, so it never reaches here. Only the argument site passes
--- true; a redirect target needs the literal path, which the token's raw text
--- is not.
--- @param node TSNode
--- @param arith_static boolean|nil
--- @return boolean
local function token_is_dynamic(node, arith_static)
    local t = node:type()
    if t == "arithmetic_expansion" then
        return not arith_static
    end
    if
        t == "glob_pattern"
        or t == "variable_ref"
        or t == "simple_expansion"
        or t == "expansion"
    then
        return true
    end
    if t == "string" then
        -- Fail-closed whitelist: dynamic unless EVERY named child is provably
        -- static. tree-sitter-zsh double-quote-string children are:
        -- string_content, simple_expansion ($x), expansion (${x}),
        -- command_substitution ($(…)), arithmetic_expansion ($((…))). Only
        -- string_content — and arithmetic under the gate — is static; any other
        -- child (incl. an unforeseen future node type) stays dynamic, so a
        -- grammar bump that adds a child type fails safe (over-prompt).
        for c in node:iter_children() do
            if c:named() then
                local ct = c:type()
                local child_static = ct == "string_content"
                    or (ct == "arithmetic_expansion" and arith_static)
                if not child_static then
                    return true
                end
            end
        end
    end
    if t == "concatenation" then
        -- Recurse: an expansion may be a direct child (`$d/x`) or nested inside a
        -- `string`/`concatenation` child (`-ex"$x"c`), which the branches above
        -- already detect. Any dynamic part makes the whole token dynamic. Do NOT
        -- flatten this into a direct-child type check: `-ex"$x"c` hides its `$x`
        -- inside a `string` child, so a flat check reports static and the raw
        -- token approves past a deny gate — unsound (regression-tested).
        for c in node:iter_children() do
            if c:named() and token_is_dynamic(c, arith_static) then
                return true
            end
        end
    end
    return false
end

--- Extract the literal command name from a `command_name` node, normalising
--- quotes so `"rm"` and `'rm'` resolve to `rm` (a quoted name must not evade a
--- deny pattern). Returns nil to bail on a dynamic name — a substitution,
--- expansion, arithmetic, or an interpolated `concatenation`. A literal
--- concatenation in command-name position (e.g. `gr"e"p`) joins to its
--- concatenated text via `literal_token`.
--- @param command_name TSNode
--- @param src string
--- @return string|nil
local function command_name_text(command_name, src)
    local inner = command_name:named_child(0)
    if not inner then
        return nil
    end
    -- A dynamic name bails. `literal_token` hands back raw `$VAR` text for a
    -- bare expansion; the permission walk tolerates that (a `$VAR` leaf matches
    -- no allow pattern → prompt) but `extract_commands` does not — a
    -- `$VAR`-named record matches no block rule, a silent miss. So drop it here
    -- and both consumers get nil. ponytail: lazy bail, not var propagation.
    if DYNAMIC_NAME_TYPES[inner:type()] then
        return nil
    end
    return literal_token(inner, src)
end

-- ── Redirects ────────────────────────────────────────────────────────────────

--- Whether a `file_redirect` is a safe form: an input redirect (`<file` —
--- a pure read, never writes/truncates; the read-write `<>` form parses to an
--- ERROR node and is rejected fail-closed upstream), a write to /dev/null, or a
--- file descriptor duplication (`2>&1`, `>&2`, `N>&M`). Every other target is a
--- file write (or an unmodelled redirect) and bails. A substitution in the
--- target (`cat > $(echo out)`, `wc <$(f)`) bails first.
--- @param fr TSNode
--- @param src string
--- @return boolean
local function redirect_is_safe(fr, src)
    local op, dest
    for child, field in fr:iter_children() do
        if field == "destination" then
            dest = child
        elseif not child:named() then
            op = child:type()
        end
    end
    if not dest or subtree_has_substitution(dest) then
        return false
    end
    if op == ">&" or op == "<&" then
        local dt = dest:type()
        return dt == "file_descriptor" or dt == "number"
    end
    if op == "<" then
        return true
    end
    return vim.treesitter.get_node_text(dest, src) == "/dev/null"
end

--- The destination node of a write redirect that `redirect_is_safe` rejects, or
--- nil when there is nothing to pin a write to. nil means "not a pinnable write
--- target" — the caller bails (falls through to a prompt). A returned node is the
--- destination the redirect would truncate/append to; the caller resolves it to a
--- concrete literal path (quote-strip + `known`-var resolution, which live in
--- permission_rules) and surfaces a `write` effect so the policy layer can clear
--- it against a trust scope (see permission_manager's `_bash_effects_clear`).
---
--- Returns nil for the forms `redirect_is_safe` already approves (input `<`, fd
--- duplication, `/dev/null`) and for a command/process-substitution destination
--- (`> $(echo f)`). A bare or quoted literal, or a variable target, is returned
--- as a node for the caller to resolve.
--- @param fr TSNode
--- @param src string
--- @return TSNode|nil
local function redirect_write_dest(fr, src)
    local op, dest
    for child, field in fr:iter_children() do
        if field == "destination" then
            dest = child
        elseif not child:named() then
            op = child:type()
        end
    end
    if not dest or subtree_has_substitution(dest) then
        return nil
    end
    if op == "<" then
        return nil
    end
    local dt = dest:type()
    if
        (op == ">&" or op == "<&")
        and (dt == "file_descriptor" or dt == "number")
    then
        return nil
    end
    if vim.treesitter.get_node_text(dest, src) == "/dev/null" then
        return nil
    end
    return dest
end

--- True iff the redirect operator is a plain truncating `>` (not `>>` append,
--- `&>`, `>|`, or an input/fd form). Heredoc content reconstruction needs a full
--- truncate — only then does the written file equal the heredoc body, with no
--- prior bytes prepended/appended.
--- @param fr TSNode file_redirect node
--- @return boolean
local function redirect_is_truncate(fr)
    for child in fr:iter_children() do
        if not child:named() then
            return child:type() == ">"
        end
    end
    return false
end

--- @class agentic.utils.ShellParse.Heredoc
--- @field text string the body as written, expansions unexpanded
--- @field dynamic boolean the body contains an expansion

--- The body of a `heredoc_redirect`.
--- @param hr TSNode heredoc_redirect node
--- @param src string
--- @return agentic.utils.ShellParse.Heredoc heredoc
local function heredoc_text(hr, src)
    local body, delimiter
    for child in hr:iter_children() do
        if child:type() == "heredoc_body" then
            body = child
        elseif child:type() == "heredoc_end" then
            delimiter = child
        end
    end
    if not body or not delimiter then
        return { text = "", dynamic = false }
    end
    local _, _, body_start = body:start()
    local _, _, delimiter_start = delimiter:start()
    -- Up to the delimiter, not the `heredoc_body` end: the node omits the final
    -- newline when the body ends in an expansion.
    return {
        text = src:sub(body_start + 1, delimiter_start),
        dynamic = body:named_child_count() > 0,
    }
end

--- The verbatim text of a `heredoc_redirect`'s body, or nil if the body carries
--- an expansion (`<<EOF` with `$var`/`$(…)`), which the shell runs at *write*
--- time and must therefore bail. A quoted `<<'EOF'` always parses as pure text
--- (no named children). An empty body → "".
--- @param hr TSNode heredoc_redirect node
--- @param src string
--- @return string|nil
local function heredoc_pure_body(hr, src)
    local heredoc = heredoc_text(hr, src)
    if heredoc.dynamic then
        return nil
    end
    return heredoc.text
end

--- True iff the command node is exactly `cat` with no arguments or env-prefix —
--- the only form whose stdout equals its heredoc stdin verbatim. Any operand
--- (`cat -n`), filter (`grep x`), or other command transforms the bytes, so the
--- written file would not equal the heredoc body.
--- @param cmd TSNode|nil command node (the redirected_statement body)
--- @param src string
--- @return boolean
local function is_bare_cat(cmd, src)
    if not cmd or cmd:type() ~= "command" or cmd:named_child_count() ~= 1 then
        return false
    end
    local name_node = cmd:field("name")[1]
    if not name_node then
        return false
    end
    return vim.fs.basename(vim.treesitter.get_node_text(name_node, src))
        == "cat"
end

-- ── Parsing ──────────────────────────────────────────────────────────────────

local BACKSLASH = ("\\"):byte()
local BACKTICK = ("`"):byte()

--- 0-based `[start, end)` byte ranges of every node in the tree that satisfies
--- `pred`, in document order.
--- @param root TSNode
--- @param pred fun(node: TSNode): boolean
--- @return [integer, integer][] ranges
local function node_ranges(root, pred)
    local ranges = {}
    local function visit(node)
        if pred(node) then
            local _, _, start_byte, _, _, end_byte = node:range(true)
            table.insert(ranges, { start_byte, end_byte })
        end
        for child in node:iter_children() do
            visit(child)
        end
    end
    visit(root)
    return ranges
end

--- Membership test for the union of `ranges`, answered in amortised O(1) by a
--- cursor that only moves forward.
--- @param ranges [integer, integer][] 0-based `[start, end)` byte ranges, sorted
--- by start
--- @return fun(i: integer): boolean covers true iff 0-based offset `i` lies in
--- the union; successive calls must pass non-decreasing `i`
local function ascending_cover(ranges)
    local merged = {}
    for _, r in ipairs(ranges) do
        local last = merged[#merged]
        if last and r[1] <= last[2] then
            last[2] = math.max(last[2], r[2])
        else
            table.insert(merged, { r[1], r[2] })
        end
    end
    local k = 1
    return function(i)
        while merged[k] and merged[k][2] <= i do
            k = k + 1
        end
        return merged[k] ~= nil and i >= merged[k][1]
    end
end

--- True iff the byte at 0-based offset `i` is escaped: preceded by an odd run
--- of backslashes.
--- @param src string
--- @param i integer
--- @return boolean
local function is_escaped(src, i)
    local n_backslashes = 0
    while i - n_backslashes > 0 and src:byte(i - n_backslashes) == BACKSLASH do
        n_backslashes = n_backslashes + 1
    end
    return n_backslashes % 2 == 1
end

--- True iff a `heredoc_body` node's delimiter is quoted (`<<'EOF'`, `<<"EOF"`,
--- `<<\EOF`). zsh treats any quoting of the delimiter as making the body
--- literal.
--- @param body TSNode heredoc_body node
--- @param src string
--- @return boolean
local function heredoc_is_literal(body, src)
    for child in assert(body:parent()):iter_children() do
        if child:type() == "heredoc_start" then
            return vim.treesitter.get_node_text(child, src):find("['\"\\]")
                ~= nil
        end
    end
    return false
end

--- Byte ranges where zsh neither runs a backtick substitution nor joins a
--- backslash-newline: single-quoted and `$'…'` strings, comments, and
--- quoted-delimiter heredoc bodies.
--- @param root TSNode
--- @param src string
--- @return [integer, integer][] ranges 0-based `[start, end)` byte ranges
local function literal_ranges(root, src)
    return node_ranges(root, function(node)
        local t = node:type()
        return t == "raw_string"
            or t == "ansi_c_string"
            or t == "comment"
            or (t == "heredoc_body" and heredoc_is_literal(node, src))
    end)
end

--- True iff a backtick in `src` is neither a `command_substitution` delimiter
--- nor literal text, i.e. a substitution zsh runs that has no node in the tree.
--- Any other backtick inside a backtick body counts, even in quotes or a
--- comment: zsh ends the body at the first unescaped one, and the grammar emits
--- no node for an escaped (nested) one.
--- @param root TSNode
--- @param src string
--- @param literal [integer, integer][] 0-based `[start, end)` byte ranges where
--- a backtick is literal text, sorted by start
--- @return boolean
local function hides_backtick_substitution(root, src, literal)
    if not src:find("`", 1, true) then
        return false
    end
    local substitutions = node_ranges(root, function(node)
        return node:type() == "command_substitution"
    end)
    local delimiters = {}
    local bodies = {}
    for _, r in ipairs(substitutions) do
        if src:byte(r[1] + 1) == BACKTICK then
            delimiters[r[1]] = true
            delimiters[r[2] - 1] = true
            table.insert(bodies, { r[1] + 1, r[2] - 1 })
        end
    end
    local in_body = ascending_cover(bodies)
    local in_literal = ascending_cover(literal)
    local i = src:find("`", 1, true)
    while i do
        local offset = i - 1
        if in_body(offset) then
            return true
        end
        if
            not delimiters[offset]
            and not in_literal(offset)
            and not is_escaped(src, offset)
        then
            return true
        end
        i = src:find("`", i + 1, true)
    end
    return false
end

--- True iff an unescaped, unquoted backslash-newline directly follows a word
--- byte (anything but a blank or `|`, `&`, `;`). zsh removes the pair before
--- splitting words, so `a\<newline>b` is the word `ab` and `a\<newline>  b`
--- continues the command. The grammar ends the command at the newline in both.
--- @param root TSNode
--- @param src string
--- @param literal [integer, integer][] 0-based `[start, end)` byte ranges where
--- a backslash-newline is literal text, sorted by start
--- @return boolean
local function continues_inside_word(root, src, literal)
    if not src:find("\\\n", 1, true) then
        return false
    end
    local in_literal = ascending_cover(literal)
    local in_quoted = ascending_cover(node_ranges(root, function(node)
        local t = node:type()
        return t == "string_content" or t == "heredoc_body"
    end))
    local i = src:find("\\\n", 1, true)
    while i do
        local offset = i - 1
        if
            offset > 0
            and not src:sub(i - 1, i - 1):match("[%s|&;]")
            and not is_escaped(src, offset)
            and not in_literal(offset)
            and not in_quoted(offset)
        then
            return true
        end
        i = src:find("\\\n", i + 1, true)
    end
    return false
end

--- True iff arithmetic `text` may read a variable: it has a letter or a `$`
--- other than `$#`, `$?`, `$$` and `$!`. zsh evaluates the variable's value as
--- arithmetic too, and a subscript in that value runs its command
--- substitutions.
--- @param text string
--- @return boolean
local function reads_value(text)
    return (text:gsub("%$[#?$!]", "")):find("[%a$]") ~= nil
end

--- True iff the text of `node` matches any of the Lua `patterns`.
--- @param node TSNode
--- @param src string
--- @param patterns string[]
--- @return boolean
local function text_finds(node, src, patterns)
    local text = vim.treesitter.get_node_text(node, src)
    for _, pattern in ipairs(patterns) do
        if text:find(pattern) then
            return true
        end
    end
    return false
end

--- True iff a subscript of `node` (the text between its anonymous `[` and `]`
--- children) reads a value. Subscripts are arithmetic.
--- @param node TSNode
--- @param src string
--- @return boolean
local function subscript_reads_value(node, src)
    local open
    for child in node:iter_children() do
        if child:type() == "[" and not child:named() then
            local _, _, start_byte = child:start()
            open = start_byte + child:byte_length()
        elseif child:type() == "]" and not child:named() and open then
            local _, _, close = child:start()
            if reads_value(src:sub(open + 1, close)) then
                return true
            end
            open = nil
        end
    end
    return false
end

--- `[[ … ]]` operators whose operands zsh evaluates as arithmetic.
local ARITHMETIC_TEST_OPERATORS =
    { ["-eq"] = true, ["-ne"] = true, ["-lt"] = true, ["-le"] = true, ["-gt"] = true, ["-ge"] = true }

--- True iff `node` is a `[[ … ]]` arithmetic comparison with an operand that
--- reads a value. `[ … ]` and `test` compare without arithmetic.
--- @param node TSNode
--- @param src string
--- @return boolean
local function comparison_reads_value(node, src)
    local test = node:parent()
    while test and test:type() ~= "test_command" do
        test = test:parent()
    end
    if not (test and test:child(0):type() == "[[") then
        return false
    end
    local arithmetic, reads = false, false
    for child in node:iter_children() do
        local text = vim.treesitter.get_node_text(child, src)
        if child:type() == "test_operator" then
            arithmetic = ARITHMETIC_TEST_OPERATORS[text] == true
        elseif child:named() and reads_value(text) then
            reads = true
        end
    end
    return arithmetic and reads
end

--- Per node type, the test for syntax that makes zsh run code while it expands
--- a word (zshexpn(1) § Parameter Expansion Flags, § Glob Qualifiers). Flag and
--- qualifier patterns match the whole text, arguments included, so a delimiter
--- character can only add a false positive, never hide a flag.
--- @type table<string, fun(node: TSNode, src: string): boolean>
local CODE_RUNNING_SYNTAX = {
    -- `e` re-expands the value, `P` reads it as a parameter name (whose
    -- subscript runs substitutions), `#`/`l`/`r`/`I` evaluate arithmetic, and
    -- `%` prompt-expands, which runs substitutions under PROMPT_SUBST.
    expansion_flags = function(node, src)
        return text_finds(node, src, { "[ePlrI#%%]" })
    end,
    -- `+cmd`, `e…` and `oe…` run code, `[…]` evaluates arithmetic, and zsh
    -- substitutes a `$` or backtick in an argument (`P:…:`, `:s/…/…/`).
    zsh_glob_qualifier = function(node, src)
        return text_finds(node, src, { "[e%[%$`]", "%+[%a_]" })
    end,
    -- `~` (GLOB_SUBST) applies glob qualifiers in the value, code-running ones
    -- included.
    expansion_style = function(node, src)
        return text_finds(node, src, { "~" })
    end,
    arithmetic_expansion = function(node, src)
        return reads_value(vim.treesitter.get_node_text(node, src):sub(2))
    end,
    expansion_substring = function(node, src)
        for _, field in ipairs({ "offset", "length" }) do
            local part = node:field(field)[1]
            if part and reads_value(vim.treesitter.get_node_text(part, src)) then
                return true
            end
        end
        return false
    end,
    -- An element's `[key]=` index; the grammar parses it as a glob.
    array = function(node, src)
        for child in node:iter_children() do
            local key = vim.treesitter.get_node_text(child, src):match("^%[(.-)%]=")
            if key and reads_value(key) then
                return true
            end
        end
        return false
    end,
    binary_expression = comparison_reads_value,
}

--- True iff the tree runs code while it expands a word: a node that fails its
--- `CODE_RUNNING_SYNTAX` test, or a subscript that reads a value.
--- @param root TSNode
--- @param src string
--- @return boolean
local function runs_code_on_expansion(root, src)
    local matches = node_ranges(root, function(node)
        local t = node:type()
        local test = CODE_RUNNING_SYNTAX[t]
        if test and test(node, src) then
            return true
        end
        return (t == "subscript" or t == "variable_ref" or t:find("^expansion") ~= nil)
            and subscript_reads_value(node, src)
    end)
    return #matches > 0
end

--- Builtins that evaluate each argument as arithmetic.
local ARITHMETIC_ARG_BUILTINS = {
    shift = true,
    ["return"] = true,
    exit = true,
    logout = true,
    ["break"] = true,
    continue = true,
}

--- True iff any of `args` from index `first` on reads a value.
--- @param args string[]
--- @param first integer
--- @return boolean
local function any_reads_value(args, first)
    for i = first, #args do
        if reads_value(args[i]) then
            return true
        end
    end
    return false
end

--- True iff the subscript of parameter name `name` reads a value.
--- @param name string
--- @return boolean
local function index_reads_value(name)
    local index = name:match("%[(.*)%]")
    return index ~= nil and reads_value(index)
end

--- True iff `format` makes printf evaluate an argument as arithmetic: it has a
--- `$` (an expansion, or a positional `%1$d`), or a directive other than `%s`,
--- `%b`, `%c` or `%q` with a digit-only width and precision.
--- @param format string
--- @return boolean
local function format_takes_arithmetic(format)
    format = format:gsub("%%%%", "")
    if format:find("%$") then
        return true
    end
    for spec, conversion in format:gmatch("%%([^%a]*)(%a?)") do
        if spec:find("%*") or not conversion:find("^[sbcq]$") then
            return true
        end
    end
    return false
end

--- True iff an argument that `cmd_name` evaluates as arithmetic reads a value
--- (see `reads_value`). Checks every argument of `ARITHMETIC_ARG_BUILTINS`
--- (`shift`, `return`, `exit`, `logout`, `break`, `continue`); for `printf`
--- and `print`, the subscript of a `-v` target name and the arguments after a
--- format that takes arithmetic. `print` options are found in every word,
--- attached values included, so an unmodelled option can only add a check.
--- @param cmd_name string
--- @param args string[] delivered words, dynamic ones as raw text
--- @return boolean
local function arithmetic_args_read_value(cmd_name, args)
    if ARITHMETIC_ARG_BUILTINS[cmd_name] then
        return any_reads_value(args, 1)
    end
    if cmd_name == "printf" then
        local i = 1
        while args[i] and args[i]:match("^%-v") do
            local name = args[i]:sub(3)
            if name == "" then
                i = i + 1
                name = args[i] or ""
            end
            if index_reads_value(name) then
                return true
            end
            i = i + 1
        end
        if args[i] == "--" then
            i = i + 1
        end
        return args[i] ~= nil
            and format_takes_arithmetic(args[i])
            and any_reads_value(args, i + 1)
    end
    if cmd_name ~= "print" then
        return false
    end
    for i, arg in ipairs(args) do
        local name = arg:match("^%-%a-v(.*)$")
        if name and index_reads_value(name ~= "" and name or args[i + 1] or "") then
            return true
        end
        local format = arg:match("^%-%a-f(.*)$")
        if format then
            local i_format = format == "" and i + 1 or i
            format = format ~= "" and format or args[i + 1]
            if
                format
                and format_takes_arithmetic(format)
                and any_reads_value(args, i_format + 1)
            then
                return true
            end
        end
    end
    return false
end

--- Parse a command string with the zsh grammar. Returns the root node, or nil
--- (fail-closed) on missing parser, parse error, any error node, syntax the
--- grammar parses differently from zsh (a hidden backtick substitution, a line
--- continuation inside a word), or a word expansion or arithmetic that can run
--- code.
---
--- Bails before parsing on the tree-sitter-zsh hang trigger (see
--- `zsh_parse_guard`): `parse()` would never return and no in-process mechanism
--- can interrupt it, so a nil here (fail-closed → prompt) is the only safe
--- outcome. Untrusted file bodies get an additional out-of-process guard — see
--- `parse_zsh_untrusted`.
--- @param src string
--- @return TSNode|nil
local function parse_zsh(src)
    if ZshParseGuard.contains_hang_trigger(src) then
        return nil
    end
    local ok, root = pcall(function()
        local parser = vim.treesitter.get_string_parser(src, "zsh")
        return parser:parse(false)[1]:root()
    end)
    if not ok or not root or root:has_error() then
        return nil
    end
    if src:find("[`\\]") then
        local literal = literal_ranges(root, src)
        if
            hides_backtick_substitution(root, src, literal)
            or continues_inside_word(root, src, literal)
        then
            return nil
        end
    end
    if runs_code_on_expansion(root, src) then
        return nil
    end
    return root
end

--- Absolute path to the headless parse-termination oracle script (sibling file).
local ORACLE_SCRIPT = vim.fn.fnamemodify(
    debug.getinfo(1, "S").source:sub(2),
    ":h"
) .. "/zsh_parse_oracle.lua"

--- Upper bound on a legitimate parse of a 64 KB body. A terminating parse is
--- ~100 ms; this only bounds how long the editor blocks before SIGKILLing a
--- genuinely-hung grammar.
local ORACLE_TIMEOUT_MS = 5000

--- Whether the zsh grammar terminates when parsing `body`, proven by parsing it
--- in a killable subprocess. Returns false on timeout (the hang), spawn/parse
--- failure, or a missing parser — all fail-closed for the caller.
---
--- Re-entrancy: `SystemObj:wait` polls with `vim.wait(…, fast_only=true)`, which
--- DOES run libuv callbacks — the ACP transport's `uv` `read_start` fires and
--- parses provider bytes during this wait — but does NOT dispatch neovim's
--- deferred queue (`vim.schedule`, autocmds). Every state-mutating ACP handler
--- (`session/update`, `session/request_permission`) is `vim.schedule`-deferred
--- (see `acp_client`), so it runs only after this returns, never re-entering the
--- in-flight permission walk. The synchronous read-callback work is inert here
--- (byte accumulation + JSON decode + enqueue).
--- @param body string
--- @return boolean
local function oracle_terminates(body)
    local parser_so = vim.api.nvim_get_runtime_file("parser/zsh.so", false)[1]
    if not parser_so then
        return false
    end
    local done = vim.system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-l",
        ORACLE_SCRIPT,
        parser_so,
    }, { stdin = body }):wait(ORACLE_TIMEOUT_MS)
    return done.code == 0 and done.signal == 0
end

--- Parse an untrusted file body (a sourced/executed script read from disk) with
--- a subprocess termination guard on top of `parse_zsh`. The known hang trigger
--- is rejected cheaply in-process; any *other* non-terminating grammar bug is
--- caught by proving termination in a killable subprocess first, because a C
--- parse loop cannot be interrupted in-process (see notes/bug-zsh-parser-hang.md
--- § 4). Timeout / spawn failure / missing parser fail closed (nil → the walk
--- prompts). Once termination is proven the body is parsed in-process to return
--- the walkable tree.
--- @param body string
--- @return TSNode|nil
function M.parse_zsh_untrusted(body)
    if ZshParseGuard.contains_hang_trigger(body) then
        return nil
    end
    if not oracle_terminates(body) then
        return nil
    end
    return parse_zsh(body)
end

-- ── Transparent prefixes (exec-wrappers, inline `-c`) ────────────────────────

--- Shell command names whose `-c <body>` runs an inline script. When the body
--- is a pure literal it is already present verbatim in `rawInput.command` (no
--- file read, no TOCTOU window), so it is re-parsed and walked recursively
--- instead of firing the unconditional `c`-flag ask.
local SHELL_C_COMMANDS = { zsh = true, bash = true, sh = true, dash = true }

--- Recursion-depth cap for nested transparent prefixes — inline `-c` bodies
--- (`zsh -c 'zsh -c "…"'`) and exec-wrappers (`stdbuf -oL timeout 5 grep foo`). It is
--- NOT a termination guard: each recursion operates on a strict substring of its
--- parent (the prefix is always removed), so source length decreases and the
--- recursion terminates with or without a cap. It exists for two other reasons:
--- a cheap O(1) bound against a crafted deeply-nested command whose per-level
--- re-parse is ~O(N²) over the 64 KB length cap (a multi-second freeze), and a
--- policy bound — benign commands nest prefixes 1–2 deep, so a deeper chain
--- correctly falls through to a prompt. A command at the cap stops recursing.
local NESTED_MAX_DEPTH = 3

--- Whether `s` matches any of the Lua patterns in `patterns`.
--- @param s string
--- @param patterns string[]
--- @return boolean
local function matches_any_lua_pattern(s, patterns)
    return vim.tbl_contains(patterns, function(p)
        return s:match(p) ~= nil
    end, { predicate = true })
end

--- Per-wrapper operand grammar, read by the shared engine
--- (`skip_wrapper_operands`). A table rather than per-wrapper skip functions
--- because the three share one getopt skeleton (value/flag/attached) — the
--- soundness-critical "bail on unrecognised option" logic is then audited once
--- in the engine instead of re-verified per wrapper. Option forms a token can
--- take, in the order the engine tries them:
--- @class agentic.utils.ShellParse.WrapperSpec
--- @field value_opts? string[] options whose value is the next token (`-s KILL`)
--- @field flag_opts? string[] boolean options (consume themselves only)
--- @field attached? string[] Lua patterns for self-contained forms — attached short value (`-oL`), `--long=value`, bare numeric (`-5`)
--- @field positionals? integer count of fixed positional operands before the inner command (timeout's `DURATION` = 1); skipped by count, not inspected
--- @field subcommand? string require this literal first positional (uv's `run`); options are consumed both before and after it, and a non-match falls through to the leaf matchers (so `uv pip`/`uv lock` keep their own allow rules)
--- @field writes? boolean the wrapper itself has a recoverable side effect of its own (uv's env sync may install). Reported back from `inner_source` so the decision walk gates recursion to the allow/safe_write tier — a read-only inner must not launder the command into a read-only one.

--- Exec-wrappers: effect-neutral prefixes whose sole job is to launch the
--- following command. Excluding a write option / requiring a positional makes
--- the inner slice misparse fail-closed rather than expose a dangerous inner.
---
--- Transparency is a per-wrapper property, not a category — recursing into any
--- launcher is unsound. Other launchers are deliberately NOT here: `env` and
--- `nohup` can set an execution-hijacking var (`PATH`, `LD_PRELOAD`) or write
--- `nohup.out`; `command`/`builtin`/`exec` alter `PATH`/the shell process;
--- `parallel` runs a command per input (its own `{}` DSL, remote exec via
--- `--sshlogin`). It is left to match no allow rule (so it prompts) rather than
--- recursed — and must NOT be given a blanket read-only entry in `permissions.json`,
--- which would auto-approve whatever it launches without the matcher inspecting it.
---
--- `xargs COMMAND` recurses like `timeout`, with one difference: xargs appends
--- stdin items to COMMAND at runtime, so `inner_source` appends a trailing dynamic
--- token (`$__xargs_stdin`) modelling them. It wildcards deny/ask and never widens
--- allow, so a gated inner (`xargs sort` → `-o`) prompts while read-only inners
--- still approve.
---
--- `uv run COMMAND` is included because a *bare* `uv run` adds no arbitrary-code
--- danger over running COMMAND directly — COMMAND is then judged on its own allow
--- rules. It is not effect-neutral like timeout/stdbuf, though: it first syncs the
--- project env, which may install the repo's already-declared deps. That sync is a
--- recoverable write, so `writes = true` marks it `safe_write`-tier — the decision
--- walk only recurses at the allow tier, never laundering a read-only inner into a
--- read-only command. Transparency is further gated to the bare form: the empty
--- option lists make `skip_wrapper_operands` bail on *any* dash token, so the
--- code-injecting options (`--with PKG`, `-s`/`--script`, `--with-requirements`,
--- which fetch arbitrary packages from the open PyPI index) bail to a prompt.
--- `uvx`/`uv tool run` are excluded outright: they fetch an arbitrary package.
--- @type table<string, agentic.utils.ShellParse.WrapperSpec>
local EXEC_WRAPPERS = {
    -- [OPTION]... DURATION COMMAND
    timeout = {
        value_opts = { "-s", "--signal", "-k", "--kill-after" },
        flag_opts = { "--preserve-status", "--foreground", "-v", "--verbose" },
        attached = { "^%-%-signal=", "^%-%-kill%-after=" },
        positionals = 1, -- DURATION; a malformed one fails when run, harmless
    },
    -- [-p] only — any write option (-o/--output/-a/-f) bails (soundness §4)
    time = { flag_opts = { "-p" } },
    -- (-i/-o/-e MODE | --input/--output/--error=MODE)... — none write
    stdbuf = {
        value_opts = { "-i", "-o", "-e", "--input", "--output", "--error" },
        attached = {
            "^%-[ioe].",
            "^%-%-input=",
            "^%-%-output=",
            "^%-%-error=",
        },
    },
    -- run COMMAND — bare only (no option lists → any dash token bails); env
    -- sync is a recoverable write, so it needs the allow tier (`writes`).
    uv = { subcommand = "run", writes = true },
    -- [OPTION]... COMMAND [ARGS]... — inner classified on its own merits; the
    -- runtime stdin items are modelled by a dynamic token appended in
    -- `inner_source`. Common flags only; mis-slice fails closed (see docstring).
    xargs = {
        value_opts = {
            "-I",
            "-n",
            "-P",
            "-a",
            "-L",
            "--arg-file",
            "--replace",
            "--max-args",
            "--max-procs",
            "--max-lines",
        },
        flag_opts = {
            "-0",
            "-r",
            "-t",
            "--null",
            "--no-run-if-empty",
            "--verbose",
        },
        attached = {
            "^%-I",
            "^%-i",
            "^%-n%d",
            "^%-P%d",
            "^%-L%d",
            "^%-%-arg%-file=",
            "^%-%-replace=",
            "^%-%-max%-args=",
            "^%-%-max%-procs=",
            "^%-%-max%-lines=",
        },
    },
}

--- `EXEC_WRAPPERS` for reporting what runs rather than deciding approval: `uv
--- run` also skips its code-injecting options (`--with`, `--python`, ...),
--- which change the environment but not which command runs. `--script`/`-s`
--- and `--directory` still stop the skip.
--- @type table<string, agentic.utils.ShellParse.WrapperSpec>
local VISIBLE_WRAPPERS = vim.tbl_extend("force", EXEC_WRAPPERS, {
    uv = vim.tbl_extend("force", EXEC_WRAPPERS.uv, {
        value_opts = {
            "--with",
            "-w",
            "--with-requirements",
            "--with-editable",
            "--python",
            "-p",
            "--project",
        },
        flag_opts = {
            "--no-project",
            "--quiet",
            "-q",
            "--no-sync",
            "--frozen",
            "--locked",
            "--offline",
            "--isolated",
        },
        attached = {
            "^%-%-with=",
            "^%-%-python=",
            "^%-%-project=",
            "^%-%-with%-requirements=",
            "^%-%-with%-editable=",
        },
    }),
})

--- Consume an exec-wrapper's own operands per its spec and return the 1-based
--- index into `args` where the inner command begins, or nil to bail.
---
--- Soundness rests on bailing on any unrecognised option: an unknown option
--- might consume a value we don't know to skip, mis-slicing the inner. The
--- `positionals` operands (timeout's DURATION) are skipped by count, never
--- inspected — validating their shape would be checking command correctness,
--- which is not our job. A malformed command fails when run (harmless), and any
--- mis-slice yields a non-matching/unparseable inner → prompt, never a dangerous
--- inner reconstructed as allowed. A dynamic operand (`timeout $D …`) is consumed
--- positionally; the inner is re-parsed, so a dynamic inner name still bails.
--- @param args string[] quote-stripped arg tokens after the wrapper name
--- @param spec agentic.utils.ShellParse.WrapperSpec
--- @return integer|nil inner_idx
local function skip_wrapper_operands(args, spec)
    --- Consume leading option tokens from index `i` per `spec`, returning the
    --- next index, or nil on an unrecognised option (the fail-closed bail).
    local function consume_options(i)
        while args[i] and args[i]:sub(1, 1) == "-" do
            local opt = args[i]
            if spec.value_opts and vim.tbl_contains(spec.value_opts, opt) then
                i = i + 2 -- value is the next token (`-s KILL`)
            elseif
                -- boolean flag, or self-contained form (`-oL`, `--signal=K`, `-5`)
                (spec.flag_opts and vim.tbl_contains(spec.flag_opts, opt))
                or (
                    spec.attached
                    and matches_any_lua_pattern(opt, spec.attached)
                )
            then
                i = i + 1
            else
                return nil
            end
        end
        return i
    end

    local i = consume_options(1)
    if i and spec.subcommand then
        if args[i] ~= spec.subcommand then
            return nil -- not the launcher subcommand → fall through to leaf
        end
        i = consume_options(i + 1)
    end
    if not i then
        return nil
    end
    return i + (spec.positionals or 0)
end

--- @alias agentic.utils.ShellParse.Origin [integer, integer]

--- Resolve the inner command to recurse into for a transparent prefix — an
--- inline shell `-c '<body>'` or an exec-wrapper (`timeout`/`time`/`stdbuf`).
--- Returns nil to fall through to the leaf matchers (not a shell or
--- wrapper, missing/dynamic body, malformed operands, empty inner).
---
--- The `-c` body comes quote-stripped from `args` (a `-c` may be the trailing
--- letter of a short-flag cluster like `-lc`, still consuming the next word). A
--- single-quoted body (`raw_string`) is byte-identical to its source content, so
--- it gets an origin (content start) and tally ranges map 1:1; any other quoting
--- (double, `$'...'`, concatenation) processes the body and stays nil-origin. The
--- wrapper inner is a raw substring of `src` (quotes/escapes intact)
--- from the inner node's start to the wrapper command node's end, with the inner
--- node's `(row, col)` as origin for translating tally ranges.
--- @param cmd_name string command name, already path-stripped
--- @param node TSNode the `command` node
--- @param args string[] quote-stripped arg tokens
--- @param arg_nodes TSNode[] the arg token nodes, parallel to `args`
--- @param args_dynamic boolean[]
--- @param src string
--- @param wrappers table<string, agentic.utils.ShellParse.WrapperSpec>|nil
---        exec-wrapper specs, default `EXEC_WRAPPERS`
--- @return string|nil inner
--- @return agentic.utils.ShellParse.Origin|nil origin
--- @return boolean writes whether the prefix has a recoverable side effect of its
---         own (the wrapper's `writes` flag); false for shells (`-c` bodies are
---         vetted command-by-command in the recursion).
local function inner_source(
    cmd_name,
    node,
    args,
    arg_nodes,
    args_dynamic,
    src,
    wrappers
)
    if SHELL_C_COMMANDS[cmd_name] then
        for i, arg in ipairs(args) do
            if arg:match("^%-[a-zA-Z]*c$") then
                local body = args[i + 1]
                if body ~= nil and not args_dynamic[i + 1] then
                    -- A single-quoted body (`raw_string`) is byte-identical to
                    -- its source content with no escape/expansion processing, so
                    -- its coordinates map 1:1 — origin is the content start (one
                    -- column past the opening quote). Any other quoting (double,
                    -- $'...', concatenation) processes the body, so it has no
                    -- faithful mapping and stays coarse (nil origin → whole-leaf
                    -- highlight).
                    local body_node = arg_nodes[i + 1]
                    --- @type agentic.utils.ShellParse.Origin|nil
                    local origin = nil
                    if body_node:type() == "raw_string" then
                        local sr, sc = body_node:range()
                        origin = { sr, sc + 1 }
                    end
                    return body, origin, false
                end
                return nil, nil, false -- missing or dynamic body
            end
        end
        return nil, nil, false
    end

    local spec = (wrappers or EXEC_WRAPPERS)[cmd_name]
    if not spec then
        return nil, nil, false
    end
    local inner_idx = skip_wrapper_operands(args, spec)
    if not inner_idx then
        return nil, nil, false
    end
    local inner_node = arg_nodes[inner_idx]
    if not inner_node then
        return nil, nil, false -- empty inner
    end
    local sr, sc, inner_start_byte = inner_node:range(true)
    local _, _, _, _, _, node_end_byte = node:range(true)
    local inner = src:sub(inner_start_byte + 1, node_end_byte)
    if cmd_name == "xargs" then
        -- Model the runtime stdin items as a dynamic token (see EXEC_WRAPPERS).
        -- The obscure name avoids resolving against an earlier sequence binding.
        inner = inner .. " $__xargs_stdin"
    end
    return inner, { sr, sc }, spec.writes or false
end

--- Resolve a path token to a canonical absolute path: tilde/`..` collapsed, a
--- relative path joined against cwd, then symlinks in the parent resolved.
--- Shared so a redirect's write target and a script execution resolve
--- identically — the permission walk's intra-command taint check correlates the
--- two by string equality, which is unsound if they normalise differently. The
--- target itself may not exist yet (a redirect creates it), so only the parent
--- is `fs_realpath`'d: that unifies symlinked roots like `/tmp` → `/private/tmp`
--- (macOS) so `> /tmp/f` and `zsh /private/tmp/f` correlate. Lexical-only
--- `vim.fs.normalize` leaves them distinct and lets the second write slip the
--- taint scan (under-prompt). Degrades to the lexical form when the parent is
--- missing.
--- @param path string
--- @return string
local function resolve_against_cwd(path)
    if path:sub(1, 1) ~= "/" and path:sub(1, 1) ~= "~" then
        path = (vim.uv.cwd() or "") .. "/" .. path
    end
    path = vim.fs.normalize(path)
    local real_parent = vim.uv.fs_realpath(vim.fs.dirname(path))
    return real_parent and real_parent .. "/" .. vim.fs.basename(path) or path
end

--- Resolve the on-disk script a command would execute for the two non-`-c`
--- forms that run a file's contents: `zsh|bash|sh|dash <file>` and
--- `source|. <file>`. Returns the cwd-resolved absolute path, or nil to bail
--- (the caller falls through to a prompt) — the caller reads the bytes,
--- re-parses, and walks them, the same shape as the `-c` body recursion.
---
--- nil for: any other command; a missing, dynamic, or option-leading first arg
--- (a shell flag / `--`, or the `-c` that `inner_source` already owns). For
--- `source`/`.` two extra gates close body-swap holes that `zsh <file>` does not
--- have: the arg must contain a slash (a bare name searches `$path`, which is not
--- knowable from the token), and no sibling `<path>.zwc` may exist (zsh runs the
--- compiled bytecode over the `.sh` text we would read).
--- @param cmd_name string path-stripped command name
--- @param args string[] quote-stripped arg tokens
--- @param args_dynamic boolean[]
--- @return string|nil path
local function script_file_source(cmd_name, args, args_dynamic)
    local is_source = cmd_name == "source" or cmd_name == "."
    if not (SHELL_C_COMMANDS[cmd_name] or is_source) then
        return nil
    end
    local arg = args[1]
    if arg == nil or args_dynamic[1] or arg:sub(1, 1) == "-" then
        return nil
    end
    if is_source and not arg:find("/", 1, true) then
        return nil
    end
    local path = resolve_against_cwd(arg)
    if is_source and vim.uv.fs_stat(path .. ".zwc") then
        return nil
    end
    return path
end

-- ── Command extraction ───────────────────────────────────────────────────────

--- Split a raw token into a record's flags/args buckets. Short clusters
--- (`-rf`) split per character so a `flag` rule matching `-f` fires; long flags
--- (`--force`) stay whole. `-`/`--`/non-dash tokens are positional args. An
--- attached-value short flag (`-ofile`) over-splits into extra flag candidates,
--- which can only widen a flag match — the safe (over-block) direction.
--- @param tok string
--- @param flags string[]
--- @param args string[]
local function classify_token(tok, flags, args)
    if tok:match("^%-%-.") then
        table.insert(flags, tok)
    elseif tok:match("^%-[^%-].*$") then
        for ch in tok:sub(2):gmatch(".") do
            table.insert(flags, "-" .. ch)
        end
    else
        table.insert(args, tok)
    end
end

--- @class agentic.utils.ShellParse.Shell
--- @field cwd? string|false current directory: nil = the caller's cwd, false = unknown

--- Map each `command` that reads a heredoc on stdin to that heredoc. Only the
--- last simple command of a redirected statement reads it. A heredoc on a
--- non-zero fd, or on a statement ending in anything but a command (compound
--- statement, subshell, `negated_command`), has no reader.
--- @param root TSNode
--- @param src string
--- @return table<string, agentic.utils.ShellParse.Heredoc> heredocs keyed by the
---         reading command's `node:id()`
local function heredoc_targets(root, src)
    --- @type table<string, agentic.utils.ShellParse.Heredoc>
    local targets = {}
    local function visit(node)
        if node:type() == "redirected_statement" then
            -- The grammar hangs the heredoc on the whole list or pipeline, but
            -- the shell feeds it to the last command.
            local target = node:field("body")[1]
            while
                target
                and (target:type() == "list" or target:type() == "pipeline")
            do
                target = target:named_child(target:named_child_count() - 1)
            end
            if target and target:type() == "command" then
                for _, hr in ipairs(node:field("redirect")) do
                    local fd = hr:field("descriptor")[1]
                    if
                        hr:type() == "heredoc_redirect"
                        and (
                            not fd
                            or vim.treesitter.get_node_text(fd, src) == "0"
                        )
                    then
                        targets[target:id()] = heredoc_text(hr, src)
                    end
                end
            end
        end
        for child in node:iter_children() do
            visit(child)
        end
    end
    visit(root)
    return targets
end

--- The directory a shell is in after `cd` with the given operands. No
--- normalisation (`/a/../b` stays as is, `~` stays unexpanded).
--- @param cwd string|false|nil directory before the `cd`: nil = the caller's
---        cwd, false = unknown
--- @param args string[] the `cd` operands
--- @param args_dynamic boolean[] parallel to `args`
--- @return string|false|nil cwd same encoding as the `cwd` parameter
local function cwd_after_cd(cwd, args, args_dynamic)
    if #args == 0 then
        return "~"
    end
    local dir = args[1]
    if #args > 1 or args_dynamic[1] or dir == "" or dir:sub(1, 1) == "-" then
        return false
    end
    if dir:match("^[/~]") or cwd == nil then
        return dir
    end
    if cwd == false then
        return false
    end
    return cwd .. "/" .. dir
end

--- Join each run of byte-adjacent argument nodes into one shell word. The
--- grammar splits a word such as `--include=*.{ts,tsx}` into a `word` and a
--- `glob_pattern` with no `concatenation` over them. A joined entry is the raw
--- source of the run, is always dynamic (the split happens only at a glob or
--- brace part), and keeps the run's first node. A run of one is copied as is.
--- @param args string[]
--- @param arg_nodes TSNode[]
--- @param args_dynamic boolean[] all three parallel
--- @param src string
--- @return string[] args
--- @return TSNode[] arg_nodes
--- @return boolean[] args_dynamic new tables, the inputs are not changed
function M.join_adjacent_args(args, arg_nodes, args_dynamic, src)
    local joined_args, joined_nodes, joined_dynamic = {}, {}, {}
    local i = 1
    while i <= #args do
        local _, _, run_start = arg_nodes[i]:range(true)
        local j = i
        while j < #args do
            local _, _, _, _, _, end_byte = arg_nodes[j]:range(true)
            local _, _, next_start = arg_nodes[j + 1]:range(true)
            if end_byte ~= next_start then
                break
            end
            j = j + 1
        end
        table.insert(joined_nodes, arg_nodes[i])
        if j == i then
            table.insert(joined_args, args[i])
            table.insert(joined_dynamic, args_dynamic[i])
        else
            local _, _, _, _, _, run_end = arg_nodes[j]:range(true)
            table.insert(joined_args, src:sub(run_start + 1, run_end))
            table.insert(joined_dynamic, true)
        end
        i = j + 1
    end
    return joined_args, joined_nodes, joined_dynamic
end

--- Forward declaration — `collect` and `collect_command` are mutually recursive.
--- @type fun(node: TSNode, src: string, out: agentic.ShellCommand[], depth: integer, shell: agentic.utils.ShellParse.Shell, stdin_of: table<string, agentic.utils.ShellParse.Heredoc>): boolean
local collect

--- Process a `command` node: resolve its name, unwrap transparent prefixes
--- (exec-wrapper / inline `-c` body) by re-parsing the inner, else emit an
--- `agentic.ShellCommand` record. Substitutions in arguments or in an
--- env-prefix value are flattened by recursing `collect` over them, so a live
--- `git commit -m "$(rm -rf /)"` yields both `git` and the inner `rm`.
--- @param node TSNode
--- @param src string
--- @param out agentic.ShellCommand[]
--- @param depth integer
--- @param shell agentic.utils.ShellParse.Shell state of the shell running
---        `node`, updated in place by `cd`, `pushd` and `popd`
--- @param stdin_of table<string, agentic.utils.ShellParse.Heredoc> the
---        heredoc each `command` in `src` reads on stdin, keyed by `node:id()`
--- @return boolean ok
local function collect_command(node, src, out, depth, shell, stdin_of)
    local name_node
    --- @type string[]
    local args = {}
    --- @type TSNode[]
    local arg_nodes = {}
    --- @type boolean[]
    local args_dynamic = {}
    -- Substitution-bearing subtrees (bare `$(...)` args, embedded `"$(…)"`,
    -- env-prefix values). Flattened *after* this command's own record so inner
    -- commands follow the outer one in extraction order.
    --- @type TSNode[]
    local to_flatten = {}
    for child in node:iter_children() do
        local t = child:type()
        if t == "command_name" then
            name_node = child
        elseif t == "variable_assignment" then
            -- Env prefix (`FOO=bar cmd`): not a command, but its value may carry
            -- a live substitution.
            if subtree_has_substitution(child) then
                table.insert(to_flatten, child)
            end
        elseif t == "command_substitution" then
            -- Bare `$(...)` arg: its captured output is an opaque dynamic token
            -- in the outer command; its inner commands flatten separately.
            table.insert(to_flatten, child)
            table.insert(args, vim.treesitter.get_node_text(child, src))
            table.insert(arg_nodes, child)
            table.insert(args_dynamic, true)
        elseif child:named() and t ~= "comment" then
            if subtree_has_substitution(child) then
                -- Embedded substitution (`"$(…)"`, concatenation): opaque
                -- dynamic token; inner flattens separately.
                table.insert(to_flatten, child)
                table.insert(args, vim.treesitter.get_node_text(child, src))
                table.insert(arg_nodes, child)
                table.insert(args_dynamic, true)
            else
                local tok = literal_token(child, src)
                if tok == nil then
                    return false
                end
                table.insert(args, tok)
                table.insert(arg_nodes, child)
                table.insert(args_dynamic, token_is_dynamic(child))
            end
        end
    end

    if not name_node then
        return false
    end
    local name = command_name_text(name_node, src)
    if not name then
        return false -- dynamic command name
    end
    local cmd_name = strip_command_path(name)
    if CODE_TAKING_BUILTINS[cmd_name] then
        return false
    end
    args, arg_nodes, args_dynamic =
        M.join_adjacent_args(args, arg_nodes, args_dynamic, src)

    -- Transparent prefix: re-parse and flatten the inner instead of emitting the
    -- wrapper/shell itself, so `timeout 5 rm -f x` and `zsh -c 'rm -f x'` both
    -- yield a record for `rm`.
    local inner = inner_source(
        cmd_name,
        node,
        args,
        arg_nodes,
        args_dynamic,
        src,
        VISIBLE_WRAPPERS
    )
    if inner and inner ~= "" then
        if depth >= NESTED_MAX_DEPTH then
            return false
        end
        local root = parse_zsh(inner)
        if not root then
            return false
        end
        local inner_stdin_of = heredoc_targets(root, inner)
        -- The wrapper's stdin reaches the inner, except xargs' (read as its
        -- argument list).
        local inner_cmd = root:named_child(0)
        if
            stdin_of[node:id()]
            and not SHELL_C_COMMANDS[cmd_name]
            and cmd_name ~= "xargs"
            and root:named_child_count() == 1
            and inner_cmd
            and inner_cmd:type() == "command"
        then
            inner_stdin_of[inner_cmd:id()] = stdin_of[node:id()]
        end
        -- The inner runs in a process of its own, so its `cd` does not leak out.
        return collect(
            root,
            inner,
            out,
            depth + 1,
            { cwd = shell.cwd },
            inner_stdin_of
        )
    end

    --- @type agentic.ShellCommand
    local rec = {
        name = cmd_name,
        flags = {},
        args = {},
        argv = args,
        argv_dynamic = args_dynamic,
        stdin = stdin_of[node:id()],
        cwd = shell.cwd,
    }
    for _, tok in ipairs(args) do
        classify_token(tok, rec.flags, rec.args)
    end
    table.insert(out, rec)

    for _, sub in ipairs(to_flatten) do
        if not collect(sub, src, out, depth, shell, stdin_of) then
            return false
        end
    end

    if cmd_name == "cd" then
        shell.cwd = cwd_after_cd(shell.cwd, args, args_dynamic)
    elseif cmd_name == "pushd" or cmd_name == "popd" then
        shell.cwd = false
    end
    return true
end

--- Node types whose commands run in a child shell, which gets a copy of the
--- parent's state (its own `cd` does not leak out). A function body runs at
--- call time, not where it is defined, so it is walked the same way.
local CHILD_SHELL_TYPES = {
    subshell = true,
    command_substitution = true,
    process_substitution = true,
    function_definition = true,
}

--- Operators that run the statement before them in the background, in a child
--- shell. The grammar has no node for the backgrounded statement, only this
--- trailing sibling.
local BACKGROUND_OPERATORS = { ["&"] = true, ["&!"] = true, ["&|"] = true }

--- Whether `child` of `parent` runs in a child shell of its own: a background
--- statement, or (in zsh) any pipeline element but the last.
--- @param parent TSNode
--- @param child TSNode
--- @return boolean
local function runs_in_child_shell(parent, child)
    local next_sibling = child:next_sibling()
    if next_sibling and BACKGROUND_OPERATORS[next_sibling:type()] then
        return true
    end
    return parent:type() == "pipeline" and child:next_named_sibling() ~= nil
end

--- @param node TSNode
--- @param src string
--- @param out agentic.ShellCommand[]
--- @param depth integer
--- @param shell agentic.utils.ShellParse.Shell state of the shell running
---        `node`, updated in place by its directory changes outside child
---        shells
--- @param stdin_of table<string, agentic.utils.ShellParse.Heredoc> the
---        heredoc each `command` in `src` reads on stdin, keyed by `node:id()`
--- @return boolean ok
function collect(node, src, out, depth, shell, stdin_of)
    local t = node:type()
    if t == "command" then
        return collect_command(node, src, out, depth, shell, stdin_of)
    end
    if CHILD_SHELL_TYPES[t] then
        shell = { cwd = shell.cwd }
    end
    -- Every other node (containers, pipelines, control flow, redirected
    -- statements, assignments, substitutions): recurse named children. A
    -- redirect target / env prefix does not hide a command, so we never bail
    -- here — only `collect_command` decides safety.
    for _, child in ipairs(node:named_children()) do
        if child:type() ~= "comment" then
            local child_shell = runs_in_child_shell(node, child)
                    and { cwd = shell.cwd }
                or shell
            if not collect(child, src, out, depth, child_shell, stdin_of) then
                return false
            end
        end
    end
    return true
end

--- @class agentic.ShellCommand
--- @field name string unwrapped inner command name, path-stripped
--- @field flags string[] short clusters split (`-rf` → `-r`,`-f`), long flags whole
--- @field args string[] positional arguments (literal text where resolvable)
--- @field argv string[] every token after the name in source order, flags unsplit (literal text where resolvable)
--- @field argv_dynamic boolean[] parallel to `argv`: true where the token is not a static literal (expansion, substitution, xargs' stand-in `$__xargs_stdin`)
--- @field stdin? agentic.utils.ShellParse.Heredoc the heredoc this command reads on stdin
--- @field cwd? string|false the directory this command starts in, after earlier `cd`s in the same shell. Not normalised, and relative to the caller's cwd when relative. nil = no `cd` yet, false = unknown. A `cd` in a branch or loop counts as if it always ran.

--- Extract the flat list of statically-resolvable commands a shell string would
--- run — across pipelines, control flow, exec-wrappers, inline `-c` bodies, and
--- live command substitutions. Each record is normalised to an
--- `agentic.ShellCommand`.
---
--- Fail-closed: parse error, absent parser, an `ERROR` node, a dynamic command
--- name, a code-taking builtin (`eval`/`source`/`.`), or an unextractable token
--- — anything that could hide a command from view — returns `nil`. `nil` means
--- "can't prove what runs" (a consumer fires every block rule); `{}` means
--- "parsed, no command" (a bare string) and fires nothing. Conflating the two is
--- the silent-miss bug — keep them distinct.
--- @param src string
--- @return agentic.ShellCommand[]|nil records nil = fail-closed (can't prove what runs)
function M.extract_commands(src)
    if type(src) ~= "string" or src == "" then
        return nil
    end
    if #src > 65536 then
        return nil
    end
    local root = parse_zsh(src)
    if not root then
        return nil
    end
    --- @type agentic.ShellCommand[]
    local out = {}
    if not collect(root, src, out, 0, {}, heredoc_targets(root, src)) then
        return nil
    end
    return out
end

-- ── Shared primitives consumed by permission_rules.walk / tally_walk ─────────

M.strip_command_path = strip_command_path
M.parse_zsh = parse_zsh
M.arithmetic_args_read_value = arithmetic_args_read_value
M.subtree_has_substitution = subtree_has_substitution
M.safe_assignment_name = safe_assignment_name
M.pure_literal_token = pure_literal_token
M.literal_token = literal_token
M.token_is_dynamic = token_is_dynamic
M.command_name_text = command_name_text
M.redirect_is_safe = redirect_is_safe
M.redirect_write_dest = redirect_write_dest
M.redirect_is_truncate = redirect_is_truncate
M.heredoc_pure_body = heredoc_pure_body
M.is_bare_cat = is_bare_cat
M.inner_source = inner_source
M.script_file_source = script_file_source
M.resolve_against_cwd = resolve_against_cwd
M.CONTAINER_TYPES = CONTAINER_TYPES
M.SUBSTITUTION_TYPES = SUBSTITUTION_TYPES
M.SUBSTITUTION_INNER_STATEMENT_TYPES = SUBSTITUTION_INNER_STATEMENT_TYPES
M.CODE_TAKING_BUILTINS = CODE_TAKING_BUILTINS
M.NESTED_MAX_DEPTH = NESTED_MAX_DEPTH

return M
