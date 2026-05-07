local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local GitFiles = require("agentic.utils.git_files")
local Logger = require("agentic.utils.logger")
local PermissionRules = require("agentic.utils.permission_rules")
local TrustSafety = require("agentic.utils.trust_safety")

-- Priority order for permission option kinds.
-- Lower number = higher priority (appears first).
local PERMISSION_KIND_PRIORITY = {
    plan_implement = 0,
    allow_once = 1,
    allow_always = 2,
    reject_once = 3,
    reject_always = 4,
}

--- @class agentic.ui.PermissionManager
--- @field message_writer agentic.ui.MessageWriter Reference to MessageWriter instance
--- @field _buf_nrs agentic.ui.ChatWidget.BufNrs All widget buffer numbers for keymap application
--- @field queue table[] Queue of pending requests {toolCallId, request, callback}
--- @field current_request? agentic.ui.PermissionManager.PermissionRequest Currently displayed request
--- @field keymap_info table[] Keymap info for cleanup {mode, lhs, bufnr}
--- @field _reanchoring boolean Guard flag to prevent recursive on_content_changed during reanchor
--- @field _always_cache table<string, "allow"|"reject"> Client-side cache for allow_always/reject_always decisions
--- @field _trust_scope? agentic.utils.TrustSafety.Scope Active trust scope (set by /trust)
--- @field _edit_records table<string, agentic.utils.TrustSafety.EditRecord> Post-edit line ranges of completed Edits, keyed by tool_call_id
--- @field _pending_edits table<string, { path: string, start_line: integer, new_lines: string[] }> Range data captured at tool_call time, promoted to _edit_records on completion
local PermissionManager = {}
PermissionManager.__index = PermissionManager

--- @param message_writer agentic.ui.MessageWriter
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @return agentic.ui.PermissionManager
function PermissionManager:new(message_writer, buf_nrs)
    local instance = setmetatable({
        message_writer = message_writer,
        _buf_nrs = buf_nrs or { chat = message_writer.bufnr },
        queue = {},
        current_request = nil,
        keymap_info = {},
        _reanchoring = false,
        _always_cache = {},
        _trust_scope = nil,
        _edit_records = {},
        _pending_edits = {},
    }, self)

    return instance
end

--- ACP tool kinds that are guaranteed read-only (no filesystem mutations).
local READ_ONLY_KINDS = {
    read = true,
    search = true,
}

--- File-scoped tool kinds where allow_always applies per file path.
local FILE_SCOPED_KINDS = {
    edit = true,
    write = true,
    create = true,
    delete = true,
    move = true,
}

--- Build a cache key for an allow_always/reject_always decision.
--- File-scoped tools key on kind:path, others on kind alone.
--- @param tool_call agentic.acp.ToolCall
--- @return string|nil
local function build_cache_key(tool_call)
    local kind = tool_call.kind
    if not kind then
        return nil
    end
    if FILE_SCOPED_KINDS[kind] then
        local path = tool_call.rawInput and tool_call.rawInput.file_path
        if path then
            return kind .. ":" .. path
        end
    end
    return kind
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

--- Send allow_once for the given request. Returns true on success.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
--- @param reason string
--- @return boolean
local function auto_approve(request, callback, reason)
    local option_id = find_option_id(request.options, "allow_once")
    if option_id then
        Logger.debug("PermissionManager: auto-approving:", reason)
        callback(option_id)
        return true
    end
    return false
end

--- Send reject_once for the given request. Returns true on success.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
--- @param reason string
--- @return boolean
local function auto_reject(request, callback, reason)
    local option_id = find_option_id(request.options, "reject_once")
    if option_id then
        Logger.debug("PermissionManager: auto-rejecting:", reason)
        callback(option_id)
        return true
    end
    return false
end

