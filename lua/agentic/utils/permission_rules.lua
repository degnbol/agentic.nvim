local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.utils.PermissionRules
local M = {}

-- Structural shell-parse primitives live once in shell_parse.lua. The `walk` and
-- `tally_walk` traversals below decide auto-approval on top of these; the same
-- module's `extract_commands` builds the flat command list from them.
local ShellParse = require("agentic.utils.shell_parse")
local parse_zsh = ShellParse.parse_zsh
local literal_token = ShellParse.literal_token
local pure_literal_token = ShellParse.pure_literal_token
local command_name_text = ShellParse.command_name_text
local subtree_has_substitution = ShellParse.subtree_has_substitution
local safe_assignment_name = ShellParse.safe_assignment_name
local token_is_dynamic = ShellParse.token_is_dynamic
local redirect_is_safe = ShellParse.redirect_is_safe
local redirect_write_target = ShellParse.redirect_write_target
local inner_source = ShellParse.inner_source
local CONTAINER_TYPES = ShellParse.CONTAINER_TYPES
local SUBSTITUTION_TYPES = ShellParse.SUBSTITUTION_TYPES
local SUBSTITUTION_INNER_STATEMENT_TYPES =
    ShellParse.SUBSTITUTION_INNER_STATEMENT_TYPES
local CODE_TAKING_BUILTINS = ShellParse.CODE_TAKING_BUILTINS
local NESTED_MAX_DEPTH = ShellParse.NESTED_MAX_DEPTH

M.strip_command_path = ShellParse.strip_command_path

--- @alias agentic.utils.PermissionRules.Origin agentic.utils.ShellParse.Origin

--- @class agentic.utils.PermissionRules.CompiledPattern
--- @field original string
--- @field lua_pattern string

--- @type agentic.utils.PermissionRules.CompiledPattern[]|nil
local cached_deny_patterns

--- @type agentic.utils.PermissionRules.CompiledPattern[]|nil
local cached_ask_patterns

--- @type agentic.utils.PermissionRules.CompiledPattern[]|nil
local cached_read_only_patterns

--- @type agentic.utils.PermissionRules.CompiledPattern[]|nil
local cached_safe_write_patterns

--- mtime of each settings.json at last load, keyed by path
--- @type table<string, number>
local cached_mtimes = {}

--- Cached config patterns, keyed by table reference
--- @type table|nil, agentic.utils.PermissionRules.CompiledPattern[]
local cached_config_read_only_ref, cached_config_read_only_patterns = nil, {}
--- @type table|nil, agentic.utils.PermissionRules.CompiledPattern[]
local cached_config_safe_write_ref, cached_config_safe_write_patterns = nil, {}
--- @type table|nil, agentic.utils.PermissionRules.CompiledPattern[]
local cached_config_deny_ref, cached_config_deny_patterns = nil, {}
--- @type table|nil, agentic.utils.PermissionRules.CompiledPattern[]
local cached_config_ask_ref, cached_config_ask_patterns = nil, {}

--- @type agentic.StructuredEntries|nil
local cached_plugin_structured_entries
--- @type number
local cached_plugin_structured_mtime = 0

--- @type table|nil, agentic.StructuredEntries
local cached_config_structured_ref, cached_config_structured_entries = nil, {}

--- Path to bundled permissions.json
--- @return string
local function plugin_permissions_path()
    local mod_path = debug.getinfo(1, "S").source:sub(2)
    local mod_dir = vim.fn.fnamemodify(mod_path, ":h:h")
    return mod_dir .. "/permissions.json"
end

--- Lua pattern magic characters that need escaping
local MAGIC_CHARS = {
    ["."] = "%.",
    ["+"] = "%+",
    ["-"] = "%-",
    ["("] = "%(",
    [")"] = "%)",
    ["["] = "%[",
    ["]"] = "%]",
    ["^"] = "%^",
    ["$"] = "%$",
    ["%"] = "%%",
}

--- Convert a settings.json glob pattern to a Lua pattern. `*` matches any run
--- of characters. The walker hands this matcher a single substitution-free,
--- redirect-free leaf command, so top-level shell operators never reach a
--- pattern (they are sibling separator nodes). The only `|`/`;`/`&` that can
--- arrive is a literal inside a quoted argument, which `*` should match.
--- @param glob string
--- @return string lua_pattern
function M.glob_to_lua_pattern(glob)
    local result = {}
    local i = 1
    while i <= #glob do
        local ch = glob:sub(i, i)
        if ch == "*" then
            table.insert(result, ".*")
        elseif MAGIC_CHARS[ch] then
            table.insert(result, MAGIC_CHARS[ch])
        else
            table.insert(result, ch)
        end
        i = i + 1
    end
    return "^" .. table.concat(result) .. "$"
end

--- Compile a list of `Bash(...)` glob strings into matched patterns. Skips
--- non-Bash entries and malformed strings.
--- @param strings string[]|nil
--- @return agentic.utils.PermissionRules.CompiledPattern[]
local function patterns_from_strings(strings)
    local out = {}
    if type(strings) ~= "table" then
        return out
    end
    for _, entry in ipairs(strings) do
        if type(entry) == "string" then
            local inner = entry:match("^Bash%((.+)%)$")
            if inner then
                table.insert(out, {
                    original = inner,
                    lua_pattern = M.glob_to_lua_pattern(inner),
                })
            end
        end
    end
    return out
end

--- Extract Bash(...) allow patterns from a settings.json permissions table.
--- @param permissions table
--- @param list_key string "allow" or "deny" or "ask"
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function M.extract_bash_patterns(permissions, list_key)
    return patterns_from_strings(permissions[list_key])
end

--- Read and decode a JSON file, returning nil on any error.
--- @param path string
--- @return table|nil
function M.read_json(path)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return nil
    end
    local fd = vim.uv.fs_open(path, "r", 438) -- 0o666
    if not fd then
        return nil
    end
    local data = vim.uv.fs_read(fd, stat.size, 0)
    vim.uv.fs_close(fd)
    if not data then
        return nil
    end
    local ok, result = pcall(vim.json.decode, data)
    if not ok then
        Logger.debug("permission_rules: failed to parse JSON:", path, result)
        return nil
    end
    return result
end

--- Get mtime for a path, or 0 if the file doesn't exist.
--- @param path string
--- @return number
local function get_mtime(path)
    local stat = vim.uv.fs_stat(path)
    if stat then
        return stat.mtime.sec
    end
    return 0
end

--- Resolve the two settings.json paths.
--- @return string global_path
--- @return string project_path
function M.settings_paths()
    local home = vim.uv.os_homedir() or os.getenv("HOME") or ""
    return home .. "/.claude/settings.json", ".claude/settings.json"
end

--- Check if any settings.json has changed since last load.
--- @return boolean
local function settings_changed()
    local global_path, project_path = M.settings_paths()
    return get_mtime(global_path) ~= (cached_mtimes[global_path] or 0)
        or get_mtime(project_path) ~= (cached_mtimes[project_path] or 0)
end

--- Load and cache patterns from all sources:
--- 1. Bundled permissions.json (if Config.permissions.use_plugin_defaults)
--- 2. ~/.claude/settings.json and .claude/settings.json (if Config.permissions.use_claude_settings)
--- 3. Config.permissions.read_only/safe_write/deny/ask (user additions)
--- Re-reads automatically when file mtimes change.
function M.load_patterns()
    if cached_read_only_patterns and not settings_changed() then
        return
    end

    cached_read_only_patterns = {}
    cached_safe_write_patterns = {}
    cached_deny_patterns = {}
    cached_ask_patterns = {}

    local global_path, project_path = M.settings_paths()
    cached_mtimes[global_path] = get_mtime(global_path)
    cached_mtimes[project_path] = get_mtime(project_path)

    -- 1. Load bundled permissions.json
    if Config.permissions.use_plugin_defaults then
        local plugin_path = plugin_permissions_path()
        local plugin_perms = M.read_json(plugin_path)
        if plugin_perms then
            vim.list_extend(
                cached_read_only_patterns,
                M.extract_bash_patterns(plugin_perms, "read_only")
            )
            vim.list_extend(
                cached_safe_write_patterns,
                M.extract_bash_patterns(plugin_perms, "safe_write")
            )
            vim.list_extend(
                cached_deny_patterns,
                M.extract_bash_patterns(plugin_perms, "deny")
            )
            vim.list_extend(
                cached_ask_patterns,
                M.extract_bash_patterns(plugin_perms, "ask")
            )
        end
    end

    -- 2. Load from Claude settings.json files (allow maps to read_only for compatibility)
    if Config.permissions.use_claude_settings then
        local global = M.read_json(global_path)
        if global and global.permissions then
            vim.list_extend(
                cached_read_only_patterns,
                M.extract_bash_patterns(global.permissions, "allow")
            )
            vim.list_extend(
                cached_deny_patterns,
                M.extract_bash_patterns(global.permissions, "deny")
            )
            vim.list_extend(
                cached_ask_patterns,
                M.extract_bash_patterns(global.permissions, "ask")
            )
        end

        local project = M.read_json(project_path)
        if project and project.permissions then
            vim.list_extend(
                cached_read_only_patterns,
                M.extract_bash_patterns(project.permissions, "allow")
            )
            vim.list_extend(
                cached_deny_patterns,
                M.extract_bash_patterns(project.permissions, "deny")
            )
            vim.list_extend(
                cached_ask_patterns,
                M.extract_bash_patterns(project.permissions, "ask")
            )
        end
    end
end

