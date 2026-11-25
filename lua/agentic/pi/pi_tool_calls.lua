local FileSystem = require("agentic.utils.file_system")

--- Tool call blocks from pi's tool execution events.
--- @class agentic.pi.PiToolCalls
local M = {}

--- @type table<string, agentic.acp.ToolKind>
local KINDS = {
    bash = "execute",
    read = "read",
    edit = "edit",
    write = "edit",
    grep = "search",
    find = "search",
    ls = "search",
}

--- The ACP tool kind of a pi tool.
--- @param tool_name string
--- @return agentic.acp.ToolKind
function M.kind(tool_name)
    return KINDS[tool_name] or "other"
end

--- The absolute path a pi tool reads `path` as: a leading `@` dropped, `~`
--- expanded, relative to `cwd`.
--- @param path string
--- @param cwd string Absolute
--- @return string
function M.resolve_path(path, cwd)
    return FileSystem.resolve((path:gsub("^@", "")), cwd)
end

--- The text parts of a tool result, as lines.
--- @param result table|nil pi's `AgentToolResult`
--- @return string[]
local function result_lines(result)
    local texts = {}
    for _, part in ipairs(result and result.content or {}) do
        if part.type == "text" then
            table.insert(texts, part.text)
        end
    end
    return vim.split(table.concat(texts, "\n"), "\n", { plain = true })
end

--- The block a `tool_execution_start` event opens.
--- @param event table `{ toolCallId, toolName, args }`
--- @param cwd string Absolute working directory of the session
--- @return agentic.ui.MessageWriter.ToolCallBlock
function M.from_start(event, cwd)
    local name = event.toolName
    local args = type(event.args) == "table" and event.args or {}
    local argument
    if name == "bash" then
        argument = args.command
    elseif name == "grep" or name == "find" then
        argument = args.pattern
    elseif type(args.path) == "string" then
        argument = M.resolve_path(args.path, cwd)
    end

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local block = {
        tool_call_id = event.toolCallId,
        kind = M.kind(name),
        argument = type(argument) == "string" and argument or name,
        status = "pending",
    }
    if name == "read" and args.offset then
        block.read_range = { offset = args.offset, limit = args.limit }
    elseif name == "grep" then
        block.search_pattern = args.pattern
    elseif name == "write" and type(args.content) == "string" then
        block.diff = {
            old = {},
            new = vim.split(args.content, "\n", { plain = true }),
        }
    end
    return block
end

--- The update a `tool_execution_end` event gives. A failed call without
--- `durationMs` never ran (invalid arguments, an unknown tool, a block): its
--- first result line is the rejection.
--- @param event table `{ toolCallId, toolName, result, isError, durationMs? }`
--- @return agentic.ui.MessageWriter.ToolCallBase
function M.from_end(event)
    local lines = result_lines(event.result)
    --- @type agentic.ui.MessageWriter.ToolCallBase
    local update = {
        tool_call_id = event.toolCallId,
        status = event.isError and "failed" or "completed",
    }
    if event.isError and event.durationMs == nil then
        update.rejection = table.remove(lines, 1)
        update.failure_reason = #lines > 0 and lines or nil
    elseif event.isError then
        update.failure_reason = lines
    elseif event.toolName ~= "edit" and event.toolName ~= "write" then
        update.body = lines
    end
    return update
end

--- The one diff pair covering every replacement of an edit call: `old` is the
--- file's lines from the first replacement's line to the last one's, `new` is
--- those lines with every replacement applied.
--- @param input table The edit call's input after pi's normalisation: `{ path, edits = { { oldText, newText }, ... } }`
--- @param cwd string Absolute working directory of the session
--- Matching is exact, while pi's edit tool also matches after normalising
--- the text (`fuzzyFindText` in pi's `edit-diff.ts`), so an edit pi applies
--- can get no diff here.
--- @return agentic.ui.MessageWriter.ToolCallDiff|nil diff Nil when the file cannot be read or an `oldText` is not in it
function M.edit_diff(input, cwd)
    if type(input.path) ~= "string" or type(input.edits) ~= "table" then
        return nil
    end
    local file_lines =
        FileSystem.read_from_disk(M.resolve_path(input.path, cwd))
    if not file_lines then
        return nil
    end
    local content = table.concat(file_lines, "\n")

    --- @type { first: integer, last: integer, new_text: string }[]
    local spans = {}
    for _, edit in ipairs(input.edits) do
        local old_text = edit.oldText
        local first = type(old_text) == "string"
            and old_text ~= ""
            and content:find(old_text, 1, true)
        if not first then
            return nil
        end
        table.insert(spans, {
            first = first,
            last = first + #old_text - 1,
            new_text = edit.newText or "",
        })
    end
    if #spans == 0 then
        return nil
    end
    table.sort(spans, function(a, b)
        return a.first < b.first
    end)

    local span_first = spans[1].first
    local span_last = 0
    for _, span in ipairs(spans) do
        span_last = math.max(span_last, span.last)
    end
    -- Widen to whole lines.
    local line_first = span_first
    while
        line_first > 1
        and content:sub(line_first - 1, line_first - 1) ~= "\n"
    do
        line_first = line_first - 1
    end
    local line_last = (content:find("\n", span_last + 1, true) or #content + 1)
        - 1

    local pieces = {}
    local at = line_first
    for _, span in ipairs(spans) do
        table.insert(pieces, content:sub(at, span.first - 1))
        table.insert(pieces, span.new_text)
        at = span.last + 1
    end
    table.insert(pieces, content:sub(at, line_last))

    --- @type agentic.ui.MessageWriter.ToolCallDiff
    local diff = {
        old = vim.split(
            content:sub(line_first, line_last),
            "\n",
            { plain = true }
        ),
        new = vim.split(table.concat(pieces), "\n", { plain = true }),
    }
    return diff
end

return M
