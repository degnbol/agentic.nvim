local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Buffer Naming", function()
    local child = Child:new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    --- Gets buffer basename for a panel in the current tabpage
    --- @param panel string Panel name (chat, input, code, files, todos)
    --- @return string basename
    local function get_panel_basename(panel)
        local bufname = child.lua_get(string.format(
            [[
(function()
    local tab_id = vim.api.nvim_get_current_tabpage()
    local session = require("agentic.session_registry").bound_session(tab_id)
    return vim.api.nvim_buf_get_name(session.widget.buf_nrs.%s)
end)()
]],
            panel
        ))
        return child.lua_get(
            string.format([[vim.fn.fnamemodify("%s", ":t")]], bufname)
        )
    end

    it("the chat name's tail is the session title", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()
        assert.equal("chat", get_panel_basename("chat"))

        child.lua([[
local tab = vim.api.nvim_get_current_tabpage()
require("agentic.session_registry").bound_session(tab).widget:set_chat_title("fix a/b")
]])

        assert.equal("fix a-b", get_panel_basename("chat"))
    end)

    it("the unread badge stays out of the name", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()
        child.lua([[
local tab = vim.api.nvim_get_current_tabpage()
require("agentic.session_registry").bound_session(tab).widget:set_unread_badge("[done]")
]])

        assert.equal("chat", get_panel_basename("chat"))
    end)

    it("names are unique across instances", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()
        child.cmd("tabnew")
        child.lua([[ require("agentic").toggle() ]])
        child.flush()
        vim.uv.sleep(50)
        child.flush()

        local names = child.lua_get([[
(function()
    local names = {}
    for _, session in pairs(require("agentic.session_registry").by_id) do
        for _, bufnr in pairs(session.widget.buf_nrs) do
            table.insert(names, vim.api.nvim_buf_get_name(bufnr))
        end
    end
    return names
end)()
]])

        local seen = {}
        for _, name in ipairs(names) do
            assert.is_true(vim.startswith(name, "agentic://"))
            assert.is_nil(seen[name])
            seen[name] = true
        end
        assert.equal(16, #names)
        assert.equal("", child.lua_get("vim.v.errmsg"))
    end)

    it("renames leave no buffer behind", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()
        vim.uv.sleep(50)
        child.flush()

        local unloaded = child.lua_get([[
#vim.tbl_filter(function(b)
    return not vim.api.nvim_buf_is_loaded(b)
end, vim.api.nvim_list_bufs())
]])
        assert.equal(0, unloaded)
    end)

    it("prevents buffer name collision errors", function()
        for _ = 1, 5 do
            child.lua([[ require("agentic").toggle() ]])
            child.flush()
            child.cmd("tabnew")
        end

        local session_count = child.lua_get([[
            vim.tbl_count(require("agentic.session_registry").by_id)
        ]])

        assert.equal(5, session_count)
    end)

    it("panel names keep their panel as the tail", function()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()

        for _, panel in ipairs({ "input", "code", "files", "todos" }) do
            assert.equal(panel, get_panel_basename(panel))
        end
    end)
end)
