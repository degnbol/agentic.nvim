local AcpKind = require("agentic.utils.acp_kind")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local GitFiles = require("agentic.utils.git_files")
local Logger = require("agentic.utils.logger")
local PermissionFloat = require("agentic.ui.permission_float")
local PermissionHighlight = require("agentic.ui.permission_highlight")
local PermissionRules = require("agentic.utils.permission_rules")
local GrantSafety = require("agentic.utils.grant_safety")

--- Highlights washing the non-known-safe parts of an execute permission prompt.
local NS_PERMISSION_HIGHLIGHT =
    vim.api.nvim_create_namespace("agentic_permission_highlight")

-- Priority order for permission option kinds.
-- Lower number = higher priority (appears first).
local PERMISSION_KIND_PRIORITY = {
    plan_implement = 0,
    allow_once = 1,
    allow_always = 2,
    reject_once = 3,
    reject_always = 4,
}

--- What approved, rejected or withheld approval of a tool call.
--- @alias agentic.PermissionCauseCode
--- | "read-only"       # a structured read_only rule allowed a shell command
--- | "safe-write"      # a structured safe_write rule allowed a shell command
--- | "glob-allow"      # a settings.json allow pattern allowed a shell command
--- | "session-allow"   # a remembered allow-always decision
--- | "session-reject"  # a remembered reject-always decision
--- | "deny"            # a structured deny gate matched a shell command
--- | "glob-deny"       # a settings.json deny pattern matched a shell command
--- | "kind"            # whether the call's kind is an approved kind
--- | "grant"           # the grant check of a path, approving or not
--- | "prompt-allow"    # the user allowed at the prompt
--- | "prompt-reject"   # the user rejected at the prompt
--- | "prompt-cancel"   # the prompt was withdrawn unanswered
--- | agentic.utils.PermissionRules.Reason

--- @class agentic.PermissionCause
--- @field code agentic.PermissionCauseCode
--- @field subject? string Command part, path or kind it judged
--- @field detail? string Why, where `code` alone does not say

--- @class agentic.PermissionVerdict
--- @field allow? boolean True to approve, false to reject, nil when no check decides
--- @field causes agentic.PermissionCause[] Empty only for an approved command that runs nothing (`# hi`)

--- Agent-facing text per cause code, for a cause with no `detail`.
--- @type table<agentic.PermissionCauseCode, string>
local CAUSE_TEXT = vim.tbl_extend("error", PermissionRules.REASON_TEXT, {
    deny = "a deny rule matches it",
    ["glob-deny"] = "a deny rule matches it",
    ["session-reject"] = "rejected for this session",
    kind = "calls of this kind need approval",
    grant = "a grant scope clears it",
})

--- An approval policy in place of the configured one.
--- @class agentic.ui.PermissionManager.Policy : agentic.utils.PermissionRules.Policy
--- @field kinds string[] In place of Config.permissions.auto_approve_kinds

--- @class agentic.ui.PermissionManager
--- @field message_writer agentic.ui.MessageWriter Main-chat writer; default when no per-tool-call resolver is set
--- @field _writer_for? fun(tool_call_id: string): agentic.ui.MessageWriter Resolves the writer owning a tool call (main vs subagent); falls back to message_writer
--- @field _buf_nrs agentic.ui.ChatWidget.BufNrs All widget buffer numbers for keymap application
--- @field queue table[] Queue of pending requests {toolCallId, request, callback}
--- @field current_request? agentic.ui.PermissionManager.PermissionRequest Currently displayed request
--- @field _keymap_restores fun()[] One per option or open key bound on a buffer, in binding order. Each unbinds its key and puts back the map it shadowed
--- @field _layout_autocmd? integer Autocmd re-placing the float and its keys on layout changes while a request is shown
--- @field permission_float agentic.ui.PermissionFloat
--- @field on_hidden? fun(badge_bufnr: integer, anchor_bufnr: integer) Called the first time a request waits with its float not visible in the current tabpage. `anchor_bufnr` is the buffer of its tool call. `badge_bufnr` is the chat while the float shows there in place of `anchor_bufnr`, else `anchor_bufnr`
--- @field on_hidden_resolved? fun(badge_bufnr: integer) Called when a request `on_hidden` reported ends, with the `badge_bufnr` it reported
--- @field open_anchor? fun(bufnr: integer, how: agentic.ui.OpenHow): integer|nil Opens `bufnr` and returns its window, or nil when nothing opened. Called by the open keys, which are bound while a request's float shows on the chat in place of its tool call's buffer
--- @field proxy_tool_call? fun(anchor_bufnr: integer): string|nil The id of the tool call in the chat that stands for the owner of `anchor_bufnr`, or nil when there is none
--- @field companion_bufs? fun(anchor: integer): integer[] Buffers besides the session's own that also get the option keys of a request whose tool call is in `anchor`
--- @field on_decided? fun(tool_call_id: string, causes: agentic.PermissionCause[]) Called on a later event loop tick after causes are recorded for a tool call
--- @field _causes table<string, agentic.PermissionCause[]> Recorded causes not yet taken, keyed by tool call id
--- @field _bash_cwds table<string, string> Directory each Bash call starts in, keyed by tool call id
--- @field _hidden boolean Whether the current request waits with its float hidden
--- @field _always_cache table<string, "allow"|"reject"> Client-side cache for allow_always/reject_always decisions
--- @field _execute_leaf_allow table<string, boolean> Session-remembered execute leaves vouched for via allow_always
--- @field _grant_scopes agentic.utils.GrantSafety.Scope[] Active grant scopes (set by /grant)
--- @field _tmp_roots string[] Temp roots, each in literal and resolved form
--- @field _edit_records table<string, agentic.utils.GrantSafety.EditRecord> Post-edit line ranges of completed Edits, keyed by tool_call_id
--- @field _pending_edits table<string, { path: string, start_line: integer, new_lines: string[] }> Range data captured at tool_call time, promoted to _edit_records on completion
--- @field _get_config_dir fun(): string Returns Claude's config directory. A getter, because the directory can change during this manager's life
--- @field _policy? agentic.ui.PermissionManager.Policy Set by `set_policy`; nil judges by the configuration
local PermissionManager = {}
PermissionManager.__index = PermissionManager

