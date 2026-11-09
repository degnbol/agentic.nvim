local Config = require("agentic.config")
local ExecutedCode = require("agentic.utils.executed_code")
local FileSystem = require("agentic.utils.file_system")
local PermissionStructured = require("agentic.utils.permission_structured")

--- @class agentic.utils.PermissionRules
local M = {}

-- Structural shell-parse primitives live once in shell_parse.lua. The `walk` and
-- `tally_walk` traversals below decide auto-approval on top of these; the same
-- module's `extract_commands` builds the flat command list from them.
local ShellParse = require("agentic.utils.shell_parse")
local ZshArithmetic = require("agentic.utils.zsh_arithmetic")
local ZshParse = require("agentic.utils.zsh_parse")
local parse_zsh = ZshParse.parse
local parse_zsh_untrusted = ZshParse.parse_untrusted
local literal_token = ShellParse.literal_token
local pure_literal_token = ShellParse.pure_literal_token
local subtree_has_substitution = ShellParse.subtree_has_substitution
local safe_assignment_name = ShellParse.safe_assignment_name
local token_is_dynamic = ShellParse.token_is_dynamic
local redirect_is_safe = ShellParse.redirect_is_safe
local redirect_write_dest = ShellParse.redirect_write_dest
local redirect_is_truncate = ShellParse.redirect_is_truncate
local heredoc_pure_body = ShellParse.heredoc_pure_body
local redirected_parts = ShellParse.redirected_parts
local is_bare_cat = ShellParse.is_bare_cat
local inner_source = ShellParse.inner_source
local script_file_source = ShellParse.script_file_source
local script_paths = ShellParse.script_paths
local resolve_against_cwd = ShellParse.resolve_against_cwd
local cwds_union = ShellParse.cwds_union
local unknown_cwds = ShellParse.unknown_cwds
local CONTAINER_TYPES = ShellParse.CONTAINER_TYPES
local SUBSTITUTION_TYPES = ShellParse.SUBSTITUTION_TYPES
local SUBSTITUTION_INNER_STATEMENT_TYPES =
    ShellParse.SUBSTITUTION_INNER_STATEMENT_TYPES
local CODE_TAKING_BUILTINS = ShellParse.CODE_TAKING_BUILTINS
local NESTED_MAX_DEPTH = ShellParse.NESTED_MAX_DEPTH

M.strip_command_path = ShellParse.strip_command_path

--- True iff a builtin call must prompt whatever the rules say: a code-taking
--- builtin (`eval`, or `source`/`.` whose file does not resolve), a builtin
--- that evaluates an argument as arithmetic that reads a value, or a
--- `printf -v`/`read` call whose target or option words are dynamic or bind a
--- name that can change execution (`read path`).
--- @param cmd_name string path-stripped command name
--- @param args string[] delivered words, dynamic ones as raw text
--- @param args_dynamic boolean[] parallel to `args`: true for a runtime-expanding word
--- @param script_path string|nil script operand of a script execution, as written
--- @return boolean
local function refuses_builtin(cmd_name, args, args_dynamic, script_path)
    if
        (CODE_TAKING_BUILTINS[cmd_name] and not script_path)
        or ZshArithmetic.builtin_args_read_value(cmd_name, args)
    then
        return true
    end
    local targets =
        ShellParse.builtin_bind_targets(cmd_name, args, args_dynamic)
    if not targets then
        return true
    end
    for _, name in ipairs(targets) do
        if not ShellParse.is_safe_var_name(name) then
            return true
        end
    end
    return false
end

--- @alias agentic.utils.PermissionRules.Origin agentic.utils.ShellParse.Origin

--- @class agentic.utils.PermissionRules.CompiledPattern
--- @field original string
--- @field lua_pattern string

--- @alias agentic.utils.PermissionRules.SettingsList "allow"|"deny"|"ask"

--- Settings.json patterns of one Claude config directory.
--- @class agentic.utils.PermissionRules.SettingsCache
--- @field patterns table<agentic.utils.PermissionRules.SettingsList, agentic.utils.PermissionRules.CompiledPattern[]> Compiled, keyed by permissions list
--- @field mtimes table<string, number> mtime of each settings.json when `patterns` was loaded, keyed by path. Per entry, because every config directory shares the project settings.json

--- Keyed by Claude config directory
--- @type table<string, agentic.utils.PermissionRules.SettingsCache>
local cached_settings_patterns = {}

--- Commands `is_read_only` has judged under `read_only_entries`, and the
--- verdict.
--- @type table<string, boolean>
local cached_read_only = {}
--- The structured entries `cached_read_only` was judged under.
--- @type agentic.StructuredEntries|nil
local read_only_entries

--- Compile the `Bash(...)` entries of one list in a settings.json permissions
--- table. Skips other tools' entries and malformed strings.
--- @param permissions table settings.json `permissions` table
--- @param list_key agentic.utils.PermissionRules.SettingsList
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function M.extract_bash_patterns(permissions, list_key)
    local out = {}
    local entries = permissions[list_key]
    if type(entries) ~= "table" then
        return out
    end
    for _, entry in ipairs(entries) do
        if type(entry) == "string" then
            local inner = entry:match("^Bash%((.+)%)$")
            if inner then
                table.insert(out, {
                    original = inner,
                    lua_pattern = PermissionStructured.glob_to_lua_pattern(
                        inner
                    ),
                })
            end
        end
    end
    return out
end

--- Paths of the global and the project Claude settings.json.
--- @param config_dir string Claude's config directory
--- @return string global_path In `config_dir`
--- @return string project_path Relative to the cwd
function M.settings_paths(config_dir)
    return config_dir .. "/settings.json", ".claude/settings.json"
end

--- Check if any settings.json has changed since the cached load for
--- `config_dir`.
--- @param config_dir string Claude's config directory
--- @return boolean
local function settings_changed(config_dir)
    local mtimes = cached_settings_patterns[config_dir].mtimes
    local global_path, project_path = M.settings_paths(config_dir)
    return FileSystem.mtime(global_path) ~= mtimes[global_path]
        or FileSystem.mtime(project_path) ~= mtimes[project_path]
end

--- Compiled `Bash(...)` patterns of one list, merged from the global and
--- project settings.json. Empty when
--- `Config.permissions.use_claude_settings` is off. Re-reads the files when
--- their mtimes change.
--- @param list_key agentic.utils.PermissionRules.SettingsList
--- @param config_dir string Claude's config directory
--- @return agentic.utils.PermissionRules.CompiledPattern[] patterns shared with the cache; do not mutate
function M.get_settings_patterns(list_key, config_dir)
    if
        not cached_settings_patterns[config_dir]
        or settings_changed(config_dir)
    then
        local global_path, project_path = M.settings_paths(config_dir)
        local patterns = { allow = {}, deny = {}, ask = {} }
        cached_settings_patterns[config_dir] = {
            patterns = patterns,
            mtimes = {
                [global_path] = FileSystem.mtime(global_path),
                [project_path] = FileSystem.mtime(project_path),
            },
        }

        if Config.permissions.use_claude_settings then
            for _, path in ipairs({ global_path, project_path }) do
                local settings = FileSystem.read_json_if_present(path)
                if settings and settings.permissions then
                    for key, list in pairs(patterns) do
                        vim.list_extend(
                            list,
                            M.extract_bash_patterns(settings.permissions, key)
                        )
                    end
                end
            end
        end
    end
    return cached_settings_patterns[config_dir].patterns[list_key]
end

--- `permissions.additionalDirectories` of the global settings.json, with a
--- `~` or `~/` home prefix expanded and other entries as written. Skips
--- entries that are not non-empty strings. Empty when the file is missing or
--- not valid JSON.
--- @param config_dir string Claude's config directory
--- @return string[] dirs
function M.get_additional_directories(config_dir)
    local global_path = M.settings_paths(config_dir)
    local settings = FileSystem.read_json_if_present(global_path)
    if
        not settings
        or not settings.permissions
        or not settings.permissions.additionalDirectories
    then
        return {}
    end

    local dirs = {}
    for _, dir in ipairs(settings.permissions.additionalDirectories) do
        if type(dir) == "string" and dir ~= "" then
            if dir == "~" or vim.startswith(dir, "~/") then
                dir = vim.fs.normalize(dir, { expand_env = false })
            end
            table.insert(dirs, dir)
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
--- the policy layer to clear against the grant scopes (over-prompt-only: an
--- effect that does not clear still blocks approval). `path` may be
--- relative.
--- @alias agentic.utils.PermissionRules.Effect agentic.utils.ShellParse.FileEffect

--- What allowed one single command in the approve walk: a structured allow
--- kind, a settings.json allow pattern, or a session-remembered leaf.
--- @alias agentic.utils.PermissionRules.Source agentic.PermAllowKind|"glob_allow"|"session_allow"

--- Function names that some definition in the command gives an unsafe body.
--- The set spans the whole command, not one sequence, so a call to a member is
--- unsafe whatever its scope or order relative to the definition.
--- @alias agentic.utils.PermissionRules.Shadowed table<string, true>

--- The action commands of an action host (`find -exec`, `fd -x`) and their
--- parse, for re-walking one level deeper. nil at the nesting cap, for a
--- command whose actions do not resolve (see `ShellParse.host_actions`), or
--- when they do not parse; the host is then matched with all its arguments.
--- @param cmd_name string
--- @param args string[] delivered words after the name
--- @param args_dynamic boolean[] parallel to `args`
--- @param depth integer nesting depth of the host
--- @return agentic.utils.ShellParse.HostActions|nil actions
--- @return TSNode|nil root parse of `actions.inner`
local function parsed_actions(cmd_name, args, args_dynamic, depth)
    if depth >= NESTED_MAX_DEPTH then
        return nil
    end
    local actions = ShellParse.host_actions(cmd_name, args, args_dynamic)
    local root = actions and parse_zsh(actions.inner)
    if not root then
        return nil
    end
    return actions, root
end

--- Whether a command that runs before a point may have changed files. Every
--- copy of a walk context shares one, so a nested walk sets it for the rest of
--- the command.
--- @alias agentic.utils.PermissionRules.Taint { set: boolean }

--- @alias agentic.utils.PermissionRules.Sourced table<string, string|false> bytes read from each resolved sourced file, false when unreadable

--- @alias agentic.utils.PermissionRules.WalkCtx { allow_settings: agentic.utils.PermissionRules.CompiledPattern[], allow_remembered: agentic.utils.PermissionRules.CompiledPattern[], sources: table<agentic.utils.PermissionRules.Source, true>, deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[], structured_entries: agentic.StructuredEntries, auto_approve_tier: agentic.PermAutoApproveTier, depth: integer, effects: agentic.utils.PermissionRules.Effect[], written: table<string, string|false>, for_budget: integer, shadowed: agentic.utils.PermissionRules.Shadowed, read_scripts: boolean, cwd_of: table<string, agentic.utils.ShellParse.Cwds>, taint: agentic.utils.PermissionRules.Taint, sourced: agentic.utils.PermissionRules.Sourced, reader_memo: table }

