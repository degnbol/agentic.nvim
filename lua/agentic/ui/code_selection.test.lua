local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.CodeSelection", function()
    local CodeSelection = require("agentic.ui.code_selection")

    --- @type integer
    local bufnr
    --- @type agentic.ui.CodeSelection
    local code_selection
    --- @type TestSpy
    local on_change_spy

    --- @param lines string[]
    --- @return agentic.Selection
    local function selection_of(lines)
        return {
            lines = lines,
            start_line = 10,
            end_line = 9 + #lines,
            file_path = "test.lua",
            file_type = "lua",
        }
    end

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        on_change_spy = spy.new(function() end)
        code_selection =
            CodeSelection:new(bufnr, on_change_spy --[[@as function]])
    end)

    after_each(function()
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("add", function()
        it("adds selections in order", function()
            local selection1 = selection_of({ "function a()" })
            local selection2 = selection_of({ "function b()" })

            code_selection:add(selection1)
            code_selection:add(selection2)

            assert.same({ selection1, selection2 }, code_selection:take())
        end)

        it("does not add selection with empty lines", function()
            code_selection:add(selection_of({}))

            assert.is_true(code_selection:is_empty())
            assert.spy(on_change_spy).was.called(0)
        end)
    end)

    describe("fence_rows", function()
        it("opens with the file type and location", function()
            assert.same(
                {
                    "```lua test.lua#L10-L11",
                    "local x = 1",
                    "return x",
                    "```",
                },
                CodeSelection.fence_rows(
                    selection_of({ "local x = 1", "return x" })
                )
            )
        end)

        it("keeps blank lines", function()
            assert.same(
                { "```lua test.lua#L10-L12", "a", "", "b", "```" },
                CodeSelection.fence_rows(selection_of({ "a", "", "b" }))
            )
        end)

        it("fences past a ``` line in the snippet", function()
            assert.same({
                "````lua test.lua#L10-L12",
                "```",
                "x",
                "```",
                "````",
            }, CodeSelection.fence_rows(
                selection_of({ "```", "x", "```" })
            ))
        end)
    end)

    it(
        "renders a selection containing a fence as one removable block",
        function()
            code_selection:add(selection_of({ "```", "x", "```" }))
            code_selection:add(selection_of({ "y" }))

            code_selection:remove_rows(3, 3)

            assert.same(
                { "```lua test.lua#L10-L10", "y", "```" },
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
        end
    )
end)
