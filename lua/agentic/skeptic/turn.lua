--- What a conversation added since the last collect: the part of a chat
--- history a skeptic has not checked yet.

--- @class agentic.skeptic.Seen
--- @field mark integer Index into `messages` after the last collected row
--- @field ids table<string, true> Collected tool_call ids and `message:`-prefixed session message ids

--- @class agentic.skeptic.Turn
--- @field prompts string[] User rows since the mark without `author`; synthetic prompts left out
--- @field text string Main agent rows since the mark, joined by blank lines; thought rows excluded
--- @field diffs string[] Unified diffs of completed tool calls, main or subagent, not in `seen.ids`
--- @field reports string[] Subagent results not in `seen.ids`: the body of a completed subagent block in the main chat, and the text of a `result` message the main agent received

--- @class agentic.skeptic.TurnModule
local M = {}

--- Key of a session message in `Seen.ids`.
--- @param message_id string
--- @return string
local function message_key(message_id)
    return "message:" .. message_id
end

--- Text of `lines` ending in a newline, or "" for none.
--- @param lines string[]
--- @return string
local function file_text(lines)
    return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

--- Unified diff of a tool call's change to the file it names.
--- @param call agentic.ui.ChatHistory.ToolCall With `diff`
--- @return string
local function unified_diff(call)
    local path = call.argument or "?"
    local hunks = vim.text.diff(
        file_text(call.diff.old),
        file_text(call.diff.new),
        { ctxlen = 3 }
    ) --[[@as string]]
    return ("--- %s\n+++ %s\n%s"):format(path, path, hunks)
end

--- @param msg agentic.ui.ChatHistory.Message
--- @return boolean
local function is_completed_call(msg)
    return msg.type == "tool_call" and msg.status == "completed"
end

--- Collect what `history` added since `seen`, and add what it took to `seen`.
--- @param history agentic.ui.ChatHistory
--- @param seen agentic.skeptic.Seen Updated in place
--- @return agentic.skeptic.Turn
function M.collect(history, seen)
    --- @type agentic.skeptic.Turn
    local turn = { prompts = {}, text = "", diffs = {}, reports = {} }
    local texts = {}
    for i = seen.mark, #history.messages do
        local msg = history.messages[i]
        if msg.type == "user" and not msg.author and not msg.synthetic then
            table.insert(turn.prompts, msg.text)
        elseif msg.type == "agent" then
            table.insert(texts, msg.text)
        end
    end
    turn.text = table.concat(texts, "\n\n")
    seen.mark = #history.messages + 1

    for _, msg in ipairs(history.messages) do
        if is_completed_call(msg) and msg.subagent then
            --- @cast msg agentic.ui.ChatHistory.ToolCall
            if not seen.ids[msg.tool_call_id] then
                seen.ids[msg.tool_call_id] = true
                table.insert(turn.reports, table.concat(msg.body or {}, "\n"))
            end
        elseif
            msg.type == "session_message"
            and msg.kind == "result"
            and msg.view == "received"
        then
            --- @cast msg agentic.ui.ChatHistory.SessionMessage
            local key = message_key(msg.message_id)
            if not seen.ids[key] then
                seen.ids[key] = true
                table.insert(turn.reports, msg.text)
            end
        end
    end

    for _, list in ipairs({ history.messages, history.subagent_messages }) do
        for _, msg in ipairs(list) do
            if is_completed_call(msg) and msg.diff then
                --- @cast msg agentic.ui.ChatHistory.ToolCall
                if not seen.ids[msg.tool_call_id] then
                    seen.ids[msg.tool_call_id] = true
                    table.insert(turn.diffs, unified_diff(msg))
                end
            end
        end
    end
    return turn
end

--- Agent keys of the subagents spawned in `messages[from..]`: each spawn
--- block's id and the task id `history` records for it.
--- @param history agentic.ui.ChatHistory
--- @param from integer
--- @return table<string, true>
local function spawned_from(history, from)
    local keys = {}
    for i = from, #history.messages do
        local msg = history.messages[i]
        if msg.type == "tool_call" and msg.subagent and msg.tool_call_id then
            keys[msg.tool_call_id] = true
            local task_id =
                vim.tbl_get(history.subagents, msg.tool_call_id, "task_id")
            if task_id then
                keys[task_id] = true
            end
        end
    end
    return keys
end

--- A `Seen` that counts everything before `message` as collected: the rows
--- before it, and the calls and results of subagents not spawned from it
--- on. Without `message` in `history`, everything counts.
--- @param history agentic.ui.ChatHistory
--- @param message agentic.ui.ChatHistory.Message|nil
--- @return agentic.skeptic.Seen
function M.seen_before(history, message)
    local mark = #history.messages + 1
    for i, msg in ipairs(history.messages) do
        if msg == message then
            mark = i
            break
        end
    end

    local ids = {}
    for i = 1, mark - 1 do
        local msg = history.messages[i]
        if msg.type == "tool_call" and msg.tool_call_id then
            ids[msg.tool_call_id] = true
        elseif msg.type == "session_message" then
            ids[message_key(msg.message_id)] = true
        end
    end
    local current = spawned_from(history, mark)
    for _, msg in ipairs(history.subagent_messages) do
        if
            msg.type == "tool_call"
            and msg.tool_call_id
            and not current[msg.agent_key]
        then
            ids[msg.tool_call_id] = true
        end
    end
    return { mark = mark, ids = ids }
end

--- @param turn agentic.skeptic.Turn
--- @return boolean
function M.is_empty(turn)
    return #turn.prompts == 0
        and turn.text == ""
        and #turn.diffs == 0
        and #turn.reports == 0
end

--- `earlier` followed by `later`, as one turn.
--- @param earlier agentic.skeptic.Turn
--- @param later agentic.skeptic.Turn
--- @return agentic.skeptic.Turn
function M.merge(earlier, later)
    local texts = vim.tbl_filter(function(text)
        return text ~= ""
    end, { earlier.text, later.text })
    --- @type agentic.skeptic.Turn
    local merged = {
        prompts = vim.list_extend(
            vim.list_slice(earlier.prompts),
            later.prompts
        ),
        text = table.concat(texts, "\n\n"),
        diffs = vim.list_extend(vim.list_slice(earlier.diffs), later.diffs),
        reports = vim.list_extend(
            vim.list_slice(earlier.reports),
            later.reports
        ),
    }
    return merged
end

return M
