--- Splitting submitted prompt text into the blocks that dispatch as separate
--- turns: one line per `/command`, and each run of everything else as prose.
---
--- "Block" here is a span of input lines. It is unrelated to the rendered
--- tool-call blocks of `utils/extmark_block.lua` and the region vocabulary of
--- the chat buffer.
--- @class agentic.utils.PromptBlocks
local M = {}

--- @class agentic.utils.PromptBlocks.Block
--- @field text string What to dispatch: edge blank lines and trailing whitespace removed
--- @field sr integer 0-indexed first line, relative to the lines that were split
--- @field er integer 0-indexed last line, inclusive

--- The command word text begins with, or nil when it is prose.
---
--- The boundary is the one `syntax/AgenticChat.vim` highlights: a leading `/`,
--- a word of `[%w_-]`, then whitespace or the end of the line. Requiring that
--- boundary is what keeps paths out — `/usr/bin/env` ends its word at `/`, so
--- it is prose. Leading whitespace disqualifies a line too, which is the
--- escape hatch for sending a `/`-leading line to the model.
---
--- Multi-line text is never a command, so an argument cannot absorb the line
--- below it.
--- @param text string
--- @return string|nil word Without the leading slash
--- @return string arg Trimmed; empty when the command took none
function M.command(text)
    local word, rest = text:match("^/([%w_-]+)([^\n]*)$")
    if not word or (rest ~= "" and not rest:match("^%s")) then
        return nil, ""
    end
    return word, vim.trim(rest)
end

--- Drop the blank lines around a run of lines and any trailing whitespace,
--- keeping the first content line's indentation.
---
--- The indentation is load-bearing: an indented `/word` is prose only for as
--- long as it stays indented, since the local parser and both providers anchor
--- their interception at the line's first character.
--- @param lines string[]
--- @return string
function M.trim_lines(lines)
    local first, last = 1, #lines
    while first <= last and lines[first]:match("^%s*$") do
        first = first + 1
    end
    while last >= first and lines[last]:match("^%s*$") do
        last = last - 1
    end
    return (table.concat(lines, "\n", first, last):gsub("%s+$", ""))
end

--- Split submitted lines into the blocks that dispatch as separate turns.
---
--- A command block is exactly one line: its argument goes on its own line, so
--- `/compact\nFocus on X` is a command and a prose block. Consecutive
--- non-command lines form one prose block, which keeps a prose-only submit a
--- single block — the common case dispatches byte-identically to a submit that
--- was never split. Blocks holding no printable content are dropped.
---
--- A block carries no kind: `M.command` on its text answers that, and answers
--- it the same way for text that never went through a split. Which is why the
--- trim keeps the first line's indentation — it is the whole difference
--- between a prose block and a command one.
--- @param lines string[]
--- @return agentic.utils.PromptBlocks.Block[]
function M.split(lines)
    --- @type agentic.utils.PromptBlocks.Block[]
    local blocks = {}
    --- @type string[]|nil
    local prose
    local prose_sr = 0

    --- @param er integer Last line of the prose run
    local function flush(er)
        if not prose then
            return
        end
        local text = M.trim_lines(prose)
        if text ~= "" then
            table.insert(blocks, { text = text, sr = prose_sr, er = er })
        end
        prose = nil
    end

    for i, line in ipairs(lines) do
        local row = i - 1
        if M.command(line) then
            flush(row - 1)
            table.insert(
                blocks,
                { text = (line:gsub("%s+$", "")), sr = row, er = row }
            )
        else
            if not prose then
                prose = {}
                prose_sr = row
            end
            table.insert(prose, line)
        end
    end
    flush(#lines - 1)

    return blocks
end

return M