--- @param message_writer agentic.ui.MessageWriter
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param writer_for? fun(tool_call_id: string): agentic.ui.MessageWriter Resolver for the writer owning a tool call (main vs subagent)
--- @param get_config_dir fun(): string Returns Claude's config directory, called at each use
--- @return agentic.ui.PermissionManager
function PermissionManager:new(
    message_writer,
    buf_nrs,
    writer_for,
    get_config_dir
)
    local instance = setmetatable({
        message_writer = message_writer,
        _writer_for = writer_for,
        _get_config_dir = get_config_dir,
        _buf_nrs = buf_nrs or { agent = message_writer.bufnr },
        permission_float = PermissionFloat:new(message_writer, buf_nrs),
        queue = {},
        current_request = nil,
        _keymap_restores = {},
        _hidden = false,
        _always_cache = {},
        _execute_leaf_allow = {},
        _grant_scopes = {},
        _tmp_roots = GrantSafety.tmp_roots(),
        _edit_records = {},
        _pending_edits = {},
        _causes = {},
        _bash_cwds = {},
    }, self)

    return instance
end

--- The MessageWriter owning a tool call: the chat's, or a subagent
--- transcript's.
--- @param tool_call_id string
--- @return agentic.ui.MessageWriter
function PermissionManager:_writer(tool_call_id)
    if self._writer_for then
        return self._writer_for(tool_call_id)
    end
    return self.message_writer
end

--- File-scoped tool kinds where allow_always applies per file path.
local FILE_SCOPED_KINDS = {
    edit = true,
    write = true,
    create = true,
    delete = true,
    move = true,
}

--- Identity fields of an allow_always/reject_always cache key, per ACP
--- protocol kind: the request's own kind, never an adapter-minted one.
--- @type table<string, string[]>
local CACHE_KEY_FIELDS = {
    edit = { "file_path", "filePath", "path" },
    write = { "file_path", "filePath", "path" },
    create = { "file_path", "filePath", "path" },
    delete = { "file_path", "filePath", "path" },
    move = { "file_path", "filePath", "path" },
    execute = { "command" },
    fetch = { "url" },
    switch_mode = { "mode" },
}

--- Fields that vary across "the same" operation and must not drive cache
--- identity. `description` is Claude's natural-language narration on Bash
--- commands ("List files in current directory"). `timeout` is transient.
--- Used by the hybrid path; also skipped if listed in CACHE_KEY_FIELDS.
--- @type table<string, true>
local CACHE_NOISE_FIELDS = {
    description = true,
    timeout = true,
}

--- Stable string representation of a table for cache keying. Sorts top-level
--- keys so two tables with the same content always produce the same string
--- regardless of `pairs()` iteration order.
--- @param t table
--- @return string
local function stable_repr(t)
    local keys = vim.tbl_keys(t)
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if type(v) == "table" then
            v = vim.inspect(v, { newline = "", indent = "" })
        end
        table.insert(parts, tostring(k) .. "=" .. tostring(v))
    end
    return table.concat(parts, "|")
end

--- Build a cache key for an allow_always/reject_always decision. The key
--- represents "the same operation again" — approving one invocation must
--- not silently approve a different one.
---
--- Two paths:
--- 1. Known kinds (`CACHE_KEY_FIELDS`): key on the kind's identity fields
---    (file_path / command / url / mode). Common case.
--- 2. Unknown kinds: hybrid — key on the whole `rawInput` minus
---    `CACHE_NOISE_FIELDS`. Lets new / provider-specific kinds (e.g.
---    `"other"`) still scope per call without per-tool maintenance.
---
--- Returns `nil` when no identifying input is available. The cache then
--- silently skips the decision and the next call prompts again — safer
--- than under-scoping by caching on bare kind.
--- @param tool_call agentic.acp.ToolCall Keyed on its `kind` and `rawInput` alone, with nothing filled in from the tool call tracker
--- @return string|nil
function PermissionManager:_build_cache_key(tool_call)
    local kind = AcpKind.normalise(tool_call.kind)
    if kind == "" then
        return nil
    end

    local raw_input = tool_call.rawInput
    local fields = CACHE_KEY_FIELDS[kind]
    if fields then
        local parts = { kind }
        for _, name in ipairs(fields) do
            local v = raw_input and raw_input[name]
            if v ~= nil and v ~= "" then
                table.insert(parts, tostring(v))
            end
        end
        if #parts == 1 then
            return nil
        end
        return table.concat(parts, ":")
    end

    if not raw_input or vim.tbl_isempty(raw_input) then
        return nil
    end
    local key_data = {}
    for k, v in pairs(raw_input) do
        if not CACHE_NOISE_FIELDS[k] then
            key_data[k] = v
        end
    end
    if vim.tbl_isempty(key_data) then
        return nil
    end
    return kind .. ":" .. stable_repr(key_data)
end

--- Find an option by kind and return its optionId.
--- @param options agentic.acp.PermissionOption[]
--- @param kind string
--- @return string|nil
local function find_option_id(options, kind)
    for _, option in ipairs(options) do
        if option.kind == kind then
            return option.optionId
        end
    end
    return nil
end

--- Answer a request with its option of `kind`, when it has one.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
--- @param kind "allow_once"|"reject_once"
--- @return boolean sent False when the request has no such option
local function send_option(request, callback, kind)
    local option_id = find_option_id(request.options, kind)
    if option_id then
        Logger.debug("PermissionManager: auto-answering", kind)
        callback(option_id)
        return true
    end
    return false
end

--- Answer a request with its allow_once option, when it has one.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
--- @return boolean sent False when the request has no such option
function PermissionManager.approve(request, callback)
    return send_option(request, callback, "allow_once")
end

--- Answer a request with its reject_once option, when it has one.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
--- @return boolean sent False when the request has no such option
function PermissionManager.reject(request, callback)
    return send_option(request, callback, "reject_once")
end

--- The shell command of a permission request: `rawInput.command`, else the
--- `argument` of its tool call tracker when that tracker's kind is execute.
--- @param request agentic.acp.RequestPermission
--- @return string|nil command
function PermissionManager:_request_command(request)
    local tool_call = request.toolCall
    local raw_input = tool_call and tool_call.rawInput
    local command = raw_input and raw_input.command
    if not command and tool_call then
        local tracker =
            self:_writer(tool_call.toolCallId).tool_call_blocks[tool_call.toolCallId]
        if tracker and AcpKind.normalise(tracker.kind) == "execute" then
            command = tracker.argument
        end
    end
    return command
end

--- Compile the session-remembered execute leaves into allow patterns to inject
--- into the decision walk. Empty set → empty list (a no-op merge in `evaluate`).
--- @return agentic.utils.PermissionRules.CompiledPattern[]
function PermissionManager:_remembered_leaf_patterns()
    local patterns = {}
    for leaf in pairs(self._execute_leaf_allow) do
        table.insert(patterns, PermissionRules.literal_pattern(leaf))
    end
    return patterns
end

--- The shell sources in the order their cause codes display.
--- @type agentic.utils.PermissionRules.Source[]
local SHELL_SOURCE_ORDER =
    { "read_only", "safe_write", "glob_allow", "session_allow" }

