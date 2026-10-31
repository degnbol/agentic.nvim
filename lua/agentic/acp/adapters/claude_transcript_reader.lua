local ClaudeTranscriptRecords =
    require("agentic.acp.adapters.claude_transcript_records")
local FileSystem = require("agentic.utils.file_system")
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

--- Tails one ACP session's Claude Code transcript jsonl for what the ACP
--- bridge does not forward: hook activity, and files the CLI loaded into the
--- model's context without a tool call. One reader per session.
---
--- Drains are empty until a transcript path is set. Records that predate the
--- reader are discarded, so the first drain of a resumed session does not
--- replay its history.
--- @class agentic.acp.ClaudeTranscriptReader
--- @field _marker string ISO-8601 UTC; records at or after it belong to this reader
--- @field _path? string
--- @field _offset integer bytes of `_path` already drained
--- @field _catching_up boolean True until the first successful read of a newly discovered path; that read is the only one whose bytes can predate this reader
--- @field _links table<string, agentic.acp.TranscriptLink> entry uuid -> the link ending its chain, shared by every entry on that chain; `NO_PLACE` for a chain with no known end
--- @field _commands table<string, string> entry uuid -> the hook command it ran
--- @field _notified boolean
local ClaudeTranscriptReader = {}
ClaudeTranscriptReader.__index = ClaudeTranscriptReader

--- @return agentic.acp.ClaudeTranscriptReader
function ClaudeTranscriptReader:new()
    return setmetatable({
        -- Same fixed-width format the CLI writes, so records compare as strings.
        _marker = os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
        _offset = 0,
        _catching_up = true,
        _links = {},
        _commands = {},
        _notified = false,
    }, self)
end

--- Point the reader at a transcript, read from its top on the next drain.
--- @param path string
function ClaudeTranscriptReader:set_transcript_path(path)
    self._path = path
    self._offset = 0
    self._catching_up = true
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

--- Record an entry's link, and the hook command it ran.
--- @param link agentic.acp.TranscriptLink
function ClaudeTranscriptReader:_index(link)
    if link.command then
        self._commands[link.uuid] = link.command
    end
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
--- Hook records whose group is `silent` are consumed rather than returned: they
--- have nothing to show, and exist here only to name the script a later
--- `context` record came from.
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
    -- Before the currency test: a record can belong to a prompt or a hook run
    -- written just before this reader started.
    if link then
        self:_index(link)
    end
    local place = link and self._links[link.uuid] or NO_PLACE
    local parent_uuid = link and link.parent_uuid

    for _, record in ipairs(ClaudeTranscriptRecords.records(entry)) do
        if self:_is_current(record) then
            local side
            if record.kind == "hook" then
                side = self:_hook_side_record(record, place, parent_uuid)
            else
                side = self:_loaded_file_side_record(record, place)
            end
            if side then
                table.insert(records, side)
            end
        end
    end
    return records
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

--- A hook record as a side record, named after its script. One that names no
--- tool call takes the anchor of its chain instead. Sets those fields on
--- `record` itself.
--- @param record agentic.acp.ClaudeHookRecord
--- @param place agentic.acp.TranscriptLink The link ending the record's chain
--- @param parent_uuid string|nil
--- @return agentic.acp.SideRecord|nil side nil for a `silent` record
function ClaudeTranscriptReader:_hook_side_record(record, place, parent_uuid)
    if record.group == "silent" then
        return nil
    end
    record.script = self:_script_of(record, parent_uuid)
    if not is_tool_call_id(record.tool_call_id) then
        local anchor = anchor_of(place)
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

--- Basename of the script a record's body came from, else the hook's
--- configured name, nil when neither is recorded. A record that ran a script
--- names its own; injected context points at its producer through
--- `parentUuid`. `UserPromptSubmit` context records point at no producer, so
--- only their hook name is left.
--- @param record agentic.acp.ClaudeHookRecord
--- @param parent_uuid string|nil `parentUuid` of the record's entry
--- @return string|nil
function ClaudeTranscriptReader:_script_of(record, parent_uuid)
    local command = record.command
    if not command and parent_uuid then
        command = self._commands[parent_uuid]
    end
    return command and vim.fs.basename(command) or record.hook_name
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
        "Claude transcript unreadable, hook activity and loaded files will not show: "
            .. (err or "unknown error")
    )
end

return ClaudeTranscriptReader
