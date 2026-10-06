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
--- @field prompt_count? integer Number of user prompts
--- @field provider? agentic.UserConfig.ProviderName config key, nil on legacy sessions
--- @field model? string model id

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
--- Returns true while capabilities are still being negotiated — the agent
--- has just been spawned (first use of this provider), so
--- `load_acp_session` will queue the load until on_ready fires, at which
--- point the capability check inside ACPClient:load_session applies. All
--- currently-supported providers advertise loadSession=true after init.
--- @param session agentic.SessionManager
--- @return boolean
local function agent_supports_load(session)
    if not session.agent then
        return false
    end
    if session.agent.agent_capabilities == nil then
        return true
    end
    return session.agent.agent_capabilities.loadSession == true
end

--- If the session's saved provider differs from the active one, destroy
--- `current_session` and switch Config.provider so a session created next
--- runs the right agent.
--- @param current_session agentic.SessionManager|nil
--- @param provider? agentic.UserConfig.ProviderName config key from the saved session
--- @return boolean changed true if Config.provider was updated
local function align_provider_for_restore(current_session, provider)
    if not provider or provider == Config.provider then
        return false
    end

    if not Config.acp_providers[provider] then
        Logger.notify(
            "Saved provider '"
                .. provider
                .. "' is not configured — restoring with current provider '"
                .. Config.provider
                .. "'.",
            vim.log.levels.WARN
        )
        return false
    end

    if current_session then
        SessionRegistry.destroy(current_session)
    end
    Config.provider = provider
    return true
end

--- Restore `item` into `current_session`, or into a new session when there
--- is none or the saved provider differs.
--- @param item agentic.SessionRestore.PickerItem
--- @param current_session agentic.SessionManager|nil
--- @param has_conflict boolean
--- @return agentic.SessionManager|nil session The session restored into, nil when none could be created
local function do_restore(item, current_session, has_conflict)
    -- Not `get_or_create`: after a destroy, `current()` can return another
    -- live session.
    local changed = align_provider_for_restore(current_session, item.provider)
    local session = (not changed and current_session)
        or SessionRegistry.create()
    if not session then
        return nil
    end

    if agent_supports_load(session) then
        if not item.provider then
            Logger.notify(
                "Session has no saved provider — restoring with current provider '"
                    .. Config.provider
                    .. "'. May fail if the session was created with a different provider.",
                vim.log.levels.WARN
            )
        end
        session:load_acp_session(item.session_id, item.cwd, item.model)
    else
        if has_conflict and session.session_id then
            session.agent:cancel_session(session.session_id)
            session:clear_chat()
        end

        ChatHistory.load(item.session_id, function(history, err)
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
        end, item.file_path)
    end

    return session
end

--- `do_restore`, then reveal the chat of the session restored into.
--- @param item agentic.SessionRestore.PickerItem
--- @param current_session agentic.SessionManager|nil
--- @param has_conflict boolean
local function restore_here(item, current_session, has_conflict)
    local session = do_restore(item, current_session, has_conflict)
    if session then
        session.widget:reveal()
    end
end

--- Restore `item` into a new session and show its chat in a new tabpage.
--- @param item agentic.SessionRestore.PickerItem
local function restore_in_new_tab(item)
    local session = do_restore(item, nil, false)
    if not session then
        return
    end
    session.widget:show({
        tab = vim.api.nvim_tabpage_get_number(
            vim.api.nvim_get_current_tabpage()
        ),
    })
end

