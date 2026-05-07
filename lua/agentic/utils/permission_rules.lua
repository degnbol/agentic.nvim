local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.utils.PermissionRules
local M = {}

--- @class agentic.utils.PermissionRules.CompiledPattern
--- @field original string
--- @field lua_pattern string

--- @type agentic.utils.PermissionRules.CompiledPattern[]|nil
local cached_allow_patterns

--- @type agentic.utils.PermissionRules.CompiledPattern[]|nil
local cached_deny_patterns

--- mtime of each settings.json at last load, keyed by path
--- @type table<string, number>
local cached_mtimes = {}

--- Compiled patterns from Config.read_only_commands, keyed by the table
--- reference at last compile so we recompile only when the user replaces
--- the list (rare).
--- @type table|nil, agentic.utils.PermissionRules.CompiledPattern[]
local cached_config_allow_ref, cached_config_allow_patterns = nil, {}
--- @type table|nil, agentic.utils.PermissionRules.CompiledPattern[]
local cached_config_deny_ref, cached_config_deny_patterns = nil, {}

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

--- Convert a settings.json glob pattern to a Lua pattern.
--- `*` matches anything except shell operators (|, &, ;).
--- @param glob string
--- @return string lua_pattern
function M.glob_to_lua_pattern(glob)
    local result = {}
    local i = 1
    while i <= #glob do
        local ch = glob:sub(i, i)
        if ch == "*" then
            table.insert(result, "[^|;&]*")
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

--- Load and cache allow/deny patterns from ~/.claude/settings.json and
--- project-level .claude/settings.json. Re-reads automatically when file
--- mtimes change (handles both in-editor and external edits).
function M.load_patterns()
    if cached_allow_patterns and not settings_changed() then
        return
    end

    cached_allow_patterns = {}
    cached_deny_patterns = {}

    local global_path, project_path = M.settings_paths()

    cached_mtimes[global_path] = get_mtime(global_path)
    cached_mtimes[project_path] = get_mtime(project_path)

    local global = M.read_json(global_path)
    if global and global.permissions then
        vim.list_extend(
            cached_allow_patterns,
            M.extract_bash_patterns(global.permissions, "allow")
        )
        vim.list_extend(
            cached_deny_patterns,
            M.extract_bash_patterns(global.permissions, "deny")
        )
        vim.list_extend(
            cached_deny_patterns,
            M.extract_bash_patterns(global.permissions, "ask")
        )
    end

    local project = M.read_json(project_path)
    if project and project.permissions then
        vim.list_extend(
            cached_allow_patterns,
            M.extract_bash_patterns(project.permissions, "allow")
        )
        vim.list_extend(
            cached_deny_patterns,
            M.extract_bash_patterns(project.permissions, "deny")
        )
        vim.list_extend(
            cached_deny_patterns,
            M.extract_bash_patterns(project.permissions, "ask")
        )
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

--- Harmless command wrappers prepended by hooks (e.g. shell-guard.sh).
--- Stripped before pattern matching so allow rules match the inner command.
local HARMLESS_PREFIXES = {
    "^stdbuf%s+%-[a-zA-Z0-9]+%s+",
}

--- Strip known harmless wrapper prefixes from a command segment.
--- @param segment string
--- @return string
function M.strip_wrapper_prefixes(segment)
    for _, prefix_pat in ipairs(HARMLESS_PREFIXES) do
        local stripped = segment:gsub(prefix_pat, "", 1)
        if stripped ~= segment then
            return stripped
        end
    end
    return segment
end