--- The cwds `node` runs in, unknown when `ctx.cwd_of` has none for it.
--- @param ctx agentic.utils.PermissionRules.WalkCtx|agentic.utils.PermissionRules.TallyCtx
--- @param node TSNode
--- @return agentic.utils.ShellParse.Cwds
local function cwds_at(ctx, node)
    return ctx.cwd_of[node:id()] or unknown_cwds()
end

--- Run `walk_once` until a run adds no name to the shadowed set, or a run
--- reports its result final. A run judges each call against the names shadowed
--- so far, so a definition later in the command (`f() { cat; }; cat() { rm x;
--- }; f`) is seen only by the next run. The set only grows and is bounded by
--- the defined names, so this ends.
--- @generic T
--- @param walk_once fun(shadowed: agentic.utils.PermissionRules.Shadowed): T, boolean|nil
---        returns its result, and true when a larger shadowed set cannot change it
--- @return T result of the last run
local function walk_until_shadowed_settles(walk_once)
    --- @type agentic.utils.PermissionRules.Shadowed
    local shadowed = {}
    while true do
        local n_shadowed = vim.tbl_count(shadowed)
        local result, final = walk_once(shadowed)
        if final or vim.tbl_count(shadowed) == n_shadowed then
            return result
        end
    end
end

--- Maximum number of body walks a literal for-loop may unroll into. Nested
--- literal loops multiply, so the budget is divided down each level; a loop whose
--- value count exceeds the remaining budget falls back to the single dynamic walk
--- (the safe direction — never widens beyond the dynamic-token floor).
local FOR_UNROLL_CAP = 64

--- Container types that are straight-line statement sequences —
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
--- soundness guard for constant-literal substitution: a multi-word or glob value would
--- word-split / expand and change which tokens the matcher sees.
--- @param lit string
--- @return boolean
local function is_safe_literal(lit)
    return lit ~= "" and lit:match("^[%w%-_./=:+@,]+$") ~= nil
end

--- The plain scalar name behind a bare `$name` / `${name}` reference or its
--- single-word double-quoted form `"$name"` / `"${name}"`, or nil for any richer
--- form (`$f[1]`, `${f:-x}`, `${#f}`, concatenation `"$f/x"`, `"$(cmd)"`, …) that
--- constant-literal substitution must not touch. A resolvable node has exactly one named child,
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
    if t == "variable_ref" or t == "expansion" or t == "simple_expansion" then
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

