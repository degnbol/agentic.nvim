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
--- No `Config`/runtime requires (only `vim.treesitter`, `zsh_parse` and the
--- pure-Lua `zsh_arithmetic` and `zsh_special_params`) so it loads under
--- `nvim -u NONE` with just the plugin on the runtimepath.
---
--- Node-type names are pinned to the installed tree-sitter-zsh grammar (verified
--- 2026-06-18). They can drift across grammar versions — re-verify with a
--- parse-tree dump after upgrading the parser.

local ZshArithmetic = require("agentic.utils.zsh_arithmetic")
local ZshParse = require("agentic.utils.zsh_parse")
local ZshSpecialParams = require("agentic.utils.zsh_special_params")

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

--- Lua patterns for lowercase env names that programs read: `*_proxy`
--- redirects curl/git/pip traffic, `npm_config_*` rewrites npm config.
local ENV_READ_PATTERNS = { "_proxy$", "^npm_config_" }

--- zsh hook functions: zsh calls each by name on its event. `precmd`,
--- `preexec`, `periodic` and `zshaddhistory` do not fire under `zsh -c`, but
--- the shell mode a command runs in is not known here.
local ZSH_HOOK_FUNCTIONS = {
    chpwd = true,
    periodic = true,
    precmd = true,
    preexec = true,
    zshaddhistory = true,
    zshexit = true,
}

--- zsh hook arrays: zsh calls every function they name.
--- @type table<string, true>
local ZSH_HOOK_ARRAYS = {}
for hook in pairs(ZSH_HOOK_FUNCTIONS) do
    ZSH_HOOK_ARRAYS[hook .. "_functions"] = true
end

--- Whether zsh calls a function of this name with no call site in the
--- command: a hook function, a `TRAP*` signal trap,
--- `command_not_found_handler`, or `zsh_directory_name` (`~[…]` expansion).
--- @param name string function name
--- @return boolean
function M.runs_without_call(name)
    return ZSH_HOOK_FUNCTIONS[name] ~= nil
        or name == "command_not_found_handler"
        or name == "zsh_directory_name"
        or vim.startswith(name, "TRAP")
end

--- Whether a variable name is inert by convention: a single uppercase letter,
--- or a name that starts lowercase after leading underscores and is not a zsh
--- special parameter, a zsh hook array, or an env name that programs read.
--- Other uppercase names are the conventional env hijackers (`PATH`,
--- `LD_PRELOAD`), all multi-character. Lowercase zsh specials (`path`,
--- `functions`) drive execution too.
--- @param name string
--- @return boolean
local function is_inert_var_name(name)
    if name:match("^[A-Z]$") then
        return true
    end
    if
        not name:match("^_*[a-z]")
        or ZshSpecialParams[name]
        or ZSH_HOOK_ARRAYS[name]
    then
        return false
    end
    for _, pattern in ipairs(ENV_READ_PATTERNS) do
        if name:find(pattern) then
            return false
        end
    end
    return true
end

--- Whether binding `name` cannot change execution: a behaviour-only env name
--- (`LANG`, `LC_*`, `TERM`) or a name that is inert by convention. A subscript
--- (`x[1]`) binds an element of its base parameter, so the base is judged.
--- @param name string parameter name, optionally subscripted
--- @return boolean
function M.is_safe_var_name(name)
    local base = name:match("^[^%[]*")
    return is_safe_env_name(base) or is_inert_var_name(base)
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

--- Node types of a word that is one expansion or substitution.
local EXPANSION_TYPES = {
    command_substitution = true,
    process_substitution = true,
    expansion = true,
    simple_expansion = true,
    variable_ref = true,
    arithmetic_expansion = true,
}

--- Code-taking builtins: the argument is shell code the matcher cannot inspect,
--- so they bail even when the builtin name would match a pattern.
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

--- Whether a `variable_assignment` node binds a name that cannot change
--- execution (`M.is_safe_var_name`). False for a node without a name.
--- @param va TSNode
--- @param src string
--- @return boolean
local function safe_assignment_name(va, src)
    local name_node = va:field("name")[1]
    return name_node ~= nil
        and M.is_safe_var_name(vim.treesitter.get_node_text(name_node, src))
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

--- Single-character escapes of a `$'…'` string (zshmisc(1) QUOTING).
local ANSI_C_ESCAPES = {
    a = "\a",
    b = "\b",
    e = "\27",
    E = "\27",
    f = "\f",
    n = "\n",
    r = "\r",
    t = "\t",
    v = "\v",
    ["\\"] = "\\",
    ["'"] = "'",
    ['"'] = '"',
    ["?"] = "?",
}

--- Quote removal for a `$'…'` string: the single-character escapes, `\NNN`
--- octal and `\xHH` hex.
--- @param text string source text of the string, `$'` and `'` included
--- @return string|nil word the word the shell delivers; nil when an escape is
---         none of those (`\u`, `\c`), or the word holds a NUL byte (zsh ends
---         an external command's argument at a NUL, but not a builtin's)
local function ansi_c_text(text)
    local out = {}
    local i, last = 3, #text - 1
    while i <= last do
        local c = text:sub(i, i)
        if c ~= "\\" then
            table.insert(out, c)
            i = i + 1
        else
            local escape = ANSI_C_ESCAPES[text:sub(i + 1, i + 1)]
            local octal = text:match("^[0-7][0-7]?[0-7]?", i + 1)
            local hex = text:match("^x(%x%x?)", i + 1)
            if escape then
                table.insert(out, escape)
                i = i + 2
            elseif octal then
                table.insert(out, string.char(tonumber(octal, 8) % 256))
                i = i + 1 + #octal
            elseif hex then
                table.insert(out, string.char(tonumber(hex, 16)))
                i = i + 2 + #hex
            else
                return nil
            end
        end
    end
    local word = table.concat(out)
    if word:find("\0", 1, true) then
        return nil
    end
    return word
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
--- cannot be read from its source bytes (`$'\q'`). Used as the recursive step
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
    if t == "ansi_c_string" then
        return ansi_c_text(vim.treesitter.get_node_text(node, src))
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

--- Whether an argument token expands at runtime to a value the matcher cannot
--- see — a variable/arithmetic expansion, an unquoted glob, or a quoted string
--- carrying an expansion. Pure literals (`word`, `number`, `raw_string`,
--- `ansi_c_string`, an all-`string_content` string, a literal `concatenation`,
--- `brace_expression`) are static. A `~`-prefixed path is a plain `word` in this grammar and
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
--- fails `ZshParse.parse`, so it never reaches here. Only the argument site passes
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

--- Extract the token text from one node that appears as a child of a
--- `command` (an argument token) or as the inner of a `command_name`. Returns
--- the joined string, or nil to bail. Lenient for top-level expansion-bearing
--- tokens (`"$f"`, `$bar`) — they're emitted as raw source text, so
--- `ls "$f"` matches a settings.json `Bash(ls *)` glob. Strict
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
        or t == "ansi_c_string"
        or t == "brace_expression"
    then
        return pure_literal_token(node, src)
    end
    if t == "string" then
        -- Substitution-bearing strings are caught at the command level. A
        -- string composed only of `string_content` yields its delivered text
        -- (so `"rm"` cannot evade a deny pattern), or nil to bail. A string
        -- that mixes `string_content` with expansions yields the raw quoted
        -- text, which settings.json globs match.
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
        -- Raw text only for a dynamic concatenation (`$d/x`), so it splices as
        -- one token. A static one with no pure form (`-x$'\q'`), or one with a
        -- substitution, has no delivered text.
        if subtree_has_substitution(node) or not token_is_dynamic(node) then
            return nil
        end
        return vim.treesitter.get_node_text(node, src)
    end
    if EXPANSION_TYPES[t] then
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

