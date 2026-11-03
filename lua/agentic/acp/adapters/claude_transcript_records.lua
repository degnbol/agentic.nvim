--- Decoder for the records the Claude Code CLI writes to its transcript jsonl
--- (`~/.claude/projects/<slug>/<session-id>.jsonl`) about what the ACP bridge
--- does not forward.
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
--- @field detail? string The full content of an error during execution, of which `body` holds only the leading prose

--- @class agentic.acp.ClaudeLoadedFileRecord
--- @field kind "loaded_file"
--- @field path string Absolute
--- @field is_mention boolean An `@` file, not a rule
--- @field timestamp? string

--- @class agentic.acp.ClaudeDiscoveredSkillsRecord
--- @field kind "discovered_skills"
--- @field title string
--- @field body string[] One `- <name>` row per skill
--- @field timestamp? string

--- @class agentic.acp.ClaudeToolUseRecord
--- @field kind "tool_use"
--- @field tool_call_id string
--- @field tool_name string
--- @field input table
--- @field timestamp? string

--- @class agentic.acp.ClaudePeerMessageRecord
--- @field kind "peer_message"
--- @field message_id string `origin.msg_id` of a message from another session, else the entry's `uuid`
--- @field text string The message without the CLI's wrapper
--- @field sender_id? string `origin.senderTaskId`: the agent id of a subagent sender
--- @field sender_name? string The display name the CLI gave the sender
--- @field timestamp? string

--- What a transcript entry says about where a load under it belongs.
--- @class agentic.acp.TranscriptLink
--- @field uuid string
--- @field parent_uuid? string
--- @field ends_chain boolean A `tool_result` record, a meta record with `sourceToolUseID`, a compaction's output, a user-text record, a `queued_command` attachment, or an `assistant` record
--- @field tool_call_id? string `tool_use_id` of a `tool_result` record, or `sourceToolUseID` of a meta record
--- @field after_prompt boolean Ends the chain at the prompt: user text or a `queued_command` the user sent
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

--- @param value any
--- @return string|nil
local function string_or_nil(value)
    return type(value) == "string" and value or nil
end

--- The `hookSpecificOutput` a hook's stdout carries as JSON. Stdout that is
--- not JSON is the common case, not an error.
--- @param stdout any
--- @return table|nil specific nil when `stdout` is not JSON carrying a `hookSpecificOutput` table
local function hook_specific_output(stdout)
    if type(stdout) ~= "string" then
        return nil
    end
    local ok, output = pcall(vim.json.decode, stdout)
    local specific = ok
        and type(output) == "table"
        and output.hookSpecificOutput
    return type(specific) == "table" and specific or nil
end

--- The `hookSpecificOutput.additionalContext` a hook's stdout carries as JSON.
--- @param stdout any
--- @return string|nil context nil when `stdout` is not JSON carrying a string context
local function json_context(stdout)
    local specific = hook_specific_output(stdout)
    return specific and string_or_nil(specific.additionalContext)
end

--- The `blockingError` table of a hook attachment.
--- @param attachment table
--- @return table blocking empty when the attachment has none
local function blocking_error_of(attachment)
    return type(attachment.blockingError) == "table"
            and attachment.blockingError
        or {}
end

