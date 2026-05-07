local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("diff_jump", function()
    --- @type agentic.ui.DiffJump
    local DiffJump
    --- @type agentic.utils.FileSystem
    local FileSystem

    local read_stub
    local path_stub

    before_each(function()
        FileSystem = require("agentic.utils.file_system")
        DiffJump = require("agentic.ui.diff_jump")

        read_stub = spy.stub(FileSystem, "read_from_buffer_or_disk")
        path_stub = spy.stub(FileSystem, "to_absolute_path")
        path_stub:invokes(function(path)
            return path
        end)
    end)

    after_each(function()
        read_stub:revert()
        path_stub:revert()
    end)

    --- Build a minimal ToolCallBlock fixture for compute_target.
    --- @param old string[]
    --- @param new string[]
    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function make_edit_block(old, new)
        return {
            tool_call_id = "t1",
            kind = "edit",
            argument = "/file.lua",
            status = "completed",
            diff = { old = old, new = new },
        } --[[@as agentic.ui.MessageWriter.ToolCallBlock]]
    end

    describe("compute_target", function()
        it(
            "maps cursor on a 'new' line to the post-edit file row + col",
            function()
                read_stub:returns({
                    "alpha",
                    "beta",
                    "gamma",
                    "delta",
                    "epsilon",
                })

                local block = make_edit_block(
                    { "beta", "gamma", "delta" },
                    { "BETA", "GAMMA", "DELTA" }
                )

                -- Layout for non-markdown diff (block_start_row = 0):
                --   row 0: ### Edit
                --   row 1: `/file.lua`
                --   row 2: ```lua
                --   row 3: beta             ← old
                --   row 4: gamma            ← old
                --   row 5: delta            ← old
                --   row 6: BETA             ← new
                --   row 7: GAMMA            ← new   (cursor here, col 3)
                --   row 8: DELTA            ← new
                local target = DiffJump.compute_target(block, 0, 7, 3)

                assert.is_not_nil(target)
                ---@cast target -nil
                assert.equal(true, target.exact)
                -- File line for second new = block.start_line + 2 - 1
                -- block.start_line = 2 (matched "beta" at row 2 in the file)
                assert.equal(3, target.file_row)
                assert.equal(3, target.file_col)
            end
        )

        it("falls back to hunk start when cursor is on a 'old' line", function()
            read_stub:returns({ "a", "b", "c", "d" })

            -- Pure deletion: old has 2 lines, new has 0
            local block = make_edit_block({ "b", "c" }, {})

            -- Layout (non-markdown):
            --   row 0: ### Edit
            --   row 1: `/file.lua`
            --   row 2: ```lua
            --   row 3: b   ← old (cursor here)
            --   row 4: c   ← old
            local target = DiffJump.compute_target(block, 0, 3, 0)

            assert.is_not_nil(target)
            ---@cast target -nil
            assert.equal(false, target.exact)
            assert.equal(2, target.file_row)
        end)

        it(
            "maps an 'old' line in a paired modification to the matching new line",
            function()
                read_stub:returns({ "x", "old1", "old2", "y" })

                local block = make_edit_block({ "old1", "old2" }, { "new1", "new2" })

                -- Layout:
                --   row 0: ### Edit
                --   row 1: `/file.lua`
                --   row 2: ```lua
                --   row 3: old1   ← old (cursor here, col 2)
                --   row 4: old2   ← old
                --   row 5: new1   ← new
                --   row 6: new2   ← new
                local target = DiffJump.compute_target(block, 0, 3, 2)

                assert.is_not_nil(target)
                ---@cast target -nil
                -- old1 pairs with new1 (both at index 1) → file row 2
                assert.equal(2, target.file_row)
                assert.equal(2, target.file_col)
                -- exact=false because cursor was on the deleted/old side
                assert.equal(false, target.exact)
            end
        )

        it("returns first hunk fallback when cursor on header", function()
            read_stub:returns({ "a", "b", "c" })

            local block = make_edit_block({ "b" }, { "B" })

            -- Cursor on block_start_row (### Edit header)
            local target = DiffJump.compute_target(block, 0, 0, 0)

            assert.is_not_nil(target)
            ---@cast target -nil
            assert.equal(false, target.exact)
            assert.equal(2, target.file_row) -- hunk start
        end)

        it("returns nil when block has no diff", function()
            local block = {
                tool_call_id = "t1",
                kind = "edit",
                argument = "/file.lua",
                status = "completed",
            } --[[@as agentic.ui.MessageWriter.ToolCallBlock]]

            local target = DiffJump.compute_target(block, 0, 5, 0)

            assert.is_nil(target)
        end)

        it("returns nil when block has empty argument", function()
            local block = make_edit_block({ "a" }, { "A" })
            block.argument = ""

            local target = DiffJump.compute_target(block, 0, 5, 0)

            assert.is_nil(target)
        end)

        it("maps new-file insertion to consecutive file rows", function()
            -- Empty file (read returns empty), new content is the whole file.
            read_stub:returns({})

            local block = make_edit_block({}, { "L1", "L2", "L3" })

            -- New-file diff: start_line = 1.
            -- Layout:
            --   row 0: ### Edit
            --   row 1: `/file.lua`
            --   row 2: ```lua
            --   row 3: L1   (cursor here, col 1)
            --   row 4: L2
            --   row 5: L3
            local target = DiffJump.compute_target(block, 0, 5, 1)

            assert.is_not_nil(target)
            ---@cast target -nil
            assert.equal(true, target.exact)
            assert.equal(3, target.file_row)
            assert.equal(1, target.file_col)
        end)

        it("accounts for absent fence on markdown files", function()
            read_stub:returns({ "para1", "old md line", "para3" })

            local block = make_edit_block({ "old md line" }, { "new md line" })
            block.argument = "/notes.md"

            -- Layout (markdown, no fences):
            --   row 0: ### Edit
            --   row 1: `/notes.md`
            --   row 2: old md line   ← old
            --   row 3: new md line   ← new (cursor here)
            local target = DiffJump.compute_target(block, 0, 3, 4)

            assert.is_not_nil(target)
            ---@cast target -nil
            assert.equal(true, target.exact)
            assert.equal(2, target.file_row)
            assert.equal(4, target.file_col)
        end)
    end)

    describe("find_block_at_row", function()
        local Renderer

        before_each(function()
            Renderer = require("agentic.ui.tool_call_renderer")
        end)

        it("returns the block whose extmark range contains the row", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "header",
                "body1",
                "body2",
                "footer",
                "after",
            })

            local extmark_id = vim.api.nvim_buf_set_extmark(
                bufnr,
                Renderer.NS_TOOL_BLOCKS,
                0,
                0,
                { end_row = 3, right_gravity = true, end_right_gravity = false }
            )

            local block = {
                tool_call_id = "x",
                kind = "edit",
                argument = "/file.lua",
                status = "completed",
                extmark_id = extmark_id,
            } --[[@as agentic.ui.MessageWriter.ToolCallBlock]]

            local found, start_row, end_row =
                DiffJump.find_block_at_row(bufnr, 2, { x = block })

            assert.equal(block, found)
            assert.equal(0, start_row)
            assert.equal(3, end_row)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("returns nil when row is outside any block", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "a",
                "b",
                "c",
                "d",
            })

            local extmark_id = vim.api.nvim_buf_set_extmark(
                bufnr,
                Renderer.NS_TOOL_BLOCKS,
                0,
                0,
                { end_row = 1, right_gravity = true, end_right_gravity = false }
            )

            local block = {
                tool_call_id = "x",
                kind = "edit",
                argument = "/file.lua",
                status = "completed",
                extmark_id = extmark_id,
            } --[[@as agentic.ui.MessageWriter.ToolCallBlock]]

            local found =
                DiffJump.find_block_at_row(bufnr, 3, { x = block })

            assert.is_nil(found)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)
end)
