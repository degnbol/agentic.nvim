local ClaudeHookRecords = require("agentic.acp.adapters.claude_hook_records")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

--- Tails one ACP session's Claude Code transcript jsonl for hook activity.
---
--- Hook lifecycle events never reach the client — the ACP bridge drops them —
--- so the CLI's transcript is the channel. One reader per session.
---
--- The transcript path is not known up front: it arrives on the plugin's own
--- PreToolUse hook input, which fires on the first tool call its matcher covers
--- and may be several turns in. A session that never trips that matcher, or a
--- provider other than Claude, never supplies one and every drain stays empty.
--- Records that predate the reader are discarded, so the first drain of a
--- resumed session does not replay its history.
--- @class agentic.HookRecordReader
--- @field _marker string ISO-8601 UTC; records at or after it belong to this reader
--- @field _path? string
--- @field _offset integer bytes of `_path` already drained
--- @field _catching_up boolean True until the first successful read of a newly discovered path; that read is the only one whose bytes can predate this reader
--- @field _commands table<string, string> record uuid -> the hook command it ran
--- @field _notified boolean
local HookRecordReader = {}
HookRecordReader.__index = HookRecordReader

--- @return agentic.HookRecordReader
function HookRecordReader:new()
    return setmetatable({
        -- Same fixed-width format the CLI writes, so records compare as strings.
        _marker = os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
        _offset = 0,
        _catching_up = true,
        _commands = {},
        _notified = false,
    }, self)
end

--- Point the reader at the transcript a hook reported, if it is this session's.
---
--- A hook that fires inside a subagent reports the subagent's transcript
--- (`<session-id>/subagents/agent-*.jsonl`) under the *parent's* session id, so
--- the id alone cannot tell them apart — the file name can.
--- @param path string `transcript_path` from a hook input
--- @param session_id string the session id that hook input reported
function HookRecordReader:set_transcript_path(path, session_id)
    if path == self._path then
        return
    end
    if vim.fs.basename(path) ~= session_id .. ".jsonl" then
        return
    end
    self._path = path
    self._offset = 0
    self._catching_up = true
end

--- Whether a record is one this reader is responsible for showing.
---
--- A timestamp places the record against the marker directly. A record without
--- one — the `verbatim` group, whose line did not parse and so has no envelope
--- — is placed by the read it came in on instead: only a read that starts from
--- the top of the file can return bytes older than this reader, so everything
--- from any other read is new by construction.
--- @param record agentic.acp.HookRecord
--- @return boolean
function HookRecordReader:_is_current(record)
    if record.timestamp then
        return record.timestamp >= self._marker
    end
    return not self._catching_up
end

--- Read the hook records appended since the last drain.
---
--- Records whose group is `silent` are consumed rather than returned: they ran
--- with nothing to show, and exist here only to name the script a later
--- `context` record came from.
--- @return agentic.acp.HookRecord[] records in transcript order
function HookRecordReader:drain()
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

    --- @type agentic.acp.HookRecord[]
    local records = {}
    for _, line in ipairs(lines) do
        local record = ClaudeHookRecords.decode(line)
        if record then
            -- Index before the currency test: a record can be attributed to a
            -- run that started just before this reader did.
            if record.uuid and record.command then
                self._commands[record.uuid] = record.command
            end
            if record.group ~= "silent" and self:_is_current(record) then
                record.script = self:_script_of(record)
                table.insert(records, record)
            end
        end
    end
    self._catching_up = false
    return records
end

--- Basename of the script a record's body came from, nil when none is
--- recorded. A record that ran a script names its own; injected context points
--- at its producer through `parentUuid`. `UserPromptSubmit` context records
--- point at no producer, and there is no other source for the name.
--- @param record agentic.acp.HookRecord
--- @return string|nil
function HookRecordReader:_script_of(record)
    local command = record.command
    if not command and record.parent_uuid then
        command = self._commands[record.parent_uuid]
    end
    return command and vim.fs.basename(command)
end

--- Tell the user hook activity is lost, once per reader — a transcript that
--- cannot be read fails again on every later drain.
--- @param err string|nil
function HookRecordReader:_notify_unreadable(err)
    if self._notified then
        return
    end
    self._notified = true
    Logger.notify(
        "Hook transcript unreadable, hook activity will not show: "
            .. (err or "unknown error")
    )
end

return HookRecordReader
