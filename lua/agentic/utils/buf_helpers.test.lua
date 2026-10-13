local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local MiniTest = require("mini.test")

describe("BufHelpers", function()
    --- @type agentic.utils.BufHelpers
    local BufHelpers

    before_each(function()
        BufHelpers = require("agentic.utils.buf_helpers")
    end)

    describe("with_modifiable", function()
        it("should allow writing to non-modifiable buffer", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            vim.bo[bufnr].modifiable = false

            local ok, err = pcall(function()
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "should fail" }
                )
            end)
            assert.is_false(ok)
            assert.is_not_nil(err)

            BufHelpers.with_modifiable(bufnr, function(buf)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
            end)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal(1, #lines)
            assert.are.equal("hello world", lines[1])

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should handle nested with_modifiable calls", function()
            local bufnr = vim.api.nvim_create_buf(false, true)

            vim.bo[bufnr].modifiable = false

            BufHelpers.with_modifiable(bufnr, function(buf)
                vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first line" })

                BufHelpers.with_modifiable(buf, function(inner_buf)
                    vim.api.nvim_buf_set_lines(
                        inner_buf,
                        -1,
                        -1,
                        false,
                        { "second line" }
                    )
                end)

                vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "third line" })
            end)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.are.equal(3, #lines)
            assert.are.equal("first line", lines[1])
            assert.are.equal("second line", lines[2])
            assert.are.equal("third line", lines[3])

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("is_buffer_blank", function()
        it("should return true for buffer with single empty line", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

            assert.is_true(BufHelpers.is_buffer_blank(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return true for single line with only whitespace", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "  \t  " })

            assert.is_true(BufHelpers.is_buffer_blank(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return true for multiple lines all whitespace", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "   ", "\t", "", "  \t  " }
            )

            assert.is_true(BufHelpers.is_buffer_blank(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return false for buffer with text", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })

            assert.is_false(BufHelpers.is_buffer_blank(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("should return false for multiple lines with text", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "   ", "", "text", "  " }
            )

            assert.is_false(BufHelpers.is_buffer_blank(bufnr))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("redraw_if_cmdline", function()
        local mode_stub, cmd_stub

        before_each(function()
            mode_stub = spy.stub(vim.fn, "mode")
            cmd_stub = spy.stub(vim, "cmd")
        end)

        after_each(function()
            mode_stub:revert()
            cmd_stub:revert()
        end)

        it("redraws while in cmdline mode", function()
            mode_stub:returns("c")

            BufHelpers.redraw_if_cmdline()

            assert.are.equal(1, cmd_stub.call_count)
            assert.is_true(cmd_stub:called_with("redraw"))
        end)

        it("does nothing outside cmdline mode", function()
            mode_stub:returns("n")

            BufHelpers.redraw_if_cmdline()

            assert.are.equal(0, cmd_stub.call_count)
        end)
    end)

    describe("trailing_blank_rows", function()
        local bufnr

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
        end)

        after_each(function()
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("counts whitespace-only rows as blank", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "text", "  " })
            assert.equal(1, BufHelpers.trailing_blank_rows(bufnr, 2))
        end)

        it("stops at the first row with text", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "text" })
            assert.equal(0, BufHelpers.trailing_blank_rows(bufnr, 2))
        end)

        it("counts at most max rows", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "", "", "" })
            assert.equal(2, BufHelpers.trailing_blank_rows(bufnr, 2))
        end)

        it("counts the one row of an empty buffer", function()
            assert.equal(1, BufHelpers.trailing_blank_rows(bufnr, 2))
        end)
    end)

    describe("append_paragraph", function()
        local bufnr

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
        end)

        after_each(function()
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        local function lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        it("replaces an empty buffer", function()
            assert.equal(0, BufHelpers.append_paragraph(bufnr, { "a", "b" }))
            assert.same({ "a", "b" }, lines())
        end)

        it("replaces a whitespace-only buffer", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { " ", "\t" })
            assert.equal(0, BufHelpers.append_paragraph(bufnr, { "a" }))
            assert.same({ "a" }, lines())
        end)

        it("puts a blank line after a last line with text", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x", "y" })
            assert.equal(3, BufHelpers.append_paragraph(bufnr, { "a" }))
            assert.same({ "x", "y", "", "a" }, lines())
        end)

        it("adds no blank line after a blank last line", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x", "" })
            assert.equal(2, BufHelpers.append_paragraph(bufnr, { "a" }))
            assert.same({ "x", "", "a" }, lines())
        end)

        it("reports a change that starts after the last line", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x", "y" })
            local start_rows = {}
            vim.api.nvim_buf_attach(bufnr, false, {
                on_bytes = function(_, _, _, start_row)
                    table.insert(start_rows, start_row)
                end,
            })

            BufHelpers.append_paragraph(bufnr, { "a" })

            assert.same({ 2 }, start_rows)
        end)
    end)

    describe("prepend_paragraph", function()
        local bufnr

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
        end)

        after_each(function()
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        local function lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        it("replaces an empty buffer", function()
            BufHelpers.prepend_paragraph(bufnr, { "a", "b" })
            assert.same({ "a", "b" }, lines())
        end)

        it("replaces a whitespace-only buffer", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { " ", "\t" })
            BufHelpers.prepend_paragraph(bufnr, { "a" })
            assert.same({ "a" }, lines())
        end)

        it("adds no blank line before a blank first line", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "", "x" })
            BufHelpers.prepend_paragraph(bufnr, { "a" })
            assert.same({ "a", "", "x" }, lines())
        end)

        it("puts a blank line before a first line with text", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "x", "y" })
            BufHelpers.prepend_paragraph(bufnr, { "a" })
            assert.same({ "a", "", "x", "y" }, lines())
        end)
    end)

    describe("prepend_draft", function()
        local bufnr

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
            -- A `nofile` buffer is never `modified`.
            vim.bo[bufnr].buftype = "acwrite"
        end)

        after_each(function()
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        local function lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        it("adds the text's lines above the draft", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "draft" })

            BufHelpers.prepend_draft(bufnr, "\nfirst\nsecond\n")

            assert.same({ "first", "second", "", "draft" }, lines())
            assert.is_true(vim.bo[bufnr].modified)
        end)

        it("adds nothing for empty text", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "draft" })
            vim.bo[bufnr].modified = false

            BufHelpers.prepend_draft(bufnr, "\n")

            assert.same({ "draft" }, lines())
            assert.is_false(vim.bo[bufnr].modified)
        end)

        it("keeps a window's cursor on its text", function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two" })
            local current = vim.api.nvim_get_current_win()
            local winid = vim.api.nvim_open_win(bufnr, false, { split = "below" })
            MiniTest.finally(function()
                vim.api.nvim_win_close(winid, true)
            end)
            vim.api.nvim_win_set_cursor(winid, { 2, 1 })

            BufHelpers.prepend_draft(bufnr, "refused")

            assert.same({ 4, 1 }, vim.api.nvim_win_get_cursor(winid))
            assert.equal(current, vim.api.nvim_get_current_win())
        end)
    end)

    describe("rename", function()
        --- @param name string
        --- @return integer[]
        local function bufs_named(name)
            return vim.tbl_filter(function(b)
                return vim.api.nvim_buf_get_name(b) == name
            end, vim.api.nvim_list_bufs())
        end

        it("leaves no buffer holding the old name", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            BufHelpers.rename(bufnr, "test://rename/old")
            BufHelpers.rename(bufnr, "test://rename/new")

            assert.same({}, bufs_named("test://rename/old"))
            assert.same({ bufnr }, bufs_named("test://rename/new"))

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("raises E95 when a loaded buffer holds the name", function()
            local holder = vim.api.nvim_create_buf(false, true)
            local bufnr = vim.api.nvim_create_buf(false, true)
            BufHelpers.rename(holder, "test://rename/taken")

            local ok, err =
                pcall(BufHelpers.rename, bufnr, "test://rename/taken")

            assert.is_false(ok)
            assert.truthy(tostring(err):find("E95"))
            assert.is_true(vim.api.nvim_buf_is_valid(holder))

            vim.api.nvim_buf_delete(holder, { force = true })
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("multi_keymap_set", function()
        it("binds nothing for a disabled value", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            local before = #vim.api.nvim_buf_get_keymap(bufnr, "n")
            for _, disabled in ipairs({ "", false, {} }) do
                BufHelpers.multi_keymap_set(disabled, bufnr, function() end)
            end
            BufHelpers.multi_keymap_set(nil, bufnr, function() end)
            assert.equal(before, #vim.api.nvim_buf_get_keymap(bufnr, "n"))
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("shadow_keymap", function()
        --- @type integer
        local bufnr

        --- @return table map The buffer-local `n` map on `<localLeader>y`,
        ---   `{}` with none
        local function local_map()
            local map = vim.api.nvim_buf_call(bufnr, function()
                return vim.fn.maparg("<localLeader>y", "n", false, true)
            end)
            return map.buffer == 1 and map or {}
        end

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
        end)

        after_each(function()
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("puts back a Lua-callback map with its callback and desc", function()
            local original = spy.new(function() end)
            BufHelpers.keymap_set(bufnr, "n", "<localLeader>y", function()
                original()
            end, { desc = "original" })

            local restore = BufHelpers.shadow_keymap(
                bufnr,
                "n",
                "<localLeader>y",
                function() end,
                { desc = "shadow" }
            )
            assert.equal("shadow", local_map().desc)

            restore()
            assert.equal("original", local_map().desc)
            local_map().callback()
            assert.spy(original).was.called(1)
        end)

        it("leaves no map when there was none", function()
            local restore = BufHelpers.shadow_keymap(
                bufnr,
                "n",
                "<localLeader>y",
                function() end
            )
            restore()
            assert.same({}, local_map())
        end)

        it(
            "gives back the original after two shadows restored in reverse",
            function()
                BufHelpers.keymap_set(
                    bufnr,
                    "n",
                    "<localLeader>y",
                    function() end,
                    { desc = "original" }
                )
                local restore_first = BufHelpers.shadow_keymap(
                    bufnr,
                    "n",
                    "<localLeader>y",
                    function() end,
                    { desc = "first" }
                )
                local restore_second = BufHelpers.shadow_keymap(
                    bufnr,
                    "n",
                    "<localLeader>y",
                    function() end,
                    { desc = "second" }
                )

                restore_second()
                restore_first()
                assert.equal("original", local_map().desc)
            end
        )

        it("does nothing on restore once the buffer is gone", function()
            local other = vim.api.nvim_create_buf(false, true)
            local restore = BufHelpers.shadow_keymap(
                other,
                "n",
                "x",
                function() end
            )
            vim.api.nvim_buf_delete(other, { force = true })
            restore()
        end)

        it("does nothing on restore once :bdelete freed the map", function()
            local restore = BufHelpers.shadow_keymap(
                bufnr,
                "n",
                "<localLeader>y",
                function() end
            )
            vim.cmd.bdelete({ bufnr, bang = true })
            restore()
            assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
        end)

        it("leaves a map bound over the shadow in place", function()
            BufHelpers.keymap_set(
                bufnr,
                "n",
                "<localLeader>y",
                function() end,
                { desc = "original" }
            )
            local restore = BufHelpers.shadow_keymap(
                bufnr,
                "n",
                "<localLeader>y",
                function() end
            )
            BufHelpers.keymap_set(
                bufnr,
                "n",
                "<localLeader>y",
                function() end,
                { desc = "newer" }
            )
            restore()
            assert.equal("newer", local_map().desc)
        end)
    end)

    describe("show_rows", function()
        --- @type integer
        local bufnr
        --- @type integer
        local winid

        --- @return integer topline
        local function topline()
            vim.cmd("redraw")
            return vim.fn.line("w0", winid)
        end

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
            local lines = {}
            for i = 1, 50 do
                lines[i] = "line " .. i
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            winid = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 40,
                height = 20,
                row = 0,
                col = 0,
            })
            vim.wo[winid].scrolloff = 0
        end)

        after_each(function()
            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        -- Room = 20 rows less a padding of 1.

        it("centres rows that fit", function()
            BufHelpers.show_rows(winid, 1, 20, 24)

            -- 7 rows above the 5, half of the 14 to spare.
            assert.equal(14, topline())
        end)

        it("shows no empty rows past the end of the buffer", function()
            BufHelpers.show_rows(winid, 1, 45, 49)

            assert.equal(32, topline())
        end)

        it("starts rows taller than the window at the top", function()
            vim.wo[winid].scrolloff = 4

            BufHelpers.show_rows(winid, 1, 10, 40)

            assert.equal(11, topline())
            assert.equal(15, vim.api.nvim_win_get_cursor(winid)[1])
        end)

        it("may scroll up", function()
            vim.api.nvim_win_set_cursor(winid, { 50, 0 })

            BufHelpers.show_rows(winid, 1, 0, 2)

            assert.equal(1, topline())
        end)

        it("counts a closed fold as one row", function()
            vim.wo[winid].foldmethod = "manual"
            vim.api.nvim_win_call(winid, function()
                vim.cmd("2,30fold")
            end)

            BufHelpers.show_rows(winid, 1, 35, 39)

            assert.equal(1, topline())
        end)

        it("leaves a cursor that stays in view", function()
            vim.api.nvim_win_set_cursor(winid, { 16, 0 })

            BufHelpers.show_rows(winid, 1, 20, 24)

            assert.equal(16, vim.api.nvim_win_get_cursor(winid)[1])
        end)
    end)
end)
