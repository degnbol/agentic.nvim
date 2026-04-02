--- Fallback session picker using quickfix window (no external deps).
--- Keymaps: <CR> restore, dd delete, u undo delete, <Tab> toggle scope, q close.
--- Deletions are deferred — files are removed from disk only when the picker closes.
local ChatHistory = require("agentic.ui.chat_history")
local Logger = require("agentic.utils.logger")
local SessionRestore = require("agentic.session_restore")

--- @class agentic.SessionRestoreBuiltin
local M = {}

--- @class agentic.SessionRestoreBuiltin.Opts
--- @field scope agentic.SessionRestore.Scope
--- @field tab_page_id integer
--- @field current_session agentic.SessionManager|nil

--- @class agentic.SessionRestoreBuiltin.DeleteEntry
--- @field index integer Original index in items list at time of deletion
--- @field item agentic.SessionRestore.PickerItem

--- Populate the quickfix list with session items.
--- @param items agentic.SessionRestore.PickerItem[]
--- @param scope agentic.SessionRestore.Scope
local function set_qf_items(items, scope)
    local scope_label = scope == "all" and "all projects" or "this project"
    local qf_items = {}
    for _, item in ipairs(items) do
        table.insert(qf_items, { text = item.display })
    end
    --- vim.fn.setqflist: no API equivalent; quickfixtextfunc must be a funcref
    vim.fn.setqflist({}, " ", {
        title = string.format(
            "Sessions (%s) │ <CR>:restore  dd:delete  u:undo  <Tab>:scope  q:close",
            scope_label
        ),
        items = qf_items,
        quickfixtextfunc = function(info)
            --- vim.fn.getqflist: no API equivalent for fetching qf items by id
            local qf = vim.fn.getqflist({ id = info.id, items = 1 }).items
            local lines = {}
            for i = info.start_idx, info.end_idx do
                lines[#lines + 1] = qf[i] and qf[i].text or ""
            end
            return lines
        end,
    })
end

--- Commit pending deletions to disk.
--- @param pending agentic.SessionRestoreBuiltin.DeleteEntry[]
--- @return integer deleted
--- @return integer failed
local function commit_deletes(pending)
    if #pending == 0 then
        return 0, 0
    end
    local deleted, failed = 0, 0
    for _, entry in ipairs(pending) do
        local fp = entry.item.file_path
            or ChatHistory.get_file_path(entry.item.session_id)
        if os.remove(fp) then
            deleted = deleted + 1
        else
            failed = failed + 1
        end
    end
    return deleted, failed
end

--- @param items agentic.SessionRestore.PickerItem[]
--- @param on_select fun(item: agentic.SessionRestore.PickerItem)
--- @param opts agentic.SessionRestoreBuiltin.Opts
function M.show(items, on_select, opts) -- luacheck: ignore
    local scope = opts.scope or "local"
    --- @type agentic.SessionRestoreBuiltin.DeleteEntry[]
    local pending_deletes = {}
    local committed = false

    local function commit_and_notify()
        if committed then
            return
        end
        committed = true
        local deleted, failed = commit_deletes(pending_deletes)
        if deleted > 0 then
            local msg = deleted == 1 and "Deleted 1 session"
                or string.format("Deleted %d sessions", deleted)
            if failed > 0 then
                msg = msg .. string.format(" (%d failed)", failed)
            end
            Logger.notify(msg, vim.log.levels.INFO)
        elseif failed > 0 then
            Logger.notify("Failed to delete sessions", vim.log.levels.WARN)
        end
    end

    local function setup_qf_win()
        local win = vim.api.nvim_get_current_win()
        vim.api.nvim_set_option_value(
            "winhighlight",
            "QuickFixLine:",
            { win = win }
        )
        vim.api.nvim_set_option_value("signcolumn", "no", { win = win })
        vim.api.nvim_set_option_value("conceallevel", 0, { win = win })
        vim.api.nvim_set_option_value("statuscolumn", "", { win = win })
        vim.api.nvim_set_option_value("number", false, { win = win })
        vim.api.nvim_set_option_value("relativenumber", false, { win = win })
        vim.api.nvim_set_option_value("wrap", false, { win = win })
    end

    local function open_qf()
        set_qf_items(items, scope)
        -- Suppress FileType qf so quicker.nvim (and other qf plugins) don't fire
        local ei = vim.o.eventignore
        vim.o.eventignore = "FileType"
        vim.cmd("botright copen")
        vim.o.eventignore = ei
        setup_qf_win()
    end

    open_qf()

    local qf_buf = vim.api.nvim_get_current_buf()
    local map_opts = { buffer = qf_buf, nowait = true, silent = true }

    local function apply_syntax()
        vim.cmd("syntax clear")
        vim.cmd(
            [[syntax match AgenticPickerDate "^\d\{4}-\d\{2}-\d\{2} \d\{2}:\d\{2}"]]
        )
        vim.cmd([[syntax match AgenticPickerDelim "│"]])
    end
    apply_syntax()
    local augroup =
        vim.api.nvim_create_augroup("agentic_session_picker", { clear = true })
    vim.api.nvim_create_autocmd("Syntax", {
        group = augroup,
        buffer = qf_buf,
        callback = apply_syntax,
    })

    -- Commit deletions when the qf buffer is closed by any means (:q, :cclose, q)
    vim.api.nvim_create_autocmd("BufUnload", {
        group = augroup,
        buffer = qf_buf,
        once = true,
        callback = function()
            vim.schedule(commit_and_notify)
        end,
    })

    --- Remove items at indices [from, to] (1-based, inclusive) from the list.
    --- @param from integer
    --- @param to integer
    local function delete_range(from, to)
        local count = 0
        for i = to, from, -1 do
            local item = items[i]
            if item then
                table.insert(pending_deletes, { index = i, item = item })
                table.remove(items, i)
                count = count + 1
            end
        end
        if count > 0 then
            open_qf()
            local new_idx = math.min(from, #items)
            if new_idx > 0 then
                vim.api.nvim_win_set_cursor(0, { new_idx, 0 })
            end
        end
    end

    vim.keymap.set("n", "u", function()
        if #pending_deletes == 0 then
            return
        end
        local entry = table.remove(pending_deletes)
        local idx = math.min(entry.index, #items + 1)
        table.insert(items, idx, entry.item)
        open_qf()
        vim.api.nvim_win_set_cursor(0, { idx, 0 })
    end, map_opts)

    vim.keymap.set("n", "<CR>", function()
        local idx = vim.api.nvim_win_get_cursor(0)[1]
        local item = items[idx]
        if item then
            commit_and_notify()
            vim.cmd("cclose")
            on_select(item)
        end
    end, map_opts)

    vim.keymap.set("n", "dd", function()
        local idx = vim.api.nvim_win_get_cursor(0)[1]
        delete_range(idx, idx)
    end, map_opts)

    --- vim.fn.line: no API equivalent for "v" mark
    vim.keymap.set("x", "d", function()
        local from = vim.fn.line("v")
        local to = vim.fn.line(".")
        if from > to then
            from, to = to, from
        end
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
            "nx",
            false
        )
        delete_range(from, to)
    end, map_opts)

    vim.keymap.set("n", "<Tab>", function()
        commit_and_notify()
        vim.cmd("cclose")
        local new_scope = scope == "all" and "local" or "all"
        SessionRestore.show_picker(
            opts.tab_page_id,
            opts.current_session,
            new_scope
        )
    end, map_opts)

    vim.keymap.set("n", "q", function()
        vim.cmd("cclose")
    end, map_opts)
end

return M
