--- A line below the end of a buffer naming the plugin's own step in progress
--- (starting, loading or forking a session): a `virt_lines` extmark on the
--- last line. Writes that append lines leave it behind until `reposition`.

local NS_STEP_LINE = vim.api.nvim_create_namespace("agentic_step_line")

--- @class agentic.ui.StepLine
--- @field _bufnr integer
--- @field _text? string The step shown, nil when none
--- @field _extmark_id? integer
local StepLine = {}
StepLine.__index = StepLine

--- @param bufnr integer
--- @return agentic.ui.StepLine
function StepLine:new(bufnr)
    return setmetatable({ _bufnr = bufnr }, self)
end

--- Show `text` below the last line, replacing any step shown.
--- @param text string
function StepLine:show(text)
    self._text = text
    self:reposition()
end

--- Remove the shown step. A no-op with no step shown.
function StepLine:clear()
    self._text = nil
    if self._extmark_id then
        -- The mark may already be gone with its buffer or namespace.
        pcall(
            vim.api.nvim_buf_del_extmark,
            self._bufnr,
            NS_STEP_LINE,
            self._extmark_id
        )
        self._extmark_id = nil
    end
end

--- Move the shown step below the current last line. A no-op with no step
--- shown.
function StepLine:reposition()
    if not self._text or not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end
    local last_row = vim.api.nvim_buf_line_count(self._bufnr) - 1
    self._extmark_id =
        vim.api.nvim_buf_set_extmark(self._bufnr, NS_STEP_LINE, last_row, 0, {
            id = self._extmark_id,
            virt_lines = { { { " " .. self._text, "NonText" } } },
        })
end

return StepLine