--- Read additionalDirectories from ~/.claude/settings.json, expanding ~ to
--- the home directory. Returns absolute paths suitable for the Claude SDK.
--- @return string[]
function M.get_additional_directories()
    local global_path = M.settings_paths()
    local settings = M.read_json(global_path)
    if
        not settings
        or not settings.permissions
        or not settings.permissions.additionalDirectories
    then
        return {}
    end

    local home = vim.uv.os_homedir() or os.getenv("HOME") or ""
    local dirs = {}
    for _, dir in ipairs(settings.permissions.additionalDirectories) do
        if type(dir) == "string" and dir ~= "" then
            local expanded = dir:gsub("^~/", home .. "/")
            table.insert(dirs, expanded)
        end
    end
    return dirs
end

--- Check if a single command leaf matches any compiled pattern. The walker
--- supplies substitution-free, redirect-free leaf text (env-prefix assignments
--- already excluded, exec-wrapper prefixes already recursed past), so only a
--- system binary-dir prefix remains to strip before matching.
--- @param segment string
--- @param patterns agentic.utils.PermissionRules.CompiledPattern[]
--- @return boolean
function M.matches_any_pattern(segment, patterns)
    local trimmed = vim.trim(segment)
    trimmed = M.strip_command_path(trimmed)
    trimmed = vim.trim(trimmed)

    if trimmed == "" then
        return false
    end

    for _, pat in ipairs(patterns) do
        if trimmed:match(pat.lua_pattern) then
            return true
        end
    end
    return false
end

--- Resolve the merged read_only pattern list from all sources.
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function M.get_read_only_patterns()
    M.load_patterns()
    local result = {}
    vim.list_extend(result, cached_read_only_patterns or {})
    local list = Config.permissions.read_only
    if list ~= cached_config_read_only_ref then
        cached_config_read_only_ref = list
        cached_config_read_only_patterns = patterns_from_strings(list)
    end
    vim.list_extend(result, cached_config_read_only_patterns)
    return result
end

--- Resolve the merged safe_write pattern list from all sources.
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function M.get_safe_write_patterns()
    M.load_patterns()
    local result = {}
    vim.list_extend(result, cached_safe_write_patterns or {})
    local list = Config.permissions.safe_write
    if list ~= cached_config_safe_write_ref then
        cached_config_safe_write_ref = list
        cached_config_safe_write_patterns = patterns_from_strings(list)
    end
    vim.list_extend(result, cached_config_safe_write_patterns)
    return result
end

--- Resolve the merged allow-pattern list based on auto_approve setting.
--- Returns read_only + safe_write if "allow", read_only only if "read-only".
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function M.get_allow_patterns()
    local auto_approve = Config.permissions.auto_approve
    if not auto_approve then
        return {}
    end

    local result = M.get_read_only_patterns()

    if auto_approve == "allow" then
        vim.list_extend(result, M.get_safe_write_patterns())
    end

    return result
end

--- Resolve the merged deny-pattern list from all sources.
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function M.get_deny_patterns()
    M.load_patterns()
    local result = {}
    vim.list_extend(result, cached_deny_patterns or {})
    local list = Config.permissions.deny
    if list ~= cached_config_deny_ref then
        cached_config_deny_ref = list
        cached_config_deny_patterns = patterns_from_strings(list)
    end
    vim.list_extend(result, cached_config_deny_patterns)
    return result
end

--- Resolve the merged ask-pattern list from all sources.
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function M.get_ask_patterns()
    M.load_patterns()
    local result = {}
    vim.list_extend(result, cached_ask_patterns or {})
    local list = Config.permissions.ask
    if list ~= cached_config_ask_ref then
        cached_config_ask_ref = list
        cached_config_ask_patterns = patterns_from_strings(list)
    end
    vim.list_extend(result, cached_config_ask_patterns)
    return result
end

--- Strip leading dashes from a rule option so `"--exec"`, `"-exec"`, and
--- `"exec"` all canonicalise to the dashless candidate-space form. Idempotent.
--- @param s string
--- @return string
local function normalise_option(s)
    return (s:gsub("^%-+", ""))
end

local STRUCTURED_KINDS = { "read_only", "safe_write", "ask", "deny" }

--- Deep-copy a single gate, normalising every option string (`options` and
--- `leading_options`) to the dashless form. Positionals are left raw
--- (glob-compiled at match time). Unknown keys are dropped — defence in depth,
--- so a gate is never silently treated as the all-wildcard `{}`.
--- @param gate any
--- @return agentic.PermGate
local function normalise_gate(gate)
    --- @type agentic.PermGate
    local g = {}
    if type(gate) ~= "table" then
        return g
    end
    for _, field in ipairs({ "options", "leading_options" }) do
        if type(gate[field]) == "table" then
            local opts = {}
            for _, opt in ipairs(gate[field]) do
                if type(opt) == "string" then
                    table.insert(opts, normalise_option(opt))
                end
            end
            g[field] = opts
        end
    end
    if type(gate.positionals) == "table" then
        local pos = {}
        for _, p in ipairs(gate.positionals) do
            if type(p) == "string" then
                table.insert(pos, p)
            end
        end
        g.positionals = pos
    end
    return g
end