--- Join an all-static `concatenation` (`$base/x`) to its literal, or nil if any
--- part is not statically knowable. A part qualifies as an inert literal
--- (`pure_literal_token` succeeds) or a `$name`/`${name}`/`"$name"` bound to a
--- safe literal in `known`; every joined part must pass `is_safe_literal`, so a
--- glob (`*.js`), unbound var, or richer expansion part → nil and the caller
--- keeps the concatenation dynamic. Command-substitution parts never reach here
--- (bailed by `subtree_has_substitution` at the call site).
--- @param node TSNode
--- @param src string
--- @param known table<string, string>
--- @return string|nil
local function resolved_concatenation(node, src, known)
    local parts = {}
    for c in node:iter_children() do
        if c:named() then
            local part = pure_literal_token(c, src)
            if part == nil then
                local kname = resolved_var_name(c, src)
                part = kname and known[kname] or nil
            end
            if part == nil or not is_safe_literal(part) then
                return nil
            end
            table.insert(parts, part)
        end
    end
    return table.concat(parts)
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
--- shell ran the rebound value. `read`, `printf` and zsh's `print` (`-v NAME`)
--- satisfy "allowlisted ∧ rebinds", so their membership is load-bearing, not
--- insurance. `print` gets no `-v` carve-out because its short options cluster
--- (`print -rv NAME`), which the exact-token scan for `-v` would miss.
local NAMESPACE_MUTATING = {
    read = true,
    printf = true,
    print = true,
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
    local name = ShellParse.command_name(node, src)
    return name and M.strip_command_path(name)
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

--- Forward declaration: `collect_bindings` uses it before its definition.
--- @type fun(node: TSNode, src: string, ctx: any, known: table<string, string>|nil, inner_check: fun(subst: TSNode, src: string, ctx: any): boolean): string[]|nil, TSNode[]|nil, boolean[]|nil, TSNode|nil
local extract_args

--- Collect the variable names a control-flow sibling could rebind in the
--- enclosing sequence (the capable grade), accumulating them into `targets`.
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
--- `SCOPE_BOUNDARY` nodes (inner bindings sealed in a child shell).
--- `printf -v` enumerates its target; other namespace-mutating builtins
--- clear-all.
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
        local name = name_node and vim.treesitter.get_node_text(name_node, src)
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
        local parts = redirected_parts(node, src)
        if not parts then
            return false
        end
        local statements = vim.list_extend({ parts.body }, parts.rest)
        return vim.iter(statements):all(function(statement)
            return collect_bindings(statement, src, targets)
        end)
    elseif t == "command" then
        local name = command_leaf_name(node, src)
        if name == "printf" then
            -- `-v NAME` rebinds NAME. Enumerate plain NAMEs; a dynamic or
            -- subscripted target → clear-all. Substitutions are vetted where
            -- the command itself is walked, so here every one passes.
            local args, _, args_dynamic = extract_args(
                node,
                src,
                nil,
                nil,
                function()
                    return true
                end
            )
            local names = args
                and ShellParse.builtin_bind_targets(name, args, args_dynamic)
            if not names then
                return false
            end
            for _, n in ipairs(names) do
                if not n:match("^[%w_]+$") then
                    return false
                end
                targets[n] = true
            end
            return true
        elseif not name or NAMESPACE_MUTATING[name] then
            return false
        end
        -- A plain non-mutating command binds nothing in the enclosing scope.
        -- (Args are inert or scope boundaries; an arithmetic assignment such
        -- as `$((d=…))` names a variable, so it already failed the parse.)
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
--- `variable_assignment` records `known[name]=lit`; a non-literal, subscripted
--- (`f[1]=…`) or appending (`f+=…`) one drops just that name. Every other child is handed to `collect_bindings` (the
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
        local name = name_node and vim.treesitter.get_node_text(name_node, src)
        if not name then
            return
        end
        -- `f[1]=…` and `f+=…` change `$f` to a value other than the literal.
        local partial = name_node:type() == "subscript"
            or vim.iter(child:iter_children()):any(function(c)
                return c:type() == "+="
            end)
        name = name:match("^[^%[]*")
        local value = child:field("value")[1]
        local lit = not partial and value and pure_literal_token(value, src)
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

--- Forward declaration — `walk_sequence` dispatches a `redirected_statement`
--- here (threading the per-sequence `known` env), but it is defined further down.
--- @type fun(node: TSNode, src: string, ctx: agentic.utils.PermissionRules.WalkCtx, known: table<string, string>|nil): boolean
local walk_redirected

--- True for a double-quoted `string` whose only expansions are command
--- substitutions (string-embedded command substitution): at least one
--- `command_substitution` named child and every named child is `string_content`
--- or `command_substitution`.
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

--- Extract a `command` node's argument tokens, without the command name, as
--- the parallel `args`/`arg_nodes`/`args_dynamic` streams. `inner_check`
--- vets each inner command substitution. `args` is nil on any structural
--- bail (an env-hijack prefix, an unhandled substitution, an unextractable
--- token).
---
--- A bare `$(…)` argument and a quoted `"$(…)"` (a `string` whose single
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
function extract_args(node, src, ctx, known, inner_check)
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
            -- Not an argument: callers read it with `ShellParse.command_name`.
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
            -- a bare `$name`/`${name}` bound to a splitting-proof literal
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
                -- a quoted `"$(cmd)"`. Like the bare form, vet the inner (it
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
                -- a quoted string mixing literal text with one or more command
                -- substitutions (`"count: $(ls)"`). Vet every inner (they run),
                -- then splice the whole quoted string as ONE dynamic token — raw
                -- text, quotes kept (unlike the single-child strip; the
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
                -- A command-substitution-bearing argument (concatenation
                -- `a$(b)c`, a `$var`-mixed quoted string) is not handled by the
                -- dynamic-token machinery — bail.
                if subtree_has_substitution(child) then
                    return nil
                end
                -- a `concatenation` whose every part is a safe literal or a
                -- `known`-bound var (`base=/safe; head $base/x`) resolves to the
                -- joined literal and feeds the gates as a static token. A glob,
                -- unbound var, or richer expansion part leaves `joined` nil and
                -- falls to `literal_token`, which emits the raw text as one
                -- dynamic token (`head $d/x`) — same word-split surface as `$d`.
                local joined = known
                        and child:type() == "concatenation"
                        and resolved_concatenation(child, src, known)
                    or nil
                if joined then
                    table.insert(args, joined)
                    table.insert(arg_nodes, child)
                    table.insert(args_dynamic, false)
                else
                    local tok = literal_token(child, src)
                    if tok == nil then
                        return nil
                    end
                    table.insert(args, tok)
                    table.insert(arg_nodes, child)
                    table.insert(args_dynamic, token_is_dynamic(child, true))
                end
            end
        end
    end
    args, arg_nodes, args_dynamic =
        ShellParse.join_adjacent_args(args, arg_nodes, args_dynamic, src)
    return args, arg_nodes, args_dynamic
end

--- The script operand of a command (`ShellParse.script_file_source`), as the
--- path the shell opens (`ShellParse.delivered_path`).
--- @param cmd_name string path-stripped command name
--- @param args string[] delivered words after the name
--- @param arg_nodes TSNode[] parallel to `args`
--- @param args_dynamic boolean[] parallel to `args`
--- @param src string
--- @return string|nil operand
local function script_operand(cmd_name, args, arg_nodes, args_dynamic, src)
    local operand = script_file_source(cmd_name, args, args_dynamic)
    return operand and ShellParse.delivered_path(operand, arg_nodes[1], src)
end

--- Whether the structured rules class a leaf `read_only`.
--- @param entries agentic.StructuredEntries
--- @param cmd_name string path-stripped command name
--- @param args string[]
--- @param args_dynamic boolean[] parallel to `args`
--- @return boolean
local function classifies_read_only(entries, cmd_name, args, args_dynamic)
    return next(entries) ~= nil
        and PermissionStructured.classify_leaf(entries, {
                cmd_name = cmd_name,
                args = args,
                args_dynamic = args_dynamic,
            }).read_only
            == true
end

--- A command's name and delivered args joined by single spaces.
--- @param name string
--- @param args string[]
--- @return string
local function leaf_text(name, args)
    return #args > 0 and name .. " " .. table.concat(args, " ") or name
end

--- The bytes of a script file, up to `ZshParse.MAX_SOURCE_BYTES`
--- (`FileSystem.read_regular_file`).
--- @param path string resolved absolute path
--- @return string|nil
local function read_script(path)
    -- No re-stat against the eventual `open()`: the walk → approve callback
    -- path is synchronous, so the bytes read here are the bytes judged, and
    -- the post-callback IPC window to the shell's open is not closeable
    -- client-side anyway.
    return FileSystem.read_regular_file(path, ZshParse.MAX_SOURCE_BYTES)
end

--- The files a redirected statement writes, and the bytes they then hold.
--- Content is known only for `cat > f <<'EOF' … EOF`: a bare `cat` with no
--- words on its redirects, one truncating write, one heredoc without
--- expansions, and the rest of the line, if any, after `&&`. After `||` or
--- `|` the rest may run before the file holds the body.
--- Safe redirects (`> /dev/null`, fd duplication) write nothing.
--- @param parts agentic.utils.ShellParse.RedirectedParts the statement
--- @param src string
--- @param known table<string, string>|nil constant environment of the enclosing sequence
--- @return string[] paths write targets that resolve to a literal, as delivered
--- @return string|nil content bytes every target holds when the rest of the
---         line and the later statements run, nil when unknown
--- @return boolean resolved every write target resolves to a literal
local function redirect_writes(parts, src, known)
    --- @type string[]
    local paths = {}
    local resolved = true
    local truncates = false
    --- @type (string|false)[] pure body of each heredoc, false for one with expansions
    local heredocs = {}
    local other_redirect = false
    for _, r in ipairs(parts.redirects) do
        local t = r:type()
        if t == "heredoc_redirect" then
            table.insert(heredocs, heredoc_pure_body(r, src) or false)
        elseif t ~= "file_redirect" then
            other_redirect = true
        elseif not redirect_is_safe(r, src) then
            -- Resolved exactly as an `rm` operand is, so the two correlate
            -- for the intra-command create-then-delete check: a `$var`
            -- bound to a literal earlier in the sequence resolves through
            -- `known`, a quoted literal is quote-stripped.
            local dest = redirect_write_dest(r, src)
            local kname = dest and known and resolved_var_name(dest, src)
            local target = kname and known and known[kname] or nil
            if dest and target == nil and not token_is_dynamic(dest) then
                local text = literal_token(dest, src)
                target = text and ShellParse.delivered_path(text, dest, src)
            end
            if target then
                table.insert(paths, target)
                truncates = redirect_is_truncate(r)
            else
                resolved = false
            end
        end
    end
    local content = nil
    if
        resolved
        and #heredocs == 1
        and heredocs[1]
        and not other_redirect
        and #paths == 1
        and truncates
        and #parts.words == 0
        and (parts.rest_op == nil or parts.rest_op == "&&")
        and is_bare_cat(parts.body, src)
    then
        content = heredocs[1] --[[@as string]]
    end
    return paths, content, resolved
end

--- Record writes to `paths` in `written`, keyed by the resolved path:
--- `content` for a first write to a key; `false` for a second write or nil
--- content. A relative path under more than one possible cwd marks every
--- candidate key `false`; under unknown cwds it has no key, nor does a
--- `~name` path.
--- @param written table<string, string|false> resolved path → bytes, false = unknown
--- @param paths string[]
--- @param content string|nil
--- @param cwds agentic.utils.ShellParse.Cwds where the writes happen
local function record_writes(written, paths, content, cwds)
    for _, path in ipairs(paths) do
        --- @type (string|nil)[]
        local keys = {}
        if path:match("^[/~]") then
            keys = { resolve_against_cwd(path) }
        elseif not cwds.unknown then
            keys = vim.tbl_map(function(dir)
                return resolve_against_cwd(path, dir)
            end, cwds.dirs)
        end
        for _, key in ipairs(keys) do
            written[key] = #keys == 1
                    and written[key] == nil
                    and (content or false)
                or false
        end
    end
end

--- A function giving the cwds after sourcing a file, from the bytes on disk:
--- unknown for an unreadable or unparsable file, or past the nesting cap. A
--- sourced file may `return` early, so every set inside it counts, not only
--- its exit.
--- @param sourced agentic.utils.PermissionRules.Sourced filled with each body read
--- @param depth integer nesting depth of the tree that sources the file
--- @return fun(operand: string, before: agentic.utils.ShellParse.Cwds): agentic.utils.ShellParse.Cwds
local function sourced_cwds(sourced, depth)
    return function(operand, before)
        local paths = depth < NESTED_MAX_DEPTH
            and script_paths("source", operand, before)
        if not paths then
            return unknown_cwds()
        end
        local after = { dirs = {}, unknown = false }
        for _, p in ipairs(paths) do
            local body = read_script(p.path)
            sourced[p.path] = body or false
            local root = body and parse_zsh_untrusted(body)
            if not root then
                return unknown_cwds()
            end
            local cwd_of, exit = ShellParse.command_cwds(
                root,
                body --[[@as string]],
                p.start,
                sourced_cwds(sourced, depth + 1)
            )
            after = cwds_union(after, exit)
            for _, cwds in pairs(cwd_of) do
                after = cwds_union(after, cwds)
            end
        end
        return after
    end
end

--- The cwds of each node of a tree, reading a sourced file only when
--- `read_scripts` is set.
--- @param root TSNode
--- @param src string
--- @param start agentic.utils.ShellParse.Cwds where the tree starts
--- @param ctx { sourced: agentic.utils.PermissionRules.Sourced, read_scripts: boolean } of the walk
--- @param depth integer nesting depth of `root`
--- @return table<string, agentic.utils.ShellParse.Cwds> cwd_of keyed by `node:id()`
local function tree_cwds(root, src, start, ctx, depth)
    return (
        ShellParse.command_cwds(
            root,
            src,
            start,
            ctx.read_scripts and sourced_cwds(ctx.sourced, depth) or nil
        )
    )
end

--- A reader of a file's bytes as a command at this point of the walk would
--- see them. A write earlier in the same command (`ctx.written`) wins over
--- disk. Once `ctx.taint` is set, only such a write's bytes count. For
--- `source`/`.`, a file held in `ctx.sourced` must still hold those bytes,
--- as the cwds after it came from them.
--- @param cmd_name string path-stripped name of the command that reads
--- @param ctx agentic.utils.PermissionRules.WalkCtx|agentic.utils.PermissionRules.TallyCtx
--- @return fun(path: string): string|false|nil read nil when the file is
---         missing and `ctx.taint` is unset; false when the path does not
---         resolve, its bytes are unknown, it is unreadable, or a sourced
---         file changed
local function file_reader(cmd_name, ctx)
    local is_source = cmd_name == "source" or cmd_name == "."
    return function(path)
        local key = resolve_against_cwd(path)
        if not key then
            return false
        end
        --- @type string|false|nil
        local bytes = ctx.written[key]
        if bytes == nil then
            if ctx.taint.set then
                return false
            end
            if not vim.uv.fs_stat(key) then
                return nil
            end
            bytes = read_script(key) or false
        end
        local sourced = is_source and ctx.sourced[key]
        if type(sourced) == "string" and sourced ~= bytes then
            return false
        end
        return bytes
    end
end

--- @alias agentic.utils.PermissionRules.Body { src: string, start: agentic.utils.ShellParse.Cwds }

--- The shell commands a command runs from code it reads
--- (`ExecutedCode.READERS`), from each directory it may run in.
--- @param cmd_name string path-stripped command name
--- @param args string[] delivered words after the name
--- @param arg_nodes TSNode[] parallel to `args`
--- @param args_dynamic boolean[] parallel to `args`
--- @param src string source text the nodes index into
--- @param ctx agentic.utils.PermissionRules.WalkCtx|agentic.utils.PermissionRules.TallyCtx
--- @param node TSNode the command
--- @return agentic.utils.PermissionRules.Body[]|nil bodies one per command
---         and directory; nil unless the command's reader takes it from
---         every directory and finds a command, `ctx.read_scripts` is set,
---         and `ctx.depth` is below the nesting cap
local function executed_bodies(
    cmd_name,
    args,
    arg_nodes,
    args_dynamic,
    src,
    ctx,
    node
)
    local reader = ExecutedCode.READERS[cmd_name]
    if not reader or not ctx.read_scripts or ctx.depth >= NESTED_MAX_DEPTH then
        return nil
    end
    local words = vim.iter(ipairs(args))
        :map(function(i, arg)
            return args_dynamic[i] and arg
                or ShellParse.delivered_path(arg, arg_nodes[i], src)
        end)
        :totable()
    local read = file_reader(cmd_name, ctx)
    local cwds = cwds_at(ctx, node)
    --- @type agentic.utils.PermissionRules.Body[]
    local bodies = {}
    --- @param cwd string|nil
    --- @return boolean read the reader took the command
    local function read_from(cwd)
        local code = reader(words, args_dynamic, cwd, read, ctx.reader_memo)
        if not code then
            return false
        end
        local start = code.dir and { dirs = { code.dir }, unknown = false }
            or unknown_cwds()
        for _, command in ipairs(code.commands) do
            table.insert(bodies, { src = command, start = start })
        end
        return true
    end
    local took = cwds.unknown and read_from(nil)
        or not cwds.unknown and vim.iter(cwds.dirs):all(read_from)
    -- Zero commands would approve vacuously: keep the command's own rules.
    return took and #bodies > 0 and bodies or nil
end

--- A copy of `ctx` one nesting level deeper, holding the cwds of the
--- commands in `body`.
--- @generic C: agentic.utils.PermissionRules.WalkCtx|agentic.utils.PermissionRules.TallyCtx
--- @param ctx C
--- @param root TSNode the body's parse
--- @param body agentic.utils.PermissionRules.Body
--- @return C
local function nested_ctx(ctx, root, body)
    return vim.tbl_extend("force", ctx, {
        depth = ctx.depth + 1,
        cwd_of = tree_cwds(root, body.src, body.start, ctx, ctx.depth + 1),
    })
end

--- Whether a config file may make a command load code, by the `runs` items
--- of its structured entry (`ExecutedCode.runs_code`). True when the walk can
--- no longer trust the disk (`ctx.taint`) or a directory the command may run
--- in is unknown. False for a command whose entry has no `runs`.
--- @param cmd_name string path-stripped command name
--- @param args string[] delivered words after the name
--- @param args_dynamic boolean[] parallel to `args`
--- @param ctx agentic.utils.PermissionRules.WalkCtx|agentic.utils.PermissionRules.TallyCtx
--- @param node TSNode the command
--- @return boolean
local function may_run_config_code(cmd_name, args, args_dynamic, ctx, node)
    local entry = ctx.structured_entries[cmd_name]
    local items = entry and entry.runs
    if not items then
        return false
    end
    local cwds = cwds_at(ctx, node)
    return ctx.taint.set
        or cwds.unknown
        or vim.iter(cwds.dirs):any(function(cwd)
            return ExecutedCode.runs_code(items, args, args_dynamic, cwd)
        end)
end

--- Walk a `command`: validate the name and each argument by position
--- (substitution is recursed in argument position, bailed elsewhere), validate
--- env-prefix assignments, then combine the glob
--- and structured layers (composition rule in the `permissions` project skill).
--- `known` (optional) is the per-sequence constant environment of the enclosing sequence;
--- a bare `$name` bound in it resolves to its literal and becomes a static token.
--- `funcs` (optional) maps each function name defined and body-walked clean
--- earlier in the sequence to the sources its body needed; a call to one
--- approves regardless of its args and adds those sources. A call to a name in
--- `ctx.shadowed` bails. Both match the command word as written, as zsh's
--- function lookup does: `/bin/ls` does not call a function `ls`.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @param known table<string, string>|nil
--- @param funcs table<string, table<agentic.utils.PermissionRules.Source, true>>|nil
--- @return boolean
local function walk_command(node, src, ctx, known, funcs)
    local args, arg_nodes, args_dynamic =
        extract_args(node, src, ctx, known, walk_substitution_inner)
    if not (args and arg_nodes and args_dynamic) then
        return false
    end

    local name = ShellParse.command_name(node, src)
    if not name then
        return false
    end
    local cmd_name = M.strip_command_path(name)
    -- A non-`-c` script execution (`zsh file.sh`, `source ./file.sh`) has a
    -- literal operand; the recursion below reads + walks the file it names.
    -- This lifts `source`/`.` out of the unconditional code-taking bail only
    -- when the file resolves (`eval`, and an unresolved `source`, still bail).
    local script_path =
        script_operand(cmd_name, args, arg_nodes, args_dynamic, src)
    if
        refuses_builtin(
            cmd_name,
            args,
            args_dynamic --[[@as boolean[] ]],
            script_path
        ) or ctx.shadowed[name]
    then
        return false
    end

    local leaf = leaf_text(name, args)

    -- Cheap glob denies first — short-circuit before the structured matcher.
    if #ctx.deny > 0 and M.matches_any_pattern(leaf, ctx.deny) then
        return false
    end
    if #ctx.ask > 0 and M.matches_any_pattern(leaf, ctx.ask) then
        return false
    end

    local glob_allowed = M.matches_any_pattern(leaf, ctx.allow_settings)
    local session_allowed = M.matches_any_pattern(leaf, ctx.allow_remembered)
    local user_allowed = glob_allowed or session_allowed

    -- An `rm` emits a delete effect per concrete operand instead of bailing to
    -- the structured `ask`. A dynamic operand (`rm $x`) cannot be pinned to a
    -- literal → bail like a dynamic redirect. A directory delete (`-r`/`-R`/
    -- `-d`, their long forms, an operand ending in `/`) bails too: the policy
    -- layer judges one file per effect. The policy layer
    -- (`_bash_effects_clear`) then clears each operand against the grant
    -- scopes.
    --
    -- This is a fallback for an `rm` that would otherwise prompt: an explicit
    -- glob allow (`Bash(rm *)`) approves it cleanly with no effect, so it is not
    -- intercepted here (the effect would make `should_auto_approve` withhold the
    -- user's own allow). `rm -f`/`--force` never reaches this walk under normal
    -- flow — `should_auto_reject` runs first and rejects it (force is a
    -- structured deny gate).
    if cmd_name == "rm" and not user_allowed then
        local operands, recursive = ShellParse.rm_operands(args, args_dynamic)
        if recursive then
            return false
        end
        for _, operand in ipairs(operands) do
            if operand.dynamic or operand.path:sub(-1) == "/" then
                return false
            end
        end
        if #operands > 0 then
            for _, operand in ipairs(operands) do
                table.insert(
                    ctx.effects,
                    { kind = "delete", path = operand.path }
                )
            end
            ctx.taint.set = true
            return true
        end
    end

    -- a call to a function defined earlier in this straight-line sequence.
    -- Its body was walked clean at definition time with every parameter dynamic,
    -- so the body is safe for ANY call arguments — the call needs no re-vetting
    -- of how the function uses them. The arguments were still walked above (a
    -- side-effecting `foo $(rm x)` already bailed on the substitution).
    if funcs and funcs[name] then
        for source in pairs(funcs[name]) do
            ctx.sources[source] = true
            ctx.taint.set = ctx.taint.set or source ~= "read_only"
        end
        return true
    end

    -- Transparent prefix (inline `sh -c '<body>'` or exec-wrapper): walk the
    -- inner command instead of treating the prefix as an opaque leaf. Must run
    -- before the structured matcher so a shell's `c` gate does not pre-empt the
    -- `-c` recursion. A body at the depth cap, or one that does not resolve,
    -- falls through to the leaf matchers.
    local inner =
        inner_source(cmd_name, node, args, arg_nodes, args_dynamic, src)
    if inner and ctx.depth < NESTED_MAX_DEPTH then
        local root = parse_zsh(inner)
        if not root then
            return false
        end
        return walk(
            root,
            inner,
            vim.tbl_extend("force", ctx, {
                depth = ctx.depth + 1,
                cwd_of = tree_cwds(
                    root,
                    inner,
                    cwds_at(ctx, node),
                    ctx,
                    ctx.depth + 1
                ),
            })
        )
    end

    -- Code the command reads (a script, a makefile): every command in it must
    -- approve, and its effects join this command's. A user allow on the leaf
    -- is the user's choice over that code, so it skips the read.
    local bodies = not user_allowed
        and executed_bodies(
            cmd_name,
            args,
            arg_nodes,
            args_dynamic,
            src,
            ctx,
            node
        )
    if bodies then
        return vim.iter(bodies):all(function(body)
            local root = parse_zsh_untrusted(body.src)
            return root ~= nil
                and walk(root, body.src, nested_ctx(ctx, root, body))
        end)
    end

    -- Action host (`find -exec`, `fd -x`): its actions must approve, then the
    -- structured matcher sees the host without them. Globs keep the whole
    -- leaf: allow still needs the actions, deny/ask only over-fire. An
    -- action that runs in another directory may not add a path effect or read
    -- a script, since a relative path in it resolves there.
    local actions, actions_root =
        parsed_actions(cmd_name, args, args_dynamic, ctx.depth)
    if actions and actions_root then
        local n_effects = #ctx.effects
        if
            not walk(
                actions_root,
                actions.inner,
                vim.tbl_extend("force", ctx, {
                    depth = ctx.depth + 1,
                    read_scripts = ctx.read_scripts and not actions.foreign_cwd,
                    cwd_of = tree_cwds(
                        actions_root,
                        actions.inner,
                        actions.foreign_cwd and unknown_cwds()
                            or cwds_at(ctx, node),
                        ctx,
                        ctx.depth + 1
                    ),
                })
            )
            or (actions.foreign_cwd and #ctx.effects > n_effects)
        then
            return false
        end
        args, args_dynamic = actions.args, actions.args_dynamic
    end

    --- @type agentic.PermDecision
    local structured = nil
    --- @type agentic.PermAllowKind|nil
    local allow_kind = nil
    if next(ctx.structured_entries) ~= nil then
        --- @type agentic.ParsedLeaf
        local parsed =
            { cmd_name = cmd_name, args = args, args_dynamic = args_dynamic }
        structured, allow_kind = PermissionStructured.decide_leaf(
            ctx.structured_entries,
            parsed,
            ctx.auto_approve_tier
        )
        -- In the APPROVE walk deny and ask both collapse to "not approved". The
        -- distinction (deny rejects with no prompt, ask prompts) is enforced
        -- earlier by `should_auto_reject` — see the reject walk below.
        if structured == "deny" or structured == "ask" then
            return false
        end
        if
            allow_kind
            and may_run_config_code(cmd_name, args, args_dynamic, ctx, node)
        then
            allow_kind = nil
        end
    end

    --- @type agentic.utils.PermissionRules.Source|nil
    local source = allow_kind
    if not source and glob_allowed then
        source = "glob_allow"
    elseif not source and session_allowed then
        source = "session_allow"
    end
    if source then
        ctx.sources[source] = true
        ctx.taint.set = ctx.taint.set
            or not (
                allow_kind == "read_only"
                or classifies_read_only(
                    ctx.structured_entries,
                    cmd_name,
                    args,
                    args_dynamic
                )
            )
    end
    return source ~= nil
end

--- Whether every redirect a node carries in its `redirect` field is a safe
--- form (`redirect_is_safe`). True for a node with none.
--- @param node TSNode
--- @param src string
--- @return boolean
local function redirects_safe(node, src)
    return vim.iter(node:field("redirect")):all(function(r)
        return r:type() == "file_redirect" and redirect_is_safe(r, src)
    end)
end

--- Walk a `function_definition`. Defining a named function never runs its
--- body, so the definition approves; the body's cleanliness only decides how a
--- later *call* resolves. Body-walk it as a fresh sequence (every
--- `$var`/positional dynamic, no inherited `known` literals or `funcs`). A
--- clean body records every name in `funcs`, with the sources the body needed;
--- an unsafe body adds every name to `ctx.shadowed`. A redirect on the
--- definition (`f() { … } > x`) that is not a safe form counts as unsafe: zsh
--- applies it at every call, expanding its target then. Either way adds
--- `read_only` to `ctx.sources`. Bails on an anonymous `() { … }` (it runs
--- immediately), a name that is not a plain word, and a name zsh calls on its
--- own (`ShellParse.runs_without_call`).
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @param funcs table<string, table<agentic.utils.PermissionRules.Source, true>>
--- @return boolean
local function walk_function_definition(node, src, ctx, funcs)
    local names = ShellParse.function_names(node, src)
    if not names or vim.iter(names):any(ShellParse.runs_without_call) then
        return false
    end
    local body = node:field("body")[1]
    -- Defining a function never runs its body, so any file-mutating effect in
    -- it must NOT leak into the outer command's effects. Walk with a throwaway
    -- effects list. A body that emits effects (e.g. an `rm`) cannot be vetted at
    -- definition time — the policy layer that clears effects only sees the outer
    -- command — so such a body is treated as unsafe and the name is not recorded.
    -- The body runs at a call, after any write in the command, so it reads
    -- no script from disk.
    local body_effects = {}
    local body_sources = {}
    local body_ctx = vim.tbl_extend("force", ctx, {
        effects = body_effects,
        written = {},
        sources = body_sources,
        taint = { set = true },
    })
    local clean = body ~= nil
        and redirects_safe(node, src)
        and walk(body, src, body_ctx)
        and #body_effects == 0
    for _, name in ipairs(names) do
        if clean then
            funcs[name] = body_sources
        else
            ctx.shadowed[name] = true
        end
    end
    ctx.sources.read_only = true
    return true
end

--- Walk statements that may run after a write the walk reaches later: loop
--- iterations, pipeline elements, a background statement and the ones after
--- it. When the walk sets `ctx.taint`, walk them again with the taint set
--- from the start.
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @param walk_once fun(): boolean walks the statements once
--- @return boolean
local function walk_unordered(ctx, walk_once)
    local tainted = ctx.taint.set
    return walk_once() and (tainted or not ctx.taint.set or walk_once())
end

--- Whether a sequence holds a background statement.
--- @param node TSNode
--- @return boolean
local function has_background(node)
    return vim.iter(node:iter_children()):any(function(child)
        return child:named() and ShellParse.is_background(child)
    end)
end

--- Forward declaration — `walk_sequence` wraps it.
--- @type fun(node: TSNode, src: string, ctx: agentic.utils.PermissionRules.WalkCtx, seed: table<string, string>|nil): boolean
local walk_statements

--- Walk a straight-line statement sequence (`program`, `list`, an `if`/`elif`/
--- `else` body, a `do_group`, or a brace group / function body
--- `compound_statement`), threading the constant environment and the
--- function table left to right: a pure-literal assignment binds a name, a
--- function definition records a body-walked-clean name, and a later `command`
--- resolves bare `$name` references and recorded calls against them. Both are
--- sequence-local — nested blocks reached via `walk(child)` start fresh, so
--- neither a binding nor a clean function record leaks across sequences (an
--- unsafe definition's names do, through `ctx.shadowed`).
---
--- `seed` (optional) pre-binds names in the constant environment — a for-loop
--- unrolls its body once per literal value by calling this with `{ [loopvar] =
--- value }`. `update_known` still runs per body statement, so a body that rebinds
--- the loop var drops the seed exactly as its rebinding rules dictate.
---
--- A sequence with a background statement is walked as `walk_unordered`: the
--- background statement runs beside the statements after it.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @param seed table<string, string>|nil
--- @return boolean
local function walk_sequence(node, src, ctx, seed)
    local function walk_once()
        return walk_statements(node, src, ctx, seed)
    end
    if has_background(node) then
        return walk_unordered(ctx, walk_once)
    end
    return walk_once()
end

--- `walk_sequence` once, in statement order.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @param seed table<string, string>|nil
--- @return boolean
function walk_statements(node, src, ctx, seed)
    --- @type table<string, string>
    local known = seed and vim.tbl_extend("force", {}, seed) or {}
    --- @type table<string, table<agentic.utils.PermissionRules.Source, true>>
    local funcs = {}
    for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            local ok
            local t = child:type()
            if t == "command" then
                ok = walk_command(child, src, ctx, known, funcs)
            elseif t == "function_definition" then
                ok = walk_function_definition(child, src, ctx, funcs)
            elseif t == "redirected_statement" then
                -- Thread `known` so a redirect target `$f`/`"$f"` bound earlier in
                -- this sequence resolves to its literal (the generic `walk`
                -- dispatcher drops the per-sequence env).
                ok = walk_redirected(child, src, ctx, known)
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
--- every file redirect must be a safe form or write to a literal path, and each statement the rest of a
--- heredoc's line continues into must pass. A herestring, a heredoc body with
--- an expansion (it runs at write time), words on a redirect, and a line the
--- tree may group differently from zsh bail. After `|` the rest runs beside
--- the body, so the statement is walked as `walk_unordered`.
---
--- Mutates `ctx`: every concrete file write emits a `ctx.effects` entry and
--- sets `ctx.taint`, and `ctx.written` maps each written path, resolved
--- against its possible cwds, to the bytes the file will hold
--- (`redirect_writes`), else `false`. `ctx.written` is set before the body
--- is walked, as the shell opens the files before the body runs.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @param known table<string, string>|nil constant environment of the enclosing sequence
--- @return boolean
function walk_redirected(node, src, ctx, known)
    local parts = redirected_parts(node, src)
    if not parts or #parts.words > 0 then
        return false
    end
    local function walk_once()
        local paths, content, resolved = redirect_writes(parts, src, known)
        if not resolved then
            return false
        end
        record_writes(ctx.written, paths, content, cwds_at(ctx, node))
        if parts.body and not walk(parts.body, src, ctx) then
            return false
        end
        for _, r in ipairs(parts.redirects) do
            local t = r:type()
            if
                t == "herestring_redirect"
                or t == "heredoc_redirect" and not heredoc_pure_body(r, src)
            then
                return false
            end
        end
        for _, path in ipairs(paths) do
            table.insert(ctx.effects, { kind = "write", path = path })
        end
        ctx.taint.set = ctx.taint.set or #paths > 0
        return vim.iter(parts.rest):all(function(statement)
            return walk(statement, src, ctx)
        end)
    end
    if parts.rest_op == "|" then
        return walk_unordered(ctx, walk_once)
    end
    return walk_once()
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
--- `"$(…)"` argument is unwrapped to its inner `command_substitution` and
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
--- array-element position is sound (see the `permissions` skill
--- `references/parsing.md` § Pipeline). A poisoned name (`PATH=/evil`) bails because a
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
        ctx.sources.read_only = true
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
        ctx.sources.read_only = true
        return true
    end
    -- Any other value form (literal, concatenation, expansion, …): the
    -- pre-Phase-2 bail still applies — a substitution anywhere in the value
    -- that did not come through the two carve-outs above is rejected.
    if subtree_has_substitution(value) then
        return false
    end
    ctx.sources.read_only = true
    return true
end

--- Walk a `for_statement`. A loop var that can change execution
--- (`for path in …`) bails. When every list item is a splitting-proof literal
--- and the loop var is a plain name, unroll: walk the body once per value with
--- the var pre-bound, so a gated body command (`find -exec`) is checked against
--- each concrete value and the loop approves iff every value approves. A
--- non-literal list (substitution / glob / expansion) or a value count over the
--- remaining budget falls back to the single dynamic walk: a bare
--- `command_substitution` item runs via `walk_substitution_inner`, any other
--- substitution-bearing item bails, and the body walks once with the loop var
--- dynamic (a laundered payload caught at the use site). Unnamed children
--- (`for`/`in`/`do`/`;` keywords and separators) are ignored even when the
--- grammar tags them with the same field as a named sibling.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.WalkCtx
--- @return boolean
local function walk_for(node, src, ctx)
    local var_name, body
    --- @type TSNode[]
    local items = {}
    for child, field in node:iter_children() do
        if child:named() then
            if field == "variable" then
                var_name = vim.treesitter.get_node_text(child, src)
            elseif field == "value" then
                table.insert(items, child)
            elseif field == "body" then
                body = child
            end
        end
    end
    if not (body and var_name and ShellParse.is_safe_var_name(var_name)) then
        return false
    end

    -- unroll a fully-literal list with a plain loop var, bounded by budget.
    local budget = ctx.for_budget or FOR_UNROLL_CAP
    if var_name:match("^[%w_]+$") and #items > 0 then
        --- @type string[]
        local values = {}
        local all_literal = true
        for _, item in ipairs(items) do
            local lit = pure_literal_token(item, src)
            if lit and is_safe_literal(lit) then
                table.insert(values, lit)
            else
                all_literal = false
                break
            end
        end
        if all_literal and #values <= budget then
            local sub_budget = math.max(1, math.floor(budget / #values))
            local sub_ctx =
                vim.tbl_extend("force", ctx, { for_budget = sub_budget })
            for _, v in ipairs(values) do
                if
                    not walk_sequence(body, src, sub_ctx, { [var_name] = v })
                then
                    return false
                end
            end
            return true
        end
    end

    -- Fallback: validate list-item substitutions, then walk the body once with
    -- the loop var dynamic.
    for _, item in ipairs(items) do
        if item:type() == "command_substitution" then
            if not walk_substitution_inner(item, src, ctx) then
                return false
            end
        elseif subtree_has_substitution(item) then
            return false
        end
    end
    return walk_unordered(ctx, function()
        return walk(body, src, ctx)
    end)
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
    return walk_unordered(ctx, function()
        return walk(cond, src, ctx) and walk(body, src, ctx)
    end)
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
        if subtree_has_substitution(node) then
            return false
        end
        ctx.sources.read_only = true
        return true
    elseif t == "case_statement" then
        return walk_case(node, src, ctx)
    elseif
        SEQUENCE_TYPES[t]
        or t == "do_group"
        or t == "compound_statement"
        or t == "subshell"
    then
        -- `compound_statement` is a brace group `{ …; }` or a function body,
        -- `subshell` a `( … )` command group — all run their body sequentially
        -- (the subshell in a child shell, which changes only variable scope and
        -- cwd persistence, never leaf safety), like a `list`.
        return walk_sequence(node, src, ctx)
    elseif CONTAINER_TYPES[t] then
        -- `pipeline` / `variable_assignments` — the non-sequence containers (the
        -- sequence types overlap CONTAINER_TYPES but are caught above). Iterate
        -- named children only; anonymous separators (`;`, `&&`, `|`, `&`,
        -- newline) and `comment` nodes carry no executable content. Pipeline
        -- elements run side by side.
        local function walk_once()
            for child in node:iter_children() do
                if child:named() and child:type() ~= "comment" then
                    if not walk(child, src, ctx) then
                        return false
                    end
                end
            end
            return true
        end
        if t == "pipeline" then
            return walk_unordered(ctx, walk_once)
        end
        return walk_once()
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
        -- Reached outside a sequence (a pipeline stage): there is no
        -- sequence function table, so a clean record is dropped
        -- and a later call is judged as the command of that name.
        return walk_function_definition(node, src, ctx, {})
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
-- settings.json allow/deny/ask globs), not the `auto_approve_tier`-resolved
-- decision, so a `safe_write` like `git add` never lights up even at the
-- read_only tier.

--- @alias agentic.utils.PermissionRules.TallyCtx { allow: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[], structured_entries: agentic.StructuredEntries, depth: integer, leaves: string[], written: table<string, string|false>, for_budget: integer, shadowed: agentic.utils.PermissionRules.Shadowed, read_scripts: boolean, cwd_of: table<string, agentic.utils.ShellParse.Cwds>, taint: agentic.utils.PermissionRules.Taint, sourced: agentic.utils.PermissionRules.Sourced, reader_memo: table }

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

--- Whether a `command` leaf is known-safe: it matches a structured
--- read_only/safe_write rule or a settings.json allow AND no deny/ask rule,
--- with no structural reason to bail (substitution in a non-bare position,
--- env-hijack prefix, dynamic name, code-taking builtin, unextractable token).
--- Mirrors `walk_command`'s
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
--- @param known table<string, string>|nil constant environment of the enclosing sequence
--- @param funcs table<string, boolean>|nil recorded function names of the enclosing sequence
--- @return boolean known_safe
--- @return agentic.utils.PermissionRules.Range[]|nil sub_ranges
--- @return string|nil leaf #stripped, rememberable leaf signature; non-nil only
---   when an allow match on the leaf would approve it (never on a deny/ask or
---   structural/substitution bail)
local function command_known_safe(node, src, ctx, known, funcs)
    --- @type agentic.utils.PermissionRules.Range[]
    local subst_ranges = {}
    local args, arg_nodes, args_dynamic = extract_args(
        node,
        src,
        ctx,
        known,
        function(subst, s, c)
            return substitution_inner_collect(subst, s, c, subst_ranges)
        end
    )
    -- Any leaf but a `read_only` one, safe or not, sets the taint: the
    -- prompt runs it all once approved.
    if not (args and arg_nodes and args_dynamic) then
        ctx.taint.set = true
        return false
    end

    local name = ShellParse.command_name(node, src)
    if not name then
        ctx.taint.set = true
        return false
    end
    local cmd_name = M.strip_command_path(name)
    -- Mirror of walk_command: a non-`-c` script execution lifts source/. out of
    -- the code-taking bail when the file resolves; the recursion below tallies it.
    local script_path =
        script_operand(cmd_name, args, arg_nodes, args_dynamic, src)
    if
        refuses_builtin(
            cmd_name,
            args,
            args_dynamic --[[@as boolean[] ]],
            script_path
        ) or ctx.shadowed[name]
    then
        ctx.taint.set = true
        return false
    end

    local leaf = leaf_text(name, args)

    if
        M.matches_any_pattern(leaf, ctx.deny)
        or M.matches_any_pattern(leaf, ctx.ask)
    then
        ctx.taint.set = true
        return false
    end

    -- a call to a function recorded earlier in this sequence is known-safe
    -- (mirrors walk_command — body vetted at definition time for any args).
    if funcs and funcs[name] then
        ctx.taint.set = true
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
            ctx.taint.set = true
            return false
        end
        --- @type agentic.utils.PermissionRules.Range[]
        local body_ranges = {}
        tally_walk(
            root,
            inner,
            -- Fresh `leaves`: the inner is vetted only to decide this leaf's
            -- safety, so its leaves must not leak into the outer rememberable
            -- set (an unsafe inner makes the whole leaf non-rememberable).
            vim.tbl_extend("force", ctx, {
                depth = ctx.depth + 1,
                leaves = {},
                cwd_of = tree_cwds(
                    root,
                    inner,
                    cwds_at(ctx, node),
                    ctx,
                    ctx.depth + 1
                ),
            }),
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

    local glob_safe = M.matches_any_pattern(leaf, ctx.allow)

    -- Code the command reads: known-safe iff every command in it is. The code
    -- has no place in the chat buffer to anchor ranges to, so an unsafe
    -- command washes the whole leaf. The leaf stays rememberable, as a user
    -- allow on it skips the read (mirrors walk_command).
    local bodies = not glob_safe
        and executed_bodies(
            cmd_name,
            args,
            arg_nodes,
            args_dynamic,
            src,
            ctx,
            node
        )
    if bodies then
        --- @type agentic.utils.PermissionRules.Range[]
        local body_ranges = {}
        for _, body in ipairs(bodies) do
            local root = parse_zsh_untrusted(body.src)
            if not root then
                ctx.taint.set = true
                return false
            end
            tally_walk(
                root,
                body.src,
                vim.tbl_extend(
                    "force",
                    nested_ctx(ctx, root, body),
                    { leaves = {} }
                ),
                body_ranges
            )
        end
        if #body_ranges == 0 then
            return true
        end
        return false, nil, leaf
    end

    -- Action host (`find -exec`, `fd -x`): its actions must be known-safe, and
    -- one outside the cwd may not read a script. The rebuilt actions are not a
    -- substring of `src`, so an unsafe one washes the whole leaf.
    local actions, actions_root =
        parsed_actions(cmd_name, args, args_dynamic, ctx.depth)
    if actions and actions_root then
        --- @type agentic.utils.PermissionRules.Range[]
        local body_ranges = {}
        tally_walk(
            actions_root,
            actions.inner,
            vim.tbl_extend("force", ctx, {
                depth = ctx.depth + 1,
                leaves = {},
                read_scripts = ctx.read_scripts and not actions.foreign_cwd,
                cwd_of = tree_cwds(
                    actions_root,
                    actions.inner,
                    actions.foreign_cwd and unknown_cwds() or cwds_at(ctx, node),
                    ctx,
                    ctx.depth + 1
                ),
            }),
            body_ranges
        )
        if #body_ranges > 0 then
            return false
        end
        args, args_dynamic = actions.args, actions.args_dynamic
    end

    local struct_safe = false
    if next(ctx.structured_entries) ~= nil then
        local c = PermissionStructured.classify_leaf(ctx.structured_entries, {
            cmd_name = cmd_name,
            args = args,
            args_dynamic = args_dynamic,
        })
        ctx.taint.set = ctx.taint.set or not c.read_only
        if c.deny or c.ask then
            return false
        end
        struct_safe = (c.read_only or c.safe_write)
            and not may_run_config_code(cmd_name, args, args_dynamic, ctx, node)
    else
        ctx.taint.set = true
    end

    local safe = glob_safe or struct_safe
    if safe and #subst_ranges > 0 then
        -- Otherwise-safe leaf whose only problem is a dirty substitution:
        -- pinpoint the in-place inner instead of washing the whole leaf.
        return false, subst_ranges
    end
    if not safe then
        -- Reached only when no deny/ask/structural bail fired above: the leaf is
        -- unapproved purely for lack of an allow match, so it is rememberable.
        return false, nil, leaf
    end
    return true
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

--- Tally a `function_definition`. The body is not run, so no range inside it
--- is recorded. A clean body records every name in `funcs`, an unsafe one (or
--- a definition with an unsafe redirect, see `walk_function_definition`) adds every
--- name to `ctx.shadowed`. An anonymous definition, a name that is not a
--- plain word, or a name zsh calls on its own records the whole range.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
--- @param funcs table<string, boolean>
local function tally_function_definition(node, src, ctx, ranges, funcs)
    local names = ShellParse.function_names(node, src)
    if not names or vim.iter(names):any(ShellParse.runs_without_call) then
        record(ranges, node)
        return
    end
    local body = node:field("body")[1]
    --- @type agentic.utils.PermissionRules.Range[]
    local body_ranges = {}
    if body then
        -- Fresh `leaves`: a definition is not run, so its body leaves are not
        -- rememberable execution positions.
        tally_walk(
            body,
            src,
            -- `taint`: see `walk_function_definition`.
            vim.tbl_extend(
                "force",
                ctx,
                { leaves = {}, written = {}, taint = { set = true } }
            ),
            body_ranges
        )
    end
    local clean = body ~= nil
        and redirects_safe(node, src)
        and #body_ranges == 0
    for _, name in ipairs(names) do
        if clean then
            funcs[name] = true
        else
            ctx.shadowed[name] = true
        end
    end
end

--- Tally statements that may run after a write the tally reaches later; mirrors
--- `walk_unordered`. When the tally sets `ctx.taint`, its ranges and the
--- leaves it added are replaced by a second tally with the taint set from the
--- start.
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[] appended with the statements' ranges
--- @param tally_once fun(once_ranges: agentic.utils.PermissionRules.Range[]) tallies the statements once into `once_ranges`
local function tally_unordered(ctx, ranges, tally_once)
    local tainted = ctx.taint.set
    local n_leaves = #ctx.leaves
    --- @type agentic.utils.PermissionRules.Range[]
    local once_ranges = {}
    tally_once(once_ranges)
    if not tainted and ctx.taint.set then
        for i = #ctx.leaves, n_leaves + 1, -1 do
            ctx.leaves[i] = nil
        end
        once_ranges = {}
        tally_once(once_ranges)
    end
    vim.list_extend(ranges, once_ranges)
end

--- Tally a `redirected_statement`, mirroring `walk_redirected`. The body and
--- the rest of a heredoc's line recurse. A file redirect that is not a safe
--- form (`> /dev/null`, FD duplication), a herestring, a heredoc body with an
--- expansion, and the words on a heredoc's line record as unapproved. The
--- files it writes go into `ctx.written` before the body is tallied. A
--- statement whose line the tree may group differently from zsh records
--- whole.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
--- @param known table<string, string>|nil constant environment of the enclosing sequence
local function tally_redirected(node, src, ctx, ranges, known)
    local parts = redirected_parts(node, src)
    if not parts then
        record(ranges, node)
        ctx.taint.set = true
        return
    end
    --- @param once_ranges agentic.utils.PermissionRules.Range[]
    local function tally_once(once_ranges)
        local paths, content = redirect_writes(parts, src, known)
        record_writes(ctx.written, paths, content, cwds_at(ctx, node))
        if parts.body then
            tally_walk(parts.body, src, ctx, once_ranges)
        end
        --- @type TSNode[]
        local unsafe = {}
        for _, r in ipairs(parts.redirects) do
            local t = r:type()
            if t == "heredoc_redirect" then
                -- Not the whole redirect: it spans the rest of the line.
                if not heredoc_pure_body(r, src) then
                    table.insert(
                        unsafe,
                        ShellParse.heredoc_body(r) --[[@as TSNode]]
                    )
                end
                vim.list_extend(unsafe, r:field("argument"))
            elseif t ~= "file_redirect" or not redirect_is_safe(r, src) then
                -- A file redirect's later destinations are inside it.
                table.insert(unsafe, r)
            end
        end
        for _, n in ipairs(unsafe) do
            record(once_ranges, n)
            ctx.taint.set = true
        end
        for _, statement in ipairs(parts.rest) do
            tally_walk(statement, src, ctx, once_ranges)
        end
    end
    if parts.rest_op == "|" then
        tally_unordered(ctx, ranges, tally_once)
    else
        tally_once(ranges)
    end
end

--- Forward declaration — `tally_sequence` wraps it.
--- @type fun(node: TSNode, src: string, ctx: agentic.utils.PermissionRules.TallyCtx, ranges: agentic.utils.PermissionRules.Range[], seed: table<string, string>|nil)
local tally_statements

--- Tally a straight-line sequence, threading the constant environment so a
--- command whose only "unapproved" token is a resolved benign `$var` is not
--- highlighted (mirrors `walk_sequence`). `seed` (optional) pre-binds names,
--- for a for-loop body unrolled per literal value. UI-only — a stale binding here
--- can only mis-highlight, never mis-approve. A sequence with a background
--- statement is tallied as `tally_unordered`.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
--- @param seed table<string, string>|nil
local function tally_sequence(node, src, ctx, ranges, seed)
    local function tally_once(sequence_ranges)
        tally_statements(node, src, ctx, sequence_ranges, seed)
    end
    if has_background(node) then
        tally_unordered(ctx, ranges, tally_once)
    else
        tally_once(ranges)
    end
end

--- `tally_sequence` once, in statement order.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
--- @param seed table<string, string>|nil
function tally_statements(node, src, ctx, ranges, seed)
    --- @type table<string, string>
    local known = seed and vim.tbl_extend("force", {}, seed) or {}
    --- @type table<string, boolean>
    local funcs = {}
    for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            local t = child:type()
            if t == "command" then
                local safe, sub_ranges, leaf =
                    command_known_safe(child, src, ctx, known, funcs)
                if not safe then
                    if sub_ranges then
                        for _, r in ipairs(sub_ranges) do
                            table.insert(ranges, r)
                        end
                    else
                        record(ranges, child)
                        if leaf then
                            table.insert(ctx.leaves, leaf)
                        end
                    end
                end
            elseif t == "function_definition" then
                tally_function_definition(child, src, ctx, ranges, funcs)
            elseif t == "redirected_statement" then
                tally_redirected(child, src, ctx, ranges, known)
            else
                tally_walk(child, src, ctx, ranges)
            end
            update_known(known, child, src)
        end
    end
end

--- Tally a `for_statement`. Mirrors `walk_for`: a loop var that can change
--- execution records the whole loop; a fully-literal list with a plain
--- loop var unrolls the body once per value, so a body command highlighted
--- for one binding but not another is caught; ranges are deduped across values
--- (one binding highlighting a span is enough). Otherwise the list items record
--- their substitutions (a clean bare `$(...)` records nothing, a dirty one
--- pinpoints its inner, any other runs code flowing into body args) and the body
--- recurses once with the loop var dynamic.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
local function tally_for(node, src, ctx, ranges)
    local var_name, body
    --- @type TSNode[]
    local items = {}
    for child, field in node:iter_children() do
        if child:named() then
            if field == "variable" then
                var_name = vim.treesitter.get_node_text(child, src)
            elseif field == "value" then
                table.insert(items, child)
            elseif field == "body" then
                body = child
            end
        end
    end

    if not (var_name and ShellParse.is_safe_var_name(var_name)) then
        record(ranges, node)
        return
    end

    local budget = ctx.for_budget or FOR_UNROLL_CAP
    if body and var_name:match("^[%w_]+$") and #items > 0 then
        --- @type string[]
        local values = {}
        local all_literal = true
        for _, item in ipairs(items) do
            local lit = pure_literal_token(item, src)
            if lit and is_safe_literal(lit) then
                table.insert(values, lit)
            else
                all_literal = false
                break
            end
        end
        if all_literal and #values <= budget then
            local sub_ctx = vim.tbl_extend(
                "force",
                ctx,
                { for_budget = math.max(1, math.floor(budget / #values)) }
            )
            local seen = {}
            for _, v in ipairs(values) do
                --- @type agentic.utils.PermissionRules.Range[]
                local per_value = {}
                tally_sequence(
                    body,
                    src,
                    sub_ctx,
                    per_value,
                    { [var_name] = v }
                )
                for _, r in ipairs(per_value) do
                    local key = table.concat(r, ",")
                    if not seen[key] then
                        seen[key] = true
                        table.insert(ranges, r)
                    end
                end
            end
            return
        end
    end

    for _, item in ipairs(items) do
        record_substitutions(item, src, ctx, ranges)
    end
    if body then
        tally_unordered(ctx, ranges, function(loop_ranges)
            tally_walk(body, src, ctx, loop_ranges)
        end)
    end
end

--- Tally a `while_statement` (covers `while`/`until`): condition and body each
--- recurse as statements.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.TallyCtx
--- @param ranges agentic.utils.PermissionRules.Range[]
local function tally_while(node, src, ctx, ranges)
    tally_unordered(ctx, ranges, function(loop_ranges)
        for child, field in node:iter_children() do
            if child:named() and (field == "condition" or field == "body") then
                tally_walk(child, src, ctx, loop_ranges)
            end
        end
    end)
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
    elseif
        SEQUENCE_TYPES[t]
        or t == "do_group"
        or t == "compound_statement"
        or t == "subshell"
    then
        tally_sequence(node, src, ctx, ranges)
    elseif t == "pipeline" then
        tally_unordered(ctx, ranges, function(pipeline_ranges)
            tally_children(node, src, ctx, pipeline_ranges)
        end)
    elseif CONTAINER_TYPES[t] then
        tally_children(node, src, ctx, ranges)
    elseif t == "command" then
        local safe, sub_ranges, leaf = command_known_safe(node, src, ctx)
        if not safe then
            if sub_ranges then
                for _, r in ipairs(sub_ranges) do
                    table.insert(ranges, r)
                end
            else
                record(ranges, node)
                if leaf then
                    table.insert(ctx.leaves, leaf)
                end
            end
        end
    elseif t == "redirected_statement" then
        tally_redirected(node, src, ctx, ranges, nil)
    elseif t == "variable_assignment" then
        local value = node:field("value")[1]
        if not safe_assignment_name(node, src) then
            record(ranges, node)
        elseif value then
            record_substitutions(value, src, ctx, ranges)
        end
    elseif t == "for_statement" then
        tally_for(node, src, ctx, ranges)
    elseif t == "while_statement" then
        tally_while(node, src, ctx, ranges)
    elseif t == "function_definition" then
        tally_function_definition(node, src, ctx, ranges, {})
    else
        -- A bare substitution statement or any unknown/unmodelled node:
        -- highlight it. The decision walk fails closed here, so the prompt
        -- fired — show the user what triggered it.
        record(ranges, node)
    end
end

--- The cwds of a command that starts in `cwd`.
--- @param cwd string|nil absolute directory; nil when unknown
--- @return agentic.utils.ShellParse.Cwds
local function start_cwds(cwd)
    return cwd and { dirs = { vim.fs.normalize(cwd) }, unknown = false }
        or unknown_cwds()
end

--- Find every part of a Bash command that is NOT known-safe — the leaves and
--- structural nodes the permission prompt is asking about. Find-all (every
--- branch), unlike the first-bail decision `walk`. Two consumers:
---
--- * The highlighter reads `ranges` — byte ranges relative to `command`'s own
---   lines (0-indexed rows, byte cols, matching `node:range()`). It binds to the
---   *displayed* (reformatted) command, whereas the decision walk binds to the
---   raw `rawInput.command`.
--- * The allow-always collector reads `leaves`/`complete`: `leaves` are the
---   stripped signatures of parts unapproved purely for lack of an allow match
---   (rememberable as session-local allow patterns); `complete` is true iff
---   *every* unapproved part was such a leaf — false signals the manager to keep
---   the whole-command fallback for deny/ask-gated or structural parts.
---
--- `ranges` is `nil` when the command does not parse (no parser / parse error)
--- so the highlighter can fall back to highlighting the whole block; an empty
--- list means it parsed and nothing needs attention (bare prompt). On any
--- non-parse path `leaves` is empty and `complete` is false. Pure analysis — it
--- never grants anything.
--- @param command string
--- @param config_dir string Claude's config directory
--- @param cwd string|nil absolute directory the command starts in; nil when unknown
--- @return agentic.utils.PermissionRules.Range[]|nil ranges
--- @return string[] leaves
--- @return boolean complete
function M.tally_unapproved(command, config_dir, cwd)
    local root = ZshParse.parse_command(command)
    if not root then
        return nil, {}, false
    end

    local allow = M.get_settings_patterns("allow", config_dir)
    local deny = M.get_settings_patterns("deny", config_dir)
    local ask = M.get_settings_patterns("ask", config_dir)
    local structured_entries = PermissionStructured.get_entries()
    local reader_memo = {}
    local run = walk_until_shadowed_settles(function(shadowed)
        --- @type agentic.utils.PermissionRules.TallyCtx
        local ctx = {
            allow = allow,
            deny = deny,
            ask = ask,
            structured_entries = structured_entries,
            depth = 0,
            leaves = {},
            written = {},
            for_budget = FOR_UNROLL_CAP,
            shadowed = shadowed,
            read_scripts = true,
            cwd_of = {},
            taint = { set = false },
            sourced = {},
            reader_memo = reader_memo,
        }
        ctx.cwd_of = tree_cwds(root, command, start_cwds(cwd), ctx, 0)
        --- @type agentic.utils.PermissionRules.Range[]
        local ranges = {}
        tally_walk(root, command, ctx, ranges)
        return { ranges = ranges, leaves = ctx.leaves }
    end)
    -- Each clean leaf records exactly one range and collects one signature;
    -- every other unapproved part records ≥1 range and no signature. So the
    -- counts match iff every unapproved part was a rememberable leaf.
    return run.ranges, run.leaves, #run.leaves == #run.ranges
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
-- withholds approval, and prompts. The deny pass also keeps `--` as the end of
-- options, even where the approve walk reads it as a flag's value. Net:
-- concrete deny rejects, laundered/uncertain deny prompts.

--- @alias agentic.utils.PermissionRules.RejectCtx { deny: agentic.utils.PermissionRules.CompiledPattern[], structured_entries: agentic.StructuredEntries, depth: integer }

--- Forward declaration — `reject_walk` and `command_is_denied` are mutually
--- recursive (a transparent-prefix wrapper re-walks its inner command).
--- @type fun(node: TSNode, src: string, ctx: agentic.utils.PermissionRules.RejectCtx): "deny"|"glob_deny"|nil
local reject_walk

--- Which deny a single `command` leaf concretely matches: `"glob_deny"` for a
--- glob deny pattern from settings.json, `"deny"` for a structured deny gate
--- (concrete-only), nil for neither. A transparent prefix (`timeout … cmd`,
--- `sh -c '…'`) re-walks its inner command so a wrapped deny still rejects. Returns nil on any extraction bail — the leaf's own
--- denial cannot be established, and any executed substitution inside it is
--- visited separately by `reject_walk`'s child recursion.
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.RejectCtx
--- @return "deny"|"glob_deny"|nil
local function command_is_denied(node, src, ctx)
    local args, arg_nodes, args_dynamic = extract_args(
        node,
        src,
        ctx,
        nil,
        function()
            return true
        end
    )
    if not args then
        return nil
    end
    local name = ShellParse.command_name(node, src)
    if not name then
        return nil
    end
    local cmd_name = M.strip_command_path(name)

    -- Transparent prefix: a deny buried under `timeout`/`sh -c` still rejects.
    local inner =
        inner_source(cmd_name, node, args, arg_nodes, args_dynamic, src)
    if inner and ctx.depth < NESTED_MAX_DEPTH then
        local root = parse_zsh(inner)
        local source = root
            and reject_walk(
                root,
                inner,
                vim.tbl_extend("force", ctx, {
                    depth = ctx.depth + 1,
                })
            )
        if source then
            return source
        end
    end

    local leaf = leaf_text(name, args)
    -- Action host: a denied action rejects, and the structured matcher sees
    -- the host without its actions (`-delete` inside an action is an
    -- argument of it).
    local actions, actions_root = parsed_actions(
        cmd_name,
        args,
        args_dynamic --[[@as boolean[] ]],
        ctx.depth
    )
    if actions and actions_root then
        local source = reject_walk(
            actions_root,
            actions.inner,
            vim.tbl_extend("force", ctx, {
                depth = ctx.depth + 1,
            })
        )
        if source then
            return source
        end
        args, args_dynamic = actions.args, actions.args_dynamic
    end

    if #ctx.deny > 0 and M.matches_any_pattern(leaf, ctx.deny) then
        return "glob_deny"
    end

    if next(ctx.structured_entries) ~= nil then
        if
            PermissionStructured.deny_leaf(ctx.structured_entries, {
                cmd_name = cmd_name,
                args = args,
                args_dynamic = args_dynamic,
            })
        then
            return "deny"
        end
    end
    return nil
end

--- Walk the parse tree, returning the deny matched by the first executed
--- `command` leaf that is a concrete deny: `"glob_deny"` for a settings.json
--- pattern, `"deny"` for a structured gate, else nil. Recurses into every
--- executed position — pipelines, &&/||/; chains, loops, conditionals,
--- redirected bodies, and command substitutions — by descending into all named
--- children. A `function_definition` is skipped: defining a function never
--- runs its body (a later call laundering through it falls to the approve walk,
--- which prompts).
--- @param node TSNode
--- @param src string
--- @param ctx agentic.utils.PermissionRules.RejectCtx
--- @return "deny"|"glob_deny"|nil
reject_walk = function(node, src, ctx)
    local t = node:type()
    if t == "function_definition" then
        return nil
    end
    if t == "command" then
        local source = command_is_denied(node, src, ctx)
        if source then
            return source
        end
    end
    for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            local source = reject_walk(child, src, ctx)
            if source then
                return source
            end
        end
    end
    return nil
end

--- Whether a Bash command must be REJECTED outright (a `deny` rule matched), as
--- opposed to merely not-approved. Parses with the zsh grammar and returns true
--- if any executed leaf is a concrete deny (a structured `deny` gate or a glob
--- deny pattern). Concrete-only — a dynamic token does not trigger a reject (it
--- falls through to the approve walk's prompt). Fail-closed-to-PROMPT: no parser,
--- a parse error, or an over-long command returns false so the command prompts
--- rather than silently rejecting.
--- @param command string
--- @param config_dir string Claude's config directory
--- @return boolean rejected
--- @return "deny"|"glob_deny"|nil source The rejecting leaf's match: a structured deny gate (`"deny"`) or a settings.json deny pattern (`"glob_deny"`); nil unless rejected
function M.should_auto_reject(command, config_dir)
    local deny = M.get_settings_patterns("deny", config_dir)
    local structured_entries = PermissionStructured.get_entries()
    if #deny == 0 and next(structured_entries) == nil then
        return false
    end

    local root = ZshParse.parse_command(command)
    if not root then
        return false
    end

    local source = reject_walk(root, command, {
        deny = deny,
        structured_entries = structured_entries,
        depth = 0,
    })
    return source ~= nil, source
end

--- Parse a Bash command with the zsh grammar and walk the tree against
--- `rules` and the structured rules: every leaf command must match an allow
--- pattern, no leaf may match a deny or ask pattern, and any unmodelled
--- structure (argument-position substitution, dynamic command name, negation)
--- bails. A file-writing redirect emits an effect rather than bailing; brace
--- groups (`{ …; }`), subshells (`( … )`), loops, and if/case control flow
--- recurse into every branch. Fail-closed: an absent parser, a parse error,
--- or a truncated/malformed tree all return false.
--- @param command string
--- @param rules { allow_settings: agentic.utils.PermissionRules.CompiledPattern[], allow_remembered: agentic.utils.PermissionRules.CompiledPattern[], deny: agentic.utils.PermissionRules.CompiledPattern[], ask: agentic.utils.PermissionRules.CompiledPattern[], tier: agentic.PermAutoApproveTier, read_scripts: boolean, cwd: string|nil } `read_scripts` false leaves code a command reads unread, so its leaf meets the rules as written. `cwd` is the absolute directory the command starts in, nil when unknown
--- @return boolean ok Structurally approvable
--- @return agentic.utils.PermissionRules.Effect[] effects Concrete file-mutating effects (redirect writes, `rm` operands) the command would produce, in order
--- @return table<agentic.utils.PermissionRules.Source, true> sources Every source that allowed a single command; empty unless ok
local function run_walk(command, rules)
    local structured_entries = PermissionStructured.get_entries()
    -- Skip the parse entirely when neither layer has any allow source — the
    -- walker has nothing to approve against.
    if
        #rules.allow_settings == 0
        and #rules.allow_remembered == 0
        and next(structured_entries) == nil
    then
        return false, {}, {}
    end

    local root = ZshParse.parse_command(command)
    if not root then
        return false, {}, {}
    end

    local reader_memo = {}
    local run = walk_until_shadowed_settles(function(shadowed)
        --- @type agentic.utils.PermissionRules.WalkCtx
        local ctx = {
            allow_settings = rules.allow_settings,
            allow_remembered = rules.allow_remembered,
            sources = {},
            deny = rules.deny,
            ask = rules.ask,
            structured_entries = structured_entries,
            auto_approve_tier = rules.tier,
            depth = 0,
            effects = {},
            written = {},
            for_budget = FOR_UNROLL_CAP,
            shadowed = shadowed,
            read_scripts = rules.read_scripts,
            cwd_of = {},
            taint = { set = false },
            sourced = {},
            reader_memo = reader_memo,
        }
        ctx.cwd_of = tree_cwds(root, command, start_cwds(rules.cwd), ctx, 0)
        local ok = walk(root, command, ctx)
        -- More shadowed names only turn approvals into bails.
        return { ok = ok, ctx = ctx }, not ok
    end)
    -- Leaves before a failing one have already added their sources.
    return run.ok, run.ctx.effects, run.ok and run.ctx.sources or {}
end

--- Check if a Bash command should be auto-approved under the configured
--- settings.json rules and `auto_approve_tier`, by the walk of `run_walk`.
---
--- A structurally-ok command with effects STILL requires every effect to clear
--- at the policy layer before approval — `ok` alone is not approval (see
--- permission_manager's `_bash_effects_clear`). Empty effects means a pure
--- read/no-write command that approves on `ok` alone.
---
--- `extra_allow` injects session-remembered leaf patterns on top of the
--- configured allow rules; they widen approval only, never override a deny/ask.
--- A script the command runs or sources is read from every directory the
--- command may be in at that point, starting from `cwd`.
--- @param command string
--- @param config_dir string Claude's config directory
--- @param cwd string|nil absolute directory the command starts in; nil when unknown
--- @param extra_allow agentic.utils.PermissionRules.CompiledPattern[]|nil
--- @return boolean ok
--- @return agentic.utils.PermissionRules.Effect[] effects
--- @return table<agentic.utils.PermissionRules.Source, true> sources
function M.evaluate(command, config_dir, cwd, extra_allow)
    -- Remembered leaves count even when `auto_approve_tier` is nil, because the
    -- user approved each one.
    return run_walk(command, {
        allow_settings = Config.permissions.auto_approve_tier
                and M.get_settings_patterns("allow", config_dir)
            or {},
        allow_remembered = extra_allow or {},
        deny = M.get_settings_patterns("deny", config_dir),
        ask = M.get_settings_patterns("ask", config_dir),
        tier = Config.permissions.auto_approve_tier,
        read_scripts = true,
        cwd = cwd,
    })
end

--- Whether a command only reads: every leaf passes a structured `read_only`
--- gate, no structured deny or ask gate matches, and it has no file-mutating
--- effect. Settings.json rules, remembered leaves and `auto_approve_tier` do
--- not count. Code a command reads (`ExecutedCode.READERS`) is not read, so
--- its leaf meets the rules as written. For display, never for
--- approval. Memoised per command while the structured rules are unchanged.
--- @param command string
--- @return boolean
function M.is_read_only(command)
    local entries = PermissionStructured.get_entries()
    if entries ~= read_only_entries then
        read_only_entries = entries
        cached_read_only = {}
    end
    local cached = cached_read_only[command]
    if cached ~= nil then
        return cached
    end
    local ok, effects = run_walk(command, {
        allow_settings = {},
        allow_remembered = {},
        deny = {},
        ask = {},
        tier = "read_only",
        read_scripts = false,
    })
    local read_only = ok and #effects == 0
    cached_read_only[command] = read_only
    return read_only
end

--- Whether a command auto-approves on its own, with no grant scope. True iff it
--- is structurally approvable AND produces no file-mutating effects (a redirect
--- write or an `rm`, see `evaluate`).
--- @param command string
--- @param config_dir string Claude's config directory
--- @param cwd string|nil see `evaluate`
--- @param extra_allow agentic.utils.PermissionRules.CompiledPattern[]|nil session-remembered leaf patterns (forwarded to `evaluate`)
--- @return boolean
function M.should_auto_approve(command, config_dir, cwd, extra_allow)
    local ok, effects = M.evaluate(command, config_dir, cwd, extra_allow)
    return ok and #effects == 0
end

--- Compile a single command leaf into an exact-match allow pattern (no glob
--- wildcarding), for injecting a session-remembered leaf into `evaluate`'s allow
--- list. Built from the path-stripped leaf so it matches the same form
--- `matches_any_pattern` compares against (which strips the bin-dir prefix per
--- segment).
--- @param leaf string
--- @return agentic.utils.PermissionRules.CompiledPattern
function M.literal_pattern(leaf)
    local stripped = M.strip_command_path(leaf)
    return {
        original = stripped,
        lua_pattern = "^" .. vim.pesc(stripped) .. "$",
    }
end

--- Invalidate the settings.json patterns (forces a re-read on next check).
function M.invalidate_cache()
    cached_settings_patterns = {}
end

return M
