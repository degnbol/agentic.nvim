local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Rendering in any window", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        child.cmd("Agentic")
        child.flush()
        child.lua([[
_G.s = require("agentic.session_registry").current()
_G.chat = _G.s.widget.buf_nrs.agent
]])
    end)

    after_each(function()
        child.stop()
    end)

    --- Show the chat in the only window of a new tab.
    --- @return integer winid
    local function show_chat_in_new_tab()
        child.cmd("tabnew")
        child.cmd("buffer " .. child.lua_get("_G.chat"))
        child.flush()
        return child.api.nvim_get_current_win()
    end

    --- @param winid integer
    --- @param name string
    local function win_opt(winid, name)
        return child.lua_get(
            "vim.api.nvim_get_option_value(select(1, ...), { win = select(2, ...) })",
            { name, winid }
        )
    end

    it("a foreign window gets the chat options, scoped to the chat", function()
        child.cmd("tabnew " .. vim.fn.tempname() .. ".lua")
        local code = child.api.nvim_get_current_buf()
        local winid = child.api.nvim_get_current_win()
        child.cmd("buffer " .. child.lua_get("_G.chat"))
        child.flush()

        assert.equal("expr", win_opt(winid, "foldmethod"))
        assert.equal(2, win_opt(winid, "conceallevel"))
        assert.equal("yes:1", win_opt(winid, "signcolumn"))

        child.cmd("buffer " .. code)

        assert.equal("manual", win_opt(winid, "foldmethod"))
        assert.equal(0, win_opt(winid, "conceallevel"))
    end)

    it("a window opened later gets the folds already closed", function()
        child.lua([[
local writer = _G.s.message_writer
writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "intro", "```text-fold", "one", "two", "three", "```", "outro",
    })
end)
writer:_queue_fold(2, false)
]])
        child.flush()
        vim.uv.sleep(50)
        child.flush()

        local winid = show_chat_in_new_tab()

        assert.equal(3, child.lua_get("vim.fn.foldclosed(3)", {}))
        assert.equal(
            child.lua_get("_G.chat"),
            child.api.nvim_win_get_buf(winid)
        )
    end)

    it("a fold closes in every window showing the chat", function()
        show_chat_in_new_tab()
        child.lua([[
local writer = _G.s.message_writer
writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "intro", "```text-fold", "one", "two", "three", "```", "outro",
    })
end)
writer:_queue_fold(2, false)
]])
        child.flush()
        vim.uv.sleep(50)
        child.flush()

        local closed = child.lua_get([[
vim.tbl_map(function(winid)
    return vim.api.nvim_win_call(winid, function()
        return vim.fn.foldclosed(3)
    end)
end, vim.fn.win_findbuf(_G.chat))
]])
        assert.same({ 3, 3 }, closed)
    end)

    it(
        "the home window gets the folds when show_in shows the chat again",
        function()
            child.lua([[
_G.s.chat_history:add_message({ type = "user", text = "x", timestamp = 0, provider_name = "p" })
local writer = _G.s.message_writer
writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "intro", "```text-fold", "one", "two", "three", "```", "outro",
    })
end)
writer:_queue_fold(2, false)
]])
            child.flush()
            vim.uv.sleep(50)
            child.flush()

            local home = child.lua_get("_G.s.widget:home_win()")
            child.cmd("enew")
            child.flush()
            assert.equal(vim.NIL, child.lua_get("_G.s.widget:home_win()"))
            child.lua("_G.s.widget:show_in(...)", { home })
            child.flush()
            vim.uv.sleep(50)
            child.flush()

            assert.equal(home, child.lua_get("_G.s.widget:home_win()"))
            assert.equal(
                3,
                child.lua_get([[
vim.api.nvim_win_call(_G.s.widget:home_win(), function()
    return vim.fn.foldclosed(3)
end)
]])
            )
        end
    )

    it("each window follows writes on its own", function()
        local foreign = show_chat_in_new_tab()
        local widget = child.lua_get("_G.s.widget:home_win()")
        child.lua(
            [[
local writer = _G.s.message_writer
local lines = {}
for i = 1, 200 do lines[i] = "line " .. i end
writer:_own_edit(function(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end)
for _, winid in ipairs({ ... }) do
    vim.api.nvim_win_call(winid, function() vim.cmd("normal! G") end)
end
]],
            { foreign, widget }
        )
        child.flush()
        -- The user moves the foreign window, the current one, up.
        child.type_keys("gg")
        child.flush()

        child.lua([[
local writer = _G.s.message_writer
writer:_schedule_follow()
writer:_own_edit(function(bufnr)
    local more = {}
    for i = 1, 50 do more[i] = "more " .. i end
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, more)
end)
]])
        child.flush()
        vim.uv.sleep(50)
        child.flush()

        local last = child.lua_get("vim.api.nvim_buf_line_count(_G.chat)")
        local function botline(winid)
            return child.lua_get("vim.fn.getwininfo(...)[1].botline", { winid })
        end
        assert.equal(last, botline(widget))
        assert.is_true(botline(foreign) < last)
    end)

    describe("a permission for a chat no window shows", function()
        before_each(function()
            -- A message keeps the session alive once its chat is hidden.
            child.lua([[
_G.s.chat_history:add_message({ type = "user", text = "x", timestamp = 0, provider_name = "p" })
vim.cmd("enew")
_G.bells = 0
require("agentic.session_manager")._ring_bell = function() _G.bells = _G.bells + 1 end
]])
            child.cmd("tabnew")
            child.lua([[
_G.below = vim.api.nvim_get_current_win()
_G.answer = nil
_G.s:_on_request_permission({
    sessionId = "s",
    toolCall = { toolCallId = "tc-1", kind = "edit" },
    options = { { optionId = "allow-once", name = "Allow", kind = "allow_once" } },
}, function(option_id) _G.answer = option_id end)
_G.float = _G.s.permission_manager.permission_float
]])
            child.flush()
        end)

        it(
            "shows in the current tab, and its keys work from the float",
            function()
                assert.equal("tab", child.lua_get("_G.float:get_host()"))
                assert.equal(1, child.lua_get("_G.bells"))
                assert.same(
                    {},
                    child.lua_get([[vim.fn.maparg("\\y", "n", false, true)]])
                )
                child.lua([[
_G.reached_below = false
vim.keymap.set("n", "\\y", function() _G.reached_below = true end, { buf = 0 })
]])

                child.type_keys("<C-w>w")
                assert.equal(
                    child.lua_get("_G.float:get_bufnr()"),
                    child.api.nvim_get_current_buf()
                )
                child.type_keys("\\y")
                child.flush()

                assert.equal("allow-once", child.lua_get("_G.answer"))
                assert.is_false(child.lua_get("_G.reached_below"))
                assert.equal(
                    child.lua_get("_G.below"),
                    child.api.nvim_get_current_win()
                )
            end
        )

        it("an open key in the float opens in the previous window", function()
            child.type_keys("<C-w>w")
            child.type_keys("\\e")
            child.flush()

            assert.equal(
                child.lua_get("_G.below"),
                child.api.nvim_get_current_win()
            )
            assert.equal(
                child.lua_get("_G.chat"),
                child.api.nvim_get_current_buf()
            )
            assert.equal("anchor", child.lua_get("_G.float:get_host()"))
        end)

        it("follows into another tab without the chat", function()
            child.cmd("tabnew")
            child.flush()
            vim.uv.sleep(50)
            child.flush()

            assert.equal("tab", child.lua_get("_G.float:get_host()"))
            assert.equal(
                child.api.nvim_get_current_tabpage(),
                child.lua_get("vim.api.nvim_win_get_tabpage(_G.float._winid)")
            )
            assert.equal(1, child.lua_get("_G.bells"))
        end)
    end)

    it(
        "a detached permission moves to the home window when show_in shows the chat",
        function()
            child.lua([[
_G.s.chat_history:add_message({ type = "user", text = "x", timestamp = 0, provider_name = "p" })
_G.home = _G.s.widget:home_win()
vim.cmd("enew")
_G.answer = nil
_G.s.permission_manager:add_request({
    sessionId = "s",
    toolCall = { toolCallId = "tc-1", kind = "edit" },
    options = { { optionId = "allow-once", name = "Allow", kind = "allow_once" } },
}, function(option_id) _G.answer = option_id end)
_G.s.widget:show_in(_G.home)
]])
            child.flush()
            vim.uv.sleep(50)
            child.flush()

            local home = child.lua_get("_G.home")
            assert.equal(home, child.lua_get("_G.s.widget:home_win()"))
            assert.equal(
                home,
                child.lua_get(
                    "vim.api.nvim_win_get_config(_G.s.permission_manager.permission_float._winid).win"
                )
            )
            child.api.nvim_set_current_win(home)
            child.type_keys("\\y")
            child.flush()
            assert.equal("allow-once", child.lua_get("_G.answer"))
        end
    )

    it("a window showing the chat later gets its winbar", function()
        -- The default header functions return nil: no winbar.
        child.lua([[require("agentic.config").headers.agent = nil]])
        local winid = show_chat_in_new_tab()
        assert.truthy(win_opt(winid, "winbar"):find("Agentic Chat", 1, true))
    end)
end)