--- Detect output redirection that would write to a file.
--- Call AFTER `strip_devnull_redirects` so harmless `>/dev/null` and `2>&1`
--- forms don't trigger. Recognises `>`, `>>`, `2>`, `&>` (write) and
--- `>&N` where N is a digit (fd dup, not a file write — `>&2`, `2>&1`,
--- etc. are allowed). Quoted `>` is ignored.
---
--- This is the safety net that lets the read-only command list stay
--- focused on the COMMAND being read-only — without it, `cat foo > evil`
--- would match `Bash(cat *)` because `[^|;&]*` lets `>` through, and
--- silently write the file.
--- @param segment string
--- @return boolean
function M.has_unsafe_redirect(segment)
    local in_single = false
    local in_double = false
    local i = 1
    local len = #segment
    while i <= len do
        local ch = segment:sub(i, i)
        if ch == "'" and not in_double then
            in_single = not in_single
            i = i + 1
        elseif ch == '"' and not in_single then
            in_double = not in_double
            i = i + 1
        elseif not in_single and not in_double and ch == ">" then
            local next_ch = segment:sub(i + 1, i + 1)
            if next_ch == "&" then
                local third_ch = segment:sub(i + 2, i + 2)
                if third_ch:match("%d") then
                    -- >&N where N is a digit = fd duplication, not a file write
                    i = i + 3
                else
                    -- >&filename = combined output redirect (rare bash idiom)
                    return true
                end
            else
                -- > file, >> file, 2> file, &> file = file write
                return true
            end
        else
            i = i + 1
        end
    end
    return false
end

--- Strip harmless redirects from a command segment: writes to /dev/null
--- and file descriptor duplications (`2>&1`, `>&2`, `N>&M`). All of these
--- are no-ops or terminal-only writes — never write to a user file. Run
--- before pattern matching so `[^|;&]*` doesn't choke on the `&` in
--- `>&N`. Other redirect targets are left intact for `has_unsafe_redirect`
--- to detect.
--- @param segment string
--- @return string
function M.strip_devnull_redirects(segment)
    -- Order matters: longer/combined patterns before shorter ones
    segment = segment:gsub("%s*&>/dev/null", "")
    segment = segment:gsub("%s*2>/dev/null", "")
    segment = segment:gsub("%s*>/dev/null", "")
    -- File descriptor duplications: N>&M and >&N (digit only)
    segment = segment:gsub("%s*%d+>&%d+", "")
    segment = segment:gsub("%s*>&%d+", "")
    return segment
end

--- Replace shell operators (`|`, `;`, `&`) that sit inside quoted regions
--- with a safe placeholder. The splitter preserves quoted operators in a
--- segment (test: "preserves operators inside single quotes"), but compiled
--- allow patterns use `[^|;&]*` for `*`, which would reject the segment.
--- Masking only the quoted occurrences lets the match succeed without
--- weakening the operator exclusion against top-level operators (which the
--- splitter has already removed).
--- @param segment string
--- @return string
function M.mask_quoted_operators(segment)
    local result = {}
    local in_single = false
    local in_double = false
    for i = 1, #segment do
        local ch = segment:sub(i, i)
        if ch == "'" and not in_double then
            in_single = not in_single
            table.insert(result, ch)
        elseif ch == '"' and not in_single then
            in_double = not in_double
            table.insert(result, ch)
        elseif
            (in_single or in_double)
            and (ch == "|" or ch == ";" or ch == "&")
        then
            table.insert(result, "x")
        else
            table.insert(result, ch)
        end
    end
    return table.concat(result)
end

--- Split a command string on top-level shell operators (|, ||, &&, ;).
--- Returns nil if the command contains unsafe constructs (subshells, unbalanced
--- quotes, process substitution).
--- @param command string
--- @return string[]|nil segments
function M.split_command(command)
    -- Bail on subshells and process substitution
    if command:find("%$%(") or command:find("`") then
        return nil
    end
    if command:find("<%(") or command:find(">%(") then
        return nil
    end

    local segments = {}
    local current = {}
    local in_single = false
    local in_double = false
    local i = 1
    local len = #command

    while i <= len do
        local ch = command:sub(i, i)
        local advance = 1
        local split = false

        if ch == "'" and not in_double then
            in_single = not in_single
            table.insert(current, ch)
        elseif ch == '"' and not in_single then
            in_double = not in_double
            table.insert(current, ch)
        elseif not in_single and not in_double then
            local next_ch = command:sub(i + 1, i + 1)
            if
                (ch == "|" and next_ch == "|") or (ch == "&" and next_ch == "&")
            then
                split = true
                advance = 2
            elseif ch == "|" or ch == ";" then
                split = true
            else
                table.insert(current, ch)
            end
        else
            table.insert(current, ch)
        end

        if split then
            table.insert(segments, table.concat(current))
            current = {}
        end

        i = i + advance
    end

    -- Unbalanced quotes
    if in_single or in_double then
        return nil
    end

    table.insert(segments, table.concat(current))
    return segments
