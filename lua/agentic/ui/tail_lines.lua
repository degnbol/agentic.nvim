--- Lines below the end of a buffer, in a `virt_lines` extmark on the last
--- line: prompts sent and not yet taken in, then the plugin's own step in
--- progress (starting, loading or forking a session). Writes that append lines
--- leave them behind until `reposition`.

local Theme = require("agentic.theme")

local NS_TAIL_LINES = vim.api.nvim_create_namespace("agentic_tail_lines")

--- Screen cells of the sign column (`signcolumn=yes:1`), which the lines
--- start in.
local SIGN_WIDTH = 2

--- A prompt sent and not yet taken in.
--- @class agentic.ui.TailLines.Prompt
--- @field sign string Its identity sign, as the prompt's row in the buffer will carry it
--- @field text string

--- @class agentic.ui.TailLines
--- @field _bufnr integer
--- @field _step? string The step shown, nil when none
--- @field _prompts agentic.ui.TailLines.Prompt[] The prompts shown, oldest first
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
--- @param prompts agentic.ui.TailLines.Prompt[] Oldest first
function TailLines:show_prompts(prompts)
    self._prompts = prompts
    self:reposition()
end

--- The virtual lines of what is shown, from the sign column on: each prompt
--- dimmed, its sign in the sign column, then the step.
--- @return [string, string][][] virt_lines
function TailLines:_virt_lines()
    local pad = string.rep(" ", SIGN_WIDTH)
    local lines = {}
    for _, prompt in ipairs(self._prompts) do
        local rows = vim.split(prompt.text, "\n", { plain = true })
        for i, row in ipairs(rows) do
            local sign = i == 1 and prompt.sign or pad
            table.insert(
                lines,
                { { sign .. row, Theme.HL_GROUPS.UNTAKEN_PROMPT } }
            )
        end
    end
    if self._step then
        table.insert(lines, { { pad .. " " .. self._step, "NonText" } })
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
            virt_lines_leftcol = true,
        })
end

return TailLines
