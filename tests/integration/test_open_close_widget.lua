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
        assert.equal(
            chat_win,
            child.fn.win_getid(child.fn.winnr("k"))
        )
    end)

    it("binds <localLeader>p to switch provider and leaves i_CTRL-V", function()
        open()

        local input = child.lua_get("_G.s.widget.buf_nrs.input")
        --- @param lhs string
        --- @param mode string
        --- @return string|vim.NIL desc The desc of the input buffer's map,
        ---   `vim.NIL` with no map
        local function map_desc(lhs, mode)
            return child.lua_get(string.format(
                [[vim.api.nvim_buf_call(%d, function() return vim.fn.maparg(%q, %q, false, true).desc end)]],
                input,
                lhs,
                mode
            ))
        end
        assert.equal("Agentic: Switch provider", map_desc("<localLeader>p", "n"))
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
            child.lua_get(
                [[require("agentic.session_registry").bound_session(vim.api.nvim_get_current_tabpage()).id]]
            )
        )
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

    it("creates independent sessions per tabpage", function()
        open()
        local tab1_id = child.api.nvim_get_current_tabpage()

        child.cmd("tabnew")
        open()
        assert.is_not.equal(tab1_id, child.api.nvim_get_current_tabpage())

        assert.equal(
            2,
            child.lua_get(
                [[vim.tbl_count(require("agentic.session_registry").by_id)]]
            )
        )

        assert.has_no_errors(function()
            child.cmd("tabclose")
        end)

        assert.equal(
            1,
            child.lua_get(
                [[vim.tbl_count(require("agentic.session_registry").by_id)]]
            )
        )
    end)

    it(
        "tabclose destroys the closed tab's session, not the one at its number",
        function()
            local tabs = {}
            for i = 1, 3 do
                if i > 1 then
                    child.cmd("tabnew")
                end
                child.cmd("Agentic")
                tabs[i] = child.api.nvim_get_current_tabpage()
            end
            child.flush()

            -- Handles 1, 2, 3 at numbers 1, 2, 3. Closing handle 1 moves handle 3
            -- to number 2; closing it must not destroy handle 2's session.
            child.cmd("1tabclose")
            child.cmd("2tabclose")
            child.flush()

            local live = child.lua_get([[
vim.tbl_keys(require("agentic.session_registry").tab_bindings)
]])
            assert.same({ tabs[2] }, live)
        end
    )

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
