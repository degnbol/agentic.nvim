local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.acp.AgentConfigOptions
--- @field mode? agentic.acp.ConfigOption
--- @field model? agentic.acp.ConfigOption
--- Reserved ACP category. claude-agent-acp 0.29.0 does not emit it — see
--- lua/agentic/acp/AGENTS.md § "`thought_level` ConfigOption not emitted".
--- @field thought_level? agentic.acp.ConfigOption
--- @field legacy_agent_modes agentic.acp.AgentModes
--- @field legacy_agent_models agentic.acp.AgentModels
--- @field _pending_model_select boolean
--- @field _pending_initial_model? string model id to apply once options arrive (session restore)
--- @field _set_model_callback fun(model_id: string, is_legacy: boolean)
local AgentConfigOptions = {}
AgentConfigOptions.__index = AgentConfigOptions

--- @param buffers agentic.ui.ChatWidget.BufNrs Same buffers as ChatWidget instance
--- @param set_mode_callback fun(mode_id: string, is_legacy: boolean)
--- @param set_model_callback fun(model_id: string, is_legacy: boolean)
--- @return agentic.acp.AgentConfigOptions
function AgentConfigOptions:new(buffers, set_mode_callback, set_model_callback)
    local AgentModes = require("agentic.acp.agent_modes")
    local AgentModels = require("agentic.acp.agent_models")

    self = setmetatable({
        mode = nil,
        model = nil,
        thought_level = nil,
        legacy_agent_modes = AgentModes:new(),
        legacy_agent_models = AgentModels:new(),
        _pending_model_select = false,
        _pending_initial_model = nil,
        _set_model_callback = set_model_callback,
    }, self)

    for _, bufnr in pairs(buffers) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.change_mode,
            bufnr,
            function()
                self:show_mode_selector(set_mode_callback)
            end,
            { desc = "Agentic: Select Agent Mode" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_model,
            bufnr,
            function()
                self:show_model_selector(set_model_callback)
            end,
            { desc = "Agentic: Select Model" }
        )
    end

    return self
end

function AgentConfigOptions:clear()
    self.mode = nil
    self.model = nil
    self.thought_level = nil
    self._pending_model_select = false
    self._pending_initial_model = nil
    self.legacy_agent_modes:clear()
    self.legacy_agent_models:clear()
end

--- @param configOptions agentic.acp.ConfigOption[]|nil
function AgentConfigOptions:set_options(configOptions)
    local was_pending = self._pending_model_select
    local pending_initial = self._pending_initial_model
    self:clear()

    if not configOptions then
        self._pending_initial_model = pending_initial
        return
    end

    for _i, option in ipairs(configOptions) do
        if option.category == "mode" then
            self.mode = option
        elseif option.category == "model" then
            self.model = option
        elseif option.category == "thought_level" then
            self.thought_level = option
        else
            Logger.debug("Unknown config option", option)
        end
    end

    if was_pending then
        self:_flush_pending_model_select()
    end

    if pending_initial then
        self._pending_initial_model = pending_initial
        self:_flush_pending_initial_model()
    end
end

--- Modes from providers that don't support the new Config Options
--- @param modes_info agentic.acp.ModesInfo
function AgentConfigOptions:set_legacy_modes(modes_info)
    self.legacy_agent_modes:set_modes(modes_info)
end

--- Models from providers that don't support the new Config Options
--- @param models_info agentic.acp.ModelsInfo
function AgentConfigOptions:set_legacy_models(models_info)
    self.legacy_agent_models:set_models(models_info)

    if self._pending_model_select then
        self:_flush_pending_model_select()
    end

    if self._pending_initial_model then
        self:_flush_pending_initial_model()
    end
end

--- Queue a model id to apply once configOptions (or legacy models) become
--- available. Used by session restore to reapply the saved model.
--- @param model_id string
function AgentConfigOptions:set_pending_initial_model(model_id)
    self._pending_initial_model = model_id
    if
        self:get_model(model_id) or self.legacy_agent_models:get_model(model_id)
    then
        self:_flush_pending_initial_model()
    end
end

--- Apply a queued initial model if it's now available.
function AgentConfigOptions:_flush_pending_initial_model()
    local model_id = self._pending_initial_model
    if not model_id then
        return
    end

    local current = (self.model and self.model.currentValue)
        or self.legacy_agent_models.current_model_id

    if current == model_id then
        self._pending_initial_model = nil
        return
    end

    local is_legacy
    if self:get_model(model_id) then
        is_legacy = false
    elseif self.legacy_agent_models:get_model(model_id) then
        is_legacy = true
    else
        return
    end

    self._pending_initial_model = nil
    self._set_model_callback(model_id, is_legacy)
end

