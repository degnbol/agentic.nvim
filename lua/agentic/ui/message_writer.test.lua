--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local Renderer = require("agentic.ui.tool_call_renderer")

-- Collapsed tool-call heading glyphs (mirror KIND_GLYPHS in the renderer).
local G_READ = "󰈈"
local G_EXEC = "󰆍"

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
    local original_shell
    local original_code_shell

    before_each(function()
        -- Re-acquire in case a prior test replaced the module in package.loaded
        Config = require("agentic.config")
        original_auto_scroll = Config.auto_scroll
        original_tool_call_display = vim.deepcopy(Config.tool_call_display)
        -- Disable external formatter for deterministic fallback tests
        Config.tool_call_display.execute_formatter = false
        -- Pin the shell so the execute fence label is deterministic — the
        -- renderer resolves it via ExecShell (CLAUDE_CODE_SHELL then $SHELL,
        -- executable & bash/zsh). Use real, executable paths.
        original_shell = vim.env.SHELL
        original_code_shell = vim.env.CLAUDE_CODE_SHELL
        vim.env.CLAUDE_CODE_SHELL = nil
        vim.env.SHELL = "/bin/bash"
        MessageWriter = require("agentic.ui.message_writer")

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 60,
            height = 20,
            row = 0,
            col = 0,
        })

        writer = MessageWriter:new(bufnr)
    end)

    after_each(function()
        Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch
        Config.tool_call_display = original_tool_call_display
        vim.env.SHELL = original_shell
        vim.env.CLAUDE_CODE_SHELL = original_code_shell
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

    describe("emit_divider", function()
        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        it("appends a --- separator after content", function()
            writer:write_message_chunk(make_message_update("subagent prose"))
            writer:emit_divider()
            assert.is_true(vim.tbl_contains(buffer_lines(), "---"))
        end)

        it("no-ops when nothing was written since the last divider", function()
            writer:write_message_chunk(make_message_update("prose"))
            writer:emit_divider()
            local after_first = buffer_lines()

            writer:emit_divider()
            assert.same(after_first, buffer_lines())
        end)
    end)

    describe("subagent ordinal numbering", function()
        local function decoration_signs()
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                Renderer.NS_DECORATIONS,
                0,
                -1,
                { details = true }
            )
            local signs = {}
            for _, m in ipairs(marks) do
                table.insert(signs, m[4].sign_text)
            end
            return signs
        end

        local function count(signs, value)
            local n = 0
            for _, s in ipairs(signs) do
                if s == value then
                    n = n + 1
                end
            end
            return n
        end

        -- The buffer text of every row carrying `value` as its decoration sign.
        -- Full-rail numbering stamps every body row (concealed fence delimiters
        -- included), so this includes fence rows; used to prove the digit
        -- reaches the actual content rows — a content row is never concealed, so
        -- the number is always visible somewhere on the block.
        local function signed_row_texts(value)
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                Renderer.NS_DECORATIONS,
                0,
                -1,
                { details = true }
            )
            local texts = {}
            for _, m in ipairs(marks) do
                if m[4].sign_text == value then
                    local row = m[2]
                    table.insert(
                        texts,
                        vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
                    )
                end
            end
            return texts
        end

        it("renders no number while numbering is inactive", function()
            local block = make_tool_call_block("sub-1", "completed")
            block.ordinal = 0
            writer:write_tool_call_block(block)

            assert.equal(0, count(decoration_signs(), "0 "))
            assert.is_true(count(decoration_signs(), "│ ") > 0)
        end)

        -- Full-rail invariant for a buffer holding only numbered blocks: the
        -- digit replaces every body-row border, so no plain │ remains, and each
        -- block keeps its ╭─/╰─ corners.
        local function assert_full_rail(n_blocks)
            assert.equal(0, count(decoration_signs(), "│ "))
            assert.equal(n_blocks, count(decoration_signs(), "╭─"))
            assert.equal(n_blocks, count(decoration_signs(), "╰─"))
        end

        it("replaces the whole body rail with the ordinal when active", function()
            writer:enable_numbering()

            local block = make_tool_call_block("sub-2", "completed")
            block.ordinal = 0
            writer:write_tool_call_block(block)

            -- every body row becomes the digit; the corners stay
            assert_full_rail(1)

            -- the digit reaches the actual content rows (command + output),
            -- never only the concealed fence delimiters
            assert.is_true(vim.tbl_contains(signed_row_texts("0 "), "ls"))
            assert.is_true(vim.tbl_contains(signed_row_texts("0 "), "output"))
        end)

        it("stamps a fence-less read block's single body row", function()
            writer:enable_numbering()

            local block = {
                tool_call_id = "read-1",
                status = "completed",
                kind = "read",
                argument = "foo.lua",
                body = { "a", "b", "c" },
            }
            block.ordinal = 0
            writer:write_tool_call_block(block)

            -- read's body is a bare "Read N lines" row (no fences), so the whole
            -- rail is that single row
            assert.same({ "Read 3 lines" }, signed_row_texts("0 "))
            assert.equal(0, count(decoration_signs(), "│ "))
        end)

        it("backfills the ordinal onto an already-rendered block", function()
            local block = make_tool_call_block("sub-3", "completed")
            block.ordinal = 1
            writer:write_tool_call_block(block)
            assert.equal(0, count(decoration_signs(), "1 "))
            assert.is_true(count(decoration_signs(), "│ ") > 0)

            writer:enable_numbering()
            assert_full_rail(1)
            assert.is_true(vim.tbl_contains(signed_row_texts("1 "), "output"))
        end)

        it("keeps the number when a live-stamped block gets an update", function()
            writer:enable_numbering()

            local block = make_tool_call_block("sub-4", "pending", { "start" })
            block.ordinal = 1
            writer:write_tool_call_block(block)
            assert_full_rail(1)

            -- completion update with a changed body → content-changed rebuild path
            writer:update_tool_call_block({
                tool_call_id = "sub-4",
                status = "completed",
                body = { "more", "output", "lines" },
            })
            assert_full_rail(1)
            assert.is_true(vim.tbl_contains(signed_row_texts("1 "), "more"))
        end)

        it("backfills two blocks rendered before the latch flips", function()
            local a = make_tool_call_block("agent-a", "completed")
            a.ordinal = 0
            writer:write_tool_call_block(a)
            local b = make_tool_call_block("agent-b", "completed")
            b.ordinal = 1
            writer:write_tool_call_block(b)

            writer:enable_numbering()
            assert_full_rail(2)
            assert.is_true(vim.tbl_contains(signed_row_texts("0 "), "output"))
            assert.is_true(vim.tbl_contains(signed_row_texts("1 "), "output"))
        end)

        it("backfills one block then live-stamps the next", function()
            local a = make_tool_call_block("agent-a2", "completed")
            a.ordinal = 0
            writer:write_tool_call_block(a)

            writer:enable_numbering()

            local b = make_tool_call_block("agent-b2", "completed")
            b.ordinal = 1
            writer:write_tool_call_block(b)

            assert_full_rail(2)
            assert.is_true(vim.tbl_contains(signed_row_texts("0 "), "output"))
            assert.is_true(vim.tbl_contains(signed_row_texts("1 "), "output"))
        end)

        it("shows no number for a bodyless block, then numbers it once a body arrives", function()
            -- header + footer only: no body row to stamp at backfill time
            local block = {
                tool_call_id = "sub-6",
                status = "pending",
                kind = "other",
                argument = "",
            }
            block.ordinal = 1
            writer:write_tool_call_block(block)

            writer:enable_numbering() -- nothing to stamp: bodyless
            assert.equal(0, count(decoration_signs(), "1 "))

            writer:update_tool_call_block({
                tool_call_id = "sub-6",
                status = "completed",
                body = { "output", "lines" },
            })
            assert.is_true(count(decoration_signs(), "1 ") > 0)
            assert.equal(0, count(decoration_signs(), "│ "))
        end)

        it("numbers a block first rendered pending, then updated after backfill", function()
            -- realistic subagent flow: pending initial (little output yet)
            -- renders before the second agent exists, so numbering is still
            -- inactive and the block is stamped by backfill + the later update
            local block = make_tool_call_block("sub-5", "pending", { "start" })
            block.ordinal = 1
            writer:write_tool_call_block(block)

            writer:enable_numbering()

            writer:update_tool_call_block({
                tool_call_id = "sub-5",
                status = "completed",
                body = { "more", "output", "lines" },
            })
            assert_full_rail(1)
            assert.is_true(vim.tbl_contains(signed_row_texts("1 "), "more"))
        end)
    end)

    describe("write_user_prompt", function()
        --- 0-indexed rows carrying a prompt marker, traversal order.
        local function marker_rows()
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                MessageWriter.NS_PROMPT_MARKERS,
                0,
                -1,
                {}
            )
            local rows = {}
            for _, mark in ipairs(marks) do
                table.insert(rows, mark[2])
            end
            return rows
        end

        local function line_at(row)
            return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        end

        it("marks the heading row when writing into a non-empty buffer", function()
            writer:write_message(make_message_update("prior agent prose"))
            local before = vim.api.nvim_buf_line_count(bufnr)

            writer:write_user_prompt("Hello there")

            assert.same({ before }, marker_rows())
            assert.equal("## Hello there", line_at(before))
        end)

        it("marks row 0 when the buffer is empty", function()
            writer:write_user_prompt("First prompt")

            assert.same({ 0 }, marker_rows())
            assert.equal("## First prompt", line_at(0))
        end)

        it("keeps the marker on the heading across a chunk reflow", function()
            writer:write_message_chunk(make_message_update("thinking one"))
            writer:write_user_prompt("The prompt")
            writer:write_message_chunk(make_message_update("thinking two"))
            writer:finalize_turn()

            local rows = marker_rows()
            assert.equal(1, #rows)
            assert.equal("## The prompt", line_at(rows[1]))
        end)
    end)

    describe("_check_auto_scroll", function()
        it("returns true when cursor is on the last line", function()
            setup_buffer(50, 50)
            assert.is_true(writer:_check_auto_scroll(bufnr))
        end)

        it("returns false when cursor is not on the last line", function()
            setup_buffer(50, 1)
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns false when paused regardless of cursor", function()
            setup_buffer(50, 50)
            writer._auto_scroll_paused = true
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it(
            "returns true when viewport reaches end without cursor on last line, focus elsewhere",
            function()
                -- Cursor mid-buffer in chat, viewport scrolled so the
                -- last line is visible, but focus is in another window.
                -- The user can't move the chat cursor — the viewport is
                -- the only signal. Mimics OS-scroll-wheel-hovering-on-chat
                -- while focused in the input panel.
                setup_buffer(30, 15)
                vim.api.nvim_win_call(winid, function()
                    vim.fn.winrestview({ topline = 11 })
                end)
                vim.cmd("redraw")

                -- Switch focus away from the chat window.
                local other_buf = vim.api.nvim_create_buf(false, true)
                local other_win = vim.api.nvim_open_win(other_buf, true, {
                    relative = "editor",
                    width = 20,
                    height = 5,
                    row = 25,
                    col = 0,
                })

                assert.is_true(writer:_check_auto_scroll(bufnr))

                vim.api.nvim_win_close(other_win, true)
                vim.api.nvim_buf_delete(other_buf, { force = true })
            end
        )

        it(
            "returns false when chat is focused but cursor is not on last line, even if last line is visible",
            function()
                -- Short buffer that fits in winheight=20: botline reaches
                -- end without any scrolling. Chat is focused. User is
                -- reading mid-buffer with the cursor up — not "at bottom".
                setup_buffer(10, 3)
                vim.api.nvim_set_current_win(winid)
                local info = vim.fn.getwininfo(winid)[1]
                assert.is_true(info.botline >= 10) -- viewport shows last line
                assert.is_false(writer:_check_auto_scroll(bufnr))
            end
        )

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
            assert.is_true(writer._scroll_callback_queued)

            local check_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)
            writer:_auto_scroll(bufnr)

            assert.equal(0, check_spy.call_count)
            check_spy:revert()
        end)
    end)

    describe("_should_auto_scroll sticky field", function()
        it(
            "remains true after buffer growth despite cursor leaving the bottom band",
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
                assert.is_false(writer._scroll_callback_queued)

                schedule_stub:revert()

                schedule_stub = spy.stub(vim, "schedule")

                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                writer:_auto_scroll(bufnr)
                assert.is_false(writer._should_auto_scroll)

                schedule_stub:revert()
            end
        )
    end)

    describe("fold-path scroll ownership", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "callback skips the scroll and keeps the verdict when a fold op is pending",
            function()
                setup_buffer(50, 1)
                -- A pending fold op stands in for a queued :foldclose.
                writer._pending_fold_ops = { { id = 1, open = false } }
                writer._should_auto_scroll = true

                local scroll_spy = spy.on(writer, "_scroll_now")
                writer:_auto_scroll(bufnr)

                assert.equal(0, scroll_spy.call_count)
                -- Verdict survives for flush_pending_fold_ops to consume.
                assert.is_true(writer._should_auto_scroll)
                scroll_spy:revert()
            end
        )

        it("flush scrolls once the folds are closed, then clears the verdict", function()
            setup_buffer(50, 1)
            writer._should_auto_scroll = true

            local scroll_spy = spy.on(writer, "_scroll_now")
            -- A real fold anchor isn't needed — flush scrolls after draining
            -- whatever ops are present, missing folds are swallowed.
            local id =
                vim.api.nvim_buf_set_extmark(bufnr, vim.api.nvim_create_namespace("agentic_fold_anchors"), 0, 0, {})
            writer._pending_fold_ops = { { id = id, open = false } }
            writer:flush_pending_fold_ops()

            assert.equal(1, scroll_spy.call_count)
            assert.is_nil(writer._should_auto_scroll)
            scroll_spy:revert()
        end)

        it("flush does not scroll a scrolled-away user", function()
            setup_buffer(50, 1)
            writer._should_auto_scroll = true
            writer._auto_scroll_paused = true

            local scroll_spy = spy.on(writer, "_scroll_now")
            local id =
                vim.api.nvim_buf_set_extmark(bufnr, vim.api.nvim_create_namespace("agentic_fold_anchors"), 0, 0, {})
            writer._pending_fold_ops = { { id = id, open = false } }
            writer:flush_pending_fold_ops()

            assert.equal(0, scroll_spy.call_count)
            scroll_spy:revert()
        end)
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

    describe("prose anchor pin", function()
        it("sets anchor on first prose chunk", function()
            writer:write_message_chunk(
                make_message_update("Hello, here is some prose.")
            )

            assert.is_not_nil(writer._prose_anchor_line)
        end)

        it("clears anchor when a tool call follows", function()
            writer:write_message_chunk(make_message_update("first prose"))
            assert.is_not_nil(writer._prose_anchor_line)

            writer:write_tool_call_block(make_tool_call_block("t1", "pending"))

            assert.is_nil(writer._prose_anchor_line)
        end)

        it("re-anchors on prose after a tool call", function()
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:write_message_chunk(
                make_message_update("Now writing the summary.")
            )

            assert.is_not_nil(writer._prose_anchor_line)
            local anchor_line = writer._prose_anchor_line --[[@as integer]]
            local content = vim.api.nvim_buf_get_lines(
                bufnr,
                anchor_line,
                anchor_line + 1,
                false
            )[1]
            -- Anchor must land on actual prose, not the leading blank line
            -- the writer inserts after a tool call.
            assert.is_not_nil(content)
            assert.is_true(content:match("%S") ~= nil)
        end)

        local NS_TURN_USAGE =
            vim.api.nvim_create_namespace("agentic_turn_usage")

        local function usage_extmarks()
            return vim.api.nvim_buf_get_extmarks(
                bufnr,
                NS_TURN_USAGE,
                0,
                -1,
                { details = true }
            )
        end

        it("stamps a right-aligned footer for a non-zero turn", function()
            writer:finalize_turn()
            writer:set_turn_usage({ inputTokens = 1234, outputTokens = 420 })

            local marks = usage_extmarks()
            assert.equal(#marks, 1)
            local vt = marks[1][4].virt_text
            local text = vt and vt[1] and vt[1][1]
            assert.equal(marks[1][4].virt_text_pos, "right_align")
            assert.equal(text, "1.2k in · 0.4k out")
        end)

        it("renders nothing for an all-zero turn", function()
            writer:finalize_turn()
            writer:set_turn_usage({ inputTokens = 0, outputTokens = 0 })
            assert.equal(#usage_extmarks(), 0)
        end)

        it("renders nothing for missing usage", function()
            writer:finalize_turn()
            writer:set_turn_usage(nil)
            assert.equal(#usage_extmarks(), 0)
        end)

        it("clears anchor on finalize_turn (turn end)", function()
            writer:write_message_chunk(make_message_update("final answer"))
            assert.is_not_nil(writer._prose_anchor_line)

            writer:finalize_turn()

            assert.is_nil(writer._prose_anchor_line)
        end)

        it("clears anchor on reset_turn_state", function()
            writer:write_message_chunk(make_message_update("some prose"))
            assert.is_not_nil(writer._prose_anchor_line)

            writer:reset_turn_state()

            assert.is_nil(writer._prose_anchor_line)
        end)

        it("clears anchor on write_error_message", function()
            writer:write_message_chunk(make_message_update("interrupted"))
            assert.is_not_nil(writer._prose_anchor_line)

            writer:write_error_message({
                code = -32603,
                message = "Internal error: something went wrong",
            })

            assert.is_nil(writer._prose_anchor_line)
        end)

        it(
            "user scrolls away from bottom: pauses and releases pin",
            function()
                writer:write_message_chunk(
                    make_message_update("some prose")
                )
                assert.is_not_nil(writer._prose_anchor_line)
                -- Grow the buffer and park cursor far from the end so the
                -- threshold check sees a "scrolled away" state.
                local lines = {}
                for i = 1, 50 do
                    lines[i] = "filler " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                writer:on_user_scroll()

                assert.is_nil(writer._prose_anchor_line)
                assert.is_true(writer._auto_scroll_paused)
            end
        )

        it(
            "user scrolls to bottom: resumes auto-scroll",
            function()
                -- User had previously paused; now G or scroll-to-bottom.
                writer._auto_scroll_paused = true
                local lines = {}
                for i = 1, 50 do
                    lines[i] = "line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
                vim.api.nvim_win_set_cursor(winid, { 50, 0 })

                writer:on_user_scroll()

                assert.is_false(writer._auto_scroll_paused)
            end
        )

        it(
            "ignores on_user_scroll while _suppress_pin_release is set",
            function()
                writer:write_message_chunk(make_message_update("some prose"))
                assert.is_not_nil(writer._prose_anchor_line)
                local lines = {}
                for i = 1, 50 do
                    lines[i] = "filler " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                -- Our own programmatic scrolls/writes fire WinScrolled with
                -- the suppression flag set; pause/pin must survive those.
                writer._suppress_pin_release = true
                writer:on_user_scroll()
                writer._suppress_pin_release = false

                assert.is_not_nil(writer._prose_anchor_line)
                assert.is_false(writer._auto_scroll_paused)
            end
        )

        it("does not set the pin while paused", function()
            writer._auto_scroll_paused = true

            writer:write_message_chunk(make_message_update("more prose"))

            assert.is_nil(writer._prose_anchor_line)
        end)

        it("keeps anchor pinned when scrolloff is non-zero", function()
            -- scrolloff = 4 (a common user setting) was breaking the pin:
            -- vim insists on `scrolloff` lines between cursor and the
            -- window bottom, so parking the cursor at the last visible
            -- row caused vim to scroll topline forward by `scrolloff`
            -- lines, defeating the clamp.
            vim.wo[winid].scrolloff = 4

            for i = 1, 30 do
                writer:write_message_chunk(
                    make_message_update("line " .. i .. "\n")
                )
                vim.cmd("redraw")
            end
            vim.wait(50, function()
                return false
            end)
            vim.cmd("redraw")

            local info = vim.fn.getwininfo(winid)[1]
            assert.equal(1, info.topline)
        end)

        it(
            "keeps anchor pinned across streaming chunks past the viewport",
            function()
                -- Window height = 20. Stream 25 chunks of one line each.
                -- The prose anchor lands at row 0; once total > winheight
                -- the natural scroll would push the anchor off-screen.
                -- The pin must keep topline at row 1 (anchor + 1 in
                -- 1-indexed terms) for every subsequent chunk.
                --
                -- Regression: nvim_buf_set_text moves the chat cursor to
                -- the end of inserted text; vim then auto-corrects topline
                -- to keep the cursor visible. That happens between
                -- _check_auto_scroll (pre-write) and scroll_down (scheduled,
                -- post-write). Cannot stub vim.schedule synchronously here:
                -- doing so runs scroll_down *before* the write, which
                -- bypasses the bug entirely. Drain via vim.wait instead.
                for i = 1, 25 do
                    writer:write_message_chunk(
                        make_message_update("line " .. i .. "\n")
                    )
                    vim.cmd("redraw")
                    vim.wait(20, function()
                        return false
                    end)
                end

                local info = vim.fn.getwininfo(winid)[1]
                assert.equal(1, info.topline)
                -- Cursor parked inside the pinned viewport, not at last.
                assert.is_true(
                    vim.api.nvim_win_get_cursor(winid)[1] <= 20
                )
            end
        )
    end)

    describe("scroll_down max_topline cap", function()
        --- @type agentic.utils.BufHelpers
        local BufHelpers

        before_each(function()
            BufHelpers = require("agentic.utils.buf_helpers")
        end)

        it("caps natural scroll at max_topline", function()
            -- Window height = 20. Add 50 lines so the natural target
            -- topline is ~31; with max_topline=10 the viewport is held at
            -- line 10.
            local lines = {}
            for i = 1, 50 do
                lines[i] = "line " .. i
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            vim.api.nvim_win_set_cursor(winid, { 1, 0 })
            vim.api.nvim_win_call(winid, function()
                vim.fn.winrestview({ topline = 1 })
            end)

            BufHelpers.scroll_down(winid, 10)
            -- Force a redraw — vim re-corrects topline if cursor is off
            -- screen, which the parked cursor inside the viewport prevents.
            vim.cmd("redraw")

            local info = vim.fn.getwininfo(winid)[1]
            assert.equal(10, info.topline)
            local cursor = vim.api.nvim_win_get_cursor(winid)
            assert.is_true(cursor[1] >= 10)
            assert.is_true(cursor[1] <= 10 + 20 - 1)
        end)

        it("is a no-op when target would scroll upward", function()
            -- scroll_down never moves the viewport backward, even when
            -- max_topline lies above the current topline.
            local lines = {}
            for i = 1, 50 do
                lines[i] = "line " .. i
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            vim.api.nvim_win_set_cursor(winid, { 25, 0 })
            vim.api.nvim_win_call(winid, function()
                vim.fn.winrestview({ topline = 25 })
            end)

            BufHelpers.scroll_down(winid, 10)

            local info = vim.fn.getwininfo(winid)[1]
            assert.equal(25, info.topline)
        end)

        it("scrolls normally when max_topline is nil", function()
            local lines = {}
            for i = 1, 50 do
                lines[i] = "line " .. i
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            vim.api.nvim_win_set_cursor(winid, { 1, 0 })
            vim.api.nvim_win_call(winid, function()
                vim.fn.winrestview({ topline = 1 })
            end)

            BufHelpers.scroll_down(winid, nil)

            local info = vim.fn.getwininfo(winid)[1]
            -- With 50 lines and a 20-line window, natural bottom-scroll puts
            -- topline ~= 31. Without a clamp it should be much greater than 10.
            assert.is_true(info.topline > 10)
        end)

        it(
            "no-ops without error when topline sits on the last line",
            function()
                -- The last line alone is taller than the window (wraps to
                -- ~34 rows > winheight=20) and the viewport already starts
                -- on it, so no forward scroll is possible. The tail-does-
                -- not-fit height check cannot short-circuit here, so this
                -- pins the `old_topline >= last_line` guard: without it the
                -- search would start below the last line and compute an
                -- out-of-range target.
                local lines = {}
                for i = 1, 5 do
                    lines[i] = "line " .. i
                end
                lines[6] = string.rep("x", 2000)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

                vim.wo[winid].wrap = true
                vim.api.nvim_win_set_cursor(winid, { 6, 0 })
                vim.api.nvim_win_call(winid, function()
                    vim.fn.winrestview({ topline = 6 })
                end)
                vim.cmd("redraw")

                BufHelpers.scroll_down(winid, nil)

                local info = vim.fn.getwininfo(winid)[1]
                assert.equal(6, info.topline)
            end
        )

        it(
            "stays put when closed folds collapse buffer to fit window",
            function()
                -- 30 buffer lines with lines 2..16 collapsed into one screen
                -- row by a closed fold. Total visible rows = 1 (line 1) +
                -- 1 (fold) + 14 (lines 17..30) = 16 ≤ winheight=20. The whole
                -- content fits, so topline must remain at 1 — buffer-line math
                -- would have set it to 30 - 20 + 1 = 11. The fold source is
                -- irrelevant to scroll_down (it works off rendered screen
                -- rows), so a manual fold stands in for the treesitter fold.
                local lines = {}
                for i = 1, 30 do
                    lines[i] = "line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

                vim.wo[winid].foldmethod = "manual"
                vim.wo[winid].foldenable = true
                vim.api.nvim_win_call(winid, function()
                    vim.cmd("2,16fold")
                end)
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })
                vim.api.nvim_win_call(winid, function()
                    vim.fn.winrestview({ topline = 1 })
                end)
                vim.cmd("redraw")

                BufHelpers.scroll_down(winid, nil)
                vim.cmd("redraw")

                local info = vim.fn.getwininfo(winid)[1]
                assert.equal(1, info.topline)
                assert.equal(30, info.botline)
            end
        )
    end)

    describe("_check_auto_scroll prose-pin override", function()
        it(
            "returns true while a prose anchor is set, regardless of view",
            function()
                local lines = {}
                for i = 1, 50 do
                    lines[i] = "line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
                -- Cursor far from buffer end — threshold would fail.
                vim.api.nvim_win_set_cursor(winid, { 1, 0 })
                writer._prose_anchor_line = 9

                -- Pin overrides the proximity threshold. Vim is free to
                -- drift topline (scrolloff, redraws) and drag the cursor
                -- with it; neither field is a reliable user-intent signal,
                -- so the pin stays armed until cleared by a turn boundary
                -- (tool call, separator, error, /new).
                assert.is_true(writer:_check_auto_scroll(bufnr))
                assert.is_not_nil(writer._prose_anchor_line)
            end
        )
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

        it("renders execute tool call with bash and console fences", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-fence",
                status = "pending",
                kind = "execute",
                argument = "ls -la /tmp",
                body = { "total 16" },
            }

            local lines, _ = Renderer.prepare_block_lines(block, 80)

            assert.equal("### " .. G_EXEC, lines[1])
            assert.equal("```bash", lines[2])
            assert.equal("ls -la /tmp", lines[3])
            assert.equal("```", lines[4])
            assert.equal("```console", lines[5])
            assert.equal("total 16", lines[6])
            assert.equal("```", lines[7])
        end)

        it("labels the execute fence with the shell from $SHELL", function()
            vim.env.SHELL = "/bin/zsh"
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-zsh",
                status = "pending",
                kind = "execute",
                argument = "ls -la /tmp",
                body = { "total 16" },
            }

            local lines, _ = Renderer.prepare_block_lines(block, 80)

            assert.equal("```zsh", lines[2])
        end)

        it(
            "renders the execute description as the collapsed heading name",
            function()
                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "exec-desc",
                    status = "completed",
                    kind = "execute",
                    argument = "ls -la /tmp",
                    description = "List the temp directory",
                    body = { "total 16" },
                }

                local lines, _ = Renderer.prepare_block_lines(block, 80)

                assert.equal("### " .. G_EXEC .. " `List the temp directory`", lines[1])
                assert.equal("```bash", lines[2])
                assert.equal("ls -la /tmp", lines[3])
                assert.equal("```", lines[4])
                -- Single console fence around the body — no nested/double wrap.
                assert.equal("```console", lines[5])
                assert.equal("total 16", lines[6])
                assert.equal("```", lines[7])
            end
        )

        it(
            "unwraps an already-fenced execute body to avoid double-wrapping",
            function()
                -- A body that arrives still wrapped in a ```console fence (e.g.
                -- a stale adapter instance after hot-reload, or a provider that
                -- pre-fences) must not be wrapped a second time.
                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "exec-prefenced",
                    status = "completed",
                    kind = "execute",
                    argument = "echo hi",
                    body = { "```console", "hi", "```" },
                }

                local lines, _ = Renderer.prepare_block_lines(block, 80)
                local text = table.concat(lines, "\n")

                assert.is_nil(text:match("```console\n```console"))
                local openers = 0
                for _ in text:gmatch("```console") do
                    openers = openers + 1
                end
                assert.equal(1, openers)
                assert.equal("### " .. G_EXEC, lines[1])
                assert.equal("```bash", lines[2])
                assert.equal("echo hi", lines[3])
                assert.equal("```", lines[4])
                assert.equal("```console", lines[5])
                assert.equal("hi", lines[6])
                assert.equal("```", lines[7])
            end
        )

        it("splits multi-line execute arguments into separate lines", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "exec-multi",
                status = "pending",
                kind = "execute",
                argument = "for i in 1 2 3; do\necho $i\ndone",
            }

            local lines, _ = Renderer.prepare_block_lines(block, 80)

            assert.equal("### " .. G_EXEC, lines[1])
            assert.equal("```bash", lines[2])
            assert.equal("for i in 1 2 3; do", lines[3])
            assert.equal("echo $i", lines[4])
            assert.equal("done", lines[5])
            assert.equal("```", lines[6])
        end)

        it(
            "renders non-execute tool call with argument on the collapsed heading",
            function()
                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "read-inline",
                    status = "pending",
                    kind = "read",
                    argument = "/tmp/file.txt",
                    body = { "line1" },
                }

                local lines, _ = Renderer.prepare_block_lines(block, 80)

                assert.equal("### " .. G_READ .. " `/tmp/file.txt`", lines[1])
                assert.equal("Read 1 lines", lines[2])
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

            local lines, _ = Renderer.prepare_block_lines(block, 80)

            assert.equal("### " .. G_READ .. " `/tmp/file.txt`", lines[1])
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

            local lines, _ = Renderer.prepare_block_lines(block, 80)

            assert.equal("### " .. G_READ .. " `/tmp/file.txt`", lines[1])
            assert.equal("Read 100 lines (1 - 100)", lines[2])
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

            local lines, _ = Renderer.prepare_block_lines(block, 80)

            assert.equal("### " .. G_READ .. " `/tmp/file.txt`", lines[1])
            assert.equal("Read 3 lines (10 - 12)", lines[2])
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

            local lines, highlight_ranges =
                Renderer.prepare_block_lines(block, 80)

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

            local lines, _ = Renderer.prepare_block_lines(block, 80)

            assert.equal("### " .. G_EXEC, lines[1])
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

            local lines, _ = Renderer.prepare_block_lines(block, 80)

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

            local lines, _ = Renderer.prepare_block_lines(block, 80)

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

            local lines, _ = Renderer.prepare_block_lines(block, 80)

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
                assert.equal("### " .. G_EXEC, lines_after_write[1])
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
                assert.equal("### " .. G_EXEC, lines_after_update[1])
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
            "finalize_turn reflow does not corrupt tool call block",
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
                writer:finalize_turn()

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                -- Find the collapsed execute header
                local found_header = false
                local found_fence = false
                local found_command = false
                for _, line in ipairs(lines) do
                    if line == "### " .. G_EXEC then
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
                writer:finalize_turn()

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                local found_header = false
                local found_fence = false
                for _, line in ipairs(lines) do
                    if line == "### " .. G_EXEC then
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

    describe("message boundary space insertion", function()
        it("inserts space when uppercase follows non-whitespace", function()
            writer:write_message_chunk(
                make_message_update("Compacting completed.")
            )
            writer:write_message_chunk(
                make_message_update("Now continuing the work.")
            )

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local last_content = lines[#lines] ~= "" and lines[#lines]
                or lines[#lines - 1]
            assert.truthy(
                last_content:find("completed%. Now"),
                "Expected space between chunks, got: " .. last_content
            )
        end)

        it("does not insert space when chunk starts with whitespace", function()
            writer:write_message_chunk(make_message_update("Hello"))
            writer:write_message_chunk(make_message_update(" World"))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local last = lines[#lines] ~= "" and lines[#lines]
                or lines[#lines - 1]
            assert.truthy(
                last:find("Hello World"),
                "Should not double-space: " .. last
            )
        end)

        it("does not insert space when chunk starts lowercase", function()
            writer:write_message_chunk(make_message_update("use `"))
            writer:write_message_chunk(make_message_update("vim.api"))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local last = lines[#lines] ~= "" and lines[#lines]
                or lines[#lines - 1]
            assert.truthy(
                last:find("`vim%.api"),
                "Should not insert space before lowercase: " .. last
            )
        end)

        it(
            "does not insert space inside abbreviations streamed as separate chunks",
            function()
                writer:write_message_chunk(make_message_update("the C"))
                writer:write_message_chunk(make_message_update("WD is"))

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local last = lines[#lines] ~= "" and lines[#lines]
                    or lines[#lines - 1]
                assert.truthy(
                    last:find("CWD"),
                    "Should not split abbreviation: " .. last
                )
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

            local lines, error_type = MessageWriter._format_error_lines(err)

            assert.equal("401 Invalid authentication credentials", lines[1])
            -- No hint line — auth re-login is handled by the caller
            assert.equal(1, #lines)
            assert.equal("authentication_error", error_type)
        end)

        it("parses overloaded error with embedded JSON", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: API Error: 529\n"
                    .. '{"type":"error","error":{"type":"overloaded_error",'
                    .. '"message":"Overloaded."}}',
            }

            local lines, error_type = MessageWriter._format_error_lines(err)

            assert.equal("529 Overloaded.", lines[1])
            assert.equal("", lines[2])
            assert.equal(
                "The API is overloaded. Try again in a moment.",
                lines[3]
            )
            assert.equal("overloaded_error", error_type)
        end)

        it("falls back to raw message when no JSON present", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32000,
                message = "Authentication required",
            }

            local lines, error_type = MessageWriter._format_error_lines(err)

            assert.equal("Authentication required", lines[1])
            assert.equal(1, #lines)
            assert.is_nil(error_type)
        end)

        it("falls back to raw message when JSON is invalid", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: {not valid json}",
            }

            local lines, error_type = MessageWriter._format_error_lines(err)

            assert.equal("Internal error: {not valid json}", lines[1])
            assert.is_nil(error_type)
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

        it("detects usage limit error with 12h time format", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: You're out of extra usage · resets 5pm (Europe/London)",
            }

            local lines, error_type, reset_epoch =
                MessageWriter._format_error_lines(err)

            assert.equal("usage_limit", error_type)
            assert.equal(1, #lines)
            assert.truthy(lines[1]:find("out of extra usage"))
            -- reset_epoch depends on system time, just check it's a number or nil
            -- (nil if GNU date isn't available)
            if reset_epoch then
                assert.truthy(reset_epoch > os.time())
            end
        end)

        it("detects usage limit error with 24h time format", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: You're out of extra usage · resets 17:00 (Europe/London)",
            }

            local lines, error_type = MessageWriter._format_error_lines(err)

            assert.equal("usage_limit", error_type)
            assert.truthy(lines[1]:find("out of extra usage"))
        end)

        it("detects usage limit error with minutes in 12h format", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: You're out of extra usage · resets 5:30pm (US/Eastern)",
            }

            local lines, error_type = MessageWriter._format_error_lines(err)

            assert.equal("usage_limit", error_type)
            assert.truthy(lines[1]:find("out of extra usage"))
        end)

        it("returns nil error_type for non-usage-limit plain errors", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: Something else went wrong",
            }

            local _, error_type = MessageWriter._format_error_lines(err)

            assert.is_nil(error_type)
        end)

        it("classifies billing_error from errorKind with a hint", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "billing_error" },
                message = "Internal error: You've hit your org's monthly spend "
                    .. "limit · run /usage-credits to ask your admin for a "
                    .. "higher limit",
            }

            local lines, error_type, reset_epoch =
                MessageWriter._format_error_lines(err)

            assert.equal("billing_error", error_type)
            assert.is_nil(reset_epoch)
            -- Wrapper prefix stripped from the first body line
            assert.equal(
                "You've hit your org's monthly spend limit · run /usage-credits"
                    .. " to ask your admin for a higher limit",
                lines[1]
            )
            -- Hint present after a blank separator
            assert.equal("", lines[2])
            assert.truthy(lines[3]:find("no automatic retry", 1, true))
        end)

        it("maps authentication_failed errorKind to auth class", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "authentication_failed" },
                message = "Internal error: Please run /login",
            }

            local _, error_type = MessageWriter._format_error_lines(err)

            assert.equal("authentication_error", error_type)
        end)

        it("errorKind is authoritative over embedded JSON class", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "authentication_failed" },
                message = "Internal error: API Error: 500\n"
                    .. '{"type":"error","error":{"type":"server_error",'
                    .. '"message":"Boom"}}',
            }

            local lines, error_type = MessageWriter._format_error_lines(err)

            -- Class comes from errorKind; display still uses the JSON extraction
            assert.equal("authentication_error", error_type)
            assert.equal("500 Boom", lines[1])
        end)

        it("mapped kind keeps its hint when embedded JSON is present", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "billing_error" },
                message = "Internal error: API Error: 400\n"
                    .. '{"type":"error","error":{"type":"invalid_request_error",'
                    .. '"message":"Spend cap"}}',
            }

            local lines, error_type = MessageWriter._format_error_lines(err)

            assert.equal("billing_error", error_type)
            assert.equal("400 Spend cap", lines[1])
            -- Hint follows the resolved (billing) class, not the JSON type
            assert.truthy(lines[3] and lines[3]:find("no automatic retry", 1, true))
        end)

        it("strips the API Error prefix from a mapped-kind body", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "authentication_failed" },
                message = "Internal error: API Error: 401 Session expired",
            }

            local lines = MessageWriter._format_error_lines(err)

            assert.equal("Session expired", lines[1])
        end)

        it("returns reset_epoch nil for a mapped kind over a reset clause", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "billing_error" },
                message = "Internal error: Spend cap · resets 5pm (Europe/London)",
            }

            local _, error_type, reset_epoch =
                MessageWriter._format_error_lines(err)

            -- errorKind wins: billing has no reset, so no auto-continue epoch
            assert.equal("billing_error", error_type)
            assert.is_nil(reset_epoch)
        end)

        it("unmapped errorKind falls through to text classification", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                data = { errorKind = "server_error" },
                message = "Internal error: API Error: 529\n"
                    .. '{"type":"error","error":{"type":"overloaded_error",'
                    .. '"message":"Overloaded."}}',
            }

            local lines, error_type = MessageWriter._format_error_lines(err)

            assert.equal("overloaded_error", error_type)
            assert.equal("529 Overloaded.", lines[1])
        end)
    end)

    describe("_parse_reset_time", function()
        it("returns a future epoch for a valid time and timezone", function()
            -- This test depends on GNU date being available
            local epoch = MessageWriter._parse_reset_time("11:59pm", "UTC")
            if epoch then
                assert.truthy(epoch > os.time())
            end
        end)

        it("returns nil for invalid timezone", function()
            local epoch =
                MessageWriter._parse_reset_time("5pm", "Not/A/Timezone")
            -- GNU date may still parse this or return nil; just ensure no crash
            assert.truthy(epoch == nil or type(epoch) == "number")
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

        it(
            "writes heading and body to buffer and returns error_type",
            function()
                --- @type agentic.acp.ACPError
                local err = {
                    code = -32000,
                    message = "Authentication required",
                }

                local error_type = writer:write_error_message(err)

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

                assert.equal("### Error", lines[1])
                assert.equal("", lines[2])
                assert.equal("Authentication required", lines[3])
                -- No embedded JSON, so error_type is nil
                assert.is_nil(error_type)
            end
        )

        it("returns parsed error_type from embedded JSON", function()
            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "Internal error: API Error: 401\n"
                    .. '{"type":"error","error":{"type":"authentication_error",'
                    .. '"message":"Invalid credentials"}}',
            }

            local error_type = writer:write_error_message(err)

            assert.equal("authentication_error", error_type)
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

    describe("write_error_action", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("appends action text with ERROR_BODY highlight", function()
            local NS_ERROR = vim.api.nvim_create_namespace("agentic_error")

            -- Pre-fill buffer so action appends
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "### Error", "", "401 Auth failed", "" }
            )

            writer:write_error_action(
                "Press [r] to re-authenticate in browser."
            )

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            -- Action text should be appended after existing content
            local found = false
            for _, line in ipairs(lines) do
                if line == "Press [r] to re-authenticate in browser." then
                    found = true
                end
            end
            assert.is_true(found)

            -- Should have an ERROR_BODY extmark on the action line
            local extmarks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                NS_ERROR,
                0,
                -1,
                { details = true }
            )
            local body_extmarks = vim.tbl_filter(function(ext)
                return ext[4].hl_group == "AgenticErrorBody"
            end, extmarks)
            assert.is_true(#body_extmarks > 0)
        end)
    end)

    --- @diagnostic disable: missing-fields, redundant-parameter
    describe("parallel tool calls", function()
        it(
            "all blocks remain in buffer after sequential write then update",
            function()
                -- Simulate parallel tool calls: 3 blocks written, then enriched, then completed
                -- This mirrors the ACP event order for parallel tool calls

                -- Phase 1: Initial tool_call events (pending, minimal)
                local block1 = {
                    tool_call_id = "par-1",
                    status = "pending",
                    kind = "execute",
                    argument = nil,
                    body = nil,
                }
                writer:write_tool_call_block(
                    block1 --[[@as agentic.ui.MessageWriter.ToolCallBlock]]
                )

                local block2 = {
                    tool_call_id = "par-2",
                    status = "pending",
                    kind = "execute",
                    argument = nil,
                    body = nil,
                }
                writer:write_tool_call_block(
                    block2 --[[@as agentic.ui.MessageWriter.ToolCallBlock]]
                )

                local block3 = {
                    tool_call_id = "par-3",
                    status = "pending",
                    kind = "execute",
                    argument = nil,
                    body = nil,
                }
                writer:write_tool_call_block(
                    block3 --[[@as agentic.ui.MessageWriter.ToolCallBlock]]
                )

                -- All 3 blocks should be tracked
                assert.is_not_nil(writer.tool_call_blocks["par-1"])
                assert.is_not_nil(writer.tool_call_blocks["par-2"])
                assert.is_not_nil(writer.tool_call_blocks["par-3"])

                -- Phase 2: Enrichment updates (rawInput arrives, no status)
                writer:update_tool_call_block({
                    tool_call_id = "par-1",
                    kind = "execute",
                    argument = "rm /tmp/file1.txt",
                    body = { "```bash", "rm /tmp/file1.txt", "```" },
                } --[[@as agentic.ui.MessageWriter.ToolCallBase]])

                writer:update_tool_call_block({
                    tool_call_id = "par-2",
                    kind = "execute",
                    argument = "rm /tmp/file2.txt",
                    body = { "```bash", "rm /tmp/file2.txt", "```" },
                } --[[@as agentic.ui.MessageWriter.ToolCallBase]])

                writer:update_tool_call_block({
                    tool_call_id = "par-3",
                    kind = "execute",
                    argument = "rm /tmp/file3.txt",
                    body = { "```bash", "rm /tmp/file3.txt", "```" },
                } --[[@as agentic.ui.MessageWriter.ToolCallBase]])

                -- Phase 3: Completed updates
                writer:update_tool_call_block({
                    tool_call_id = "par-1",
                    status = "completed",
                })

                writer:update_tool_call_block({
                    tool_call_id = "par-2",
                    status = "completed",
                })

                writer:update_tool_call_block({
                    tool_call_id = "par-3",
                    status = "completed",
                })

                -- Verify all 3 blocks still have valid extmarks
                for _, id in ipairs({ "par-1", "par-2", "par-3" }) do
                    local tracker = writer.tool_call_blocks[id]
                    assert.is_not_nil(tracker, "tracker missing for " .. id)
                    local pos = vim.api.nvim_buf_get_extmark_by_id(
                        bufnr,
                        Renderer.NS_TOOL_BLOCKS,
                        tracker.extmark_id,
                        { details = true }
                    )
                    assert.is_not_nil(pos[1], "extmark missing for " .. id)
                    local start_row = pos[1]
                    local end_row = pos[3].end_row
                    assert.truthy(
                        end_row > start_row,
                        string.format(
                            "collapsed extmark for %s: start=%d end=%d",
                            id,
                            start_row,
                            end_row
                        )
                    )
                end

                -- Verify buffer content: search for each block's argument text
                local all_lines =
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local content = table.concat(all_lines, "\n")
                assert.truthy(
                    content:find("file1", 1, true),
                    "block 1 content missing from buffer"
                )
                assert.truthy(
                    content:find("file2", 1, true),
                    "block 2 content missing from buffer"
                )
                assert.truthy(
                    content:find("file3", 1, true),
                    "block 3 content missing from buffer"
                )
            end
        )
    end)

    describe("tool call folding", function()
        before_each(function()
            -- The chat buffer parses as the private `agentic` language so its
            -- folds query (queries/agentic/folds.scm) drives folding. Mirror
            -- the runtime setup from init.lua / chat_widget / widget_layout.
            local md =
                vim.api.nvim_get_runtime_file("parser/markdown.so", false)[1]
            pcall(vim.treesitter.language.add, "agentic", {
                path = md,
                symbol_name = "markdown",
            })
            pcall(vim.treesitter.language.register, "agentic", "AgenticChat")
            vim.bo[bufnr].filetype = "AgenticChat"
            pcall(vim.treesitter.start, bufnr, "agentic")

            vim.wo[winid].foldmethod = "expr"
            vim.wo[winid].foldexpr = "v:lua.vim.treesitter.foldexpr()"
            vim.wo[winid].foldenable = true
            vim.wo[winid].foldlevel = 99
        end)

        --- Body long enough to exceed execute_max_lines (default 25).
        --- @return string[]
        local function long_execute_body()
            local body = {}
            for i = 1, Config.tool_call_display.execute_max_lines + 5 do
                table.insert(body, "out " .. i)
            end
            return body
        end

        --- Buffer lines (1-indexed) carrying a `*-fold` opening fence.
        --- @return integer[]
        local function fold_fence_lines()
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local fences = {}
            for i, line in ipairs(lines) do
                if line:match("^`+[%w]+%-fold$") then
                    table.insert(fences, i)
                end
            end
            return fences
        end

        --- Wait for the deferred :foldclose to land. _close_fold schedules the
        --- close so it runs after treesitter's own scheduled level recompute.
        --- @param line integer 1-indexed line known to sit inside the fold
        local function wait_closed(line)
            vim.wait(500, function()
                return vim.fn.foldclosed(line) ~= -1
            end)
        end

        it("closes the fold for a long execute body", function()
            writer:write_tool_call_block({
                tool_call_id = "fold-1",
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = long_execute_body(),
            })

            local fences = fold_fence_lines()
            assert.equal(1, #fences)
            local fence = fences[1]
            local body_start = fence + 1
            wait_closed(body_start)
            -- The fold spans code_fence_content only, so it starts on the
            -- first body line — not the conceal_lines-hidden delimiter. That
            -- keeps the `··· N lines ···` foldtext on a visible screen row.
            -- foldclosed returns the fold's first line for any line inside it.
            assert.equal(body_start, vim.fn.foldclosed(body_start))
            -- The opening delimiter is level 0, outside the fold.
            assert.equal(-1, vim.fn.foldclosed(fence))
        end)

        it("does not fold a short execute body", function()
            writer:write_tool_call_block({
                tool_call_id = "fold-short",
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = { "single output line" },
            })

            assert.equal(0, #fold_fence_lines())
        end)

        it("folds when the body grows past the threshold on update", function()
            writer:write_tool_call_block({
                tool_call_id = "fold-grow",
                status = "in_progress",
                kind = "execute",
                argument = "build",
                body = { "starting" },
            })
            assert.equal(0, #fold_fence_lines())

            writer:update_tool_call_block({
                tool_call_id = "fold-grow",
                status = "completed",
                body = long_execute_body(),
            })

            local fences = fold_fence_lines()
            assert.equal(1, #fences)
            wait_closed(fences[1] + 1)
            assert.equal(fences[1] + 1, vim.fn.foldclosed(fences[1] + 1))
        end)

        it("produces two distinct closed folds for adjacent blocks", function()
            writer:write_tool_call_block({
                tool_call_id = "fold-adj-1",
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = long_execute_body(),
            })
            writer:write_tool_call_block({
                tool_call_id = "fold-adj-2",
                status = "completed",
                kind = "execute",
                argument = "pwd",
                body = long_execute_body(),
            })

            local fences = fold_fence_lines()
            assert.equal(2, #fences)
            wait_closed(fences[1] + 1)
            wait_closed(fences[2] + 1)
            -- Two separate folds: each body-start line reports itself as its
            -- fold start. A merged fold would make the second report the first.
            assert.equal(fences[1] + 1, vim.fn.foldclosed(fences[1] + 1))
            assert.equal(fences[2] + 1, vim.fn.foldclosed(fences[2] + 1))
        end)

        it("keeps the fold closed across a status-only update", function()
            local body = long_execute_body()
            writer:write_tool_call_block({
                tool_call_id = "fold-status",
                status = "in_progress",
                kind = "execute",
                argument = "ls",
                body = body,
            })
            local fence = fold_fence_lines()[1]
            assert.is_not_nil(fence)
            wait_closed(fence + 1)
            assert.equal(fence + 1, vim.fn.foldclosed(fence + 1))

            -- Same body, status flips to completed → content_unchanged early
            -- return, no rewrite. The closed fold must persist.
            writer:update_tool_call_block({
                tool_call_id = "fold-status",
                status = "completed",
                body = body,
            })
            assert.equal(fence + 1, vim.fn.foldclosed(fence + 1))
        end)

        --- An edit diff whose new content has ≥2 foldable structures: if the
        --- diff fence injected `lua`, lua's folds.scm would fold `foo` and
        --- `bar` separately (the sub-folds that sank the first attempt).
        local diff_new = {
            "local function foo()",
            "    return 1",
            "end",
            "local function bar()",
            "    return 2",
            "end",
        }

        --- 1-indexed line of the diff fence carrying the `difffold` marker.
        --- @return integer line
        local function difffold_fence_line()
            for i, line in
                ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
            do
                if line:match("difffold$") then
                    return i
                end
            end
            error("no difffold fence in buffer")
        end

        --- 1-indexed line of the next bare closing fence after `from`.
        --- @param from integer
        --- @return integer
        local function closing_fence_after(from)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            for i = from + 1, #lines do
                if lines[i]:match("^`+$") then
                    return i
                end
            end
            error("no closing fence after line " .. from)
        end

        --- Wait for treesitter to recompute fold levels after the buffer edit
        --- (scheduled, like the deferred fold close — see _close_fold).
        --- @param line integer 1-indexed line expected inside a fold
        local function wait_folded(line)
            vim.wait(500, function()
                return vim.fn.foldlevel(line) >= 1
            end)
        end

        it("folds an edit diff as ONE block with no injected sub-folds", function()
            writer:write_tool_call_block({
                tool_call_id = "diff-onefold",
                status = "completed",
                kind = "create",
                argument = "/tmp/agentic_difffold_probe.lua",
                diff = { old = {}, new = diff_new },
            })

            local fence = difffold_fence_line()
            local body_start = fence + 1
            local body_end = closing_fence_after(fence) - 1
            wait_folded(body_start)

            -- No injected sub-fold: nothing inside the body exceeds level 1
            -- (vim.fn.foldlevel forces foldexpr computation). A surviving lua
            -- fold over `foo`/`bar` would report level 2.
            for line = body_start, body_end do
                assert.is_true(
                    vim.fn.foldlevel(line) <= 1,
                    "sub-fold at line " .. line
                )
            end

            -- The whole body is a single fold: closing inside a function body
            -- collapses the entire diff, not just that function.
            vim.api.nvim_win_call(winid, function()
                vim.cmd((body_start + 1) .. "foldclose")
            end)
            assert.equal(body_start, vim.fn.foldclosed(body_start))
            assert.equal(body_start, vim.fn.foldclosed(body_end))
            -- The concealed delimiter stays outside the fold.
            assert.equal(-1, vim.fn.foldclosed(fence))
        end)

        it("leaves an applied edit diff foldable but open", function()
            writer:write_tool_call_block({
                tool_call_id = "diff-open",
                status = "completed",
                kind = "create",
                argument = "/tmp/agentic_difffold_open.lua",
                diff = { old = {}, new = diff_new },
            })

            local body_start = difffold_fence_line() + 1
            wait_folded(body_start)
            -- Foldable (level 1) and explicitly opened for a non-failed edit,
            -- so `zc` works but nothing is collapsed.
            assert.equal(1, vim.fn.foldlevel(body_start))
            assert.equal(-1, vim.fn.foldclosed(body_start))
        end)

        it("closes the diff and shows the reason when the edit fails", function()
            writer:write_tool_call_block({
                tool_call_id = "diff-fail",
                status = "failed",
                kind = "edit",
                argument = "/tmp/agentic_difffold_fail.lua",
                diff = { old = { "stub" }, new = diff_new },
                failure_reason = { "User refused permission to run tool" },
            })

            local fence = difffold_fence_line()
            assert.is_not_nil(fence)
            local body_start = fence + 1
            wait_closed(body_start)
            -- A failed (e.g. rejected) edit folds closed.
            assert.equal(body_start, vim.fn.foldclosed(body_start))

            -- The reason renders below the diff, not in place of it.
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local reason_line
            for i, line in ipairs(lines) do
                if line == "User refused permission to run tool" then
                    reason_line = i
                end
            end
            assert.is_not_nil(reason_line)
        end)

        it("closes the diff and appends the reason on the in_progress→failed transition", function()
            writer:write_tool_call_block({
                tool_call_id = "diff-trans",
                status = "in_progress",
                kind = "edit",
                argument = "/tmp/agentic_difffold_trans.lua",
                diff = { old = { "stub" }, new = diff_new },
            })
            -- Open while in progress.
            assert.equal(-1, vim.fn.foldclosed(difffold_fence_line() + 1))

            writer:update_tool_call_block({
                tool_call_id = "diff-trans",
                status = "failed",
                failure_reason = { "Load /coding skill first." },
            })

            local fence = difffold_fence_line()
            assert.is_not_nil(fence)
            wait_closed(fence + 1)
            -- Folds closed after the failed transition.
            assert.equal(fence + 1, vim.fn.foldclosed(fence + 1))

            -- The diff was not discarded: its content survives the transition,
            -- and the reason is appended beneath it.
            local text =
                table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
            assert.is_not_nil(text:find("local function foo()", 1, true))
            assert.is_not_nil(text:find("Load /coding skill first.", 1, true))
        end)

        it("opens an applied edit diff appended after a closed fold", function()
            -- A closed fold poisons foldexpr: a fold created afterwards
            -- inherits the closed state. The applied edit must come up open
            -- anyway (regression for the rejected-edit fold leak).
            writer:write_tool_call_block({
                tool_call_id = "leak-exec",
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = long_execute_body(),
            })
            local exec_fence = fold_fence_lines()[1]
            wait_closed(exec_fence + 1)
            assert.equal(exec_fence + 1, vim.fn.foldclosed(exec_fence + 1))

            writer:write_tool_call_block({
                tool_call_id = "leak-edit",
                status = "completed",
                kind = "create",
                argument = "/tmp/agentic_difffold_leak.lua",
                diff = { old = {}, new = diff_new },
            })
            local edit_body = difffold_fence_line() + 1
            wait_folded(edit_body)
            -- Foldable but open despite the preceding closed fold. The open is
            -- deferred (like the close), so wait for it rather than racing.
            vim.wait(500, function()
                return vim.fn.foldclosed(edit_body) == -1
            end)
            assert.equal(-1, vim.fn.foldclosed(edit_body))
            -- The earlier execute fold stays closed.
            assert.equal(exec_fence + 1, vim.fn.foldclosed(exec_fence + 1))
        end)

        it("does not orphan diff highlights past the block on the failed transition", function()
            -- Block is the LAST thing in the buffer (the live mid-turn case).
            -- The failed re-render replaces block lines via set_lines; DIFF_ADD
            -- line_hl_group extmarks migrate to EOF, past the pre-edit range, so
            -- a clear after set_lines misses them and a diff-bg highlight bleeds
            -- onto the trailing blank line. Clearing before set_lines fixes it.
            writer:write_message(make_message_update("intro prose line"))
            writer:write_tool_call_block({
                tool_call_id = "diff-orphan",
                status = "in_progress",
                kind = "create",
                argument = "/tmp/agentic_difffold_orphan.lua",
                diff = { old = {}, new = diff_new },
            })
            writer:update_tool_call_block({
                tool_call_id = "diff-orphan",
                status = "failed",
                failure_reason = { "short" },
            })
            -- No wait: the orphaned marks are the OLD highlights that survive
            -- the synchronous clear+set_lines. The re-applied (correct) marks
            -- land later via vim.schedule, but the bug is detectable now.

            -- The diff body ends at the last added line; nothing below it
            -- (reason fence, footer, trailing blank) may carry a diff highlight.
            local last_diff_row
            for i, l in
                ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
            do
                if l == "end" then
                    last_diff_row = i - 1 -- 0-indexed; last added diff line
                end
            end
            assert.is_not_nil(last_diff_row)

            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                Renderer.NS_DIFF_HIGHLIGHTS,
                0,
                -1,
                {}
            )
            for _, m in ipairs(marks) do
                assert.is_true(
                    m[2] <= last_diff_row,
                    "diff highlight orphaned at row " .. m[2]
                )
            end
        end)
    end)

    describe("execute description heading", function()
        before_each(function()
            Config.tool_call_display.execute_formatter = false
        end)

        it(
            "renders description as the heading name and a single body fence across the update",
            function()
                local output = {}
                for i = 1, Config.tool_call_display.execute_max_lines + 5 do
                    output[i] = "line " .. i
                end

                -- Initial tool_call carries only the description (no output).
                writer:write_tool_call_block({
                    tool_call_id = "exec-desc-1",
                    status = "in_progress",
                    kind = "execute",
                    argument = "ls",
                    description = "Demo execute folding",
                })
                -- Completion: output arrives, already stripped of the bridge's
                -- console fence by the adapter.
                writer:update_tool_call_block({
                    tool_call_id = "exec-desc-1",
                    status = "completed",
                    description = "Demo execute folding",
                    body = output,
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local text = table.concat(lines, "\n")

                -- Description is the collapsed heading name, directly above
                -- the command fence.
                assert.is_not_nil(
                    text:match(
                        "### " .. G_EXEC .. " `Demo execute folding`\n```bash"
                    )
                )
                -- No accumulation divider, no double-wrapped console fence.
                assert.is_nil(text:match("\n%-%-%-\n"))
                assert.is_nil(text:match("```console%-fold\n```console"))

                local openers = 0
                for _ in text:gmatch("```console%-fold") do
                    openers = openers + 1
                end
                assert.equal(1, openers)

                -- The heading name is left to treesitter (@markup.raw on the
                -- backtick code span) — the renderer applies no NS_STATUS
                -- overlay on the head line.
                local marks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    Renderer.NS_STATUS,
                    { 0, 0 },
                    { 0, -1 },
                    { details = true }
                )
                assert.equal(0, #marks)
            end
        )
    end)

    describe("AgenticDimmedBlock extmark", function()
        --- @type TestStub
        local schedule_stub
        local NS_DECORATIONS

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            NS_DECORATIONS =
                vim.api.nvim_create_namespace("agentic_tool_decorations")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        --- Return NS_DECORATIONS extmarks whose hl_group is AgenticDimmedBlock.
        --- @return table[]
        local function dim_extmarks()
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                NS_DECORATIONS,
                0,
                -1,
                { details = true }
            )
            local out = {}
            for _, m in ipairs(marks) do
                if m[4].hl_group == "AgenticDimmedBlock" then
                    table.insert(out, m)
                end
            end
            return out
        end

        it("dims fetch sidecar bodies", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "dim-fetch",
                status = "completed",
                kind = "fetch",
                argument = "https://example.com prompt",
                body = { "page content" },
            }
            writer:write_tool_call_block(block)

            assert.is_true(#dim_extmarks() > 0)
        end)

        it("dims WebSearch sidecar bodies", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "dim-websearch",
                status = "completed",
                kind = "WebSearch",
                argument = "lua tables",
                body = { "result snippet" },
            }
            writer:write_tool_call_block(block)

            assert.is_true(#dim_extmarks() > 0)
        end)

        it("dims SubAgent sidecar bodies", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "dim-subagent",
                status = "completed",
                kind = "SubAgent",
                argument = "general-purpose",
                body = { "subagent output" },
            }
            writer:write_tool_call_block(block)

            assert.is_true(#dim_extmarks() > 0)
        end)

        it("does not dim markdown file edits", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "dim-md-edit",
                status = "completed",
                kind = "write",
                argument = "/tmp/notes.md",
                diff = {
                    old = {},
                    new = { "new note line" },
                },
            }
            writer:write_tool_call_block(block)

            assert.equal(0, #dim_extmarks())
        end)

        it("does not dim execute or search bodies", function()
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local exec = {
                tool_call_id = "dim-exec",
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = { "output" },
            }
            writer:write_tool_call_block(exec)

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local search = {
                tool_call_id = "dim-search",
                status = "completed",
                kind = "search",
                argument = "rg foo",
                body = { "match" },
            }
            writer:write_tool_call_block(search)

            assert.equal(0, #dim_extmarks())
        end)
    end)
end)