end

--- Check if a single command segment matches any compiled pattern.
--- @param segment string
--- @param patterns agentic.utils.PermissionRules.CompiledPattern[]
--- @return boolean
function M.matches_any_pattern(segment, patterns)
    local trimmed = vim.trim(segment)
    trimmed = M.strip_wrapper_prefixes(trimmed)
    trimmed = M.strip_devnull_redirects(trimmed)
    trimmed = vim.trim(trimmed)

    if trimmed == "" then
        return false
    end

    local masked = M.mask_quoted_operators(trimmed)

    for _, pat in ipairs(patterns) do
        if masked:match(pat.lua_pattern) then
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

--- Resolve the merged allow-pattern list: settings.json patterns plus
--- Config.read_only_commands (when enabled). The config list is recompiled
--- only when its table reference changes.
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function M.get_allow_patterns()
    M.load_patterns()
    local result = {}
    vim.list_extend(result, cached_allow_patterns or {})
    if Config.auto_approve_read_only_commands then
        local list = Config.read_only_commands
        if list ~= cached_config_allow_ref then
            cached_config_allow_ref = list
            cached_config_allow_patterns = patterns_from_strings(list)
        end
        vim.list_extend(result, cached_config_allow_patterns)
    end
    return result
end

--- Resolve the merged deny-pattern list: settings.json deny/ask plus
--- Config.read_only_commands_deny (when enabled).
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function M.get_deny_patterns()
    M.load_patterns()
    local result = {}
    vim.list_extend(result, cached_deny_patterns or {})
    if Config.auto_approve_read_only_commands then
        local list = Config.read_only_commands_deny
        if list ~= cached_config_deny_ref then
            cached_config_deny_ref = list
            cached_config_deny_patterns = patterns_from_strings(list)
        end
        vim.list_extend(result, cached_config_deny_patterns)
    end
    return result
end

--- Check if a compound Bash command should be auto-approved.
--- Every segment must match an allow pattern, and no segment may match a
--- deny/ask pattern. Returns false for empty commands, unsafe constructs,
--- or any unmatched segment.
--- @param command string
--- @return boolean
function M.should_auto_approve(command)
    local allow = M.get_allow_patterns()
    local deny = M.get_deny_patterns()

    if #allow == 0 then
        return false
    end

    local segments = M.split_command(command)
    if not segments or #segments == 0 then
        return false
    end

    for _, seg in ipairs(segments) do
        local trimmed = vim.trim(seg)
        if trimmed == "" then
            return false
        end

        -- Output redirection is a write regardless of the command, so
        -- reject before pattern matching. /dev/null forms are stripped
        -- first because they're harmless.
        local stripped = M.strip_devnull_redirects(trimmed)
        if M.has_unsafe_redirect(stripped) then
            return false
        end

        -- Deny/ask patterns take precedence
        if #deny > 0 and M.matches_any_pattern(trimmed, deny) then
            return false
        end

        if not M.matches_any_pattern(trimmed, allow) then
            return false
        end
    end

    return true
end

--- Invalidate cached patterns (forces re-read on next check).
function M.invalidate_cache()
    cached_allow_patterns = nil
    cached_deny_patterns = nil
    cached_mtimes = {}
    cached_config_allow_ref = nil
    cached_config_allow_patterns = {}
    cached_config_deny_ref = nil
    cached_config_deny_patterns = {}
end

return M
