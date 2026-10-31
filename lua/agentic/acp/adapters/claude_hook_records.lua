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
--- | "silent" ran with nothing to show; carried only so its `command` can attribute a later record

--- @class agentic.acp.ClaudeHookRecord : agentic.acp.HookRecord
--- @field group agentic.acp.ClaudeHookRecordGroup
--- @field uuid? string
--- @field parent_uuid? string
--- @field timestamp? string ISO-8601 UTC, fixed width so string order is time order
--- @field command? string the hook script's invocation
--- @field tool_call_id? string what the hook fired on, verbatim from `toolUseID`. Only a `toolu_`-prefixed value is a tool call id: an event with no call to name puts `"SessionStart"`, `hook-<uuid>` or a bare message uuid in the same slot

--- Keys of `stdout.hookSpecificOutput` whose meaning is already accounted for:
--- `permissionDecision` gates a call, `additionalContext` is repeated verbatim
--- as its own `hook_additional_context` record, `updatedInput` rewrites the
--- call. Anything else is unrecognised output.
local KNOWN_OUTPUT_KEYS = {
    "permissionDecision",
    "additionalContext",
    "updatedInput",
}

--- The SDK's stand-in for a non-zero exit that wrote no stderr. Exiting 1 to
--- mean "nothing to say" is the common hook idiom, so a record carrying only
--- this literal is not a failure worth raising. Version-coupled to the CLI —
--- recheck the wording on a bump.
local NO_STDERR = "Failed with non-blocking status code: No stderr output"

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

--- Whether a completed hook's stdout is output we already account for
--- elsewhere.
--- @param stdout string|nil
--- @return boolean
local function is_known_output(stdout)
    if type(stdout) ~= "string" or stdout == "" then
        return false
    end
    local ok, parsed = pcall(vim.json.decode, stdout)
    if not ok or type(parsed) ~= "table" then
        return false
    end
    local output = parsed.hookSpecificOutput
    if type(output) ~= "table" then
        return false
    end
    for _, key in ipairs(KNOWN_OUTPUT_KEYS) do
        if output[key] ~= nil then
            return true
        end
    end
    return false
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
        if is_known_output(attachment.stdout) then
            return "silent", {}
        end
        return "unrecognised", body_lines(attachment.content)
    end

    if kind == "hook_non_blocking_error" then
        if attachment.stderr == NO_STDERR then
            return "silent", {}
        end
        return "failure", body_lines(attachment.stderr)
    end

    if kind == "hook_cancelled" then
        local seconds = math.floor((attachment.timeoutMs or 0) / 1000)
        return "failure",
            { ("no output — the hook timed out after %d s"):format(seconds) }
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
