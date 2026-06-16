--- Static status indicator rendered as a virtual-line extmark pinned to the
--- buffer bottom.
---
--- ## Usage
--- ```lua
--- local StatusAnimation = require("agentic.ui.status_animation")
--- local animator = StatusAnimation:new(bufnr)
--- animator:start("generating")
--- -- later...
--- animator:stop()
--- ```
---
--- ponytail: static text, no animation loop. Add a timer in _render_frame if
--- animated spinner frames are ever wanted.

local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")

--- @class agentic.ui.StatusAnimation
--- @field _bufnr number Buffer number where the indicator is rendered
--- @field _state? agentic.Theme.SpinnerState Current state label
--- @field _extmark_id? number Current extmark ID
local StatusAnimation = {}
StatusAnimation.__index = StatusAnimation

--- @param bufnr number
--- @return agentic.ui.StatusAnimation
function StatusAnimation:new(bufnr)
    local instance = setmetatable({
        _bufnr = bufnr,
        _state = nil,
        _extmark_id = nil,
    }, StatusAnimation)

    return instance
end

--- Start the animation with the given state.
--- If the state is unchanged, just repositions the extmark to the current
--- buffer bottom without a delete/recreate cycle (avoids visual flicker
--- during streaming when called on every chunk).
--- @param state agentic.Theme.SpinnerState
function StatusAnimation:start(state)
    if self._state == state and self._extmark_id then
        self:_render_frame()
        return
    end

    self:stop()

    self._state = state
    self:_render_frame()
end

function StatusAnimation:stop()
    self._state = nil

    if self._extmark_id then
        pcall(
            vim.api.nvim_buf_del_extmark,
            self._bufnr,
            NS_ANIMATION,
            self._extmark_id
        )
    end

    self._extmark_id = nil
end

--- Whether a status indicator is currently rendered.
--- @return boolean
function StatusAnimation:is_active()
    return self._state ~= nil and self._extmark_id ~= nil
end

--- Move the extmark to the current buffer bottom without changing state.
--- No-op if no animation is active. Call after any buffer modification that
--- appends lines (tool call blocks, separators, etc.) to keep the status
--- indicator pinned to the bottom.
function StatusAnimation:reposition()
    if self._state and self._extmark_id then
        self:_render_frame()
    end
end

function StatusAnimation:_render_frame()
    if not self._state or not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end

    local line_num = math.max(0, vim.api.nvim_buf_line_count(self._bufnr) - 1)

    self._extmark_id =
        vim.api.nvim_buf_set_extmark(self._bufnr, NS_ANIMATION, line_num, 0, {
            id = self._extmark_id,
            virt_lines = { { { " " .. self._state, "NonText" } } },
            virt_lines_above = false,
        })
end

return StatusAnimation
