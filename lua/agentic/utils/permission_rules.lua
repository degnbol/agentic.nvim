local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.utils.PermissionRules
local M = {}

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
function M.strip_command_path(segment)
    for _, dir in ipairs(SYSTEM_BIN_DIRS) do
        if segment:sub(1, #dir) == dir then
            return segment:sub(#dir + 1)
        end
    end
    return segment
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

--- @alias agentic.utils.PermissionRules.WalkCtx { allow: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[], structured_entries: agentic.StructuredEntries, auto_approve: agentic.PermAutoApprove, depth: integer }

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
--- launders dangerous tokens past the deny/ask layer (`find $(echo -exec rm)`),
--- so Phase 1a bails on all of them — assignment-position recursion is Phase 2.
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
    return literal_token(inner, src)
end

--- Whether a `file_redirect` is a safe form: a write to /dev/null, or a file
--- descriptor duplication (`2>&1`, `>&2`, `N>&M`). Every other target is a file
--- write (or an unmodelled redirect) and bails. A substitution in the target
--- (`cat > $(echo out)`) bails first.
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
    return vim.treesitter.get_node_text(dest, src) == "/dev/null"
end

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
--- @class agentic.utils.PermissionRules.WrapperSpec
--- @field value_opts? string[] options whose value is the next token (`-s KILL`)
--- @field flag_opts? string[] boolean options (consume themselves only)
--- @field attached? string[] Lua patterns for self-contained forms — attached short value (`-oL`), `--long=value`, bare numeric (`-5`)
--- @field positionals? integer count of fixed positional operands before the inner command (timeout's `DURATION` = 1); skipped by count, not inspected

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
--- @type table<string, agentic.utils.PermissionRules.WrapperSpec>
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
--- @param spec agentic.utils.PermissionRules.WrapperSpec
--- @return integer|nil inner_idx
local function skip_wrapper_operands(args, spec)
    local i = 1
    while args[i] and args[i]:sub(1, 1) == "-" do
        local opt = args[i]
        if spec.value_opts and vim.tbl_contains(spec.value_opts, opt) then
            i = i + 2 -- value is the next token (`-s KILL`)
        elseif
            -- boolean flag, or a self-contained form (`-oL`, `--signal=K`, `-5`)
            (spec.flag_opts and vim.tbl_contains(spec.flag_opts, opt))
            or (spec.attached and matches_any_lua_pattern(opt, spec.attached))
        then
            i = i + 1
        else
            return nil
        end
    end
    return i + (spec.positionals or 0)
end

--- @alias agentic.utils.PermissionRules.Origin [integer, integer]

--- Resolve the inner command to recurse into for a transparent prefix — an
--- inline shell `-c '<body>'` or an exec-wrapper (`timeout`/`time`/`stdbuf`).
--- Returns nil to fall through to the leaf matchers (not a shell or
--- wrapper, missing/dynamic body, malformed operands, empty inner).
---
--- The `-c` body comes quote-stripped from `args` (a `-c` may be the trailing
--- letter of a short-flag cluster like `-lc`, still consuming the next word);
--- origin is nil because its quote-stripped coordinates cannot be mapped back to
--- `src`. The wrapper inner is a raw substring of `src` (quotes/escapes intact)
--- from the inner node's start to the wrapper command node's end, with the inner
--- node's `(row, col)` as origin for translating tally ranges.
--- @param cmd_name string command name, already path-stripped
--- @param node TSNode the `command` node
--- @param args string[] quote-stripped arg tokens
--- @param arg_nodes TSNode[] the arg token nodes, parallel to `args`
--- @param args_dynamic boolean[]
--- @param src string
--- @return string|nil inner
--- @return agentic.utils.PermissionRules.Origin|nil origin
local function inner_source(cmd_name, node, args, arg_nodes, args_dynamic, src)
    if SHELL_C_COMMANDS[cmd_name] then
        for i, arg in ipairs(args) do
            if arg:match("^%-[a-zA-Z]*c$") then
                local body = args[i + 1]
                if body ~= nil and not args_dynamic[i + 1] then
                    return body, nil
                end
                return nil, nil -- missing or dynamic body
            end
        end
        return nil, nil
    end

    local spec = EXEC_WRAPPERS[cmd_name]
    if not spec then
        return nil, nil
    end
    local inner_idx = skip_wrapper_operands(args, spec)
    if not inner_idx then
        return nil, nil
    end
    local inner_node = arg_nodes[inner_idx]
    if not inner_node then
        return nil, nil -- empty inner
    end
    local sr, sc, inner_start_byte = inner_node:range(true)
    local _, _, _, _, _, node_end_byte = node:range(true)
    return src:sub(inner_start_byte + 1, node_end_byte), { sr, sc }
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

--- Walk a `command`: validate the name and each argument by position
--- (substitution is recursed in argument position, bailed elsewhere), validate
--- env-prefix assignments, then combine the glob
--- and structured layers (composition rule in the `permissions` project skill).
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
local function walk_command(node, src, ctx)
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
                return false
            end
        elseif t == "command_name" then
            -- A substitution-bearing name is dynamic; command_name_text returns
            -- nil for it below and we bail.
            name_node = child
        elseif t == "command_substitution" then
            -- A bare `$(...)` argument: vet the inner command (it runs), then
            -- splice its output into the arg stream as a dynamic token. The
            -- dynamic flag makes the structured layer wildcard deny/ask, so a
            -- payload like `find . $(echo -exec rm)` still prompts.
            if not walk_substitution_inner(child, src, ctx) then
                return false
            end
            table.insert(args, vim.treesitter.get_node_text(child, src))
            table.insert(args_dynamic, true)
        elseif child:named() then
            -- Any other substitution-bearing argument (string-embedded
            -- `"$(…)"`, concatenation `a$(b)c`, process substitution `<(…)`) is
            -- not handled by the dynamic-token machinery — bail.
            if subtree_has_substitution(child) then
                return false
            end
            local tok = literal_token(child, src)
            if tok == nil then
                return false
            end
            table.insert(args, tok)
            table.insert(arg_nodes, child)
            table.insert(args_dynamic, token_is_dynamic(child))
        end
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

    -- Transparent prefix (inline `sh -c '<body>'` or exec-wrapper): walk the
    -- inner command instead of treating the prefix as an opaque leaf. Must run
    -- before the structured matcher so a shell's `c` gate does not pre-empt the
    -- `-c` recursion. A body at the depth cap, or one that does not resolve,
    -- falls through to the leaf matchers.
    local inner = inner_source(cmd_name, node, args, arg_nodes, args_dynamic, src)
    if inner and ctx.depth < NESTED_MAX_DEPTH then
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
        if structured == "deny" or structured == "ask" then
            return false
        end
    end

    if structured == "allow" then
        return true
    end
    return M.matches_any_pattern(leaf, ctx.allow)
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
            if
                child:type() ~= "file_redirect"
                or not redirect_is_safe(child, src)
            then
                return false
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
--- so the structured layer wildcards deny/ask over it. The non-bare forms
--- (string-embedded `"$(…)"`, concatenation, process substitution) are bailed
--- by `subtree_has_substitution` at the call site before reaching here.
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

--- Walk a `do_group`: every named child is a statement that must pass.
--- Anonymous separators (`do`, `done`, `;`) and `comment` nodes are skipped
--- (mirrors the container walk).
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
local function walk_do_group(node, src, ctx)
    for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            if not walk(child, src, ctx) then
                return false
            end
        end
    end
    return true
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
    elseif CONTAINER_TYPES[t] then
        -- Iterate named children only — anonymous separators (`;`, `&&`, `|`,
        -- `&`, newline) and `comment` nodes carry no executable content.
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
    elseif t == "do_group" then
        return walk_do_group(node, src, ctx)
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

--- Record every command/process substitution node in a subtree without
--- descending into it. Substitution is always a "look before OK" case (it runs
--- code the matcher cannot inspect), so it highlights wherever it appears
--- outside a command leaf (for-list, case value/pattern, assignment value,
--- test). Inside a `command` it is absorbed into the whole-command range.
--- @param node TSNode
--- @param ranges agentic.utils.PermissionRules.Range[]
local function record_substitutions(node, ranges)
    if SUBSTITUTION_TYPES[node:type()] then
        record(ranges, node)
        return
    end
    for child in node:iter_children() do
        if child:named() then
            record_substitutions(child, ranges)
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

--- Whether a `command_substitution`'s inner tallies clean: every inner
--- statement is a valid inner type AND records no unapproved range. Mirrors
--- `walk_substitution_inner` for the highlight pass, so an approved
--- `cmd $(...)` does not light up its whole leaf.
--- @param subst TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @return boolean
local function substitution_inner_clean(subst, src, ctx)
    local saw_statement = false
    --- @type agentic.utils.PermissionRules.Range[]
    local sub_ranges = {}
    for child in subst:iter_children() do
        if child:named() and child:type() ~= "comment" then
            if not SUBSTITUTION_INNER_STATEMENT_TYPES[child:type()] then
                return false
            end
            tally_walk(child, src, ctx, sub_ranges)
            saw_statement = true
        end
    end
    return saw_statement and #sub_ranges == 0
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
--- known-safe `timeout 5` prefix. The `-c` body has no faithful coordinate
--- mapping (quote-stripped), so it stays coarse: not-known-safe with no
--- sub-ranges, falling back to the whole-leaf highlight.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @return boolean known_safe
--- @return agentic.utils.PermissionRules.Range[]|nil sub_ranges
local function command_known_safe(node, src, ctx)
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
            if
                not safe_assignment_name(child, src)
                or subtree_has_substitution(child)
            then
                return false
            end
        elseif t == "command_name" then
            name_node = child
        elseif t == "command_substitution" then
            -- Mirror walk_command: a bare `$(...)` arg is known-safe only if its
            -- inner tallies clean; then treat its output as a dynamic token.
            if not substitution_inner_clean(child, src, ctx) then
                return false
            end
            table.insert(args, vim.treesitter.get_node_text(child, src))
            table.insert(args_dynamic, true)
        elseif child:named() then
            if subtree_has_substitution(child) then
                return false
            end
            local tok = literal_token(child, src)
            if tok == nil then
                return false
            end
            table.insert(args, tok)
            table.insert(arg_nodes, child)
            table.insert(args_dynamic, token_is_dynamic(child))
        end
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

    -- Transparent prefix: known-safe iff the inner tallies clean. A wrapper
    -- inner pinpoints its unapproved sub-ranges; the `-c` body stays coarse.
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

    return glob_safe or struct_safe
end

--- Recurse a container/`do_group`: every named non-comment child is a statement.
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

--- Tally a `for_statement`: a clean bare `$(...)` list item is approved; any
--- other list-item substitution records (it runs code that flows into body
--- args); the `do_group` body recurses.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
local function tally_for(node, src, ctx, ranges)
    for child, field in node:iter_children() do
        if child:named() then
            if field == "value" then
                -- A clean bare `$(...)` list item is approved (mirrors
                -- walk_for) and does not highlight; any other substitution
                -- records.
                if
                    not (
                        child:type() == "command_substitution"
                        and substitution_inner_clean(child, src, ctx)
                    )
                then
                    record_substitutions(child, ranges)
                end
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
                record_substitutions(child, ranges)
            elseif child:type() == "case_item" then
                for item_child, item_field in child:iter_children() do
                    if
                        item_child:named()
                        and item_child:type() ~= "comment"
                    then
                        if item_field == "value" then
                            record_substitutions(item_child, ranges)
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
        record_substitutions(node, ranges)
    elseif t == "case_statement" then
        tally_case(node, src, ctx, ranges)
    elseif CONTAINER_TYPES[t] or t == "do_group" then
        tally_children(node, src, ctx, ranges)
    elseif t == "command" then
        local known, sub_ranges = command_known_safe(node, src, ctx)
        if not known then
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
            record_substitutions(value, ranges)
        end
    elseif t == "for_statement" then
        tally_for(node, src, ctx, ranges)
    elseif t == "while_statement" then
        tally_while(node, src, ctx, ranges)
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

--- Check if a Bash command should be auto-approved. Parses the command with the
--- zsh grammar and walks the tree: every leaf command must match an allow
--- pattern, no leaf may match a deny or ask pattern, and any unmodelled
--- structure (argument-position substitution, file-writing redirect, dynamic
--- command name, subshell, brace group, negation) bails. Loops and if/case
--- control flow recurse into every branch. Fail-closed — an absent parser, a
--- parse error, or a truncated/malformed tree all return false.
--- @param command string
--- @return boolean
function M.should_auto_approve(command)
    if type(command) ~= "string" or command == "" then
        return false
    end
    -- A pathologically long generated command could make parsing slow on this
    -- cold path. 64 KB is far above any real command — refuse rather than parse.
    if #command > 65536 then
        return false
    end

    local allow = M.get_allow_patterns()
    local structured_entries = M.get_structured_entries()
    -- Skip the parse entirely when neither layer has any allow source — the
    -- walker has nothing to approve against.
    if #allow == 0 and next(structured_entries) == nil then
        return false
    end

    local root = parse_zsh(command)
    if not root then
        return false
    end

    return walk(root, command, {
        allow = allow,
        deny = M.get_deny_patterns(),
        ask = M.get_ask_patterns(),
        structured_entries = structured_entries,
        auto_approve = Config.permissions.auto_approve,
        depth = 0,
    })
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
