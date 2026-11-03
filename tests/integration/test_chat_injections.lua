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
