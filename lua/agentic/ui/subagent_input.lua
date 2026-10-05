local BufHelpers = require("agentic.utils.buf_helpers")
local PromptInput = require("agentic.ui.prompt_input")
local WindowDecoration = require("agentic.ui.window_decoration")

--- Callbacks of a message input.
--- @class agentic.ui.SubagentInput.Handlers
--- @field on_submit fun(text: string, opts: agentic.ui.PromptInput.SubmitOpts): boolean Send the text to the subagent. False keeps it in the buffer
--- @field setup_buf fun(bufnr: integer) Called after the input binds its own maps, on creation and on each reload of the buffer
--- @field on_wipeout fun() Called once when the buffer is wiped other than by `destroy`

--- A message input for one subagent: an unlisted buffer whose submitted text
--- goes to that subagent.
--- @class agentic.ui.SubagentInput
--- @field bufnr integer
--- @field _destroyed boolean
local SubagentInput = {}
SubagentInput.__index = SubagentInput

--- An input buffer, shown in no window.
--- @param name string Tail of the buffer name
--- @param label string Display name of the subagent
--- @param widget agentic.ui.ChatWidget Sets the buffer up as its `message` panel
--- @param handlers agentic.ui.SubagentInput.Handlers
--- @return agentic.ui.SubagentInput
function SubagentInput:new(name, label, widget, handlers)
    local bufnr = vim.api.nvim_create_buf(false, true)
    self = setmetatable({ bufnr = bufnr, _destroyed = false }, self)

    -- What a load provides and an unload by `:bd` resets.
    local function setup()
        widget:setup_panel_buf(bufnr, "message")
        WindowDecoration.set_header(
            bufnr,
            { title = "󰦨 Message to " .. label }
        )
        PromptInput.bind_submit(bufnr, function(opts)
            vim.cmd("stopinsert")
            local text = self:text()
            if handlers.on_submit(text, opts) then
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
            end
            BufHelpers.sync_modified(bufnr)
        end)
        handlers.setup_buf(bufnr)
    end

    setup()
    BufHelpers.rename(bufnr, WindowDecoration.buffer_name(bufnr, name))

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = bufnr,
        callback = function()
            BufHelpers.sync_modified(bufnr)
        end,
    })
    vim.api.nvim_create_autocmd("BufReadCmd", {
        buffer = bufnr,
        callback = function()
            if not self._destroyed then
                setup()
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        callback = function()
            if not self._destroyed then
                self._destroyed = true
                handlers.on_wipeout()
            end
        end,
    })

    return self
end

--- The buffer's text, lines joined by newlines.
--- @return string
function SubagentInput:text()
    return table.concat(
        vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false),
        "\n"
    )
end

--- Wipe the buffer, closing its windows. The handlers are not called after
--- this.
function SubagentInput:destroy()
    self._destroyed = true
    if vim.api.nvim_buf_is_valid(self.bufnr) then
        vim.api.nvim_buf_delete(self.bufnr, { force = true })
    end
end

return SubagentInput
