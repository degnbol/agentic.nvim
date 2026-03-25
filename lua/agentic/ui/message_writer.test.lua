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
    local original_tool_call_display

    before_each(function()
        original_auto_scroll = Config.auto_scroll
        original_tool_call_display = vim.deepcopy(Config.tool_call_display)
        -- Disable external formatter for deterministic fallback tests
        Config.tool_call_display.execute_formatter = false
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
        Config.tool_call_display = original_tool_call_display
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

            assert.equal("### Execute", lines[1])
            assert.equal("```bash", lines[2])
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

            assert.equal("### Execute", lines[1])
            assert.equal("```bash", lines[2])
            assert.equal("for i in 1 2 3; do", lines[3])
            assert.equal("echo $i", lines[4])
            assert.equal("done", lines[5])
            assert.equal("```", lines[6])
        end)

        it(
            "renders non-execute tool call with argument on separate line",
            function()
                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "read-inline",
                    status = "pending",
                    kind = "read",
                    argument = "/tmp/file.txt",
                    body = { "line1" },
                }

                local lines, _ = writer:_prepare_block_lines(block)

                assert.equal("### Read", lines[1])
                assert.equal("`/tmp/file.txt`", lines[2])
            end
        )

        it("strips redundant kind prefix from argument", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "read-prefix",
                status = "pending",
                kind = "read",
                argument = "Read /tmp/file.txt",
                body = { "line1" },
            }

            local lines, _ = writer:_prepare_block_lines(block)

            assert.equal("### Read", lines[1])
            assert.equal("`/tmp/file.txt`", lines[2])
        end)

        it("extracts range from argument into read_range", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "read-title-range",
                status = "pending",
                kind = "read",
                argument = "Read /tmp/file.txt (1 - 100)",
                body = { "a", "b", "c" },
            }

            local lines, _ = writer:_prepare_block_lines(block)

            assert.equal("### Read", lines[1])
            assert.equal("`/tmp/file.txt`", lines[2])
            assert.equal("Read 100 lines (1 - 100)", lines[3])
        end)

        it("shows line range in read info when read_range is set", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "read-range",
                status = "pending",
                kind = "read",
                argument = "/tmp/file.txt",
                body = { "a", "b", "c" },
                read_range = { offset = 10, limit = 3 },
            }

            local lines, _ = writer:_prepare_block_lines(block)

            assert.equal("### Read", lines[1])
            assert.equal("`/tmp/file.txt`", lines[2])
            assert.equal("Read 3 lines (10 - 12)", lines[3])
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

        it("splits long one-liner execute commands at operators", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-long",
                status = "pending",
                kind = "execute",
                argument = "cd /some/very/long/project/path && npm install --save-dev typescript && npm run build && npm test",
            }

            local lines, _ = writer:_prepare_block_lines(block)

            assert.equal("### Execute", lines[1])
            assert.equal("```bash", lines[2])
            assert.equal("cd /some/very/long/project/path &&", lines[3])
            assert.equal("npm install --save-dev typescript &&", lines[4])
            assert.equal("npm run build &&", lines[5])
            assert.equal("npm test", lines[6])
            assert.equal("```", lines[7])
        end)

        it("does not split short execute commands", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-short",
                status = "pending",
                kind = "execute",
                argument = "ls -la && echo done",
            }

            local lines, _ = writer:_prepare_block_lines(block)

            assert.equal("ls -la && echo done", lines[3])
        end)

        it("does not split inside quoted strings", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-quoted",
                status = "pending",
                kind = "execute",
                argument = [[echo "this && that || other" && echo 'pipes | here ; too' && echo done with a very long command line]],
            }

            local lines, _ = writer:_prepare_block_lines(block)

            assert.equal("```bash", lines[2])
            assert.equal([[echo "this && that || other" &&]], lines[3])
            assert.equal([[echo 'pipes | here ; too' &&]], lines[4])
            assert.equal("echo done with a very long command line", lines[5])
        end)

        it("does not split inside subshells", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-subshell",
                status = "pending",
                kind = "execute",
                argument = "result=$(cmd1 && cmd2 || cmd3) && echo $result && final_command with some extra arguments to be long",
            }

            local lines, _ = writer:_prepare_block_lines(block)

            assert.equal("result=$(cmd1 && cmd2 || cmd3) &&", lines[3])
            assert.equal("echo $result &&", lines[4])
            assert.equal(
                "final_command with some extra arguments to be long",
                lines[5]
            )
        end)
    end)

    describe("status footer as direct buffer text", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "writes status text into the footer line on initial write",
            function()
                local block = make_tool_call_block("status-1", "pending")
                writer:write_tool_call_block(block)

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local found_pending = false
                for _, line in ipairs(lines) do
                    if line:find("pending") then
                        found_pending = true
                        break
                    end
                end
                assert.is_true(found_pending)
            end
        )

        it("updates footer line in place when status changes", function()
            local block = make_tool_call_block("status-2", "pending")
            writer:write_tool_call_block(block)

            local line_count_before = vim.api.nvim_buf_line_count(bufnr)

            writer:update_tool_call_block({
                tool_call_id = "status-2",
                status = "completed",
            })

            -- Line count should not change (footer replaced, not appended)
            assert.equal(line_count_before, vim.api.nvim_buf_line_count(bufnr))

            -- Footer should now contain completed text
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local found_completed = false
            for _, line in ipairs(lines) do
                if line:find("completed") then
                    found_completed = true
                    break
                end
            end
            assert.is_true(found_completed)
        end)

        it(
            "no overlay extmarks — only line highlights in NS_STATUS",
            function()
                local NS_STATUS =
                    vim.api.nvim_create_namespace("agentic_status_footer")

                local block = make_tool_call_block("status-3", "pending")
                writer:write_tool_call_block(block)

                local extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    NS_STATUS,
                    0,
                    -1,
                    { details = true }
                )
                for _, ext in ipairs(extmarks) do
                    assert.is_nil(ext[4].virt_text)
                end
            end
        )

        it("keeps block tracked after terminal status", function()
            local block = make_tool_call_block("status-4", "completed")
            writer:write_tool_call_block(block)

            -- Block remains tracked (no freeze/removal)
            assert.is_not_nil(writer.tool_call_blocks["status-4"])
        end)

        it("keeps range extmark after terminal status", function()
            local NS_TOOL_BLOCKS =
                vim.api.nvim_create_namespace("agentic_tool_blocks")

            local block = make_tool_call_block("status-5", "completed")
            writer:write_tool_call_block(block)

            local tracker = writer.tool_call_blocks["status-5"]
            local all_extmarks =
                vim.api.nvim_buf_get_extmarks(bufnr, NS_TOOL_BLOCKS, 0, -1, {})
            assert.equal(1, #all_extmarks)
            assert.equal(tracker.extmark_id, all_extmarks[1][1])
        end)

        it("decoration signs survive status update", function()
            local NS_DECORATIONS =
                vim.api.nvim_create_namespace("agentic_tool_decorations")

            local block = make_tool_call_block("status-6", "pending")
            writer:write_tool_call_block(block)

            local before =
                vim.api.nvim_buf_get_extmarks(bufnr, NS_DECORATIONS, 0, -1, {})
            assert.is_true(#before > 0)

            writer:update_tool_call_block({
                tool_call_id = "status-6",
                status = "completed",
            })

            local after =
                vim.api.nvim_buf_get_extmarks(bufnr, NS_DECORATIONS, 0, -1, {})
            assert.equal(#before, #after)
        end)

        it("handles failed status in footer", function()
            local block = make_tool_call_block("status-7", "pending")
            writer:write_tool_call_block(block)

            writer:update_tool_call_block({
                tool_call_id = "status-7",
                status = "failed",
            })

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local found_failed = false
            for _, line in ipairs(lines) do
                if line:find("failed") then
                    found_failed = true
                    break
                end
            end
            assert.is_true(found_failed)
        end)
    end)

    describe("long command formatting", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "write+update preserves header, body, and decorations for split commands",
            function()
                local long_cmd =
                    "cd /some/very/long/project/path && npm install --save-dev typescript && npm run build && npm test"

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "long-exec-1",
                    status = "pending",
                    kind = "execute",
                    argument = long_cmd,
                }
                writer:write_tool_call_block(block)

                local lines_after_write =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                -- Header should be present
                assert.equal("### Execute", lines_after_write[1])
                -- Code fence and split command
                assert.equal("```bash", lines_after_write[2])
                assert.equal(
                    "cd /some/very/long/project/path &&",
                    lines_after_write[3]
                )
                assert.equal("npm test", lines_after_write[6])
                assert.equal("```", lines_after_write[7])

                -- Decorations should exist
                local NS_DECORATIONS =
                    vim.api.nvim_create_namespace("agentic_tool_decorations")
                local decs_after_write = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    NS_DECORATIONS,
                    0,
                    -1,
                    {}
                )
                assert.is_true(#decs_after_write > 0)

                -- Block should be tracked
                assert.is_not_nil(writer.tool_call_blocks["long-exec-1"])

                -- Now update with body (simulating command completion)
                writer:update_tool_call_block({
                    tool_call_id = "long-exec-1",
                    status = "completed",
                    body = { "output line 1", "output line 2" },
                })

                local lines_after_update =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                -- Header still present
                assert.equal("### Execute", lines_after_update[1])
                assert.equal("```bash", lines_after_update[2])

                -- Body output should be present
                local found_output = false
                for _, line in ipairs(lines_after_update) do
                    if line == "output line 1" then
                        found_output = true
                        break
                    end
                end
                assert.is_true(found_output)

                -- Status should show completed
                local found_completed = false
                for _, line in ipairs(lines_after_update) do
                    if line:find("completed") then
                        found_completed = true
                        break
                    end
                end
                assert.is_true(found_completed)

                -- Decorations should still exist
                local decs_after_update = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    NS_DECORATIONS,
                    0,
                    -1,
                    {}
                )
                assert.is_true(#decs_after_update > 0)

                -- Block still tracked
                assert.is_not_nil(writer.tool_call_blocks["long-exec-1"])
            end
        )
    end)

    describe("external formatter (shfmt)", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            Config.tool_call_display.execute_formatter = "shfmt"
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("indents control structures when shfmt is available", function()
            if vim.fn.executable("shfmt") ~= 1 then
                return -- skip when shfmt not installed
            end

            -- shfmt preserves one-liners; use multi-line input (as Claude sends)
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "shfmt-1",
                status = "pending",
                kind = "execute",
                argument = "for i in 1 2 3; do\necho $i\ndone",
            }
            writer:write_tool_call_block(block)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            -- shfmt should indent the loop body
            local found_indent = false
            for _, line in ipairs(lines) do
                if line:match("^%s+echo") then
                    found_indent = true
                    break
                end
            end
            assert.is_true(found_indent, "shfmt should indent loop body")
        end)

        it(
            "falls back to operator splitting when formatter is disabled",
            function()
                Config.tool_call_display.execute_formatter = false

                local long_cmd =
                    "cd /some/very/long/project/path && npm install --save-dev typescript && npm run build && npm test"

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "fallback-1",
                    status = "pending",
                    kind = "execute",
                    argument = long_cmd,
                }
                writer:write_tool_call_block(block)

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.equal("```bash", lines[2])
                assert.equal("cd /some/very/long/project/path &&", lines[3])
            end
        )
    end)

    describe("message chunk + tool call + separator flow", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "append_separator reflow does not corrupt tool call block",
            function()
                -- Simulate: agent streams message, then tool call, then separator
                writer:write_message_chunk(
                    make_message_update("Do a sample for loop\n\n---")
                )

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "reflow-exec",
                    status = "pending",
                    kind = "execute",
                    argument = "for colour in 31 32 33 34 35 36; do\n  printf 'hello'\ndone",
                }
                writer:write_tool_call_block(block)

                -- This is what happens when the response ends
                writer:append_separator()

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                -- Find "### Execute" header
                local found_header = false
                local found_fence = false
                local found_command = false
                for _, line in ipairs(lines) do
                    if line == "### Execute" then
                        found_header = true
                    end
                    if line == "```bash" then
                        found_fence = true
                    end
                    if line:find("for colour") then
                        found_command = true
                    end
                end
                assert.is_true(found_header, "Execute header missing")
                assert.is_true(found_fence, "```bash fence missing")
                assert.is_true(found_command, "Command missing")

                -- Block should still be tracked
                assert.is_not_nil(writer.tool_call_blocks["reflow-exec"])

                -- Decorations should exist
                local NS_DECORATIONS =
                    vim.api.nvim_create_namespace("agentic_tool_decorations")
                local decs = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    NS_DECORATIONS,
                    0,
                    -1,
                    {}
                )
                assert.is_true(#decs > 0, "Decoration extmarks missing")
            end
        )

        it(
            "narrow window reflow preserves tool call block after streamed chunks",
            function()
                -- Resize window to trigger prose wrapping in reflow
                vim.api.nvim_win_set_config(winid, { width = 40, height = 40 })

                -- Stream message in multiple chunks (like real ACP flow)
                writer:write_message_chunk(
                    make_message_update("Do a sample for loop that ")
                )
                writer:write_message_chunk(
                    make_message_update("produces multiple lines ")
                )
                writer:write_message_chunk(
                    make_message_update("with ansi colored text\n\n---")
                )

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "narrow-exec",
                    status = "pending",
                    kind = "execute",
                    argument = "for colour in 31 32 33 34 35 36; do\n  printf 'hello'\ndone",
                }
                writer:write_tool_call_block(block)
                writer:append_separator()

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                local found_header = false
                local found_fence = false
                for _, line in ipairs(lines) do
                    if line == "### Execute" then
                        found_header = true
                    end
                    if line == "```bash" then
                        found_fence = true
                    end
                end
                assert.is_true(found_header, "Execute header missing")
                assert.is_true(found_fence, "```bash fence missing")

                -- Decorations should survive
                local NS_DECORATIONS =
                    vim.api.nvim_create_namespace("agentic_tool_decorations")
                local decs = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    NS_DECORATIONS,
                    0,
                    -1,
                    {}
                )
                assert.is_true(#decs > 0, "Decoration extmarks missing")
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

    describe("_format_error_lines", function()
        it("parses auth error with embedded JSON", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: Failed to authenticate. API Error: 401\n"
                    .. '{"type":"error","error":{"type":"authentication_error",'
                    .. '"message":"Invalid authentication credentials"},'
                    .. '"request_id":"req_test123"}',
            }

            local lines = MessageWriter._format_error_lines(err)

            assert.equal("401 Invalid authentication credentials", lines[1])
            assert.equal("", lines[2])
            assert.equal("Try running /login to re-authenticate.", lines[3])
        end)

        it("parses overloaded error with embedded JSON", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: API Error: 529\n"
                    .. '{"type":"error","error":{"type":"overloaded_error",'
                    .. '"message":"Overloaded."}}',
            }

            local lines = MessageWriter._format_error_lines(err)

            assert.equal("529 Overloaded.", lines[1])
            assert.equal("", lines[2])
            assert.equal(
                "The API is overloaded. Try again in a moment.",
                lines[3]
            )
        end)

        it("falls back to raw message when no JSON present", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32000,
                message = "Authentication required",
            }

            local lines = MessageWriter._format_error_lines(err)

            assert.equal("Authentication required", lines[1])
            assert.equal(1, #lines)
        end)

        it("falls back to raw message when JSON is invalid", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: {not valid json}",
            }

            local lines = MessageWriter._format_error_lines(err)

            assert.equal("Internal error: {not valid json}", lines[1])
        end)

        it("uses error type as fallback when message is empty", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = 'API Error: 500\n{"type":"error","error":'
                    .. '{"type":"api_error","message":""}}',
            }

            local lines = MessageWriter._format_error_lines(err)

            assert.equal("Api error", lines[1])
        end)

        it("handles error without HTTP code in prefix", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = 'Something went wrong\n{"type":"error","error":'
                    .. '{"type":"unknown_error","message":"Details here"}}',
            }

            local lines = MessageWriter._format_error_lines(err)

            assert.equal("Details here", lines[1])
        end)

        it("handles missing message field", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = nil, --- @diagnostic disable-line: assign-type-mismatch
            }

            local lines = MessageWriter._format_error_lines(err)

            assert.equal("Unknown error", lines[1])
        end)
    end)

    describe("write_error_message", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("writes heading and body to buffer", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32000,
                message = "Authentication required",
            }

            writer:write_error_message(err)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            assert.equal("### Error", lines[1])
            assert.equal("", lines[2])
            assert.equal("Authentication required", lines[3])
        end)

        it("applies error heading extmark on Error text", function()
            local NS_ERROR = vim.api.nvim_create_namespace("agentic_error")

            --- @type agentic.acp.ACPError
            local err = {
                code = -32000,
                message = "Authentication required",
            }

            writer:write_error_message(err)

            local extmarks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                NS_ERROR,
                0,
                -1,
                { details = true }
            )

            -- First extmark should be the heading highlight
            assert.is_true(#extmarks >= 1)
            local heading_ext = extmarks[1]
            assert.equal(0, heading_ext[2]) -- row 0
            assert.equal(4, heading_ext[3]) -- col 4 (after "### ")
            assert.equal("AgenticErrorHeading", heading_ext[4].hl_group)
        end)

        it("applies error body extmarks on non-empty lines", function()
            local NS_ERROR = vim.api.nvim_create_namespace("agentic_error")

            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: API Error: 401\n"
                    .. '{"type":"error","error":{"type":"authentication_error",'
                    .. '"message":"Invalid authentication credentials"}}',
            }

            writer:write_error_message(err)

            local extmarks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                NS_ERROR,
                0,
                -1,
                { details = true }
            )

            -- Should have heading + body extmarks (skip blank lines)
            local body_extmarks = vim.tbl_filter(function(ext)
                return ext[4].hl_group == "AgenticErrorBody"
            end, extmarks)
            assert.is_true(#body_extmarks > 0)
        end)

        it("writes parsed error on non-empty buffer", function()
            -- Pre-fill buffer with existing content
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "previous message", "" }
            )

            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: API Error: 529\n"
                    .. '{"type":"error","error":{"type":"overloaded_error",'
                    .. '"message":"Overloaded."}}',
            }

            writer:write_error_message(err)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            -- Should find the error after existing content
            local found_heading = false
            local found_body = false
            for _, line in ipairs(lines) do
                if line == "### Error" then
                    found_heading = true
                end
                if line == "529 Overloaded." then
                    found_body = true
                end
            end
            assert.is_true(found_heading)
            assert.is_true(found_body)
        end)
    end)
end)
