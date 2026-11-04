--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

describe("agentic.ui.InputDispatch", function()
    local InputDispatch = require("agentic.ui.input_dispatch")

    --- A dispatch over an `acwrite` scratch buffer, as the input is, shown in
    --- a new tabpage's window, with its untag attached and its maps bound.
    --- @param on_submit fun(prompt: string, opts: agentic.SessionManager.SubmitOpts): boolean
    --- @return agentic.ui.InputDispatch dispatch
    --- @return integer bufnr
    --- @return integer winid
    local function new_dispatch(on_submit)
        vim.cmd("tabnew")
        local bufnr = vim.api.nvim_create_buf(false, true)
        -- 'modified' sticks only on a buffer that can be written.
        vim.bo[bufnr].buftype = "acwrite"
        local winid = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(winid, bufnr)
        local dispatch = InputDispatch:new(bufnr, on_submit, function() end)
        dispatch:attach_untag()
        dispatch:bind()
        return dispatch, bufnr, winid
    end

    --- Close the tabpage and wipe the buffer of `new_dispatch`.
    --- @param bufnr integer
    local function drop_dispatch(bufnr)
        vim.cmd("tabclose")
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end

    describe("partial_send", function()
        --- @type agentic.ui.InputDispatch
        local dispatch
        local buf
        local input_win
        local submit_spy
        local debug_spy
        local original_send_register

        before_each(function()
            submit_spy = spy.new(function()
                return true
            end)
            dispatch, buf, input_win =
                new_dispatch(submit_spy --[[@as function]])
            debug_spy = spy.on(Logger, "debug")
            original_send_register = Config.settings.send_register
            Config.settings.send_register = nil
        end)

        after_each(function()
            Config.settings.send_register = original_send_register
            debug_spy:revert()
            drop_dispatch(buf)
        end)

        local function set_input(lines)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        end

        local function input_lines()
            return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end

        describe("_send_line", function()
            it("sends current line and removes it from buffer", function()
                set_input({ "alpha", "beta", "gamma" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

                dispatch:_send_line()

                assert.spy(submit_spy).was.called(1)
                assert.equal("alpha", submit_spy.calls[1][1])
                assert.same({ "beta", "gamma" }, input_lines())
            end)

            it("no-op on empty buffer", function()
                set_input({ "" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

                dispatch:_send_line()

                assert.spy(submit_spy).was.called(0)
            end)

            it("no-op on whitespace-only line", function()
                set_input({ "   \t ", "beta" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

                dispatch:_send_line()

                assert.spy(submit_spy).was.called(0)
                assert.same({ "   \t ", "beta" }, input_lines())
            end)

            it("clamps a count past buffer end and tags the rest", function()
                set_input({ "/compact", "then continue" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })
                -- Drive via a real mapping so vim.v.count1 reflects the count.
                vim.keymap.set("n", "<Plug>(agentic-test-send)", function()
                    dispatch:_send_line()
                end, { buffer = buf })

                vim.api.nvim_feedkeys(
                    "9" .. vim.keycode("<Plug>(agentic-test-send)"),
                    "x",
                    false
                )
                -- `v:count1` keeps the count until a command without one.
                vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "x", false)

                assert.spy(submit_spy).was.called(1)
                assert.equal("/compact", submit_spy.calls[1][1])
                assert.same({ "then continue" }, input_lines())
                local ns =
                    vim.api.nvim_create_namespace("agentic_queued_region")
                local marks = vim.api.nvim_buf_get_extmarks(
                    buf,
                    ns,
                    0,
                    -1,
                    { details = true }
                )
                assert.equal(1, #marks)
                assert.same({ 0, 0 }, { marks[1][2], marks[1][4].end_row })
            end)
        end)

        describe("_send_operator", function()
            it("linewise: sends line range and removes from buffer", function()
                set_input({ "alpha", "beta", "gamma", "delta" })
                vim.api.nvim_buf_set_mark(buf, "[", 2, 0, {})
                vim.api.nvim_buf_set_mark(buf, "]", 3, 0, {})

                dispatch:_send_operator("line")

                assert.spy(submit_spy).was.called(1)
                assert.equal("beta\ngamma", submit_spy.calls[1][1])
                assert.same({ "alpha", "delta" }, input_lines())
            end)

            it("charwise: sends substring and splices it out", function()
                set_input({ "hello world" })
                -- Select "world" (chars 6..10 inclusive, 0-indexed cols)
                vim.api.nvim_buf_set_mark(buf, "[", 1, 6, {})
                vim.api.nvim_buf_set_mark(buf, "]", 1, 10, {})

                dispatch:_send_operator("char")

                assert.spy(submit_spy).was.called(1)
                assert.equal("world", submit_spy.calls[1][1])
                assert.same({ "hello " }, input_lines())
            end)

            it("block: no-op with debug log", function()
                set_input({ "alpha", "beta" })

                dispatch:_send_operator("block")

                assert.spy(submit_spy).was.called(0)
                assert.is_true(debug_spy.call_count >= 1)
            end)
        end)

        describe("submit regression", function()
            local ns = vim.api.nvim_create_namespace("agentic_queued_region")

            it("no-arg path still sends whole buffer and clears it", function()
                set_input({ "line1", "line2" })

                dispatch:submit()

                assert.spy(submit_spy).was.called(1)
                assert.equal("line1\nline2", submit_spy.calls[1][1])
                assert.same({ "" }, input_lines())
            end)

            it("tags and keeps the text when the session defers", function()
                Config.settings.send_register = "a"
                vim.fn.setreg("a", "untouched")
                set_input({ "line1", "line2" })
                submit_spy = spy.new(function()
                    return false
                end)
                dispatch.on_submit = submit_spy --[[@as function]]

                dispatch:submit()

                assert.spy(submit_spy).was.called(1)
                assert.same({ "line1", "line2" }, input_lines())
                -- One tag over the whole submitted range.
                local marks = vim.api.nvim_buf_get_extmarks(
                    buf,
                    ns,
                    0,
                    -1,
                    { details = true }
                )
                assert.equal(1, #marks)
                assert.equal(0, marks[1][2])
                assert.equal(1, marks[1][4].end_row)
                -- Nothing was sent, so the register is not written.
                assert.equal("untouched", vim.fn.getreg("a"))
                -- Unsent text is unsaved text.
                assert.is_true(vim.bo[buf].modified)
            end)

            it("dispatches the first block and tags the rest", function()
                set_input({ "/compact", "then continue" })

                dispatch:submit()

                assert.spy(submit_spy).was.called(1)
                assert.equal("/compact", submit_spy.calls[1][1])
                -- The remainder stays visible and editable, tagged for the
                -- drain that runs at the command's turn end.
                assert.same({ "then continue" }, input_lines())
                local marks = vim.api.nvim_buf_get_extmarks(
                    buf,
                    ns,
                    0,
                    -1,
                    { details = true }
                )
                assert.equal(1, #marks)
                assert.same({ 0, 0 }, { marks[1][2], marks[1][4].end_row })
            end)

            it("tags the deferred head above the untouched rest", function()
                set_input({ "/compact", "then continue" })
                dispatch.on_submit = spy.new(function()
                    return false
                end) --[[@as function]]

                dispatch:submit()

                assert.same({ "/compact", "then continue" }, input_lines())
                local marks = vim.api.nvim_buf_get_extmarks(
                    buf,
                    ns,
                    0,
                    -1,
                    { details = true }
                )
                assert.equal(2, #marks)
                assert.same({ 0, 0 }, { marks[1][2], marks[1][4].end_row })
                assert.same({ 1, 1 }, { marks[2][2], marks[2][4].end_row })
            end)

            it("submits from the write commands like the submit key", function()
                set_input({ "line1" })

                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)
                vim.api.nvim_exec_autocmds("BufWriteCmd", {
                    buffer = buf,
                })
                schedule_stub:revert()

                assert.spy(submit_spy).was.called(1)
                assert.same({ from_buffer = true }, submit_spy.calls[1][2])
            end)
        end)

        describe("send_register", function()
            it("writes sent text when configured (linewise)", function()
                Config.settings.send_register = "a"
                vim.fn.setreg("a", "")
                set_input({ "alpha", "beta" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

                dispatch:_send_line()

                assert.equal("alpha\n", vim.fn.getreg("a"))
                assert.equal("V", vim.fn.getregtype("a"))
            end)

            it("leaves register untouched when nil", function()
                vim.fn.setreg("a", "preserved")
                set_input({ "alpha" })
                vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

                dispatch:_send_line()

                assert.equal("preserved", vim.fn.getreg("a"))
            end)

            it("uses charwise regtype for char delete_range", function()
                Config.settings.send_register = "a"
                vim.fn.setreg("a", "")
                set_input({ "hello world" })
                vim.api.nvim_buf_set_mark(buf, "[", 1, 6, {})
                vim.api.nvim_buf_set_mark(buf, "]", 1, 10, {})

                dispatch:_send_operator("char")

                assert.equal("world", vim.fn.getreg("a"))
                assert.equal("v", vim.fn.getregtype("a"))
            end)
        end)
    end)

    describe("queue", function()
        local ns = vim.api.nvim_create_namespace("agentic_queued_region")
        --- @type agentic.ui.InputDispatch
        local dispatch
        local buf
        local input_win
        local submit_spy

        before_each(function()
            submit_spy = spy.new(function()
                return true
            end)
            dispatch, buf, input_win =
                new_dispatch(submit_spy --[[@as function]])
        end)

        after_each(function()
            drop_dispatch(buf)
        end)

        local function set_input(lines)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        end

        local function input_lines()
            return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        end

        --- Tagged regions as `{ start_row, end_row }` pairs in buffer order.
        local function tags()
            local marks = vim.api.nvim_buf_get_extmarks(
                buf,
                ns,
                0,
                -1,
                { details = true }
            )
            return vim.tbl_map(function(m)
                return { m[2], m[4].end_row }
            end, marks)
        end

        it("tags the cursor line and never sends, even when idle", function()
            set_input({ "one", "two", "three" })
            vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

            dispatch:_queue_line()

            assert.same({ { 0, 0 } }, tags())
            assert.spy(submit_spy).was.called(0)
            assert.same({ "one", "two", "three" }, input_lines())
        end)

        describe("queue_paragraph", function()
            it(
                "tags a paragraph added at the end, keeping other tags",
                function()
                    set_input({ "queued", "", "draft" })
                    dispatch:_queue_line_range(0, 0)
                    vim.api.nvim_win_set_cursor(input_win, { 3, 2 })
                    vim.cmd("startinsert")

                    local mark = dispatch:queue_paragraph("held\nmore")

                    assert.same(
                        { "queued", "", "draft", "", "held", "more" },
                        input_lines()
                    )
                    assert.same({ { 0, 0 }, { 4, 5 } }, tags())
                    assert.is_not_nil(mark)
                    assert.equal(input_win, vim.api.nvim_get_current_win())
                    assert.same(
                        { 3, 2 },
                        vim.api.nvim_win_get_cursor(input_win)
                    )
                    assert.is_true(vim.bo[buf].modified)
                    vim.cmd("stopinsert")
                end
            )

            it("returns nil for text with no lines", function()
                set_input({ "draft" })
                assert.is_nil(dispatch:queue_paragraph("\n\n"))
                assert.same({ "draft" }, input_lines())
            end)

            it(
                "puts a first paragraph above the first region, keeping its tag",
                function()
                    set_input({ "draft", "", "queued" })
                    dispatch:_queue_line_range(2, 2)

                    dispatch:queue_paragraph("again", { first = true })

                    assert.same(
                        { "draft", "", "again", "", "queued" },
                        input_lines()
                    )
                    assert.same({ { 2, 2 }, { 4, 4 } }, tags())
                end
            )

            it(
                "puts a first paragraph on top of an input with only draft",
                function()
                    set_input({ "draft" })

                    dispatch:queue_paragraph("again", { first = true })

                    assert.same({ "again", "", "draft" }, input_lines())
                    assert.same({ { 0, 0 } }, tags())
                end
            )
        end)

        describe("delete_queued_region", function()
            it("deletes a tagged region and its separator row", function()
                set_input({ "draft" })
                local mark = dispatch:queue_paragraph("continue") --[[@as integer]]
                dispatch:delete_queued_region(mark, "continue")
                assert.same({ "draft" }, input_lines())
            end)

            it(
                "takes the separator below a region that starts the input",
                function()
                    local mark = dispatch:queue_paragraph("continue") --[[@as integer]]
                    dispatch:queue_paragraph("next")

                    dispatch:delete_queued_region(mark, "continue")

                    assert.same({ "next" }, input_lines())
                    assert.same({ { 0, 0 } }, tags())
                end
            )

            it("does nothing once an edit dropped the tag", function()
                local mark = dispatch:queue_paragraph("continue") --[[@as integer]]
                vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "continue now" })

                dispatch:delete_queued_region(mark, "continue")

                assert.same({ "continue now" }, input_lines())
            end)

            it("does nothing when a reused id tags other text", function()
                local mark = dispatch:queue_paragraph("continue") --[[@as integer]]
                dispatch:cancel_queue()
                set_input({ "mine" })
                local reused = dispatch:_queue_line_range(0, 0)
                assert.equal(mark, reused)

                dispatch:delete_queued_region(mark, "continue")

                assert.same({ "mine" }, input_lines())
                assert.same({ { 0, 0 } }, tags())
            end)
        end)

        it("re-queueing an overlapping range replaces, never stacks", function()
            set_input({ "one", "two", "three", "four" })
            dispatch:_queue_line_range(1, 1)
            dispatch:_queue_line_range(0, 2)

            assert.same({ { 0, 2 } }, tags())
        end)

        -- Sending the line above a region must not drop it to draft: the
        -- delete abuts the region, which is indistinguishable from an edit
        -- inside it unless the dispatch says so.
        it("keeps a region tagged when the line above it is sent", function()
            set_input({ "send me", "queued task" })
            dispatch:_queue_line_range(1, 1)
            vim.api.nvim_win_set_cursor(input_win, { 1, 0 })

            dispatch:_send_line()

            assert.same({ "queued task" }, input_lines())
            assert.same({ { 0, 0 } }, tags())
        end)

        it("editing inside a region drops its tag", function()
            set_input({ "one", "two", "three" })
            dispatch:_queue_line_range(0, 1)
            assert.equal(1, #tags())

            vim.api.nvim_buf_set_text(buf, 0, 3, 0, 3, { "X" })

            assert.equal(0, #tags())
        end)

        it("editing outside a region leaves its tag", function()
            set_input({ "one", "two", "three" })
            dispatch:_queue_line_range(0, 0)

            vim.api.nvim_buf_set_text(buf, 2, 0, 2, 0, { "X" })

            assert.equal(1, #tags())
        end)

        it("entering insert inside a region drops its tag", function()
            set_input({ "one", "two", "three" })
            dispatch:_queue_line_range(1, 1)
            vim.api.nvim_win_set_cursor(input_win, { 2, 0 })

            vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buf })

            assert.equal(0, #tags())
        end)

        it("cancel_queue clears every tag, leaving text in place", function()
            set_input({ "one", "two", "three" })
            dispatch:_queue_line_range(0, 0)
            dispatch:_queue_line_range(2, 2)
            assert.equal(2, #tags())

            dispatch:cancel_queue()

            assert.equal(0, #tags())
            assert.same({ "one", "two", "three" }, input_lines())
        end)

        it("reads the topmost region's first block, consuming none", function()
            set_input({ "one", "two", "three" })
            -- Queue bottom then top: buffer order must still be top-to-bottom.
            dispatch:_queue_line_range(2, 2)
            dispatch:_queue_line_range(0, 0)

            assert.equal("one", dispatch:next_queued_block().text)
            -- A caller that decides not to dispatch leaves them visible.
            assert.equal(2, #tags())
            assert.same({ "one", "two", "three" }, input_lines())
        end)

        it("splits a region into one block per command line", function()
            set_input({ "/compact", "then continue", "with X" })
            dispatch:_queue_line_range(0, 2)

            assert.equal(2, dispatch:queued_block_count())
            assert.equal("/compact", dispatch:next_queued_block().text)
        end)

        it("consuming a region's only block takes the region", function()
            set_input({ "one", "two", "three" })
            dispatch:_queue_line_range(2, 2)
            dispatch:_queue_line_range(0, 0)

            dispatch:consume_queued_block()

            assert.same({ { 1, 1 } }, tags())
            assert.same({ "two", "three" }, input_lines())
        end)

        -- Consuming a region's last block must delete its mark: a collapsed
        -- zero-width mark would read the untagged draft line below it as the
        -- next queued block and send it.
        it("never reads the draft line below a consumed region", function()
            set_input({ "queued", "draft" })
            dispatch:_queue_line_range(0, 0)

            dispatch:consume_queued_block()

            assert.same({}, tags())
            assert.is_nil(dispatch:next_queued_block())
            assert.same({ "draft" }, input_lines())
        end)

        it("consuming one block of a region leaves the rest tagged", function()
            set_input({ "/compact", "then continue", "draft" })
            dispatch:_queue_line_range(0, 1)

            dispatch:consume_queued_block()

            assert.same({ { 0, 0 } }, tags())
            assert.same({ "then continue", "draft" }, input_lines())
            assert.equal("then continue", dispatch:next_queued_block().text)
        end)

        it("ignores a blockwise motion", function()
            set_input({ "one", "two" })
            vim.api.nvim_buf_set_mark(buf, "[", 1, 0, {})
            vim.api.nvim_buf_set_mark(buf, "]", 2, 0, {})

            dispatch:_queue_operator("block")

            assert.same({}, tags())
        end)

        it("reads nil when nothing is queued", function()
            set_input({ "one" })
            assert.is_nil(dispatch:next_queued_block())
            assert.equal(0, dispatch:queued_block_count())
        end)

        it("clamps a count past buffer end (no crash)", function()
            set_input({ "one", "two" })
            vim.api.nvim_win_set_cursor(input_win, { 1, 0 })
            -- Drive via a real mapping so vim.v.count1 reflects the typed count.
            vim.keymap.set("n", "<Plug>(agentic-test-queue)", function()
                dispatch:_queue_line()
            end, { buffer = buf })
            vim.api.nvim_feedkeys(
                "9"
                    .. vim.api.nvim_replace_termcodes(
                        "<Plug>(agentic-test-queue)",
                        true,
                        true,
                        true
                    ),
                "x",
                false
            )

            -- Clamped to the last line (row 1), not row 8.
            assert.same({ { 0, 1 } }, tags())
        end)
    end)
end)
