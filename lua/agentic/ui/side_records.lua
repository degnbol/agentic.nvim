local FileSystem = require("agentic.utils.file_system")
local MarkdownGuard = require("agentic.utils.markdown_guard")
local ShellParse = require("agentic.utils.shell_parse")

--- @class agentic.ui.SideRecords
local SideRecords = {}

--- A duration for reading at a glance: milliseconds below a second, then
--- seconds to one decimal.
--- @param ms number
--- @return string
local function format_duration(ms)
    if ms < 1000 then
        return ("%d ms"):format(ms)
    end
    return ("%.1f s"):format(ms / 1000)
end

--- @type table<agentic.acp.HookOutcome, string>
local OUTCOME_WORDS = {
    blocked = "blocked",
    stopped = "stopped the turn",
    allowed = "allowed",
    denied = "denied",
    asked = "asked",
    deferred = "deferred",
}

--- The text naming a hook: the path its command runs as one code span, else
--- the command as one, else its `hook_name`, else `hook`. An absolute or `~`
--- path is shown smart; a relative one verbatim, as it is relative to the
--- hook's cwd, not the editor's.
--- @param record agentic.acp.HookRecord
--- @return string
local function hook_label(record)
    if not record.command then
        return record.hook_name or "hook"
    end
    local path = ShellParse.leading_path(record.command)
    if path and (vim.startswith(path, "/") or vim.startswith(path, "~/")) then
        path = FileSystem.to_smart_path(path)
    end
    -- One row: a code span renders a line ending as a space anyway.
    local shown = path or record.command:gsub("\r?\n", " ")
    return MarkdownGuard.whole_within(shown, math.huge)
end

--- One row naming a hook record, then ` · <outcome>` and ` · <duration>` for
--- those recorded.
--- @param record agentic.acp.HookRecord
--- @return string
local function hook_title(record)
    local title = hook_label(record)
    if record.outcome then
        title = title .. " · " .. OUTCOME_WORDS[record.outcome]
    end
    if record.duration_ms then
        title = title .. " · " .. format_duration(record.duration_ms)
    end
    return title
end

--- The record kinds `SideRecords.write` writes.
--- @type table<string, true>
SideRecords.KINDS =
    { hook = true, loaded_file = true, discovered_skills = true }

--- Write hook, loaded-file and discovered-skills records to `writer` in the
--- order given, each at the anchor it names. A hook run with no body to read
--- is one row: one that passed, failed or acted (`outcome`). Records of other
--- kinds are not written.
--- @param writer agentic.ui.MessageWriter
--- @param records agentic.acp.SideRecord[]
function SideRecords.write(writer, records)
    for _, side in ipairs(records) do
        if side.kind == "loaded_file" then
            writer:write_loaded_file(side.loaded_file)
        elseif side.kind == "discovered_skills" then
            writer:write_discovered_skills(side.discovered_skills)
        elseif side.kind == "hook" then
            local record = side.hook
            local failed = record.group == "failure"
            local is_run = record.group == "passed"
                or failed
                or record.outcome ~= nil
            if is_run and #record.body == 0 then
                writer:write_hook_row({
                    text = hook_title(record),
                    tool_call_id = record.tool_call_id,
                    after_prompt = record.after_prompt,
                    after_compaction = record.after_compaction,
                    failed = failed,
                })
            else
                writer:write_hook_block({
                    body = record.body,
                    title = hook_title(record),
                    tool_call_id = record.tool_call_id,
                    after_prompt = record.after_prompt,
                    after_compaction = record.after_compaction,
                    failed = failed,
                    for_user = record.group == "message",
                })
            end
        end
    end
end

return SideRecords
