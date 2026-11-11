local ACPPayloads = require("agentic.acp.acp_payloads")
local CanonicalToolCall = require("agentic.acp.canonical_tool_call")
local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local Glyphs = require("agentic.glyphs")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")
local SideRecords = require("agentic.ui.side_records")
local TextWrap = require("agentic.utils.text_wrap")
local Theme = require("agentic.theme")

--- @class agentic.SessionResume.PickerItem : agentic.ui.ChatHistory.SessionMeta
--- @field display string

--- @class agentic.SessionResume
local SessionResume = {}

--- Shorten a path for display: the home directory becomes `~`, and a path with
--- more than 3 components keeps only the last 2 (`~/a/b/c/d` gives `…/c/d`).
--- @param cwd string
--- @return string
local function shorten_cwd(cwd)
    cwd = vim.fn.fnamemodify(cwd, ":~")
    local parts = vim.split(cwd, "/", { trimempty = true })
    if #parts > 3 then
        return "…/" .. table.concat(parts, "/", #parts - 1)
    end
    return cwd
end

--- Build the list of picker items from session metadata.
--- @param sessions agentic.ui.ChatHistory.SessionMeta[]
--- @param opts? { show_cwd?: boolean }
--- @return agentic.SessionResume.PickerItem[]
function SessionResume.build_items(sessions, opts)
    local show_cwd = opts and opts.show_cwd or false
    local items = {} --- @type agentic.SessionResume.PickerItem[]
    for _, s in ipairs(sessions) do
        local ts = s.last_activity or s.timestamp or 0
        local date_str = os.date("%Y-%m-%d %H:%M", ts) --[[@as string]]
        local title = (s.title or "(no title)"):match("^([^\n]+)")
            or "(no title)"

        local display = string.format("%s │ %s", date_str, title)
        if show_cwd and s.cwd then
            display = string.format("%s  [%s]", display, shorten_cwd(s.cwd))
        end

        local item = vim.tbl_extend("force", s, { display = display }) --[[@as agentic.SessionResume.PickerItem]]
        table.insert(items, item)
    end
    return items
end

--- Format a session's messages as preview lines for the picker, from the
--- first message its chat shows (`ChatHistory.render_start`). Synthetic
--- prompts are skipped.
--- @param messages agentic.ui.ChatHistory.Message[]
--- @return string[]
function SessionResume.format_preview(messages)
    local lines = {}
    local shown = vim.list_slice(messages, ChatHistory.render_start(messages))
    for _, msg in ipairs(shown) do
        if msg.type == "user" and not msg.synthetic then
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
            local status_icon = (Config.status_icons or {})[CanonicalToolCall.status_word(
                msg
            )] or "…"
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
        elseif msg.type == "session_message" then
            local title, rest =
                SessionResume.message_title(msg.text, msg.summary)
            table.insert(lines, "## " .. title)
            vim.list_extend(lines, rest)
            table.insert(lines, "")
        elseif msg.type == "subagent_end" then
            table.insert(lines, "## " .. msg.state)
            if msg.error then
                vim.list_extend(
                    lines,
                    vim.split(msg.error, "\n", { plain = true })
                )
            end
            table.insert(lines, "")
        end
    end
    return lines
end

--- @alias agentic.SessionResume.Scope "local"|"all"

--- Sessions of `scope`: "local" is the project folder of
--- `vim.fn.getcwd()`, "all" is every project folder. Calls `callback`
--- before it returns.
--- @param scope agentic.SessionResume.Scope
--- @param callback fun(sessions: agentic.ui.ChatHistory.SessionMeta[])
function SessionResume.list(scope, callback)
    if scope == "all" then
        ChatHistory.list_all_sessions(callback)
    else
        ChatHistory.list_sessions(vim.fn.getcwd(), callback)
    end
end

--- Show the chat of the open session that holds `ref.session_id`. Else create
--- a session on `ref.provider`, apply `sessions.cd_on_load`, load the
--- saved session into it (ACP `session/load`) and show its chat. A nil `cwd`,
--- `provider` or `model` takes the value of the saved file, when there is one.
--- A provider that is not configured warns and uses the default provider.
--- @param ref agentic.ui.ChatHistory.SessionRef
--- @param mods vim.api.keyset.cmd_mods|nil A split or tab modifier shows the chat in a new window
--- @param on_shown fun(session: agentic.SessionManager, winid: integer)|nil Runs once the chat shows the session, with the window it was shown in: at once for an open session, else when the load ends
function SessionResume.resume(ref, mods, on_shown)
    local open_session = SessionRegistry.session_for_acp_id(ref.session_id)
    if open_session then
        open_session.widget:show(mods, SessionRegistry.target_win())
        if on_shown then
            on_shown(open_session, vim.api.nvim_get_current_win())
        end
        return
    end

    local cwd, provider, model = ref.cwd, ref.provider, ref.model
    if not (cwd and provider and model) then
        local saved = ChatHistory.read_saved(ref.session_id)
        if saved then
            cwd = cwd or saved.cwd
            provider = provider or saved.provider
            model = model or saved.model
        end
    end

    local configured = provider and Config.acp_providers[provider] and provider
        or nil
    local session = SessionRegistry.create(configured)
    if not session then
        return
    end
    if Config.sessions.cd_on_load and cwd then
        local st = vim.uv.fs_stat(cwd)
        if st and st.type == "directory" then
            vim.api.nvim_set_current_dir(cwd)
        end
    end
    if provider and not configured then
        Logger.notify(
            "Saved provider '"
                .. provider
                .. "' is not configured — resuming with provider '"
                .. session.agent.provider_name
                .. "'.",
            vim.log.levels.WARN
        )
    end
    --- @type integer
    local shown_win
    session:load_acp_session(
        ref.session_id,
        cwd,
        model,
        on_shown
            and function(loaded)
                on_shown(loaded, shown_win)
            end
    )
    session.widget:show(mods, SessionRegistry.target_win())
    -- `show` focuses the window it shows the chat in.
    shown_win = vim.api.nvim_get_current_win()
end

--- Saved sessions of all projects whose id starts with `query`, else whose
--- title equals `query` (case-insensitive). One row per session id, newest
--- activity first.
--- @param query string
--- @param callback fun(matches: agentic.ui.ChatHistory.SessionMeta[])
function SessionResume.find(query, callback)
    SessionResume.list("all", function(sessions)
        callback(ChatHistory.match_sessions(sessions, query))
    end)
end

--- @class agentic.SessionResume.PickerOpts
--- @field scope? agentic.SessionResume.Scope "local" (default) or "all"
--- @field mods? vim.api.keyset.cmd_mods
--- @field marked_id? string ACP session id to mark
--- @field sessions? agentic.ui.ChatHistory.SessionMeta[] Sessions to show. Default: the saved sessions of `scope`
--- @field notice? string Notified before the picker shows, or joined with the "No saved sessions found" notification into one

--- Show saved sessions in a picker and resume the picked one.
--- @param opts agentic.SessionResume.PickerOpts|nil
function SessionResume.show_picker(opts)
    opts = opts or {}
    local scope = opts.scope or "local"

    --- @param sessions agentic.ui.ChatHistory.SessionMeta[]
    local function show(sessions)
        if #sessions == 0 then
            local message = "No saved sessions found"
            if opts.notice then
                message = opts.notice .. "\n" .. message
            end
            Logger.notify(message, vim.log.levels.INFO)
            return
        end
        if opts.notice then
            Logger.notify(opts.notice, vim.log.levels.INFO)
        end

        local items =
            SessionResume.build_items(sessions, { show_cwd = scope == "all" })

        --- @param item agentic.SessionResume.PickerItem
        local function on_select(item)
            SessionResume.resume(item, opts.mods)
        end

        -- Three genuinely different backends (builtin quickfix, fzf-lua,
        -- vim.ui.select) selected by config — a real strategy split, not a
        -- factory to collapse.
        local picker_name = Config.sessions.picker or "quickfix"
        local picker_opts = {
            scope = scope,
            mods = opts.mods,
            marked_id = opts.marked_id,
        }

        if picker_name == "fzf-lua" then
            local fzf_picker = require("agentic.session_resume_fzf")
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

        local qf_picker = require("agentic.session_resume_builtin")
        qf_picker.show(items, on_select, picker_opts)
    end

    if opts.sessions then
        show(opts.sessions)
    else
        SessionResume.list(scope, show)
    end
end

--- Resume the saved session of any project whose id starts with `query`, else
--- whose title equals `query` (case-insensitive). Several matches: pick among
--- them. No match: notify and pick among the sessions of this project. Nil or
--- "" `query`: pick among the sessions of this project.
--- @param query string|nil
--- @param opts { mods?: vim.api.keyset.cmd_mods, marked_id?: string }|nil
function SessionResume.pick(query, opts)
    opts = opts or {}
    if not query or query == "" then
        SessionResume.show_picker({
            mods = opts.mods,
            marked_id = opts.marked_id,
        })
        return
    end
    SessionResume.find(query, function(matches)
        if #matches == 1 then
            SessionResume.resume(matches[1], opts.mods)
        elseif #matches > 1 then
            SessionResume.show_picker({
                scope = "all",
                sessions = matches,
                mods = opts.mods,
                marked_id = opts.marked_id,
            })
        else
            SessionResume.show_picker({
                notice = "No saved session matches: " .. query,
                mods = opts.mods,
                marked_id = opts.marked_id,
            })
        end
    end)
end

--- The title of a message's row and the lines under it. A message with a
--- summary is titled by it, with its whole text under it. Else the title is
--- the first sentence of the first non-blank line
--- (`TextWrap.split_sentence`), without heading marks, and the rest of that
--- line and the text go under it. A text with no such line is titled
--- `(empty message)`. A first line opening a code fence or holding only
--- heading marks is no title, so the row is titled `(message)` and the rest
--- goes under it.
--- @param text string
--- @param summary string|nil
--- @return string title
--- @return string[] rest
function SessionResume.message_title(text, summary)
    local head, rest = TextWrap.head_and_rest(text)
    if not head then
        return summary or "(empty message)", {}
    end
    if summary then
        return summary, vim.split(vim.trim(text), "\n", { plain = true })
    end
    if TextWrap.is_fence_delimiter(head) then
        return "(message)", vim.list_extend({ head }, rest)
    end
    head = head:gsub("^%s*#+%s+", "")
    if head == "" then
        return "(message)", rest
    end
    local sentence, tail = TextWrap.split_sentence(head)
    if not tail then
        return head, rest
    end
    local lines = { tail }
    if #rest > 0 then
        table.insert(lines, "")
    end
    return sentence, vim.list_extend(lines, rest)
end

--- How a subagent end row's run ended. A saved state `cancelled` reads as
--- `interrupted`.
--- @param row agentic.ui.ChatHistory.SubagentEnd
--- @return string
function SessionResume.end_state(row)
    return row.state == "cancelled" and "interrupted" or row.state
end

--- Write a session message or a subagent end as a notice. A message is signed
--- with the glyph of its kind (`Glyphs.MESSAGE`), split into heading and body
--- by `SessionResume.message_title`, with the other end's buffer name, else
--- the sender's name, dimmed under the heading and the body folded, and
--- tagged with its message id. An end is signed with its state's status icon
--- when that is one cell wide, else `Glyphs.RUN_ENDED`, and holds the error
--- text, titled `SessionResume.end_state`.
--- @param writer agentic.ui.MessageWriter
--- @param row agentic.ui.ChatHistory.SessionMessage|agentic.ui.ChatHistory.SubagentEnd
--- @param mid_turn boolean The writer's turn is still running, so the notice must not finalize it
--- @param buffer_name fun(session_id: string): string|nil Name of a session's buffer, nil when it has none
function SessionResume.write_row(writer, row, mid_turn, buffer_name)
    if row.type == "subagent_end" then
        local state = SessionResume.end_state(row)
        local icon = (Config.status_icons or {})[state]
        -- One cell: a sign holds two, and the glyph takes a trailing space.
        local usable = type(icon) == "string"
            and vim.fn.strdisplaywidth(icon) == 1
        writer:write_notice({
            glyph = usable and icon or Glyphs.RUN_ENDED,
            glyph_hl = Theme.HL_GROUPS.GLYPH_AGENT,
            title = state,
            body = row.error and vim.split(row.error, "\n", { plain = true }),
            mid_turn = mid_turn,
        })
        return
    end

    local title, rest = SessionResume.message_title(row.text, row.summary)
    local peer = row.view == "sent" and row.recipient_session_id
        or row.sender_session_id
    writer:write_notice({
        glyph = Glyphs.MESSAGE[row.kind == "message" and row.view or row.kind],
        glyph_hl = Theme.HL_GROUPS.GLYPH_AGENT,
        title = title,
        detail = peer and buffer_name(peer) or row.sender_name,
        fold_body = rest,
        mid_turn = mid_turn,
        id = row.message_id,
    })
end

--- Replay stored messages to the UI. Synthetic prompts are skipped. Each
--- prompt's message is its payload in the writer.
--- @param writer agentic.ui.MessageWriter
--- @param messages agentic.ui.ChatHistory.Message[]
--- @param buffer_name fun(session_id: string): string|nil Name of a session's buffer, nil when it has none
function SessionResume.replay_messages(writer, messages, buffer_name)
    for _, msg in ipairs(messages) do
        if msg.type == "user" and not msg.synthetic then
            writer:write_user_prompt(msg.text, nil, msg.author, msg)
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
            -- Records saved before normalisation at ingress hold the raw
            -- argument. Only the split is safe to repeat (`normalise`).
            local record = CanonicalToolCall.split_read_range(msg, msg.kind)
            writer:write_tool_call_block(ChatHistory.to_tool_call_block(record))
        elseif msg.type == "session_message" or msg.type == "subagent_end" then
            SessionResume.write_row(writer, msg, true, buffer_name)
        elseif msg.type == "side_records" then
            SideRecords.write(writer, msg.records)
        elseif msg.type == "fork_link" then
            writer:write_fork_link(msg)
        end
    end
    -- Neither caller finalizes the turn, so a history ending on a thought would
    -- leave the run buffered until the next turn's first write and render the
    -- history's thinking under the new prompt.
    writer:flush_thought_run()
end

return SessionResume
