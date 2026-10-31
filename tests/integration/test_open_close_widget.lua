local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Show the chat and its panels", function()
    local child = Child:new()

    --- Gets sorted filetypes for all windows in the given tabpage
    --- @param tabpage number
    --- @return string[]
    local function get_tabpage_filetypes(tabpage)
        local winids = child.api.nvim_tabpage_list_wins(tabpage)
        local filetypes = {}
        for _, winid in ipairs(winids) do
            local bufnr = child.api.nvim_win_get_buf(winid)
            local ft =
                child.lua_get(string.format([[vim.bo[%d].filetype]], bufnr))
            table.insert(filetypes, ft)
        end
        table.sort(filetypes)
        return filetypes
    end

    --- Open `:Agentic` and record its session as `_G.s`.
    --- @param cmd string|nil The command; `Agentic` when nil
    local function open(cmd)
        child.cmd(cmd or "Agentic")
        child.flush()
        child.lua([[
_G.s = require("agentic.session_registry").owner_of_buf(vim.api.nvim_get_current_buf())
]])
    end

    --- Number of sessions in the child's registry.
    --- @return integer
    local function live_sessions()
        return child.lua_get(
            [[vim.tbl_count(require("agentic.session_registry").by_id)]]
        )
    end

    --- Fill the session's code selection, which opens the code panel.
    local function add_code()
        child.lua([[
_G.s.code_selection:add({
    lines = { "local x = 1" },
    start_line = 1,
    end_line = 1,
    file_path = "/tmp/a.lua",
    file_type = "lua",
})
]])
        child.flush()
    end

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("shows the chat in the current window without an input", function()
        local winid = child.api.nvim_get_current_win()

        open()

        assert.same({ "AgenticChat" }, get_tabpage_filetypes(0))
        assert.equal(winid, child.lua_get("_G.s.widget:home_win()"))
    end)

    it("opens the input below the chat on an insert key", function()
        open()
        local chat_win = child.api.nvim_get_current_win()

        child.type_keys("i")
        child.flush()

        assert.equal("AgenticInput", child.lua_get("vim.bo.filetype"))
        assert.equal("i", child.fn.mode())
        local below = child.fn.win_getid(child.fn.winnr("j"))
        assert.equal(child.api.nvim_get_current_win(), below)
        assert.equal(chat_win, child.fn.win_getid(child.fn.winnr("k")))
    end)

    it("binds <localLeader>p to switch provider and leaves i_CTRL-V", function()
        open()

        local input = child.lua_get("_G.s.widget.buf_nrs.input")
        --- @param lhs string
        --- @param mode string
        --- @return string|vim.NIL desc The desc of the input buffer's map,
        ---   `vim.NIL` with no map
        local function map_desc(lhs, mode)
            return child.lua_get(
                string.format(
                    [[vim.api.nvim_buf_call(%d, function() return vim.fn.maparg(%q, %q, false, true).desc end)]],
                    input,
                    lhs,
                    mode
                )
            )
        end
        assert.equal(
            "Agentic: Switch provider",
            map_desc("<localLeader>p", "n")
        )
        assert.equal(vim.NIL, map_desc("<C-v>", "i"))
    end)

    it(":tab Agentic moves the panels to the new tabpage", function()
        open()
        add_code()
        local first_tab = child.api.nvim_get_current_tabpage()
        assert.same({ "AgenticChat", "AgenticCode" }, get_tabpage_filetypes(0))

        child.cmd("tab Agentic")
        child.flush()

        assert.are_not.equal(first_tab, child.api.nvim_get_current_tabpage())
        assert.equal(
            child.api.nvim_get_current_win(),
            child.lua_get("_G.s.widget:home_win()")
        )
        assert.same({ "AgenticChat", "AgenticCode" }, get_tabpage_filetypes(0))
        assert.same({ "AgenticChat" }, get_tabpage_filetypes(first_tab))
        assert.equal(
            child.lua_get("_G.s.id"),
            child.lua_get([[require("agentic.session_registry").current().id]])
        )
    end)

    describe(":AgenticResume", function()
        --- Make every listing show `sessions`, and record each load as
        --- `_G.loaded`.
        --- @param sessions table[]
        local function stub_saved(sessions)
            child.lua(
                [[
local sessions = ...
local ChatHistory = require("agentic.ui.chat_history")
ChatHistory.list_sessions = function(_, callback) callback(sessions) end
ChatHistory.list_all_sessions = function(callback) callback(sessions) end
ChatHistory.read_saved = function() end
require("agentic.session_manager").load_acp_session = function(_, sid)
    _G.loaded = sid
end
]],
                { sessions }
            )
        end

        --- @param id string
        --- @param title string
        local function meta(id, title)
            return {
                session_id = id,
                title = title,
                timestamp = 0,
                file_path = "/x/" .. id .. ".json",
            }
        end

        --- Window of the quickfix list in the current tabpage, 0 when none.
        --- @return integer
        local function qf_win()
            return child.lua_get("vim.fn.getqflist({ winid = 0 }).winid")
        end

        before_each(function()
            stub_saved({ meta("sid-a", "First"), meta("sid-b", "Second") })
        end)

        it("<CR> from the input shows the pick in the home window", function()
            open()
            local chat_win = child.api.nvim_get_current_win()
            child.type_keys("i", "<Esc>")
            child.flush()
            assert.equal("AgenticInput", child.lua_get("vim.bo.filetype"))

            child.cmd("AgenticResume")
            child.flush()
            assert.are_not.equal(0, qf_win())
            child.type_keys("<CR>")
            child.flush()

            assert.equal("sid-a", child.lua_get("_G.loaded"))
            assert.equal(0, qf_win())
            local shown = child.api.nvim_win_get_buf(chat_win)
            assert.are_not.equal(
                child.lua_get("_G.s.id"),
                child.lua_get(
                    string.format(
                        [[require("agentic.session_registry").owner_of_buf(%d).id]],
                        shown
                    )
                )
            )
        end)

        for _, used in ipairs({ false, true }) do
            it(
                "a pick from "
                    .. (used and "a used" or "an unused")
                    .. " chat "
                    .. (used and "keeps" or "ends")
                    .. " its session",
                function()
                    open()
                    if used then
                        child.lua([[
table.insert(_G.s.chat_history.messages, { type = "user", text = "hi" })
]])
                    end

                    child.cmd("AgenticResume")
                    child.flush()
                    child.type_keys("<CR>")
                    child.flush()

                    assert.equal(used and 2 or 1, live_sessions())
                    assert.equal(not used, child.lua_get("_G.s.destroyed"))
                end
            )
        end

        it(
            ":tab AgenticResume then <CR> shows the pick in a new tabpage",
            function()
                open()
                child.lua([[
table.insert(_G.s.chat_history.messages, { type = "user", text = "hi" })
]])
                local first_tab = child.api.nvim_get_current_tabpage()

                child.cmd("tab AgenticResume")
                child.flush()
                child.type_keys("<CR>")
                child.flush()

                assert.are_not.equal(
                    first_tab,
                    child.api.nvim_get_current_tabpage()
                )
                assert.same({ "AgenticChat" }, get_tabpage_filetypes(0))
                assert.same({ "AgenticChat" }, get_tabpage_filetypes(first_tab))
            end
        )

        it("{query} with two title matches opens the picker on them", function()
            stub_saved({
                meta("sid-a", "foo"),
                meta("sid-b", "bar"),
                meta("sid-c", "Foo"),
            })

            child.cmd("AgenticResume foo")
            child.flush()

            assert.are_not.equal(0, qf_win())
            assert.equal(2, child.lua_get("#vim.fn.getqflist()"))
            assert.equal(vim.NIL, child.lua_get("_G.loaded"))
        end)
    end)

    it(":vert Agentic shows the chat in a vertical split", function()
        child.cmd("Agentic")
        child.cmd("enew")
        open("vert Agentic")

        assert.equal("row", child.lua_get("vim.fn.winlayout()[1]"))
        assert.same({ "", "AgenticChat" }, get_tabpage_filetypes(0))
    end)

    it("<C-^> closes the panels, and <C-^> back reopens them", function()
        child.cmd("edit " .. vim.fn.tempname())
        open()
        add_code()
        -- A used session survives having no window.
        child.lua([[
table.insert(_G.s.chat_history.messages, { type = "user", text = "hi" })
]])

        child.type_keys("<C-^>")
        child.flush()
        assert.same({ "" }, get_tabpage_filetypes(0))
        assert.equal(vim.NIL, child.lua_get("_G.s.widget:home_win()"))

        child.type_keys("<C-^>")
        child.flush()
        assert.same({ "AgenticChat", "AgenticCode" }, get_tabpage_filetypes(0))
    end)

    it("closing the chat window closes its panels", function()
        child.cmd("enew")
        child.cmd("vsplit")
        open()
        add_code()
        child.type_keys("i")
        child.flush()
        child.cmd("stopinsert")

        child.api.nvim_win_close(child.lua_get("_G.s.widget:home_win()"), true)
        child.flush()

        assert.same({ "" }, get_tabpage_filetypes(0))
    end)

    it(":q on a full-view chat quits", function()
        open()
        add_code()

        local ok, err = pcall(child.cmd, "q")

        assert.is_false(ok)
        -- The child exited.
        assert.truthy(tostring(err):find("closed by the peer", 1, true))
    end)

    it(":q with an unsent draft is refused and the input comes back", function()
        open()
        child.type_keys("i")
        child.flush()
        child.type_keys("draft", "<Esc>")
        child.flush()
        child.cmd("wincmd k")

        local ok = pcall(child.cmd, "q")
        child.flush()

        assert.is_false(ok)
        assert.same({ "AgenticChat", "AgenticInput" }, get_tabpage_filetypes(0))
    end)

    it(":Agentic in another tabpage shows the last active session", function()
        open()
        local first = child.lua_get("_G.s.id")

        child.cmd("tabnew")
        open()

        assert.equal(first, child.lua_get("_G.s.id"))
        assert.equal(1, live_sessions())
        assert.has_no_errors(function()
            child.cmd("tabclose")
        end)
        assert.equal(1, live_sessions())
    end)

    it("new_session leaves the previous session alive", function()
        open()
        local first = child.lua_get("_G.s.id")
        child.lua([[
table.insert(_G.s.chat_history.messages, { type = "user", text = "hi" })
]])

        child.new_session()

        assert.equal(2, live_sessions())
        assert.are_not.equal(
            first,
            child.lua_get(
                [[require("agentic.session_registry").owner_of_buf(0).id]]
            )
        )
    end)

    --- Open `:Agentic` and focus its input window in normal mode.
    --- @return integer home The chat's home window
    local function open_into_input()
        open()
        local home = child.lua_get("_G.s.widget:home_win()")
        child.type_keys("i")
        child.flush()
        child.type_keys("<Esc>")
        child.flush()
        assert.equal("AgenticInput", child.lua_get("vim.bo.filetype"))
        return home
    end

    --- Whether any window shows `bufnr`.
    --- @param bufnr integer
    --- @return boolean
    local function is_shown(bufnr)
        return #child.fn.win_findbuf(bufnr) > 0
    end

    it("new_session from the input shows the chat in the home", function()
        local home = open_into_input()
        child.lua([[
table.insert(_G.s.chat_history.messages, { type = "user", text = "hi" })
]])
        local old_chat = child.lua_get("_G.s.widget.buf_nrs.agent")
        local old_input = child.lua_get("_G.s.widget.buf_nrs.input")

        child.new_session()

        local new_chat = child.lua_get(
            [[require("agentic.session_registry").owner_of_buf(0).widget.buf_nrs.agent]]
        )
        assert.equal(new_chat, child.api.nvim_win_get_buf(home))
        assert.equal(home, child.api.nvim_get_current_win())
        assert.is_false(is_shown(old_chat))
        assert.is_false(is_shown(old_input))
        assert.equal(2, live_sessions())
    end)

    it("new_session from the input of an unused session destroys it", function()
        open_into_input()
        local old_id = child.lua_get("_G.s.id")
        local old_chat = child.lua_get("_G.s.widget.buf_nrs.agent")
        local old_input = child.lua_get("_G.s.widget.buf_nrs.input")

        child.new_session()

        assert.equal(1, live_sessions())
        assert.are_not.equal(
            old_id,
            child.lua_get(
                [[require("agentic.session_registry").owner_of_buf(0).id]]
            )
        )
        assert.is_false(is_shown(old_chat))
        assert.is_false(is_shown(old_input))
    end)

    it("add_file goes to the session entered last", function()
        child.cmd("edit tests/init.lua")
        local source_win = child.api.nvim_get_current_win()
        child.cmd("vsplit")
        open()
        local first = child.lua_get("_G.s.id")
        child.cmd("split")
        child.new_session()
        child.lua(
            [[
_G.second = require("agentic.session_registry").owner_of_buf(0)
_G.first = require("agentic.session_registry").by_id[...]
]],
            { first }
        )
        -- Both chats show in this tabpage; enter the first one last.
        child.api.nvim_set_current_win(
            child.lua_get(
                "vim.fn.win_findbuf(_G.first.widget.buf_nrs.agent)[1]"
            )
        )
        child.api.nvim_set_current_win(source_win)

        child.lua([[require("agentic").add_file()]])
        child.flush()

        assert.equal(1, child.lua_get("_G.first.file_list:count()"))
        assert.equal(0, child.lua_get("_G.second.file_list:count()"))
    end)

    it("tabclose destroys only the unused sessions it hides", function()
        local ids = {}
        for i = 1, 3 do
            if i > 1 then
                child.cmd("tabnew")
            end
            child.new_session()
            ids[i] = child.lua_get(
                [[require("agentic.session_registry").owner_of_buf(0).id]]
            )
        end

        child.cmd("1tabclose")
        child.cmd("2tabclose")
        child.flush()

        assert.same(
            { ids[2] },
            child.lua_get(
                [[vim.tbl_keys(require("agentic.session_registry").by_id)]]
            )
        )
    end)

    it("handles tabclose while in insert mode without errors", function()
        open()
        child.type_keys("i")

        child.cmd("tabnew")
        child.type_keys("<Esc>")
        open()
        child.type_keys("i")

        assert.equal("i", child.fn.mode())

        assert.has_no_errors(function()
            child.cmd("tabclose!")
            vim.uv.sleep(200)
        end)
    end)
end)
