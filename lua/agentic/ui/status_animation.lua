--- StatusAnimation module for displaying animated spinners in windows
---
--- This module provides utilities to render animated state indicators (spinners)
--- in buffers using extmarks and timers.
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

local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")

--- @class agentic.ui.StatusAnimation
--- @field _bufnr number Buffer number where animation is rendered
--- @field _state? agentic.Theme.SpinnerState Current animation state
--- @field _next_frame_handle? uv.uv_timer_t One-shot deferred function handle from vim.defer_fn
--- @field _spinner_idx number Current spinner frame index
--- @field _extmark_id? number Current extmark ID
local StatusAnimation = {}
StatusAnimation.__index = StatusAnimation

--- @param bufnr number
--- @return agentic.ui.StatusAnimation
function StatusAnimation:new(bufnr)
    local instance = setmetatable({
        _bufnr = bufnr,
        _state = nil,
        _next_frame_handle = nil,
        _spinner_idx = 1,
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
    self._spinner_idx = 1
    self:_render_frame()
end

function StatusAnimation:stop()
    self._state = nil

    if self._next_frame_handle then
        pcall(function()
            self._next_frame_handle:stop()
        end)
        pcall(function()
            self._next_frame_handle:close()
        end)
        self._next_frame_handle = nil
    end

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
    -- No timer — static text, no animation loop
end

return StatusAnimation
