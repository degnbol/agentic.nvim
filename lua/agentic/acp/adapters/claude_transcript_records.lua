--- Decoder for the records the Claude Code CLI writes to its transcript jsonl
--- (`~/.claude/projects/<slug>/<session-id>.jsonl`) about what the ACP bridge
--- does not forward: hook activity, and files the CLI added to the model's
--- context without a tool call.
---
--- Pure and stateless: one entry in, zero or more records out. Records do not
--- carry the place they belong: that takes joins across entries. `link` gives
--- each entry's part in the `parentUuid` join.
local M = {}

--- @alias agentic.acp.ClaudeHookRecordGroup
--- | agentic.acp.HookRecordGroup
--- | "context_run" a run whose JSON stdout carries `additionalContext`, that context as its body. Not for display: the CLI writes the same context again in a later `hook_additional_context` entry, which lacks the run's `command` and `durationMs`

--- @class agentic.acp.ClaudeHookRecord : agentic.acp.HookRecord
--- @field kind "hook"
--- @field group agentic.acp.ClaudeHookRecordGroup
--- @field timestamp? string ISO-8601 UTC, fixed width so string order is time order
--- @field hook_event? string the event the hook fired on, e.g. `PreToolUse`
--- @field tool_call_id? string what the hook fired on, verbatim from `toolUseID`. Only a `toolu_`-prefixed value is a tool call id: an event with no call to name puts `"SessionStart"`, `hook-<uuid>` or a bare message uuid in the same slot

--- @class agentic.acp.ClaudeLoadedFileRecord
--- @field kind "loaded_file"
--- @field path string Absolute
--- @field is_mention boolean An `@` file, not a rule
--- @field timestamp? string