--- The cause code of a permission rule source.
--- @param source agentic.utils.PermissionRules.Source|"deny"|"glob_deny"
--- @return agentic.PermissionCauseCode
local function cause_code(source)
    return (source:gsub("_", "-")) --[[@as agentic.PermissionCauseCode]]
end

--- One agent-facing line for a cause: `<subject>: <why>`, or `<why>` for a
--- cause with no subject. `<why>` is the cause's detail, else its code's text,
--- else the code itself.
--- @param cause agentic.PermissionCause
--- @return string
function PermissionManager.cause_line(cause)
    local why = cause.detail or CAUSE_TEXT[cause.code] or cause.code
    return cause.subject and ("%s: %s"):format(cause.subject, why) or why
end

--- Whether the policy's kinds, else `Config.permissions.auto_approve_kinds`,
--- list a kind, compared case-insensitively.
--- @param kind_lc string Trimmed, lowercase kind (the `AcpKind.normalise` form)
--- @return boolean
function PermissionManager:_is_approved_kind(kind_lc)
    local kinds = self._policy and self._policy.kinds
        or Config.permissions.auto_approve_kinds
    return vim.tbl_contains(kinds, function(k)
        return AcpKind.normalise(k) == kind_lc
    end, { predicate = true })
end

--- Judge every later call by `policy` in place of the configured tier,
--- settings.json allows and approved kinds.
--- @param policy agentic.ui.PermissionManager.Policy
function PermissionManager:set_policy(policy)
    self._policy = policy
end

--- The rules a shell command is judged by, under the policy when one is set.
--- @return agentic.utils.PermissionRules.Rules
function PermissionManager:_rules()
    return PermissionRules.rules(
        self._get_config_dir(),
        self:_remembered_leaf_patterns(),
        self._policy
    )
end

--- A request's kind, tool call, edit diff and Bash cwd, with what the request
--- leaves out filled in from its tool call tracker:
--- - kind: the tracker's kind when it is an approved kind. opencode's
---   `external_directory` requests and Claude's Skill requests arrive with
---   kind="other".
--- - tool_call: a copy with the tracker's command as `rawInput.command` when
---   the request has none (opencode sends `metadata: {}` on shell requests).
--- All four are nil when the request has no tool call.
--- @param request agentic.acp.RequestPermission
--- @return string|nil kind
--- @return agentic.acp.ToolCall|nil tool_call
--- @return table|nil diff The tracker's edit diff
--- @return string|nil cwd Directory the Bash call starts in, nil when unknown
function PermissionManager:resolve_request(request)
    local tool_call = request.toolCall
    if not tool_call then
        return nil, nil, nil, nil
    end

    local tracker =
        self:_writer(tool_call.toolCallId).tool_call_blocks[tool_call.toolCallId]
    local kind = tool_call.kind
    local tracker_kind_lc = tracker and AcpKind.normalise(tracker.kind) or ""
    if self:_is_approved_kind(tracker_kind_lc) then
        kind = tracker.kind
    end

    local command = self:_request_command(request)
    if command and not (tool_call.rawInput and tool_call.rawInput.command) then
        tool_call = vim.tbl_extend("force", {}, tool_call) --[[@as agentic.acp.ToolCall]]
        tool_call.rawInput = vim.tbl_extend(
            "force",
            tool_call.rawInput or {},
            { command = command }
        ) --[[@as agentic.acp.RawInput]]
    end

    return kind,
        tool_call,
        tracker and tracker.diff,
        self:bash_cwd(tool_call.toolCallId)
end

--- Try to auto-approve/reject a permission request without user interaction.
--- On an allow verdict calls `callback` with the request's allow_once option,
--- on a deny verdict with its reject_once option. Not handled when the
--- request has no such option.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
--- @return boolean handled
function PermissionManager:_try_auto_approve(request, callback)
    local kind, tool_call, diff, cwd = self:resolve_request(request)
    if not tool_call then
        return false
    end
    local verdict = self:decide(kind, tool_call, diff, cwd)
    local handled = false
    if verdict.allow == true then
        handled = PermissionManager.approve(request, callback)
    elseif verdict.allow == false then
        handled = PermissionManager.reject(request, callback)
    end
    -- Unhandled (no matching option), the request goes to the prompt.
    if handled then
        self:record_causes(tool_call.toolCallId, verdict.causes)
    end
    return handled
end

--- Hold `causes` for a tool call, replacing any already held.
--- @param tool_call_id string
--- @param causes agentic.PermissionCause[]
function PermissionManager:stash_causes(tool_call_id, causes)
    self._causes[tool_call_id] = causes
end

--- Hold `causes` for a tool call, then call `on_decided` on a later event
--- loop tick. Does no other work, so it is safe in a context that must not
--- fail or block.
--- @param tool_call_id string
--- @param causes agentic.PermissionCause[]
function PermissionManager:record_causes(tool_call_id, causes)
    self:stash_causes(tool_call_id, causes)
    vim.schedule(function()
        if self.on_decided then
            self.on_decided(tool_call_id, causes)
        end
    end)
end

--- Remove and return the causes held for a tool call.
--- @param tool_call_id string
--- @return agentic.PermissionCause[]|nil causes
function PermissionManager:take_causes(tool_call_id)
    local causes = self._causes[tool_call_id]
    self._causes[tool_call_id] = nil
    return causes
end

--- Forget the causes held for every tool call.
function PermissionManager:drop_causes()
    self._causes = {}
end

--- Hold the directory a Bash call starts in, replacing any already held.
--- @param tool_call_id string
--- @param cwd string absolute
function PermissionManager:record_bash_cwd(tool_call_id, cwd)
    self._bash_cwds[tool_call_id] = cwd
end

--- @param tool_call_id string
--- @return string|nil cwd The directory held for a Bash call
function PermissionManager:bash_cwd(tool_call_id)
    return self._bash_cwds[tool_call_id]
end

--- Forget the directory held for a Bash call.
--- @param tool_call_id string
function PermissionManager:drop_bash_cwd(tool_call_id)
    self._bash_cwds[tool_call_id] = nil
end

--- Read the file path from a tool call's rawInput. Different ACP providers
--- use slightly different field names; check the common ones in order.
---
--- Known field usage by provider:
---   - claude-agent-acp, auggie-acp: `file_path` (snake_case)
---   - opencode-acp: `path` (`filePath` in sessions migrated from 1.x)
---   - gemini-acp, codex-acp, mistral-vibe-acp: path arrives via
---     `update.locations[]` or `update.content[]`, not `rawInput` — these
---     providers will return nil here and rely on the adapter to surface
---     the path through `tool_call.argument` instead.
--- @param raw table|nil
--- @return string|nil
local function raw_input_path(raw)
    if not raw then
        return nil
    end
    return raw.file_path
        or raw.filePath
        or raw.path
        or raw.target
        or raw.source_path
        or raw.sourcePath
