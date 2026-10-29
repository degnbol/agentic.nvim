local GrepArgs = require("agentic.utils.grep_args")
local GrepOutput = require("agentic.utils.grep_output")
local GrepRegex = require("agentic.utils.grep_regex")
local Logger = require("agentic.utils.logger")
local ShellParse = require("agentic.utils.shell_parse")

--- Highlight spans on the output of a grep-family tool: the parts of each
--- match row's prefix, and the matches of the searched pattern in its text.
--- @class agentic.utils.GrepHighlights
local M = {}

--- @class agentic.utils.GrepHighlights.Match
--- @field line_index integer 0-based row index
--- @field col_start integer Start column (byte offset)
--- @field col_end integer End column (byte offset, exclusive)
--- @field hl_group? string Highlight group override (default: AgenticSearchMatch)

--- Every grep-family command a shell command line runs, wherever it sits in
--- the line.
--- @param command string shell command line
--- @return agentic.utils.GrepArgs.Invocation[] invocations empty when there
---   is none or the line does not parse
local function grep_invocations_in(command)
    --- @type agentic.utils.GrepArgs.Invocation[]
    local invocations = {}
    for _, rec in ipairs(ShellParse.extract_commands(command) or {}) do
        local invocation = GrepArgs.parse(rec.name, rec.argv, rec.argv_dynamic)
        if invocation then
            table.insert(invocations, invocation)
        end
    end
    return invocations
end

--- Non-overlapping, non-empty matches of a Vim regex in a string.
--- @param text string
--- @param vim_pattern string
--- @param first_only boolean try the first match only, and give none if it is empty
--- @return { [1]: integer, [2]: integer }[]|nil spans 0-based start and
---   exclusive end bytes; nil when matching fails
--- @return string|nil err why matching failed, such as E363 past 'maxmempattern'
local function regex_spans(text, vim_pattern, first_only)
    local spans = {}
    -- With {count} given, matches before {start} are ignored rather than
    -- the text cut there, so `^` still anchors at column 0 (`:help match()`).
    local start = 0
    while true do
        local ok, result =
            pcall(vim.fn.matchstrpos, text, vim_pattern, start, 1)
        if not ok then
            return nil, tostring(result)
        end
        local _, s, e = unpack(result)
        if s < 0 then
            break
        end
        if e > s then
            table.insert(spans, { s, e })
        end
        if first_only or (e == s and e >= #text) then
            break
        end
        -- Past a zero-width match by one whole character, not a byte.
        start = e > s and e or e + 1 + vim.str_utf_end(text, e + 1)
    end
    return spans
end

--- Path, line-number and separator spans of each grep-format row.
--- @param rows string[]
--- @param pathless boolean also accept a bare `N:`/`N-` prefix
--- @return agentic.utils.GrepHighlights.Match[]
function M.prefixes(rows, pathless)
    --- @type agentic.utils.GrepHighlights.Match[]
    local matches = {}
    for i, row in ipairs(rows) do
        local col = 0
        for _, part in ipairs(GrepOutput.prefix_parts(row, pathless) or {}) do
            table.insert(matches, {
                line_index = i - 1,
                col_start = col,
                col_end = col + #part.text,
                hl_group = part.hl_group,
            })
            col = col + #part.text
        end
    end
    return matches
end

--- Spans of a translated pattern in the text of each match row. A row's
--- text starts where a prefix ends; with several prefixes, only spans
--- found from every start are kept. A failed match is notified and gives none.
--- @param rows string[]
--- @param translation agentic.utils.GrepRegex.Translation|nil nil gives none
--- @param ignore_case boolean
--- @param prefixes string[] Lua patterns of a match-row prefix
--- @param diagnostic_names string[] see `GrepOutput.text_starts`
--- @return agentic.utils.GrepHighlights.Match[]
function M.terms(rows, translation, ignore_case, prefixes, diagnostic_names)
    --- @type agentic.utils.GrepHighlights.Match[]
    local matches = {}
    if not translation then
        return matches
    end
    -- \C, since matchstrpos() follows 'ignorecase' (`:help match-pattern`).
    local vim_pattern = (ignore_case and "\\c" or "\\C")
        .. "\\V"
        .. translation.vim_pattern
    for i, raw_row in ipairs(rows) do
        -- vim.fn turns a string holding NUL into a Blob (E976, `:help lua-eval`); a one-byte
        -- stand-in keeps the columns.
        local row = raw_row:gsub("%z", "\1")
        --- @type table<string, integer> votes per `start:end` span
        local votes = {}
        --- @type { [1]: integer, [2]: integer }[]
        local candidates = {}
        local starts = GrepOutput.text_starts(row, prefixes, diagnostic_names)
        for _, start in ipairs(starts) do
            local full_text = row:sub(start + 1)
            local text = GrepOutput.strip_omitted(full_text)
            if text and translation.ascii_only and text:find("[\128-\255]") then
                text = nil
            end
            local spans, err
            if text then
                -- Where rg cut the line, a stand-in word character keeps
                -- `$`, `\b` and word ends from matching at the cut.
                local subject = #text < #full_text and text .. "é" or text
                spans, err =
                    regex_spans(subject, vim_pattern, translation.first_only)
            end
            if err then
                Logger.notify("Search highlight failed: " .. err)
                return {}
            end
            for _, span in ipairs(spans or {}) do
                --- @cast text string
                if span[2] > #text then
                    break
                end
                local s, e = span[1] + start, span[2] + start
                local key = s .. ":" .. e
                if not votes[key] then
                    votes[key] = 0
                    table.insert(candidates, { s, e })
                end
                votes[key] = votes[key] + 1
            end
        end
        for _, span in ipairs(candidates) do
            if votes[span[1] .. ":" .. span[2]] == #starts then
                table.insert(matches, {
                    line_index = i - 1,
                    col_start = span[1],
                    col_end = span[2],
                })
            end
        end
    end
    return matches
end

--- Prefix spans and term matches for the output of a shell command line,
--- from each grep-family command it runs. Empty when it runs none.
--- @param rows string[]
--- @param command string shell command line
--- @return agentic.utils.GrepHighlights.Match[]
function M.for_command(rows, command)
    local invocations = grep_invocations_in(command)
    if #invocations == 0 then
        return {}
    end
    local line_numbers = false
    for _, invocation in ipairs(invocations) do
        line_numbers = line_numbers or invocation.line_numbers
    end
    local matches = M.prefixes(rows, line_numbers)
    for _, invocation in ipairs(invocations) do
        vim.list_extend(
            matches,
            M.terms(
                rows,
                GrepRegex.translate(
                    invocation.patterns,
                    invocation.dialects,
                    invocation.whole
                ),
                invocation.ignore_case,
                GrepOutput.prefix_patterns(invocation.layout),
                invocation.diagnostic_names
            )
        )
    end
    return matches
end

return M
