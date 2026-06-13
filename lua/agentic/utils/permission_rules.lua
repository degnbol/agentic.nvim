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

--- Extract Bash(...) allow patterns from a settings.json permissions table.
--- @param permissions table
--- @param list_key string "allow" or "deny" or "ask"
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function M.extract_bash_patterns(permissions, list_key)
    local patterns = {}
    local list = permissions[list_key]
    if type(list) ~= "table" then
        return patterns
    end
    for _, entry in ipairs(list) do
        if type(entry) == "string" then
            local inner = entry:match("^Bash%((.+)%)$")
            if inner then
                table.insert(patterns, {
                    original = inner,
                    lua_pattern = M.glob_to_lua_pattern(inner),
                })
            end
        end
    end
    return patterns
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
local function is_data_var_name(name)
    return name:match("^[a-z_]") ~= nil or name:match("^[A-Z]$") ~= nil
end

--- Strip a leading `stdbuf` line-buffering wrapper from a command leaf, so the
--- inner command is matched on its own (`stdbuf -oL grep x` becomes `grep x`).
--- Loops to handle chains. Variable-assignment prefixes (`LC_ALL=C grep x`,
--- `f=/path ls "$f"`) are no longer handled here — the walker validates and
--- excludes them structurally before the matcher sees the leaf.
--- @param segment string
--- @return string
function M.strip_wrapper_prefixes(segment)
    while true do
        local stripped = segment:gsub("^stdbuf%s+%-[a-zA-Z0-9]+%s+", "", 1)
        if stripped == segment then
            return segment
        end
        segment = stripped
    end
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
--- already excluded), so only the `stdbuf` wrapper and a system binary-dir
--- prefix remain to strip before matching.
--- @param segment string
--- @param patterns agentic.utils.PermissionRules.CompiledPattern[]
--- @return boolean
function M.matches_any_pattern(segment, patterns)
    local trimmed = vim.trim(segment)
    trimmed = M.strip_wrapper_prefixes(trimmed)
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

--- @alias agentic.utils.PermissionRules.WalkCtx { allow: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[] }

--- Container nodes whose every named child must itself pass. `do_group` and the
--- loop/conditional statements are intentionally absent — Phase 1a rejects all
--- control flow.
local CONTAINER_TYPES = {
    program = true,
    list = true,
    pipeline = true,
    variable_assignments = true,
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

--- Whether any node in the subtree is a dynamic name part (rejects an
--- interpolated command name built as a `concatenation`).
--- @param node TSNode
--- @return boolean
local function subtree_has_dynamic_name(node)
    if DYNAMIC_NAME_TYPES[node:type()] then
        return true
    end
    for child in node:iter_children() do
        if child:named() and subtree_has_dynamic_name(child) then
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
    return is_safe_env_name(name) or is_data_var_name(name)
end

--- Extract the literal command name from a `command_name` node, normalising
--- quotes so `"rm"` and `'rm'` resolve to `rm` (a quoted name must not evade a
--- deny pattern). Returns nil to bail on a dynamic name — a substitution,
--- expansion, arithmetic, or an interpolated `concatenation`.
--- @param command_name TSNode
--- @param src string
--- @return string|nil
local function command_name_text(command_name, src)
    local inner = command_name:named_child(0)
    if not inner then
        return nil
    end
    local t = inner:type()
    if DYNAMIC_NAME_TYPES[t] then
        return nil
    end
    if t == "string" then
        -- A double-quoted name is literal only with no interpolation child.
        local parts = {}
        for c in inner:iter_children() do
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
        local txt = vim.treesitter.get_node_text(inner, src)
        return (txt:gsub("^'", ""):gsub("'$", ""))
    end
    if t == "concatenation" and subtree_has_dynamic_name(inner) then
        return nil
    end
    return vim.treesitter.get_node_text(inner, src)
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

--- Forward declaration — `walk` and the per-node handlers are mutually
--- recursive.
--- @type fun(node: TSNode, src: string, ctx: agentic.utils.PermissionRules.WalkCtx): boolean
local walk

--- Walk a `command`: reject substitution anywhere, validate env-prefix
--- assignments, extract the literal name, then match the leaf (name + args,
--- with prefixes and redirects excluded) against the pattern buckets.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
local function walk_command(node, src, ctx)
    if subtree_has_substitution(node) then
        return false
    end

    local name_node
    --- @type string[]
    local args = {}
    for child in node:iter_children() do
        local t = child:type()
        if t == "variable_assignment" then
            if not safe_assignment_name(child, src) then
                return false
            end
        elseif t == "command_name" then
            name_node = child
        elseif child:named() then
            table.insert(args, vim.treesitter.get_node_text(child, src))
        end
    end

    if not name_node then
        return false
    end
    local name = command_name_text(name_node, src)
    if not name then
        return false
    end
    if CODE_TAKING_BUILTINS[M.strip_command_path(name)] then
        return false
    end

    local leaf = name
    if #args > 0 then
        leaf = leaf .. " " .. table.concat(args, " ")
    end

    if #ctx.deny > 0 and M.matches_any_pattern(leaf, ctx.deny) then
        return false
    end
    if #ctx.ask > 0 and M.matches_any_pattern(leaf, ctx.ask) then
        return false
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

--- Walk a statement-level `variable_assignment` (`f=path`, `arr=(a b c)`). It
--- executes nothing, so it is inert when the name is safe and the value holds
--- no substitution. A poisoned-name assignment (`PATH=/evil`) bails because a
--- later command would inherit it.
--- @param node TSNode
--- @param src string
--- @return boolean
local function walk_assignment(node, src)
    if subtree_has_substitution(node) then
        return false
    end
    return safe_assignment_name(node, src)
end

function walk(node, src, ctx)
    local t = node:type()
    if CONTAINER_TYPES[t] then
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
        return walk_assignment(node, src)
    end
    return false
end

--- Check if a Bash command should be auto-approved. Parses the command with the
--- zsh grammar and walks the tree: every leaf command must match an allow
--- pattern, no leaf may match a deny or ask pattern, and any non-simple
--- structure (substitution, control flow, file-writing redirect, dynamic
--- command name) bails. Fail-closed — an absent parser, a parse error, or a
--- truncated/malformed tree all return false.
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
    if #allow == 0 then
        return false
    end

    local ok, root = pcall(function()
        local parser = vim.treesitter.get_string_parser(command, "zsh")
        return parser:parse(true)[1]:root()
    end)
    if not ok or not root or root:has_error() then
        return false
    end

    return walk(root, command, {
        allow = allow,
        deny = M.get_deny_patterns(),
        ask = M.get_ask_patterns(),
    })
end

--- Invalidate cached patterns (forces re-read on next check).
function M.invalidate_cache()
    cached_deny_patterns = nil
    cached_ask_patterns = nil
    cached_read_only_patterns = nil
    cached_safe_write_patterns = nil
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
