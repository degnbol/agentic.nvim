--- Parses ANSI SGR escape codes from text and converts them to Neovim
--- highlight groups + extmark spans. Used to render coloured terminal output
--- (e.g. from execute tool calls) in the chat buffer.
---
--- @class agentic.utils.Ansi
local Ansi = {}

--- Cache of dynamically created highlight groups: key → hl_group name.
local hl_cache = {}

--- Standard 8+8 ANSI colour palette (fallbacks when terminal_color_N unset).
local DEFAULT_PALETTE = {
    [0] = "#555753", -- black (brightened for dark backgrounds)
    [1] = "#cc0000",
    [2] = "#4e9a06",
    [3] = "#c4a000",
    [4] = "#3465a4",
    [5] = "#75507b",
    [6] = "#06989a",
    [7] = "#d3d7cf",
    [8] = "#888a85",
    [9] = "#ef2929",
    [10] = "#8ae234",
    [11] = "#fce94f",
    [12] = "#729fcf",
    [13] = "#ad7fa8",
    [14] = "#34e2e2",
    [15] = "#eeeeec",
}

--- Resolve a 256-colour palette index to a hex string.
--- @param index integer 0–255
--- @return string hex "#rrggbb"
local function palette_color(index)
    if index < 16 then
        local tc = vim.g["terminal_color_" .. index]
        return tc or DEFAULT_PALETTE[index] or "#808080"
    end
    if index < 232 then
        local n = index - 16
        local b = n % 6
        local g = math.floor(n / 6) % 6
        local r = math.floor(n / 36)
        r = r > 0 and (r * 40 + 55) or 0
        g = g > 0 and (g * 40 + 55) or 0
        b = b > 0 and (b * 40 + 55) or 0
        return string.format("#%02x%02x%02x", r, g, b)
    end
    -- 232–255: greyscale ramp
    local v = (index - 232) * 10 + 8
    return string.format("#%02x%02x%02x", v, v, v)
end

--- @class agentic.utils.Ansi.State
--- @field fg? string hex colour
--- @field bg? string hex colour
--- @field bold? boolean
--- @field dim? boolean
--- @field italic? boolean
--- @field underline? boolean
--- @field strikethrough? boolean

