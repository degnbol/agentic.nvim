local Child = require("tests.helpers.child")
local assert = require("tests.helpers.assert")

describe("agentic.ui.MentionHighlight", function()
    local child = Child.new()

    before_each(function()
        child.launch()
        child.lua([[
            local SessionRegistry = require("agentic.session_registry")
            SessionRegistry.by_id.s = {
                cwd = function()
                    return vim.fn.getcwd()
                end,
            }
            _G.marks = {}
            local set_extmark = vim.api.nvim_buf_set_extmark
            vim.api.nvim_buf_set_extmark = function(bufnr, ns, row, col, opts)
                if opts.ephemeral then
                    _G.marks[col .. "-" .. opts.end_col] = opts.hl_group
                end
                return set_extmark(bufnr, ns, row, col, opts)
            end
            require("agentic.ui.mention_highlight").register()
        ]])
    end)
    after_each(child.stop)

    --- Ephemeral marks drawn for a buffer of `filetype` holding `line`.
    --- @param filetype string
    --- @param line string
    --- @param agentic_window string|nil
    --- @return table<string, string> marks hl_group by `"col-end_col"`
    local function draw(filetype, line, agentic_window)
        child.lua(
            [[
            local filetype, line, agentic_window = ...
            local bufnr = vim.api.nvim_get_current_buf()
            vim.b[bufnr].agentic_session_id = "s"
            vim.b[bufnr].agentic_window = agentic_window
            vim.bo[bufnr].filetype = filetype
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
            _G.marks = {}
            vim.cmd("redraw!")
        ]],
            { filetype, line, agentic_window }
        )
        return child.lua_get("_G.marks")
    end

    it("underlines a path that exists", function()
        assert.same(
            { ["4-5"] = "AgenticMentionPrefix", ["5-13"] = "AgenticMention" },
            draw("AgenticInput", "see @Makefile.")
        )
    end)

    it("highlights only the @ of a missing path", function()
        assert.same(
            { ["0-1"] = "AgenticMentionPrefix" },
            draw("AgenticChat", "@nope.lua")
        )
    end)

    it("skips other filetypes", function()
        assert.same({}, draw("AgenticCode", "@Makefile"))
    end)

    it("skips a subagent message input", function()
        assert.same({}, draw("AgenticInput", "@Makefile", "message"))
    end)
end)
