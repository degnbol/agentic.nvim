local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Session identity", function()
    local child = Child:new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    --- Open a session's widget in the first tab, then show its chat buffer in
    --- the only window of a second tab.
    --- @return integer owner_tab
    --- @return integer foreign_tab
    local function show_chat_in_foreign_tab()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()
        local owner_tab = child.api.nvim_get_current_tabpage()
        child.lua([[
local tab = vim.api.nvim_get_current_tabpage()
_G.owner = require("agentic.session_registry").bound_session(tab)
]])
        child.cmd("tabnew")
        child.cmd("buffer " .. child.lua_get("_G.owner.widget.buf_nrs.chat"))
        return owner_tab, child.api.nvim_get_current_tabpage()
    end

    it("a widget map in a foreign tab acts on the owner", function()
        show_chat_in_foreign_tab()
        child.lua([[
_G.stopped = false
_G.owner.stop_generation = function() _G.stopped = true end
]])

        child.type_keys("<C-c>")

        assert.is_true(child.lua_get("_G.stopped"))
        assert.equal(
            1,
            child.lua_get(
                [[vim.tbl_count(require("agentic.session_registry").by_id)]]
            )
        )
    end)

    it("open from a shown chat binds its session to the tab", function()
        local owner_tab, foreign_tab = show_chat_in_foreign_tab()

        child.lua([[ require("agentic").open() ]])
        child.flush()

        local registry = [[require("agentic.session_registry")]]
        assert.equal(
            foreign_tab,
            child.lua_get(registry .. ".tab_of(_G.owner.id)")
        )
        assert.equal(
            1,
            child.lua_get("vim.tbl_count(" .. registry .. ".by_id)")
        )
        assert.is_true(child.lua_get("_G.owner.widget:is_open()"))
        assert.equal(
            foreign_tab,
            child.lua_get(
                "vim.api.nvim_win_get_tabpage(_G.owner.widget.win_nrs.chat)"
            )
        )
        -- The widget left the tab it was bound to.
        assert.equal(1, #child.api.nvim_tabpage_list_wins(owner_tab))
    end)

    it("an insert key in a foreign tab opens the input below", function()
        local owner_tab, foreign_tab = show_chat_in_foreign_tab()
        local owner_wins = #child.api.nvim_tabpage_list_wins(owner_tab)

        child.type_keys("i")
        child.flush()

        assert.equal(
            child.lua_get("_G.owner.widget.buf_nrs.input"),
            child.api.nvim_get_current_buf()
        )
        assert.equal(foreign_tab, child.api.nvim_get_current_tabpage())
        assert.equal(2, #child.api.nvim_tabpage_list_wins(foreign_tab))
        assert.equal(owner_wins, #child.api.nvim_tabpage_list_wins(owner_tab))
    end)
end)
