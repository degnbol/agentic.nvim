local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Follow", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        child.lua([[require("agentic").toggle()]])
        child.flush()
        child.lua([[
local tab = vim.api.nvim_get_current_tabpage()
_G.s = require("agentic.session_registry").bound_session(tab)
_G.chat = _G.s.widget.buf_nrs.chat
_G.win = _G.s.widget.win_nrs.chat
local lines = {}
for i = 1, 200 do lines[i] = "line " .. i end
_G.s.message_writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end)
vim.api.nvim_set_current_win(_G.win)
vim.cmd("normal! G")
]])
        child.flush()
    end)

    after_each(function()
        child.stop()
    end)

    --- Let the scheduled scroll land.
    local function settle()
        child.flush()
        vim.uv.sleep(50)
        child.flush()
    end

    --- Append lines to the chat the way a streamed write does, and let the
    --- scheduled scroll land.
    --- @param n integer|nil Number of lines, 50 by default
    local function write_more(n)
        child.lua(
            [[
local n = ...
local writer = _G.s.message_writer
writer:_schedule_follow()
writer:_own_edit(function(bufnr)
    local more = {}
    for i = 1, n do more[i] = "more " .. i end
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, more)
end)
]],
            { n or 50 }
        )
        settle()
    end

    --- Stream a prose run taller than the chat window, and let the scroll
    --- land.
    local function write_long_prose()
        child.lua([[
local paragraphs = {}
for i = 1, 100 do paragraphs[i] = "prose paragraph " .. i end
_G.s.message_writer:write_message_chunk({
    sessionUpdate = "agent_message_chunk",
    content = { type = "text", text = table.concat(paragraphs, "\n\n") },
})
]])
        settle()
    end

    --- @return integer
    local function topline()
        return child.lua_get("vim.fn.getwininfo(_G.win)[1].topline")
    end

    --- @return boolean
    local function user_controlled()
        return child.lua_get(
            "_G.s.message_writer._user_controlled[_G.win] == true"
        )
    end

    --- @return boolean
    local function shows_last_line()
        return child.lua_get(
            "vim.fn.getwininfo(_G.win)[1].botline >= vim.api.nvim_buf_line_count(_G.chat)"
        )
    end

    it("a cursor motion up puts the window in user control", function()
        child.type_keys("k")
        child.flush()
        child.lua([[vim.api.nvim_set_current_win(_G.s.widget.win_nrs.input)]])

        write_more()

        assert.is_false(shows_last_line())
    end)

    it("a cursor the prose pin parks keeps the window following", function()
        child.lua([[
local writer = _G.s.message_writer
writer._prose_anchor_line = vim.api.nvim_buf_line_count(_G.chat) - 1
]])
        write_more()

        assert.is_false(user_controlled())
        assert.is_true(
            child.lua_get("_G.s.message_writer._prose_anchor_line ~= nil")
        )
        assert.is_true(
            child.lua_get(
                "vim.api.nvim_win_get_cursor(_G.win)[1] < vim.api.nvim_buf_line_count(_G.chat)"
            )
        )
    end)

    it(
        "a scroll the prose pin caps keeps an unfocused window following",
        function()
            child.lua([[
vim.api.nvim_set_current_win(_G.s.widget.win_nrs.input)
local writer = _G.s.message_writer
writer._prose_anchor_line = vim.api.nvim_buf_line_count(_G.chat) - 1
]])
            write_more()
            write_more()

            assert.is_false(user_controlled())
            assert.is_true(
                child.lua_get("_G.s.message_writer._prose_anchor_line ~= nil")
            )
        end
    )

    it("a cursor motion back to the last line follows again", function()
        child.type_keys("k")
        child.flush()
        child.type_keys("G")
        child.flush()
        child.lua([[vim.api.nvim_set_current_win(_G.s.widget.win_nrs.input)]])

        write_more()

        assert.is_true(shows_last_line())
    end)

    it("a view move down onto the last line follows again", function()
        child.type_keys("gg")
        child.flush()
        assert.is_true(user_controlled())

        child.lua([[
local last = vim.api.nvim_buf_line_count(_G.chat)
vim.fn.winrestview({ topline = last - 5, lnum = last - 5 })
]])
        child.flush()

        assert.is_false(user_controlled())
    end)

    it("the writes after a short prose run follow the bottom", function()
        child.lua([[
local writer = _G.s.message_writer
writer:write_message_chunk({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "short prose" } })
writer:write_error_message({ code = -32603, message = "boom" })
]])
        child.flush()
        vim.uv.sleep(50)
        child.flush()
        write_more()

        assert.is_true(shows_last_line())
    end)

    it("a long prose run holds the view past the next tool call", function()
        write_long_prose()
        local held_topline = topline()
        assert.is_false(shows_last_line())

        child.lua([[
_G.s.message_writer:write_tool_call_block({
    tool_call_id = "t1", status = "pending", kind = "execute",
    argument = "ls", body = { "output" },
})
]])
        settle()
        write_more()

        assert.is_true(user_controlled())
        assert.equal(held_topline, topline())
    end)

    it("a long final prose run holds the view at turn end", function()
        write_long_prose()
        local held_topline = topline()

        child.lua([[_G.s.message_writer:finalize_turn()]])
        settle()

        assert.is_true(user_controlled())
        assert.equal(held_topline, topline())
    end)

    it("a refresh leaves a window the pin held following", function()
        write_long_prose()

        child.lua([[_G.s.message_writer:reset_turn_state()]])
        write_more()

        assert.is_false(user_controlled())
        assert.is_true(shows_last_line())
    end)

    it("a write that fits the view moves the cursor to the last line", function()
        -- Empty rows below the last line, as a fold that closes leaves them.
        child.lua([[
local last = vim.api.nvim_buf_line_count(_G.chat)
_G.s.message_writer:_own_change(function()
    vim.fn.winrestview({ topline = last - 2, lnum = last })
end)
]])
        write_more(3)

        assert.is_true(
            child.lua_get(
                "vim.api.nvim_win_get_cursor(_G.win)[1] == vim.api.nvim_buf_line_count(_G.chat)"
            )
        )
    end)

    it("the cursor a window entry places is not a motion", function()
        child.lua([[
vim.api.nvim_set_current_win(_G.s.widget.win_nrs.input)
]])
        child.flush()
        child.lua([[
vim.api.nvim_set_current_win(_G.win)
vim.api.nvim_win_set_cursor(_G.win, { 10, 0 })
]])
        child.flush()

        assert.is_false(user_controlled())
    end)

    it("clearing the chat leaves the window following", function()
        child.lua([[_G.s:clear_chat()]])
        child.flush()

        assert.is_false(user_controlled())
    end)

    it("goto bottom puts an unfocused window in following", function()
        child.type_keys("k")
        child.flush()
        child.lua([[
vim.api.nvim_set_current_win(_G.s.widget.win_nrs.input)
_G.s.widget:_goto_transcripts_bottom()
]])
        child.flush()

        assert.is_false(user_controlled())
    end)

    it("a submit clears [idle] and leaves [?]", function()
        --- @param badge string
        --- @return string|nil
        local function after_clear(badge)
            return child.lua_get(
                [[(function(badge)
_G.s.widget:set_badge(badge)
_G.s.widget:clear_idle_badge()
return require("agentic.ui.window_decoration").get_header(_G.chat).badge
end)(...)]],
                { badge }
            )
        end

        assert.equal(vim.NIL, after_clear("[idle]"))
        assert.equal("[?]", after_clear("[?]"))
    end)
end)