--- The text a word delivers, when it is a static literal.
--- @param node TSNode
--- @param src string
--- @return string text the delivered text, or the source text when `dynamic`
--- @return boolean dynamic the word is not a static literal, or its text does
---         not resolve
local function word_value(node, src)
    if not token_is_dynamic(node) and not subtree_has_substitution(node) then
        local text = pure_literal_token(node, src)
        if text then
            return text, false
        end
    end
    return vim.treesitter.get_node_text(node, src), true
end

--- Whether a `command_name` node's word is only known at runtime — a
--- substitution, expansion, arithmetic, glob, or a `string`/`concatenation`
--- carrying one (`"$x"`).
--- @param command_name TSNode
--- @return boolean
local function name_is_dynamic(command_name)
    local inner = command_name:named_child(0)
    return inner ~= nil
        and (token_is_dynamic(inner) or subtree_has_substitution(inner))
end

--- Extract the literal command name from a `command_name` node, normalising
--- quotes so `"rm"` and `'rm'` resolve to `rm` (a quoted name must not evade a
--- deny pattern). A literal concatenation in command-name position (e.g.
--- `gr"e"p`) joins to its concatenated text via `literal_token`.
--- @param command_name TSNode
--- @param src string
--- @return string|nil name nil when the name is missing, dynamic (`$x`,
---         `"$x"`), or static with text that does not resolve (`$'\q'`)
local function command_name_text(command_name, src)
    local inner = command_name:named_child(0)
    -- A dynamic name is nil, not the raw `$VAR` text `literal_token` hands
    -- back for a bare expansion, so no consumer mistakes it for a name.
    if not inner or name_is_dynamic(command_name) then
        return nil
    end
    return literal_token(inner, src)
end

--- The name of a `command` node as written (path kept). Nil when the node
--- has no name, the name is dynamic (`$x`), or its text does not resolve
--- (`$'\q'`).
--- @param node TSNode `command` node
--- @param src string source of `node`
--- @return string|nil name
function M.command_name(node, src)
    local name_node = node:field("name")[1]
    return name_node and command_name_text(name_node, src)
end

--- The path a command line runs first, as written: the name of its first
--- `command` node when that holds a `/`. No file system access, so `~` and
--- relative paths stay as they are.
--- @param command string
--- @return string|nil path nil when the line does not parse, or its first command's name is not a static path
function M.leading_path(command)
    local root = ZshParse.parse_command(command)
    local function first_command(node)
        if node:type() == "command" then
            return node
        end
        for child in node:iter_children() do
            local found = first_command(child)
            if found then
                return found
            end
        end
        return nil
    end
    local node = root and first_command(root)
    local name = node and M.command_name(node, command)
    return name and name:find("/", 1, true) and name or nil
end

