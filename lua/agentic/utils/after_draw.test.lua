local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

-- A child with a UI: the test runner's own redraws do not draw new windows.
-- The child redraws between RPC calls, so each case opens its window and
-- acts on it in one chunk.
describe("agentic.utils.AfterDraw", function()
    local child = Child:new()

    --- Lua that opens `_G.win` and has `once` count calls in `_G.calls`.
    local OPEN = [[
_G.calls = 0
_G.win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor", row = 0, col = 0, width = 10, height = 2,
})
require("agentic.utils.after_draw").once(_G.win, function()
    _G.calls = _G.calls + 1
end)
]]

    before_each(function()
        child.launch()
    end)

    after_each(function()
        child.stop()
    end)

    --- @return integer
    local function calls()
        return child.lua_get("_G.calls")
    end

    it("calls fn once, after a redraw that draws the window", function()
        child.lua(OPEN .. [[
vim.schedule(function() _G.before_draw = _G.calls end)
vim.cmd("redraw")
_G.in_draw = _G.calls
]])
        child.flush()
        assert.equal(0, child.lua_get("_G.before_draw"))
        assert.equal(0, child.lua_get("_G.in_draw"))
        assert.equal(1, calls())

        child.cmd("redraw!")
        child.flush()
        assert.equal(1, calls())
    end)

    it("does not call fn for a window closed before its draw", function()
        child.lua(OPEN .. [[
vim.api.nvim_win_close(_G.win, true)
vim.cmd("redraw")
]])
        child.flush()

        assert.equal(0, calls())
    end)
end)
