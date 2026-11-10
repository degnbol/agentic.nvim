local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Chat buffer injections", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        child.cmd("Agentic")
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    it("has no combined injection pattern", function()
        assert.is_false(child.lua_get([[
vim.treesitter.query.get("agentic", "injections").has_combined_injections == true
]]))
    end)

    it("a range parse injects only the rows in its range", function()
        local n_regions = child.lua([[
local s = require("agentic.session_registry").current()
local lines = {}
for i = 1, 200 do
    vim.list_extend(lines, { "paragraph " .. i, "" })
end
s.message_writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end)
local parser = vim.treesitter.get_parser(s.widget.buf_nrs.agent)
parser:parse({ 100, 101 })
local inline = parser:children().markdown_inline
return inline and #inline:included_regions() or 0
]])

        assert.equal(1, n_regions)
    end)

    --- Write a tool call into 200 paragraphs with the cursor on the first or
    --- last line, and read the injections right after the writer's own
    --- multi-range parse: later edits and row parses in the same write
    --- replace them again.
    --- @param at_end boolean Cursor on the last line, else the first
    --- @return { view_valid: boolean, n_regions: integer, n_distinct: integer }
    local function write_with_cursor(at_end)
        child.lua(
            [[
_G.s = require("agentic.session_registry").current()
local lines = {}
for i = 1, 200 do
    vim.list_extend(lines, { "paragraph " .. i, "" })
end
_G.s.message_writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end)
local win = _G.s.widget:home_win()
local lnum = ... and vim.api.nvim_buf_line_count(_G.s.widget.buf_nrs.agent) or 1
vim.api.nvim_win_set_cursor(win, { lnum, 0 })
]],
            { at_end }
        )
        child.flush()

        return child.lua([=[
local win = _G.s.widget:home_win()
local parser = vim.treesitter.get_parser(_G.s.widget.buf_nrs.agent)
local parse = parser.parse
local seen
parser.parse = function(self, range, ...)
    local trees = parse(self, range, ...)
    if not seen and type(range) == "table" and type(range[1]) == "table" then
        local view = { vim.fn.line("w0", win) - 1, vim.fn.line("w$", win) + 1 }
        local regions = self:children().markdown_inline:included_regions()
        local starts = {}
        for _, region in pairs(regions) do
            starts[region[1][3]] = true
        end
        seen = {
            view_valid = self:is_valid(false, { view }),
            n_regions = vim.tbl_count(regions),
            n_distinct = vim.tbl_count(starts),
        }
    end
    return trees
end
_G.s.message_writer:write_tool_call_block({
    tool_call_id = "t1", status = "completed", kind = "execute",
    argument = "ls", body = { "output" },
})
parser.parse = nil
return seen
]=])
    end

    it("a tool call written out of view keeps the view parsed", function()
        local seen = write_with_cursor(false)

        assert.is_true(seen.view_valid)
        assert.equal(seen.n_distinct, seen.n_regions)
    end)

    it("a tool call written into view keeps the view parsed", function()
        local seen = write_with_cursor(true)

        assert.is_true(seen.view_valid)
        assert.equal(seen.n_distinct, seen.n_regions)
    end)
end)

