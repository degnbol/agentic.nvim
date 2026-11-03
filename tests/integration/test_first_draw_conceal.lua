local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

-- A new chat window draws once at 'conceallevel' 0 and then takes its level
-- back, which collapses the fence rows; these check where it is placed then.
describe("First draw of a new chat window", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        child.cmd("Agentic")
        child.flush()
        child.lua([[
_G.s = require("agentic.session_registry").current()
_G.chat = _G.s.widget.buf_nrs.agent
_G.win = _G.s.widget:home_win()
local lines = {}
for i = 1, 60 do
    vim.list_extend(lines, { "prose " .. i, "```lua", "x = " .. i, "```", "" })
end
_G.s.message_writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end)
vim.treesitter.get_parser(_G.chat):parse(true)
vim.api.nvim_set_current_win(_G.win)
vim.cmd("normal! G")
]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    --- Let the first draw, the restore and the scroll it schedules land.
    local function settle()
        child.flush()
        vim.uv.sleep(50)
        child.flush()
    end

    --- Run `cmd` in the chat window and name the window it opens `_G.new`.
    --- @param cmd string
    local function split(cmd)
        child.lua(
            [[
vim.api.nvim_set_current_win(_G.win)
vim.cmd(...)
_G.new = vim.api.nvim_get_current_win()
]],
            { cmd }
        )
        settle()
    end

    --- @return boolean
    local function user_controlled()
        return child.lua_get(
            "_G.s.message_writer._user_controlled[_G.new] == true"
        )
    end

    --- Empty rows below the end of the buffer in `_G.new`.
    --- @return integer
    local function empty_rows()
        return child.lua_get([[
math.max(0, vim.api.nvim_win_get_height(_G.new) - vim.api.nvim_win_text_height(_G.new, {
    start_row = vim.fn.getwininfo(_G.new)[1].topline - 1,
}).all)
]])
    end

    --- Empty rows a following window keeps below the end.
    --- @return integer
    local function bottom_padding()
        return child.lua_get(
            [[require("agentic.config").follow.bottom_padding]]
        )
    end

    --- @return boolean
    local function shows_last_line()
        return child.lua_get(
            "vim.fn.getwininfo(_G.new)[1].botline >= vim.api.nvim_buf_line_count(_G.chat)"
        )
    end

    it("a split of a following window fills it to the end", function()
        split("vsplit")

        assert.equal(2, child.lua_get("vim.wo[_G.new].conceallevel"))
        assert.is_false(user_controlled())
        assert.is_true(shows_last_line())
        assert.equal(bottom_padding(), empty_rows())
    end)

    it("a window that newly shows the chat fills it to the end", function()
        child.lua([[
vim.cmd("tabnew")
_G.new = vim.api.nvim_get_current_win()
]])
        settle()

        child.lua([[vim.api.nvim_win_set_buf(_G.new, _G.chat)]])
        settle()

        assert.equal(2, child.lua_get("vim.wo[_G.new].conceallevel"))
        assert.is_false(user_controlled())
        assert.is_true(shows_last_line())
        assert.equal(bottom_padding(), empty_rows())
    end)

    it("with follow off, a split ends on the last line", function()
        child.lua([[require("agentic.config").follow.enabled = false]])

        split("vsplit")

        assert.equal(
            child.lua_get("vim.api.nvim_buf_line_count(_G.chat)"),
            child.lua_get("vim.api.nvim_win_get_cursor(_G.new)[1]")
        )
        assert.equal(0, empty_rows())
    end)

    it("a split places a held block as a newly shown window", function()
        child.lua([[
local writer = _G.s.message_writer
local Renderer = require("agentic.ui.tool_call_renderer")
local id = vim.api.nvim_buf_set_extmark(
    _G.chat, Renderer.NS_TOOL_BLOCKS, 99, 0, { end_row = 103 }
)
writer.tool_call_blocks.h = {
    tool_call_id = "h", status = "pending", kind = "execute",
    argument = "ls", extmark_id = id,
}
writer:hold_tool_call("h", false)
]])
        settle()

        split("vsplit")

        assert.is_true(child.lua_get([[
vim.fn.getwininfo(_G.new)[1].topline <= 100
    and vim.fn.getwininfo(_G.new)[1].botline >= 104
]]))
    end)

    describe("of a window in user control", function()
        before_each(function()
            child.type_keys("150G")
            child.flush()
            child.lua([[
local writer = _G.s.message_writer
local original = writer.on_row_heights_changed
writer.on_row_heights_changed = function(self, winid)
    _G.topline_before = vim.fn.getwininfo(winid)[1].topline
    original(self, winid)
    _G.topline_after = vim.fn.getwininfo(winid)[1].topline
end
]])
        end)

        it("stays in user control", function()
            split("vsplit")

            assert.is_true(user_controlled())
        end)

        it("keeps its topline", function()
            split("vsplit")

            assert.is_not_nil(child.lua_get("_G.topline_before"))
            assert.equal(
                child.lua_get("_G.topline_before"),
                child.lua_get("_G.topline_after")
            )
        end)

        it("in a new tab follows", function()
            split("tab split")

            assert.is_false(user_controlled())
            assert.is_true(shows_last_line())
            assert.equal(bottom_padding(), empty_rows())
        end)
    end)
end)
