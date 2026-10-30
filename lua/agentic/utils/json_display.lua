local MarkdownTable = require("agentic.utils.markdown_table")

--- JSON text as display rows: a markdown table for flat records, pretty JSON
--- otherwise.
--- @class agentic.utils.JsonDisplay
local M = {}

--- @param value any decoded JSON value
--- @return string|nil text a string as-is, another scalar as JSON; nil for a table, a non-finite number, or a string with a control character
local function scalar_text(value)
    if type(value) == "table" then
        return nil
    elseif type(value) == "number" then
        if value ~= value or math.abs(value) == math.huge then
            return nil
        end
    elseif type(value) == "string" then
        return not value:find("%c") and value or nil
    end
    return vim.json.encode(value)
end

--- @param object table decoded JSON value
--- @return table<string, string>|nil cells text of each key; nil when `object` is a list, empty, or has a key or value that is not scalar text
local function flat_cells(object)
    if next(object) == nil or vim.islist(object) then
        return nil
    end
    local cells = {} --- @type table<string, string>
    for key, value in pairs(object) do
        local text = scalar_text(value)
        if not text or not scalar_text(key) then
            return nil
        end
        cells[key] = text
    end
    return cells
end

--- Keys sorted, then the widest column (header included, escaped, after
--- conceal) moved to the end. On a tie, the last in sorted order is the
--- widest, so tied columns keep key order.
--- Sorting keeps one order across arrays whose objects list keys
--- differently; the widest column last is where a long row clips.
--- @param keys string[]
--- @param rows table<string, string>[] cell text by key, per row
--- @return string[] order
local function column_order(keys, rows)
    local order = vim.list_extend({}, keys)
    table.sort(order)
    --- @param key string
    --- @return integer
    local function column_width(key)
        local width = MarkdownTable.width(MarkdownTable.cell(key))
        for _, row in ipairs(rows) do
            width = math.max(
                width,
                MarkdownTable.width(MarkdownTable.cell(row[key]))
            )
        end
        return width
    end
    local i_widest, widest = 1, -1
    for i, key in ipairs(order) do
        local width = column_width(key)
        if width >= widest then
            i_widest, widest = i, width
        end
    end
    table.insert(order, table.remove(order, i_widest))
    return order
end

--- Markdown table for a decoded JSON value: a flat object as `key | value`
--- rows, a non-empty array of flat objects with one key set as one column per
--- key.
--- @param value table decoded JSON value
--- @return string[]|nil lines nil for any other shape
local function table_lines(value)
    local cells = flat_cells(value)
    if cells then
        local keys = vim.tbl_keys(cells)
        table.sort(keys)
        local rows = {}
        for i, key in ipairs(keys) do
            rows[i] =
                { MarkdownTable.cell(key), MarkdownTable.cell(cells[key]) }
        end
        return (MarkdownTable.lines({ "key", "value" }, rows))
    end

    if next(value) == nil or not vim.islist(value) then
        return nil
    end
    local records = {} --- @type table<string, string>[]
    for i, item in ipairs(value) do
        records[i] = type(item) == "table" and flat_cells(item) or nil
        if not records[i] then
            return nil
        end
    end
    local keys = vim.tbl_keys(records[1])
    for _, record in ipairs(records) do
        if vim.tbl_count(record) ~= #keys then
            return nil
        end
        for _, key in ipairs(keys) do
            if not record[key] then
                return nil
            end
        end
    end

    local order = column_order(keys, records)
    local header = vim.tbl_map(MarkdownTable.cell, order)
    local rows = {}
    for i, record in ipairs(records) do
        rows[i] = vim.tbl_map(function(key)
            return MarkdownTable.cell(record[key])
        end, order)
    end
    return (MarkdownTable.lines(header, rows))
end

--- Display rows for JSON text. A flat object, or a non-empty array of flat
--- objects with one key set, becomes a markdown table; any other object or
--- array becomes pretty JSON (2-space indent, sorted keys).
--- @param text string
--- @return string[]|nil rows nil when `text` does not decode to an object or array, or does not encode back (`inf`)
--- @return "markdown"|"json"|nil lang
function M.lines(text)
    local ok, value = pcall(vim.json.decode, text)
    if not ok or type(value) ~= "table" then
        return nil
    end
    local rows = table_lines(value)
    if rows then
        return rows, "markdown"
    end
    local encoded, pretty =
        pcall(vim.json.encode, value, { indent = "  ", sort_keys = true })
    if not encoded then
        return nil
    end
    return vim.split(pretty, "\n", { plain = true }), "json"
end

return M
