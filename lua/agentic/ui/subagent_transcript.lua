local BufHelpers = require("agentic.utils.buf_helpers")
local ChatBuffer = require("agentic.ui.chat_buffer")
local Glyphs = require("agentic.glyphs")
local MessageWriter = require("agentic.ui.message_writer")
local ResponseBoundary = require("agentic.acp.response_boundary")
local StatusIndicator = require("agentic.ui.status_indicator")
local ToolCallRenderer = require("agentic.ui.tool_call_renderer")
local WindowDecoration = require("agentic.ui.window_decoration")

--- What the owning session does for a transcript's buffer.
--- @class agentic.ui.SubagentTranscript.Handlers
--- @field setup_buf fun(bufnr: integer, writer: agentic.ui.MessageWriter) Bind the session's own maps
--- @field on_reload fun() Render the buffer again after `:e`, starting with `restart`
--- @field on_write fun() Write the buffer on `:w`
--- @field on_wipeout fun() The buffer is gone, wiped by the user

--- One subagent's transcript: a listed, chat-style buffer with its own writer,
--- working indicator and response boundary.
--- @class agentic.ui.SubagentTranscript
--- @field bufnr integer
--- @field writer agentic.ui.MessageWriter
--- @field status_indicator agentic.ui.StatusIndicator
--- @field response_boundary agentic.acp.ResponseBoundary
--- @field _destroyed boolean
local SubagentTranscript = {}
SubagentTranscript.__index = SubagentTranscript

--- The buffer-name tail of a transcript: the label with every character
--- outside 'isfname' replaced by `-`, so `<cfile>` takes the whole name, then
--- the agent id's last 8 characters, then `-g<N>` for a generation N ≥ 2.
--- @param agent_id string
--- @param generation integer
--- @param label string
--- @return string
local function name_tail(agent_id, generation, label)
    local tail = vim.fn.substitute(label, [[\%(\f\)\@!.]], "-", "g")
        .. "-"
        .. agent_id:sub(-8)
    if generation >= 2 then
        tail = tail .. "-g" .. generation
    end
    return tail
end

--- A transcript buffer named after the subagent, holding its heading.
--- @param agent_id string Id addressing the subagent
--- @param generation integer Which run of the subagent this is, from 1
--- @param subagent agentic.ui.MessageWriter.SubagentInfo|nil Nil for output saved without a block, headed `Agent`
--- @param widget agentic.ui.ChatWidget
--- @param handlers agentic.ui.SubagentTranscript.Handlers
--- @return agentic.ui.SubagentTranscript
function SubagentTranscript:new(agent_id, generation, subagent, widget, handlers)
    local bufnr = vim.api.nvim_create_buf(true, true)
    widget:setup_panel_buf(bufnr, "subagent")
    -- After the b-vars: its BufWinEnter reads the panel.
    ChatBuffer.setup(bufnr)
    local name = WindowDecoration.buffer_name(
        bufnr,
        name_tail(agent_id, generation, subagent and subagent.label or "Agent")
    )
    -- `:e` or `gf` on the name of a wiped transcript leaves a plain buffer
    -- holding it.
    local stray = vim.fn.bufnr("^" .. vim.fn.escape(name, "\\/.*$^~[]") .. "$")
    if stray ~= -1 and vim.b[stray].agentic_window ~= "subagent" then
        vim.api.nvim_buf_delete(stray, { force = true })
    end
    BufHelpers.rename(bufnr, name)

    local status_indicator = StatusIndicator:new(bufnr)
    local writer = MessageWriter:new(bufnr, status_indicator, function()
        return widget:panel_win("subagent")
    end)

    self = setmetatable({
        bufnr = bufnr,
        writer = writer,
        status_indicator = status_indicator,
        response_boundary = ResponseBoundary:new(),
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

    return self
end

--- Empty the transcript and open it again with its heading.
--- @param subagent agentic.ui.MessageWriter.SubagentInfo|nil
function SubagentTranscript:restart(subagent)
    self.writer:reset()
    ChatBuffer.start(self.bufnr)
    BufHelpers.with_modifiable(self.bufnr, function()
        vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, {})
    end)
    self.writer:write_subagent_heading(
        ToolCallRenderer.subagent_heading(subagent)
    )
end

--- Show the subagent's heading, and its state once it has one, in the header.
--- @param subagent agentic.ui.MessageWriter.SubagentInfo|nil
--- @param state string|nil
function SubagentTranscript:set_header(subagent, state)
    local header = WindowDecoration.get_header(self.bufnr)
    header.title = Glyphs.KIND.subagent
        .. " "
        .. ToolCallRenderer.subagent_heading(subagent)
    header.context = state
    WindowDecoration.set_header(self.bufnr, header)
end

--- Set 'modified', unless the buffer is unloaded or gone.
--- @param modified boolean
function SubagentTranscript:set_modified(modified)
    if
        vim.api.nvim_buf_is_valid(self.bufnr)
        and vim.api.nvim_buf_is_loaded(self.bufnr)
    then
        vim.bo[self.bufnr].modified = modified
    end
end

--- Unload the buffer, so it renders afresh, through `on_reload`, when next
--- loaded.
function SubagentTranscript:unload()
    vim.cmd.bunload({ args = { tostring(self.bufnr) }, bang = true })
end

--- Wipe the buffer. Its autocmds no longer reach the handlers.
function SubagentTranscript:destroy()
    self._destroyed = true
    self.status_indicator:stop()
    if vim.api.nvim_buf_is_valid(self.bufnr) then
        vim.api.nvim_buf_delete(self.bufnr, { force = true })
    end
end

return SubagentTranscript