--- Every name a `function_definition` defines (`function a b { … }` defines
--- two), unescaped (`l\s() …` defines `ls`).
--- @param node TSNode a `function_definition`
--- @param src string
--- @return string[]|nil names nil for an anonymous function or a name that is
---         not a plain word
function M.function_names(node, src)
    local name_nodes = node:field("name")
    if #name_nodes == 0 then
        return nil
    end
    local names = {}
    for _, n in ipairs(name_nodes) do
        if n:type() ~= "word" then
            return nil
        end
        table.insert(names, pure_literal_token(n, src))
    end
    return names
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
--- it against the grant scopes (see permission_manager's `_bash_effects_clear`).
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

--- @class agentic.utils.ShellParse.Redirect
--- @field op string the operator as written: `>`, `>>`, `>|`, `&>`, `&>>`, `<`, `>&`, `<&`, `<<<` (`>&-` is `>&` with target `-`)
--- @field fd? integer the descriptor before the operator (`2>`), nil when none is written
--- @field target string the destination, literal text where resolvable, the herestring text for `<<<`
--- @field target_fd boolean the destination is a descriptor (`>&2`, `2>&1`, `2>&-`), not a file (`>& file`)
--- @field dynamic boolean the destination is not a static literal

--- A `file_redirect` or `herestring_redirect` as a record. Only the first
--- `destination` child is the target, later ones are ignored.
--- @param node TSNode
--- @param src string
--- @return agentic.utils.ShellParse.Redirect redirect
local function redirect_record(node, src)
    local op, dest
    for child, field in node:iter_children() do
        if not child:named() then
            op = child:type()
        elseif field ~= "descriptor" then
            dest = dest or child
        end
    end
    local fd_node = node:field("descriptor")[1]
    --- @type agentic.utils.ShellParse.Redirect
    local redirect = {
        op = op,
        fd = fd_node and tonumber(vim.treesitter.get_node_text(fd_node, src)),
        target = "-",
        target_fd = true,
        dynamic = false,
    }
    if op == ">&-" or op == "<&-" then
        redirect.op = op:sub(1, 2)
        return redirect
    end
    redirect.target, redirect.dynamic = word_value(dest, src)
    redirect.target_fd = (op == ">&" or op == "<&")
        and (dest:type() == "file_descriptor" or dest:type() == "number")
    return redirect
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

-- ── Prefix assignments ───────────────────────────────────────────────────────

--- @class agentic.utils.ShellParse.Assignment
--- @field value string the value, unquoted when static, as written when `dynamic`
--- @field dynamic boolean the value is not a static literal, or appends (`+=`) to one not known

--- A `variable_assignment` as a record.
--- @param va TSNode
--- @param src string
--- @return string name the name as written, subscript included
--- @return agentic.utils.ShellParse.Assignment assignment
local function assignment_record(va, src)
    local name = vim.treesitter.get_node_text(va:field("name")[1], src)
    local value_node = va:field("value")[1]
    --- @type agentic.utils.ShellParse.Assignment
    local assignment = { value = "", dynamic = false }
    if value_node then
        assignment.value, assignment.dynamic = word_value(value_node, src)
    end
    for child in va:iter_children() do
        if child:type() == "+=" then
            assignment.dynamic = true
        end
    end
    return name, assignment
end

-- ── Builtin bindings ─────────────────────────────────────────────────────────

--- True iff any of the first `n` words is dynamic.
--- @param args_dynamic boolean[] per word: true for a word that expands at runtime
--- @param n integer
--- @return boolean
local function any_dynamic(args_dynamic, n)
    for i = 1, n do
        if args_dynamic[i] then
            return true
        end
    end
    return false
end

--- Option letters of zsh's `print` and `read` that take a value (zshbuiltins(1)):
--- `"value"` takes the rest of the word, else the next word; `"number"` takes
--- attached digits, else a next word of digits only.
--- @type table<string, table<string, "value"|"number">>
local BUILTIN_VALUE_OPTIONS = {
    print = {
        C = "value",
        f = "value",
        u = "value",
        v = "value",
        x = "value",
        X = "value",
    },
    read = { d = "value", u = "value", k = "number", t = "number" },
}

--- Parse the leading option words of a zsh builtin. Options end at a `--` or
--- `-` word (consumed) or at the first word not starting with `-`.
--- @param args string[] the builtin's arguments
--- @param spec table<string, "value"|"number"> value-taking option letters
---   (see `BUILTIN_VALUE_OPTIONS`)
--- @return table<string, string[]> values per `"value"` letter, in order
--- @return integer i_operand index of the first operand, `#args + 1` when
---   there is none
--- @return boolean terminated true when a `--` or `-` word ended the options
local function builtin_options(args, spec)
    local values, i = {}, 1
    while args[i] do
        local word = args[i]
        if not word:match("^%-") then
            return values, i, false
        end
        i = i + 1
        if word == "--" or word == "-" then
            return values, i, true
        end
        local j = 2
        while j <= #word do
            local letter = word:sub(j, j)
            if spec[letter] == "value" then
                local value = word:sub(j + 1)
                if value == "" and args[i] then
                    value = args[i]
                    i = i + 1
                end
                values[letter] = values[letter] or {}
                table.insert(values[letter], value)
                j = #word
            elseif spec[letter] == "number" then
                local digits = word:match("^%d*", j + 1)
                j = j + #digits
                if
                    digits == ""
                    and j == #word
                    and (args[i] or ""):match("^%d+$")
                then
                    i = i + 1
                end
            end
            j = j + 1
        end
    end
    return values, i, false
end

--- The parameter names a `printf`, `print` or `read` call binds by argument:
--- each `-v` name of printf and print, and each operand of read with any
--- `?prompt` suffix stripped. Read's implicit `REPLY`/`reply` are not included.
--- @param cmd_name string path-stripped command name
--- @param args string[] delivered words, dynamic ones as raw text
--- @param args_dynamic boolean[] parallel to `args`: true for a word that
---   expands at runtime
--- @return string[]|nil targets `{}` for any other command; nil when a word
---   that may be a target, or may expand to an option, is dynamic
function M.builtin_bind_targets(cmd_name, args, args_dynamic)
    if cmd_name == "printf" then
        local targets, i_operand = ZshArithmetic.printf_options(args)
        if any_dynamic(args_dynamic, i_operand) then
            return nil
        end
        return targets
    end
    local spec = BUILTIN_VALUE_OPTIONS[cmd_name]
    if not spec then
        return {}
    end
    local values, i_operand, terminated = builtin_options(args, spec)
    if cmd_name == "print" then
        -- An unterminated first operand may expand to an option.
        if
            any_dynamic(args_dynamic, terminated and i_operand - 1 or i_operand)
        then
            return nil
        end
        return values.v or {}
    end
    if any_dynamic(args_dynamic, #args) then
        return nil
    end
    local targets = {}
    for i = i_operand, #args do
        table.insert(targets, (args[i]:gsub("%?.*", "")))
    end
    return targets
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
--- @field writes? boolean the wrapper itself has a recoverable side effect of its own (uv's env sync may install). Reported back from `inner_source` so the decision walk gates recursion to the safe_write tier — a read-only inner must not launder the command into a read-only one.
--- @field assignments? boolean `NAME=value` operands may follow the options (env's), skipped like options
--- @field code_opts? string[] options whose value is shell code (`script -c`), unwrapped like a `zsh -c` body. A short one may also end a cluster of `flag_opts` (`-qc`).

--- Where a launcher's inner command is among its arguments (the words after
--- its name).
--- @class agentic.utils.ShellParse.WrapperOperands
--- @field i_inner integer argument index of the inner command's first word, or of the shell code when `code`. Past the end when there is no inner command.
--- @field code boolean the word at `i_inner` is the value of a `code_opts` option
--- @field i_assignments integer[] argument indices of the `NAME=value` operands

--- Exec-wrappers: effect-neutral prefixes whose sole job is to launch the
--- following command. Excluding a write option / requiring a positional makes
--- the inner slice misparse fail-closed rather than expose a dangerous inner.
---
--- Transparency is a per-wrapper property, not a category — recursing into any
--- launcher is unsound. Other launchers are deliberately NOT here: `env` and
--- `nohup` can set an execution-hijacking var (`PATH`, `LD_PRELOAD`) or write
--- `nohup.out`; `command -p` is not unwrapped, though it only swaps `PATH` for a
--- default one (bare `command` is a wrapper);
--- `builtin`/`exec` alter the shell process; `parallel` runs a command per
--- input (its own `{}` DSL, remote exec via `--sshlogin`). It is left to match no allow rule (so it prompts) rather than
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
--- walk only recurses at the safe_write tier, never laundering a read-only inner into a
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
    -- COMMAND — bare only, so `-p`/`-v`/`-V` bail. It runs the external
    -- COMMAND (not a function or builtin) with the same PATH.
    command = {},
    -- run COMMAND — bare only (no option lists → any dash token bails); env
    -- sync is a recoverable write, so it needs the safe_write level (`writes`).
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
--- and `--directory` still stop the skip. Also unwraps the launchers that
--- `EXEC_WRAPPERS` leaves out for their other effects (`sudo`, `env`, `nohup`,
--- `exec`, `builtin`, ...): they still run the command.
--- @type table<string, agentic.utils.ShellParse.WrapperSpec>
local VISIBLE_WRAPPERS = vim.tbl_extend("force", EXEC_WRAPPERS, {
    sudo = {
        value_opts = {
            "-u",
            "-g",
            "-h",
            "-p",
            "-C",
            "-D",
            "-r",
            "-t",
            "-U",
            "--user",
            "--group",
            "--host",
            "--prompt",
            "--close-from",
            "--chdir",
            "--role",
            "--type",
            "--other-user",
        },
        flag_opts = {
            "-A",
            "-b",
            "-E",
            "-H",
            "-k",
            "-n",
            "-P",
            "-S",
            "--askpass",
            "--background",
            "--preserve-env",
            "--set-home",
            "--reset-timestamp",
            "--non-interactive",
            "--preserve-groups",
            "--stdin",
        },
        attached = { "^%-%-[%w-]+=", "^%-[ugpCDrtUh]." },
    },
    -- [OPTION]... [NAME=VALUE]... COMMAND; `-S` splits a string into words
    -- and stops the skip.
    env = {
        value_opts = { "-u", "-C", "--unset", "--chdir" },
        flag_opts = { "-", "-i", "-0", "--ignore-environment", "--null" },
        attached = { "^%-%-unset=", "^%-%-chdir=", "^%-[uC]." },
        assignments = true,
    },
    nice = {
        value_opts = { "-n", "--adjustment" },
        attached = { "^%-%-adjustment=", "^%-n.", "^%-%d+$" },
    },
    nohup = {},
    exec = { value_opts = { "-a" }, flag_opts = { "-c", "-l" } },
    builtin = {},
    noglob = {},
    nocorrect = {},
    -- BSD `[-adeFkpqr] [-T fmt] [file [command …]]`, util-linux
    -- `[options] [-c command] [file]`. `-t` stops the skip: BSD's takes a
    -- value, util-linux's an optional attached one.
    script = {
        value_opts = {
            "-T",
            "-B",
            "-I",
            "-O",
            "-E",
            "-m",
            "-o",
            "--log-io",
            "--log-in",
            "--log-out",
            "--log-timing",
            "--logging-format",
            "--output-limit",
            "--echo",
        },
        flag_opts = {
            "-a",
            "-d",
            "-e",
            "-F",
            "-f",
            "-k",
            "-p",
            "-q",
            "-r",
            "--append",
            "--return",
            "--flush",
            "--force",
            "--quiet",
        },
        attached = {
            "^%-%-log%-io=",
            "^%-%-log%-in=",
            "^%-%-log%-out=",
            "^%-%-log%-timing=",
            "^%-%-logging%-format=",
            "^%-%-output%-limit=",
            "^%-%-echo=",
        },
        code_opts = { "-c", "--command" },
        positionals = 1, -- the transcript file
    },
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

--- Consume an exec-wrapper's own operands per its spec and locate the inner
--- command, or nil to bail.
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
--- @return agentic.utils.ShellParse.WrapperOperands|nil operands
local function skip_wrapper_operands(args, spec)
    --- Whether `opt` is a `code_opts` option, alone or ending a cluster of
    --- `flag_opts` (`-qc`).
    local function is_code_option(opt)
        if not spec.code_opts then
            return false
        end
        if vim.list_contains(spec.code_opts, opt) then
            return true
        end
        local cluster, letter = opt:match("^%-(%a+)(%a)$")
        return cluster ~= nil
            and vim.list_contains(spec.code_opts, "-" .. letter)
            and vim.iter(vim.split(cluster, "")):all(function(c)
                return vim.list_contains(spec.flag_opts or {}, "-" .. c)
            end)
    end

    --- Consume leading option tokens from index `i` per `spec`, returning the
    --- next index, or nil on an unrecognised option (the fail-closed bail).
    --- @param i integer
    --- @return integer|nil i
    --- @return boolean|nil code the options end at a code option, so `i` is
    ---         its value
    local function consume_options(i)
        while args[i] and args[i]:sub(1, 1) == "-" do
            local opt = args[i]
            if opt == "--" then
                return i + 1 -- end of options
            elseif is_code_option(opt) then
                return i + 1, true
            elseif
                spec.value_opts and vim.tbl_contains(spec.value_opts, opt)
            then
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

    local i, code = consume_options(1)
    if i and not code and spec.subcommand then
        if args[i] ~= spec.subcommand then
            return nil -- not the launcher subcommand → fall through to leaf
        end
        i, code = consume_options(i + 1)
    end
    if not i then
        return nil
    end
    --- @type agentic.utils.ShellParse.WrapperOperands
    local operands = { i_inner = i, code = code or false, i_assignments = {} }
    if code then
        return operands
    end
    while spec.assignments and args[i] and args[i]:match("^[%a_][%w_]*=") do
        table.insert(operands.i_assignments, i)
        i = i + 1
    end
    operands.i_inner = i + (spec.positionals or 0)
    return operands
end

--- Grammar of a command that runs an action command per match. Unlike an
--- exec-wrapper, the host keeps effects of its own (`find -delete`).
--- @class agentic.utils.ShellParse.ActionSpec
--- @field opts string[] tokens that start an action
--- @field flag_opts string[] valueless options an action option may follow
--- @field pair_opts string[] options that take two values, so the second may be an action option
--- @field foreign_cwd_opts string[] action options that run in the match's directory
--- @field chdir_opts string[] host options whose value becomes every action's cwd. A short one also counts inside a cluster (`-HC`).
--- @field plus_ends boolean `+` directly after `{}` ends an action
--- @field open_ended boolean the last action may run to the end of the arguments
--- @field placeholders string[] substrings replaced by a match's path
--- @field escapes string[] substrings that make an action word unresolved
--- @field appends_path boolean an action without a placeholder gets the path appended

--- Commands that run action commands. find per BSD find(1) and the GNU
--- findutils manual. fd per `fd --help` (10.5.0).
--- @type table<string, agentic.utils.ShellParse.ActionSpec>
local ACTION_HOSTS = {
    find = {
        opts = { "-exec", "-execdir", "-ok", "-okdir" },
        flag_opts = {
            -- options
            "-H",
            "-L",
            "-P",
            "-E",
            "-X",
            "-d",
            "-s",
            "-x",
            "-depth",
            "-xdev",
            "-mount",
            "-follow",
            "-noleaf",
            "-daystart",
            "-ignore_readdir_race",
            "-noignore_readdir_race",
            "-warn",
            "-nowarn",
            -- tests and actions
            "-empty",
            "-executable",
            "-readable",
            "-writable",
            "-nouser",
            "-nogroup",
            "-true",
            "-false",
            "-prune",
            "-quit",
            "-delete",
            "-print",
            "-print0",
            "-ls",
            -- operators
            "-not",
            "-a",
            "-and",
            "-o",
            "-or",
        },
        pair_opts = { "-fprintf" },
        foreign_cwd_opts = { "-execdir", "-okdir" },
        chdir_opts = {},
        plus_ends = true,
        open_ended = false,
        placeholders = { "{}" },
        escapes = {},
        appends_path = false,
    },
    fd = {
        opts = { "-x", "--exec", "-X", "--exec-batch" },
        flag_opts = {
            "-H",
            "--hidden",
            "-I",
            "--no-ignore",
            "--no-ignore-vcs",
            "--no-require-git",
            "--no-ignore-parent",
            "-u",
            "--unrestricted",
            "-s",
            "--case-sensitive",
            "-i",
            "--ignore-case",
            "-g",
            "--glob",
            "--regex",
            "-F",
            "--fixed-strings",
            "--exact",
            "-a",
            "--absolute-path",
            "-l",
            "--list-details",
            "-L",
            "--follow",
            "-p",
            "--full-path",
            "-0",
            "--print0",
            "--prune",
            "-1",
            "-q",
            "--quiet",
            "--show-errors",
            "--hyperlink",
            "--strip-cwd-prefix",
            "--one-file-system",
        },
        pair_opts = {},
        foreign_cwd_opts = {},
        chdir_opts = { "-C", "--base-directory" },
        plus_ends = false,
        open_ended = true,
        placeholders = { "{}", "{/}", "{//}", "{.}", "{/.}" },
        escapes = { "{{", "}}" },
        appends_path = true,
    },
}

--- Stand-in word for the path an action receives at runtime. The obscure name
--- avoids a variable assigned earlier in the command.
local EXEC_PATH = "$__exec_path"

--- Whether `word` contains any of `substrings`.
--- @param word string
--- @param substrings string[]
--- @return boolean
local function contains_any(word, substrings)
    return vim.iter(substrings):any(function(s)
        return word:find(s, 1, true) ~= nil
    end)
end

--- The words of each action command of an action host.
---
--- Fails closed wherever the host may read the words differently: an action
--- word that is dynamic (it may expand to the terminator), that starts with
--- `;` or (after `{}`) `+` without being the terminator, or that holds an
--- escape; and an action option that an option before it may take as its
--- value: directly after a dynamic word, `--`, or a dash-word that is neither
--- a valueless option nor a self-contained `--opt=value`, or second after a
--- two-value option. An option token inside an action is a word of it.
--- @param args string[] delivered words after the host name
--- @param args_dynamic boolean[] parallel to `args`
--- @param spec agentic.utils.ShellParse.ActionSpec
--- @return { first: integer, last: integer, opt: string }[]|nil spans index
---         range into `args` of each action's words (without the option and
---         terminator) and its option, in order. nil when unresolved, an
---         action is empty, or an action that may not run to the end of the
---         arguments has no terminator.
local function action_spans(args, args_dynamic, spec)
    local spans = {}
    local i = 1
    while i <= #args do
        local opt = args[i]
        if vim.list_contains(spec.opts, opt) then
            local prev = args[i - 1]
            if
                args_dynamic[i - 1]
                or (prev and prev:sub(1, 1) == "-" and not vim.list_contains(
                    spec.flag_opts,
                    prev
                ) and not prev:match("^%-%-[^=]+="))
                or vim.list_contains(spec.pair_opts, args[i - 2])
            then
                return nil
            end
            local first = i + 1
            local j = first
            local ended = false
            while j <= #args do
                local word = args[j]
                local plus_ends = spec.plus_ends and args[j - 1] == "{}"
                if word == ";" or (plus_ends and word == "+") then
                    ended = true
                    break
                end
                if
                    args_dynamic[j]
                    or word:sub(1, 1) == ";"
                    or (plus_ends and word:sub(1, 1) == "+")
                    or contains_any(word, spec.escapes)
                then
                    return nil
                end
                j = j + 1
            end
            if j == first or not (ended or spec.open_ended) then
                return nil
            end
            table.insert(spans, { first = first, last = j - 1, opt = opt })
            i = j + 1
        else
            i = i + 1
        end
    end
    return spans
end

--- Whether `word` sets one of `opts`: the option itself, its `--opt=value`
--- form, or a short option anywhere in a single-dash cluster.
--- @param word string
--- @param opts string[] long options and one-letter short options
--- @return boolean
local function sets_option(word, opts)
    return vim.iter(opts):any(function(opt)
        if vim.startswith(opt, "--") then
            return word == opt or vim.startswith(word, opt .. "=")
        end
        return word:match("^%-[^-]") ~= nil
            and word:find(opt:sub(2), 2, true) ~= nil
    end)
end

--- @class agentic.utils.ShellParse.HostActions
--- @field inner string one action per line. A word that holds a placeholder is `$__exec_path`, other words are their delivered text in single quotes, so the inner runs each as the word it is (find does not parse shell: `X=1` is a program name). On an `appends_path` host, an action without a placeholder ends with ` $__exec_path`.
--- @field args string[] the host's own tokens (no action option, word or terminator)
--- @field args_dynamic boolean[] parallel to `args`
--- @field foreign_cwd boolean some action runs outside the cwd

--- Split an action host (`find -exec`, `fd -x`) into its action commands and
--- its own tokens. Placeholders, terminators and escapes are read on the
--- delivered word. A word that holds a placeholder becomes a dynamic token as
--- a whole, since a match's path is runtime data.
--- @param cmd_name string command name, already path-stripped
--- @param args string[] delivered words after the name
--- @param args_dynamic boolean[] parallel to `args`
--- @return agentic.utils.ShellParse.HostActions|nil actions nil when
---         `cmd_name` is no action host, it has no action, or an action does
---         not resolve: it is empty or unterminated, holds a dynamic word or an
---         escape, or its option may be the value of an option before it
function M.host_actions(cmd_name, args, args_dynamic)
    local spec = ACTION_HOSTS[cmd_name]
    local spans = spec and action_spans(args, args_dynamic, spec)
    if not spans or #spans == 0 then
        return nil
    end
    local lines = {}
    --- @type table<integer, true>
    local action_tokens = {}
    local foreign_cwd = false
    for _, span in ipairs(spans) do
        local words = {}
        local has_placeholder = false
        for k = span.first, span.last do
            if contains_any(args[k], spec.placeholders) then
                has_placeholder = true
                table.insert(words, EXEC_PATH)
            else
                table.insert(words, "'" .. args[k]:gsub("'", [['\'']]) .. "'")
            end
        end
        if spec.appends_path and not has_placeholder then
            table.insert(words, EXEC_PATH)
        end
        table.insert(lines, table.concat(words, " "))
        for k = span.first - 1, span.last + 1 do
            action_tokens[k] = true
        end
        foreign_cwd = foreign_cwd
            or vim.list_contains(spec.foreign_cwd_opts, span.opt)
    end
    --- @type agentic.utils.ShellParse.HostActions
    local actions = {
        inner = table.concat(lines, "\n"),
        args = {},
        args_dynamic = {},
        foreign_cwd = foreign_cwd,
    }
    for k, arg in ipairs(args) do
        if not action_tokens[k] then
            table.insert(actions.args, arg)
            table.insert(actions.args_dynamic, args_dynamic[k])
            actions.foreign_cwd = actions.foreign_cwd
                or sets_option(arg, spec.chdir_opts)
        end
    end
    return actions
end

--- @alias agentic.utils.ShellParse.Origin [integer, integer]

--- The shell code in word `i`, quote-stripped.
--- @param i integer
--- @param args string[] quote-stripped arg tokens
--- @param arg_nodes TSNode[] parallel to `args`
--- @param args_dynamic boolean[] parallel to `args`
--- @return string|nil code nil when the word is missing or dynamic
--- @return agentic.utils.ShellParse.Origin|nil origin source position of the
---         code's first byte. Only a single-quoted word (`raw_string`) has
---         one: any other quoting (double, `$'...'`, concatenation) processes
---         the code, so its bytes do not map 1:1 to the source.
local function code_word(i, args, arg_nodes, args_dynamic)
    if args[i] == nil or args_dynamic[i] then
        return nil, nil
    end
    if arg_nodes[i]:type() ~= "raw_string" then
        return args[i], nil
    end
    local sr, sc = arg_nodes[i]:range()
    return args[i], { sr, sc + 1 }
end

--- Resolve the inner command to recurse into for a transparent prefix — an
--- inline shell `-c '<body>'` or an exec-wrapper (`timeout`/`time`/`stdbuf`).
--- Returns nil to fall through to the leaf matchers (not a shell or
--- wrapper, missing/dynamic body, malformed operands, empty inner, an inner
--- that starts past `node`'s end).
---
--- The `-c` body, and a wrapper's `code_opts` value, is the quote-stripped
--- word, with an origin only when it is single-quoted (a `-c` may be the
--- trailing letter of a short-flag cluster like `-lc`, still consuming the
--- next word). The wrapper inner is a raw substring
--- of `src` (quotes/escapes intact) from the inner node's start to the wrapper
--- command node's end, then `trailing`, with the inner node's `(row, col)` as
--- origin for translating tally ranges.
--- @param cmd_name string command name, already path-stripped
--- @param node TSNode the `command` node
--- @param args string[] quote-stripped arg tokens
--- @param arg_nodes TSNode[] the arg token nodes, parallel to `args`
--- @param args_dynamic boolean[]
--- @param src string
--- @param wrappers table<string, agentic.utils.ShellParse.WrapperSpec>|nil
---        exec-wrapper specs, default `EXEC_WRAPPERS`
--- @param trailing string|nil source of the words of the command that lie
---        past `node`'s end, each with a leading space
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
    wrappers,
    trailing
)
    if SHELL_C_COMMANDS[cmd_name] then
        for i, arg in ipairs(args) do
            if arg:match("^%-[a-zA-Z]*c$") then
                local body, origin =
                    code_word(i + 1, args, arg_nodes, args_dynamic)
                return body, origin, false
            end
        end
        return nil, nil, false
    end

    local spec = (wrappers or EXEC_WRAPPERS)[cmd_name]
    if not spec then
        return nil, nil, false
    end
    local operands = skip_wrapper_operands(args, spec)
    if not operands then
        return nil, nil, false
    end
    if operands.code then
        local code, origin =
            code_word(operands.i_inner, args, arg_nodes, args_dynamic)
        return code, origin, spec.writes or false
    end
    local inner_node = arg_nodes[operands.i_inner]
    if not inner_node then
        return nil, nil, false -- empty inner
    end
    local sr, sc, inner_start_byte = inner_node:range(true)
    local _, _, _, _, _, node_end_byte = node:range(true)
    if inner_start_byte >= node_end_byte then
        return nil, nil, false -- inner starts in `trailing`
    end
    local inner = src:sub(inner_start_byte + 1, node_end_byte)
        .. (trailing or "")
    if cmd_name == "xargs" then
        -- Model the runtime stdin items as a dynamic token (see EXEC_WRAPPERS).
        -- The obscure name avoids resolving against an earlier sequence binding.
        inner = inner .. " $__xargs_stdin"
    end
    return inner, { sr, sc }, spec.writes or false
end

--- Resolve a path token to a canonical absolute path, so two spellings of one
--- file compare equal as strings. Expands a leading `~` (a `$VAR` is literal
--- text), joins a relative path to the cwd, collapses `.`/`..`, and resolves symlinks in the
--- parent directory (on macOS `/tmp/f` gives `/private/tmp/f`). The last
--- component is kept as written because the file may not exist yet. When the
--- parent does not exist, the result is the lexical form.
--- @param path string
--- @return string
local function resolve_against_cwd(path)
    path = vim.fs.normalize(vim.fs.abspath(path), { expand_env = false })
    local real_parent = vim.uv.fs_realpath(vim.fs.dirname(path))
    return real_parent and vim.fs.joinpath(real_parent, vim.fs.basename(path))
        or path
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

--- What a statement's redirects give one node of it.
--- @class agentic.utils.ShellParse.NodeIO
--- @field stdin? agentic.utils.ShellParse.Heredoc the heredoc a `command` reads on stdin
--- @field redirects? agentic.utils.ShellParse.Redirect[] the file redirects and herestrings applied to the node, in order
--- @field words? TSNode[] words of the node's command that the grammar put on its redirects

--- Map each node a redirected statement's redirects apply to, to what they
--- give it. The grammar hangs them on the whole list or pipeline, but the shell
--- applies them to its last element. Only a simple command reads a heredoc on
--- stdin: a heredoc on a non-zero fd, or on a compound statement, subshell or
--- `negated_command`, has no reader.
---
--- tree-sitter-zsh parses the words after a file redirect's target as further
--- `destination` children of the `file_redirect` (`rm a 2>/dev/null b` →
--- destinations `/dev/null` and `b`); they go to `words`.
--- @param root TSNode
--- @param src string
--- @return table<string, agentic.utils.ShellParse.NodeIO> io keyed by `node:id()`
local function node_io(root, src)
    --- @type table<string, agentic.utils.ShellParse.NodeIO>
    local io_of = {}
    local function visit(node)
        if node:type() == "redirected_statement" then
            local target = node:field("body")[1]
            while
                target
                and (target:type() == "list" or target:type() == "pipeline")
            do
                target = target:named_child(target:named_child_count() - 1)
            end
            if target then
                --- @type agentic.utils.ShellParse.NodeIO
                local io = { redirects = {}, words = {} }
                for _, r in ipairs(node:field("redirect")) do
                    local fd = r:field("descriptor")[1]
                    if r:type() == "heredoc_redirect" then
                        if
                            target:type() == "command"
                            and (
                                not fd
                                or vim.treesitter.get_node_text(fd, src)
                                    == "0"
                            )
                        then
                            io.stdin = heredoc_text(r, src)
                        end
                    else
                        table.insert(io.redirects, redirect_record(r, src))
                        vim.list_extend(
                            io.words,
                            vim.list_slice(r:field("destination"), 2)
                        )
                    end
                end
                io_of[target:id()] = io
            end
        end
        for child in node:iter_children() do
            visit(child)
        end
    end
    visit(root)
    return io_of
end

--- The directory a shell is in after `cd` with the given operands. No `..`
--- or `~` resolution (`/a/../b` stays as is, `~` stays unexpanded).
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
    return vim.fs.joinpath(cwd, dir)
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

--- Transparent prefixes whose inner runs in the current shell, not a child.
local SAME_SHELL_PREFIXES = {
    eval = true,
    builtin = true,
    exec = true,
    noglob = true,
    nocorrect = true,
}

--- Whether a command that was not unwrapped still runs code given in its
--- arguments: an `eval`, a shell with `-c`, an action option of an
--- `ACTION_HOSTS` command, or a launcher in `VISIBLE_WRAPPERS` unless its
--- operands resolve to no inner command.
--- @param cmd_name string
--- @param args string[] quote-stripped arg tokens
--- @return boolean
local function names_unseen_command(cmd_name, args)
    if #args == 0 then
        return false
    end
    if cmd_name == "eval" then
        return true
    end
    if SHELL_C_COMMANDS[cmd_name] then
        return vim.tbl_contains(args, function(arg)
            return arg:match("^%-[a-zA-Z]*c$") ~= nil
        end, { predicate = true })
    end
    if ACTION_HOSTS[cmd_name] then
        return vim.iter(args):any(function(arg)
            return vim.list_contains(ACTION_HOSTS[cmd_name].opts, arg)
        end)
    end
    local spec = VISIBLE_WRAPPERS[cmd_name]
    if
        not spec
        or (spec.subcommand and not vim.list_contains(args, spec.subcommand))
    then
        return false
    end
    local operands = skip_wrapper_operands(args, spec)
    return not operands or operands.code or args[operands.i_inner] ~= nil
end

--- What a command inherits from the statements and launchers enclosing it.
--- @class agentic.utils.ShellParse.Enclosing
--- @field redirects agentic.utils.ShellParse.Redirect[] in the order the shell applies them, outermost first
--- @field assignments table<string, agentic.utils.ShellParse.Assignment> the prefix assignments and `env` operands of the launchers

--- Forward declaration — `collect` and `collect_command` are mutually recursive.
--- @type fun(node: TSNode, src: string, out: agentic.ShellCommand[], depth: integer, shell: agentic.utils.ShellParse.Shell, io_of: table<string, agentic.utils.ShellParse.NodeIO>, enclosing: agentic.utils.ShellParse.Enclosing): boolean
local collect

--- `collect` over each node in turn, stopping at the first failure.
--- @param nodes TSNode[]
--- @param src string
--- @param out agentic.ShellCommand[]
--- @param depth integer
--- @param shell agentic.utils.ShellParse.Shell
--- @param io_of table<string, agentic.utils.ShellParse.NodeIO>
--- @param enclosing agentic.utils.ShellParse.Enclosing
--- @return boolean ok
local function collect_each(nodes, src, out, depth, shell, io_of, enclosing)
    for _, node in ipairs(nodes) do
        if not collect(node, src, out, depth, shell, io_of, enclosing) then
            return false
        end
    end
    return true
end

--- Parse `inner` and `collect` it one level deeper, with `launcher` prepended
--- to the `via` of every record it adds.
--- @param inner string the source the launcher runs
--- @param launcher string
--- @param out agentic.ShellCommand[]
--- @param depth integer the launcher's depth
--- @param shell agentic.utils.ShellParse.Shell state of the shell running `inner`
--- @param stdin agentic.utils.ShellParse.Heredoc|nil heredoc the inner reads
---        on stdin when it is a single command
--- @param enclosing agentic.utils.ShellParse.Enclosing what `inner` inherits
--- @return boolean ok false also when `depth` is at the nesting cap or
---         `inner` does not parse
local function collect_unwrapped(
    inner,
    launcher,
    out,
    depth,
    shell,
    stdin,
    enclosing
)
    if depth >= NESTED_MAX_DEPTH then
        return false
    end
    local root = ZshParse.parse(inner)
    if not root then
        return false
    end
    local inner_io_of = node_io(root, inner)
    local inner_cmd = root:named_child(0)
    if
        stdin
        and root:named_child_count() == 1
        and inner_cmd
        and inner_cmd:type() == "command"
    then
        inner_io_of[inner_cmd:id()] = inner_io_of[inner_cmd:id()] or {}
        inner_io_of[inner_cmd:id()].stdin = stdin
    end
    local first = #out + 1
    local ok =
        collect(root, inner, out, depth + 1, shell, inner_io_of, enclosing)
    for i = first, #out do
        table.insert(out[i].via, 1, launcher)
    end
    return ok
end

--- Process a `command` node: resolve its name, unwrap transparent prefixes
--- (exec-wrapper / inline `-c` body) by re-parsing the inner, else emit an
--- `agentic.ShellCommand` record. Substitutions in arguments, in an
--- env-prefix value or in a redirect are flattened by recursing `collect` over
--- them, so a live `git commit -m "$(rm -rf /)"` yields both `git` and the
--- inner `rm`. They inherit `enclosing` only: the command's own redirects and
--- assignments do not apply to them. An unwrapped launcher's argument
--- substitutions are walked inside its inner, with what the inner inherits.
--- @param node TSNode
--- @param src string
--- @param out agentic.ShellCommand[]
--- @param depth integer
--- @param shell agentic.utils.ShellParse.Shell state of the shell running
---        `node`, updated in place by `cd`, `pushd` and `popd`
--- @param io_of table<string, agentic.utils.ShellParse.NodeIO> what the
---        statements' redirects in `src` give each node, keyed by `node:id()`
--- @param enclosing agentic.utils.ShellParse.Enclosing
--- @return boolean ok
local function collect_command(node, src, out, depth, shell, io_of, enclosing)
    local io = io_of[node:id()] or {}
    local name_node
    --- @type string[]
    local args = {}
    --- @type TSNode[]
    local arg_nodes = {}
    --- @type boolean[]
    local args_dynamic = {}
    -- Substitution-bearing subtrees: the env-prefix values and redirects
    -- before the name, which an unwrapped inner does not contain, then the
    -- arguments (bare `$(...)`, embedded `"$(…)"`). Flattened *after* this
    -- command's own record so inner commands follow the outer one in
    -- extraction order.
    --- @type TSNode[]
    local prefix_flatten = {}
    --- @type TSNode[]
    local to_flatten = {}
    local redirects = vim.list_slice(enclosing.redirects)
    local assignments = vim.tbl_extend("force", {}, enclosing.assignments)

    --- Append an argument word.
    --- @param word TSNode
    --- @return boolean ok false when the word has no token text
    local function add_arg(word)
        if subtree_has_substitution(word) then
            -- A substitution (`$(…)`, `"$(…)"`, concatenation): opaque dynamic
            -- token; inner flattens separately.
            table.insert(to_flatten, word)
            table.insert(args, vim.treesitter.get_node_text(word, src))
            table.insert(arg_nodes, word)
            table.insert(args_dynamic, true)
            return true
        end
        local tok = literal_token(word, src)
        if tok == nil then
            return false
        end
        table.insert(args, tok)
        table.insert(arg_nodes, word)
        table.insert(args_dynamic, token_is_dynamic(word))
        return true
    end

    for child, field in node:iter_children() do
        local t = child:type()
        if t == "command_name" then
            name_node = child
        elseif t == "variable_assignment" then
            -- Env prefix (`FOO=bar cmd`): not a command, but its value may carry
            -- a live substitution.
            if subtree_has_substitution(child) then
                table.insert(prefix_flatten, child)
            end
            local name, assignment = assignment_record(child, src)
            assignments[name] = assignment
        elseif
            field == "redirect"
            and (t == "file_redirect" or t == "herestring_redirect")
        then
            -- A redirect before the name (`> f cmd`).
            if subtree_has_substitution(child) then
                table.insert(prefix_flatten, child)
            end
            table.insert(redirects, redirect_record(child, src))
            for _, word in ipairs(vim.list_slice(child:field("destination"), 2)) do
                if not add_arg(word) then
                    return false
                end
            end
        elseif child:named() and t ~= "comment" then
            if not add_arg(child) then
                return false
            end
        end
    end
    vim.list_extend(redirects, io.redirects or {})
    -- Words past the node's end, which an unwrapped inner must get back.
    --- @type string[]
    local trailing = {}
    for _, word in ipairs(io.words or {}) do
        if not add_arg(word) then
            return false
        end
        table.insert(trailing, " " .. vim.treesitter.get_node_text(word, src))
    end

    if not name_node then
        return false
    end
    if name_is_dynamic(name_node) then
        -- A dynamic name is no evidence of any particular command: no record,
        -- but the substitutions in its name and arguments still run.
        return collect_each(
            vim.list_extend({ name_node, unpack(prefix_flatten) }, to_flatten),
            src,
            out,
            depth,
            shell,
            io_of,
            enclosing
        )
    end
    local name = command_name_text(name_node, src)
    if not name then
        return false
    end
    local cmd_name = strip_command_path(name)
    args, arg_nodes, args_dynamic =
        M.join_adjacent_args(args, arg_nodes, args_dynamic, src)

    -- Transparent prefix: re-parse and flatten the inner instead of emitting the
    -- wrapper/shell itself, so `timeout 5 rm -f x` and `zsh -c 'rm -f x'` both
    -- yield a record for `rm`. An `eval` of static words runs those words,
    -- joined by spaces, as code.
    local inner
    if cmd_name == "eval" then
        inner = not vim.list_contains(args_dynamic, true)
            and table.concat(args, " ")
    else
        inner = inner_source(
            cmd_name,
            node,
            args,
            arg_nodes,
            args_dynamic,
            src,
            VISIBLE_WRAPPERS,
            table.concat(trailing)
        )
    end
    --- @type agentic.utils.ShellParse.Enclosing
    local inherited = { redirects = redirects, assignments = assignments }
    if inner and inner ~= "" then
        local spec = VISIBLE_WRAPPERS[cmd_name]
        local operands = spec
            and spec.assignments
            and skip_wrapper_operands(args, spec)
        for _, i in ipairs(operands and operands.i_assignments or {}) do
            local var, value = args[i]:match("^([^=]*)=(.*)$")
            assignments[var] = { value = value, dynamic = args_dynamic[i] }
        end
        -- Most inners run in a process of their own, so their `cd` does not
        -- leak out. The wrapper's stdin reaches the inner, except xargs' (read
        -- as its argument list).
        return collect_unwrapped(
            inner,
            cmd_name,
            out,
            depth,
            SAME_SHELL_PREFIXES[cmd_name] and shell or { cwd = shell.cwd },
            not SHELL_C_COMMANDS[cmd_name] and cmd_name ~= "xargs" and io.stdin
                or nil,
            inherited
        ) and collect_each(
            prefix_flatten,
            src,
            out,
            depth,
            shell,
            io_of,
            enclosing
        )
    end

    -- An action host is still a record of its own, without its actions.
    local actions = M.host_actions(cmd_name, args, args_dynamic)
    if actions then
        args, args_dynamic = actions.args, actions.args_dynamic
    end

    --- @type agentic.ShellCommand
    local rec = {
        name = cmd_name,
        flags = {},
        args = {},
        argv = args,
        argv_dynamic = args_dynamic,
        stdin = io.stdin,
        redirects = #redirects > 0 and redirects or nil,
        assignments = next(assignments) and assignments or nil,
        cwd = shell.cwd,
        via = {},
        opaque = names_unseen_command(cmd_name, args) or nil,
    }
    for _, tok in ipairs(args) do
        classify_token(tok, rec.flags, rec.args)
    end
    table.insert(out, rec)

    if
        actions
        and not collect_unwrapped(
            actions.inner,
            cmd_name,
            out,
            depth,
            { cwd = not actions.foreign_cwd and shell.cwd },
            nil,
            inherited
        )
    then
        return false
    end
    if
        not collect_each(
            vim.list_extend(prefix_flatten, to_flatten),
            src,
            out,
            depth,
            shell,
            io_of,
            enclosing
        )
    then
        return false
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
--- @param io_of table<string, agentic.utils.ShellParse.NodeIO> what the
---        statements' redirects in `src` give each node, keyed by `node:id()`
--- @param enclosing agentic.utils.ShellParse.Enclosing what `node` inherits
--- @return boolean ok
function collect(node, src, out, depth, shell, io_of, enclosing)
    local t = node:type()
    if t == "command" then
        return collect_command(node, src, out, depth, shell, io_of, enclosing)
    end
    if CHILD_SHELL_TYPES[t] then
        shell = { cwd = shell.cwd }
    end
    local io = io_of[node:id()]
    if io then
        -- Words after a compound statement's redirect: zsh rejects the line.
        if io.words and #io.words > 0 then
            return false
        end
        enclosing = {
            redirects = vim.list_extend(
                vim.list_slice(enclosing.redirects),
                io.redirects or {}
            ),
            assignments = enclosing.assignments,
        }
    end
    -- Every other node (containers, pipelines, control flow, redirected
    -- statements, assignments, substitutions): recurse named children. A
    -- redirect target / env prefix does not hide a command, so we never bail
    -- here — only `collect_command` decides safety.
    local children = node:named_children()
    if t == "file_redirect" then
        -- The later destinations are words of the command (see `node_io`).
        children = { node:field("destination")[1] }
    end
    --- @type integer[]|nil indices in `out` of the previous pipeline element's records
    local upstream
    for _, child in ipairs(children) do
        if child:type() ~= "comment" then
            local child_shell = runs_in_child_shell(node, child)
                    and { cwd = shell.cwd }
                or shell
            local first = #out + 1
            if
                not collect(
                    child,
                    src,
                    out,
                    depth,
                    child_shell,
                    io_of,
                    enclosing
                )
            then
                return false
            end
            if t == "pipeline" then
                -- An inner pipeline has already set its own downstream elements.
                for i = first, #out do
                    out[i].pipe_from = out[i].pipe_from or upstream
                end
                upstream = {}
                for i = first, #out do
                    table.insert(upstream, i)
                end
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
--- @field argv_dynamic boolean[] parallel to `argv`: true where the token is not a static literal (expansion, substitution, xargs' stand-in `$__xargs_stdin`, an action's path `$__exec_path`)
--- @field stdin? agentic.utils.ShellParse.Heredoc the heredoc this command reads on stdin
--- @field redirects? agentic.utils.ShellParse.Redirect[] every file redirect and herestring the shell applies to this command, in the order it applies them: those of the compound statements and launchers enclosing it, outermost first, then its own. A list or pipeline's redirect applies to its last command. Heredocs are in `stdin`. nil when none.
--- @field assignments? table<string, agentic.utils.ShellParse.Assignment> the prefix assignments in effect for this command (`IFS=$'\t' read` → `IFS`), its launchers' prefix assignments and `env` operands included. nil when none.
--- @field cwd? string|false the directory this command starts in, after earlier `cd`s in the same shell. Not normalised, and relative to the caller's cwd when relative. nil = no `cd` yet, false = unknown. A `cd` in a branch or loop counts as if it always ran.
--- @field opaque? true the command runs code from its arguments that extraction could not unwrap (`eval "$x"`, `sudo -i …`, `zsh -c "$x"`), so `argv` holds commands no record shows
--- @field via string[] the launchers, `-c` shells and static `eval`s this command was unwrapped from, outermost first (`timeout 5 uv run x` → `{ "timeout", "uv" }`)
--- @field pipe_from? integer[] indices, in the same record list, of the records of the pipeline element before this command's, whose output its stdin reads. Every record inside a pipeline element, its substitutions included, gets them. nil outside a pipeline and in its first element.

--- Extract the flat list of statically-resolvable commands a shell string would
--- run — across pipelines, control flow, launchers (`VISIBLE_WRAPPERS`), inline
--- `-c` bodies, `eval`s of static words, and live command substitutions. Each
--- record is normalised to an `agentic.ShellCommand`.
---
--- A command with a dynamic name (`$cmd -f x`) gets no record, but the
--- commands in the substitutions of its name and arguments still do. `source`
--- and `.` are records like any other: their code is not walked. A command
--- that runs code extraction could not unwrap (an `eval` with a dynamic
--- argument, a launcher with an unknown option) is a record marked `opaque`.
---
--- An empty or over-64-KiB `src`, a parse error, an absent parser, an `ERROR`
--- node, an unextractable token or unwrapping nested past `NESTED_MAX_DEPTH`
--- returns `nil`: what runs is unknown. `{}` means "parsed, no command" (a
--- bare string).
--- @param src string
--- @return agentic.ShellCommand[]|nil records nil = what runs is unknown
function M.extract_commands(src)
    local root = ZshParse.parse_command(src)
    if not root then
        return nil
    end
    --- @type agentic.ShellCommand[]
    local out = {}
    if
        not collect(
            root,
            src,
            out,
            0,
            {},
            node_io(root, src),
            { redirects = {}, assignments = {} }
        )
    then
        return nil
    end
    return out
end

-- ── Shared primitives consumed by permission_rules.walk / tally_walk ─────────

M.strip_command_path = strip_command_path
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