--- Try to auto-approve a permission request without user interaction.
---
--- Two independent checks (either can approve):
--- 1. Read-only tool kinds ("read", "search") — always safe regardless of path.
--- 2. Compound Bash commands — every pipe/chain segment must match an allow
---    pattern from settings.json with no deny/ask match.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
--- @return boolean handled
function PermissionManager:_try_auto_approve(request, callback)
    local tool_call = request.toolCall
    if not tool_call then
        return false
    end

    -- Read-only tools: always approve (no filesystem mutation possible).
    -- Match case-insensitively — providers vary on casing (e.g. opencode
    -- emits "Read" while the ACP spec uses lowercase).
    local kind_lc = tool_call.kind and tool_call.kind:lower() or nil
    if
        Config.auto_approve_read_only_tools
        and kind_lc
        and READ_ONLY_KINDS[kind_lc]
    then
        return auto_approve(
            request,
            callback,
            "read-only tool kind: " .. tool_call.kind
        )
    end

    -- Compound Bash commands: check each segment against settings.json rules
    if Config.auto_approve_compound_commands then
        local raw_input = tool_call.rawInput
        if
            raw_input
            and raw_input.command
            and PermissionRules.should_auto_approve(raw_input.command)
        then
            return auto_approve(
                request,
                callback,
                "compound command: " .. raw_input.command
            )
        end
    end

    -- Client-side allow_always/reject_always cache (provider persistence unreliable via ACP)
    local cache_key = build_cache_key(tool_call)
    if cache_key then
        local cached = self._always_cache[cache_key]
        if cached == "allow" then
            return auto_approve(
                request,
                callback,
                "cached allow_always: " .. cache_key
            )
        elseif cached == "reject" then
            return auto_reject(
                request,
                callback,
                "cached reject_always: " .. cache_key
            )
        end
    end

    -- Trust scope: scoped auto-approval for file-scoped tool kinds when the
    -- target lies inside the user's /trust scope AND the change is recoverable
    -- (new file, or tracked file with clean / Claude-owned hunks).
    if
        Config.auto_approve_trust_scope
        and self._trust_scope
        and FILE_SCOPED_KINDS[tool_call.kind]
    then
        local ok, reason = self:_check_trust(tool_call)
        if ok then
            return auto_approve(
                request,
                callback,
                "trust scope: "
                    .. self._trust_scope.display
                    .. " ("
                    .. reason
                    .. ")"
            )
        end
    end

    return false
end

--- Read the file path from a tool call's rawInput. Different ACP providers
--- use slightly different field names; check the common ones in order.
---
--- Known field usage by provider:
---   - claude-agent-acp, claude-acp, auggie-acp: `file_path` (snake_case)
---   - opencode-acp: `filePath` (camelCase)
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

--- Check whether `path` lies inside the active trust scope. The orchestrator
--- handles symlink resolution at the call site, so this is a pure-membership
--- check over the (already-resolved) path.
--- @param path string Absolute, normalised path
--- @return boolean
function PermissionManager:_path_in_trust_scope(path)
    local scope = self._trust_scope
    if not scope then
        return false
    end

    if scope.kind == "path" and scope.glob_matcher then
        return scope.glob_matcher(path) == true
    end

    local git_root = GitFiles.get_git_root(scope.cwd)
    if not git_root then
        return false
    end
    if not GitFiles.is_tracked(path, git_root) then
        return false
    end
    if scope.kind == "here" then
        local cwd = scope.cwd
        if cwd:sub(-1) ~= "/" then
            cwd = cwd .. "/"
        end
        return vim.startswith(path, cwd)
    end
    return true
end

--- Build a `KindArgs` for one path: stat, tracked-state, hunks, edit range,
--- and Claude-owned ranges. Returns nil if the path is missing or git lookup
--- fails.
--- @param tool_call agentic.acp.ToolCall
--- @param path string Absolute, normalised path (post-symlink for orig)
--- @param git_root string|nil Git root for the scope, or nil for kind="path"
--- @return agentic.utils.TrustSafety.KindArgs|nil
function PermissionManager:_build_kind_args(tool_call, path, git_root)
    local snap = TrustSafety.stat_snapshot(path)
    local tracked = git_root ~= nil and GitFiles.is_tracked(path, git_root)
    local hunks = (tracked and snap.exists)
            and GitFiles.diff_hunks(git_root, path)
        or {}

    --- @type string[]
    local file_lines = {}
    if snap.exists then
        local read_lines, err = FileSystem.read_from_disk(path)
        if read_lines then
            file_lines = read_lines
        else
            Logger.debug("trust: could not read", path, err)
        end
    end

    local tracker = self.message_writer.tool_call_blocks[tool_call.toolCallId]
    local diff = tracker and tracker.diff

    local edit_range = TrustSafety.edit_target_range(diff, file_lines)
    local owned = TrustSafety.claude_owned_ranges(
        path,
        self._edit_records,
        tool_call.toolCallId,
        file_lines
    )

    --- @type agentic.utils.TrustSafety.KindArgs
    local args = {
        exists = snap.exists,
        tracked = tracked,
        has_unstaged_hunks = #hunks > 0,
        hunks = hunks,
        edit_range = edit_range,
        claude_owned_ranges = owned,
        is_pure_addition = TrustSafety.is_pure_addition(diff),
        write_all = diff and diff.all or nil,
    }
    return args
end

