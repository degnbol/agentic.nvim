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
--- Zero plugin requires (only `vim.treesitter`) so it loads under `nvim -u NONE`
--- with just the plugin on the runtimepath — no `Config`/runtime pulled in.
---
--- Node-type names are pinned to the installed tree-sitter-zsh grammar (verified
--- 2026-06-18). They can drift across grammar versions — re-verify with a
--- parse-tree dump after upgrading the parser.

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

--- Strict literal extraction: every byte of the returned string must be
--- exactly what the shell delivers to the program. Returns nil if any subtree
--- contains a variable expansion or substitution. Used as the recursive step
--- inside `concatenation` — joining `-ex"$x"c` would otherwise launder a
--- dynamic flag past the matcher.
--- @param node TSNode
--- @param src string
--- @return string|nil
local function pure_literal_token(node, src)
    local t = node:type()
    if t == "word" or t == "number" or t == "glob_pattern" then
        return vim.treesitter.get_node_text(node, src)
    end
    if t == "string" then
        local parts = {}
        for c in node:iter_children() do
            if c:named() then
                if c:type() ~= "string_content" then
                    return nil
                end
                table.insert(parts, vim.treesitter.get_node_text(c, src))
            end
        end
        return table.concat(parts)
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
        -- string composed only of `string_content` joins to its quote-stripped
        -- literal (so `"rm"` cannot evade a deny pattern). A string that
        -- mixes `string_content` with expansions yields the raw quoted text,
        -- preserving Phase 1a glob matching.
        local has_non_content = false
        local parts = {}
        for c in node:iter_children() do
            if c:named() then
                if c:type() == "string_content" then
                    table.insert(parts, vim.treesitter.get_node_text(c, src))
                else
                    has_non_content = true
                end
            end
        end
        if has_non_content then
            return vim.treesitter.get_node_text(node, src)
        end
        return table.concat(parts)
    end
    if t == "concatenation" then
        return pure_literal_token(node, src)
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
--- Only called on tokens `literal_token` already accepted, so substitution-
--- bearing nodes (rejected at the command level) never reach here, and a
--- `concatenation` that survived is necessarily all-literal.
--- @param node TSNode
--- @return boolean
local function token_is_dynamic(node)
    local t = node:type()
    if
        t == "glob_pattern"
        or t == "variable_ref"
        or t == "simple_expansion"
        or t == "expansion"
        or t == "arithmetic_expansion"
    then
        return true
    end
    if t == "string" then
        for c in node:iter_children() do
            if c:named() and c:type() ~= "string_content" then
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
    if (op == ">&" or op == "<&") and (dt == "file_descriptor" or dt == "number") then
        return nil
    end
    if vim.treesitter.get_node_text(dest, src) == "/dev/null" then
        return nil
    end
    return dest
end

-- ── Parsing ──────────────────────────────────────────────────────────────────

--- Parse a command string with the zsh grammar. Returns the root node, or nil
--- on missing parser / parse error / any error node (fail-closed). Shared by the
--- decision walk, the tally walk, and the inline `-c` body recursion.
--- @param src string
--- @return TSNode|nil
local function parse_zsh(src)
    local ok, root = pcall(function()
        local parser = vim.treesitter.get_string_parser(src, "zsh")
        return parser:parse(true)[1]:root()
    end)
    if not ok or not root or root:has_error() then
        return nil
    end
    return root
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
--- `xargs`/`parallel` run a command per input. These are left to match no allow
--- rule (so they prompt) rather than recursed — and must NOT be given a blanket
--- read-only entry in `permissions.json`, which would auto-approve whatever they
--- launch without the matcher ever inspecting it.
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
}

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
                or (spec.attached and matches_any_lua_pattern(opt, spec.attached))
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
--- @return string|nil inner
--- @return agentic.utils.ShellParse.Origin|nil origin
--- @return boolean writes whether the prefix has a recoverable side effect of its
---         own (the wrapper's `writes` flag); false for shells (`-c` bodies are
---         vetted command-by-command in the recursion).
local function inner_source(cmd_name, node, args, arg_nodes, args_dynamic, src)
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

    local spec = EXEC_WRAPPERS[cmd_name]
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
    return src:sub(inner_start_byte + 1, node_end_byte), { sr, sc }, spec.writes or false
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

