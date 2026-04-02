local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")

--- @class agentic.SessionRestore.PickerItem
--- @field display string
--- @field session_id string
--- @field timestamp integer
--- @field last_activity? integer
--- @field cwd? string
--- @field file_path? string Full path to session JSON (for cross-project access)

--- @class agentic.SessionRestore
local SessionRestore = {}

--- Checks if the current session has messages or we can safely restore into it if it's empty
--- @param current_session agentic.SessionManager|nil
--- @return boolean has_conflict
local function check_conflict(current_session)
    return current_session ~= nil
        and current_session.session_id ~= nil
        and current_session.chat_history ~= nil
        and #current_session.chat_history.messages > 0
end

--- Check whether the agent supports the session/load RPC.
--- @param session agentic.SessionManager
--- @return boolean
local function agent_supports_load(session)
    return session.agent ~= nil
        and session.agent.agent_capabilities ~= nil
        and session.agent.agent_capabilities.loadSession == true
end

--- @param session_id string
--- @param tab_page_id integer
--- @param has_conflict boolean
--- @param cwd? string Original cwd for cross-project restore
--- @param file_path? string Full path to session JSON (cross-project)
local function do_restore(session_id, tab_page_id, has_conflict, cwd, file_path)
    SessionRegistry.get_session_for_tab_page(tab_page_id, function(session)
        if agent_supports_load(session) then
            session:load_acp_session(session_id, cwd)
        else
            if has_conflict and session.session_id then
                session.agent:cancel_session(session.session_id)
                session.widget:clear()
            end

            ChatHistory.load(session_id, function(history, err)
                if err or not history then
                    Logger.notify(
                        "Failed to load session: " .. (err or "unknown error"),
                        vim.log.levels.WARN
                    )
                    return
                end

                session:restore_from_history(
                    history,
                    { reuse_session = not has_conflict }
                )
            end, file_path)
        end

        session.widget:show()
        session.widget:close_empty_non_widget_windows()
    end)
end

--- Restore a session in a new tabpage.
--- @param session_id string
--- @param cwd? string
--- @param file_path? string
local function restore_in_new_tab(session_id, cwd, file_path)
    vim.cmd("tabnew")
    local new_tab = vim.api.nvim_get_current_tabpage()
    do_restore(session_id, new_tab, false, cwd, file_path)
end

--- @param session_id string
--- @param tab_page_id integer
--- @param has_conflict boolean
--- @param cwd? string Original cwd for cross-project restore
--- @param file_path? string Full path to session JSON (cross-project)
local function restore_with_conflict_check(
    session_id,
    tab_page_id,
    has_conflict,
    cwd,
    file_path
)
    if has_conflict then
        vim.ui.select({
            "Restore here (replace current)",
            "Open in new tab",
        }, {
            prompt = "Current session has messages:",
        }, function(choice)
            if choice == "Restore here (replace current)" then
                do_restore(
                    session_id,
                    tab_page_id,
                    has_conflict,
                    cwd,
                    file_path
                )
            elseif choice == "Open in new tab" then
                restore_in_new_tab(session_id, cwd, file_path)
            end
        end)
    else
        do_restore(session_id, tab_page_id, has_conflict, cwd, file_path)
    end
end