--- @param target_mode string|nil
--- @param handle_mode_change fun(mode: string, is_legacy: boolean|nil): any
function AgentConfigOptions:set_initial_mode(target_mode, handle_mode_change)
    if not target_mode or target_mode == "" then
        Logger.debug("not setting initial mode", target_mode)
        return
    end

    local is_legacy = false
    local can_switch = false

    if self:get_mode(target_mode) ~= nil then
        can_switch = target_mode ~= self.mode.currentValue
        Logger.debug("Setting initial config mode", target_mode, can_switch)
    elseif self.legacy_agent_modes:get_mode(target_mode) ~= nil then
        is_legacy = true
        can_switch = target_mode ~= self.legacy_agent_modes.current_mode_id
        Logger.debug("Setting initial legacy mode", target_mode, can_switch)
    end

    if can_switch then
        handle_mode_change(target_mode, is_legacy)
    else
        local current = self.mode and self.mode.currentValue
            or self.legacy_agent_modes.current_mode_id
            or "unknown"
        Logger.notify(
            string.format(
                "Configured default_mode ‘%s’ not available. "
                    .. "Using provider’s default ‘%s’",
                target_mode,
                current
            ),
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end
end

--- @param target agentic.acp.ConfigOption|nil
--- @param value string
--- @return agentic.acp.ConfigOption.Option|nil
local function getter(target, value)
    if not target or not target.options or #target.options == 0 then
        return nil
    end

    for _, option in ipairs(target.options) do
        if option.value == value then
            return option
        end
    end

    return nil
end

--- @param mode_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_mode(mode_value)
    return getter(self.mode, mode_value)
end

--- @param mode_value string
--- @return string|nil mode_name
function AgentConfigOptions:get_mode_name(mode_value)
    local mode = self:get_mode(mode_value)

    if mode then
        return mode.name
    end

    local legacy_mode = self.legacy_agent_modes:get_mode(mode_value)

    if legacy_mode then
        return legacy_mode.name
    end

    return nil
end

--- @param model_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_model(model_value)
    return getter(self.model, model_value)
end

--- @param model_value string
--- @return string|nil model_name
function AgentConfigOptions:get_model_name(model_value)
    local model = self:get_model(model_value)

    if model then
        return model.name
    end

    local legacy_model = self.legacy_agent_models:get_model(model_value)

    if legacy_model then
        return legacy_model.name
    end

    return nil
end

--- @param handle_mode_change fun(mode: string, is_legacy: boolean): any
--- @return boolean shown
function AgentConfigOptions:show_mode_selector(handle_mode_change)
    local shown = self:_show_selector(
        self.mode,
        "Select agent mode config:",
        handle_mode_change
    )

    if shown then
        return true
    end

    local legacy_shown = self.legacy_agent_modes:show_mode_selector(
        function(mode)
            handle_mode_change(mode, true)
        end
    )

    if not legacy_shown then
        Logger.notify(
            "This provider does not support mode switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return legacy_shown
end

--- @param handle_model_change fun(model_id: string, is_legacy: boolean): any
--- @return boolean shown
function AgentConfigOptions:show_model_selector(handle_model_change)
    local shown = self:_show_selector(
        self.model,
        "Select model to change:",
        handle_model_change
    )

    if shown then
        return true
    end

    local legacy_shown = self.legacy_agent_models:show_model_selector(
        function(model_id)
            handle_model_change(model_id, true)
        end
    )

    if legacy_shown then
        return true
    end

    -- No models available yet — queue for when the session delivers them
    self._pending_model_select = true
    Logger.notify(
        "Waiting for session to start...",
        vim.log.levels.INFO,
        { title = "Agentic" }
    )
    return false
end

--- Show the model selector if it was requested before models were available
function AgentConfigOptions:_flush_pending_model_select()
    self._pending_model_select = false
    vim.schedule(function()
        self:show_model_selector(self._set_model_callback)
    end)
end

--- @param target agentic.acp.ConfigOption|nil
--- @param prompt string
--- @param handle_change fun(mode: string, is_legacy: boolean): any
--- @return boolean shown
function AgentConfigOptions:_show_selector(target, prompt, handle_change)
    if not target or not target.options or #target.options == 0 then
        return false
    end

    vim.ui.select(target.options, {
        prompt = prompt,
        format_item = function(item)
            --- @cast item agentic.acp.ConfigOption.Option -- need to cast because `select` has a Generic, but not for `format_item`
            local prefix = item.value == target.currentValue and "● " or "  "

            if item.description and item.description ~= "" then
                return string.format(
                    "%s%s: %s",
                    prefix,
                    item.name,
                    item.description
                )
            end
            return prefix .. item.name
        end,
    }, function(selected_mode)
        if selected_mode and selected_mode.value ~= target.currentValue then
            handle_change(selected_mode.value, false)
        end
    end)

    return true
end

return AgentConfigOptions
