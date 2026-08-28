--- Decoder for the hook records the Claude Code CLI writes to its transcript
--- jsonl (`~/.claude/projects/<slug>/<session-id>.jsonl`). The ACP bridge drops
--- the hook lifecycle events, so the transcript is the only channel carrying
--- what a hook injected, printed or how it failed.
---
--- Pure and stateless: one line in, one record out. Cross-record work — the
--- `parentUuid` join that attributes a body to a script, offsets, session
--- teardown — belongs to `agentic.hook_record_reader`.
local M = {}

--- @alias agentic.acp.HookRecordGroup
--- | "context" context a hook delivered to the model
--- | "unrecognised" output in a schema we do not know, surfaced rather than dropped
--- | "failure" timed out, or exited non-zero with real stderr
--- | "silent" ran with nothing to show; carried only so its `command` can attribute a later record
--- | "verbatim" the transcript line itself did not parse

--- @class agentic.acp.HookRecord
--- @field group agentic.acp.HookRecordGroup
--- @field body string[]
--- @field uuid? string
--- @field parent_uuid? string
--- @field timestamp? string ISO-8601 UTC, fixed width so string order is time order
--- @field command? string the hook script's invocation
--- @field script? string basename of the script the body came from; filled in by the reader, which owns the `parentUuid` join

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
    if type(text) ~= "string" or text == "" then
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
--- @return agentic.acp.HookRecordGroup|nil group nil when the attachment is not a hook record
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

--- Decode one transcript line into a hook record. A line that is not valid JSON
--- still yields a record, in the `verbatim` group: a transcript this decoder
--- cannot read is the thing least safe to drop.
--- @param line string one raw line of the transcript jsonl
--- @return agentic.acp.HookRecord|nil record nil for a line that carries no hook activity
function M.decode(line)
    if line:match("^%s*$") then
        return nil
    end

    local ok, entry = pcall(vim.json.decode, line)
    if not ok or type(entry) ~= "table" then
        --- @type agentic.acp.HookRecord
        local unparsed = { group = "verbatim", body = { line } }
        return unparsed
    end

    -- Every hook record is nested under an attachment; the CLI writes no
    -- top-level hook envelope. `hookEvent` is what separates them from the
    -- other attachment kinds (pasted images, file contents).
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

    --- @type agentic.acp.HookRecord
    local record = {
        group = group,
        body = body,
        uuid = entry.uuid,
        parent_uuid = entry.parentUuid,
        timestamp = entry.timestamp,
        command = attachment.command,
    }
    return record
end

return M