--- Orchestrator for the trust check: symlink resolution → scope match →
--- stat snapshot → git state → safety predicate → mtime revalidation.
--- @param tool_call agentic.acp.ToolCall
--- @return boolean ok
--- @return string reason
function PermissionManager:_check_trust(tool_call)
    local raw = tool_call.rawInput
    local source_path = raw_input_path(raw)
    if not source_path then
        return false, "no file path"
    end

    local orig, real = TrustSafety.resolve_symlink_pair(source_path)
    if not orig then
        return false, "broken symlink"
    end

    if not self:_path_in_trust_scope(orig) then
        return false, "path not in scope"
    end
    if real ~= orig and not self:_path_in_trust_scope(real) then
        return false, "symlink realpath outside scope"
    end

    local source_snap = TrustSafety.stat_snapshot(orig)

    local scope = self._trust_scope --[[@as agentic.utils.TrustSafety.Scope]]
    local git_root = nil
    if scope.kind ~= "path" then
        git_root = GitFiles.get_git_root(scope.cwd)
        if not git_root then
            return false, "no git root for scope"
        end
    else
        -- For path scope, infer git root from the file's location for hunk
        -- detection. Failure is fine — without a git root we treat the file
        -- as untracked, which will still allow create/new-file paths.
        git_root = GitFiles.get_git_root(vim.fs.dirname(orig))
    end

    local source_args = self:_build_kind_args(tool_call, orig, git_root)
    if not source_args then
        return false, "could not build source args"
    end

    --- @type agentic.utils.TrustSafety.StatSnapshot|nil
    local dest_snap = nil
    if tool_call.kind == "move" then
        local dest = raw_input_destination(raw)
        if not dest then
            return false, "move missing destination"
        end
        local d_orig, d_real = TrustSafety.resolve_symlink_pair(dest)
        if not d_orig then
            return false, "destination broken symlink"
        end
        if not self:_path_in_trust_scope(d_orig) then
            return false, "destination outside scope"
        end
        if d_real ~= d_orig and not self:_path_in_trust_scope(d_real) then
            return false, "destination symlink realpath outside scope"
        end
        dest_snap = TrustSafety.stat_snapshot(d_orig)
        local dest_git_root = git_root
            or GitFiles.get_git_root(vim.fs.dirname(d_orig))
        local dest_args =
            self:_build_kind_args(tool_call, d_orig, dest_git_root)
        if not dest_args then
            return false, "could not build destination args"
        end
        source_args.dest = dest_args
    end

    local ok, reason = TrustSafety.safe_for_kind(tool_call.kind, source_args)
    if not ok then
        return false, reason or "unsafe"
    end

    -- TOCTOU revalidation: re-stat between snapshot and approval.
    if not TrustSafety.stat_unchanged(orig, source_snap) then
        return false, "source changed during check"
    end
    if dest_snap then
        local dest = raw_input_destination(raw) or ""
        if dest ~= "" and not TrustSafety.stat_unchanged(dest, dest_snap) then
            return false, "destination changed during check"
        end
    end

    return true, reason or "safe"
end

--- Record the pre-edit position of an Edit tool call. Called from
--- SessionManager on the initial `tool_call` notification, before the SDK
--- has applied the edit to disk. `start_line` is the 1-based line where
--- `old_string` begins — the same line where `new_string` will land.
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
    --- @type agentic.utils.TrustSafety.EditRecord
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
--- Used by SessionManager to avoid redundant disk reads when recording
--- is attempted from multiple points in the tool-call lifecycle.
--- @param tool_call_id string
--- @return boolean
function PermissionManager:has_edit_range(tool_call_id)
    return self._pending_edits[tool_call_id] ~= nil
        or self._edit_records[tool_call_id] ~= nil
end

--- Set the active trust scope. Replaces any existing scope.
--- @param scope agentic.utils.TrustSafety.Scope
function PermissionManager:set_trust_scope(scope)
    self._trust_scope = scope
end

--- Clear the active trust scope.
function PermissionManager:clear_trust_scope()
    self._trust_scope = nil
end

--- Read the active trust scope (or nil if unset).
--- @return agentic.utils.TrustSafety.Scope|nil
function PermissionManager:get_trust_scope()
    return self._trust_scope
end

--- Add a new permission request to the queue to be processed sequentially
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function PermissionManager:add_request(request, callback)
    if not request.toolCall or not request.toolCall.toolCallId then
        Logger.debug(
            "PermissionManager: Invalid request - missing toolCall.toolCallId"
        )
        return
    end

    if self:_try_auto_approve(request, callback) then
        return
    end

    local toolCallId = request.toolCall.toolCallId
    table.insert(self.queue, { toolCallId, request, callback })

    if not self.current_request then
        self:_process_next()
    end
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

    local _, _, option_mapping = self.message_writer:display_permission_buttons(
        request.toolCall.toolCallId,
        sorted_options
    )

    ---@class agentic.ui.PermissionManager.PermissionRequest
    self.current_request = {
        toolCallId = toolCallId,
        request = request,
        callback = callback,
        option_mapping = option_mapping,
    }

    self:_setup_keymaps(option_mapping)

    self.message_writer:set_on_content_changed(function()
        self:_reanchor_permission_prompt()
    end)