--- Shorten a cwd path for display (collapse home dir, keep last 2 components).
--- @param cwd string
--- @return string
local function shorten_cwd(cwd)
    local home = vim.uv.os_homedir() or ""
    if home ~= "" and cwd:sub(1, #home) == home then
        cwd = "~" .. cwd:sub(#home + 1)
    end
    -- Keep last 2 path components: ~/a/b/c/d → …/c/d
    local parts = {}
    for part in cwd:gmatch("[^/]+") do
        table.insert(parts, part)
    end
    if #parts > 3 then
        return "…/" .. parts[#parts - 1] .. "/" .. parts[#parts]
    end
    return cwd
end

--- Build the list of picker items from session metadata.
--- @param sessions agentic.ui.ChatHistory.SessionMeta[]
--- @param opts? { show_cwd?: boolean }
--- @return agentic.SessionRestore.PickerItem[]
function SessionRestore.build_items(sessions, opts)
    local show_cwd = opts and opts.show_cwd or false
    local items = {} --- @type agentic.SessionRestore.PickerItem[]
    for _, s in ipairs(sessions) do
        local ts = s.last_activity or s.timestamp or 0
        local date_str = os.date("%Y-%m-%d %H:%M", ts) --[[@as string]]
        local title = (s.title or "(no title)"):match("^([^\n]+)")
            or "(no title)"

        local display = string.format("%s │ %s", date_str, title)
        if show_cwd and s.cwd then
            display = string.format("%s  [%s]", display, shorten_cwd(s.cwd))
        end

        table.insert(items, {
            display = display,
            session_id = s.session_id,
            timestamp = s.timestamp or 0,
            last_activity = s.last_activity,
            cwd = s.cwd,
            file_path = s.file_path,
        })
    end
    return items
end

--- Format a session's messages as preview lines for the picker.
--- @param messages agentic.ui.ChatHistory.Message[]
--- @return string[]
function SessionRestore.format_preview(messages)
    local lines = {}
    for _, msg in ipairs(messages) do
        if msg.type == "user" then
            table.insert(lines, "## You")
            for line in msg.text:gmatch("[^\n]+") do
                table.insert(lines, line)
            end
            table.insert(lines, "")
        elseif msg.type == "agent" then
            table.insert(lines, "## Agent")
            for line in msg.text:gmatch("[^\n]+") do
                table.insert(lines, line)
            end
            table.insert(lines, "")
        elseif msg.type == "thought" then
            table.insert(lines, "> *thinking...*")
            local thought_lines = {}
            for line in msg.text:gmatch("[^\n]+") do
                table.insert(thought_lines, line)
            end
            -- Show only first 3 lines of thought
            for i = 1, math.min(3, #thought_lines) do
                table.insert(lines, "> " .. thought_lines[i])
            end
            if #thought_lines > 3 then
                table.insert(
                    lines,
                    string.format("> ... (%d more lines)", #thought_lines - 3)
                )
            end
            table.insert(lines, "")
        elseif msg.type == "tool_call" then
            local status_icon = msg.status == "completed" and "✔"
                or msg.status == "failed" and "✖"
                or "…"
            local arg = (msg.argument or ""):match("^([^\n]+)") or ""
            table.insert(
                lines,
                string.format(
                    "**%s** `%s` %s",
                    msg.kind or "tool",
                    arg,
                    status_icon
                )
            )
            table.insert(lines, "")
        end
    end
    return lines
end

--- @alias agentic.SessionRestore.Scope "local"|"all"

--- Show session picker and restore selected session
--- @param tab_page_id integer
--- @param current_session agentic.SessionManager|nil
--- @param scope? agentic.SessionRestore.Scope "local" (default) or "all"
function SessionRestore.show_picker(tab_page_id, current_session, scope)
    scope = scope or "local"
    local list_fn = scope == "all" and ChatHistory.list_all_sessions
        or ChatHistory.list_sessions

    list_fn(function(sessions)
        if #sessions == 0 then
            Logger.notify("No saved sessions found", vim.log.levels.INFO)
            return
        end

        local show_cwd = scope == "all"
        local items =
            SessionRestore.build_items(sessions, { show_cwd = show_cwd })
        local has_conflict = check_conflict(current_session)

        --- @param item agentic.SessionRestore.PickerItem
        local function on_select(item)
            restore_with_conflict_check(
                item.session_id,
                tab_page_id,
                has_conflict,
                item.cwd,
                item.file_path
            )
        end

        local picker_name = Config.session_restore.picker or "quickfix"
        local picker_opts = {
            scope = scope,
            tab_page_id = tab_page_id,
            current_session = current_session,
        }

        if picker_name == "fzf-lua" then
            local fzf_picker = require("agentic.session_restore_fzf")
            if fzf_picker.show(items, on_select, picker_opts) then
                return
            end
            Logger.notify(
                "fzf-lua not installed, falling back to quickfix picker",
                vim.log.levels.WARN
            )
            picker_name = "quickfix"
        end

        if picker_name == "select" then
            vim.ui.select(items, {
                prompt = "Sessions:",
                format_item = function(item)
                    return item.display
                end,
            }, function(item)
                if item then
                    on_select(item)
                end
            end)
            return
        end

        local qf_picker = require("agentic.session_restore_builtin")
        qf_picker.show(items, on_select, picker_opts)
    end)
end

--- Replay stored messages to the UI
--- @param writer agentic.ui.MessageWriter
--- @param messages agentic.ui.ChatHistory.Message[]
function SessionRestore.replay_messages(writer, messages)
    for _, msg in ipairs(messages) do
        if msg.type == "user" then
            local message_lines = {
                "##",
                msg.text,
                "\n---\n",
            }
            local user_message =
                ACPPayloads.generate_user_message(message_lines)
            writer:write_message(user_message)
        elseif msg.type == "agent" then
            local agent_message = ACPPayloads.generate_agent_message(msg.text)
            writer:write_message(agent_message)
        elseif msg.type == "thought" then
            --- @type agentic.acp.AgentThoughtChunk
            local thought_chunk = {
                sessionUpdate = "agent_thought_chunk",
                content = { type = "text", text = msg.text },
            }
            writer:write_message_chunk(thought_chunk)
        elseif msg.type == "tool_call" then
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local tool_block = {
                tool_call_id = msg.tool_call_id,
                kind = msg.kind,
                argument = msg.argument or "",
                status = msg.status,
                body = msg.body,
                diff = msg.diff,
            }
            writer:write_tool_call_block(tool_block)
        end
    end
end

return SessionRestore
