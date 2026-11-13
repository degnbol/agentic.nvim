local CanonicalToolCall = require("agentic.acp.canonical_tool_call")
local Duration = require("agentic.utils.duration")
local MarkdownGuard = require("agentic.utils.markdown_guard")
local TextWrap = require("agentic.utils.text_wrap")

--- The run times of tool calls, told to the agent in a prompt.
--- @class agentic.ToolTimings
local M = {}

--- A `<tool_timings>` prompt block listing each reported call, longest
--- first: its id, kind, the first line of its argument cut to 80 columns,
--- its run time and status word. A call with no block gets its id and time
--- only.
--- @param reports agentic.ui.RunClocks.Report[]
--- @param blocks table<string, agentic.ui.MessageWriter.ToolCallBlock> By tool call id
--- @param threshold_ms integer The threshold the reports were cut at, named in the block's intro line
--- @return string|nil text nil for no reports
function M.prompt_text(reports, blocks, threshold_ms)
    if #reports == 0 then
        return nil
    end
    local sorted = vim.list_extend({}, reports)
    table.sort(sorted, function(a, b)
        return a.ms > b.ms
    end)

    local lines = {
        "<tool_timings>",
        string.format(
            "Run time the editor measured for your tool calls that took %s or longer since the previous prompt:",
            Duration.format_ms(threshold_ms)
        ),
    }
    for _, report in ipairs(sorted) do
        local block = blocks[report.id]
        local time = Duration.format_ms(report.ms)
        if block then
            local argument = vim.split(block.argument or "", "\n")[1]
            table.insert(
                lines,
                string.format(
                    "- %s %s %s: %s, %s",
                    report.id,
                    block.kind,
                    MarkdownGuard.whole_within(
                        TextWrap.truncate_to_width(argument, 80),
                        math.huge
                    ),
                    time,
                    CanonicalToolCall.status_word(block)
                )
            )
        else
            table.insert(lines, string.format("- %s: %s", report.id, time))
        end
    end
    table.insert(lines, "</tool_timings>")
    return table.concat(lines, "\n")
end

return M