end

--- Read the destination path from a `move`'s rawInput. None of the surveyed
--- providers currently send move/rename destinations via rawInput, so the
--- camelCase aliases are defensive — if a future provider emits them.
--- @param raw table|nil
--- @return string|nil
local function raw_input_destination(raw)
    if not raw then
        return nil
    end
    return raw.destination_path
        or raw.destinationPath
        or raw.destination
        or raw.new_path
        or raw.newPath
        or raw.target_path
        or raw.targetPath
end

--- True iff some active grant scope contains `path`.
--- @param path string Absolute, normalised path
--- @return boolean
function PermissionManager:_path_granted(path)
    for _, scope in ipairs(self._grant_scopes) do
        if GrantSafety.scope_contains(scope, path) then
            return true
        end
    end
    return false
end

--- The literal and resolved forms of `path`, or nil when either is not
--- granted, or `path` is relative or does not resolve.
--- @param path string
--- @return string|nil orig Normalised `path`
--- @return string|nil real Resolved `path`, symlinked parents included
function PermissionManager:_granted_pair(path)
    if path:sub(1, 1) ~= "/" then
        return nil, nil
    end
    local orig = vim.fs.normalize(path, { expand_env = false })
    if not self:_path_granted(orig) then
        return nil, nil
    end
    local real = GrantSafety.resolve(path)
    if real and self:_path_granted(real) then
        return orig, real
    end
    return nil, nil
end

--- `GrantSafety.is_under_tmp` against this manager's tmp roots.
--- @param path string
--- @return boolean
function PermissionManager:_is_under_tmp(path)
    return GrantSafety.is_under_tmp(path, self._tmp_roots)
end

--- Whether every file-mutating effect a Bash command would produce clears
--- against the active grant scopes. Empty effects → trivially clear (a
--- command with no concrete writes auto-approves on structural grounds
--- alone). Otherwise every effect path must be absolute and granted in both
--- its literal and resolved form. A relative path never clears: an effect
--- holds its path as written, without the directories it may resolve in.
---
--- Each effect must pass `GrantSafety.safe_for_kind`, except a delete of
--- scratch (`GrantSafety.is_scratch`): it clears only when an earlier write
--- in the same (ordered) list targeted the same path and
--- `Config.permissions.tmp_cleanup` is on. The file state is rechecked before
--- returning.
---
--- Effects are judged against the file state before the command runs. An
--- earlier leaf in the same command that changes files (an allowed
--- formatter, as in `black f.py; rm f.py`) can change that state.
--- @param effects agentic.utils.PermissionRules.Effect[]
--- @return boolean ok
--- @return string|nil reason Why the first refused effect is refused, nil when ok
--- @return string|nil path The refused effect's path, nil when ok
function PermissionManager:_bash_effects_clear(effects)
    if #effects == 0 then
        return true
    end
    --- Paths written earlier in this same command.
    --- @type table<string, boolean>
    local written = {}
    --- @type { path: string, snap: agentic.utils.GrantSafety.StatSnapshot }[]
    local snapshots = {}
    for _, eff in ipairs(effects) do
        if eff.path:sub(1, 1) ~= "/" then
            return false, "relative path", eff.path
        end
        local orig, real = self:_granted_pair(eff.path)
        if not orig or not real then
            return false, "not in a grant scope", eff.path
        end
        local snap = GrantSafety.stat_snapshot(orig)
        local args = self:_kind_args(eff.kind, orig, real, nil, nil)
        if eff.kind == "delete" and GrantSafety.is_scratch(args) then
            if not Config.permissions.tmp_cleanup then
                return false, "scratch delete with tmp_cleanup off", eff.path
            end
            if not written[orig] then
                return false, "scratch delete with no earlier write", eff.path
            end
        else
            local safe, reason = GrantSafety.safe_for_kind(eff.kind, args)
            if not safe then
                return false, reason, eff.path
            end
        end
        table.insert(snapshots, { path = orig, snap = snap })
        if eff.kind == "write" then
            written[orig] = true
        end
    end
    for _, s in ipairs(snapshots) do
        if not GrantSafety.stat_unchanged(s.path, s.snap) then
            return false, "file changed during check", s.path
        end
    end
    return true
end

--- Build a `KindArgs` for one path. write/create/edit follow a symlink, so
--- their file state is read from `real`. delete and move (source and
--- destination) act on the link itself, so theirs is read from `orig`. Git
--- state comes from the repo holding that file.
--- @param kind string Normalised tool kind acting on the path
--- @param orig string Absolute, normalised path
--- @param real string Resolved `orig`, symlinked parents included
--- @param diff { old?: string[], new?: string[], all?: boolean }|nil Edit diff, passed in so this stays tracker-free (see `decide`)
--- @param exclude_id string|nil Tool call whose own edit record is left out of the Claude-owned ranges
--- @return agentic.utils.GrantSafety.KindArgs
function PermissionManager:_kind_args(kind, orig, real, diff, exclude_id)
    local path = (kind == "delete" or kind == "move") and orig or real
    local snap = GrantSafety.stat_snapshot(path)
    local lstat = vim.uv.fs_lstat(path)
    local git_root = vim.fs.root(vim.fs.dirname(path), ".git")
    --- @type boolean|nil
    local tracked = false
    if git_root then
        tracked = GitFiles.is_tracked(path, git_root)
    end
    --- @type agentic.utils.GitFiles.Hunk[]|nil
    local hunks = {}
    if git_root and tracked and snap.exists then
        hunks = GitFiles.diff_hunks(git_root, path)
    end
    local git_unknown = snap.exists and (tracked == nil or hunks == nil)
    hunks = hunks or {}

    --- @type string[]
    local file_lines = {}
    if snap.exists then
        local read_lines, err = FileSystem.read_from_disk(path)
        if read_lines then
            file_lines = read_lines
        else
            Logger.debug("grant: could not read", path, err)
        end
    end

    local edit_range = GrantSafety.edit_target_range(diff, file_lines)
    local owned = GrantSafety.claude_owned_ranges(
        path,
        self._edit_records,
        exclude_id,
        file_lines
    )

    --- @type agentic.utils.GrantSafety.KindArgs
    local args = {
        exists = snap.exists,
        tracked = tracked == true,
        git_unknown = git_unknown,
        has_unstaged_hunks = #hunks > 0,
        hunks = hunks,
        edit_range = edit_range,
        claude_owned_ranges = owned,
        is_pure_addition = GrantSafety.is_pure_addition(diff),
        write_all = diff and diff.all or nil,
        tmp = self:_is_under_tmp(orig) and self:_is_under_tmp(real),
        is_dir = lstat ~= nil and lstat.type == "directory",
    }
    return args
