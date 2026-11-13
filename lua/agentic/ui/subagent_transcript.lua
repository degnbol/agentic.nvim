local AgentView = require("agentic.ui.agent_view")
local BufHelpers = require("agentic.utils.buf_helpers")
local ChatBuffer = require("agentic.ui.chat_buffer")
local Glyphs = require("agentic.glyphs")
local ToolCallLayout = require("agentic.ui.tool_call_layout")
local WindowDecoration = require("agentic.ui.window_decoration")

--- What the owning session does for a transcript's buffer.
--- @class agentic.ui.SubagentTranscript.Handlers
--- @field setup_buf fun(bufnr: integer, writer: agentic.ui.MessageWriter) Bind the session's own maps
--- @field on_reload fun() Render the buffer again after `:e`, starting with `restart`
--- @field on_write fun() Write the buffer on `:w`
--- @field on_wipeout fun() The buffer is gone, wiped by the user
--- @field on_listed_change? fun() The buffer was made, listed or unlisted, called on the next tick: during `BufDelete` it is still listed

--- One subagent's transcript: a listed, chat-style buffer with its own view.
--- @class agentic.ui.SubagentTranscript
--- @field bufnr integer
--- @field view agentic.ui.AgentView
--- @field _destroyed boolean
local SubagentTranscript = {}
SubagentTranscript.__index = SubagentTranscript

--- A transcript buffer holding the subagent's heading.
--- @param name string The buffer name, taken with `BufHelpers.claim_name`
--- @param subagent agentic.ui.MessageWriter.SubagentInfo|nil Nil for output saved without a block, headed `Agent`
--- @param widget agentic.ui.ChatWidget
--- @param handlers agentic.ui.SubagentTranscript.Handlers
--- @param run_clocks agentic.ui.RunClocks|nil nil shows no run times
--- @return agentic.ui.SubagentTranscript
function SubagentTranscript:new(name, subagent, widget, handlers, run_clocks)
    local bufnr = vim.api.nvim_create_buf(true, true)
    widget:setup_panel_buf(bufnr, "subagent")
    -- After the b-vars: its BufWinEnter reads the panel.
    ChatBuffer.setup(bufnr)
    BufHelpers.claim_name(bufnr, name)

    local view = AgentView:new(bufnr, run_clocks)
    local writer = view.writer

    self = setmetatable({
        bufnr = bufnr,
        view = view,
        _destroyed = false,
    }, self)

    handlers.setup_buf(bufnr, writer)
    self:restart(subagent)
    self:set_header(subagent)

    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = bufnr,
        callback = function()
            WindowDecoration.render_header(bufnr)
        end,
    })
    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = function()
            if not self._destroyed then
                handlers.on_write()
            end
        end,
    })
    vim.api.nvim_create_autocmd("BufReadCmd", {
        buffer = bufnr,
        callback = function()
            if self._destroyed then
                return
            end
            widget:setup_panel_buf(bufnr, "subagent")
            handlers.setup_buf(bufnr, writer)
            handlers.on_reload()
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
    local on_listed_change = handlers.on_listed_change
    if on_listed_change then
        -- The buffer was made listed.
        vim.schedule(function()
            if not self._destroyed then
                on_listed_change()
            end
        end)
        -- A wipe of a listed buffer fires `BufDelete` too.
        vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete" }, {
            buffer = bufnr,
            callback = function()
                if not self._destroyed then
                    vim.schedule(on_listed_change)
                end
            end,
        })
    end

    return self
end

--- Empty the transcript and open it again with its heading.
--- @param subagent agentic.ui.MessageWriter.SubagentInfo|nil
function SubagentTranscript:restart(subagent)
    self.view:restart()
    BufHelpers.with_modifiable(self.bufnr, function()
        vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, {})
    end)
    self.view.writer:write_subagent_heading(
        ToolCallLayout.subagent_heading(subagent)
    )
end

--- Whether the buffer is loaded.
--- @return boolean
function SubagentTranscript:is_loaded()
    return vim.api.nvim_buf_is_valid(self.bufnr)
        and vim.api.nvim_buf_is_loaded(self.bufnr)
end

--- Show the subagent's heading in the header, after its session's id. A
--- no-op while the buffer is unloaded: it has no b-vars, so no header, and
--- its next load writes it whole.
--- @param subagent agentic.ui.MessageWriter.SubagentInfo|nil
function SubagentTranscript:set_header(subagent)
    if not self:is_loaded() then
        return
    end
    local header = WindowDecoration.get_header(self.bufnr)
    header.icon = Glyphs.AGENT
    header.title = "#"
        .. vim.b[self.bufnr].agentic_session_id
        .. " › "
        .. ToolCallLayout.subagent_heading(subagent)
    WindowDecoration.set_header(self.bufnr, header)
end

--- Show in the header whether the subagent works. A no-op while the buffer
--- is unloaded.
--- @param running boolean
function SubagentTranscript:set_running(running)
    if self:is_loaded() then
        WindowDecoration.set_header_fact(self.bufnr, "running", running)
    end
end

--- Set the header's context text, or clear it with nil. A no-op while the
--- buffer is unloaded.
--- @param context string|nil
function SubagentTranscript:set_context(context)
    if not self:is_loaded() then
        return
    end
    local header = WindowDecoration.get_header(self.bufnr)
    header.context = context
    WindowDecoration.set_header(self.bufnr, header)
end

--- Set 'modified', unless the buffer is unloaded or gone.
--- @param modified boolean
function SubagentTranscript:set_modified(modified)
    if self:is_loaded() then
        vim.bo[self.bufnr].modified = modified
    end
end

--- Unload the buffer, so it renders afresh, through `on_reload`, when next
--- loaded.
function SubagentTranscript:unload()
    vim.cmd.bunload({ args = { tostring(self.bufnr) }, bang = true })
end

--- Wipe the buffer, unless it is already destroyed or being wiped. Its
--- autocmds no longer reach the handlers.
function SubagentTranscript:destroy()
    local was_destroyed = self._destroyed
    self._destroyed = true
    -- A buffer stays valid during its BufWipeout, and deleting it then is E937.
    if not was_destroyed and vim.api.nvim_buf_is_valid(self.bufnr) then
        vim.api.nvim_buf_delete(self.bufnr, { force = true })
    end
end

return SubagentTranscript