end

function PermissionManager:_reanchor_permission_prompt()
    if self._reanchoring or not self.current_request then
        return
    end

    self._reanchoring = true

    --- @type agentic.ui.PermissionManager.PermissionRequest
    local current = self.current_request

    local ok, err = pcall(function()
        self.message_writer:remove_permission_buttons()
        self:_remove_keymaps()

        local sorted_options =
            self._sort_permission_options(current.request.options)

        local _, _, option_mapping =
            self.message_writer:display_permission_buttons(
                current.request.toolCall.toolCallId,
                sorted_options
            )

        current.option_mapping = option_mapping

        self:_setup_keymaps(option_mapping)
    end)

    self._reanchoring = false

    if not ok then
        Logger.notify(
            "Error during permission prompt reanchor: " .. vim.inspect(err),
            vim.log.levels.ERROR
        )
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
    if selected_kind == "allow_always" or selected_kind == "reject_always" then
        local cache_key = build_cache_key(current.request.toolCall)
        if cache_key then
            local action = selected_kind == "allow_always" and "allow"
                or "reject"
            self._always_cache[cache_key] = action
            Logger.debug("PermissionManager: cached", action, "for", cache_key)
        end
    end

    self.message_writer:remove_permission_buttons()

    self:_remove_keymaps()
    self.message_writer:set_on_content_changed(nil)
    current.callback(option_id)

    self.current_request = nil
    self:_process_next()
end

--- Clear all displayed buttons and keymaps, cancel all pending requests.
--- Called when session ends or user cancels generation.
function PermissionManager:clear()
    if self.current_request then
        self.message_writer:remove_permission_buttons()
        self:_remove_keymaps()
        self.message_writer:set_on_content_changed(nil)

        local ok, err = pcall(self.current_request.callback, nil)
        if not ok then
            Logger.debug("Permission callback error during clear:", err)
        end
        self.current_request = nil
    end

    for _, item in ipairs(self.queue) do
        local callback = item[3]
        local ok, err = pcall(callback, nil)
        if not ok then
            Logger.debug("Queued permission callback error during clear:", err)
        end
    end

    self.queue = {}
    self._always_cache = {}
    self._trust_scope = nil
    self._edit_records = {}
    self._pending_edits = {}
end

--- Reject the current request and cancel all remaining queued requests.
--- Unlike clear(), sends reject_once (not cancelled) for the current request
--- so the provider sees an active rejection and can adapt its approach.
function PermissionManager:reject_and_cancel_remaining()
    if not self.current_request then
        return
    end

    -- Find the reject_once option
    local reject_option_id
    for _, option in ipairs(self.current_request.request.options) do
        if option.kind == "reject_once" then
            reject_option_id = option.optionId
            break
        end
    end

    -- Remove UI and keymaps for current request
    self.message_writer:remove_permission_buttons()
    self:_remove_keymaps()
    self.message_writer:set_on_content_changed(nil)

    -- Send reject_once for current, cancelled for the rest
    local ok, err = pcall(self.current_request.callback, reject_option_id)
    if not ok then
        Logger.debug("Permission callback error during reject:", err)
    end
    self.current_request = nil

    for _, item in ipairs(self.queue) do
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

--- @param option_mapping table<integer, string> Mapping from number (1-N) to option_id
function PermissionManager:_setup_keymaps(option_mapping)
    self:_remove_keymaps()

    local permission_keys = Config.keymaps.permission or {}

    for number, option_id in pairs(option_mapping) do
        local lhs = permission_keys[number] or tostring(number)
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

        for _, bufnr in pairs(self._buf_nrs) do
            if vim.api.nvim_buf_is_valid(bufnr) then
                BufHelpers.keymap_set(bufnr, "n", lhs, callback, {
                    desc = "Select permission option " .. tostring(number),
                })
                table.insert(
                    self.keymap_info,
                    { mode = "n", lhs = lhs, bufnr = bufnr }
                )
            end
        end
    end
end

function PermissionManager:_remove_keymaps()
    for _, info in ipairs(self.keymap_info) do
        if vim.api.nvim_buf_is_valid(info.bufnr) then
            pcall(vim.keymap.del, info.mode, info.lhs, { buffer = info.bufnr })
        end
    end
    self.keymap_info = {}
end

return PermissionManager
