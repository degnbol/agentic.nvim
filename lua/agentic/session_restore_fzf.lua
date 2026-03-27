local ChatHistory = require("agentic.ui.chat_history")
local SessionRestore = require("agentic.session_restore")

--- @class agentic.SessionRestoreFzf
local M = {}

--- Show the fzf-lua session picker with preview.
--- @param items agentic.SessionRestore.PickerItem[]
--- @param on_select fun(session_id: string)
--- @return boolean success
function M.show(items, on_select)
    local fzf_ok, fzf = pcall(require, "fzf-lua")
    if not fzf_ok then
        return false
    end

    -- Map display string -> item for lookup after selection
    local display_to_item = {}
    local display_lines = {}
    for _, item in ipairs(items) do
        display_to_item[item.display] = item
        table.insert(display_lines, item.display)
    end

    --- @type table<string, string>
    local preview_cache = {}

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

        local file_path = ChatHistory.get_file_path(item.session_id)
        local content = vim.fn.readfile(file_path)
        if #content == 0 then
            return "Empty session file"
        end
        local ok, parsed =
            pcall(vim.json.decode, table.concat(content, "\n"))
        if not ok or not parsed or not parsed.messages then
            return "Failed to parse session"
        end

        local lines = SessionRestore.format_preview(parsed.messages)
        local result = table.concat(lines, "\n")
        preview_cache[item.session_id] = result
        return result
    end, {}, "{}") --[[@as string]]

    fzf.fzf_exec(display_lines, {
        prompt = "Sessions> ",
        fzf_opts = {
            ["--preview"] = previewer,
            ["--preview-window"] = "down:60%",
            ["--no-multi"] = "",
        },
        actions = {
            ["enter"] = function(selected)
                if not selected or #selected == 0 then
                    return
                end
                local item = display_to_item[selected[1]]
                if item then
                    on_select(item.session_id)
                end
            end,
        },
    })

    return true
end

return M
