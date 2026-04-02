local ChatHistory = require("agentic.ui.chat_history")
local Logger = require("agentic.utils.logger")
local SessionRestore = require("agentic.session_restore")

--- @class agentic.SessionRestoreFzf
local M = {}

--- @class agentic.SessionRestoreFzf.Opts
--- @field scope agentic.SessionRestore.Scope
--- @field tab_page_id integer
--- @field current_session agentic.SessionManager|nil

--- Show the fzf-lua session picker with preview and scope toggle.
--- @param items agentic.SessionRestore.PickerItem[]
--- @param on_select fun(item: agentic.SessionRestore.PickerItem)
--- @param opts agentic.SessionRestoreFzf.Opts
--- @return boolean success
function M.show(items, on_select, opts)
    local fzf_ok, fzf = pcall(require, "fzf-lua")
    if not fzf_ok then
        return false
    end

    local scope = opts.scope or "local"

    -- Map display string -> item for lookup after selection.
    -- Rebuilt on reload via the content function.
    local display_to_item = {}

    --- @type table<string, string>
    local preview_cache = {}

    local function make_header()
        local scope_label = scope == "all" and "all projects" or "this project"
        return string.format(
            "ctrl-g: toggle scope (%s) │ ctrl-x: delete",
            scope_label
        )
    end

    --- Build display lines and lookup map from current items.
    local function build_content(fzf_cb)
        display_to_item = {}
        for _, item in ipairs(items) do
            display_to_item[item.display] = item
            fzf_cb(item.display)
        end
        fzf_cb()
    end

    --- Reload items after scope change or deletion.
    local function refresh_items()
        local show_cwd = scope == "all"
        local list_fn = scope == "all" and ChatHistory.list_all_sessions
            or ChatHistory.list_sessions

        -- list_sessions/list_all_sessions are synchronous under the hood
        list_fn(function(sessions)
            items =
                SessionRestore.build_items(sessions, { show_cwd = show_cwd })
        end)
        preview_cache = {}
    end

    local previewer = fzf.shell.stringify_data(function(selected)
        if type(selected) == "table" then
            selected = selected[1]
        end
        if type(selected) ~= "string" or selected == "" then
            return "No session selected"
        end

        local item = display_to_item[selected]
        if not item then
            return "Unknown session: " .. selected
        end

        if preview_cache[item.session_id] then
            return preview_cache[item.session_id]
        end

        local file_path = item.file_path
            or ChatHistory.get_file_path(item.session_id)
        -- vim.fn.readfile: no API equivalent
        local content = vim.fn.readfile(file_path)
        if #content == 0 then
            return "Empty session file"
        end
        local ok, parsed = pcall(vim.json.decode, table.concat(content, "\n"))
        if not ok or not parsed or not parsed.messages then
            return "Failed to parse session"
        end

        local lines = SessionRestore.format_preview(parsed.messages)
        local result = table.concat(lines, "\n")
        preview_cache[item.session_id] = result
        return result
    end, {}, "{}") --[[@as string]]

    fzf.fzf_exec(build_content, {
        prompt = "Sessions> ",
        fzf_opts = {
            ["--preview"] = previewer,
            ["--preview-window"] = "down:60%",
            ["--no-multi"] = "",
            ["--header"] = make_header(),
        },
        actions = {
            ["enter"] = function(selected)
                if not selected or #selected == 0 then
                    return
                end
                local item = display_to_item[selected[1]]
                if item then
                    on_select(item)
                end
            end,
            ["ctrl-g"] = {
                fn = function()
                    scope = scope == "all" and "local" or "all"
                    refresh_items()
                end,
                reload = true,
                noclose = true,
                header = make_header,
            },
            ["ctrl-x"] = {
                fn = function(selected)
                    if not selected or #selected == 0 then
                        return
                    end
                    local item = display_to_item[selected[1]]
                    if not item then
                        return
                    end
                    local file_path = item.file_path
                        or ChatHistory.get_file_path(item.session_id)
                    local ok, err = os.remove(file_path)
                    if ok then
                        for i, it in ipairs(items) do
                            if it.session_id == item.session_id then
                                table.remove(items, i)
                                break
                            end
                        end
                        preview_cache[item.session_id] = nil
                        Logger.notify("Deleted session", vim.log.levels.INFO)
                    else
                        Logger.notify(
                            "Failed to delete: " .. (err or "unknown"),
                            vim.log.levels.WARN
                        )
                    end
                end,
                reload = true,
                noclose = true,
            },
        },
    })

    return true
end

return M
