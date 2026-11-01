local ClaudeTranscriptRecords =
    require("agentic.acp.adapters.claude_transcript_records")
local ClaudeUtils = require("agentic.acp.adapters.claude_utils")
local FileSystem = require("agentic.utils.file_system")
local List = require("agentic.utils.list")
local Logger = require("agentic.utils.logger")

--- The link of a chain with no known end: it gives what is under it no place.
--- Shared and never written to.
--- @type agentic.acp.TranscriptLink
local NO_PLACE = {
    uuid = "",
    ends_chain = true,
    after_prompt = false,
    after_compaction = false,
    user_text = false,
    injected = false,
}

--- The fields a `SendMessage` tool use adds to its tool call, nil for any
--- other tool.
---
--- The bridge withholds a `SendMessage` call until it ends, then reports it
--- from its first and last notifications, neither of which carries the input
--- (`unexposedControlFallback` in claude-agent-acp's `native-subagents.js`).
--- @param record agentic.acp.ClaudeToolUseRecord
--- @return agentic.acp.SideRecord|nil side
local function tool_use_side_record(record)
    if record.tool_name ~= "SendMessage" then
        return nil
    end
    return {
        kind = "tool_call",
        tool_call = ClaudeUtils.send_message_update(
            record.tool_call_id,
            record.input
        ),
    }
end

--- A peer message as a side record.
--- @param record agentic.acp.ClaudePeerMessageRecord
--- @return agentic.acp.SideRecord side
local function peer_message_side_record(record)
    return {
        kind = "received_message",
        received_message = {
            message_id = record.message_id,
            text = record.text,
            sender_id = record.sender_id,
            sender_name = record.sender_name,
        },
    }
end

--- Tails one Claude Code transcript jsonl, a session's or a subagent's, for
--- records of what the ACP bridge does not forward. One reader per
--- transcript.
---
--- The bridge forwards no peer message: live it forwards only messages a
--- human sent, and a child's `SendMessage` to its parent reaches no announced
--- child (`isRemoteHumanMessage` and `routeRfdSendMessage` in
--- claude-agent-acp).
---
--- Drains are empty until a transcript path is set. Records older than the
--- reader's start time are discarded, so by default the first drain of a
--- resumed session does not replay its history.
--- @class agentic.acp.ClaudeTranscriptReader
--- @field _marker string ISO-8601 UTC; records at or after it belong to this reader
--- @field _path? string
--- @field _offset integer bytes of `_path` already drained
--- @field _catching_up boolean True until the first successful read of a newly discovered path; that read is the only one whose bytes can predate this reader
--- @field _links table<string, agentic.acp.TranscriptLink> entry uuid -> the link ending its chain, shared by every entry on that chain; `NO_PLACE` for a chain with no known end
--- @field _context_runs agentic.acp.ClaudeHookRecord[] `context_run` records no context has paired with yet, oldest first
--- @field _notified boolean
local ClaudeTranscriptReader = {}
ClaudeTranscriptReader.__index = ClaudeTranscriptReader

--- @param since string|nil ISO-8601 UTC time the reader keeps records from, nil for now
--- @return agentic.acp.ClaudeTranscriptReader
function ClaudeTranscriptReader:new(since)
    return setmetatable({
        -- Same fixed-width format the CLI writes, so records compare as strings.
        _marker = since or os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
        _offset = 0,
        _catching_up = true,
        _links = {},
        _context_runs = {},
        _notified = false,
    }, self)
end

--- The time the reader keeps records from.
--- @return string since ISO-8601 UTC
function ClaudeTranscriptReader:since()
    return self._marker
end

--- Point the reader at a transcript, read from its top on the next drain.
--- @param path string
function ClaudeTranscriptReader:set_transcript_path(path)
    self._path = path
    self._offset = 0
    self._catching_up = true
    self._context_runs = {}
end

--- @return boolean
function ClaudeTranscriptReader:has_transcript()
    return self._path ~= nil
end

--- Whether a record is one this reader is responsible for showing.
---
--- A timestamp places the record against the marker directly. A record without
--- one — the `verbatim` group, whose line did not parse and so has no envelope
--- — is placed by the read it came in on instead: only a read that starts from
--- the top of the file can return bytes older than this reader, so everything
--- from any other read is new by construction.
--- @param record { timestamp?: string }
--- @return boolean
function ClaudeTranscriptReader:_is_current(record)
    if record.timestamp then
        return record.timestamp >= self._marker
    end
    return not self._catching_up
end

--- Record an entry's link.
--- @param link agentic.acp.TranscriptLink
function ClaudeTranscriptReader:_index(link)
    if link.ends_chain then
        self._links[link.uuid] = link
        return
    end
    -- The parent's table rather than a copy, so a long transcript read on
    -- catch-up costs one table per chain. An injected entry copies only when
    -- it changes `user_text`.
    local place = link.parent_uuid and self._links[link.parent_uuid] or NO_PLACE
    if link.injected and place.user_text then
        place = vim.tbl_extend("force", place, { user_text = false }) --[[@as agentic.acp.TranscriptLink]]
    end
    self._links[link.uuid] = place
end

--- Read the records appended since the last drain.
---
--- Hook records whose group is `context_run` are consumed rather than
--- returned: the `context` record they pair with shows the same run.
--- @return agentic.acp.SideRecord[] records in transcript order
function ClaudeTranscriptReader:drain()
    if not self._path then
        return {}
    end

    local previous = self._offset
    local lines, offset, err = FileSystem.read_appended(self._path, previous)
    -- Moving backwards means the file was replaced and `read_appended`
    -- restarted at the top, so this read is on the same footing as catch-up:
    -- its bytes can predate the reader.
    if offset < previous then
        self._catching_up = true
    end
    self._offset = offset

    if not lines then
        self:_notify_unreadable(err)
        return {}
    end

    --- @type agentic.acp.SideRecord[]
    local records = {}
    for _, line in ipairs(lines) do
        if not line:match("^%s*$") then
            vim.list_extend(records, self:_read_line(line))
        end
    end
    self._catching_up = false
    return records
end

--- The records of one transcript line that this reader shows. Indexes the
--- line's link.
--- @param line string
--- @return agentic.acp.SideRecord[]
function ClaudeTranscriptReader:_read_line(line)
    --- @type agentic.acp.SideRecord[]
    local records = {}
    local entry = ClaudeTranscriptRecords.parse(line)
    if not entry then
        local record = ClaudeTranscriptRecords.verbatim(line)
        if self:_is_current(record) then
            table.insert(records, { kind = "hook", hook = record })
        end
        return records
    end

    local link = ClaudeTranscriptRecords.link(entry)
    -- Before the currency test: a record can belong to a prompt written just
    -- before this reader started.
    if link then
        self:_index(link)
    end
    local place = link and self._links[link.uuid] or NO_PLACE

    --- @type agentic.acp.ClaudeTranscriptRecord[]
    local entry_records = {}
    for _, record in ipairs(ClaudeTranscriptRecords.records(entry)) do
        if record.kind == "hook" and record.group == "context_run" then
            table.insert(self._context_runs, record)
        else
            table.insert(entry_records, record)
        end
    end
    -- Also before the currency test: a context written before this reader
    -- started consumes its run.
    self:_pair_contexts(entry_records)

    for _, record in ipairs(entry_records) do
        if self:_is_current(record) then
            local side
            if record.kind == "hook" then
                side = self:_hook_side_record(record, place)
            elseif record.kind == "loaded_file" then
                side = self:_loaded_file_side_record(record, place)
            elseif record.kind == "peer_message" then
                side = peer_message_side_record(record)
            elseif record.kind == "discovered_skills" then
                side = self:_discovered_skills_side_record(record, place)
            else
                side = tool_use_side_record(record)
            end
            if side then
                table.insert(records, side)
            end
        end
    end
    return records
end

--- Give each `context` record without a command the `command`,
--- `duration_ms` and `hook_name` of the run in `_context_runs` that produced
--- it, and remove that run from `_context_runs`. The record keeps its own
--- body: it is what the model received.
--- @param records agentic.acp.ClaudeTranscriptRecord[] one entry's records. Paired ones are updated in place
function ClaudeTranscriptReader:_pair_contexts(records)
    -- A context's text equals its run's `additionalContext` unless the CLI
    -- replaced a large one with a pointer, and a SessionStart context's
    -- `toolUseID` differs from its run's. So every record first tries a run
    -- with the same text, and only then does a record still unpaired take a
    -- run with the same tool call id.
    --- @type agentic.acp.ClaudeHookRecord[]
    local contexts = vim.tbl_filter(function(record)
        return record.kind == "hook"
            and record.group == "context"
            and not record.command
    end, records)

    --- @type table<agentic.acp.ClaudeHookRecord, agentic.acp.ClaudeHookRecord>
    local runs = {}
    for _, context in ipairs(contexts) do
        local function same_text(run)
            return run.hook_event == context.hook_event
                and vim.deep_equal(run.body, context.body)
        end
        runs[context] = List.take_first(self._context_runs, function(run)
            return same_text(run) and run.tool_call_id == context.tool_call_id
        end) or List.take_first(self._context_runs, same_text)
    end
    for _, context in ipairs(contexts) do
        runs[context] = runs[context]
            or List.take_first(self._context_runs, function(run)
                return run.hook_event == context.hook_event
                    and run.tool_call_id == context.tool_call_id
            end)
        local run = runs[context]
        if run then
            context.command = run.command
            context.duration_ms = run.duration_ms
            context.hook_name = run.hook_name
        end
    end
end

--- @param id string|nil
--- @return boolean
local function is_tool_call_id(id)
    return type(id) == "string" and vim.startswith(id, "toolu_")
end

--- The anchor a chain ending at `place` gives what is under it.
--- @param place agentic.acp.TranscriptLink
--- @return agentic.acp.Anchor
local function anchor_of(place)
    --- @type agentic.acp.Anchor
    local anchor = {
        tool_call_id = place.tool_call_id,
        after_prompt = place.after_prompt or nil,
        after_compaction = place.after_compaction or nil,
    }
    return anchor
end

--- The anchor of a SessionStart record. Its chain ends at no prompt: the hook
--- ran before the session's first one, so the record is read after the
--- prompt of the turn it is drained in, or after the compaction that fired it.
--- @param hook_name string|nil
--- @return agentic.acp.Anchor
local function session_start_anchor(hook_name)
    local compact = hook_name == "SessionStart:compact"
    --- @type agentic.acp.Anchor
    local anchor = {
        after_prompt = not compact or nil,
        after_compaction = compact or nil,
    }
    return anchor
end

--- A hook record as a side record. One that names no tool call takes an
--- anchor instead: a SessionStart record its own, any other the anchor of its
--- chain, written into `record` itself.
--- @param record agentic.acp.ClaudeHookRecord
--- @param place agentic.acp.TranscriptLink The link ending the record's chain
--- @return agentic.acp.SideRecord side
function ClaudeTranscriptReader:_hook_side_record(record, place)
    if not is_tool_call_id(record.tool_call_id) then
        local anchor = record.hook_event == "SessionStart"
                and session_start_anchor(record.hook_name)
            or anchor_of(place)
        record.tool_call_id = anchor.tool_call_id
        record.after_prompt = anchor.after_prompt
        record.after_compaction = anchor.after_compaction
    end
    return { kind = "hook", hook = record }
end

--- A loaded file as a side record at the anchor of its chain. An `@` file
--- under the user's own text has none: the text already shows the `@path`.
--- @param record agentic.acp.ClaudeLoadedFileRecord
--- @param place agentic.acp.TranscriptLink The link ending the record's chain
--- @return agentic.acp.SideRecord|nil side
function ClaudeTranscriptReader:_loaded_file_side_record(record, place)
    if record.is_mention and place.user_text then
        return nil
    end
    local loaded_file = anchor_of(place) --[[@as agentic.acp.LoadedFile]]
    loaded_file.path = record.path
    return { kind = "loaded_file", loaded_file = loaded_file }
end

--- Discovered skills as a side record at the anchor of their chain.
--- @param record agentic.acp.ClaudeDiscoveredSkillsRecord
--- @param place agentic.acp.TranscriptLink The link ending the record's chain
--- @return agentic.acp.SideRecord side
function ClaudeTranscriptReader:_discovered_skills_side_record(record, place)
    local skills = anchor_of(place) --[[@as agentic.acp.DiscoveredSkills]]
    skills.title = record.title
    skills.body = record.body
    return { kind = "discovered_skills", discovered_skills = skills }
end

--- Tell the user side records are lost, once per reader — a transcript that
--- cannot be read fails again on every later drain.
--- @param err string|nil
function ClaudeTranscriptReader:_notify_unreadable(err)
    if self._notified then
        return
    end
    self._notified = true
    Logger.notify(
        "Claude transcript unreadable, activity it records outside ACP will not show: "
            .. (err or "unknown error")
    )
end

return ClaudeTranscriptReader