--- Deep-copy a cmd-keyed structured-entries table, normalising every option
--- string to the dashless form. A `vim.NIL` value (the user's "disable a
--- bundled cmd" marker) is preserved so it survives the merge in
--- `get_structured_entries`. The output is owned by the caller (safe to
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
                            table.insert(arr, normalise_gate(gate))
                        end
                        copy[kind] = arr
                    end
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
--- Re-reads the bundled file automatically when its mtime changes; user
--- additions are recompiled when the table reference changes.
--- @return agentic.StructuredEntries
function M.get_structured_entries()
    local plugin_path = plugin_permissions_path()
    local plugin_mtime = get_mtime(plugin_path)
    if
        cached_plugin_structured_entries == nil
        or plugin_mtime ~= cached_plugin_structured_mtime
    then
        cached_plugin_structured_mtime = plugin_mtime
        cached_plugin_structured_entries = {}
        if Config.permissions.use_plugin_defaults then
            local data = M.read_json(plugin_path)
            cached_plugin_structured_entries =
                normalise_structured_entries(data)
        end
    end

    local user_table = Config.permissions.structured
    if user_table ~= cached_config_structured_ref then
        cached_config_structured_ref = user_table
        cached_config_structured_entries =
            normalise_structured_entries(user_table)
    end

    --- @type agentic.StructuredEntries
    local merged = vim.tbl_deep_extend(
        "force",
        cached_plugin_structured_entries,
        cached_config_structured_entries
    ) or {}
    -- Drop `vim.NIL`-valued entries (the user's disable marker) so the matcher
    -- sees a clean table. decide_leaf also guards against vim.NIL.
    --- @type agentic.StructuredEntries
    local result = {}
    for cmd, entry in pairs(merged) do
        if entry ~= vim.NIL then
            result[cmd] = entry
        end
    end
    return result
end

-- ── Treesitter walker ──────────────────────────────────────────────────────
--
-- A command string is parsed with the zsh grammar and every node is proven
-- safe before auto-approval. Reject-by-default: any node type not explicitly
-- whitelisted bails to a prompt (fail-closed). The matcher layer above
-- (`matches_any_pattern` + the four pattern buckets) is unchanged — the walker
-- only decides HOW the command decomposes into leaf commands and refuses
-- non-simple structure (substitution, control flow, file-writing redirects,
-- dynamic command names).
--
-- Node-type names are pinned to the installed tree-sitter-zsh grammar (verified
-- 2026-06-12). They can drift across grammar versions — re-verify with a
-- parse-tree dump after upgrading the parser.

--- A file-mutating leaf the walker pinned to a concrete literal path. The walk
--- still bails structurally on everything it cannot model; a leaf that *can* be
--- modelled as a recoverable mutation is emitted here instead of bailing, for
--- the policy layer to clear against a trust scope (over-prompt-only: an effect
--- that does not clear still blocks approval). `path` may be relative — the
--- policy layer resolves it against cwd.
--- @class agentic.utils.PermissionRules.Effect
--- @field kind "write" Mutation kind (only redirect writes for now)
--- @field path string Concrete target path

--- @alias agentic.utils.PermissionRules.WalkCtx { allow: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[], structured_entries: agentic.StructuredEntries, auto_approve: agentic.PermAutoApprove, depth: integer, effects: agentic.utils.PermissionRules.Effect[] }

--- Container types that are straight-line statement sequences — #3
--- constant-literal propagation threads a per-sequence `known` environment
--- through these (and `do_group`) left to right. The decision/tally walks route
--- these to `walk_sequence`/`tally_sequence` (checked *before* `CONTAINER_TYPES`,
--- which they overlap). `pipeline` and `variable_assignments` are deliberately
--- absent: a `pipeline` stage runs in a subshell so its assignments do not reach
--- siblings, so they stay on the plain (no-propagation) container path.
local SEQUENCE_TYPES = {
    program = true,
    list = true,
    if_statement = true,
    elif_clause = true,
    else_clause = true,
}

--- The simplest splitting-proof literal: replacing an unquoted `$f` with this
--- value must yield exactly one word identical to itself — no IFS whitespace, no
--- glob/brace/tilde metacharacter, no expansion trigger. Paths, flags, and
--- `option=value` tokens qualify; anything richer keeps `$f` dynamic. This is the
--- soundness guard for #3 substitution: a multi-word or glob value would
--- word-split / expand and change which tokens the matcher sees.
--- @param lit string
--- @return boolean
local function is_safe_literal(lit)
    return lit ~= "" and lit:match("^[%w%-_./=:+@,]+$") ~= nil
end

--- The plain scalar name behind a bare `$name` / `${name}` reference or its
--- single-word double-quoted form `"$name"` / `"${name}"`, or nil for any richer
--- form (`$f[1]`, `${f:-x}`, `${#f}`, concatenation `"$f/x"`, `"$(cmd)"`, …) that
--- #3 substitution must not touch. A resolvable node has exactly one named child,
--- a `simple_variable_name`. A `string` node wrapping a single expansion recurses
--- on that child: quoting suppresses word-splitting and globbing, so the quoted
--- form yields exactly the one literal we substitute. The `named_child_count == 1`
--- guard excludes concatenation (`"pre$f"` has a `string_content` sibling, `"$a$b"`
--- a second expansion) and quoted command substitution (the inner child is
--- `command_substitution`, not a `simple_variable_name`, so the recursion returns
--- nil and the form stays dynamic).
--- @param node TSNode
--- @param src string
--- @return string|nil
local function resolved_var_name(node, src)
    local t = node:type()
    if
        t == "variable_ref"
        or t == "expansion"
        or t == "simple_expansion"
    then
        if node:named_child_count() == 1 then
            local c = node:named_child(0)
            if c and c:type() == "simple_variable_name" then
                return vim.treesitter.get_node_text(c, src)
            end
        end
    elseif t == "string" and node:named_child_count() == 1 then
        local c = node:named_child(0)
        if c then
            return resolved_var_name(c, src)
        end
    end
    return nil
end

--- Builtins whose normal action rebinds the shell namespace into the enclosing
--- scope. `collect_bindings` returns clear-all for any of these (the bindings
--- can't be enumerated from a token scan), with `printf` carved out — its
--- `-v NAME` form names its target, so it enumerates that one name instead.
--- `eval`/`source`/`.` already bail in `walk_command`; listed here so the tally
--- walk (which does not bail) still clears. `local`/`typeset`/`declare`/
--- `readonly` parse as `declaration_command` (collect-all'd directly) and are
--- listed only for the rare grammar emission as a plain command.
---
--- Cross-file coupling: any builtin allowlisted in `permissions.json` that can
--- rebind a shell variable must appear here, else the binding survives a plain
--- command unscathed and the matcher resolves a stale `known[var]` while the
--- shell ran the rebound value. Today only `printf` satisfies "allowlisted ∧
--- rebinds", which is why its membership is load-bearing, not insurance.
local NAMESPACE_MUTATING = {
    read = true,
    printf = true,
    mapfile = true,
    readarray = true,
    getopts = true,
    set = true,
    unset = true,
    export = true,
    eval = true,
    source = true,
    ["."] = true,
    let = true,
    declare = true,
    typeset = true,
    ["local"] = true,
    readonly = true,
}

--- The path-stripped command name of a `command` node, or nil when it has no
--- literal `command_name` (a dynamic name — treated as namespace-mutating by the
--- sequence walk, i.e. it clears `known`).
--- @param node TSNode
--- @param src string
--- @return string|nil
local function command_leaf_name(node, src)
    for child in node:iter_children() do
        if child:type() == "command_name" then
            local n = command_name_text(child, src)
            return n and M.strip_command_path(n) or nil
        end
    end
    return nil
end

--- Node types whose bindings never reach the enclosing sequence — a subshell,
--- a `$(…)` / `<(…)` substitution. Their inner assignments are sealed in a
--- child shell, so they contribute no names to drop and need no recursion.
--- (`pipeline` is deliberately absent: a `read`/`mapfile` in a pipeline stage
--- could escape under bash `lastpipe`, so it stays in `STATEMENT_CONTAINER` and
--- a mutating stage clears `known`.)
local SCOPE_BOUNDARY = {
    subshell = true,
    command_substitution = true,
    process_substitution = true,
}

--- Control-flow / grouping containers whose every named child is a statement
--- (no value/pattern/redirect-target leaves), so the collect-targets scan can
--- recurse all their named children. Field-specific containers
--- (`for`/`while`/`case`/`case_item`/`redirected_statement`) are handled inline
--- so the scan descends only into statement positions and skips the loop list,
--- matched value, case patterns, and redirect targets — which carry no escaping
--- binding (a `$(…)` there is sealed in a subshell) and would otherwise hit the
--- fail-safe.
local STATEMENT_CONTAINER = {
    if_statement = true,
    elif_clause = true,
    else_clause = true,
    list = true,
    pipeline = true,
    do_group = true,
    compound_statement = true,
    negated_command = true,
}

--- Collect the variable names a control-flow sibling could rebind in the
--- enclosing sequence (#3 capable grade), accumulating them into `targets`.
--- Returns `false` to signal *clear-all* — the construct contains a binding
--- whose target set cannot be enumerated (a namespace-mutating builtin, a
--- dynamic / subscripted assignment name, arithmetic assignment, a
--- `declaration_command`, or any unmodelled node type), so the caller must
--- drop every binding rather than trust an undercount.
---
--- Soundness is one-directional: an over-collected name (or a needless
--- clear-all) only over-prompts; a *missed* binder under-prompts (the matcher
--- would resolve a stale `known[var]` while the shell ran the rebound value).
--- So a node preserves `known` only when provably binding-free or
--- cleanly-enumerable; any unmodelled node type returns `false`. The scan
--- recurses only into statement positions (so `while read x; …` clears via the
--- recursed condition while `case $x in …` skips the matched value), stops at
--- `SCOPE_BOUNDARY` nodes (inner bindings sealed in a child shell), and mirrors
--- `update_known`'s per-command logic (`printf -v` enumerates its target, other
--- namespace-mutating builtins clear-all) so the two stay consistent.
--- @param node TSNode
--- @param src string
--- @param targets table<string, boolean>
--- @return boolean enumerable
local function collect_bindings(node, src, targets)
    --- Recurse every named, non-comment child whose field is in `fields` (all
    --- of them when `fields` is nil). Returns false on the first clear-all.
    --- @param fields table<string, boolean>|nil
    --- @return boolean
    local function recurse(fields)
        for child, field in node:iter_children() do
            if
                child:named()
                and child:type() ~= "comment"
                and (not fields or fields[field])
                and not collect_bindings(child, src, targets)
            then
                return false
            end
        end
        return true
    end

    local t = node:type()
    if SCOPE_BOUNDARY[t] or t == "test_command" then
        -- Sealed subshell, or a side-effect-free predicate — binds nothing.
        return true
    elseif t == "variable_assignment" then
        local name_node = node:field("name")[1]
        local name = name_node
            and vim.treesitter.get_node_text(name_node, src)
        -- Only a plain scalar name is enumerable; `arr[$i]=…` / a name carrying
        -- an expansion could rebind anything → clear-all.
        if name and name:match("^[%w_]+$") then
            targets[name] = true
            return true
        end
        return false
    elseif t == "for_statement" then
        local var = node:field("variable")[1]
        local name = var and vim.treesitter.get_node_text(var, src)
        if not (name and name:match("^[%w_]+$")) then
            return false
        end
        targets[name] = true
        return recurse({ body = true })
    elseif t == "while_statement" then
        return recurse({ condition = true, body = true })
    elseif t == "case_statement" then
        for child in node:iter_children() do
            if
                child:type() == "case_item"
                and not collect_bindings(child, src, targets)
            then
                return false
            end
        end
        return true
    elseif t == "case_item" then
        for child, field in node:iter_children() do
            if
                field ~= "value"
                and child:named()
                and child:type() ~= "comment"
                and not collect_bindings(child, src, targets)
            then
                return false
            end
        end
        return true
    elseif t == "redirected_statement" then
        return recurse({ body = true })
    elseif t == "command" then
        local name = command_leaf_name(node, src)
        if name == "printf" then
            -- Mirrors update_known: `-v NAME` rebinds NAME. Enumerate a literal
            -- NAME; a dynamic / missing target → clear-all.
            local want_name = false
            for arg in node:iter_children() do
                local at = vim.treesitter.get_node_text(arg, src)
                if want_name then
                    if at:match("^[%w_]+$") then
                        targets[at] = true
                        want_name = false
                    else
                        return false
                    end
                elseif at == "-v" then
                    want_name = true
                end
            end
            return not want_name
        elseif not name or NAMESPACE_MUTATING[name] then
            return false
        end
        -- A plain non-mutating command binds nothing in the enclosing scope.
        -- (Args are inert or scope boundaries; `$((d=…))` arithmetic in an arg
        -- is the same accepted residual as the lazy grade — it can only forge a
        -- numeric value, never a flag/path.)
        return true
    elseif STATEMENT_CONTAINER[t] then
        return recurse(nil)
    end
    -- Unknown / unmodelled node type → fail-safe clear-all.
    return false
end

--- Update the per-sequence constant environment after processing one
--- straight-line child, left to right. The rule is inverted from enumerating
--- what rebinds: a child *preserves* `known` only when provably inert, and
--- everything else drops only the binding(s) it could touch. A pure-literal
--- `variable_assignment` records `known[name]=lit`; a non-literal one drops
--- just that name. Every other child is handed to `collect_bindings` (#3
--- capable grade): a plain command or a binding-free control-flow construct
--- drops nothing (`f=…; if c; then :; fi; find $f` keeps `f`), one that binds
--- enumerable names (`printf -v g`, an `if`-body assignment, a `for` loop var)
--- drops exactly those, and one whose targets can't be enumerated (a
--- namespace-mutating builtin, arithmetic assignment, a `declaration_command`,
--- a dynamic name, or any unmodelled node type) clears `known` entirely.
--- Dropping can only shrink `known`, so it can only ever over-prompt.
--- @param known table<string, string>
--- @param child TSNode
--- @param src string
local function update_known(known, child, src)
    if child:type() == "variable_assignment" then
        local name_node = child:field("name")[1]
        local name = name_node
            and vim.treesitter.get_node_text(name_node, src)
        if not name then
            return
        end
        local value = child:field("value")[1]
        local lit = value and pure_literal_token(value, src)
        if lit and is_safe_literal(lit) then
            known[name] = lit
        else
            known[name] = nil
        end
        return
    end

    --- @type table<string, boolean>
    local targets = {}
    if collect_bindings(child, src, targets) then
        for name in pairs(targets) do
            known[name] = nil
        end
    else
        for k in pairs(known) do
            known[k] = nil
        end
    end
end

--- Forward declaration — `walk` and the per-node handlers are mutually
--- recursive.
--- @type fun(node: TSNode, src: string, ctx: agentic.utils.PermissionRules.WalkCtx): boolean
local walk

--- Forward declaration — `walk_command`/`walk_for` recurse into a bare
--- `command_substitution` (argument or for-list position) via this helper, which
--- is defined further down.
--- @type fun(subst: TSNode, src: string, ctx: agentic.utils.PermissionRules.WalkCtx): boolean
local walk_substitution_inner

--- True for a double-quoted `string` whose only expansions are command
--- substitutions (#4b generalised): at least one `command_substitution` named
--- child and every named child is `string_content` or `command_substitution`.
--- A `$var`/`${…}`/arithmetic child (dynamic-unresolvable) or any other node
--- fails the whitelist, so the caller bails. Pure-literal strings (no
--- substitution) return false and stay concrete literal tokens.
--- @param node TSNode
--- @return boolean
local function string_subst_only(node)
    local saw_subst = false
    for c in node:iter_children() do
        if c:named() then
            local t = c:type()
            if t == "command_substitution" then
                saw_subst = true
            elseif t ~= "string_content" then
                return false
            end
        end
    end
    return saw_subst
end

--- Extract a `command` node's argument tokens — shared by `walk_command` (the
--- mode-gated decision) and `command_known_safe` (the highlight tally), which
--- differ only in how an inner command substitution is vetted, passed in as
--- `inner_check`. Returns the parallel `args`/`arg_nodes`/`args_dynamic` streams
--- plus the `command_name` node. `args` is nil on any structural bail (an
--- env-hijack prefix, an unhandled substitution, an unextractable token).
---
--- A bare `$(…)` argument and a quoted `"$(…)"` (#4b: a `string` whose single
--- named child is a `command_substitution`) both vet their inner via
--- `inner_check` (it runs) and splice the inner's `$(…)` text as a dynamic
--- token, so a gated outer command still prompts. Process substitution `<(…)` /
--- `>(…)` also vets its inner via `inner_check`, but splices a *static*
--- `/dev/fd` placeholder — it always expands to a `/dev/fd/N` path, never a flag
--- or subcommand, so it can't launder a gate token. Other substitution-bearing
--- arguments (concatenation `a$(b)c`, a multi-child quoted string) bail.
--- @param node TSNode
--- @param src string
--- @param ctx any walk or tally ctx — only threaded through to `inner_check`
--- @param known table<string, string>|nil
--- @param inner_check fun(subst: TSNode, src: string, ctx: any): boolean
--- @return string[]|nil args
--- @return TSNode[]|nil arg_nodes
--- @return boolean[]|nil args_dynamic
--- @return TSNode|nil name_node
local function extract_args(node, src, ctx, known, inner_check)
    local name_node
    --- @type string[]
    local args = {}
    --- @type TSNode[]
    local arg_nodes = {}
    --- @type boolean[]
    local args_dynamic = {}
    for child in node:iter_children() do
        local t = child:type()
        if t == "variable_assignment" then
            -- A prefix assignment's name must be inert; a substitution in its
            -- value launders argument-position tokens once expanded at a later
            -- use, so bail (the standalone-statement form, where the value is
            -- captured into a variable, is vetted by walk_assignment).
            if
                not safe_assignment_name(child, src)
                or subtree_has_substitution(child)
            then
                return nil
            end
        elseif t == "command_name" then
            -- A substitution-bearing name is dynamic; command_name_text returns
            -- nil for it at the call site and we bail.
            name_node = child
        elseif t == "command_substitution" then
            -- A bare `$(...)` argument: vet the inner command (it runs), then
            -- splice its output into the arg stream as a dynamic token. The
            -- dynamic flag makes the structured layer wildcard deny/ask, so a
            -- payload like `find . $(echo -exec rm)` still prompts.
            if not inner_check(child, src, ctx) then
                return nil
            end
            table.insert(args, vim.treesitter.get_node_text(child, src))
            table.insert(arg_nodes, child)
            table.insert(args_dynamic, true)
        elseif t == "process_substitution" then
            -- `<(cmd)` / `>(cmd)`: vet the inner command(s) (they run), then
            -- splice a concrete `/dev/fd` placeholder. The arg always expands to
            -- a single `/dev/fd/N` path — structurally a path, never a flag or
            -- subcommand — so unlike `$(…)` output it cannot launder a gate token
            -- and stays static (a dynamic splice would wildcard-fire the outer
            -- command's deny/ask gates and over-prompt). `>(…)` is the same node
            -- type and equally safe: a writing inner still bails on the recursion.
            if not inner_check(child, src, ctx) then
                return nil
            end
            table.insert(args, "/dev/fd")
            table.insert(arg_nodes, child)
            table.insert(args_dynamic, false)
        elseif child:named() then
            -- #3: a bare `$name`/`${name}` bound to a splitting-proof literal
            -- earlier in this straight-line sequence resolves to that literal and
            -- becomes static, so a benign value (`f=/safe; find $f`) no longer
            -- wildcard-fires a gate. The literal feeds the same gates, so
            -- `f=--exec; find $f` still denies.
            local kname = known and resolved_var_name(child, src)
            local lit = kname and known and known[kname] or nil
            if lit ~= nil then
                table.insert(args, lit)
                table.insert(arg_nodes, child)
                table.insert(args_dynamic, false)
            elseif
                child:type() == "string"
                and child:named_child_count() == 1
                and child:named_child(0):type() == "command_substitution"
            then
                -- #4b: a quoted `"$(cmd)"`. Like the bare form, vet the inner (it
                -- runs) and splice the inner's `$(…)` text as a dynamic token.
                -- Quoting suppresses word-splitting (one term vs zero-or-many),
                -- but the spliced token is unknown content either way, so the
                -- dynamic-token wildcarding gives the identical safety outcome.
                local inner = child:named_child(0) --[[@as TSNode]]
                if not inner_check(inner, src, ctx) then
                    return nil
                end
                table.insert(args, vim.treesitter.get_node_text(inner, src))
                table.insert(arg_nodes, child)
                table.insert(args_dynamic, true)
            elseif child:type() == "string" and string_subst_only(child) then
                -- #4b generalised: a quoted string mixing literal text with one
                -- or more command substitutions (`"count: $(ls)"`). Vet every
                -- inner (they run), then splice the whole quoted string as ONE
                -- dynamic token — raw text, quotes kept (unlike #4b's strip; the
                -- token is dynamic so the structured matcher wildcards it and
                -- ignores its text). A gated outer command's deny/ask still
                -- wildcard-fires at this index.
                for sub in child:iter_children() do
                    if
                        sub:type() == "command_substitution"
                        and not inner_check(sub, src, ctx)
                    then
                        return nil
                    end
                end
                table.insert(args, vim.treesitter.get_node_text(child, src))
                table.insert(arg_nodes, child)
                table.insert(args_dynamic, true)
            else
                -- Any other substitution-bearing argument (concatenation
                -- `a$(b)c`, process substitution `<(…)`, a `$var`-mixed quoted
                -- string) is not handled by the dynamic-token machinery — bail.
                if subtree_has_substitution(child) then
                    return nil
                end
                local tok = literal_token(child, src)
                if tok == nil then
                    return nil
                end
                table.insert(args, tok)
                table.insert(arg_nodes, child)
                table.insert(args_dynamic, token_is_dynamic(child))
            end
        end
    end
    return args, arg_nodes, args_dynamic, name_node
end

--- Walk a `command`: validate the name and each argument by position
--- (substitution is recursed in argument position, bailed elsewhere), validate
--- env-prefix assignments, then combine the glob
--- and structured layers (composition rule in the `permissions` project skill).
--- `known` (optional) is the #3 constant environment of the enclosing sequence;
--- a bare `$name` bound in it resolves to its literal and becomes a static token.
--- `funcs` (optional) is the #6 set of function names defined and body-walked
--- clean earlier in the sequence; a call to one approves regardless of its args.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @param known table<string, string>|nil
--- @param funcs table<string, boolean>|nil
--- @return boolean
local function walk_command(node, src, ctx, known, funcs)
    local args, arg_nodes, args_dynamic, name_node =
        extract_args(node, src, ctx, known, walk_substitution_inner)
    if not args then
        return false
    end

    if not name_node then
        return false
    end
    local name = command_name_text(name_node, src)
    if not name then
        return false
    end
    local cmd_name = M.strip_command_path(name)
    if CODE_TAKING_BUILTINS[cmd_name] then
        return false
    end

    local leaf = name
    if #args > 0 then
        leaf = leaf .. " " .. table.concat(args, " ")
    end

    -- Cheap glob denies first — short-circuit before the structured matcher.
    if #ctx.deny > 0 and M.matches_any_pattern(leaf, ctx.deny) then
        return false
    end
    if #ctx.ask > 0 and M.matches_any_pattern(leaf, ctx.ask) then
        return false
    end

    -- #6: a call to a function defined earlier in this straight-line sequence.
    -- Its body was walked clean at definition time with every parameter dynamic,
    -- so the body is safe for ANY call arguments — the call needs no re-vetting
    -- of how the function uses them. The arguments were still walked above (a
    -- side-effecting `foo $(rm x)` already bailed on the substitution).
    if funcs and funcs[cmd_name] then
        return true
    end

    -- Transparent prefix (inline `sh -c '<body>'` or exec-wrapper): walk the
    -- inner command instead of treating the prefix as an opaque leaf. Must run
    -- before the structured matcher so a shell's `c` gate does not pre-empt the
    -- `-c` recursion. A body at the depth cap, or one that does not resolve,
    -- falls through to the leaf matchers. A `writes` wrapper (uv's env sync) is
    -- safe_write-tier: recurse only at the allow tier, else fall through so the
    -- inner's read_only class cannot launder the command into read-only.
    local inner, _, writes =
        inner_source(cmd_name, node, args, arg_nodes, args_dynamic, src)
    if
        inner
        and ctx.depth < NESTED_MAX_DEPTH
        and (not writes or ctx.auto_approve == "allow")
    then
        local root = parse_zsh(inner)
        if not root then
            return false
        end
        return walk(
            root,
            inner,
            vim.tbl_extend("force", ctx, { depth = ctx.depth + 1 })
        )
    end

    --- @type agentic.PermDecision
    local structured = nil
    if next(ctx.structured_entries) ~= nil then
        --- @type agentic.ParsedLeaf
        local parsed =
            { cmd_name = cmd_name, args = args, args_dynamic = args_dynamic }
        -- Lazy require: permission_structured itself requires this module
        -- (for `glob_to_lua_pattern`). Deferring to call-time breaks the cycle.
        local PermissionStructured =
            require("agentic.utils.permission_structured")
        structured = PermissionStructured.decide_leaf(
            ctx.structured_entries,
            parsed,
            ctx.auto_approve
        )
        -- In the APPROVE walk deny and ask both collapse to "not approved". The
        -- distinction (deny rejects with no prompt, ask prompts) is enforced
        -- earlier by `should_auto_reject` — see the reject walk below.
        if structured == "deny" or structured == "ask" then
            return false
        end
    end

    if structured == "allow" then
        return true
    end
    return M.matches_any_pattern(leaf, ctx.allow)
end

--- Walk a named `function_definition` in sequence context (#6). Defining a named
--- function never runs its body, so the definition always approves; the body's
--- cleanliness only decides whether a later *call* resolves. Body-walk it as a
--- fresh sequence (every `$var`/positional dynamic, no inherited `known` literals
--- or `funcs`); record the name in `funcs` iff it walks clean. A redefinition
--- with an unsafe body must *un-record* the name — otherwise a stale safe record
--- would approve a call that now runs the rebound (unsafe) body. An anonymous
--- `() { … }` executes immediately and is left to the dispatcher's fail-closed
--- branch.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @param funcs table<string, boolean>
--- @return boolean
local function walk_function_definition(node, src, ctx, funcs)
    local name_node = node:field("name")[1]
    if not name_node then
        return false
    end
    local name = vim.treesitter.get_node_text(name_node, src)
    local body = node:field("body")[1]
    funcs[name] = (body and walk(body, src, ctx)) or nil
    return true
end

--- Walk a straight-line statement sequence (`program`, `list`, an `if`/`elif`/
--- `else` body, a `do_group`, or a brace group / function body
--- `compound_statement`), threading the #3 constant environment and the #6
--- function table left to right: a pure-literal assignment binds a name, a
--- function definition records a body-walked-clean name, and a later `command`
--- resolves bare `$name` references and recorded calls against them. Both are
--- sequence-local — nested blocks reached via `walk(child)` start fresh, so
--- neither a binding nor a function name leaks across sequences.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
local function walk_sequence(node, src, ctx)
    --- @type table<string, string>
    local known = {}
    --- @type table<string, boolean>
    local funcs = {}
    for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            local ok
            local t = child:type()
            if t == "command" then
                ok = walk_command(child, src, ctx, known, funcs)
            elseif t == "function_definition" then
                ok = walk_function_definition(child, src, ctx, funcs)
            else
                ok = walk(child, src, ctx)
            end
            if not ok then
                return false
            end
            update_known(known, child, src)
        end
    end
    return true
end

--- Walk a `redirected_statement`: the body (command/pipeline/list) must pass,
--- and every redirect must be a safe form. Heredoc/herestring redirects are
--- unmodelled and bail.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
local function walk_redirected(node, src, ctx)
    for child, field in node:iter_children() do
        if field == "body" then
            if not walk(child, src, ctx) then
                return false
            end
        elseif child:named() then
            if child:type() ~= "file_redirect" then
                return false
            end
            if not redirect_is_safe(child, src) then
                -- A concrete file-write redirect (`cmd > /tmp/x`) is not bailed
                -- but emitted as a write effect; the policy layer clears it
                -- against the trust scope. A target it cannot pin to a literal
                -- (dynamic / unmodelled) still bails.
                local target = redirect_write_target(child, src)
                if not target then
                    return false
                end
                table.insert(
                    ctx.effects,
                    { kind = "write", path = target }
                )
            end
        end
    end
    return true
end

--- Recurse `walk` over every inner statement of a `command_substitution`. Each
--- direct named child must be one of `SUBSTITUTION_INNER_STATEMENT_TYPES` AND
--- pass its own walk — so `f=$(rm x)` still bails (the inner `rm` is not in
--- allow) and `f=$(foo > bar)` bails (the inner `file_redirect` fires through
--- `walk_redirected` → `redirect_is_safe`).
---
--- Two soundness requirements hold at every call site (assignment value /
--- array element, bare argument, for-list item): the inner code *runs*, so it
--- must clear the same bar as a standalone command (this walk); and its
--- *output* splices into the surrounding context, where it is opaque to the
--- matcher. In assignment position the output is captured into a variable
--- (expansion deferred to a later use the matcher already cannot see through);
--- in argument / for-list position the caller marks the spliced token dynamic,
--- so the structured layer wildcards deny/ask over it. A single-child quoted
--- `"$(…)"` argument (#4b) is unwrapped to its inner `command_substitution` and
--- passed here too. A process substitution `<(…)` / `>(…)` node is also passed
--- here — its inner commands are this node's named children, so the same
--- iteration vets them (the caller then splices a static `/dev/fd` placeholder
--- rather than a dynamic token). The remaining non-bare forms (concatenation
--- `a$(b)c`, a multi-child quoted string) are bailed by
--- `subtree_has_substitution` at the call site before reaching here.
--- @param subst TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
function walk_substitution_inner(subst, src, ctx)
    local saw_statement = false
    for child in subst:iter_children() do
        if child:named() and child:type() ~= "comment" then
            if not SUBSTITUTION_INNER_STATEMENT_TYPES[child:type()] then
                return false
            end
            if not walk(child, src, ctx) then
                return false
            end
            saw_statement = true
        end
    end
    -- An empty `$()` has no inner statement; refuse rather than approve a
    -- substitution that contributes no walked content.
    return saw_statement
end

--- Walk a statement-level `variable_assignment` (`f=path`, `arr=(a b c)`,
--- `f=$(echo hi)`, `arr=(a $(echo b) c)`). Inert by itself — only its `value`
--- may carry a side-effecting substitution, and only assignment value /
--- array-element position is sound (see the `permissions` skill § "Compound
--- Bash commands"). A poisoned name (`PATH=/evil`) bails because a
--- later command would inherit it.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
local function walk_assignment(node, src, ctx)
    if not safe_assignment_name(node, src) then
        return false
    end
    local value = node:field("value")[1]
    if not value then
        -- Bare `f=` with no value — no substitution, no side effect.
        return true
    end
    local vt = value:type()
    if vt == "command_substitution" then
        return walk_substitution_inner(value, src, ctx)
    end
    if vt == "array" then
        for child in value:iter_children() do
            if child:named() and child:type() ~= "comment" then
                local ct = child:type()
                if ct == "command_substitution" then
                    if not walk_substitution_inner(child, src, ctx) then
                        return false
                    end
                elseif subtree_has_substitution(child) then
                    -- A non-`command_substitution` element that nonetheless
                    -- carries a substitution (e.g. `"$(...)"`, `a$(b)c`) is
                    -- argument-position substitution once expanded; bail.
                    return false
                end
            end
        end
        return true
    end
    -- Any other value form (literal, concatenation, expansion, …): the
    -- pre-Phase-2 bail still applies — a substitution anywhere in the value
    -- that did not come through the two carve-outs above is rejected.
    if subtree_has_substitution(value) then
        return false
    end
    return true
end

--- Walk a `for_statement`: each list item is a literal / glob / expansion or a
--- bare `command_substitution` (recursed via `walk_substitution_inner`); any
--- other substitution-bearing item bails. Then the `do_group` body recurses,
--- where the loop var is already dynamic so a laundered payload is caught at
--- the use site. Unnamed children (the `for`/`in`/`do`/`;` keywords and
--- separators) are ignored even when the grammar tags them with the same field
--- as a named sibling.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
local function walk_for(node, src, ctx)
    local body
    for child, field in node:iter_children() do
        if child:named() then
            if field == "value" then
                -- A bare `$(...)` list item is vetted like an argument
                -- substitution: it runs, and its output becomes loop values
                -- that enter the body as the already-dynamic loop var. Any
                -- other substitution-bearing item bails.
                if child:type() == "command_substitution" then
                    if not walk_substitution_inner(child, src, ctx) then
                        return false
                    end
                elseif subtree_has_substitution(child) then
                    return false
                end
            elseif field == "body" then
                body = child
            end
        end
    end
    if not body then
        return false
    end
    return walk(body, src, ctx)
end

--- Walk a `while_statement` (covers `while` and `until` — both parse to the
--- same node type in this grammar). The `condition` is a statement
--- (`command`/`pipeline`/`list`/`redirected_statement`) that must itself
--- pass; the `body` (a `do_group`) recurses. The grammar attaches the
--- terminating `;` to the `condition` field as well as the statement itself,
--- so unnamed children with that field are ignored.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
local function walk_while(node, src, ctx)
    local cond, body
    for child, field in node:iter_children() do
        if child:named() then
            if field == "condition" then
                cond = child
            elseif field == "body" then
                body = child
            end
        end
    end
    if not cond or not body then
        return false
    end
    if not walk(cond, src, ctx) then
        return false
    end
    return walk(body, src, ctx)
end

--- Walk a `case_statement`: the matched value and every `case_item` pattern
--- must be substitution-free (a `$(cmd)` in either position *runs* during the
--- match — `case $(rm x) in $(rm y)) …` executes both), and every item body
--- recurses. Pattern words/extglobs that are not substitutions are inert glob
--- text and ignored. The `value`-field children inside a `case_item` are the
--- patterns; unfielded named children are body statements.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
local function walk_case(node, src, ctx)
    for child, field in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            if field == "value" then
                if subtree_has_substitution(child) then
                    return false
                end
            elseif child:type() == "case_item" then
                for item_child, item_field in child:iter_children() do
                    if
                        item_child:named()
                        and item_child:type() ~= "comment"
                    then
                        if item_field == "value" then
                            if subtree_has_substitution(item_child) then
                                return false
                            end
                        elseif not walk(item_child, src, ctx) then
                            return false
                        end
                    end
                end
            else
                -- Unexpected named child for this node type — fail-closed.
                return false
            end
        end
    end
    return true
end

function walk(node, src, ctx)
    local t = node:type()
    if t == "test_command" then
        -- `[[ … ]]` / `[ … ]` — a side-effect-free predicate. The only way it
        -- runs code is an embedded substitution (`[[ -f $(rm y) ]]`).
        return not subtree_has_substitution(node)
    elseif t == "case_statement" then
        return walk_case(node, src, ctx)
    elseif SEQUENCE_TYPES[t] or t == "do_group" or t == "compound_statement" then
        -- `compound_statement` is a brace group `{ …; }` or a function body —
        -- both run sequentially in the current shell, like a `list`.
        return walk_sequence(node, src, ctx)
    elseif CONTAINER_TYPES[t] then
        -- `pipeline` / `variable_assignments` — the non-sequence containers (the
        -- sequence types overlap CONTAINER_TYPES but are caught above). Iterate
        -- named children only; anonymous separators (`;`, `&&`, `|`, `&`,
        -- newline) and `comment` nodes carry no executable content.
        for child in node:iter_children() do
            if child:named() and child:type() ~= "comment" then
                if not walk(child, src, ctx) then
                    return false
                end
            end
        end
        return true
    elseif t == "command" then
        return walk_command(node, src, ctx)
    elseif t == "redirected_statement" then
        return walk_redirected(node, src, ctx)
    elseif t == "variable_assignment" then
        return walk_assignment(node, src, ctx)
    elseif t == "for_statement" then
        return walk_for(node, src, ctx)
    elseif t == "while_statement" then
        -- `until` also parses to `while_statement` in the pinned zsh grammar.
        return walk_while(node, src, ctx)
    elseif t == "function_definition" then
        -- Reached outside a sequence (rare): defining a *named* function never
        -- runs its body, so it approves without a body-walk; an anonymous
        -- (`() { … }`, no `name`) executes immediately and fails closed. The #6
        -- body-walk-and-record happens in `walk_sequence` (the common path),
        -- which has the `funcs` table; here there is none to record into.
        return node:field("name")[1] ~= nil
    end
    -- Any unknown future node type stays rejected (fail-closed).
    return false
end

-- ── Tally walk (highlight the unapproved parts of a prompt) ──────────────────
--
-- A second traversal over the same parse tree, used only for UI: it records the
-- byte ranges of every leaf/structural node that is NOT known-safe, so the
-- permission prompt can wash those bytes. It is deliberately SEPARATE from the
-- decision `walk` above — a bug here can only mis-highlight, never mis-approve,
-- since it never feeds `should_auto_approve`. It reuses every structural helper
-- (`literal_token`, `command_name_text`, `redirect_is_safe`,
-- `subtree_has_substitution`, the node-type sets, …) so "what counts as safe
-- structure" stays single-sourced; only the control flow differs (record and
-- continue, vs bail on first).
--
-- Classification is CATEGORY-level (`PermissionStructured.classify_leaf` + the
-- four glob buckets), not the `auto_approve`-resolved decision: a leaf is
-- known-safe iff it matches a read_only/safe_write rule AND no deny/ask rule, so
-- a `safe_write` like `git add` never lights up even in read-only mode.

--- @alias agentic.utils.PermissionRules.TallyCtx { read_only: agentic.utils.PermissionRules.CompiledPattern[], safe_write: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[], structured_entries: agentic.StructuredEntries, depth: integer }

--- Forward declaration — the tally handlers are mutually recursive, and
--- `command_known_safe` recurses through `tally_walk` for inline `-c` bodies.
--- @type fun(node: TSNode, src: string, ctx: agentic.utils.PermissionRules.TallyCtx, ranges: agentic.utils.PermissionRules.Range[])
local tally_walk

--- @alias agentic.utils.PermissionRules.Range [integer, integer, integer, integer]

--- Append a node's `node:range()` (0-indexed byte cols) to `ranges`.
--- @param ranges agentic.utils.PermissionRules.Range[]
--- @param node TSNode
local function record(ranges, node)
    local sr, sc, er, ec = node:range()
    table.insert(ranges, { sr, sc, er, ec })
end

--- Tally a `command_substitution`'s inner statements into `out`. Returns false
--- when the inner is structurally invalid (a child is not a
--- `SUBSTITUTION_INNER_STATEMENT_TYPES`) or empty — the caller then falls back
--- to a coarse whole-node highlight. A valid but unapproved inner returns true
--- with its ranges in `out` (in `src` coordinates — the inner is parsed
--- in-place, so no translation). Mirrors `walk_substitution_inner` for the
--- highlight pass, replacing the old clean-check: a clean inner returns true
--- with `out` empty (records nothing).
--- @param subst TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param out agentic.utils.PermissionRules.Range[]
--- @return boolean valid
local function substitution_inner_collect(subst, src, ctx, out)
    local saw_statement = false
    for child in subst:iter_children() do
        if child:named() and child:type() ~= "comment" then
            if not SUBSTITUTION_INNER_STATEMENT_TYPES[child:type()] then
                return false
            end
            tally_walk(child, src, ctx, out)
            saw_statement = true
        end
    end
    return saw_statement
end

--- Record unapproved substitution ranges in a subtree without descending into a
--- command leaf. A bare `command_substitution` (for-list, case value/pattern,
--- assignment value, test) pinpoints its unapproved inner statements in-place
--- (no translation — they are children of the same tree); an empty/invalid
--- inner, process substitution, and any other `SUBSTITUTION_TYPE` stay
--- whole-node. Inside a `command` substitution is absorbed into the
--- whole-command range.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
local function record_substitutions(node, src, ctx, ranges)
    if node:type() == "command_substitution" then
        --- @type agentic.utils.PermissionRules.Range[]
        local inner = {}
        if substitution_inner_collect(node, src, ctx, inner) then
            for _, r in ipairs(inner) do
                table.insert(ranges, r)
            end
        else
            record(ranges, node) -- empty/invalid inner: coarse
        end
        return
    end
    if SUBSTITUTION_TYPES[node:type()] then
        record(ranges, node) -- process substitution etc.: coarse
        return
    end
    for child in node:iter_children() do
        if child:named() then
            record_substitutions(child, src, ctx, ranges)
        end
    end
end

--- Translate tally ranges produced against an inner-command source back into the
--- outer `src` coordinate system, given the inner's `(row, col)` origin. Rows
--- shift by the origin row; the origin column applies only to relative-row 0
--- (every later row already starts at column 0 in the inner source).
--- @param ranges agentic.utils.PermissionRules.Range[]
--- @param origin agentic.utils.PermissionRules.Origin
--- @return agentic.utils.PermissionRules.Range[]
local function translate_ranges(ranges, origin)
    local orow, ocol = origin[1], origin[2]
    --- @type agentic.utils.PermissionRules.Range[]
    local out = {}
    for _, r in ipairs(ranges) do
        local sr, sc, er, ec = r[1], r[2], r[3], r[4]
        table.insert(out, {
            sr + orow,
            sr == 0 and sc + ocol or sc,
            er + orow,
            er == 0 and ec + ocol or ec,
        })
    end
    return out
end

--- Whether a `command` leaf is known-safe: it matches a read_only/safe_write
--- rule (glob or structured) AND no deny/ask rule, with no structural reason to
--- bail (substitution in a non-bare position, env-hijack prefix, dynamic name,
--- code-taking builtin, unextractable token). Mirrors `walk_command`'s
--- extraction but classifies by category instead of resolving the mode-gated
--- decision.
---
--- For a transparent prefix (exec-wrapper or `sh -c`) the inner command is
--- tallied recursively. A wrapper inner returns its unapproved sub-ranges
--- (translated into `src` coordinates) so the prompt pinpoints only the
--- genuinely-unapproved part — e.g. `rm -rf /` in `timeout 5 rm -rf /`, not the
--- known-safe `timeout 5` prefix. A single-quoted `-c` body (`raw_string`) maps
--- 1:1 and is pinpointed the same way; any other quoting (double, `$'...'`,
--- concatenation) processes the body, so it has no faithful coordinate mapping
--- and stays coarse: not-known-safe with no sub-ranges, falling back to the
--- whole-leaf highlight.
---
--- A dirty `$(...)` argument (bare or quoted `"$(...)"`) in an otherwise-safe
--- leaf pinpoints its in-place inner the same way, but needs no translation —
--- the inner is parsed as a child of the same tree, so its ranges are already
--- in `src` coordinates. Collected during `extract_args` via the inner-check
--- closure and returned at the tail. A leaf whose name itself is denied/unknown
--- bails before the tail, discarding the accumulator (the whole leaf is the
--- danger).
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param known table<string, string>|nil #3 constant environment of the enclosing sequence
--- @param funcs table<string, boolean>|nil #6 recorded function names of the enclosing sequence
--- @return boolean known_safe
--- @return agentic.utils.PermissionRules.Range[]|nil sub_ranges
local function command_known_safe(node, src, ctx, known, funcs)
    --- @type agentic.utils.PermissionRules.Range[]
    local subst_ranges = {}
    local args, arg_nodes, args_dynamic, name_node = extract_args(
        node,
        src,
        ctx,
        known,
        function(subst, s, c)
            return substitution_inner_collect(subst, s, c, subst_ranges)
        end
    )
    if not args then
        return false
    end

    if not name_node then
        return false
    end
    local name = command_name_text(name_node, src)
    if not name then
        return false
    end
    local cmd_name = M.strip_command_path(name)
    if CODE_TAKING_BUILTINS[cmd_name] then
        return false
    end

    local leaf = name
    if #args > 0 then
        leaf = leaf .. " " .. table.concat(args, " ")
    end

    if
        M.matches_any_pattern(leaf, ctx.deny)
        or M.matches_any_pattern(leaf, ctx.ask)
    then
        return false
    end

    -- #6: a call to a function recorded earlier in this sequence is known-safe
    -- (mirrors walk_command — body vetted at definition time for any args).
    if funcs and funcs[cmd_name] then
        return true
    end

    -- Transparent prefix: known-safe iff the inner tallies clean. A wrapper or
    -- single-quoted `-c` body pinpoints its unapproved sub-ranges; other `-c`
    -- quoting has no faithful mapping (nil origin) and stays coarse.
    local inner, origin =
        inner_source(cmd_name, node, args, arg_nodes, args_dynamic, src)
    if inner and ctx.depth < NESTED_MAX_DEPTH then
        local root = parse_zsh(inner)
        if not root then
            return false
        end
        --- @type agentic.utils.PermissionRules.Range[]
        local body_ranges = {}
        tally_walk(
            root,
            inner,
            vim.tbl_extend("force", ctx, { depth = ctx.depth + 1 }),
            body_ranges
        )
        if #body_ranges == 0 then
            return true
        end
        if origin then
            return false, translate_ranges(body_ranges, origin)
        end
        return false
    end

    local glob_safe = M.matches_any_pattern(leaf, ctx.read_only)
        or M.matches_any_pattern(leaf, ctx.safe_write)

    local struct_safe = false
    if next(ctx.structured_entries) ~= nil then
        local PermissionStructured =
            require("agentic.utils.permission_structured")
        local c = PermissionStructured.classify_leaf(ctx.structured_entries, {
            cmd_name = cmd_name,
            args = args,
            args_dynamic = args_dynamic,
        })
        if c.deny or c.ask then
            return false
        end
        struct_safe = c.read_only or c.safe_write
    end

    local safe = glob_safe or struct_safe
    if safe and #subst_ranges > 0 then
        -- Otherwise-safe leaf whose only problem is a dirty substitution:
        -- pinpoint the in-place inner instead of washing the whole leaf.
        return false, subst_ranges
    end
    return safe
end

--- Recurse a non-sequence container (`pipeline`, `variable_assignments`): every
--- named non-comment child is a statement.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
local function tally_children(node, src, ctx, ranges)
    for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            tally_walk(child, src, ctx, ranges)
        end
    end
end

--- Tally a straight-line sequence, threading the #3 constant environment so a
--- command whose only "unapproved" token is a resolved benign `$var` is not
--- highlighted (mirrors `walk_sequence`). UI-only — a stale binding here can only
--- mis-highlight, never mis-approve.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
local function tally_sequence(node, src, ctx, ranges)
    --- @type table<string, string>
    local known = {}
    --- @type table<string, boolean>
    local funcs = {}
    for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            local t = child:type()
            if t == "command" then
                local safe, sub_ranges =
                    command_known_safe(child, src, ctx, known, funcs)
                if not safe then
                    if sub_ranges then
                        for _, r in ipairs(sub_ranges) do
                            table.insert(ranges, r)
                        end
                    else
                        record(ranges, child)
                    end
                end
            elseif t == "function_definition" then
                -- Mirror walk_function_definition: a named definition is not run
                -- (body not highlighted); record the name if the body tallies
                -- clean. An anonymous function runs immediately, so highlight it.
                local name_node = child:field("name")[1]
                if name_node then
                    local name = vim.treesitter.get_node_text(name_node, src)
                    local body = child:field("body")[1]
                    --- @type agentic.utils.PermissionRules.Range[]
                    local body_ranges = {}
                    if body then
                        tally_walk(body, src, ctx, body_ranges)
                    end
                    -- Record on clean, un-record on unsafe redefinition.
                    funcs[name] = (body and #body_ranges == 0) or nil
                else
                    record(ranges, child)
                end
            else
                tally_walk(child, src, ctx, ranges)
            end
            update_known(known, child, src)
        end
    end
end

--- Tally a `redirected_statement`: the body recurses; any redirect that is not
--- a safe form (`> /dev/null`, FD duplication) records as unapproved.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
local function tally_redirected(node, src, ctx, ranges)
    for child, field in node:iter_children() do
        if field == "body" then
            tally_walk(child, src, ctx, ranges)
        elseif child:named() then
            if
                child:type() ~= "file_redirect"
                or not redirect_is_safe(child, src)
            then
                record(ranges, child)
            end
        end
    end
end

--- Tally a `for_statement`: a clean bare `$(...)` list item records nothing, a
--- dirty one pinpoints its inner, any other list-item substitution records (it
--- runs code that flows into body args); the `do_group` body recurses.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
local function tally_for(node, src, ctx, ranges)
    for child, field in node:iter_children() do
        if child:named() then
            if field == "value" then
                record_substitutions(child, src, ctx, ranges)
            elseif field == "body" then
                tally_walk(child, src, ctx, ranges)
            end
        end
    end
end

--- Tally a `while_statement` (covers `while`/`until`): condition and body each
--- recurse as statements.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
local function tally_while(node, src, ctx, ranges)
    for child, field in node:iter_children() do
        if child:named() and (field == "condition" or field == "body") then
            tally_walk(child, src, ctx, ranges)
        end
    end
end

--- Tally a `case_statement`: the matched value and each item pattern record
--- their substitutions (both run code during the match); each item body
--- recurses.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
local function tally_case(node, src, ctx, ranges)
    for child, field in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            if field == "value" then
                record_substitutions(child, src, ctx, ranges)
            elseif child:type() == "case_item" then
                for item_child, item_field in child:iter_children() do
                    if
                        item_child:named()
                        and item_child:type() ~= "comment"
                    then
                        if item_field == "value" then
                            record_substitutions(item_child, src, ctx, ranges)
                        else
                            tally_walk(item_child, src, ctx, ranges)
                        end
                    end
                end
            end
        end
    end
end

function tally_walk(node, src, ctx, ranges)
    local t = node:type()
    if t == "test_command" then
        record_substitutions(node, src, ctx, ranges)
    elseif t == "case_statement" then
        tally_case(node, src, ctx, ranges)
    elseif SEQUENCE_TYPES[t] or t == "do_group" or t == "compound_statement" then
        tally_sequence(node, src, ctx, ranges)
    elseif CONTAINER_TYPES[t] then
        tally_children(node, src, ctx, ranges)
    elseif t == "command" then
        local safe, sub_ranges = command_known_safe(node, src, ctx)
        if not safe then
            if sub_ranges then
                for _, r in ipairs(sub_ranges) do
                    table.insert(ranges, r)
                end
            else
                record(ranges, node)
            end
        end
    elseif t == "redirected_statement" then
        tally_redirected(node, src, ctx, ranges)
    elseif t == "variable_assignment" then
        local value = node:field("value")[1]
        if value then
            record_substitutions(value, src, ctx, ranges)
        end
    elseif t == "for_statement" then
        tally_for(node, src, ctx, ranges)
    elseif t == "while_statement" then
        tally_while(node, src, ctx, ranges)
    elseif t == "function_definition" then
        -- Mirror `walk`: a named definition is approved (body not run), so it
        -- records nothing; an anonymous function runs immediately and records.
        if node:field("name")[1] == nil then
            record(ranges, node)
        end
    else
        -- A bare substitution statement or any unknown/unmodelled node:
        -- highlight it. The decision walk fails closed here, so the prompt
        -- fired — show the user what triggered it.
        record(ranges, node)
    end
end

--- Tally the byte ranges of the parts of a Bash command that are NOT known-safe
--- — the leaves and structural nodes the permission prompt is asking about. The
--- highlight binds to the displayed (reformatted) command, so coordinates are
--- relative to `command`'s own lines (0-indexed rows, byte cols), matching
--- tree-sitter's `node:range()`.
---
--- Returns `nil` when the command does not parse (no parser / parse error) so
--- the caller can fall back to highlighting the whole block; an empty list means
--- it parsed and nothing needs attention (bare prompt). This is pure UI — it
--- never grants anything and binds to the *displayed* text, whereas the decision
--- walk binds to the raw `rawInput.command` (see notes/perm-highlight…).
--- @param command string
--- @return agentic.utils.PermissionRules.Range[]|nil
function M.tally_unapproved(command)
    if type(command) ~= "string" or command == "" then
        return nil
    end
    if #command > 65536 then
        return nil
    end

    local root = parse_zsh(command)
    if not root then
        return nil
    end

    --- @type agentic.utils.PermissionRules.TallyCtx
    local ctx = {
        read_only = M.get_read_only_patterns(),
        safe_write = M.get_safe_write_patterns(),
        deny = M.get_deny_patterns(),
        ask = M.get_ask_patterns(),
        structured_entries = M.get_structured_entries(),
        depth = 0,
    }
    --- @type agentic.utils.PermissionRules.Range[]
    local ranges = {}
    tally_walk(root, command, ctx, ranges)
    return ranges
end

-- ── Reject walk (deny rules reject immediately, no prompt) ───────────────────
--
-- A third traversal, parallel to the decision `walk` and the highlight
-- `tally_walk`. A `deny` gate must REJECT a command outright (no prompt), whereas
-- the decision walk collapses deny and ask into a single "not approved →
-- prompt". Reject is EXISTENTIAL (any one executed leaf matching a concrete deny
-- rejects the whole command), so it is a separate first-deny-wins pass rather
-- than a tri-state retrofit of the universal-AND decision walk.
--
-- Deny matching is CONCRETE-ONLY (see `PermissionStructured.deny_leaf`): a
-- dynamic token never satisfies a deny gate, so `rm $flags x` is not rejected —
-- it falls through to the approve walk, which wildcards the dynamic token,
-- withholds approval, and prompts. Net: concrete deny rejects,
-- laundered/uncertain deny prompts.

--- @alias agentic.utils.PermissionRules.RejectCtx { deny: agentic.utils.PermissionRules.CompiledPattern[], structured_entries: agentic.StructuredEntries, depth: integer }

--- Forward declaration — `reject_walk` and `command_is_denied` are mutually
--- recursive (a transparent-prefix wrapper re-walks its inner command).
--- @type fun(node: TSNode, src: string, ctx: agentic.utils.PermissionRules.RejectCtx): boolean
local reject_walk

--- Whether a single `command` leaf is a concrete deny: a glob deny pattern from
--- settings.json/Config, or a structured deny gate (concrete-only). A transparent
--- prefix (`timeout … cmd`, `sh -c '…'`) re-walks its inner command so a wrapped
--- deny still rejects. Returns false on any extraction bail — the leaf's own
--- denial cannot be established, and any executed substitution inside it is
--- visited separately by `reject_walk`'s child recursion.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.RejectCtx
--- @return boolean
local function command_is_denied(node, src, ctx)
    local args, arg_nodes, args_dynamic, name_node =
        extract_args(node, src, ctx, nil, function()
            return true
        end)
    if not args or not name_node then
        return false
    end
    local name = command_name_text(name_node, src)
    if not name then
        return false
    end
    local cmd_name = M.strip_command_path(name)

    -- Transparent prefix: a deny buried under `timeout`/`sh -c` still rejects.
    local inner =
        inner_source(cmd_name, node, args, arg_nodes, args_dynamic, src)
    if inner and ctx.depth < NESTED_MAX_DEPTH then
        local root = parse_zsh(inner)
        if
            root
            and reject_walk(
                root,
                inner,
                vim.tbl_extend("force", ctx, { depth = ctx.depth + 1 })
            )
        then
            return true
        end
    end

    local leaf = name
    if #args > 0 then
        leaf = leaf .. " " .. table.concat(args, " ")
    end
    if #ctx.deny > 0 and M.matches_any_pattern(leaf, ctx.deny) then
        return true
    end

    if next(ctx.structured_entries) ~= nil then
        local PermissionStructured =
            require("agentic.utils.permission_structured")
        return PermissionStructured.deny_leaf(ctx.structured_entries, {
            cmd_name = cmd_name,
            args = args,
            args_dynamic = args_dynamic,
        })
    end
    return false
end

--- Walk the parse tree, returning true on the first executed `command` leaf that
--- is a concrete deny. Recurses into every executed position — pipelines,
--- &&/||/; chains, loops, conditionals, redirected bodies, and command
--- substitutions — by descending into all named children. A
--- `function_definition` is skipped: defining a function never runs its body (a
--- later call laundering through it falls to the approve walk, which prompts).
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.RejectCtx
--- @return boolean
reject_walk = function(node, src, ctx)
    local t = node:type()
    if t == "function_definition" then
        return false
    end
    if t == "command" and command_is_denied(node, src, ctx) then
        return true
    end
    for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            if reject_walk(child, src, ctx) then
                return true
            end
        end
    end
    return false
end

--- Whether a Bash command must be REJECTED outright (a `deny` rule matched), as
--- opposed to merely not-approved. Parses with the zsh grammar and returns true
--- if any executed leaf is a concrete deny (a structured `deny` gate or a glob
--- deny pattern). Concrete-only — a dynamic token does not trigger a reject (it
--- falls through to the approve walk's prompt). Fail-closed-to-PROMPT: no parser,
--- a parse error, or an over-long command returns false so the command prompts
--- rather than silently rejecting.
--- @param command string
--- @return boolean
function M.should_auto_reject(command)
    if type(command) ~= "string" or command == "" then
        return false
    end
    if #command > 65536 then
        return false
    end

    local deny = M.get_deny_patterns()
    local structured_entries = M.get_structured_entries()
    if #deny == 0 and next(structured_entries) == nil then
        return false
    end

    local root = parse_zsh(command)
    if not root then
        return false
    end

    return reject_walk(root, command, {
        deny = deny,
        structured_entries = structured_entries,
        depth = 0,
    })
end

--- Check if a Bash command should be auto-approved. Parses the command with the
--- zsh grammar and walks the tree: every leaf command must match an allow
--- pattern, no leaf may match a deny or ask pattern, and any unmodelled
--- structure (argument-position substitution, file-writing redirect, dynamic
--- command name, subshell, brace group, negation) bails. Loops and if/case
--- control flow recurse into every branch. Fail-closed — an absent parser, a
--- parse error, or a truncated/malformed tree all return false.
---
--- `ok` means structurally approvable; the second return is the ordered list of
--- concrete file-mutating effects (redirect writes) the command would produce.
--- A structurally-ok command with effects STILL requires every effect to clear
--- at the policy layer before approval — `ok` alone is not approval (see
--- permission_manager's `_bash_effects_clear`). Empty effects means a pure
--- read/no-write command that approves on `ok` alone.
--- @param command string
--- @return boolean ok
--- @return agentic.utils.PermissionRules.Effect[] effects
function M.evaluate(command)
    if type(command) ~= "string" or command == "" then
        return false, {}
    end
    -- A pathologically long generated command could make parsing slow on this
    -- cold path. 64 KB is far above any real command — refuse rather than parse.
    if #command > 65536 then
        return false, {}
    end

    local allow = M.get_allow_patterns()
    local structured_entries = M.get_structured_entries()
    -- Skip the parse entirely when neither layer has any allow source — the
    -- walker has nothing to approve against.
    if #allow == 0 and next(structured_entries) == nil then
        return false, {}
    end

    local root = parse_zsh(command)
    if not root then
        return false, {}
    end

    --- @type agentic.utils.PermissionRules.Effect[]
    local effects = {}
    local ok = walk(root, command, {
        allow = allow,
        deny = M.get_deny_patterns(),
        ask = M.get_ask_patterns(),
        structured_entries = structured_entries,
        auto_approve = Config.permissions.auto_approve,
        depth = 0,
        effects = effects,
    })
    return ok, effects
end

--- Whether a command auto-approves on its own, with no trust scope. True iff it
--- is structurally approvable AND produces no file-mutating effects (a redirect
--- write needs `/trust tmp` to clear — see `evaluate` / `_bash_effects_clear`).
--- @param command string
--- @return boolean
function M.should_auto_approve(command)
    local ok, effects = M.evaluate(command)
    return ok and #effects == 0
end

--- Invalidate cached patterns (forces re-read on next check).
function M.invalidate_cache()
    cached_deny_patterns = nil
    cached_ask_patterns = nil
    cached_read_only_patterns = nil
    cached_safe_write_patterns = nil
    cached_plugin_structured_entries = nil
    cached_plugin_structured_mtime = 0
    cached_config_structured_ref = nil
    cached_config_structured_entries = {}
    cached_mtimes = {}
    cached_config_read_only_ref = nil
    cached_config_read_only_patterns = {}
    cached_config_safe_write_ref = nil
    cached_config_safe_write_patterns = {}
    cached_config_deny_ref = nil
    cached_config_deny_patterns = {}
    cached_config_ask_ref = nil
    cached_config_ask_patterns = {}
end

return M
