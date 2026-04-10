local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local PermissionRules = require("agentic.utils.permission_rules")

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

    -- Read-only tools: always approve (no filesystem mutation possible)
    if
        Config.auto_approve_read_only_tools
        and READ_ONLY_KINDS[tool_call.kind]
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

    return false
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
