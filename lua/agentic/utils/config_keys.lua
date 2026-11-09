--- Key paths that a TOML, INI or JSON config file holds.
--- @class agentic.utils.ConfigKeys
local M = {}

--- @alias agentic.ConfigFormat "toml" | "ini" | "json"

--- An ordered set of key paths.
--- @return string[][] paths
--- @return fun(path: string[]) add appends a copy of `path` once
local function path_set()
    local paths, seen = {}, {}
    return paths,
        function(path)
            local id = table.concat(path, "\0")
            if not seen[id] then
                seen[id] = true
                table.insert(paths, vim.list_extend({}, path))
            end
        end
end

--- @param path string[]
--- @param segments string[]
--- @return string[] joined a new list
local function join(path, segments)
    return vim.list_extend(vim.list_extend({}, path), segments)
end

--- @param node TSNode
--- @return TSNode[] children named children other than comments
local function named_children(node)
    local children = {}
    for child in node:iter_children() do
        if child:named() and child:type() ~= "comment" then
            table.insert(children, child)
        end
    end
    return children
end

--- Segments of a TOML key node. A basic-string key is decoded as a JSON
--- string, so a TOML-only escape (`\U`, `\e`, `\x`) is undecodable.
--- @param node TSNode a `bare_key`, `quoted_key` or `dotted_key`
--- @param text string the source the node was parsed from
--- @return string[]|nil segments nil when a quoted key is undecodable
local function toml_segments(node, text)
    local raw = vim.treesitter.get_node_text(node, text)
    local kind = node:type()
    if kind == "bare_key" then
        return { raw }
    end
    if kind == "quoted_key" then
        if raw:sub(1, 1) == "'" then
            return { raw:sub(2, -2) }
        end
        local ok, key = pcall(vim.json.decode, raw)
        return ok and type(key) == "string" and { key } or nil
    end
    local segments = {}
    for _, child in ipairs(named_children(node)) do
        local child_segments = toml_segments(child, text)
        if not child_segments then
            return nil
        end
        vim.list_extend(segments, child_segments)
    end
    return segments
end

local toml_value