--- What a transcript entry says about where a load under it belongs.
--- @class agentic.acp.TranscriptLink
--- @field uuid string
--- @field parent_uuid? string
--- @field ends_chain boolean A `tool_result` record, a meta record with `sourceToolUseID`, a compaction's output, a user-text record, a `queued_command` attachment, or an `assistant` record
--- @field tool_call_id? string `tool_use_id` of a `tool_result` record, or `sourceToolUseID` of a meta record
--- @field after_prompt boolean Ends the chain at the prompt: user text or a `queued_command`
--- @field after_compaction boolean Ends the chain at a compaction's output (`repeatsCompactSummary`)
--- @field user_text boolean Ends the chain at the user's own text
--- @field injected boolean Text the CLI injected under its parent (a meta record without `sourceToolUseID`: a skill run as `/name`, a Stop hook's feedback): the chain goes on through it, but past it the text is no longer the user's own

--- Events whose plain-text stdout the model receives as context (hooks docs
--- § "Exit code 0"). On any other event a successful hook's stdout reaches
--- no one.
local STDOUT_CONTEXT_EVENTS = {
    SessionStart = true,
    UserPromptSubmit = true,
    UserPromptExpansion = true,
    PostModelSwitch = true,
}

--- Prefix the SDK puts on the stderr of a hook that exited non-zero. Only a
--- `hook_non_blocking_error` with this prefix has the process's own `exitCode`.
--- Version-coupled to the CLI — recheck the wording on a bump.
local FAILED_PREFIX = "Failed with non-blocking status code: "

--- The SDK's stand-in for a non-zero exit that wrote no stderr. Exiting 1 to
--- mean "nothing to say" is the common hook idiom, so a record carrying only
--- this literal is a pass, not a failure.
local NO_STDERR = FAILED_PREFIX .. "No stderr output"

--- @param content string|string[]|nil
--- @return string[]
local function body_lines(content)
    local text = type(content) == "table" and table.concat(content, "\n")
        or content
    if type(text) ~= "string" then
        return {}
    end
    -- A newline ends the last line rather than starting an empty one.
    text = text:gsub("\n$", "")
    if text == "" then
        return {}
    end
    return vim.split(text, "\n")
end

--- Body lines saying why a hook run failed: the timeout, or the exit code
--- followed by the stderr. The script is not named.
--- @param attachment table `hook_non_blocking_error` or a timed-out `hook_cancelled`
--- @return string[]
local function failure_body(attachment)
    if attachment.type == "hook_cancelled" then
        return { ("timed out after %g s"):format(attachment.timeoutMs / 1000) }
    end

    local stderr = type(attachment.stderr) == "string" and attachment.stderr
        or ""
    if not vim.startswith(stderr, FAILED_PREFIX) then
        local lines = body_lines(stderr)
        return #lines > 0 and lines or { "failed with no stderr" }
    end
    local lines = body_lines(stderr:sub(#FAILED_PREFIX + 1))
    if type(attachment.exitCode) == "number" then
        table.insert(lines, 1, ("exited %d"):format(attachment.exitCode))
    end
    return lines
end

--- The `hookSpecificOutput.additionalContext` a hook's stdout carries as JSON.
--- @param stdout any
--- @return string|nil context nil when `stdout` is not JSON carrying a string context
local function json_context(stdout)
    if type(stdout) ~= "string" then
        return nil
    end
    local ok, output = pcall(vim.json.decode, stdout)
    local specific = ok
        and type(output) == "table"
        and output.hookSpecificOutput
    local context = type(specific) == "table" and specific.additionalContext
    return type(context) == "string" and context or nil
end

--- @param attachment table any hook attachment but `hook_additional_context`
--- @return agentic.acp.ClaudeHookRecordGroup|nil group nil when the attachment is not a hook record
--- @return string[] body
local function classify(attachment)
    local kind = attachment.type

    if kind == "hook_success" then
        local body = body_lines(attachment.content)
        if #body == 0 then
            local context = body_lines(json_context(attachment.stdout))
            if #context > 0 then
                return "context_run", context
            end
            return "passed", body
        end
        if STDOUT_CONTEXT_EVENTS[attachment.hookEvent] then
            return "context", body
        end
        return "stray", body
    end

    if kind == "hook_non_blocking_error" then
        if attachment.stderr == NO_STDERR then
            return "passed", {}
        end
        return "failure", failure_body(attachment)
    end

    if kind == "hook_cancelled" then
        -- Not timed out: the turn was cancelled while the hook ran, or the
        -- hook was skipped inside an agent a hook spawned (no `timedOut`).
        if attachment.timedOut ~= true then
            return nil, {}
        end
        return "failure", failure_body(attachment)
    end

    return nil, {}
end

--- The hook records a transcript entry carries as its attachment. A
--- `hook_additional_context` gives one record per `content` element: the CLI
--- merges the context of several hooks on one event into one attachment, one
--- element per hook.
--- @param entry table one decoded transcript line
--- @return agentic.acp.ClaudeHookRecord[] records empty when the entry is not a hook attachment
local function attachment_records(entry)
    --- @type agentic.acp.ClaudeHookRecord[]
    local records = {}
    -- `hookEvent` is what separates hook attachments from the other
    -- attachment kinds (pasted images, file contents).
    local attachment = entry.attachment
    if
        entry.type ~= "attachment"
        or type(attachment) ~= "table"
        or not attachment.hookEvent
    then
        return records
    end

    local group, bodies
    if attachment.type == "hook_additional_context" then
        local content = attachment.content
        group = "context"
        bodies = vim.tbl_map(
            body_lines,
            type(content) == "table" and content or { content }
        )
    else
        local body
        group, body = classify(attachment)
        bodies = { body }
    end
    if not group then
        return records
    end

    for _, body in ipairs(bodies) do
        table.insert(records, {
            kind = "hook",
            group = group,
            body = body,
            timestamp = entry.timestamp,
            command = attachment.command,
            hook_name = attachment.hookName,
            hook_event = attachment.hookEvent,
            duration_ms = attachment.durationMs,
            tool_call_id = attachment.toolUseID,
        })
    end
    return records
end

--- Split a `[<command>]: <text>` entry into its parts.
--- @param text string
--- @return string|nil command nil when `text` lacks the prefix
--- @return string body `text` after the prefix, or all of it
local function split_command(text)
    local command, body = text:match("^%[(.-)%]: (.*)$")
    return command, body or text
end

--- One `context` record per Stop hook that blocked the turn's end, carrying the
--- feedback the model receives as its next input. A `hookErrors` entry without
--- the command prefix is a non-blocking error, which a
--- `hook_non_blocking_error` attachment already carries, so it yields none.
--- @param entry table one decoded transcript line
--- @return agentic.acp.ClaudeHookRecord[] records empty when the entry is not a Stop hook summary
local function stop_feedback_records(entry)
    --- @type agentic.acp.ClaudeHookRecord[]
    local records = {}
    if
        entry.type ~= "system"
        or entry.subtype ~= "stop_hook_summary"
        or type(entry.hookErrors) ~= "table"
    then
        return records
    end
    for _, hook_error in ipairs(entry.hookErrors) do
        local command, body
        if type(hook_error) == "string" then
            command, body = split_command(hook_error)
        end
        if command then
            table.insert(records, {
                kind = "hook",
                group = "context",
                body = body_lines(body),
                timestamp = entry.timestamp,
                command = command,
                -- No `uuid`: every hook in the summary shares it, so it names
                -- no single script's run. No `tool_call_id`: `toolUseID` on
                -- this entry is not a tool call id.
            })
        end
    end
    return records
end

--- Attachment types that carry a file the CLI added to the model's context,
--- and the field holding its absolute path.
local LOADED_FILE_PATH_FIELDS = {
    nested_memory = "path",
    file = "filename",
}

--- The loaded file a transcript entry carries as its attachment.
--- @param entry table one decoded transcript line
--- @return agentic.acp.ClaudeLoadedFileRecord|nil record nil when the entry is not a loaded file
local function loaded_file_record(entry)
    local attachment = entry.attachment
    if entry.type ~= "attachment" or type(attachment) ~= "table" then
        return nil
    end
    local field = LOADED_FILE_PATH_FIELDS[attachment.type]
    local path = field and attachment[field]
    if type(path) ~= "string" then
        return nil
    end

    --- @type agentic.acp.ClaudeLoadedFileRecord
    local record = {
        kind = "loaded_file",
        path = path,
        is_mention = attachment.type == "file",
        timestamp = entry.timestamp,
    }
    return record
end

--- Decode one transcript line.
--- @param line string one raw line of the transcript jsonl
--- @return table|nil entry nil when the line is not JSON
function M.parse(line)
    local ok, entry = pcall(vim.json.decode, line)
    if not ok or type(entry) ~= "table" then
        return nil
    end
    return entry
end

--- The record a line that does not parse becomes: a transcript this decoder
--- cannot read is the thing least safe to drop.
--- @param line string
--- @return agentic.acp.ClaudeHookRecord
function M.verbatim(line)
    --- @type agentic.acp.ClaudeHookRecord
    local record = { kind = "hook", group = "verbatim", body = { line } }
    return record
end

--- The hook records and loaded file a transcript entry carries.
--- @param entry table one decoded transcript line
--- @return (agentic.acp.ClaudeHookRecord|agentic.acp.ClaudeLoadedFileRecord)[] records empty for an entry that carries neither
function M.records(entry)
    local loaded_file = loaded_file_record(entry)
    if loaded_file then
        return { loaded_file }
    end
    local hooks = attachment_records(entry)
    if #hooks > 0 then
        return hooks
    end
    return stop_feedback_records(entry)
end

--- The first `tool_result` block of a message's content.
--- @param content any
--- @return table|nil
local function tool_result_block(content)
    if type(content) ~= "table" then
        return nil
    end
    for _, block in ipairs(content) do
        if type(block) == "table" and block.type == "tool_result" then
            return block
        end
    end
    return nil
end

--- Whether a message's content is text: a string, or holding a `text` block.
--- @param content any
--- @return boolean
local function has_text(content)
    if type(content) == "string" then
        return true
    end
    if type(content) ~= "table" then
        return false
    end
    for _, block in ipairs(content) do
        if type(block) == "table" and block.type == "text" then
            return true
        end
    end
    return false
end

--- What a transcript entry says about where records under it belong.
---
--- An `assistant` entry ends the chain with no place set: what the CLI writes
--- under the agent's own output, such as a Stop hook, came after that output.
--- @param entry table one decoded transcript line
--- @return agentic.acp.TranscriptLink|nil link nil for an entry without `uuid`
function M.link(entry)
    if type(entry.uuid) ~= "string" then
        return nil
    end

    --- @type agentic.acp.TranscriptLink
    local link = {
        uuid = entry.uuid,
        parent_uuid = type(entry.parentUuid) == "string" and entry.parentUuid
            or nil,
        ends_chain = false,
        after_prompt = false,
        after_compaction = false,
        user_text = false,
        injected = false,
    }

    local attachment = type(entry.attachment) == "table" and entry.attachment
        or {}
    if entry.type == "attachment" then
        if attachment.type == "queued_command" then
            link.ends_chain = true
            link.after_prompt = true
            link.user_text = true
        end
        return link
    end

    if entry.type == "assistant" then
        link.ends_chain = true
        return link
    end
    if entry.type ~= "user" then
        return link
    end

    local content = type(entry.message) == "table" and entry.message.content
    local result = tool_result_block(content)
    if result then
        link.ends_chain = true
        link.tool_call_id = result.tool_use_id
    elseif entry.isMeta then
        link.ends_chain = entry.sourceToolUseID ~= nil
        link.tool_call_id = entry.sourceToolUseID
        link.injected = entry.sourceToolUseID == nil
    elseif entry.repeatsCompactSummary then
        link.ends_chain = true
        link.after_compaction = true
    elseif has_text(content) then
        link.ends_chain = true
        link.after_prompt = true
        link.user_text = true
    end
    return link
end

return M
