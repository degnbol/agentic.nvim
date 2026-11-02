local MarkdownGuard = require("agentic.utils.markdown_guard")

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

--- One row naming a hook record: its command as one code span, else its
--- `hook_name`, else `hook`, followed by ` · ` and its duration when one is
--- recorded.
--- @param record agentic.acp.HookRecord
--- @return string
local function hook_title(record)
    -- One row: a code span renders a line ending as a space anyway.
    local command = record.command and record.command:gsub("\r?\n", " ")
    local title = command and MarkdownGuard.whole_within(command, math.huge)
        or record.hook_name
        or "hook"
    if record.duration_ms then
        title = title .. " · " .. format_duration(record.duration_ms)
    end
    return title
end

--- The record kinds `SideRecords.write` writes.
--- @type table<string, true>
SideRecords.KINDS =
    { hook = true, loaded_file = true, discovered_skills = true }

--- Write hook, loaded-file and discovered-skills records to `writer`, each at
--- the anchor it names. Hooks that passed follow the rest, one row each.
--- Records of other kinds are not written.
--- @param writer agentic.ui.MessageWriter
--- @param records agentic.acp.SideRecord[]
function SideRecords.write(writer, records)
    --- @type agentic.acp.HookRecord[]
    local passes = {}
    for _, side in ipairs(records) do
        if side.kind == "loaded_file" then
            writer:write_loaded_file(side.loaded_file)
        elseif side.kind == "discovered_skills" then
            writer:write_discovered_skills(side.discovered_skills)
        elseif side.kind == "hook" then
            local record = side.hook
            if record.group == "passed" then
                table.insert(passes, record)
            else
                writer:write_hook_block({
                    body = record.body,
                    title = hook_title(record),
                    tool_call_id = record.tool_call_id,
                    after_prompt = record.after_prompt,
                    after_compaction = record.after_compaction,
                    failed = record.group == "failure",
                })
            end
        end
    end
    for _, record in ipairs(passes) do
        writer:write_hook_row({
            text = hook_title(record),
            tool_call_id = record.tool_call_id,
            after_prompt = record.after_prompt,
            after_compaction = record.after_compaction,
        })
    end
end

return SideRecords
