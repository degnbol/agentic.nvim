--- Dimmed lines below the end of a buffer, in a `virt_lines` extmark on the
--- last line: prompts sent and not yet taken in, then the plugin's own step
--- in progress (starting, loading or forking a session). Writes that append
--- lines leave them behind until `reposition`.

local NS_TAIL_LINES = vim.api.nvim_create_namespace("agentic_tail_lines")

--- @class agentic.ui.TailLines
--- @field _bufnr integer
--- @field _step? string The step shown, nil when none
--- @field _prompts string[] The prompts shown, oldest first
--- @field _extmark_id? integer
local TailLines = {}
TailLines.__index = TailLines

--- @param bufnr integer
--- @return agentic.ui.TailLines
function TailLines:new(bufnr)
    return setmetatable({ _bufnr = bufnr, _prompts = {} }, self)
end

--- Show `text` as the step, replacing any step shown.
--- @param text string
function TailLines:show_step(text)
    self._step = text
    self:reposition()
end

--- Remove the shown step. A no-op with no step shown.
function TailLines:clear_step()
    self._step = nil
    self:reposition()
end

--- Show `prompts`, replacing the prompts shown. Empty shows none.
--- @param prompts string[] Prompt texts, oldest first
function TailLines:show_prompts(prompts)
    self._prompts = prompts
    self:reposition()
end

--- The virtual lines of what is shown.
--- @return [string, string][][] virt_lines
function TailLines:_virt_lines()
    local lines = {}
    for _, prompt in ipairs(self._prompts) do
        for _, line in ipairs(vim.split(prompt, "\n", { plain = true })) do
            table.insert(lines, { { line, "NonText" } })
        end
    end
    if self._step then
        table.insert(lines, { { " " .. self._step, "NonText" } })
    end
    return lines
end

--- Move what is shown below the current last line, or remove the mark when
--- nothing is shown.
function TailLines:reposition()
    if not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end
    local virt_lines = self:_virt_lines()
    if #virt_lines == 0 then
        if self._extmark_id then
            vim.api.nvim_buf_del_extmark(
                self._bufnr,
                NS_TAIL_LINES,
                self._extmark_id
            )
            self._extmark_id = nil
        end
        return
    end
    local last_row = vim.api.nvim_buf_line_count(self._bufnr) - 1
    self._extmark_id =
        vim.api.nvim_buf_set_extmark(self._bufnr, NS_TAIL_LINES, last_row, 0, {
            id = self._extmark_id,
            virt_lines = virt_lines,
        })
end

return TailLines