--- Forward declaration — `collect` and `collect_command` are mutually recursive.
--- @type fun(node: TSNode, src: string, out: agentic.ShellCommand[], depth: integer): boolean
local collect

--- Process a `command` node: resolve its name, unwrap transparent prefixes
--- (exec-wrapper / inline `-c` body) by re-parsing the inner, else emit a
--- `{name, flags, args}` record. Substitutions in arguments or in an env-prefix
--- value are flattened by recursing `collect` over them, so a live
--- `git commit -m "$(rm -rf /)"` yields both `git` and the inner `rm`.
--- @param node TSNode
--- @param src string
--- @param out agentic.ShellCommand[]
--- @param depth integer
--- @return boolean ok
local function collect_command(node, src, out, depth)
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

    -- Transparent prefix: re-parse and flatten the inner instead of emitting the
    -- wrapper/shell itself, so `timeout 5 rm -f x` and `zsh -c 'rm -f x'` both
    -- yield a record for `rm`.
    local inner = inner_source(cmd_name, node, args, arg_nodes, args_dynamic, src)
    if inner and inner ~= "" then
        if depth >= NESTED_MAX_DEPTH then
            return false
        end
        local root = parse_zsh(inner)
        if not root then
            return false
        end
        return collect(root, inner, out, depth + 1)
    end

    --- @type agentic.ShellCommand
    local rec = { name = cmd_name, flags = {}, args = {} }
    for _, tok in ipairs(args) do
        classify_token(tok, rec.flags, rec.args)
    end
    table.insert(out, rec)

    for _, sub in ipairs(to_flatten) do
        if not collect(sub, src, out, depth) then
            return false
        end
    end
    return true
end

--- @param node TSNode
--- @param src string
--- @param out agentic.ShellCommand[]
--- @param depth integer
--- @return boolean ok
function collect(node, src, out, depth)
    if node:type() == "command" then
        return collect_command(node, src, out, depth)
    end
    -- Every other node (containers, pipelines, control flow, redirected
    -- statements, assignments, substitutions): recurse named children. A
    -- redirect target / env prefix does not hide a command, so we never bail
    -- here — only `collect_command` decides safety.
    for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            if not collect(child, src, out, depth) then
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

--- Extract the flat list of statically-resolvable commands a shell string would
--- run — across pipelines, control flow, exec-wrappers, inline `-c` bodies, and
--- live command substitutions. Each record is normalised to
--- `{ name, flags, args }`.
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
    if not collect(root, src, out, 0) then
        return nil
    end
    return out
end

-- ── Shared primitives consumed by permission_rules.walk / tally_walk ─────────

M.strip_command_path = strip_command_path
M.parse_zsh = parse_zsh
M.subtree_has_substitution = subtree_has_substitution
M.safe_assignment_name = safe_assignment_name
M.pure_literal_token = pure_literal_token
M.literal_token = literal_token
M.token_is_dynamic = token_is_dynamic
M.command_name_text = command_name_text
M.redirect_is_safe = redirect_is_safe
M.redirect_write_dest = redirect_write_dest
M.inner_source = inner_source
M.script_file_source = script_file_source
M.resolve_against_cwd = resolve_against_cwd
M.CONTAINER_TYPES = CONTAINER_TYPES
M.SUBSTITUTION_TYPES = SUBSTITUTION_TYPES
M.SUBSTITUTION_INNER_STATEMENT_TYPES = SUBSTITUTION_INNER_STATEMENT_TYPES
M.CODE_TAKING_BUILTINS = CODE_TAKING_BUILTINS
M.NESTED_MAX_DEPTH = NESTED_MAX_DEPTH

return M