end

--- Whether the file mutation of `tool_call` is safe to auto-approve under
--- the active grant scopes: its path (and a move's destination) is granted
--- in literal and resolved form, passes `GrantSafety.safe_for_kind`, and
--- does not change on disk during the check.
--- @param kind_lc string Normalised tool kind (passed in — see `decide`)
--- @param tool_call agentic.acp.ToolCall
--- @param diff { old?: string[], new?: string[], all?: boolean }|nil Edit diff
--- @return boolean ok
--- @return string reason Why the mutation is or is not safe
function PermissionManager:_check_grant(kind_lc, tool_call, diff)
    local raw = tool_call.rawInput
    local source_path = raw_input_path(raw)
    if not source_path then
        return false, "no file path"
    end

    local orig, real = self:_granted_pair(source_path)
    if not orig or not real then
        return false, "not in a grant scope"
    end

    local source_snap = GrantSafety.stat_snapshot(orig)
    local source_args =
        self:_kind_args(kind_lc, orig, real, diff, tool_call.toolCallId)

    --- @type string|nil
    local dest_orig = nil
    --- @type agentic.utils.GrantSafety.StatSnapshot|nil
    local dest_snap = nil
    if kind_lc == "move" then
        local dest = raw_input_destination(raw)
        if not dest then
            return false, "move missing destination"
        end
        local dest_real
        dest_orig, dest_real = self:_granted_pair(dest)
        if not dest_orig or not dest_real then
            return false, "destination not in a grant scope"
        end
        dest_snap = GrantSafety.stat_snapshot(dest_orig)
        source_args.dest = self:_kind_args(
            "move",
            dest_orig,
            dest_real,
            nil,
            tool_call.toolCallId
        )
    end

    local ok, reason = GrantSafety.safe_for_kind(kind_lc, source_args)
    if not ok then
        return false, reason or "unsafe"
    end

    -- TOCTOU revalidation: re-stat between snapshot and approval.
    if not GrantSafety.stat_unchanged(orig, source_snap) then
        return false, "source changed during check"
    end
    if dest_orig and dest_snap then
        if not GrantSafety.stat_unchanged(dest_orig, dest_snap) then
            return false, "destination changed during check"
        end
    end

    return true, reason or "safe"
end

--- The text of `src` inside `range`.
--- @param src string
--- @param range agentic.utils.PermissionRules.Range
--- @return string
local function range_text(src, range)
    local lines = vim.split(src, "\n", { plain = true })
    local sr, sc, er, ec = range[1] + 1, range[2], range[3] + 1, range[4]
    if sr == er then
        return lines[sr]:sub(sc + 1, ec)
    end
    local out = { lines[sr]:sub(sc + 1) }
    vim.list_extend(out, lines, sr + 1, er - 1)
    table.insert(out, lines[er]:sub(1, ec))
    return table.concat(out, "\n")
end

--- The verdict of the shell checks on `command`: approved when every leaf
--- matches an allow rule with no deny/ask and every file effect clears the
--- grant scopes, else undecided. An approval's causes are its allow sources
--- in display order, then one `grant` per effect. An undecided verdict has
--- one `grant` cause for the first effect that does not clear, else one cause
--- per unapproved part. A command with no part to blame gets one `unparsed`
--- or `structure` cause on the whole command.
--- @param command string
--- @param cwd string|nil Directory the command starts in; nil when unknown
--- @return agentic.PermissionVerdict
function PermissionManager:_shell_verdict(command, cwd)
    local rules = self:_rules()
    --- @type agentic.PermissionVerdict
    local verdict = { causes = {} }
    local ok, effects, sources = PermissionRules.evaluate(command, rules, cwd)
    if ok then
        local clear, reason, path = self:_bash_effects_clear(effects)
        if not clear then
            verdict.causes =
                { { code = "grant", subject = path, detail = reason } }
            return verdict
        end
        verdict.allow = true
        for _, source in ipairs(SHELL_SOURCE_ORDER) do
            if sources[source] then
                table.insert(verdict.causes, { code = cause_code(source) })
            end
        end
        for _, effect in ipairs(effects) do
            table.insert(
                verdict.causes,
                { code = "grant", subject = effect.path }
            )
        end
        return verdict
    end

    local ranges = PermissionRules.tally_unapproved(command, rules, cwd)
    if not ranges then
        verdict.causes = { { code = "unparsed", subject = command } }
    elseif #ranges == 0 then
        -- The walk bailed on something the tally does not model.
        verdict.causes = { { code = "structure", subject = command } }
    else
        verdict.causes = vim.tbl_map(function(range)
            --- @type agentic.PermissionCause
            local cause =
                { code = range[5], subject = range_text(command, range) }
            return cause
        end, ranges)
    end
    return verdict
end

--- Run the deterministic permission ladder and return its verdict, with **no**
--- ACP-side effect (no callback, no auto_approve/auto_reject).
---
--- Checks in order (the first to decide wins):
--- 1. Compound Bash commands: a concrete `deny` match on any executed leaf
---    → reject, with the leaf as the cause's subject.
--- 2. allow_always/reject_always client cache, so a cached reject also beats
---    the checks below.
--- 3. Approved kinds (`_is_approved_kind`), whatever the path → approve.
--- 4. Compound Bash commands: `_shell_verdict`.
--- 5. Grant scopes for file-scoped kinds.
---
--- An undecided verdict's causes are the shell check's, then the grant
--- check's, for whichever of the two judge the call. A call that neither
--- judges has one `kind` cause.
---
--- Reads only its arguments, never the tool call tracker, since the tracker
--- may be unpopulated. A command must be in `tool_call.rawInput.command`.
--- @param kind string|nil ACP tool kind
--- @param tool_call agentic.acp.ToolCall
--- @param diff { old?: string[], new?: string[], all?: boolean }|nil Edit diff for the grant check
--- @param cwd string|nil Directory a Bash command starts in; nil when unknown
--- @return agentic.PermissionVerdict
function PermissionManager:decide(kind, tool_call, diff, cwd)
    local kind_lc = AcpKind.normalise(kind)

    local command = tool_call.rawInput and tool_call.rawInput.command
    if command then
        local rejected, source, leaf =
            PermissionRules.should_auto_reject(command, self._get_config_dir())
        if rejected and source then
            --- @type agentic.PermissionVerdict
            local denied = {
                allow = false,
                causes = { { code = cause_code(source), subject = leaf } },
            }
            return denied
        end
    end

    local cache_key = self:_build_cache_key(tool_call)
    local cached = cache_key and self._always_cache[cache_key]
    if cached then
        --- @type agentic.PermissionVerdict
        local remembered = {
            allow = cached == "allow",
            causes = {
                {
                    code = cached == "allow" and "session-allow"
                        or "session-reject",
                },
            },
        }
        return remembered
    end

    --- @type agentic.PermissionVerdict
    local verdict = { causes = {} }
    if self:_is_approved_kind(kind_lc) then
        verdict.allow = true
        verdict.causes = { { code = "kind", subject = kind_lc } }
        return verdict
    end

    if command then
        local shell = self:_shell_verdict(command, cwd)
        if shell.allow then
            return shell
        end
        verdict.causes = shell.causes
    end

    if FILE_SCOPED_KINDS[kind_lc] then
        local ok, reason = self:_check_grant(kind_lc, tool_call, diff)
        --- @type agentic.PermissionCause
        local grant = {
            code = "grant",
            subject = raw_input_path(tool_call.rawInput),
            detail = reason,
        }
        if ok then
            verdict.allow = true
            verdict.causes = { grant }
            return verdict
        end
        table.insert(verdict.causes, grant)
    elseif not command then
        verdict.causes = { { code = "kind", subject = kind_lc } }
    end
    return verdict
end

--- Record the pre-edit position of an Edit tool call, before the edit
--- reaches disk. `start_line` is the line where `old_string` begins — the
--- same line where `new_string` will land.
--- @param tool_call_id string
--- @param path string Absolute file path
--- @param start_line integer 1-based
--- @param new_lines string[] Expected post-edit content at the range
function PermissionManager:record_pending_edit(
    tool_call_id,
    path,
    start_line,
    new_lines
)
    self._pending_edits[tool_call_id] = {
        path = path,
        start_line = start_line,
        new_lines = new_lines,
    }
end

--- Promote a pending edit to a finalized record once the tool call reaches
--- `completed`. No-op if no pending record exists (edit failed, or was for a
--- kind we don't track).
--- @param tool_call_id string
function PermissionManager:finalize_edit_range(tool_call_id)
    local pending = self._pending_edits[tool_call_id]
    if not pending then
        return
    end
    self._pending_edits[tool_call_id] = nil
    --- @type agentic.utils.GrantSafety.EditRecord
    local record = {
        path = pending.path,
        start_line = pending.start_line,
        end_line = pending.start_line + #pending.new_lines - 1,
        new_lines = pending.new_lines,
    }
    self._edit_records[tool_call_id] = record
end

--- Drop a pending record (call on failed/rejected tool call).
--- @param tool_call_id string
function PermissionManager:drop_pending_edit(tool_call_id)
    self._pending_edits[tool_call_id] = nil
end

--- True if this tool call already has a pending or finalized edit range.
--- @param tool_call_id string
--- @return boolean
function PermissionManager:has_edit_range(tool_call_id)
    return self._pending_edits[tool_call_id] ~= nil
        or self._edit_records[tool_call_id] ~= nil
end

--- Add a grant scope to the active set.
--- @param scope agentic.utils.GrantSafety.Scope
--- @return boolean added False when a scope with the same key is active
function PermissionManager:add_grant_scope(scope)
    for _, active in ipairs(self._grant_scopes) do
        if active.key == scope.key then
            return false
        end
    end
    table.insert(self._grant_scopes, scope)
    return true
end

--- Remove the active grant scope with `key`, if any.
--- @param key string The scope's `key` field
function PermissionManager:remove_grant_scope(key)
    self._grant_scopes = vim.tbl_filter(function(scope)
        return scope.key ~= key
    end, self._grant_scopes)
end

function PermissionManager:clear_grant_scopes()
    self._grant_scopes = {}
end

--- @return agentic.utils.GrantSafety.Scope[] scopes The active grant scopes, in the order added
function PermissionManager:get_grant_scopes()
    return self._grant_scopes
end

--- Add a new permission request to the queue to be processed sequentially
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
--- @return boolean prompted true only when an interactive prompt was queued
--- (user must act); false when auto-resolved or the request was invalid
function PermissionManager:add_request(request, callback)
    if not request.toolCall or not request.toolCall.toolCallId then
        Logger.debug(
            "PermissionManager: Invalid request - missing toolCall.toolCallId"
        )
        return false
    end

    if self:_try_auto_approve(request, callback) then
        return false
    end

    local toolCallId = request.toolCall.toolCallId
    table.insert(self.queue, { toolCallId, request, callback })

    if not self.current_request then
        self:_process_next()
    end
    return true
end

function PermissionManager:_process_next()
    if #self.queue == 0 then
        return
    end

    local item = table.remove(self.queue, 1)
    local toolCallId = item[1]
    local request = item[2]
    local callback = item[3]
    local sorted_options = self._sort_permission_options(request.options)
    local writer = self:_writer(toolCallId)

    local option_mapping =
        self.permission_float:open(sorted_options, writer.bufnr)
    self:_apply_unapproved_highlight(request)

    ---@class agentic.ui.PermissionManager.PermissionRequest
    ---@field writer agentic.ui.MessageWriter The writer of the tool call's buffer
    ---@field badge_bufnr? integer The buffer `on_hidden` was given to badge
    ---@field proxy_held boolean Whether the chat holds the tool call that stands for the owner of the tool call's buffer (see `proxy_tool_call`)
    self.current_request = {
        toolCallId = toolCallId,
        request = request,
        callback = callback,
        option_mapping = option_mapping,
        was_hidden = false,
        writer = writer,
        proxy_held = false,
    }

    writer:hold_tool_call(toolCallId, true)
    self:_sync_proxy_hold()
    self:_watch_layout()
    self:_sync_keymaps()
    self:_set_hidden(not self.permission_float:is_visible_in_current_tab())
end

--- Record whether the current request waits with its float hidden, and run
--- `on_hidden` the first time it does: tabpage switches flip the state back
--- and forth.
--- @param hidden boolean
function PermissionManager:_set_hidden(hidden)
    self._hidden = hidden
    local request = self.current_request
    if not hidden or not request or request.was_hidden then
        return
    end
    request.was_hidden = true
    local anchor = request.writer.bufnr
    request.badge_bufnr = self.permission_float:is_on_fallback()
            and self.message_writer.bufnr
        or anchor
    if self.on_hidden then
        self.on_hidden(request.badge_bufnr, anchor)
    end
end

--- Make the chat hold the tool call standing for the current request's
--- anchor owner (see `proxy_tool_call`) while the float shows on the chat in
--- place of the anchor, and release it once a window shows the anchor.
function PermissionManager:_sync_proxy_hold()
    local request = self.current_request
    if not request then
        return
    end
    local on_fallback = self.permission_float:is_on_fallback()
    if on_fallback and not request.proxy_held then
        local id = self.proxy_tool_call
            and self.proxy_tool_call(request.writer.bufnr)
        if id then
            -- The proxy's body is the subagent's prompt, not what the
            -- request asks about.
            self.message_writer:hold_tool_call(id, false)
            request.proxy_held = true
        end
    elseif not on_fallback and request.proxy_held then
        self.message_writer:release_hold()
        request.proxy_held = false
    end
end

--- Open the current request's anchor buffer with `open_anchor`, and follow
--- in the window it opens. Leaves the request pending.
--- @param how agentic.ui.OpenHow
function PermissionManager:_open_anchor(how)
    local request = self.current_request
    if not request or not self.open_anchor then
        return
    end
    self:_sync_anchor()
    local winid = self.open_anchor(request.writer.bufnr, how)
    if winid then
        request.writer:follow_in(winid)
    end
end

--- Move the current request to the writer that owns its tool call now: a
--- transcript the user wiped comes back as a new buffer with a new writer.
--- The hold and the float's anchor move with it. A no-op while the writer is
--- the same.
function PermissionManager:_sync_anchor()
    local request = self.current_request --[[@as agentic.ui.PermissionManager.PermissionRequest]]
    local writer = self:_writer(request.toolCallId)
    if writer == request.writer then
        return
    end
    request.writer:release_hold()
    request.writer = writer
    writer:hold_tool_call(request.toolCallId, true)
    self.permission_float:set_anchor(writer.bufnr)
end

--- Highlight the non-known-safe parts of an execute permission prompt while it
--- is shown. A request counts as execute when its tracked tool call is one,
--- for providers that re-kind a request under the underlying tool's
--- toolCallId.
--- @param request agentic.acp.RequestPermission
function PermissionManager:_apply_unapproved_highlight(request)
    if not Config.permissions.highlight_unapproved then
        return
    end
    local tool_call = request.toolCall
    if not tool_call then
        return
    end
    local tracker =
        self:_writer(tool_call.toolCallId).tool_call_blocks[tool_call.toolCallId]
    local tracker_kind_lc = tracker and AcpKind.normalise(tracker.kind) or ""
    if
        AcpKind.normalise(tool_call.kind) ~= "execute"
        and tracker_kind_lc ~= "execute"
    then
        return
    end
    if not tracker then
        return
    end
    local bufnr = self:_writer(tool_call.toolCallId).bufnr
    if bufnr then
        PermissionHighlight.apply(
            bufnr,
            NS_PERMISSION_HIGHLIGHT,
            tracker,
            self._get_config_dir(),
            self:_remembered_leaf_patterns(),
            self:bash_cwd(tool_call.toolCallId)
        )
    end
end

--- Clear the unapproved-command highlight from the buffer owning the current
--- request's tool call, or from the chat when there is no current request.
function PermissionManager:_clear_unapproved_highlight()
    local id = self.current_request and self.current_request.toolCallId
    local writer = id and self:_writer(id) or self.message_writer
    if writer.bufnr then
        PermissionHighlight.clear(writer.bufnr, NS_PERMISSION_HIGHLIGHT)
    end
end

--- @param options agentic.acp.PermissionOption[]
--- @return agentic.acp.PermissionOption[]
function PermissionManager._sort_permission_options(options)
    local sorted = {}
    for _, option in ipairs(options) do
        table.insert(sorted, option)
    end

    table.sort(sorted, function(a, b)
        local priority_a = PERMISSION_KIND_PRIORITY[a.kind] or 999
        local priority_b = PERMISSION_KIND_PRIORITY[b.kind] or 999
        return priority_a < priority_b
    end)

    return sorted
end

--- Complete the current request and process next in queue
--- @param option_id string|nil
function PermissionManager:_complete_request(option_id)
    local current = self.current_request
    if not current then
        return
    end

    -- Cache allow_always/reject_always decisions for client-side auto-approval
    local selected_kind
    for _, opt in ipairs(current.request.options) do
        if opt.optionId == option_id then
            selected_kind = opt.kind
            break
        end
    end
    local selected = AcpKind.normalise(selected_kind)
    if selected == "allow_always" or selected == "reject_always" then
        local _, resolved, _, cwd = self:resolve_request(current.request)
        local tool_call = resolved --[[@as agentic.acp.ToolCall]]
        -- Allow-always on an execute prompt remembers the individual safe-but-
        -- unruled leaves, so a later block sharing them auto-approves. Only the
        -- non-leaf parts (deny/ask-gated, structural) need the whole-command
        -- fallback — `complete` reports whether any such part remains. A tally
        -- with no part to blame remembers no leaf, so it needs the fallback too.
        local store_whole = true
        if selected == "allow_always" then
            local command = tool_call.rawInput and tool_call.rawInput.command
            if command then
                local ranges, leaves, complete =
                    PermissionRules.tally_unapproved(
                        command,
                        self:_rules(),
                        cwd
                    )
                for _, leaf in ipairs(leaves) do
                    self._execute_leaf_allow[leaf] = true
                end
                store_whole = not complete or #ranges == 0
            end
        end

        if store_whole then
            local cache_key = self:_build_cache_key(tool_call)
            if cache_key then
                local action = selected == "allow_always" and "allow"
                    or "reject"
                self._always_cache[cache_key] = action
                Logger.debug(
                    "PermissionManager: cached",
                    action,
                    "for",
                    cache_key
                )
            end
        end
    end

    if vim.startswith(selected, "allow_") then
        self:record_causes(current.toolCallId, { { code = "prompt-allow" } })
    elseif vim.startswith(selected, "reject_") then
        self:record_causes(current.toolCallId, { { code = "prompt-reject" } })
    end

    self.permission_float:close()
    self:_clear_unapproved_highlight()

    self:_release_request()
    current.callback(option_id)

    self.current_request = nil
    self:_process_next()
end

--- Close the prompt and resolve the open and queued requests with nil,
--- recording `prompt-cancel` for each. Remembered decisions and edit records
--- stay.
function PermissionManager:cancel_requests()
    if self.current_request then
        self:record_causes(
            self.current_request.toolCallId,
            { { code = "prompt-cancel" } }
        )
        self.permission_float:close()
        self:_clear_unapproved_highlight()
        self:_release_request()

        local ok, err = pcall(self.current_request.callback, nil)
        if not ok then
            Logger.notify(
                "Permission callback error during cancel: " .. tostring(err),
                vim.log.levels.ERROR
            )
        end
        self.current_request = nil
    end

    for _, item in ipairs(self.queue) do
        self:record_causes(item[1], { { code = "prompt-cancel" } })
        local callback = item[3]
        local ok, err = pcall(callback, nil)
        if not ok then
            Logger.notify(
                "Queued permission callback error during cancel: "
                    .. tostring(err),
                vim.log.levels.ERROR
            )
        end
    end

    self.queue = {}
end

--- Resolve all requests with nil and forget allow/reject-always decisions,
--- remembered execute leaves, recorded edit ranges and grant scopes.
function PermissionManager:clear()
    self:cancel_requests()
    self._always_cache = {}
    self._execute_leaf_allow = {}
    self._edit_records = {}
    self._pending_edits = {}
    self:drop_causes()
    self._bash_cwds = {}
    self:clear_grant_scopes()
end

--- Reject the current request and cancel all remaining queued requests.
--- Unlike `cancel_requests`, sends reject_once (not cancelled) for the current
--- request so the provider sees an active rejection and can adapt its approach.
--- Records `prompt-reject` for the current request, or `prompt-cancel` when it
--- has no reject_once option, and `prompt-cancel` for each queued one.
function PermissionManager:reject_and_cancel_remaining()
    if not self.current_request then
        return
    end

    local reject_option_id
    for _, option in ipairs(self.current_request.request.options) do
        if AcpKind.normalise(option.kind) == "reject_once" then
            reject_option_id = option.optionId
            break
        end
    end

    self:record_causes(self.current_request.toolCallId, {
        { code = reject_option_id and "prompt-reject" or "prompt-cancel" },
    })

    self.permission_float:close()
    self:_clear_unapproved_highlight()
    self:_release_request()

    local ok, err = pcall(self.current_request.callback, reject_option_id)
    if not ok then
        Logger.debug("Permission callback error during reject:", err)
    end
    self.current_request = nil

    for _, item in ipairs(self.queue) do
        self:record_causes(item[1], { { code = "prompt-cancel" } })
        local callback = item[3]
        local ok2, err2 = pcall(callback, nil)
        if not ok2 then
            Logger.debug(
                "Queued permission callback error during reject:",
                err2
            )
        end
    end

    self.queue = {}
end

--- Remove permission request for a specific tool call ID (e.g., when tool call fails)
--- @param toolCallId string
function PermissionManager:remove_request_by_tool_call_id(toolCallId)
    self.queue = vim.tbl_filter(function(item)
        return item[1] ~= toolCallId
    end, self.queue)

    if
        self.current_request
        and self.current_request.toolCallId == toolCallId
    then
        self:_complete_request(nil)
    end
end

--- Bind the current request's option keys on the session's buffers, on the
--- buffer owning the request's tool call and on its `companion_bufs`, while
--- its float is visible in the current tabpage, and unbind them otherwise:
--- the keys are buffer-local, and the buffers can be shown in a tabpage the
--- float is not in. While the float shows on the chat in place of that
--- buffer, the open keys (`PermissionFloat.open_keys`) are bound there too.
--- A key shadows any buffer-local map of the same lhs until unbound.
function PermissionManager:_sync_keymaps()
    self:_remove_keymaps()

    local option_mapping = self.current_request
        and self.current_request.option_mapping
    if
        not option_mapping
        or not self.permission_float:is_visible_in_current_tab()
    then
        return
    end

    local bufnrs = vim.tbl_values(self._buf_nrs)
    local anchor = self.current_request.writer.bufnr
    local extra = { anchor }
    if self.companion_bufs then
        vim.list_extend(extra, self.companion_bufs(anchor))
    end
    for _, bufnr in ipairs(extra) do
        if not vim.list_contains(bufnrs, bufnr) then
            table.insert(bufnrs, bufnr)
        end
    end

    for lhs, option_id in pairs(option_mapping) do
        local callback
        if option_id == "__reject_all__" then
            callback = function()
                self:reject_and_cancel_remaining()
            end
        else
            callback = function()
                self:_complete_request(option_id)
            end
        end

        self:_shadow_keymap(bufnrs, lhs, callback, {
            desc = "Select permission option " .. option_id,
        })
    end

    if self.permission_float:is_on_fallback() and self.open_anchor then
        for _, key in ipairs(PermissionFloat.open_keys()) do
            self:_shadow_keymap(bufnrs, key.lhs, function()
                self:_open_anchor(key.how)
            end, {
                desc = "Open the buffer asking permission: " .. key.how,
            })
        end
    end
end

--- Shadow `lhs` in normal mode on each valid buffer of `bufnrs`, keeping the
--- restores in `_keymap_restores`.
--- @param bufnrs integer[]
--- @param lhs string
--- @param callback fun()
--- @param opts vim.keymap.set.Opts
function PermissionManager:_shadow_keymap(bufnrs, lhs, callback, opts)
    for _, bufnr in ipairs(bufnrs) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            table.insert(
                self._keymap_restores,
                BufHelpers.shadow_keymap(bufnr, "n", lhs, callback, opts)
            )
        end
    end
end

--- Unbind the option keys and put back the maps they shadowed.
function PermissionManager:_remove_keymaps()
    -- LIFO, so overlapping shadows unwind correctly.
    for i = #self._keymap_restores, 1, -1 do
        self._keymap_restores[i]()
    end
    self._keymap_restores = {}
end

--- Place the current request's float for the current layout, update the
--- chat's proxy hold (see `_sync_proxy_hold`), and bind its keys to match. A
--- no-op with no request shown.
function PermissionManager:refresh_float()
    if not self.current_request then
        return
    end
    self:_sync_anchor()
    self.permission_float:place()
    self:_sync_proxy_hold()
    self:_sync_keymaps()
    self:_set_hidden(not self.permission_float:is_visible_in_current_tab())
end

--- Keep the float and its option keys in step with the layout for as long as
--- a request is shown: across tabpage switches, a window closing (the
--- float's anchor, or the float itself), and the anchor buffer entering a
--- window.
function PermissionManager:_watch_layout()
    if self._layout_autocmd then
        return
    end
    self._layout_autocmd = vim.api.nvim_create_autocmd(
        { "TabEnter", "WinClosed", "BufWinEnter" },
        {
            callback = function()
                -- WinClosed runs while the window is still open.
                vim.schedule(function()
                    self:refresh_float()
                end)
            end,
        }
    )
end

--- Unbind the option keys, stop following the layout, end the holds of the
--- request being resolved, and end its hidden state, running
--- `on_hidden_resolved` if it was ever hidden.
function PermissionManager:_release_request()
    self:_remove_keymaps()
    if self._layout_autocmd then
        pcall(vim.api.nvim_del_autocmd, self._layout_autocmd)
        self._layout_autocmd = nil
    end
    self._hidden = false
    local request = self.current_request
    if not request then
        return
    end
    request.writer:release_hold()
    if request.proxy_held then
        self.message_writer:release_hold()
    end
    if request.was_hidden and self.on_hidden_resolved then
        self.on_hidden_resolved(request.badge_bufnr --[[@as integer]])
    end
end

return PermissionManager