--- @param item agentic.SessionRestore.PickerItem
--- @param current_session agentic.SessionManager|nil
--- @param has_conflict boolean
--- @return boolean accepted true if user chose to restore (not cancelled)
local function restore_with_conflict_check(item, current_session, has_conflict)
    if has_conflict then
        local choice = vim.fn.confirm(
            "Current session has messages:",
            "&Replace here\n&Open in new tab\n&Cancel",
            3
        ) -- no nvim_* equivalent
        if choice == 1 then
            restore_here(item, current_session, has_conflict)
        elseif choice == 2 then
            restore_in_new_tab(item)
        else
            return false
        end
    else
        restore_here(item, current_session, has_conflict)
    end
    return true
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
            prompt_count = s.prompt_count,
            provider = s.provider,
            model = s.model,
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
            -- Same glyph vocabulary as the live footer, so a status this
            -- preview has never heard of still reads as the chat buffer
            -- renders it. Unconfigured statuses fall through to the ellipsis.
            local status_icon = (Config.status_icons or {})[msg.status] or "…"
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
--- @param current_session agentic.SessionManager Session to restore into. A new one when it has ended by the time an item is picked
--- @param scope? agentic.SessionRestore.Scope "local" (default) or "all"
function SessionRestore.show_picker(current_session, scope)
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

        --- @param item agentic.SessionRestore.PickerItem
        --- @return boolean accepted
        local function on_select(item)
            local open_session =
                SessionRegistry.session_for_acp_id(item.session_id)
            if open_session then
                open_session.widget:reveal()
                return true
            end
            -- The picker does not block, so the session can end before a pick.
            local live_session = not current_session.destroyed
                    and current_session
                or nil
            return restore_with_conflict_check(
                item,
                live_session,
                check_conflict(live_session)
            )
        end

        -- Three genuinely different backends (builtin quickfix, fzf-lua,
        -- vim.ui.select) selected by config — a real strategy split, not a
        -- factory to collapse.
        local picker_name = Config.session_restore.picker or "quickfix"
        local picker_opts = {
            scope = scope,
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
            writer:write_user_prompt(msg.text)
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
                description = msg.description,
                body = msg.body,
                diff = msg.diff,
                skill_path = msg.skill_path,
                subagent = msg.subagent,
            }
            writer:write_tool_call_block(tool_block)
        end
    end
    -- Neither caller finalizes the turn, so a history ending on a thought would
    -- leave the run buffered until the next turn's first write and render the
    -- restored session's thinking under the new prompt.
    writer:flush_thought_run()
end

--- The stored messages of the agent one Task spawned, in stored order.
--- @param subagent_messages agentic.ui.ChatHistory.SubagentMessage[]
--- @param task_id string The spawning Task's tool call id
--- @return agentic.ui.ChatHistory.SubagentMessage[]
function SessionRestore.messages_for_task(subagent_messages, task_id)
    return vim.tbl_filter(function(msg)
        return msg.parent_tool_use_id == task_id
    end, subagent_messages)
end

--- Resolve a session reference to a cached session. Tries session_id prefix
--- first, then exact case-insensitive title match. Invokes `callback` with
--- `nil` when zero or multiple sessions match (multi-match notifies).
--- @param query string
--- @param callback fun(session_id?: string, cwd?: string, model?: string)
function SessionRestore.resolve_query(query, callback)
    if query == "" then
        callback()
        return
    end
    ChatHistory.list_all_sessions(function(sessions)
        local query_lower = query:lower()
        local prefix_matches = {}
        local title_matches = {}
        for _, s in ipairs(sessions) do
            if s.session_id:sub(1, #query) == query then
                table.insert(prefix_matches, s)
            end
            if type(s.title) == "string" and s.title:lower() == query_lower then
                table.insert(title_matches, s)
            end
        end
        if #prefix_matches == 1 then
            local m = prefix_matches[1]
            callback(m.session_id, m.cwd, m.model)
            return
        elseif #prefix_matches > 1 then
            Logger.notify(
                "Ambiguous session id prefix: " .. #prefix_matches .. " matches",
                vim.log.levels.WARN
            )
            callback()
            return
        end
        if #title_matches == 1 then
            local m = title_matches[1]
            callback(m.session_id, m.cwd, m.model)
        elseif #title_matches > 1 then
            table.sort(title_matches, function(a, b)
                return (a.last_activity or a.timestamp or 0)
                    > (b.last_activity or b.timestamp or 0)
            end)
            local m = title_matches[1]
            Logger.notify(
                string.format(
                    "Ambiguous session title (%d matches); picking newest (%s)",
                    #title_matches,
                    m.session_id:sub(1, 8)
                ),
                vim.log.levels.WARN
            )
            callback(m.session_id, m.cwd, m.model)
        else
            callback()
        end
    end)
end

return SessionRestore
