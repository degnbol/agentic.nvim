local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("Add diagnostics to session", function()
    local child = Child:new()

    before_each(function()
        child.setup()
        child.cmd([[ edit tests/init.lua ]])
    end)

    after_each(function()
        child.stop()
    end)

    --- Show the chat in a split and go back to the window showing the file.
    local function show_chat_beside()
        child.cmd("vsplit")
        child.cmd("Agentic")
        child.flush()
        child.cmd("wincmd p")
    end

    --- Record `Logger.notify` messages in `_G.notes`.
    local function record_notes()
        child.lua([[
_G.notes = {}
require("agentic.utils.logger").notify = function(msg)
    table.insert(_G.notes, msg)
end
]])
    end

    local function get_session_diagnostics()
        return child.lua([[
            local session = require("agentic.session_registry").current()
            return session.diagnostics_list:get_diagnostics()
        ]])
    end

    --- @return integer|vim.NIL winid
    local function diagnostics_panel_win()
        return child.lua_get([[
require("agentic.session_registry").current().widget:panel_win("diagnostics")
]])
    end

    it("Adds cursor-line diagnostics and opens diagnostics window", function()
        child.lua([[
            local bufnr = vim.api.nvim_get_current_buf()
            local ns = vim.api.nvim_create_namespace("test_diagnostics")
            vim.diagnostic.set(ns, bufnr, {
                {
                    lnum = 0,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "Test error on line 1",
                },
            })
        ]])

        show_chat_beside()
        record_notes()
        child.lua([[ vim.api.nvim_win_set_cursor(0, {1, 0}) ]])
        child.lua([[ require("agentic").add_current_line_diagnostics() ]])
        child.flush()

        local diagnostics = get_session_diagnostics()
        assert.equal(1, #diagnostics)
        assert.equal("Test error on line 1", diagnostics[1].message)
        assert.equal(0, diagnostics[1].lnum)
        assert.equal(vim.diagnostic.severity.ERROR, diagnostics[1].severity)

        local diagnostics_winid = diagnostics_panel_win()
        assert.is_not.equal(vim.NIL, diagnostics_winid)
        assert.is_true(child.api.nvim_win_is_valid(diagnostics_winid))
        -- The panel shows the change.
        assert.same({}, child.lua_get("_G.notes"))
    end)

    it(
        "Adds all buffer diagnostics and notifies when the chat is not shown",
        function()
            child.lua([[
            local bufnr = vim.api.nvim_get_current_buf()
            local ns = vim.api.nvim_create_namespace("test_diagnostics")
            vim.diagnostic.set(ns, bufnr, {
                {
                    lnum = 0,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = "First error",
                },
                {
                    lnum = 5,
                    col = 10,
                    severity = vim.diagnostic.severity.WARN,
                    message = "Warning message",
                },
                {
                    lnum = 10,
                    col = 0,
                    severity = vim.diagnostic.severity.HINT,
                    message = "Hint for improvement",
                },
            })
        ]])

            record_notes()
            child.lua([[ require("agentic").add_buffer_diagnostics() ]])
            child.flush()

            local diagnostics = get_session_diagnostics()
            assert.equal(3, #diagnostics)
            assert.equal("First error", diagnostics[1].message)
            assert.equal(vim.diagnostic.severity.ERROR, diagnostics[1].severity)
            assert.equal("Warning message", diagnostics[2].message)
            assert.equal(vim.diagnostic.severity.WARN, diagnostics[2].severity)
            assert.equal("Hint for improvement", diagnostics[3].message)
            assert.equal(vim.diagnostic.severity.HINT, diagnostics[3].severity)

            assert.same(
                { "Added 3 diagnostics to the chat context" },
                child.lua_get("_G.notes")
            )
            assert.equal(1, #child.api.nvim_tabpage_list_wins(0))
        end
    )

    it("Opens no diagnostics panel when no diagnostics exist", function()
        show_chat_beside()
        record_notes()

        child.lua([[ require("agentic").add_current_line_diagnostics() ]])
        child.flush()

        assert.equal(0, #get_session_diagnostics())
        assert.same(
            { "No diagnostics found on the current line" },
            child.lua_get("_G.notes")
        )
        assert.equal(vim.NIL, diagnostics_panel_win())
    end)
end)