describe("Chat buffer fence rows", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        -- As a user config: treesitter started on every filetype, markdown
        -- injected into another language's strings (as into a heredoc or a
        -- docstring; lua's parser is bundled), and a filetype registered to
        -- markdown.
        child.lua([[
vim.api.nvim_create_autocmd("FileType", {
    callback = function(args)
        if vim.treesitter.get_parser(args.buf, nil, { error = false }) then
            vim.treesitter.start(args.buf)
        end
    end,
})
vim.treesitter.query.set("lua", "injections", [=[
((string_content) @injection.content
  (#set! injection.language "markdown"))
]=])
vim.treesitter.language.register("markdown", "pandoc")
]])
        child.cmd("Agentic")
        child.flush()
        child.lua([[
_G.s = require("agentic.session_registry").current()
_G.chat = _G.s.widget.buf_nrs.agent
_G.win = _G.s.widget:home_win()
_G.FenceRows = require("agentic.ui.fence_rows")
]])
    end)

    after_each(function()
        child.stop()
    end)

    --- Write a tool call with a markdown sidecar body, and prose with pandoc,
    --- Markdown and lua fences, one lua string holding a markdown fence.
    local function write_mixed()
        child.lua([=[
local writer = _G.s.message_writer
writer:write_tool_call_block({
    tool_call_id = "fetch", status = "completed", kind = "fetch",
    argument = "https://example.com",
    body = { "## Heading", "", "```lua", "x = 1", "```", "", "tail" },
})
writer:write_message({
    sessionUpdate = "agent_message",
    content = { type = "text", text = table.concat({
        "````pandoc", "```lua", "y = 2", "```", "````", "",
        "```Markdown", "# Title", "```", "",
        "````lua", "doc = [[", "```c", "int w;", "```", "]]", "````",
    }, "\n") },
})
vim.treesitter.get_parser(_G.chat):parse(true)
]=])
        child.flush()
    end

    --- @return boolean
    local function highlighter_hides_rows()
        return child.lua_get(
            "vim.treesitter.highlighter.active[_G.chat]._conceal_line == true"
        )
    end

    --- 0-indexed rows `FenceRows` marks.
    --- @return integer[]
    local function marked_rows()
        return child.lua_get(
            [[vim.tbl_map(function(mark)
    return mark[2]
end, vim.api.nvim_buf_get_extmarks(_G.chat, _G.FenceRows.NS, 0, -1, {}))]]
        )
    end

    it("hides fence rows with marks, not the highlighter", function()
        write_mixed()

        assert.is_false(highlighter_hides_rows())
        assert.is_true(child.lua([[
local found = false
vim.treesitter.get_parser(_G.chat):for_each_tree(function(_, tree)
    if tree:lang() == "lua" and tree:children().markdown then
        found = true
    end
end)
return found
]]))

        --- 0-indexed rows of the lines that are exactly `text`.
        --- @param text string
        --- @return integer[]
        local function rows_of(text)
            return child.lua(
                [[
local rows = {}
for i, line in ipairs(vim.api.nvim_buf_get_lines(_G.chat, 0, -1, false)) do
    if vim.trim(line) == ... then
        table.insert(rows, i - 1)
    end
end
return rows
]],
                { text }
            )
        end
        local marked = marked_rows()
        local function all_marked(rows)
            return vim.iter(rows):all(function(row)
                return vim.tbl_contains(marked, row)
            end)
        end
        -- Inside the sidecar body and the pandoc body.
        assert.equal(2, #rows_of("```lua"))
        assert.is_true(all_marked(rows_of("```lua")))
        assert.is_true(all_marked(rows_of("```Markdown")))
        assert.is_true(all_marked(rows_of("````lua")))
        -- Inside a lua string: content of a lua block, drawn as written.
        assert.is_false(vim.tbl_contains(marked, rows_of("```c")[1]))
    end)

    it("highlights a markdown body as markdown", function()
        write_mixed()

        local captures = child.lua([[
local row = vim.fn.search("^## Heading", "nw") - 1
return vim.tbl_map(function(c)
    return c.capture .. "." .. c.lang
end, vim.treesitter.get_captures_at_pos(_G.chat, row, 0))
]])
        assert.is_true(vim.tbl_contains(captures, "markup.heading.2.markdown"))
    end)

    it("draws fence rows at level 0", function()
        write_mixed()
        child.lua(
            [[vim.api.nvim_win_call(_G.win, function() vim.cmd("normal! zR") end)]]
        )
        local height = "vim.api.nvim_win_text_height(_G.win, {}).all"
        local at_2 = child.lua_get(height)

        child.lua([[vim.wo[_G.win].conceallevel = 0]])

        assert.equal(at_2 + #marked_rows(), child.lua_get(height))
    end)

    it("marks fence rows again after the chat is reloaded", function()
        write_mixed()

        child.lua(
            [[vim.api.nvim_win_call(_G.win, function() vim.cmd.edit() end)]]
        )
        child.flush()
        assert.is_false(highlighter_hides_rows())
        child.lua([[
_G.s.message_writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "```lua", "x", "```" })
end)
]])

        local last = child.lua_get("vim.api.nvim_buf_line_count(_G.chat)") - 1
        local marked = marked_rows()
        assert.is_true(vim.tbl_contains(marked, last))
        assert.is_true(vim.tbl_contains(marked, last - 2))
    end)

    describe("at level 2 in a following window", function()
        before_each(function()
            child.lua([[
local lines = {}
for i = 1, 60 do
    vim.list_extend(lines, { "prose " .. i, "```lua", "x = " .. i, "```", "" })
end
_G.s.message_writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end)
vim.api.nvim_set_current_win(_G.win)
vim.wo[_G.win].conceallevel = 2
vim.cmd("normal! G")
local LanguageTree = require("vim.treesitter.languagetree")
local parse = LanguageTree.parse
_G.row_parses = 0
LanguageTree.parse = function(self, range, ...)
    if
        self == vim.treesitter.get_parser(_G.chat)
        and type(range) == "table"
        and type(range[1]) == "number"
        and range[2] == range[1] + 1
    then
        _G.row_parses = _G.row_parses + 1
    end
    return parse(self, range, ...)
end
]])
            child.flush()
            child.lua([[_G.row_parses = 0]])
        end)

        it("measures rows without a parse of each", function()
            for i = 1, 20 do
                child.lua(
                    [[
_G.s.message_writer:write_message_chunk({
    sessionUpdate = "agent_message_chunk",
    content = { type = "text", text = ... },
})
]],
                    { ("chunk %d\n\n```lua\nx = %d\n```\n\n"):format(i, i) }
                )
                child.flush()
            end
            assert.equal(0, child.lua_get("_G.row_parses"))

            child.type_keys("<C-u>")
            child.flush()
            assert.equal(0, child.lua_get("_G.row_parses"))

            child.lua([[
local last = vim.api.nvim_buf_line_count(_G.chat) - 1
require("agentic.utils.buf_helpers").show_rows(_G.win, 0, last - 20, last - 10)
]])
            child.flush()
            assert.equal(0, child.lua_get("_G.row_parses"))
        end)
    end)

    it("updates a long markdown body about as fast as a console one", function()
        --- Seconds 20 updates of a 500-row `kind` body take.
        --- @param kind string
        --- @return number
        local function update_time(kind)
            return child.lua(
                [[
local kind = ...
local writer = _G.s.message_writer
local body = {}
for i = 1, 500 do
    body[i] = i % 50 == 0 and "```" or ("row " .. i)
end
writer:write_tool_call_block({
    tool_call_id = kind, status = "in_progress", kind = kind,
    argument = "x", body = body,
})
local start = vim.uv.hrtime()
for i = 1, 20 do
    body[#body + 1] = "more " .. i
    writer:update_tool_call_block({
        tool_call_id = kind, status = "in_progress", kind = kind,
        argument = "x", body = body,
    })
end
return (vim.uv.hrtime() - start) / 1e9
]],
                { kind }
            )
        end

        -- `fetch` bodies are markdown, `other` bodies console.
        local console = update_time("other")
        local markdown = update_time("fetch")

        assert.is_true(markdown <= 2 * console)
    end)
end)
