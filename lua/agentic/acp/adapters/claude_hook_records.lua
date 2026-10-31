--- Decoder for the hook records the Claude Code CLI writes to its transcript
--- jsonl (`~/.claude/projects/<slug>/<session-id>.jsonl`). The ACP bridge drops
--- the hook lifecycle events, so the transcript is the only channel carrying
--- what a hook injected, printed or how it failed.
---
--- Pure and stateless: one line in, zero or more records out. Records carry no
--- `script`: naming it takes the `parentUuid` join across records.
local M = {}

--- @alias agentic.acp.ClaudeHookRecordGroup
--- | agentic.acp.HookRecordGroup
--- | "silent" stopped by the turn's cancellation, or skipped; carried only so its `command` can attribute a later record

--- @class agentic.acp.ClaudeHookRecord : agentic.acp.HookRecord
--- @field group agentic.acp.ClaudeHookRecordGroup
--- @field uuid? string
--- @field parent_uuid? string
--- @field timestamp? string ISO-8601 UTC, fixed width so string order is time order
--- @field hook_name? string the hook's configured name, e.g. `PreToolUse:Bash`
--- @field tool_call_id? string what the hook fired on, verbatim from `toolUseID`. Only a `toolu_`-prefixed value is a tool call id: an event with no call to name puts `"SessionStart"`, `hook-<uuid>` or a bare message uuid in the same slot

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

--- @param attachment table
--- @return agentic.acp.ClaudeHookRecordGroup|nil group nil when the attachment is not a hook record
--- @return string[] body
local function classify(attachment)
    local kind = attachment.type

    if kind == "hook_additional_context" then
        return "context", body_lines(attachment.content)
    end

    if kind == "hook_success" then
        local body = body_lines(attachment.content)
        if #body == 0 then
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
            return "silent", {}
        end
        return "failure", failure_body(attachment)
    end

    return nil, {}
end

--- The hook record a transcript entry carries as its attachment.
--- @param entry table one decoded transcript line
--- @return agentic.acp.ClaudeHookRecord|nil record nil when the entry is not a hook attachment
local function attachment_record(entry)
    -- `hookEvent` is what separates hook attachments from the other
    -- attachment kinds (pasted images, file contents).
    local attachment = entry.attachment
    if
        entry.type ~= "attachment"
        or type(attachment) ~= "table"
        or not attachment.hookEvent
    then
        return nil
    end

    local group, body = classify(attachment)
    if not group then
        return nil
    end

    --- @type agentic.acp.ClaudeHookRecord
    local record = {
        group = group,
        body = body,
        uuid = entry.uuid,
        parent_uuid = entry.parentUuid,
        timestamp = entry.timestamp,
        command = attachment.command,
        hook_name = attachment.hookName,
        duration_ms = attachment.durationMs,
        tool_call_id = attachment.toolUseID,
    }
    return record
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

--- Decode one transcript line into hook records. A line that is not valid JSON
--- still yields a record, in the `verbatim` group: a transcript this decoder
--- cannot read is the thing least safe to drop.
--- @param line string one raw line of the transcript jsonl
--- @return agentic.acp.ClaudeHookRecord[] records empty for a line that carries no hook activity
function M.decode(line)
    if line:match("^%s*$") then
        return {}
    end

    local ok, entry = pcall(vim.json.decode, line)
    if not ok or type(entry) ~= "table" then
        --- @type agentic.acp.ClaudeHookRecord
        local unparsed = { group = "verbatim", body = { line } }
        return { unparsed }
    end

    local record = attachment_record(entry)
    if record then
        return { record }
    end
    return stop_feedback_records(entry)
end

return M
