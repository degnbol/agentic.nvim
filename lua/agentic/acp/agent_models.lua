--- Manages agent models for ACP sessions
--- Provides model selection via vim.ui.select

--- @class agentic.acp.AgentModels
--- @field _models agentic.acp.Model[]
--- @field current_model_id? string
local AgentModels = {}
AgentModels.__index = AgentModels

--- @return agentic.acp.AgentModels
function AgentModels:new()
    local instance = setmetatable({
        _models = {},
        current_model_id = nil,
    }, self)

    return instance
end

--- Replace all models with new list
--- @param models_info agentic.acp.ModelsInfo
function AgentModels:set_models(models_info)
    self._models = models_info.availableModels
    self.current_model_id = models_info.currentModelId
end

--- @param model_id string
--- @return agentic.acp.Model|nil
function AgentModels:get_model(model_id)
    for _, model in ipairs(self._models) do
        if model.modelId == model_id then
            return model
        end
    end
    return nil
end

--- @param set_model_callback fun(model_id: string)
--- @return boolean shown
function AgentModels:show_model_selector(set_model_callback)
    if #self._models == 0 then
        return false
    end

    vim.ui.select(self._models, {
        prompt = "Select Model:",
        format_item = function(item)
            --- @cast item agentic.acp.Model
            local prefix = item.modelId == self.current_model_id and "● "
                or "  "
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
    }, function(selected_model)
        if
            selected_model
            and selected_model.modelId ~= self.current_model_id
        then
            set_model_callback(selected_model.modelId)
        end
    end)

    return true
end

--- Reset all models and current selection
function AgentModels:clear()
    self._models = {}
    self.current_model_id = nil
end

return AgentModels
