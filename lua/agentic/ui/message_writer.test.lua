--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")

describe("agentic.ui.MessageWriter", function()
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type number
    local bufnr
    --- @type number
    local winid
    --- @type agentic.ui.MessageWriter
    local writer

    --- @type agentic.UserConfig.AutoScroll|nil
    local original_auto_scroll

    before_each(function()
        original_auto_scroll = Config.auto_scroll
        MessageWriter = require("agentic.ui.message_writer")

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        writer = MessageWriter:new(bufnr)
    end)

    after_each(function()
        Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @param line_count integer
    --- @param cursor_line integer
    local function setup_buffer(line_count, cursor_line)
        local lines = {}
        for i = 1, line_count do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(winid, { cursor_line, 0 })
    end

    --- @param text string
    --- @return agentic.acp.SessionUpdateMessage
    local function make_message_update(text)
        return {
            sessionUpdate = "agent_message_chunk",
            content = { type = "text", text = text },
        }
    end

    --- @param id string
    --- @param status agentic.acp.ToolCallStatus
    --- @param body? string[]
    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function make_tool_call_block(id, status, body)
        return {
            tool_call_id = id,
            status = status,
            kind = "execute",
            argument = "ls",
            body = body or { "output" },
        }
    end

    describe("_check_auto_scroll", function()
        it(
            "returns true when cursor is within threshold of buffer end",
            function()
                setup_buffer(20, 15)
                assert.is_true(writer:_check_auto_scroll(bufnr))
            end
        )

        it("returns false when cursor is far from buffer end", function()
            setup_buffer(50, 1)
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns false when threshold is disabled (zero or nil)", function()
            setup_buffer(1, 1)

            Config.auto_scroll = { threshold = 0 }
            assert.is_false(writer:_check_auto_scroll(bufnr))

            Config.auto_scroll = nil
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns true when window is not visible", function()
            local hidden_buf = vim.api.nvim_create_buf(false, true)
            local hidden_writer = MessageWriter:new(hidden_buf)
            assert.is_true(hidden_writer:_check_auto_scroll(hidden_buf))
            vim.api.nvim_buf_delete(hidden_buf, { force = true })
        end)

        it("uses win_findbuf to check cursor across tabpages", function()
            setup_buffer(50, 1)

            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()

            assert.is_false(writer:_check_auto_scroll(bufnr))

            vim.api.nvim_set_current_tabpage(tab2)
            vim.cmd("tabclose")
        end)
    end)

    describe("_auto_scroll", function()
        it("evaluates _check_auto_scroll eagerly on first call", function()
            local check_scroll_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)

            assert.equal(1, check_scroll_spy.call_count)
            check_scroll_spy:revert()
        end)

        it("coalesces multiple calls into a single scheduled scroll", function()
            setup_buffer(20, 20)

            writer:_auto_scroll(bufnr)
            assert.is_true(writer._scroll_scheduled)

            local check_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)
            writer:_auto_scroll(bufnr)

            assert.equal(0, check_spy.call_count)
            check_spy:revert()
        end)
    end)

    describe("_should_auto_scroll sticky field", function()
        it(
            "remains true after buffer growth despite cursor exceeding threshold",
            function()
                setup_buffer(20, 20)
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)

                local lines = {}
                for i = 1, 30 do
                    lines[i] = "tool output " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)

                local check_spy = spy.on(writer, "_check_auto_scroll")
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)
                assert.equal(0, check_spy.call_count)
                check_spy:revert()
            end
        )

        it(
            "scheduled callback resets field and moves cursor to last line",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(50, 1)
                writer._should_auto_scroll = true
                writer:_auto_scroll(bufnr)

                assert.is_nil(writer._should_auto_scroll)
                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                schedule_stub:revert()
            end
        )

        it(
            "scheduled callback scrolls when user is on a different tabpage",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(20, 20)

                local new_lines = {}
                for i = 1, 30 do
                    new_lines[i] = "streamed line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_lines)

                vim.cmd("tabnew")
                local tab2 = vim.api.nvim_get_current_tabpage()

                writer._should_auto_scroll = true
                writer:_auto_scroll(bufnr)

                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                vim.api.nvim_set_current_tabpage(tab2)
                vim.cmd("tabclose")

                schedule_stub:revert()
            end
        )

        it(
            "after reset, re-evaluates and returns false when user scrolled up",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(50, 50)
                writer:_auto_scroll(bufnr)
                assert.is_nil(writer._should_auto_scroll)
                assert.is_false(writer._scroll_scheduled)

                schedule_stub:revert()

                schedule_stub = spy.stub(vim, "schedule")

                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                writer:_auto_scroll(bufnr)
                assert.is_false(writer._should_auto_scroll)

                schedule_stub:revert()
            end
        )
    end)

    describe("auto-scroll with public write methods", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "write_message captures scroll decision before buffer grows",
            function()
                setup_buffer(10, 10)

                local long_text = {}
                for i = 1, 50 do
                    long_text[i] = "message line " .. i
                end

                writer:write_message(
                    make_message_update(table.concat(long_text, "\n"))
                )

                assert.is_true(writer._should_auto_scroll)
            end
        )

        it(
            "write_tool_call_block captures scroll decision before buffer grows",
            function()
                setup_buffer(10, 10)

                local body = {}
                for i = 1, 15 do
                    body[i] = "file" .. i .. ".lua"
                end

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "test-1",
                    status = "pending",
                    kind = "execute",
                    argument = "ls -la",
                    body = body,
                }
                writer:write_tool_call_block(block)

                assert.is_true(writer._should_auto_scroll)
                assert.is_true(vim.api.nvim_buf_line_count(bufnr) > 20)
            end
        )

        it("write_message does not scroll when user has scrolled up", function()
            setup_buffer(50, 1)

            writer:write_message(
                make_message_update("new content\nmore content")
            )

            assert.is_false(writer._should_auto_scroll)
        end)
    end)

    describe("on_content_changed callback", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("stores and fires callback via set_on_content_changed", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])

            writer:_notify_content_changed()

            assert.spy(callback_spy).was.called(1)
        end)

        it("clears callback when set to nil", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])
            writer:set_on_content_changed(nil)

            writer:_notify_content_changed()

            assert.spy(callback_spy).was.called(0)
        end)

        it(
            "fires callback for each write method that produces content",
            function()
                local block = make_tool_call_block("cb-setup", "pending")
                writer:write_tool_call_block(block)

                local callback_spy = spy.new(function() end)
                writer:set_on_content_changed(callback_spy --[[@as function]])

                writer:write_message(make_message_update("hello"))
                writer:write_message_chunk(make_message_update("chunk"))
                writer:write_tool_call_block(
                    make_tool_call_block("cb-1", "pending")
                )
                writer:update_tool_call_block({
                    tool_call_id = "cb-setup",
                    status = "completed",
                    body = { "done" },
                })

                assert.spy(callback_spy).was.called(4)
            end
        )

        it("does not fire callback when content is empty", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])

            writer:write_message(make_message_update(""))
            writer:write_message_chunk(make_message_update(""))

            assert.spy(callback_spy).was.called(0)
        end)
    end)

    describe("_prepare_block_lines", function()
        local FileSystem
        local read_stub
        local path_stub

        before_each(function()
            FileSystem = require("agentic.utils.file_system")
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

        it("renders execute tool call as a zsh code fence", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-fence",
                status = "pending",
                kind = "execute",
                argument = "ls -la /tmp",
                body = { "total 16" },
            }

            local lines, _ = writer:_prepare_block_lines(block)

            assert.equal(" execute ", lines[1])
            assert.equal("```zsh", lines[2])
            assert.equal("ls -la /tmp", lines[3])
            assert.equal("```", lines[4])
            assert.equal("total 16", lines[5])
        end)

        it("splits multi-line execute arguments into separate lines", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-multi",
                status = "pending",
                kind = "execute",
                argument = "for i in 1 2 3; do\necho $i\ndone",
            }

            local lines, _ = writer:_prepare_block_lines(block)

            assert.equal(" execute ", lines[1])
            assert.equal("```zsh", lines[2])
            assert.equal("for i in 1 2 3; do", lines[3])
            assert.equal("echo $i", lines[4])
            assert.equal("done", lines[5])
            assert.equal("```", lines[6])
        end)

        it("renders non-execute tool call with inline argument", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "read-inline",
                status = "pending",
                kind = "read",
                argument = "/tmp/file.txt",
                body = { "line1" },
            }

            local lines, _ = writer:_prepare_block_lines(block)

            assert.equal(" read(/tmp/file.txt) ", lines[1])
        end)

        it("creates highlight ranges for pure insertion hunks", function()
            read_stub:returns({ "line1", "line2", "line3" })

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "test-hl",
                status = "pending",
                kind = "edit",
                argument = "/test.lua",
                diff = {
                    old = { "line1", "line2", "line3" },
                    new = { "line1", "inserted", "line2", "line3" },
                },
            }

            local lines, highlight_ranges = writer:_prepare_block_lines(block)

            local found_inserted = false
            for _, line in ipairs(lines) do
                if line == "inserted" then
                    found_inserted = true
                    break
                end
            end
            assert.is_true(found_inserted)

            local new_ranges = vim.tbl_filter(function(r)
                return r.type == "new"
            end, highlight_ranges)
            assert.is_true(#new_ranges > 0)
            assert.equal("inserted", new_ranges[1].new_line)
        end)
    end)

    describe("_freeze_tool_call_block", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "defers freeze until next content write, then removes block",
            function()
                local block = make_tool_call_block("freeze-1", "pending")
                writer:write_tool_call_block(block)

                writer:update_tool_call_block({
                    tool_call_id = "freeze-1",
                    status = "completed",
                })

                -- Block is still tracked (freeze is deferred)
                assert.is_not_nil(writer.tool_call_blocks["freeze-1"])

                -- Next content write triggers the freeze
                writer:write_message(make_message_update("Done."))

                assert.is_nil(writer.tool_call_blocks["freeze-1"])

                -- Footer line should contain static status text
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local found_status = false
                for _, line in ipairs(lines) do
                    if line:find("completed") then
                        found_status = true
                        break
                    end
                end
                assert.is_true(found_status)
            end
        )

        it("ignores subsequent updates after freeze", function()
            local block = make_tool_call_block("freeze-2", "pending")
            writer:write_tool_call_block(block)

            writer:update_tool_call_block({
                tool_call_id = "freeze-2",
                status = "completed",
            })

            -- Flush the freeze
            writer:write_message(make_message_update("Done."))

            -- Second update should be silently ignored
            local line_count_before = vim.api.nvim_buf_line_count(bufnr)
            writer:update_tool_call_block({
                tool_call_id = "freeze-2",
                status = "completed",
                body = { "extra output" },
            })
            local line_count_after = vim.api.nvim_buf_line_count(bufnr)

            assert.equal(line_count_before, line_count_after)
        end)

        it("defers freeze on initial write until next content", function()
            local block = make_tool_call_block("freeze-3", "completed")
            writer:write_tool_call_block(block)

            -- Still tracked (deferred)
            assert.is_not_nil(writer.tool_call_blocks["freeze-3"])

            -- Next write triggers freeze
            writer:write_message(make_message_update("Done."))
            assert.is_nil(writer.tool_call_blocks["freeze-3"])
        end)

        it("freezes failed blocks on next content write", function()
            local block = make_tool_call_block("freeze-4", "pending")
            writer:write_tool_call_block(block)

            writer:update_tool_call_block({
                tool_call_id = "freeze-4",
                status = "failed",
            })

            assert.is_not_nil(writer.tool_call_blocks["freeze-4"])

            writer:write_message(make_message_update("Error occurred."))
            assert.is_nil(writer.tool_call_blocks["freeze-4"])
        end)

        it("removes range extmark from NS_TOOL_BLOCKS after freeze", function()
            local NS_TOOL_BLOCKS =
                vim.api.nvim_create_namespace("agentic_tool_blocks")

            local block = make_tool_call_block("freeze-ext-1", "pending")
            writer:write_tool_call_block(block)

            local tracker = writer.tool_call_blocks["freeze-ext-1"]
            local extmark_id = tracker.extmark_id

            -- Verify range extmark exists before freeze
            local pos = vim.api.nvim_buf_get_extmark_by_id(
                bufnr,
                NS_TOOL_BLOCKS,
                extmark_id,
                {}
            )
            assert.is_not_nil(pos[1])

            writer:update_tool_call_block({
                tool_call_id = "freeze-ext-1",
                status = "completed",
            })
            writer:write_message(make_message_update("Done."))

            -- Range extmark should be gone after freeze
            pos = vim.api.nvim_buf_get_extmark_by_id(
                bufnr,
                NS_TOOL_BLOCKS,
                extmark_id,
                {}
            )
            -- Deleted extmarks return {0, 0} with no error
            local all_extmarks =
                vim.api.nvim_buf_get_extmarks(bufnr, NS_TOOL_BLOCKS, 0, -1, {})
            assert.equal(0, #all_extmarks)
        end)

        it("re-renders decoration sign extmarks after freeze", function()
            local NS_DECORATIONS =
                vim.api.nvim_create_namespace("agentic_tool_decorations")

            local block = make_tool_call_block("freeze-ext-2", "pending")
            writer:write_tool_call_block(block)

            -- Count decorations before freeze
            local before =
                vim.api.nvim_buf_get_extmarks(bufnr, NS_DECORATIONS, 0, -1, {})
            assert.is_true(#before > 0)

            writer:update_tool_call_block({
                tool_call_id = "freeze-ext-2",
                status = "completed",
            })
            writer:write_message(make_message_update("Done."))

            -- Decorations should still exist (re-rendered, not just deleted)
            local after =
                vim.api.nvim_buf_get_extmarks(bufnr, NS_DECORATIONS, 0, -1, {})
            assert.is_true(#after > 0)
        end)

        it(
            "clears status overlay extmarks and writes static status text",
            function()
                local NS_STATUS =
                    vim.api.nvim_create_namespace("agentic_status_footer")

                local block = make_tool_call_block("freeze-ext-3", "pending")
                writer:write_tool_call_block(block)

                -- Before freeze: overlay extmark exists in NS_STATUS
                local before_status = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    NS_STATUS,
                    0,
                    -1,
                    { details = true }
                )
                local has_overlay = false
                for _, ext in ipairs(before_status) do
                    if ext[4].virt_text then
                        has_overlay = true
                        break
                    end
                end
                assert.is_true(has_overlay)

                writer:update_tool_call_block({
                    tool_call_id = "freeze-ext-3",
                    status = "completed",
                })
                writer:write_message(make_message_update("Done."))

                -- After freeze: no overlay extmarks (cleared during freeze)
                -- Only a line highlight extmark should remain
                local after_status = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    NS_STATUS,
                    0,
                    -1,
                    { details = true }
                )
                for _, ext in ipairs(after_status) do
                    assert.is_nil(ext[4].virt_text)
                end

                -- Static text should be in buffer
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local found = false
                for _, line in ipairs(lines) do
                    if line:find("completed") then
                        found = true
                        break
                    end
                end
                assert.is_true(found)
            end
        )
    end)

    describe("collapsed extmark handling", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "bails out and removes block when range extmark collapses",
            function()
                local block = make_tool_call_block("collapse-1", "pending")
                writer:write_tool_call_block(block)

                local tracker = writer.tool_call_blocks["collapse-1"]
                assert.is_not_nil(tracker)

                -- Corrupt the range extmark by setting start == end
                local pos = vim.api.nvim_buf_get_extmark_by_id(
                    bufnr,
                    vim.api.nvim_create_namespace("agentic_tool_blocks"),
                    tracker.extmark_id,
                    { details = true }
                )
                local start_row = pos[1]
                vim.api.nvim_buf_set_extmark(
                    bufnr,
                    vim.api.nvim_create_namespace("agentic_tool_blocks"),
                    start_row,
                    0,
                    {
                        id = tracker.extmark_id,
                        end_row = start_row, -- collapsed: start == end
                        right_gravity = false,
                    }
                )

                -- Update should bail out and remove from tracking
                writer:update_tool_call_block({
                    tool_call_id = "collapse-1",
                    status = "in_progress",
                })

                assert.is_nil(writer.tool_call_blocks["collapse-1"])
            end
        )
    end)
end)