--- Apply a single CSI SGR parameter string to the current state.
--- @param state agentic.utils.Ansi.State mutated in place
--- @param params string e.g. "1;32" or "" (= reset)
local function apply_sgr(state, params)
    if params == "" or params == "0" then
        for k in pairs(state) do
            state[k] = nil
        end
        return
    end

    local codes = {}
    for c in params:gmatch("%d+") do
        codes[#codes + 1] = tonumber(c)
    end

    local i = 1
    while i <= #codes do
        local c = codes[i]
        if c == 0 then
            for k in pairs(state) do
                state[k] = nil
            end
        elseif c == 1 then
            state.bold = true
        elseif c == 2 then
            state.dim = true
        elseif c == 3 then
            state.italic = true
        elseif c == 4 then
            state.underline = true
        elseif c == 9 then
            state.strikethrough = true
        elseif c == 22 then
            state.bold = nil
            state.dim = nil
        elseif c == 23 then
            state.italic = nil
        elseif c == 24 then
            state.underline = nil
        elseif c == 29 then
            state.strikethrough = nil
        elseif c >= 30 and c <= 37 then
            state.fg = palette_color(c - 30)
        elseif c == 38 then
            if codes[i + 1] == 5 and codes[i + 2] then
                state.fg = palette_color(codes[i + 2])
                i = i + 2
            elseif codes[i + 1] == 2 and codes[i + 4] then
                state.fg = string.format(
                    "#%02x%02x%02x",
                    codes[i + 2],
                    codes[i + 3],
                    codes[i + 4]
                )
                i = i + 4
            end
        elseif c == 39 then
            state.fg = nil
        elseif c >= 40 and c <= 47 then
            state.bg = palette_color(c - 40)
        elseif c == 48 then
            if codes[i + 1] == 5 and codes[i + 2] then
                state.bg = palette_color(codes[i + 2])
                i = i + 2
            elseif codes[i + 1] == 2 and codes[i + 4] then
                state.bg = string.format(
                    "#%02x%02x%02x",
                    codes[i + 2],
                    codes[i + 3],
                    codes[i + 4]
                )
                i = i + 4
            end
        elseif c == 49 then
            state.bg = nil
        elseif c >= 90 and c <= 97 then
            state.fg = palette_color(c - 90 + 8)
        elseif c >= 100 and c <= 107 then
            state.bg = palette_color(c - 100 + 8)
        end
        i = i + 1
    end
end

--- Build a cache key from the current SGR state and return (or create) the
--- corresponding Neovim highlight group.
--- @param state agentic.utils.Ansi.State
--- @return string hl_group
local function get_or_create_hl(state)
    local parts = {}
    if state.fg then
        parts[#parts + 1] = "f" .. state.fg:sub(2)
    end
    if state.bg then
        parts[#parts + 1] = "b" .. state.bg:sub(2)
    end
    if state.bold then
        parts[#parts + 1] = "B"
    end
    if state.dim then
        parts[#parts + 1] = "D"
    end
    if state.italic then
        parts[#parts + 1] = "I"
    end
    if state.underline then
        parts[#parts + 1] = "U"
    end
    if state.strikethrough then
        parts[#parts + 1] = "S"
    end

    local key = table.concat(parts, "_")
    if hl_cache[key] then
        return hl_cache[key]
    end

    local name = "AgenticAnsi_" .. key
    local opts = {}
    if state.fg then
        opts.fg = state.fg
    end
    if state.bg then
        opts.bg = state.bg
    end
    if state.bold then
        opts.bold = true
    end
    if state.italic then
        opts.italic = true
    end
    if state.underline then
        opts.underline = true
    end
    if state.strikethrough then
        opts.strikethrough = true
    end

    vim.api.nvim_set_hl(0, name, opts)
    hl_cache[key] = name
    return name
end

--- @class agentic.utils.Ansi.Span
--- @field [1] integer col_start (0-indexed byte offset, inclusive)
--- @field [2] integer col_end   (0-indexed byte offset, exclusive)
--- @field [3] string  hl_group

--- Process a single line: strip all CSI sequences, return clean text + highlight
--- spans. The SGR state is carried across lines via the mutable `state` table.
--- @param line string raw line possibly containing ANSI escapes
--- @param state agentic.utils.Ansi.State mutated in place (carries across lines)
--- @return string clean_line
--- @return agentic.utils.Ansi.Span[] spans
local function process_line(line, state)
    local clean = {}
    local spans = {}
    local col = 0
    local pos = 1
    local len = #line

    while pos <= len do
        -- Find next ESC (0x1b)
        local esc_pos = line:find("\27", pos, true)
        if not esc_pos then
            -- Rest of line is plain text
            local text = line:sub(pos)
            if #text > 0 then
                local start_col = col
                clean[#clean + 1] = text
                col = col + #text
                if next(state) then
                    spans[#spans + 1] =
                        { start_col, col, get_or_create_hl(state) }
                end
            end
            break
        end

        -- Plain text before ESC
        if esc_pos > pos then
            local text = line:sub(pos, esc_pos - 1)
            local start_col = col
            clean[#clean + 1] = text
            col = col + #text
            if next(state) then
                spans[#spans + 1] =
                    { start_col, col, get_or_create_hl(state) }
            end
        end

        -- Try to match CSI sequence: ESC [ <params> <final_byte>
        -- Final byte is 0x40–0x7E (@ through ~)
        local csi_params, csi_end =
            line:match("^%[([%d;]*)([%a@-~])", esc_pos + 1)
        if csi_params and csi_end then
            local seq_end = esc_pos
                + 1
                + #"["
                + #csi_params
                + #csi_end
                - 1
            if csi_end == "m" then
                apply_sgr(state, csi_params)
            end
            -- All CSI sequences are stripped (cursor movement, erase, etc.)
            pos = seq_end + 1
        else
            -- Not a recognised CSI sequence — try OSC (ESC ]) or other
            -- For safety, skip ESC + next char
            pos = esc_pos + 2
        end
    end

    return table.concat(clean), spans
end

--- @class agentic.utils.Ansi.Result
--- @field lines string[] clean lines (ANSI codes stripped)
--- @field highlights agentic.utils.Ansi.Span[][] per-line highlight spans
--- @field has_ansi boolean whether any ANSI codes were found

--- Process an array of lines, stripping ANSI escape codes and producing
--- per-line highlight spans. SGR state carries across lines (as real terminals
--- do).
--- @param lines string[]
--- @return agentic.utils.Ansi.Result
function Ansi.process_lines(lines)
    --- @type agentic.utils.Ansi.State
    local state = {}
    local clean_lines = {}
    local all_highlights = {}
    local has_ansi = false

    for i, line in ipairs(lines) do
        local clean, spans = process_line(line, state)
        clean_lines[i] = clean
        all_highlights[i] = spans
        if #spans > 0 then
            has_ansi = true
        end
    end

    return {
        lines = clean_lines,
        highlights = all_highlights,
        has_ansi = has_ansi,
    }
end

--- Apply pre-computed ANSI highlight spans to a buffer region.
--- @param bufnr integer
--- @param ns integer namespace for the extmarks
--- @param start_row integer 0-indexed buffer row of the first line
--- @param highlights agentic.utils.Ansi.Span[][] per-line spans from process_lines
function Ansi.apply_highlights(bufnr, ns, start_row, highlights)
    for i, spans in ipairs(highlights) do
        local row = start_row + i - 1
        for _, span in ipairs(spans) do
            pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, span[1], {
                end_col = span[2],
                hl_group = span[3],
            })
        end
    end
end

return Ansi
