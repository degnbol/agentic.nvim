local BufHelpers = require("agentic.utils.buf_helpers")
local Columns = require("agentic.utils.columns")
local Logger = require("agentic.utils.logger")
local ToolCallLayout = require("agentic.ui.tool_call_layout")

--- The calls the panel's rows act through.
--- @class agentic.ui.AgentsPanel.Actions
--- @field buf_of fun(child_id: string): integer|nil A subagent's transcript, while valid
--- @field open fun(child_id: string) Show a subagent's transcript

--- A session's subagents, one row each: how its work stands, its mode, its
--- agent type, its transcript's name and its label.
--- @class agentic.ui.AgentsPanel
--- @field _get_buf fun(): integer|nil
--- @field _actions agentic.ui.AgentsPanel.Actions
--- @field _entries agentic.Subagents.Entry[] Last rendered entries, by row
local AgentsPanel = {}
AgentsPanel.__index = AgentsPanel

--- @param get_buf fun(): integer|nil The buffer to render to, nil while there is none
--- @param actions agentic.ui.AgentsPanel.Actions
--- @return agentic.ui.AgentsPanel
function AgentsPanel:new(get_buf, actions)
    return setmetatable({
        _get_buf = get_buf,
        _actions = actions,
        _entries = {},
    }, self)
end

--- The cells of an entry's row: state, mode, agent type, name and label.
--- The mode and type are empty while unknown, and the label is `Agent`
--- without one.
--- @param entry agentic.Subagents.Entry
--- @return string[] cells
local function cells(entry)
    local subagent = entry.subagent
    if not subagent then
        return { entry.state, "", "", entry.name, "Agent" }
    end
    return {
        entry.state,
        ToolCallLayout.subagent_mode_text(subagent),
        subagent.agent_type or "",
        entry.name,
        subagent.label or "Agent",
    }
end

--- One row per entry, in columns `<state>  <mode>  <type>  <name>  <label>`
--- padded to align. A column empty on every row is left out.
--- @param entries agentic.Subagents.Entry[]
--- @return string[] lines
function AgentsPanel.lines(entries)
    return Columns.align(vim.tbl_map(cells, entries), "  ")
end

--- Write the rows of `entries`. No-op while `get_buf` gives nil.
--- @param entries agentic.Subagents.Entry[]
function AgentsPanel:render(entries)
    self._entries = entries
    local bufnr = self._get_buf()
    if not bufnr then
        return
    end
    BufHelpers.with_modifiable(bufnr, function(buf)
        vim.api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            AgentsPanel.lines(entries)
        )
    end)
end

--- `:bdelete` the transcript of each row from `first` to `last` (1-based,
--- inclusive), except that of a subagent that works, which is kept and named
--- in a notification. Notifies a transcript that refuses the delete.
--- @param first integer
--- @param last integer
function AgentsPanel:delete_rows(first, last)
    --- @type string[]
    local working = {}
    for row = first, last do
        local entry = self._entries[row]
        local bufnr = entry and self._actions.buf_of(entry.child_id)
        if entry and entry.state == "working" then
            table.insert(
                working,
                ToolCallLayout.subagent_heading(entry.subagent)
            )
        elseif bufnr then
            local ok, err = pcall(vim.cmd.bdelete, tostring(bufnr))
            if not ok then
                Logger.notify(
                    "Cannot delete " .. entry.name .. ": " .. tostring(err),
                    vim.log.levels.ERROR,
                    { title = "Agentic" }
                )
            end
        end
    end
    if #working > 0 then
        Logger.notify(
            "Kept working subagents: " .. table.concat(working, ", "),
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end
end

--- Show the transcript of the subagent on `row` (1-based). No-op past the
--- last row.
--- @param row integer
function AgentsPanel:open_row(row)
    local entry = self._entries[row]
    if entry then
        self._actions.open(entry.child_id)
    end
end

--- 'operatorfunc' that runs `delete_rows` over the `'[` to `']` rows, on the
--- panel of the session owning the current buffer. 'operatorfunc' takes only
--- a named function, so the panel is found from the buffer.
function AgentsPanel.delete_operator()
    local SessionRegistry = require("agentic.session_registry")
    local owner = SessionRegistry.owner_of_buf(vim.api.nvim_get_current_buf())
    if owner then
        owner.agents_panel:delete_rows(
            vim.api.nvim_buf_get_mark(0, "[")[1],
            vim.api.nvim_buf_get_mark(0, "]")[1]
        )
    end
end

local OPERATORFUNC = "v:lua.require'agentic.ui.agents_panel'.delete_operator"

--- Bind in `bufnr`: `d` as an operator over rows (`dd`, `d{motion}`, visual
--- `d`) running `delete_rows`, and `gf` and `<CR>` to `open_row` the cursor's
--- row.
--- @param bufnr integer
function AgentsPanel:bind_keymaps(bufnr)
    for _, map in ipairs({
        { mode = { "n", "x" }, lhs = "d", keys = "g@" },
        { mode = "n", lhs = "dd", keys = "g@_" },
    }) do
        BufHelpers.keymap_set(bufnr, map.mode, map.lhs, function()
            vim.o.operatorfunc = OPERATORFUNC
            return map.keys
        end, {
            expr = true,
            desc = "Agentic: Delete subagent transcripts",
        })
    end
    for _, lhs in ipairs({ "gf", "<CR>" }) do
        BufHelpers.keymap_set(bufnr, "n", lhs, function()
            self:open_row(vim.api.nvim_win_get_cursor(0)[1])
        end, { desc = "Agentic: Open subagent transcript" })
    end
end

return AgentsPanel