--- The reason a `hook_blocking_error` carries, without the `[<command>]: `
--- prefix the CLI puts on it.
--- @param blocking table the attachment's `blockingError`
--- @return string[]
local function blocking_error_body(blocking)
    local text = blocking.blockingError
    if type(text) ~= "string" then
        return {}
    end
    -- The known command, not `split_command`: its non-greedy match ends early
    -- on a command that holds `]: `.
    if type(blocking.command) == "string" then
        local prefix = "[" .. blocking.command .. "]: "
        if vim.startswith(text, prefix) then
            text = text:sub(#prefix + 1)
        end
    end
    return body_lines(text)
end

--- The prose a diagnostic leads with: its lines up to the JSON dump that
--- follows, which opens on a line that starts or ends with `[` or `{`.
--- @param content any
--- @return string[]
local function prose_lines(content)
    --- @type string[]
    local lines = {}
    for _, line in ipairs(body_lines(content)) do
        if line:match("^%s*[%[{]") then
            break
        end
        local before_dump = line:match("^(.-)%s*[%[{]%s*$")
        table.insert(lines, before_dump or line)
        if before_dump then
            break
        end
    end
    return lines
end

--- Outcomes of a hook's permission decision. `defer` is left out: the CLI
--- records a deferral as a `hook_deferred_tool` attachment.
--- @type table<string, agentic.acp.HookOutcome>
local PERMISSION_OUTCOMES =
    { allow = "allowed", deny = "denied", ask = "asked" }

--- The `hookSpecificOutput.permissionDecision` a hook's stdout carries as
--- JSON, as an outcome.
--- @param stdout any
--- @return agentic.acp.HookOutcome|nil outcome nil when `stdout` is not JSON carrying an allow, deny or ask
local function permission_outcome(stdout)
    local specific = hook_specific_output(stdout)
    return specific and PERMISSION_OUTCOMES[specific.permissionDecision]
end

--- How a hook attachment shows.
--- @class agentic.acp.ClaudeHookClassification
--- @field group agentic.acp.ClaudeHookRecordGroup
--- @field body string[]
--- @field outcome? agentic.acp.HookOutcome
--- @field detail? string

--- @param attachment table any hook attachment but `hook_additional_context`
--- @return agentic.acp.ClaudeHookClassification|nil classification nil when the attachment is not a hook record
local function classify(attachment)
    local kind = attachment.type

    if kind == "hook_success" then
        local body = body_lines(attachment.content)
        if #body == 0 then
            local context = body_lines(json_context(attachment.stdout))
            if #context > 0 then
                return { group = "context_run", body = context }
            end
            return {
                group = "passed",
                body = body,
                outcome = permission_outcome(attachment.stdout),
            }
        end
        if STDOUT_CONTEXT_EVENTS[attachment.hookEvent] then
            return { group = "context", body = body }
        end
        return { group = "stray", body = body }
    end

    if kind == "hook_non_blocking_error" then
        if attachment.stderr == NO_STDERR then
            return { group = "passed", body = {} }
        end
        return { group = "failure", body = failure_body(attachment) }
    end

    if kind == "hook_cancelled" then
        -- Not timed out: the turn was cancelled while the hook ran, or the
        -- hook was skipped inside an agent a hook spawned (no `timedOut`).
        if attachment.timedOut ~= true then
            return nil
        end
        return { group = "failure", body = failure_body(attachment) }
    end

    if kind == "hook_blocking_error" then
        return {
            group = "context",
            body = blocking_error_body(blocking_error_of(attachment)),
            outcome = "blocked",
        }
    end

    if kind == "hook_stopped_continuation" then
        return {
            group = "context",
            body = body_lines(attachment.message),
            outcome = "stopped",
        }
    end

    if kind == "hook_system_message" then
        return { group = "message", body = body_lines(attachment.content) }
    end

    if kind == "hook_error_during_execution" then
        return {
            group = "failure",
            body = prose_lines(attachment.content),
            detail = type(attachment.content) == "string"
                    and attachment.content
                or nil,
        }
    end

    if kind == "hook_permission_decision" then
        return {
            group = "passed",
            body = {},
            outcome = PERMISSION_OUTCOMES[attachment.decision],
        }
    end

    if kind == "hook_deferred_tool" then
        return { group = "passed", body = {}, outcome = "deferred" }
    end

    return nil
end

--- The command a hook attachment ran and the name it goes by.
--- @param attachment table
--- @return string|nil command
--- @return string|nil hook_name the configured name, else the event; for a deferral `<event>:<tool>`, as its `hookName` names a config source
local function hook_identity(attachment)
    local command = string_or_nil(attachment.command)
        or string_or_nil(blocking_error_of(attachment).command)
    local event = string_or_nil(attachment.hookEvent)
    local tool = string_or_nil(attachment.toolName)
    if attachment.type == "hook_deferred_tool" then
        return command, event and tool and event .. ":" .. tool or event
    end
    return command, string_or_nil(attachment.hookName) or event
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

    --- @type agentic.acp.ClaudeHookClassification[]
    local classifications
    if attachment.type == "hook_additional_context" then
        local content = attachment.content
        classifications = vim.tbl_map(function(element)
            return { group = "context", body = body_lines(element) }
        end, type(content) == "table" and content or { content })
    else
        classifications = { classify(attachment) }
    end

    local command, hook_name = hook_identity(attachment)
    for _, classification in ipairs(classifications) do
        table.insert(records, {
            kind = "hook",
            group = classification.group,
            body = classification.body,
            outcome = classification.outcome,
            detail = classification.detail,
            timestamp = entry.timestamp,
            command = command,
            hook_name = hook_name,
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

--- The text the CLI gives the model for a `dynamic_skill` attachment, above
--- one `- <name>` row per skill. `%s` is the attachment's `displayPath`.
--- Version-coupled to the CLI: recheck the wording on a bump.
local DISCOVERED_SKILLS_TITLE =
    "New skills discovered in %s, now available via the Skill tool:"

--- The skills a transcript entry's `dynamic_skill` attachment made available.
---
--- The CLI rebuilds the model's text from the attachment on each request, and
--- drops it when `skillDir` is no longer under the current project root, so
--- after a project root change the model may not have received this record.
--- @param entry table one decoded transcript line
--- @return agentic.acp.ClaudeDiscoveredSkillsRecord|nil record nil when the entry carries none
local function discovered_skills_record(entry)
    local attachment = entry.attachment
    if
        entry.type ~= "attachment"
        or type(attachment) ~= "table"
        or attachment.type ~= "dynamic_skill"
        or type(attachment.displayPath) ~= "string"
        or type(attachment.skillNames) ~= "table"
    then
        return nil
    end
    local body = {}
    for _, name in ipairs(attachment.skillNames) do
        if type(name) == "string" then
            table.insert(body, "- " .. name)
        end
    end
    if #body == 0 then
        return nil
    end

    --- @type agentic.acp.ClaudeDiscoveredSkillsRecord
    local record = {
        kind = "discovered_skills",
        title = DISCOVERED_SKILLS_TITLE:format(attachment.displayPath),
        body = body,
        timestamp = entry.timestamp,
    }
    return record
end

--- One record per `tool_use` block of an assistant entry.
--- @param entry table one decoded transcript line
--- @return agentic.acp.ClaudeToolUseRecord[] records empty when the entry is not an assistant entry calling a tool
local function tool_use_records(entry)
    --- @type agentic.acp.ClaudeToolUseRecord[]
    local records = {}
    local content = entry.type == "assistant"
        and type(entry.message) == "table"
        and entry.message.content
    if type(content) ~= "table" then
        return records
    end
    for _, block in ipairs(content) do
        if
            type(block) == "table"
            and block.type == "tool_use"
            and type(block.id) == "string"
            and type(block.name) == "string"
            and type(block.input) == "table"
        then
            table.insert(records, {
                kind = "tool_use",
                tool_call_id = block.id,
                tool_name = block.name,
                input = block.input,
                timestamp = entry.timestamp,
            })
        end
    end
    return records
end

--- The `origin` of a message another session or a subagent sent: on a user
--- entry when the message starts a turn, on a `queued_command` attachment
--- when it arrives while the session is busy.
--- @param entry table one decoded transcript line
--- @return table|nil origin nil when the entry is not a peer message
local function peer_origin(entry)
    local origin
    if entry.type == "user" then
        origin = entry.origin
    elseif
        entry.type == "attachment"
        and type(entry.attachment) == "table"
        and entry.attachment.type == "queued_command"
    then
        origin = entry.attachment.origin
    end
    if type(origin) ~= "table" or origin.kind ~= "peer" then
        return nil
    end
    return origin
end

--- The message a transcript entry carries from another session or a
--- subagent. A subagent's handback is not one: it is its run's result.
--- @param entry table one decoded transcript line
--- @return agentic.acp.ClaudePeerMessageRecord|nil record nil when the entry carries none
local function peer_message_record(entry)
    local origin = peer_origin(entry)
    local message_id = origin
        and (string_or_nil(origin.msg_id) or string_or_nil(entry.uuid))
    if
        not origin
        or origin.handback == true
        or type(origin.body) ~= "string"
        or not message_id
    then
        return nil
    end

    --- @type agentic.acp.ClaudePeerMessageRecord
    local record = {
        kind = "peer_message",
        message_id = message_id,
        text = origin.body,
        sender_id = string_or_nil(origin.senderTaskId),
        sender_name = string_or_nil(origin.name),
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

--- @alias agentic.acp.ClaudeTranscriptRecord
--- | agentic.acp.ClaudeHookRecord
--- | agentic.acp.ClaudeLoadedFileRecord
--- | agentic.acp.ClaudeDiscoveredSkillsRecord
--- | agentic.acp.ClaudeToolUseRecord
--- | agentic.acp.ClaudePeerMessageRecord

--- The records a transcript entry carries.
--- @param entry table one decoded transcript line
--- @return agentic.acp.ClaudeTranscriptRecord[] records empty for an entry that carries none
function M.records(entry)
    local loaded_file = loaded_file_record(entry)
    if loaded_file then
        return { loaded_file }
    end
    local discovered_skills = discovered_skills_record(entry)
    if discovered_skills then
        return { discovered_skills }
    end
    local peer_message = peer_message_record(entry)
    if peer_message then
        return { peer_message }
    end
    local hooks = attachment_records(entry)
    if #hooks > 0 then
        return hooks
    end
    local tool_uses = tool_use_records(entry)
    if #tool_uses > 0 then
        return tool_uses
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
            local from_user = peer_origin(entry) == nil
            link.ends_chain = true
            link.after_prompt = from_user
            link.user_text = from_user
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
