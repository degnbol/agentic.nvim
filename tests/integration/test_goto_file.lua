local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("gf in a transcript", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        child.lua([[
vim.cmd("Agentic")
_G.s =require("agentic.session_registry").current()
table.insert(_G.s.chat_history.messages, { type = "user", text = "hi" })
--- Write `lines` to a new file. Returns its resolved path, the name `:edit`
--- gives its buffer.
local function new_file(lines)
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile(lines, path)
    return vim.uv.fs_realpath(path)
end
_G.edited = new_file({ "x", "old1", "old2", "y" })
_G.mentioned = new_file({ "mentioned" })
_G.s.message_writer:write_tool_call_block({
    tool_call_id = "e1",
    status = "completed",
    kind = "edit",
    argument = _G.edited,
    diff = { old = { "old1", "old2" }, new = { "new1", "see " .. _G.mentioned } },
})
_G.chat_win = _G.s.widget:home_win()
]])
        child.flush()
    end)

    after_each(function()
        pcall(child.stop)
    end)

    --- Put the cursor in the chat window on the first line holding `text`, at
    --- the column where it starts.
    --- @param text string
    local function cursor_on(text)
        child.lua(
            [[
vim.api.nvim_set_current_win(_G.chat_win)
local text = ...
for i, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
    local col = line:find(text, 1, true)
    if col then
        vim.api.nvim_win_set_cursor(0, { i, col - 1 })
        return
    end
end
error("not in the chat: " .. text)
]],
            { text }
        )
    end

    --- @return string
    local function current_name()
        return child.lua_get([[vim.api.nvim_buf_get_name(0)]])
    end

    --- @param keys string
    local function press(keys)
        child.type_keys(keys)
        child.flush()
    end

    --- Append `text` to the chat below the edit block, as prose, and put the
    --- cursor on it in the chat window.
    --- @param text string
    local function cursor_on_prose(text)
        child.lua(
            [[
local chat = _G.s.widget.buf_nrs.chat
vim.bo[chat].modifiable = true
vim.api.nvim_buf_set_lines(chat, -1, -1, false, { ... })
vim.api.nvim_set_current_win(_G.chat_win)
vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(chat), 0 })
]],
            { text }
        )
    end

    it("on an added row opens the edited file at its line in place", function()
        cursor_on("new1")

        press("gf")

        assert.equal(
            child.lua_get("_G.chat_win"),
            child.api.nvim_get_current_win()
        )
        assert.equal(child.lua_get("_G.edited"), current_name())
        assert.same({ 2, 0 }, child.api.nvim_win_get_cursor(0))
    end)

    it("2gf on an added row opens the file and leaves no count", function()
        cursor_on("new1")

        press("2gf")
        press("j")

        assert.equal(child.lua_get("_G.edited"), current_name())
        assert.same({ 3, 0 }, child.api.nvim_win_get_cursor(0))
    end)

    it("<C-w>f splits and <C-w>gf opens a tab", function()
        local n_wins = #child.api.nvim_tabpage_list_wins(0)
        cursor_on("new1")

        press("<C-w>f")

        assert.equal(n_wins + 1, #child.api.nvim_tabpage_list_wins(0))
        assert.equal(child.lua_get("_G.edited"), current_name())

        cursor_on("new1")
        press("<C-w>gf")

        assert.equal(2, #child.api.nvim_list_tabpages())
        assert.equal(child.lua_get("_G.edited"), current_name())
        assert.same({ 2, 0 }, child.api.nvim_win_get_cursor(0))
    end)

    it("on a path inside the diff runs native gf", function()
        cursor_on(child.lua_get("_G.mentioned"))

        press("gf")

        assert.equal(child.lua_get("_G.mentioned"), current_name())
    end)

    it("on the header's path runs native gf", function()
        cursor_on(vim.fs.basename(child.lua_get("_G.edited")))

        press("gf")

        assert.equal(child.lua_get("_G.edited"), current_name())
        -- The fallback would land on the hunk start, line 2.
        assert.same({ 1, 0 }, child.api.nvim_win_get_cursor(0))
    end)

    it("on an agentic:// name opens that buffer", function()
        cursor_on_prose(
            child.lua_get("vim.api.nvim_buf_get_name(_G.s.widget.buf_nrs.input)")
        )

        press("gf")

        assert.equal(
            child.lua_get("_G.s.widget.buf_nrs.input"),
            child.api.nvim_get_current_buf()
        )
    end)

    it("2gf on a path in prose keeps the count", function()
        cursor_on_prose(child.lua_get("_G.mentioned"))

        -- The path has one match, so a kept count finds no second one.
        local ok, err = pcall(press, "2gf")

        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find("E347", 1, true))
        assert.equal(
            child.lua_get("_G.s.widget.buf_nrs.chat"),
            child.api.nvim_get_current_buf()
        )
    end)

    it("is mapped on a subagent transcript", function()
        child.lua([[
_G.s:_on_session_update({
    sessionUpdate = "subagent_spawned",
    subagentSessionId = "c1",
    name = "n",
    task = "t",
}, "root")
]])
        local sub = child.lua_get("_G.s._agents.c1.transcript.bufnr")
        for _, lhs in ipairs({ "gf", "<C-W>f", "<C-W><C-F>", "<C-W>gf" }) do
            local is_buffer_local = child.lua_get(
                string.format(
                    [[vim.api.nvim_buf_call(%d, function() return vim.fn.maparg(%q, "n", false, true).buffer end)]],
                    sub,
                    lhs
                )
            )
            assert.equal(1, is_buffer_local)
        end
    end)
end)
