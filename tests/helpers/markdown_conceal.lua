--- A fixed markdown_inline highlights query, so conceal widths in tests do
--- not depend on the queries installed on the machine.
local Treesitter = require("agentic.utils.treesitter")

local M = {}

--- Conceal rules of nvim-treesitter's markdown_inline highlights query,
--- except that an escape's backslash is replaced by itself rather than hidden.
local QUERY = [[
((backslash_escape) @conceal
  (#offset! @conceal 0 0 0 -1)
  (#set! conceal "\\"))

([
  (code_span_delimiter)
  (emphasis_delimiter)
] @conceal
  (#set! conceal ""))

(inline_link
  [
    "["
    "]"
    "("
    (link_destination)
    ")"
  ] @markup.link
  (#set! conceal ""))

(image
  [
    "!"
    "["
    "]"
    "("
    (link_destination)
    ")"
  ] @markup.link
  (#set! conceal ""))

(full_reference_link
  [
    "["
    "]"
    (link_label)
  ] @markup.link
  (#set! conceal ""))

(collapsed_reference_link
  [
    "["
    "]"
  ] @markup.link
  (#set! conceal ""))

(shortcut_link
  [
    "["
    "]"
  ] @markup.link
  (#set! conceal ""))

((entity_reference) @character.special
  (#eq? @character.special "&lt;")
  (#set! conceal "<"))

((entity_reference) @character.special
  (#eq? @character.special "&gt;")
  (#set! conceal ">"))

((entity_reference) @character.special
  (#eq? @character.special "&amp;")
  (#set! conceal "&"))
]]

--- Text of the markdown_inline highlights query files on 'runtimepath'.
--- @return string
local function runtime_query()
    local texts = {}
    for _, file in
        ipairs(vim.treesitter.query.get_files("markdown_inline", "highlights"))
    do
        texts[#texts + 1] = table.concat(vim.fn.readfile(file), "\n")
    end
    return table.concat(texts, "\n")
end

--- Replace the markdown_inline highlights query with the fixed one.
--- @return fun() restore sets the query back to the runtime files' text
function M.pin()
    local previous = runtime_query()
    vim.treesitter.query.set("markdown_inline", "highlights", QUERY)
    return function()
        vim.treesitter.query.set("markdown_inline", "highlights", previous)
    end
end

--- Display cells of markdown cell text at `conceallevel = 2`, under the
--- current query.
--- @param cell string
--- @return integer
function M.width(cell)
    return Treesitter.concealed_width(cell, "markdown_inline", 2)
end

return M