--- Adds the paths of `pair_nodes` under `path`.
--- @param pair_nodes TSNode[] `pair` nodes
--- @param path string[]
--- @param text string
--- @param add fun(path: string[])
--- @return boolean ok false when a key is undecodable
local function toml_pairs(pair_nodes, path, text, add)
    for _, pair in ipairs(pair_nodes) do
        local children = named_children(pair)
        local segments = toml_segments(children[1], text)
        if
            not segments
            or not toml_value(
                children[#children],
                join(path, segments),
                text,
                add
            )
        then
            return false
        end
    end
    return true
end

--- Adds the leaf paths of a TOML value at `path`. Inline tables, also
--- inside arrays, extend the path; any other value, and an empty table or
--- array, ends it.
--- @param node TSNode
--- @param path string[]
--- @param text string
--- @param add fun(path: string[])
--- @return boolean ok false when a key is undecodable
toml_value = function(node, path, text, add)
    local kind = node:type()
    local children = named_children(node)
    if (kind ~= "inline_table" and kind ~= "array") or #children == 0 then
        add(path)
        return true
    end
    if kind == "inline_table" then
        return toml_pairs(children, path, text, add)
    end
    for _, element in ipairs(children) do
        if not toml_value(element, path, text, add) then
            return false
        end
    end
    return true
end

--- @param text string
--- @return string[][]|nil paths
local function toml_paths(text)
    local ok, parser = pcall(vim.treesitter.get_string_parser, text, "toml")
    if not ok then
        return nil
    end
    local root = parser:parse()[1]:root()
    if root:has_error() then
        return nil
    end
    local paths, add = path_set()
    for _, node in ipairs(named_children(root)) do
        local done
        if node:type() == "pair" then
            done = toml_pairs({ node }, {}, text, add)
        else
            local children = named_children(node)
            local header = toml_segments(table.remove(children, 1), text)
            if header and #children == 0 then
                add(header)
            end
            done = header ~= nil and toml_pairs(children, header, text, add)
        end
        if not done then
            return nil
        end
    end
    return paths
end

--- Reads INI as Python's configparser does with default settings, which
--- setuptools, flake8, mypy, tox and pylint use: a key before any section
--- and a line without `=` or `:` are errors there too, and a `[DEFAULT]` key
--- is also a key of every other section.
--- @param text string
--- @return string[][]|nil paths
local function ini_paths(text)
    local paths, add = path_set()
    local section, in_value
    local keyed = {}
    --- @type string[]
    local sections = {}
    --- @type string[]
    local default_keys = {}
    local function close_section()
        if section and not keyed[section] then
            add({ section })
        end
    end
    for line in vim.gsplit(text, "\n", { plain = true }) do
        local trimmed = vim.trim(line)
        local indented = line:match("^%s") ~= nil
        local header = trimmed:match("^%[(.+)%]$")
        local key = trimmed:match("^(.-)%s*[=:]")
        if
            trimmed == ""
            or trimmed:match("^[#;]")
            or (indented and in_value)
        then
            -- blank, comment, or continuation of the previous value
        elseif indented then
            return nil
        elseif header then
            close_section()
            section, in_value = header, false
            table.insert(sections, header)
        elseif section and key and key ~= "" then
            in_value, keyed[section] = true, true
            add({ section, key:lower() })
            if section == "DEFAULT" then
                table.insert(default_keys, key:lower())
            end
        else
            return nil
        end
    end
    close_section()
    for _, name in ipairs(sections) do
        for _, default_key in ipairs(name ~= "DEFAULT" and default_keys or {}) do
            add({ name, default_key })
        end
    end
    return paths
end

local empty_dict_mt = getmetatable(vim.empty_dict())

--- @param value any
--- @return boolean
local function is_object(value)
    return type(value) == "table"
        and (getmetatable(value) == empty_dict_mt or not vim.islist(value))
end

--- Adds the leaf paths of a decoded JSON value at `path`, keys sorted.
--- Objects, also inside arrays, extend the path; any other value, and an
--- empty object or array, ends it.
--- @param value any
--- @param path string[]
--- @param add fun(path: string[])
local function json_value(value, path, add)
    if type(value) ~= "table" or next(value) == nil then
        add(path)
    elseif is_object(value) then
        local keys = vim.tbl_keys(value)
        table.sort(keys)
        for _, key in ipairs(keys) do
            json_value(value[key], join(path, { key }), add)
        end
    else
        for _, element in ipairs(value) do
            json_value(element, path, add)
        end
    end
end

--- @param text string
--- @return string[][]|nil paths
local function json_paths(text)
    local ok, root = pcall(vim.json.decode, text, { skip_comments = true })
    if not ok or not is_object(root) then
        return nil
    end
    local paths, add = path_set()
    json_value(root, {}, add)
    return paths
end

--- Key paths to the leaf values of a config file. A path does not index
--- into arrays: it ends at an array of plain values and continues into
--- table elements, so `[[bin]]` keys and `x = [{ y = 1 }]` give `bin.*`
--- and `x.y`. An empty table, section, object or array is a leaf.
--- Duplicate paths appear once.
--- @param text string
--- @param format agentic.ConfigFormat `"toml"`; `"ini"` (configparser
---        dialect, keys lowercased, section names as written); `"json"`
---        (comments allowed, trailing commas not)
--- @return string[][]|nil paths in document order (JSON: sorted by key).
---         nil when the text does not parse, the root is not a table, or
---         the `toml` tree-sitter parser is not installed.
function M.key_paths(text, format)
    if format == "toml" then
        return toml_paths(text)
    elseif format == "ini" then
        return ini_paths(text)
    end
    return json_paths(text)
end

return M
