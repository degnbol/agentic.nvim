--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Deferred = require("tests.helpers.deferred")
local MiniTest = require("mini.test")
local Config = require("agentic.config")
local Folds = require("agentic.ui.folds")
local Glyphs = require("agentic.glyphs")
local Renderer = require("agentic.ui.tool_call_renderer")
local Theme = require("agentic.theme")

-- Collapsed tool-call heading glyphs.
local G_EXEC = Glyphs.KIND.execute

describe("agentic.ui.MessageWriter", function()
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type number
    local bufnr
    --- @type number
    local winid
    --- @type agentic.ui.MessageWriter
    local writer

    --- @type agentic.UserConfig.Follow|nil
    local original_follow
    local original_tool_call_display
    local original_windows

    before_each(function()
        -- Re-acquire in case a prior test replaced the module in package.loaded
        Config = require("agentic.config")
        original_follow = Config.follow
        original_tool_call_display = vim.deepcopy(Config.tool_call_display)
        original_windows = vim.deepcopy(Config.windows)
        -- Disable external formatter for deterministic fallback tests
        Config.tool_call_display.execute_formatter = false
        -- No hard wrap unless a spec sets a width.
        Config.windows.wrap_width = 0
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
        Config.follow = original_follow --- @diagnostic disable-line: assign-type-mismatch
        Config.tool_call_display = original_tool_call_display
        Config.windows = original_windows
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

    --- @param text string
    --- @return agentic.acp.SessionUpdateMessage
    local function make_thought_update(text)
        return {
            sessionUpdate = "agent_thought_chunk",
            content = { type = "text", text = text },
        }
    end

    --- @param id string
    --- @param status agentic.ui.ToolCallStatus
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

    --- Parse the buffer as the chat does, and show it at the chat's
    --- 'conceallevel', so fence rows are zero height.
    local function as_chat()
        -- As bootstrap.lua registers it.
        vim.treesitter.language.add("agentic", {
            path = vim.api.nvim_get_runtime_file("parser/markdown.so", false)[1],
            symbol_name = "markdown",
        })
        vim.treesitter.language.register("agentic", "AgenticChat")
        vim.bo[bufnr].filetype = "AgenticChat"
        vim.wo[winid].conceallevel = 2
    end

    --- Every decoration sign in traversal order, `{ row, sign_text }` each.
    --- @return table[]
    local function rail()
        local marks = vim.api.nvim_buf_get_extmarks(
            bufnr,
            Renderer.NS_DECORATIONS,
            0,
            -1,
            { details = true }
        )
        local out = {}
        for _, mark in ipairs(marks) do
            if mark[4].sign_text then
                table.insert(out, { mark[2], mark[4].sign_text })
            end
        end
        return out
    end

    --- 0-indexed rows the dim extmarks cover, `{ start, end }` each, `end`
    --- exclusive.
    --- @return table[]
    local function dim_ranges()
        local marks = vim.api.nvim_buf_get_extmarks(
            bufnr,
            Renderer.NS_DECORATIONS,
            0,
            -1,
            { details = true }
        )
        local out = {}
        for _, mark in ipairs(marks) do
            if mark[4].hl_group == "AgenticDimmedBlock" then
                table.insert(out, { mark[2], mark[4].end_row })
            end
        end
        return out
    end

    --- 1-indexed row whose decoration sign is `glyph`, i.e. the opening row of
    --- the region that glyph identifies.
    --- @param glyph string
    --- @return integer|nil
    local function glyph_sign_row(glyph)
        for _, mark in ipairs(rail()) do
            if mark[2] == glyph .. " " then
                return mark[1] + 1
            end
        end
        return nil
    end

    --- 1-indexed row of the first line equal to `text`.
    --- @param text string
    --- @return integer|nil
    local function row_of(text)
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        for i, line in ipairs(lines) do
            if line == text then
                return i
            end
        end
        return nil
    end

    --- One sign per row is the whole premise of the gutter: the chat window is
    --- `signcolumn=yes:1`, so a second sign on a row is silently dropped and the
    --- loser is decided by namespace id. Asserts no row carries two, across both
    --- namespaces that place signs.
    local function assert_one_sign_per_row()
        local seen = {}
        for _, ns in ipairs({
            Renderer.NS_DECORATIONS,
            MessageWriter.NS_USER_ACTIONS,
        }) do
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                ns,
                0,
                -1,
                { details = true }
            )
            for _, mark in ipairs(marks) do
                if mark[4].sign_text then
                    assert.is_nil(seen[mark[2]])
                    seen[mark[2]] = mark[4].sign_text
                end
            end
        end
    end

    describe("range parse of a tool call block", function()
        --- Writes a completed tool call block and counts the `parse` calls
        --- the write runs that process injections: those with a row range
        --- or `true`.
        --- @return integer
        local function n_range_parses()
            local parser = vim.treesitter.get_parser(bufnr) --[[@as vim.treesitter.LanguageTree]]
            local parse = spy.on(parser, "parse")
            MiniTest.finally(function()
                parse:revert()
            end)
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            return #vim.tbl_filter(function(call)
                return call[2] ~= nil and call[2] ~= false
            end, parse.calls)
        end

        it("runs in a buffer a window shows", function()
            as_chat()

            assert.is_true(n_range_parses() > 0)
        end)

        it("is skipped in a buffer no window shows", function()
            as_chat()
            vim.api.nvim_win_close(winid, true)

            assert.equal(0, n_range_parses())
        end)
    end)

    describe("wrap_width", function()
        local PARAGRAPH = string.rep("word ", 30) .. "end"

        --- @return string[]
        local function write_paragraph()
            writer:write_message(make_message_update(PARAGRAPH))
            return vim.tbl_filter(function(line)
                return line ~= ""
            end, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
        end

        it("wraps prose at wrap_width whatever the window width", function()
            Config.windows.wrap_width = 40
            vim.api.nvim_win_set_width(winid, 20)

            local rows = write_paragraph()

            assert.is_true(#rows > 1)
            for _, row in ipairs(rows) do
                assert.is_true(#row <= 40)
            end
            assert.is_true(#rows[1] > 20)
        end)

        it("leaves a paragraph on one row at 0", function()
            assert.same({ PARAGRAPH }, write_paragraph())
        end)

        describe("while streaming code", function()
            local CODE = "local x = " .. string.rep("a", 60)

            before_each(function()
                as_chat()
                Config.windows.wrap_width = 40
            end)

            it("keeps a code row in an open fence on one row", function()
                writer:write_message_chunk(make_message_update("```lua\n"))
                writer:write_message_chunk(make_message_update(CODE))

                assert.is_not_nil(row_of(CODE))
            end)

            it(
                "keeps a code row reflowed from inside a list item's fence",
                function()
                    -- The blank inside the fence moves the reflow start past the
                    -- 4-indented opener, so the next reflow sees no opener.
                    for _, chunk in ipairs({
                        "- a\n\n",
                        "  - b\n\n",
                        "    para\n\n",
                        "    ```lua\n",
                        "    x\n\n",
                        "    " .. CODE .. "\n\n",
                        "    ```\n\n",
                    }) do
                        writer:write_message_chunk(make_message_update(chunk))
                    end
                    writer:finalize_turn()

                    assert.is_not_nil(row_of("    " .. CODE))
                end
            )
        end)
    end)

    describe("end_runs", function()
        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        it("opens the next prose on its own paragraph", function()
            writer:write_message_chunk(make_message_update("one"))
            writer:end_runs()
            writer:write_message_chunk(make_message_update("two"))

            assert.same({ "one", "", "two" }, buffer_lines())
        end)

        --- The buffer after prose, then `write_next`, with or without
        --- `end_runs` between the two.
        --- @param write_next fun()
        --- @param ended boolean
        --- @return string[]
        local function lines_after(write_next, ended)
            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
            writer:reset()
            writer:write_message_chunk(make_message_update("one"))
            if ended then
                writer:end_runs()
            end
            write_next()
            return buffer_lines()
        end

        for name, write_next in pairs({
            heading = function()
                writer:write_subagent_heading("B")
                writer:write_message_chunk(make_message_update("two"))
            end,
            ["tool call"] = function()
                writer:write_tool_call_block(
                    make_tool_call_block("t1", "completed")
                )
            end,
            ["thought run"] = function()
                writer:write_message_chunk(make_thought_update("hmm"))
                writer:write_message_chunk(make_message_update("two"))
            end,
            ["turn end"] = function()
                writer:finalize_turn()
            end,
        }) do
            it("leaves the spacing before a " .. name .. " as it is", function()
                assert.same(
                    lines_after(write_next, false),
                    lines_after(write_next, true)
                )
            end)
        end

        it("writes nothing when no run is open", function()
            writer:write_message_chunk(make_message_update("prose"))
            writer:end_runs()
            local after_first = buffer_lines()

            writer:end_runs()
            assert.same(after_first, buffer_lines())
        end)
    end)

    describe("prose cursor", function()
        --- Each cursor mark as `{ row, col }`.
        --- @return integer[][]
        local function cursors()
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                vim.api.nvim_get_namespaces().agentic_prose_cursor,
                0,
                -1,
                { details = true }
            )
            return vim.tbl_map(function(mark)
                assert.equal(Glyphs.PROSE_CURSOR, mark[4].virt_text[1][1])
                return { mark[2], mark[3] }
            end, marks)
        end

        --- @param text string
        local function stream(text)
            writer:write_message_chunk(make_message_update(text), nil, true)
        end

        it("shows at the end of live prose", function()
            stream("one\n\ntw")

            assert.same({ { 2, 2 } }, cursors())
        end)

        it("follows each chunk", function()
            stream("one")
            stream(" two")

            assert.same({ { 0, 7 } }, cursors())
        end)

        it("does not show for prose that is not live", function()
            writer:write_message_chunk(make_message_update("one"))

            assert.same({}, cursors())
        end)

        it("goes with a chunk that is not live", function()
            stream("one")

            writer:write_message_chunk(make_message_update(" two"))

            assert.same({}, cursors())
        end)

        it("goes when thinking follows the prose", function()
            stream("one")

            writer:write_message_chunk(make_thought_update("hmm"), nil, true)

            assert.same({}, cursors())
        end)

        for name, write_next in pairs({
            ["tool call"] = function()
                writer:write_tool_call_block(
                    make_tool_call_block("t1", "completed")
                )
            end,
            ["turn end"] = function()
                writer:finalize_turn()
            end,
            reset = function()
                writer:reset()
            end,
            ["turn state reset"] = function()
                writer:reset_turn_state()
            end,
            hide = function()
                writer:hide_prose_cursor()
            end,
        }) do
            it("goes at a " .. name, function()
                stream("one")

                write_next()

                assert.same({}, cursors())
            end)
        end

        it("counts its column in the hard wrap", function()
            Config.windows.wrap_width = 10

            stream("aaaa bbbbb")

            assert.same(
                { "aaaa", "bbbbb" },
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
        end)

        it("leaves a full row of prose that is not live", function()
            Config.windows.wrap_width = 10

            writer:write_message_chunk(make_message_update("aaaa bbbbb"))

            assert.same(
                { "aaaa bbbbb" },
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
        end)
    end)

    describe("fence balancing", function()
        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        --- 1-indexed positions of backtick-only lines.
        local function fence_rows()
            local rows = {}
            for i, line in ipairs(buffer_lines()) do
                if line:match("^`+$") then
                    table.insert(rows, i)
                end
            end
            return rows
        end

        it("closes an unclosed streamed fence at the turn boundary", function()
            writer:write_message_chunk(
                make_message_update("here:\n\n```lua\nx = 1\n")
            )
            writer:finalize_turn()

            assert.same(
                { "here:", "", "```lua", "x = 1", "", "```", "" },
                buffer_lines()
            )
        end)

        it("appends nothing when the streamed fence is balanced", function()
            writer:write_message_chunk(
                make_message_update("```lua\nx = 1\n```\n")
            )
            writer:finalize_turn()

            assert.same({ 3 }, fence_rows())
        end)

        it("matches the width of a wide opener", function()
            writer:write_message_chunk(make_message_update("````md\n```lua\n"))
            writer:finalize_turn()

            assert.is_true(vim.tbl_contains(buffer_lines(), "````"))
        end)

        it(
            "closes the fence before a tool call block written after prose",
            function()
                writer:write_message_chunk(
                    make_message_update("running:\n\n```bash\nls\n")
                )
                writer:write_tool_call_block(
                    make_tool_call_block("t1", "completed")
                )

                local lines = buffer_lines()
                -- The kind identity is a sign on the head row, so the head is
                -- located by its glyph in the gutter rather than in the text.
                local heading = glyph_sign_row(G_EXEC)
                assert.is_true(heading ~= nil)
                local closer = fence_rows()[1]
                assert.equal("```", lines[closer])
                assert.is_true(closer < heading)
            end
        )

        it("closes a fence that spans a blank line", function()
            -- A blank line inside the fence must not advance the reflow marker
            -- into the fence, or the flush would see a balanced region.
            writer:write_message_chunk(
                make_message_update("```lua\n\nx = 1\n\n")
            )
            writer:finalize_turn()

            assert.same(
                { "```lua", "", "x = 1", "", "", "```", "" },
                buffer_lines()
            )
        end)

        it("closes the fence before an error block", function()
            writer:write_message_chunk(
                make_message_update("here:\n\n```lua\nx = 1\n")
            )
            writer:write_error_message({ code = -32603, message = "boom" })

            local lines = buffer_lines()
            local closer = fence_rows()[1]
            local heading = vim.fn.index(lines, "## Error") + 1
            assert.is_true(heading > 0)
            assert.is_true(closer < heading)
        end)

        it("closes an unclosed fence in a full message", function()
            writer:write_message(make_message_update("intro\n\n```lua\nx = 1"))

            assert.same(
                { "intro", "", "```lua", "x = 1", "```", "" },
                buffer_lines()
            )
        end)

        it("closes a prompt fence inside the prompt region", function()
            as_chat()
            writer:write_user_prompt("look at\n```lua\nx = 1")

            local lines = buffer_lines()
            local fence = fence_rows()[1]
            assert.equal("```", lines[fence])
            -- ╰─ stops on the last *visible* row. The closer below it is
            -- concealed to zero height, so a corner there would never be drawn.
            local footer = rail()[#rail()]
            assert.equal("╰─", footer[2])
            assert.equal("x = 1", lines[footer[1] + 1])
        end)
    end)

    describe("write_user_prompt", function()
        --- 0-indexed rows carrying a prompt marker, traversal order.
        local function marker_rows()
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                MessageWriter.NS_USER_ACTIONS,
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

        --- Sign text of the first prompt marker in the buffer.
        local function marker_sign()
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                MessageWriter.NS_USER_ACTIONS,
                0,
                -1,
                { details = true }
            )
            return marks[1] and marks[1][4].sign_text
        end

        it("marks a prose prompt with the prompt marker", function()
            writer:write_user_prompt("Hello there")

            assert.equal("❯ ", marker_sign())
        end)

        it("marks a forwarded command with its own glyph", function()
            writer:write_user_prompt("/compact")

            assert.equal(Glyphs.COMMAND.compact .. " ", marker_sign())
        end)

        it("marks a command carrying an argument", function()
            writer:write_user_prompt("/compact focus on the parser")

            assert.equal(Glyphs.COMMAND.compact .. " ", marker_sign())
        end)

        it("marks an authored prompt with its author's glyph", function()
            writer:write_user_prompt("/compact", nil, "skeptic")

            assert.equal(Glyphs.AUTHOR.skeptic .. " ", marker_sign())
        end)

        it("falls back for a command word with no glyph", function()
            writer:write_user_prompt("/vendor-specific-thing")

            assert.equal(Glyphs.COMMAND_DEFAULT .. " ", marker_sign())
        end)

        -- The escape hatch `PromptBlocks.command` documents: an indented
        -- `/word` is prose, and must not take a command's identity.
        it("marks an indented slash line as prose", function()
            writer:write_user_prompt("  /compact")

            assert.equal("❯ ", marker_sign())
        end)

        it(
            "marks the heading row when writing into a non-empty buffer",
            function()
                writer:write_message(make_message_update("prior agent prose"))
                local before = vim.api.nvim_buf_line_count(bufnr)

                writer:write_user_prompt("Hello there")

                assert.same({ before }, marker_rows())
                assert.equal("## Hello there", line_at(before))
            end
        )

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

        it("writes no separator line", function()
            writer:write_user_prompt("Hello there")

            assert.is_false(
                vim.tbl_contains(
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                    "---"
                )
            )
        end)

        it("leaves a single-line prompt with the marker alone", function()
            writer:write_user_prompt("Hello there")

            assert.same({}, rail())
        end)

        it("brackets a multi-line prompt down to its last row", function()
            writer:write_user_prompt("Hello there\nsecond\nthird")

            assert.same({ { 1, "│ " }, { 2, "╰─" } }, rail())
            assert.equal("third", line_at(2))
            -- The rail must stay out of NS_USER_ACTIONS or [[/]] would stop on
            -- prompt body rows.
            assert.same({ 0 }, marker_rows())
            assert_one_sign_per_row()
        end)

        it("ends the rail above a trailing extra_lines fence", function()
            -- The selected-code path: session_manager appends a fenced snippet,
            -- so the region's last buffer row is a closing ```. That row is
            -- concealed to zero height, so ╰─ has to sit on the last visible one.
            as_chat()
            writer:write_user_prompt("check this", {
                "```lua",
                "x = 1",
                "```",
            })

            local footer = rail()[#rail()]
            assert.equal("╰─", footer[2])
            assert.equal("x = 1", line_at(footer[1]))
            assert_one_sign_per_row()
        end)
    end)

    describe("write_notice", function()
        local GLYPH = Glyphs.COMMAND.grant

        before_each(function()
            Config.windows.wrap_width = 58
        end)

        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        --- Marks in the user-action namespace as { row, sign_text, sign_hl }.
        local function action_marks()
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                MessageWriter.NS_USER_ACTIONS,
                0,
                -1,
                { details = true }
            )
            local out = {}
            for _, mark in ipairs(marks) do
                table.insert(out, {
                    mark[2],
                    mark[4].sign_text,
                    mark[4].sign_hl_group,
                })
            end
            return out
        end

        it(
            "writes the title as a heading with the glyph in the gutter",
            function()
                writer:write_notice({ glyph = GLYPH, title = "repo" })

                assert.same({ "## repo", "" }, buffer_lines())
                assert.same(
                    { { 0, GLYPH .. " ", Theme.HL_GROUPS.GLYPH_USER } },
                    action_marks()
                )
            end
        )

        it("appends body lines verbatim and a trailing blank", function()
            writer:write_notice({
                glyph = Glyphs.COMMAND.context,
                title = "72.4k / 200k · 36%",
                body = { "- Cost: $0.0412 USD" },
            })

            assert.same({
                "## 72.4k / 200k · 36%",
                "- Cost: $0.0412 USD",
                "",
            }, buffer_lines())

            -- The body row closes the notice's region; the trailing blank is a
            -- separator and belongs to no region.
            assert.same({ { 1, "╰─" } }, rail())
            assert_one_sign_per_row()
        end)

        describe("fold body", function()
            it("writes no region when empty", function()
                writer:write_notice({
                    glyph = GLYPH,
                    title = "t",
                    detail = "path",
                    fold_body = {},
                })

                assert.same({ "## t", "path", "" }, buffer_lines())
                assert.same({ { 1, "╰─" } }, rail())
                assert.same({}, writer._pending_fold_ops)
            end)

            it("fences one line without a fold", function()
                writer:write_notice({
                    glyph = GLYPH,
                    title = "t",
                    fold_body = { "```lua" },
                    id = "m1",
                })

                -- The fence outruns the backticks in the body, so the body's
                -- opener cannot swallow what follows.
                assert.same(
                    { "## t", "````markdown-fold", "```lua", "````", "" },
                    buffer_lines()
                )
                assert.same({}, writer._pending_fold_ops)
                assert.equal("m1", writer:notice_at(2))
            end)

            it("folds a longer body closed", function()
                as_chat()
                writer:write_notice({
                    glyph = GLYPH,
                    title = "t",
                    detail = "path",
                    fold_body = { "one", "two" },
                    id = "m1",
                })

                assert.same({
                    "## t",
                    "path",
                    "```markdown-fold",
                    "one",
                    "two",
                    "```",
                    "",
                }, buffer_lines())
                assert.equal(1, #writer._pending_fold_ops)
                assert.is_false(writer._pending_fold_ops[1].open)
                -- The fold is anchored on its first body row, not the fence.
                assert.equal(
                    3,
                    vim.api.nvim_buf_get_extmark_by_id(
                        bufnr,
                        vim.api.nvim_create_namespace("agentic_fold_anchors"),
                        writer._pending_fold_ops[1].id,
                        {}
                    )[1]
                )
                assert.same({
                    { 1, "│ " },
                    { 2, "│ " },
                    { 3, "│ " },
                    { 4, "╰─" },
                }, rail())
                assert.equal("m1", writer:notice_at(5))
                assert.is_nil(writer:notice_at(6))
            end)
        end)

        it("leaves a heading-only notice unbracketed", function()
            writer:write_notice({ glyph = GLYPH, title = "repo" })

            assert.same({}, rail())
        end)

        it("honours an explicit glyph highlight", function()
            writer:write_notice({
                glyph = GLYPH,
                glyph_hl = Theme.HL_GROUPS.GLYPH_OFF,
                title = "grant cleared",
            })

            assert.equal(Theme.HL_GROUPS.GLYPH_OFF, action_marks()[1][3])
        end)

        it("keeps a title wider than wrap_width on one heading row", function()
            Config.windows.wrap_width = 28
            local title = string.rep("wide ", 6) .. "tail"

            writer:write_notice({ glyph = GLYPH, title = title })

            assert.same({ "## " .. title, "" }, buffer_lines())
            assert.same(
                { { 0, GLYPH .. " ", Theme.HL_GROUPS.GLYPH_USER } },
                action_marks()
            )
        end)

        it("keeps ## and no turn boundary mid-turn", function()
            writer:write_message_chunk(make_message_update("streaming prose"))

            writer:write_notice({
                glyph = GLYPH,
                title = "repo",
                mid_turn = true,
            })

            assert.same(
                { "streaming prose", "", "## repo" },
                vim.list_slice(buffer_lines(), 1, 3)
            )
            -- The heading closed the section itself, so resumed prose gets no
            -- `###` boundary line.
            writer:write_message_chunk(make_message_update("resumed prose"))
            assert.is_false(vim.tbl_contains(buffer_lines(), "###"))
        end)

        it("closes the turn when written between turns", function()
            writer:write_message_chunk(make_message_update("prior prose"))
            writer._pending_section_break = true

            writer:write_notice({ glyph = GLYPH, title = "repo" })

            assert.same({ "prior prose", "", "## repo", "" }, buffer_lines())
            assert.is_false(writer._pending_section_break)
        end)

        it("a notice with an id keeps its row as lines go in above", function()
            writer:write_notice({ glyph = GLYPH, title = "first" })
            writer:write_notice({ glyph = GLYPH, title = "second", id = "m1" })
            assert.equal(
                "## second",
                buffer_lines()[writer:notice_row("m1") + 1]
            )

            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "a", "b" })

            assert.equal(
                "## second",
                buffer_lines()[writer:notice_row("m1") + 1]
            )
            assert.is_nil(writer:notice_row("m2"))
        end)

        it("notice_at names the notice under a heading or body row", function()
            writer:write_notice({ glyph = GLYPH, title = "plain" })
            writer:write_notice({
                glyph = GLYPH,
                title = "linked",
                body = { "one", "two" },
                id = "m1",
            })
            writer:write_notice({ glyph = GLYPH, title = "after" })

            local lines = buffer_lines()
            local function row0_of(text)
                for i, line in ipairs(lines) do
                    if line == text then
                        return i - 1
                    end
                end
            end
            assert.equal("m1", writer:notice_at(row0_of("## linked")))
            assert.equal("m1", writer:notice_at(row0_of("two")))
            assert.is_nil(writer:notice_at(row0_of("## plain")))
            assert.is_nil(writer:notice_at(row0_of("## after")))
        end)

        it("reset forgets the ids", function()
            writer:write_notice({ glyph = GLYPH, title = "linked", id = "m1" })

            writer:reset()

            assert.is_nil(writer:notice_row("m1"))
            assert.is_nil(writer:notice_at(0))
        end)
    end)

    describe("thought runs", function()
        local G_THINK = Glyphs.THINKING_SIGN

        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        it("writes nothing until the run ends", function()
            writer:write_message_chunk(make_thought_update("half a thought"))

            assert.same({ "" }, buffer_lines())
            assert.same({}, rail())
        end)

        it("renders the run as a folded, glyph-signed block", function()
            writer:write_message_chunk(
                make_thought_update("first thought\nsecond thought")
            )
            writer:write_message_chunk(make_message_update("the answer"))

            assert.same({
                "```markdown-fold",
                "first thought",
                "second thought",
                "```",
                "",
                "the answer",
            }, buffer_lines())
            -- The glyph opens on the first body row — the row a closed fold
            -- shows — and the rail closes above the concealed fence.
            assert.same({ { 1, G_THINK }, { 2, "╰─" } }, rail())
            assert.same({ { 1, 3 } }, dim_ranges())
            assert_one_sign_per_row()
        end)

        it("widens the fence past backticks in the thinking", function()
            writer:write_message_chunk(
                make_thought_update("try:\n```lua\nx = 1\n```\nno")
            )
            writer:finalize_turn()

            assert.equal("````markdown-fold", buffer_lines()[1])
        end)

        it("leaves a one-line run unfenced under the glyph", function()
            -- Vim cannot close a one-line fold, and a visible ``` around a
            -- single line is worse than the line.
            writer:write_message_chunk(make_thought_update("brief"))
            writer:finalize_turn()

            assert.equal("brief", buffer_lines()[1])
            assert.same({ { 0, G_THINK } }, rail())
        end)

        it("keeps two runs separated by a tool call apart", function()
            writer:write_message_chunk(make_thought_update("one\ntwo"))
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:write_message_chunk(make_thought_update("three\nfour"))
            writer:finalize_turn()

            local markers = {}
            for _, mark in ipairs(rail()) do
                if mark[2] == G_THINK then
                    table.insert(markers, mark[1])
                end
            end
            assert.equal(2, #markers)
            assert.equal("one", buffer_lines()[markers[1] + 1])
            assert.equal("three", buffer_lines()[markers[2] + 1])
        end)

        it("places the run above a whole stored message", function()
            -- Replay writes stored agent prose through write_message, and
            -- stores thoughts as separate entries.
            writer:write_message_chunk(make_thought_update("stored\nthinking"))
            writer:write_message(make_message_update("stored answer"))

            local lines = buffer_lines()
            assert.equal("stored", lines[2])
            assert.equal("stored answer", lines[6])
        end)

        it("writes nothing for a whitespace-only run", function()
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            local before = #buffer_lines()

            writer:write_message_chunk(make_thought_update("  \n\n "))

            assert.equal(before, #buffer_lines())
            -- The boundary belongs to whatever writes next; an empty run must
            -- not consume it.
            assert.is_true(writer._pending_section_break)
        end)

        it("places the run above the prompt that interrupts it", function()
            writer:write_message_chunk(make_thought_update("mid\nthought"))
            writer:write_user_prompt("actually, stop")

            local lines = buffer_lines()
            assert.equal("mid", lines[2])
            assert.equal("## actually, stop", lines[6])
        end)

        it("places the run above an error that ends the turn", function()
            writer:write_message_chunk(make_thought_update("mid\nthought"))
            writer:write_error_message({ code = 1, message = "boom" })

            local lines = buffer_lines()
            assert.equal("mid", lines[2])
            assert.equal("## Error", lines[6])
        end)

        it("flushes at end_runs", function()
            writer:write_message_chunk(make_thought_update("task a\nthinking"))
            writer:end_runs()

            local lines = buffer_lines()
            assert.equal("task a", lines[2])
        end)

        it("flushes before a mid-turn notice", function()
            writer:write_message_chunk(make_thought_update("mid\nthought"))
            writer:write_notice({
                glyph = Glyphs.COMMAND.grant,
                title = "repo",
                mid_turn = true,
            })

            local lines = buffer_lines()
            assert.equal("mid", lines[2])
            assert.equal("## repo", lines[6])
        end)

        it("closes the interrupted tool call's section", function()
            -- A fence inside the tool call's `###` section would keep the
            -- breadcrumb on the tool call for as long as the run is on screen.
            -- The description keeps the tool head off `###`, so a bare one is
            -- unambiguously the boundary.
            local block = make_tool_call_block("t1", "completed")
            block.description = "list the directory"
            writer:write_tool_call_block(block)
            writer:write_message_chunk(make_thought_update("now\nwhat"))
            writer:write_message_chunk(make_message_update("and the answer"))
            writer:finalize_turn()

            local lines = buffer_lines()
            local fence_row, boundaries = nil, 0
            for i, line in ipairs(lines) do
                if line == "```markdown-fold" then
                    fence_row = i
                elseif line == "###" then
                    boundaries = boundaries + 1
                end
            end
            assert.equal("###", lines[fence_row - 2])
            -- Exactly one: the run consumed the pending break, so the prose
            -- after it must not emit a second.
            assert.equal(1, boundaries)
        end)
    end)

    describe("hook blocks", function()
        local G_HOOK = Glyphs.HOOK .. " "

        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        local TITLE = "`guard.sh` · 30 ms"

        --- 0-indexed rows marked in `ns`.
        --- @param ns integer
        --- @return integer[]
        local function marked_rows(ns)
            return vim.tbl_map(function(mark)
                return mark[2]
            end, vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {}))
        end

        it("leads the region with its title, in a bare fence", function()
            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
            })

            assert.same({
                "```markdown-fold",
                TITLE,
                "injected",
                "context",
                "```",
                "",
            }, buffer_lines())
            assert.same(
                { { 1, G_HOOK }, { 2, "│ " }, { 3, "╰─" } },
                rail()
            )
            assert_one_sign_per_row()
        end)

        it("wraps the body but not the title", function()
            local title = "`/hooks/a-very-long-hook-name.sh` · 61 ms"
            Config.windows.wrap_width = 20
            writer:write_hook_block({
                body = { "one two three four five six seven" },
                title = title,
            })

            local lines = buffer_lines()
            assert.equal(title, lines[2])
            -- Fence, title, at least two body rows, fence, blank.
            assert.is_true(#lines >= 6)
            for i = 3, #lines - 2 do
                assert.is_true(vim.fn.strdisplaywidth(lines[i]) <= 20)
            end
        end)

        it("marks a folded titled region's fence for the foldtext", function()
            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
            })

            assert.same({ 0 }, marked_rows(Folds.NS_TITLED))
        end)

        it("leaves an untitled region's fence unmarked", function()
            writer:write_hook_block({ body = { "injected", "context" } })

            assert.equal("```markdown-fold", buffer_lines()[1])
            assert.same({}, marked_rows(Folds.NS_TITLED))
        end)

        it("leaves a one-line body unfenced under the glyph", function()
            writer:write_hook_block({ body = { "brief" } })

            assert.equal("brief", buffer_lines()[1])
            assert.same({ { 0, G_HOOK } }, rail())
        end)

        it("leaves a titled one-row body open", function()
            writer:write_hook_block({ body = { "brief" }, title = TITLE })

            assert.same(
                { TITLE, "brief" },
                vim.list_slice(buffer_lines(), 2, 3)
            )
            assert.equal(1, #writer._pending_fold_ops)
            assert.is_true(writer._pending_fold_ops[1].open)
        end)

        it("marks a failed block with the failed glyph", function()
            writer:write_hook_block({
                body = { "exited 127", "command not found" },
                title = TITLE,
                failed = true,
            })

            assert.same({
                { 1, Glyphs.HOOK_FAILED .. " " },
                { 2, "│ " },
                { 3, "╰─" },
            }, rail())
        end)

        it("closes a block that did not fail", function()
            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
            })

            assert.equal(1, #writer._pending_fold_ops)
            assert.is_false(writer._pending_fold_ops[1].open)
        end)

        it("leaves a block for the user open and undimmed", function()
            writer:write_hook_block({
                body = { "a message", "for you" },
                title = TITLE,
                for_user = true,
            })

            assert.equal(1, #writer._pending_fold_ops)
            assert.is_true(writer._pending_fold_ops[1].open)
            for _, mark in
                ipairs(
                    vim.api.nvim_buf_get_extmarks(
                        bufnr,
                        Renderer.NS_DECORATIONS,
                        0,
                        -1,
                        { details = true }
                    )
                )
            do
                assert.is_true(mark[4].hl_group ~= Theme.HL_GROUPS.DIMMED_BLOCK)
            end
        end)

        it("writes nothing for an empty body, even with a title", function()
            writer:write_hook_block({ body = {}, title = TITLE })

            assert.same({ "" }, buffer_lines())
            assert.same({}, rail())
        end)

        it("flushes a buffered thought run ahead of itself", function()
            writer:write_message_chunk(make_thought_update("one\ntwo"))
            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
            })

            local lines = buffer_lines()
            assert.equal("one", lines[2])
            assert.equal(TITLE, lines[7])
        end)

        --- A completed tool call followed by a two-paragraph prose run, so an
        --- anchored region has content both above and below it.
        local function call_then_prose()
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:write_message_chunk(
                make_message_update("after the call\n\nand more of it\n")
            )
        end

        it("places a record under the call it fired on", function()
            call_then_prose()

            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
                tool_call_id = "t1",
            })

            local title = row_of(TITLE)
            assert.is_not_nil(title)
            assert.is_true(title < row_of("after the call"))
            -- The region belongs to the call: no `###` closes its section
            -- above the region.
            local lines = buffer_lines()
            assert.equal("```markdown-fold", lines[title - 1])
            assert.equal("", lines[title - 2])
            assert.is_not_nil(lines[title - 3]:find("completed", 1, true))
            assert_one_sign_per_row()
        end)

        it("opens the pending section break when it appends", function()
            local block = make_tool_call_block("t1", "completed")
            block.description = "list the directory"
            writer:write_tool_call_block(block)

            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
            })

            local title = row_of(TITLE)
            assert.equal("###", buffer_lines()[title - 3])
        end)

        it("appends when no block carries the id", function()
            call_then_prose()

            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
                tool_call_id = "t9",
            })

            assert.is_true(row_of(TITLE) > row_of("after the call"))
        end)

        it("appends when the anchor's range has collapsed", function()
            call_then_prose()
            local tracker = writer.tool_call_blocks["t1"]
            vim.api.nvim_buf_set_extmark(
                bufnr,
                Renderer.NS_TOOL_BLOCKS,
                0,
                0,
                { id = tracker.extmark_id, end_row = 0 }
            )

            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
                tool_call_id = "t1",
            })

            assert.is_true(row_of(TITLE) > row_of("after the call"))
        end)

        it("keeps two records on one call in transcript order", function()
            call_then_prose()

            writer:write_hook_block({
                body = { "first", "record" },
                title = "`a.sh`",
                tool_call_id = "t1",
            })
            writer:write_hook_block({
                body = { "second", "record" },
                title = "`b.sh`",
                tool_call_id = "t1",
            })

            local first = row_of("`a.sh`")
            local second = row_of("`b.sh`")
            assert.is_true(first < second)
            assert.is_true(second < row_of("after the call"))
        end)

        it("leaves the section break to the prose after it", function()
            -- The description keeps the tool head off `###`, so a bare one is
            -- unambiguously a section boundary.
            local block = make_tool_call_block("t1", "completed")
            block.description = "list the directory"
            writer:write_tool_call_block(block)

            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
                tool_call_id = "t1",
            })
            writer:write_message_chunk(make_message_update("after the call\n"))

            local boundaries = {}
            for i, line in ipairs(buffer_lines()) do
                if line == "###" then
                    table.insert(boundaries, i)
                end
            end
            assert.equal(1, #boundaries)
            assert.is_true(row_of(TITLE) < boundaries[1])
            assert.is_true(boundaries[1] < row_of("after the call"))
        end)

        it("leaves a newer block's pending break alone", function()
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:write_message_chunk(make_message_update("between\n"))
            writer:write_tool_call_block(
                make_tool_call_block("t2", "completed")
            )

            -- Anchored to the older block, so the break t2 is owed still stands.
            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
                tool_call_id = "t1",
            })

            assert.is_true(writer._pending_section_break)
            assert.is_true(row_of(TITLE) < row_of("between"))
        end)

        it("appends when the anchor's extmark is gone", function()
            call_then_prose()
            vim.api.nvim_buf_del_extmark(
                bufnr,
                Renderer.NS_TOOL_BLOCKS,
                writer.tool_call_blocks["t1"].extmark_id
            )

            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
                tool_call_id = "t1",
            })

            assert.is_true(row_of(TITLE) > row_of("after the call"))
        end)

        it("holds the prose pin on the content it was set on", function()
            call_then_prose()
            local pinned = buffer_lines()[writer._prose_anchor_line + 1]
            assert.equal("after the call", pinned)

            writer:write_hook_block({
                body = { "injected", "context" },
                title = TITLE,
                tool_call_id = "t1",
            })

            assert.equal(pinned, buffer_lines()[writer._prose_anchor_line + 1])
        end)

        it(
            "leaves the run below it bracketed from its own first row",
            function()
                call_then_prose()

                writer:write_hook_block({
                    body = { "injected", "context" },
                    title = TITLE,
                    tool_call_id = "t1",
                })
                writer:finalize_turn()

                local opener
                for _, mark in ipairs(rail()) do
                    if mark[2] == "╭─" then
                        opener = mark[1] + 1
                    end
                end
                assert.equal(row_of("after the call"), opener)
            end
        )
    end)

    describe("discovered skills", function()
        local TITLE = "New skills discovered in sub/.claude/skills:"

        --- @param body string[]
        --- @param tool_call_id string|nil
        --- @return agentic.acp.DiscoveredSkills
        local function skills(body, tool_call_id)
            return { title = TITLE, body = body, tool_call_id = tool_call_id }
        end

        local function call_then_prose()
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:write_message_chunk(make_message_update("after the call\n"))
        end

        it("goes under its call, closed, under the skill sign", function()
            call_then_prose()

            writer:write_discovered_skills(skills({ "- foo", "- bar" }, "t1"))

            local title = row_of(TITLE)
            assert.is_not_nil(title)
            ---@cast title -nil
            assert.is_true(title < row_of("after the call"))
            assert.same(
                { "- foo", "- bar" },
                vim.api.nvim_buf_get_lines(bufnr, title, title + 2, false)
            )
            local sign
            for _, mark in ipairs(rail()) do
                if mark[1] == title - 1 then
                    sign = mark[2]
                end
            end
            assert.equal(Glyphs.KIND.skill .. " ", sign)
            local ops = writer._pending_fold_ops
            assert.is_false(ops[#ops].open)
            assert_one_sign_per_row()
        end)

        it("leaves a region with one name open", function()
            writer:write_discovered_skills(skills({ "- foo" }))

            local ops = writer._pending_fold_ops
            assert.equal(1, #ops)
            assert.is_true(ops[1].open)
        end)

        it("appends when its call is not in the buffer", function()
            call_then_prose()

            writer:write_discovered_skills(skills({ "- foo", "- bar" }, "t9"))

            assert.is_true(row_of(TITLE) > row_of("after the call"))
        end)

        it("goes below a hook region already at its call", function()
            call_then_prose()
            writer:write_hook_block({
                body = { "injected", "context" },
                title = "`guard.sh`",
                tool_call_id = "t1",
            })

            writer:write_discovered_skills(skills({ "- foo", "- bar" }, "t1"))

            assert.is_true(row_of("`guard.sh`") < row_of(TITLE))
            assert.is_true(row_of(TITLE) < row_of("after the call"))
        end)
    end)

    describe("write_folded_row", function()
        it("appends after a buffered thought run, closed", function()
            writer:write_message_chunk(make_thought_update("pondering"))

            writer:write_folded_row("Found it.", { "detail" }, "R")

            assert.is_true(row_of("pondering") < row_of("Found it."))
            assert.same(
                { "Found it.", "detail" },
                vim.api.nvim_buf_get_lines(
                    bufnr,
                    row_of("Found it.") - 1,
                    row_of("Found it.") + 1,
                    false
                )
            )
            local ops = writer._pending_fold_ops
            assert.is_false(ops[#ops].open)
            local sign
            for _, mark in ipairs(rail()) do
                if mark[1] == row_of("Found it.") - 1 then
                    sign = mark[2]
                end
            end
            assert.equal("R ", sign)
            assert_one_sign_per_row()
        end)

        it("writes a lone row without a fold", function()
            writer:write_folded_row("Found it.", {}, "R")

            assert.is_not_nil(row_of("Found it."))
            assert.same({}, writer._pending_fold_ops)
        end)
    end)

    describe("loaded files and anchors", function()
        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        --- The row `write_loaded_file` writes for `path`.
        --- @param path string
        --- @return string
        local function file_row(path)
            return "  `" .. path .. "`"
        end

        --- A completed tool call `t1` followed by prose, so content placed
        --- under the call has content below it.
        local function call_then_prose()
            local block = make_tool_call_block("t1", "completed")
            block.description = "list the directory"
            writer:write_tool_call_block(block)
            writer:write_message_chunk(make_message_update("after the call\n"))
        end

        --- The lines from the tool call's footer to the end of the buffer.
        --- @return string[]
        local function lines_after_footer()
            local lines = buffer_lines()
            for i, line in ipairs(lines) do
                if line:find("completed", 1, true) then
                    return vim.list_slice(lines, i + 1)
                end
            end
            error("no footer")
        end

        it("writes a guarded path under the read glyph", function()
            writer:write_loaded_file({ path = "/repo/a `b`.md" })

            assert.same({ "  ``/repo/a `b`.md``", "" }, buffer_lines())
            assert.same({ { 0, Glyphs.KIND.read .. " " } }, rail())
        end)

        it("keeps two rows under one call contiguous and in order", function()
            call_then_prose()

            writer:write_loaded_file({ path = "/r/a.md", tool_call_id = "t1" })
            writer:write_loaded_file({ path = "/r/b.md", tool_call_id = "t1" })

            assert.same({
                file_row("/r/a.md"),
                file_row("/r/b.md"),
                "",
                "###",
                "",
                "after the call",
                "",
            }, lines_after_footer())
            assert_one_sign_per_row()
        end)

        it("keeps write order across rows and hook regions", function()
            call_then_prose()

            writer:write_loaded_file({ path = "/r/a.md", tool_call_id = "t1" })
            writer:write_hook_block({
                body = { "injected", "context" },
                title = "`guard.sh`",
                tool_call_id = "t1",
            })
            writer:write_loaded_file({ path = "/r/b.md", tool_call_id = "t1" })

            assert.same({
                file_row("/r/a.md"),
                "",
                "```markdown-fold",
                "`guard.sh`",
                "injected",
                "context",
                "```",
                "",
                file_row("/r/b.md"),
                "",
                "###",
                "",
                "after the call",
                "",
            }, lines_after_footer())
        end)

        it("places a prompt's row after it, before the reply", function()
            writer:write_user_prompt("go")
            writer:write_message_chunk(make_message_update("the reply\n"))

            writer:write_loaded_file({ path = "/r/a.md", after_prompt = true })

            assert.same({
                "## go",
                "",
                file_row("/r/a.md"),
                "",
                "the reply",
                "",
            }, buffer_lines())
        end)

        it(
            "keeps a prompt's rows above a reply written between them",
            function()
                writer:write_user_prompt("go")
                writer:write_loaded_file({
                    path = "/r/a.md",
                    after_prompt = true,
                })
                writer:write_message_chunk(make_message_update("the reply\n"))

                writer:write_loaded_file({
                    path = "/r/b.md",
                    after_prompt = true,
                })

                assert.same({
                    "## go",
                    "",
                    file_row("/r/a.md"),
                    file_row("/r/b.md"),
                    "",
                    "the reply",
                    "",
                }, buffer_lines())
            end
        )

        it("places a prompt's hook block after it, then its rows", function()
            writer:write_user_prompt("go")
            writer:write_message_chunk(make_message_update("the reply\n"))

            writer:write_hook_block({
                body = { "remember", "this" },
                title = "UserPromptSubmit",
                after_prompt = true,
            })
            writer:write_loaded_file({ path = "/r/a.md", after_prompt = true })

            assert.same({
                "## go",
                "",
                "```markdown-fold",
                "UserPromptSubmit",
                "remember",
                "this",
                "```",
                "",
                file_row("/r/a.md"),
                "",
                "the reply",
                "",
            }, buffer_lines())
            assert_one_sign_per_row()
        end)

        it(
            "keeps a prompt's reply whole when it streams across a row",
            function()
                writer:write_user_prompt("go")
                writer:write_message_chunk(
                    make_message_update("first para\n\nsec")
                )

                writer:write_loaded_file({
                    path = "/r/a.md",
                    after_prompt = true,
                })
                writer:write_message_chunk(make_message_update("ond para\n"))
                writer:finalize_turn()

                assert.same({
                    "## go",
                    "",
                    file_row("/r/a.md"),
                    "",
                    "first para",
                    "",
                    "second para",
                    "",
                }, buffer_lines())
                assert_one_sign_per_row()
            end
        )

        it("keeps a call's prose whole when it streams across a row", function()
            local block = make_tool_call_block("t1", "completed")
            block.description = "list the directory"
            writer:write_tool_call_block(block)
            writer:write_message_chunk(make_message_update("first para\n\nsec"))

            writer:write_loaded_file({ path = "/r/a.md", tool_call_id = "t1" })
            writer:write_message_chunk(make_message_update("ond para\n"))
            writer:finalize_turn()

            assert.same({
                file_row("/r/a.md"),
                "",
                "###",
                "",
                "first para",
                "",
                "second para",
                "",
            }, lines_after_footer())
            assert_one_sign_per_row()
        end)

        it("opens no section under a prompt", function()
            writer:write_user_prompt("go")

            writer:write_loaded_file({
                path = "/r/a.md",
                after_prompt = true,
                after_compaction = false,
            })

            assert.is_false(vim.tbl_contains(buffer_lines(), "###"))
        end)

        it("anchors to the last prompt only", function()
            writer:write_user_prompt("first")
            writer:write_user_prompt("second")

            writer:write_loaded_file({ path = "/r/a.md", after_prompt = true })

            local lines = buffer_lines()
            assert.equal(file_row("/r/a.md"), lines[#lines - 1])
        end)

        it("places a compaction's files after its block", function()
            local compaction = make_tool_call_block("c-1", "completed")
            compaction.description = "compact"
            compaction.is_compaction = true
            writer:write_tool_call_block(compaction)
            writer:write_message_chunk(make_message_update("resumed\n"))

            writer:write_loaded_file({
                path = "/r/a.lua",
                after_compaction = true,
            })

            assert.same({
                file_row("/r/a.lua"),
                "",
                "###",
                "",
                "resumed",
                "",
            }, lines_after_footer())
        end)

        it("appends a row whose anchor is not in the buffer", function()
            call_then_prose()

            writer:write_loaded_file({ path = "/r/a.md", tool_call_id = "t9" })
            writer:write_loaded_file({ path = "/r/b.md" })

            local lines = buffer_lines()
            assert.same({
                "after the call",
                "",
                file_row("/r/a.md"),
                file_row("/r/b.md"),
                "",
            }, vim.list_slice(lines, #lines - 4))
        end)

        it("starts a new end group once something follows the last", function()
            writer:write_loaded_file({ path = "/r/a.md" })
            writer:write_message_chunk(make_message_update("between\n\n"))
            writer:finalize_turn()

            writer:write_loaded_file({ path = "/r/b.md" })

            local lines = buffer_lines()
            assert.equal(file_row("/r/b.md"), lines[#lines - 1])
            assert.is_true(vim.tbl_contains(lines, "between"))
        end)

        it("leaves the call's section break to the prose after it", function()
            local block = make_tool_call_block("t1", "completed")
            block.description = "list the directory"
            writer:write_tool_call_block(block)

            writer:write_loaded_file({ path = "/r/a.md", tool_call_id = "t1" })
            writer:write_message_chunk(make_message_update("after the call\n"))

            assert.same({
                file_row("/r/a.md"),
                "",
                "###",
                "",
                "after the call",
                "",
            }, lines_after_footer())
        end)

        it("leaves the section break pending for an unanchored row", function()
            local block = make_tool_call_block("t1", "completed")
            block.description = "list the directory"
            writer:write_tool_call_block(block)

            writer:write_loaded_file({ path = "/r/a.md" })
            assert.same({ "", file_row("/r/a.md"), "" }, lines_after_footer())

            writer:write_message_chunk(make_message_update("after the call\n"))
            assert.same({
                "",
                file_row("/r/a.md"),
                "",
                "###",
                "",
                "after the call",
                "",
            }, lines_after_footer())
        end)

        it("opens the section break for a region after end rows", function()
            local block = make_tool_call_block("t1", "completed")
            block.description = "list the directory"
            writer:write_tool_call_block(block)

            writer:write_loaded_file({ path = "/r/a.md" })
            writer:write_hook_block({
                body = { "injected", "context" },
                title = "`guard.sh`",
            })

            assert.same({
                "",
                file_row("/r/a.md"),
                "",
                "###",
                "",
                "```markdown-fold",
                "`guard.sh`",
                "injected",
                "context",
                "```",
                "",
            }, lines_after_footer())
        end)

        describe("write_hook_row", function()
            local TEXT = "`/hooks/guard.sh` · 30 ms"

            --- Rows dimmed as `AgenticDimmedBlock`, 0-indexed.
            --- @return integer[]
            local function dimmed_rows()
                local rows = {}
                for _, mark in
                    ipairs(
                        vim.api.nvim_buf_get_extmarks(
                            bufnr,
                            Renderer.NS_DECORATIONS,
                            0,
                            -1,
                            { details = true }
                        )
                    )
                do
                    if mark[4].hl_group == "AgenticDimmedBlock" then
                        for row = mark[2], mark[4].end_row - 1 do
                            table.insert(rows, row)
                        end
                    end
                end
                return rows
            end

            it("writes a dimmed row under the hook glyph", function()
                writer:write_hook_row({ text = TEXT })

                assert.same({ "  " .. TEXT, "" }, buffer_lines())
                assert.same({ { 0, Glyphs.HOOK .. " " } }, rail())
                assert.same({ 0 }, dimmed_rows())
            end)

            it("signs a failed row with the failed hook glyph", function()
                writer:write_hook_row({ text = TEXT, failed = true })

                assert.same({ { 0, Glyphs.HOOK_FAILED .. " " } }, rail())
                assert.same({ 0 }, dimmed_rows())
            end)

            it("keeps a row wider than the wrap width whole", function()
                Config.windows.wrap_width = 20
                writer:write_hook_row({ text = TEXT })

                assert.equal("  " .. TEXT, buffer_lines()[1])
            end)

            it("keeps two rows under one call contiguous", function()
                call_then_prose()

                writer:write_hook_row({ text = "`a.sh`", tool_call_id = "t1" })
                writer:write_hook_row({ text = "`b.sh`", tool_call_id = "t1" })

                assert.same({
                    "  `a.sh`",
                    "  `b.sh`",
                    "",
                    "###",
                    "",
                    "after the call",
                    "",
                }, lines_after_footer())
                local first = vim.fn.index(buffer_lines(), "  `a.sh`")
                assert.same({ first, first + 1 }, dimmed_rows())
                assert_one_sign_per_row()
            end)

            it("keeps two unanchored rows after a call contiguous", function()
                local block = make_tool_call_block("t1", "completed")
                block.description = "list the directory"
                writer:write_tool_call_block(block)

                writer:write_hook_row({ text = "`a.sh`" })
                writer:write_hook_row({ text = "`b.sh`" })

                assert.same(
                    { "", "  `a.sh`", "  `b.sh`", "" },
                    lines_after_footer()
                )
            end)

            it("joins a loaded-file row group at the end", function()
                writer:write_loaded_file({ path = "/r/a.md" })
                writer:write_hook_row({ text = TEXT })
                writer:write_loaded_file({ path = "/r/b.md" })

                assert.same({
                    file_row("/r/a.md"),
                    "  " .. TEXT,
                    file_row("/r/b.md"),
                    "",
                }, buffer_lines())
                assert.same({ 1 }, dimmed_rows())
                assert_one_sign_per_row()
            end)
        end)

        it("forgets the anchors on reset", function()
            writer:write_user_prompt("go")
            writer:reset()

            assert.is_nil(writer._prompt_anchor)
            assert.is_nil(writer._end_rows)
        end)
    end)

    describe("prose run regions", function()
        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        --- Every row a `╭─` opener sits on, one per bracketed prose run. Only
        --- prose opens on the plain corner, so a tool call block adds none.
        --- @return integer[]
        local function opener_rows()
            local rows = {}
            for _, mark in ipairs(rail()) do
                if mark[2] == "╭─" then
                    table.insert(rows, mark[1])
                end
            end
            return rows
        end

        --- The row the first region opens on, or nil when nothing bracketed.
        --- @return integer|nil
        local function opener_row()
            return opener_rows()[1]
        end

        --- The row closing the last region in the buffer. Tool call blocks
        --- carry `╰─` too, so the summary's is the final one, never the first.
        --- @return integer|nil
        local function closer_row()
            local row
            for _, mark in ipairs(rail()) do
                if mark[2] == "╰─" then
                    row = mark[1]
                end
            end
            return row
        end

        it("brackets a streamed run down to its last prose row", function()
            writer:write_message_chunk(
                make_message_update("one\n\ntwo\n\nthree")
            )
            writer:finalize_turn()

            -- The trailing blank carries the turn-usage footer, so it stays
            -- outside the bracket.
            assert.same({ "one", "", "two", "", "three", "" }, buffer_lines())
            assert.same({
                { 0, "╭─" },
                { 1, "│ " },
                { 2, "│ " },
                { 3, "│ " },
                { 4, "╰─" },
            }, rail())
            assert_one_sign_per_row()
        end)

        it("opens on the run's first row, not the last reflow's", function()
            -- The first chunk ends on a complete paragraph, so the streaming
            -- reflow advances its marker past it before the second arrives.
            writer:write_message_chunk(make_message_update("one\n\ntwo\n\n"))
            writer:write_message_chunk(make_message_update("three"))
            writer:finalize_turn()

            assert.is_true(writer._chunk_start_line == nil)
            assert.equal(0, opener_row())
            assert.equal("one", buffer_lines()[1])
        end)

        it("opens on the first prose row after a tool call", function()
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:write_message_chunk(
                make_message_update("summary one\n\nsummary two")
            )
            writer:finalize_turn()

            -- The empty `###` that closes the tool call's section is written
            -- for the block above it and holds no content, so the region opens
            -- below it, on the first row of text.
            local row = opener_row()
            assert.is_true(row ~= nil)
            assert.equal("summary one", buffer_lines()[row + 1])
            assert.equal("###", buffer_lines()[row - 1])
            assert_one_sign_per_row()
        end)

        it("leaves a one-line run unbracketed", function()
            writer:write_message_chunk(make_message_update("done"))
            writer:finalize_turn()

            assert.same({}, rail())
        end)

        it("leaves a multi-row single paragraph unbracketed", function()
            -- Two rows of one paragraph. A row count would bracket this; the
            -- gate reads the text, which holds nothing to group.
            writer:write_message_chunk(
                make_message_update("summary one\nsummary two")
            )
            writer:finalize_turn()

            assert.same({}, rail())
        end)

        --- The text of the row the last region closes on, after streaming
        --- `text` as one run.
        --- @param text string
        --- @return string|nil
        local function closer_text(text)
            writer:write_message_chunk(make_message_update(text))
            writer:finalize_turn()
            local row = closer_row()
            return row and buffer_lines()[row + 1]
        end

        it("ends the rail above a trailing fence", function()
            as_chat()
            assert.equal("x = 1", closer_text("here:\n\n```lua\nx = 1\n```"))
        end)

        it("ends the rail on the closer at 'conceallevel' 0", function()
            as_chat()
            vim.wo[winid].conceallevel = 0
            assert.equal("```", closer_text("here:\n\n```lua\nx = 1\n```"))
        end)

        it(
            "ends the rail on a drawn inner fence row of a text block",
            function()
                as_chat()
                assert.equal(
                    "```",
                    closer_text("one\n\ntwo\n\n````text\nx\n```\n````")
                )
            end
        )

        it("ends the rail above the closers of a markdown block", function()
            as_chat()
            assert.equal(
                "y",
                closer_text("one\n\ntwo\n\n````markdown\n```lua\ny\n```\n````")
            )
        end)

        it("ends the rail above a tilde closer", function()
            as_chat()
            assert.equal("x", closer_text("one\n\ntwo\n\n~~~\nx\n~~~"))
        end)

        it("brackets the run a tool call interrupted", function()
            writer:write_message_chunk(
                make_message_update("looking at it\n\nrunning it now")
            )
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:finalize_turn()

            local rows = opener_rows()
            assert.equal(1, #rows)
            assert.equal("looking at it", buffer_lines()[rows[1] + 1])
            assert.equal("running it now", buffer_lines()[rows[1] + 3])
            assert_one_sign_per_row()
        end)

        it("leaves a one-line aside before a tool call unbracketed", function()
            writer:write_message_chunk(make_message_update("running it now"))
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:finalize_turn()

            assert.same({}, opener_rows())
        end)

        it("keeps a bracketed run when the next run brackets", function()
            -- The second run's signs are tracked and re-stamped as it streams;
            -- releasing that tracking at each run end is what stops the
            -- re-stamp from clearing the first run's committed bracket.
            writer:write_message_chunk(
                make_message_update("first one\n\nfirst two")
            )
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:write_message_chunk(
                make_message_update("second one\n\nsecond two")
            )
            writer:finalize_turn()

            local rows = opener_rows()
            assert.equal(2, #rows)
            assert.equal("first one", buffer_lines()[rows[1] + 1])
            assert.equal("second one", buffer_lines()[rows[2] + 1])
            assert_one_sign_per_row()
        end)

        it("gives a turn that ends on a thought no region", function()
            -- A thought run is its own region, so a turn closing on one has no
            -- trailing prose left to bracket.
            writer:write_message_chunk(
                make_thought_update("still thinking\nabout it")
            )
            writer:finalize_turn()

            assert.is_nil(opener_row())
        end)

        it("opens on the answer, not the thinking before it", function()
            writer:write_message_chunk(
                make_thought_update("thinking hard\nabout the problem")
            )
            writer:write_message_chunk(
                make_message_update("the answer\n\nis here")
            )
            writer:finalize_turn()

            local row = opener_row()
            assert.equal("the answer", buffer_lines()[row + 1])
            assert.equal("is here", buffer_lines()[closer_row() + 1])
        end)

        it("follows the run start across a tool block resize", function()
            writer:write_tool_call_block(make_tool_call_block("t1", "pending"))
            writer:write_message_chunk(
                make_message_update("summary one\n\nsummary two")
            )
            -- A block above the run grows when its body arrives late, pushing
            -- every prose row down with it.
            writer:update_tool_call_block(
                make_tool_call_block("t1", "completed", {
                    "out one",
                    "out two",
                    "out three",
                    "out four",
                })
            )
            writer:finalize_turn()

            local row = opener_row()
            assert.equal("summary one", buffer_lines()[row + 1])
            assert.equal("summary two", buffer_lines()[closer_row() + 1])
            assert_one_sign_per_row()
        end)

        it("brackets the runs on each side of end_runs apart", function()
            -- The subagent pane ends runs per subagent as it closes, long
            -- before the turn does.
            writer:write_message_chunk(
                make_message_update("before one\n\nbefore two")
            )
            writer:end_runs()
            writer:write_message_chunk(
                make_message_update("after one\n\nafter two")
            )
            writer:finalize_turn()

            local rows = opener_rows()
            assert.equal(2, #rows)
            assert.equal("before one", buffer_lines()[rows[1] + 1])
            assert.equal("after one", buffer_lines()[rows[2] + 1])
            assert.equal("after two", buffer_lines()[closer_row() + 1])
            assert_one_sign_per_row()
        end)

        it("rails a run as it streams, before the turn ends", function()
            writer:write_message_chunk(make_message_update("one\n\ntwo\n"))

            assert.same(
                { { 0, "╭─" }, { 1, "│ " }, { 2, "╰─" } },
                rail()
            )

            -- The corner follows the row just gained rather than waiting for
            -- the next paragraph to complete, which is the only thing that
            -- fires a reflow.
            writer:write_message_chunk(make_message_update("three\n"))

            assert.same({
                { 0, "╭─" },
                { 1, "│ " },
                { 2, "│ " },
                { 3, "╰─" },
            }, rail())
            assert_one_sign_per_row()
        end)

        it("rails a run once a chunk lands on the blank row", function()
            -- The row a paragraph break leaves behind is where the next
            -- paragraph's first words land, so the run's last drawn row moves
            -- without the line count changing.
            writer:write_message_chunk(make_message_update("one\n\n"))
            assert.same({}, rail())

            writer:write_message_chunk(make_message_update("two "))

            assert.same(
                { { 0, "╭─" }, { 1, "│ " }, { 2, "╰─" } },
                rail()
            )
        end)

        it("drops a live region's signs when the turn state resets", function()
            -- A refresh abandons the run mid-stream. Its signs have to go with
            -- it: the next run starts on the row they end on.
            writer:write_message_chunk(make_message_update("alpha\n\nbeta"))
            writer:reset_turn_state()
            writer:write_message_chunk(make_message_update(" more\n\ngamma\n"))

            assert_one_sign_per_row()
        end)

        it("re-stamps the rail over rewrapped rows", function()
            -- Wide enough to wrap at the 60-column test window, so the reflow
            -- replaces the rows the live region is stamped on.
            local long = string.rep("word ", 30)
            writer:write_message_chunk(
                make_message_update("intro\n\n" .. long .. "\n\n")
            )
            writer:write_message_chunk(make_message_update("tail\n"))

            assert.same({ 0 }, opener_rows())
            assert.equal("tail", buffer_lines()[closer_row() + 1])
            assert_one_sign_per_row()
        end)
    end)

    describe("any_following", function()
        it("is true while a window is not in user control", function()
            setup_buffer(50, 1)
            assert.is_true(writer:any_following())
        end)

        it("is false when every window is in user control", function()
            setup_buffer(50, 50)
            writer._user_controlled[winid] = true
            assert.is_false(writer:any_following())
        end)

        it("is true when no window shows the buffer", function()
            local hidden_buf = vim.api.nvim_create_buf(false, true)
            local hidden_writer = MessageWriter:new(hidden_buf)
            assert.is_true(hidden_writer:any_following())
            vim.api.nvim_buf_delete(hidden_buf, { force = true })
        end)
    end)

    describe("_schedule_follow", function()
        it("owes a scroll", function()
            local schedule_stub = spy.stub(vim, "schedule")
            writer:_schedule_follow()

            assert.is_true(writer._scroll_owed)
            schedule_stub:revert()
        end)

        it("coalesces multiple calls into a single scheduled scroll", function()
            local schedule_stub = spy.stub(vim, "schedule")
            writer:_schedule_follow()
            writer:_schedule_follow()
            writer:_schedule_follow()

            assert.equal(1, schedule_stub.call_count)
            schedule_stub:revert()
        end)
    end)

    describe("_scroll_owed", function()
        it(
            "scheduled callback discharges it and moves cursor to last line",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(50, 1)
                writer:_schedule_follow()

                assert.is_false(writer._scroll_owed)
                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                schedule_stub:revert()
            end
        )

        it("scheduled callback leaves a window in user control", function()
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)

            setup_buffer(50, 1)
            writer._user_controlled[winid] = true
            writer:_schedule_follow()

            assert.equal(1, vim.api.nvim_win_get_cursor(winid)[1])

            schedule_stub:revert()
        end)

        it(
            "scheduled callback scrolls the home window from another tabpage",
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

                writer:_schedule_follow()

                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                vim.api.nvim_set_current_tabpage(tab2)
                vim.cmd("tabclose")

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
            "callback skips the scroll and keeps it owed when a fold op is pending",
            function()
                setup_buffer(50, 1)
                -- A pending fold op stands in for a queued :foldclose.
                writer._pending_fold_ops = { { id = 1, open = false } }

                local scroll_spy = spy.on(writer, "_scroll")
                writer:_schedule_follow()

                assert.equal(0, scroll_spy.call_count)
                -- Still owed, for flush_pending_fold_ops.
                assert.is_true(writer._scroll_owed)
                scroll_spy:revert()
            end
        )

        it("callback scrolls anyway while the op is held for insert", function()
            -- The skip above assumes the flush follows within the tick. An
            -- insert-mode hold lasts as long as the user keeps typing, and the
            -- flush does not run at all meanwhile — so deferring to it would
            -- freeze the viewport for every write until they leave insert.
            setup_buffer(50, 1)
            writer._pending_fold_ops = { { id = 1, open = false } }
            local mode = spy.stub(vim.api, "nvim_get_mode")
            mode:returns({ mode = "i", blocking = false })

            local scroll_spy = spy.on(writer, "_scroll")
            writer:_schedule_follow()

            assert.equal(1, scroll_spy.call_count)
            scroll_spy:revert()
            mode:revert()
            writer._pending_fold_ops = {}
        end)

        it("insert-mode hold scrolls for the write it inherited", function()
            -- The first write's callback has already skipped by the time the
            -- flush discovers insert mode, so the hold owes that one a scroll.
            setup_buffer(50, 1)
            writer._pending_fold_ops = { { id = 1, open = false } }
            writer._scroll_owed = true
            local mode = spy.stub(vim.api, "nvim_get_mode")
            mode:returns({ mode = "i", blocking = false })

            local scroll_spy = spy.on(writer, "_scroll")
            writer:flush_pending_fold_ops()

            assert.equal(1, scroll_spy.call_count)
            -- Held, not dropped: the rebuild after insert still has to close
            -- the fold.
            assert.equal(1, #writer._pending_fold_ops)
            assert.is_true(writer._rebuild_armed)
            scroll_spy:revert()
            mode:revert()
            -- Consume the armed autocmd so it cannot fire in a sibling test.
            writer._pending_fold_ops = {}
            vim.api.nvim_exec_autocmds("ModeChanged", {})
        end)

        it(
            "flush scrolls once the folds are closed, then discharges the scroll",
            function()
                setup_buffer(50, 1)
                writer._scroll_owed = true

                local scroll_spy = spy.on(writer, "_scroll")
                -- A real fold anchor isn't needed — flush scrolls after draining
                -- whatever ops are present, missing folds included.
                local id = vim.api.nvim_buf_set_extmark(
                    bufnr,
                    vim.api.nvim_create_namespace("agentic_fold_anchors"),
                    0,
                    0,
                    {}
                )
                writer._pending_fold_ops = { { id = id, open = false } }
                writer:flush_pending_fold_ops()

                assert.equal(1, scroll_spy.call_count)
                assert.is_false(writer._scroll_owed)
                scroll_spy:revert()
            end
        )

        it("flush reports the first fold it could not change", function()
            setup_buffer(50, 1)
            vim.api.nvim_set_option_value(
                "foldmethod",
                "manual",
                { win = winid, scope = "local" }
            )
            vim.api.nvim_win_call(winid, function()
                vim.cmd("21,30fold")
                vim.cmd("21foldopen")
            end)
            local notify = spy.stub(require("agentic.utils.logger"), "notify")
            local ns = vim.api.nvim_create_namespace("agentic_fold_anchors")
            writer._pending_fold_ops = {
                {
                    id = vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {}),
                    open = false,
                },
                {
                    id = vim.api.nvim_buf_set_extmark(bufnr, ns, 1, 0, {}),
                    open = false,
                },
                {
                    id = vim.api.nvim_buf_set_extmark(bufnr, ns, 20, 0, {}),
                    open = false,
                },
            }

            writer:flush_pending_fold_ops()

            assert.equal(1, notify.call_count)
            assert.truthy(notify.calls[1][1]:find("E490", 1, true))
            -- The failures do not stop the ops after them.
            assert.equal(21, vim.fn.foldclosed(21))
            notify:revert()
        end)

        it("a write in insert mode to a wiped buffer is a no-op", function()
            vim.api.nvim_buf_delete(bufnr, { force = true })
            local mode = spy.stub(vim.api, "nvim_get_mode")
            mode:returns({ mode = "i", blocking = false })

            local ok, err = pcall(writer._own_edit, writer, function() end)

            mode:revert()
            assert.is_true(ok, tostring(err))
        end)

        it("flush does not scroll a window in user control", function()
            setup_buffer(50, 1)
            writer._scroll_owed = true
            writer._user_controlled[winid] = true

            local scroll_spy =
                spy.on(require("agentic.utils.buf_helpers"), "scroll_down")
            local id = vim.api.nvim_buf_set_extmark(
                bufnr,
                vim.api.nvim_create_namespace("agentic_fold_anchors"),
                0,
                0,
                {}
            )
            writer._pending_fold_ops = { { id = id, open = false } }
            writer:flush_pending_fold_ops()

            assert.equal(0, scroll_spy.call_count)
            scroll_spy:revert()
        end)
    end)

    describe("follow with public write methods", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("write_message owes a scroll", function()
            setup_buffer(10, 10)

            local long_text = {}
            for i = 1, 50 do
                long_text[i] = "message line " .. i
            end

            writer:write_message(
                make_message_update(table.concat(long_text, "\n"))
            )

            assert.is_true(writer._scroll_owed)
        end)

        it("write_tool_call_block owes a scroll", function()
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

            assert.is_true(writer._scroll_owed)
            assert.is_true(vim.api.nvim_buf_line_count(bufnr) > 20)
        end)

        it("finalize_turn owes a scroll", function()
            setup_buffer(20, 20)

            writer:finalize_turn()

            assert.is_true(writer._scroll_owed)
            assert.equal(21, vim.api.nvim_buf_line_count(bufnr))
        end)

        it("write_message does not scroll a window in user control", function()
            schedule_stub:invokes(function(fn)
                fn()
            end)
            setup_buffer(50, 1)
            writer._user_controlled[winid] = true

            writer:write_message(
                make_message_update("new content\nmore content")
            )

            assert.equal(1, vim.api.nvim_win_get_cursor(winid)[1])
        end)
    end)

    describe("on_view_change", function()
        --- Set `winid`'s view, as the user would.
        --- @param view { topline: integer, lnum: integer }
        local function move(view)
            vim.api.nvim_win_call(winid, function()
                vim.fn.winrestview(view)
            end)
        end

        --- Set `winid`'s view as the writer's own change, the start of a test.
        --- @param view { topline: integer, lnum: integer }
        local function start_at(view)
            writer:_own_change(function()
                move(view)
            end)
        end

        before_each(function()
            setup_buffer(50, 1)
        end)

        it(
            "a cursor move up puts the window in user control, keeping the pin",
            function()
                writer._prose_anchor_line = 40
                start_at({ topline = 31, lnum = 50 })

                move({ topline = 31, lnum = 49 })
                writer:on_view_change(winid, false)

                assert.is_true(writer._user_controlled[winid])
                assert.equal(40, writer._prose_anchor_line)
            end
        )

        it(
            "a view move up puts the window in user control with the last line in view",
            function()
                start_at({ topline = 35, lnum = 45 })

                move({ topline = 34, lnum = 45 })
                writer:on_view_change(winid, false)

                assert.is_true(writer._user_controlled[winid])
            end
        )

        it("a view move down onto the last line follows again", function()
            writer._user_controlled[winid] = true
            start_at({ topline = 1, lnum = 1 })

            move({ topline = 31, lnum = 31 })
            writer:on_view_change(winid, false)

            assert.is_nil(writer._user_controlled[winid])
        end)

        it(
            "closing a fold that ends on the last line keeps following",
            function()
                vim.api.nvim_win_call(winid, function()
                    vim.wo.foldmethod = "manual"
                    vim.cmd("40,50fold")
                    vim.cmd("40foldopen")
                end)
                start_at({ topline = 31, lnum = 50 })

                vim.api.nvim_win_call(winid, function()
                    vim.cmd("normal! zc")
                    -- As vim's main loop does after zc: the cursor goes to the
                    -- fold start, and lines from above fill the rows it freed.
                    vim.fn.winrestview({ topline = 21, lnum = 40 })
                end)
                writer:on_view_change(winid, false)

                assert.is_nil(writer._user_controlled[winid])
            end
        )

        it(
            "closing a fold that brings the end into view keeps user control",
            function()
                writer._user_controlled[winid] = true
                start_at({ topline = 1, lnum = 1 })

                vim.api.nvim_win_call(winid, function()
                    vim.wo.foldmethod = "manual"
                    vim.cmd("5,40fold")
                end)
                writer:on_view_change(winid, false)

                assert.is_true(writer._user_controlled[winid])
            end
        )

        it(
            "a view move down short of the last line keeps user control",
            function()
                writer._user_controlled[winid] = true
                start_at({ topline = 1, lnum = 1 })

                move({ topline = 10, lnum = 10 })
                writer:on_view_change(winid, false)

                assert.is_true(writer._user_controlled[winid])
            end
        )

        it("a cursor move onto the last line follows again", function()
            writer._user_controlled[winid] = true
            start_at({ topline = 31, lnum = 40 })

            move({ topline = 31, lnum = 50 })
            writer:on_view_change(winid, false)

            assert.is_nil(writer._user_controlled[winid])
        end)

        it(
            "a cursor move down short of the last line keeps user control",
            function()
                writer._user_controlled[winid] = true
                start_at({ topline = 31, lnum = 40 })

                move({ topline = 31, lnum = 45 })
                writer:on_view_change(winid, false)

                assert.is_true(writer._user_controlled[winid])
            end
        )

        it("the view our own change leaves is not a motion", function()
            start_at({ topline = 31, lnum = 50 })
            start_at({ topline = 1, lnum = 1 })

            writer:on_view_change(winid, false)

            assert.is_nil(writer._user_controlled[winid])
        end)

        it("a resize is not a motion", function()
            start_at({ topline = 31, lnum = 50 })

            move({ topline = 20, lnum = 39 })
            writer:on_view_change(winid, true)

            assert.is_nil(writer._user_controlled[winid])
        end)

        it("a window entry is not a motion, the next change is", function()
            start_at({ topline = 31, lnum = 50 })

            writer:on_window_enter(winid)
            move({ topline = 31, lnum = 40 })
            writer:on_view_change(winid, false)
            assert.is_nil(writer._user_controlled[winid])

            move({ topline = 31, lnum = 39 })
            writer:on_view_change(winid, false)
            assert.is_true(writer._user_controlled[winid])
        end)

        it(
            "an entry left without a view change skips no later motion",
            function()
                start_at({ topline = 31, lnum = 50 })

                writer:on_window_enter(winid)
                writer:on_window_leave(winid)
                move({ topline = 31, lnum = 40 })
                writer:on_view_change(winid, false)

                assert.is_true(writer._user_controlled[winid])
            end
        )

        it(
            "go_to_bottom puts the window in following on the last line",
            function()
                writer._user_controlled[winid] = true

                writer:go_to_bottom(winid)

                assert.is_nil(writer._user_controlled[winid])
                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])
            end
        )
    end)

    describe("tool call hold", function()
        --- @type TestStub
        local schedule_stub

        --- @return integer
        local function topline(win)
            vim.cmd("redraw")
            return vim.fn.line("w0", win or winid)
        end

        --- Track a tool call "h" over 0-indexed rows `s` through `e`.
        --- @param s integer
        --- @param e integer
        local function track(s, e)
            local id = vim.api.nvim_buf_set_extmark(
                bufnr,
                Renderer.NS_TOOL_BLOCKS,
                s,
                0,
                { end_row = e }
            )
            writer.tool_call_blocks.h = make_tool_call_block("h", "pending")
            writer.tool_call_blocks.h.extmark_id = id
        end

        --- Set `win`'s view as the user would, and report it.
        --- @param view { topline: integer, lnum: integer }
        local function user_move(view, win)
            win = win or winid
            vim.api.nvim_win_call(win, function()
                vim.fn.winrestview(view)
            end)
            writer:on_view_change(win, false)
        end

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            vim.wo[winid].scrolloff = 0
            -- Room: 20 rows less the default bottom padding of 1.
            setup_buffer(50, 1)
            writer:_own_change(function() end)
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("centres a block that fits", function()
            track(20, 24)

            writer:hold_tool_call("h", false)

            assert.equal(14, topline())
        end)

        it("shows no rows past the end of the buffer", function()
            track(45, 49)

            writer:hold_tool_call("h", false)

            assert.equal(32, topline())
        end)

        it("puts a tall block's header at the top, with scrolloff", function()
            vim.wo[winid].scrolloff = 4
            track(10, 45)

            writer:hold_tool_call("h", false)

            assert.equal(11, topline())
        end)

        it(
            "caps writes at the header at the top, folded body included",
            function()
                track(20, 24)
                writer:hold_tool_call("h", false)
                vim.api.nvim_win_call(winid, function()
                    vim.wo.foldmethod = "manual"
                    vim.cmd("22,25fold")
                end)

                vim.api.nvim_buf_set_lines(
                    bufnr,
                    -1,
                    -1,
                    false,
                    { "a", "b", "c" }
                )
                for _ = 1, 30 do
                    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "more" })
                end
                writer:_schedule_follow()

                assert.equal(21, topline())
            end
        )

        it("leaves a following window the user moved down past it", function()
            track(20, 24)
            writer:hold_tool_call("h", false)
            user_move({ topline = 25, lnum = 25 })

            writer:_schedule_follow()

            assert.is_nil(writer._user_controlled[winid])
            assert.equal(25, topline())
        end)

        it(
            "a user scroll up takes only that window, keeping the hold",
            function()
                local other = vim.api.nvim_open_win(bufnr, false, {
                    relative = "editor",
                    width = 60,
                    height = 20,
                    row = 0,
                    col = 62,
                })
                track(20, 24)
                writer:hold_tool_call("h", false)

                user_move({ topline = 10, lnum = 10 })

                assert.is_true(writer._user_controlled[winid])
                assert.is_nil(writer._user_controlled[other])
                assert.equal("h", writer._held_tool_call_id)
                vim.api.nvim_win_close(other, true)
            end
        )

        it("does not move a window in user control", function()
            writer._user_controlled[winid] = true
            track(20, 24)

            writer:hold_tool_call("h", false)

            assert.equal(1, topline())
        end)

        it("moves no window with follow off", function()
            Config.follow = vim.tbl_extend("force", Config.follow, {
                enabled = false,
            }) --[[@as agentic.UserConfig.Follow]]
            track(20, 24)

            writer:hold_tool_call("h", false)

            assert.equal(1, topline())
        end)

        it("survives reset_turn_state", function()
            writer:hold_tool_call("h", false)

            writer:reset_turn_state()

            assert.equal("h", writer._held_tool_call_id)
        end)

        it("waits for pending fold ops and measures the closed fold", function()
            -- Long enough that the end of the buffer does not clamp.
            setup_buffer(80, 1)
            writer:_own_change(function() end)
            track(20, 45)
            vim.api.nvim_win_call(winid, function()
                vim.wo.foldmethod = "manual"
                vim.cmd("22,45fold")
                vim.cmd("22foldopen")
            end)
            writer._pending_fold_ops = {
                { id = writer:_place_fold_anchor(21), open = false },
            }

            writer:hold_tool_call("h", false)
            assert.equal(1, topline())
            writer:flush_pending_fold_ops()

            -- Header, closed fold, footer: 3 rows, 8 above them.
            assert.equal(13, topline())
        end)

        it(
            "placed in insert mode, places again once the folds close",
            function()
                setup_buffer(80, 1)
                writer:_own_change(function() end)
                track(20, 45)
                vim.api.nvim_win_call(winid, function()
                    vim.wo.foldmethod = "manual"
                    vim.cmd("22,45fold")
                    vim.cmd("22foldopen")
                end)
                writer._pending_fold_ops = {
                    { id = writer:_place_fold_anchor(21), open = false },
                }
                local mode = spy.stub(vim.api, "nvim_get_mode")
                mode:returns({ mode = "i", blocking = false })

                writer:hold_tool_call("h", false)
                writer:flush_pending_fold_ops()
                -- Tall while open: header at the top.
                assert.equal(21, topline())

                mode:revert()
                vim.api.nvim_exec_autocmds("ModeChanged", {})

                -- Header, closed fold, footer: 3 rows, 8 above them.
                assert.equal(13, topline())
            end
        )

        it("with follow off, the pin holds no window", function()
            writer._pin_held[winid] = true
            Config.follow = vim.tbl_extend("force", Config.follow, {
                enabled = false,
            }) --[[@as agentic.UserConfig.Follow]]

            writer:_schedule_follow()
            writer:_release_prose_pin()

            assert.is_nil(writer._user_controlled[winid])
        end)

        it(
            "a pin release skips a window that no longer shows the buffer",
            function()
                writer._pin_held[winid] = true
                local other = vim.api.nvim_create_buf(false, true)
                vim.api.nvim_win_set_buf(winid, other)

                writer:_release_prose_pin()

                assert.is_nil(writer._user_controlled[winid])
                vim.api.nvim_win_set_buf(winid, bufnr)
                vim.api.nvim_buf_delete(other, { force = true })
            end
        )

        it("a hold scroll clears the pin's hold on the window", function()
            writer._prose_anchor_line = 5
            writer._pin_held[winid] = true
            track(20, 24)

            writer:hold_tool_call("h", false)
            writer:_release_prose_pin()

            assert.is_nil(writer._user_controlled[winid])
        end)

        it("leaves a cursor that stays in view", function()
            vim.api.nvim_win_set_cursor(winid, { 16, 0 })
            writer:_own_change(function() end)
            track(20, 24)

            writer:hold_tool_call("h", false)

            assert.equal(16, vim.api.nvim_win_get_cursor(winid)[1])
        end)

        it("after release_hold, follows the stream", function()
            track(20, 24)
            writer:hold_tool_call("h", false)

            writer:release_hold()

            assert.is_nil(writer._user_controlled[winid])
            assert.equal(32, topline())
        end)

        it("a hold with no rows yet follows, then places the block", function()
            writer:hold_tool_call("h", false)
            assert.equal(32, topline())

            track(20, 24)
            writer:_schedule_follow()

            assert.equal(14, topline())
        end)

        it(
            "follow_in takes a window out of user control and places it",
            function()
                writer._user_controlled[winid] = true
                track(20, 24)
                writer:hold_tool_call("h", false)

                writer:follow_in(winid)

                assert.is_nil(writer._user_controlled[winid])
                assert.equal(14, topline())
            end
        )
    end)

    describe("last position", function()
        --- @type TestStub
        local schedule_stub

        --- @return integer
        local function last_position_line()
            return vim.api.nvim_buf_get_mark(bufnr, '"')[1]
        end

        --- Append `n` lines as the writer's own edit.
        --- @param n integer
        local function write(n)
            writer:_own_edit(function(b)
                local more = {}
                for i = 1, n do
                    more[i] = "more " .. i
                end
                vim.api.nvim_buf_set_lines(b, -1, -1, false, more)
            end)
        end

        --- Hide the buffer from its one window, which BufWinLeave reports.
        local function hide()
            vim.api.nvim_win_close(winid, true)
        end

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
            vim.wo[winid].scrolloff = 0
            setup_buffer(50, 1)
            writer:_own_change(function() end)
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("is the last line until the buffer has one", function()
            hide()
            write(5)
            assert.equal(55, last_position_line())

            write(5)
            assert.equal(60, last_position_line())
        end)

        it("is where a window in user control left it", function()
            writer._user_controlled[winid] = true
            vim.api.nvim_win_set_cursor(winid, { 10, 0 })

            hide()
            write(5)

            assert.equal(10, last_position_line())
        end)

        it("is not set by a window that left following", function()
            vim.api.nvim_win_set_cursor(winid, { 10, 0 })

            hide()
            assert.equal(50, last_position_line())
            write(5)
            assert.equal(55, last_position_line())
        end)

        it("without it, a shown window follows to the bottom", function()
            writer._user_controlled[winid] = true

            writer:on_window_shown(winid)

            assert.is_nil(writer._user_controlled[winid])
            assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])
        end)

        it("without it, a shown window reaches a pin above its view", function()
            writer._prose_anchor_line = 10
            vim.api.nvim_win_call(winid, function()
                vim.fn.winrestview({ topline = 31, lnum = 31 })
            end)

            writer:on_window_shown(winid)

            vim.cmd("redraw")
            assert.equal(11, vim.fn.line("w0", winid))
        end)

        it(
            "without it, a window vim restores below the pin reaches the pin",
            function()
                vim.api.nvim_win_set_cursor(winid, { 45, 0 })
                hide()
                writer._prose_anchor_line = 9
                schedule_stub:revert()
                local deferred = Deferred.capture()
                MiniTest.finally(deferred.revert)

                vim.cmd("sbuffer " .. bufnr)
                winid = vim.api.nvim_get_current_win()
                -- Vim's restore from the window history, after BufWinEnter.
                assert.equal(45, vim.api.nvim_win_get_cursor(winid)[1])
                vim.cmd("redraw")
                deferred.drain()

                vim.cmd("redraw")
                assert.equal(10, vim.fn.line("w0", winid))
                assert.is_nil(writer._user_controlled[winid])
            end
        )

        it(
            "without it and follow off, a shown window goes to the last line",
            function()
                Config.follow = vim.tbl_extend("force", Config.follow, {
                    enabled = false,
                }) --[[@as agentic.UserConfig.Follow]]

                writer:on_window_shown(winid)

                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])
            end
        )

        it("with it, a shown window keeps its place in user control", function()
            writer._has_last_position = true
            vim.api.nvim_win_set_cursor(winid, { 10, 0 })
            writer._scroll_owed = true
            writer._pending_fold_ops = {
                { id = writer:_place_fold_anchor(5), open = false },
            }

            writer:on_window_shown(winid)
            writer:flush_pending_fold_ops()

            assert.is_true(writer._user_controlled[winid])
            assert.equal(10, vim.api.nvim_win_get_cursor(winid)[1])
        end)

        it(
            "with it, only the first window shown after it keeps its place",
            function()
                writer._has_last_position = true
                writer:on_window_shown(winid)

                local other = vim.api.nvim_open_win(bufnr, false, {
                    relative = "editor",
                    width = 60,
                    height = 20,
                    row = 0,
                    col = 62,
                })
                MiniTest.finally(function()
                    vim.api.nvim_win_close(other, true)
                end)

                assert.is_true(writer._user_controlled[winid])
                assert.is_nil(writer._user_controlled[other])
            end
        )

        it("with it, follow_in after the show still follows", function()
            writer._has_last_position = true

            writer:on_window_shown(winid)
            writer:follow_in(winid)

            assert.is_nil(writer._user_controlled[winid])
            assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])
        end)

        it("a window opened on a hidden buffer opens at the bottom", function()
            hide()
            winid = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 60,
                height = 20,
                row = 0,
                col = 0,
            })

            assert.is_nil(writer._user_controlled[winid])
            assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])
        end)

        it("a closed window is forgotten", function()
            local other = vim.api.nvim_open_win(bufnr, false, {
                relative = "editor",
                width = 60,
                height = 20,
                row = 0,
                col = 62,
            })
            writer:_own_change(function() end)
            writer._user_controlled[other] = true
            writer._pin_held[other] = true
            writer._newly_shown[other] = true

            vim.api.nvim_win_close(other, true)

            assert.is_nil(writer._user_controlled[other])
            assert.is_nil(writer._views[other])
            assert.is_nil(writer._pin_held[other])
            assert.is_nil(writer._newly_shown[other])
            assert.is_not_nil(writer._views[winid])
        end)

        it(
            "the last window is forgotten after its last position is kept",
            function()
                writer._user_controlled[winid] = true

                hide()

                assert.is_true(writer._has_last_position)
                assert.is_nil(writer._user_controlled[winid])
                assert.is_nil(writer._views[winid])
            end
        )

        it("is forgotten on reset", function()
            writer._has_last_position = true

            writer:reset()

            assert.is_false(writer._has_last_position)
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
            -- Below a thousand the k-suffix would render the output as "0.4k",
            -- which reads as "about none".
            assert.equal(text, "1.2k in · 420 out")
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
            "resume_follow ends user control and scrolls to the bottom",
            function()
                setup_buffer(50, 1)
                writer._user_controlled[winid] = true

                writer:resume_follow()

                assert.is_nil(writer._user_controlled[winid])
                assert.equal(vim.fn.getwininfo(winid)[1].botline, 50)
            end
        )

        it("does not set the pin in user control", function()
            writer._user_controlled[winid] = true

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

            local deferred = Deferred.capture()
            MiniTest.finally(deferred.revert)
            for i = 1, 30 do
                writer:write_message_chunk(
                    make_message_update("line " .. i .. "\n")
                )
                vim.cmd("redraw")
                deferred.drain()
            end
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
                -- the write and scroll_down (scheduled, post-write). Cannot run scheduled callbacks inline here:
                -- doing so runs scroll_down *before* the write, which
                -- bypasses the bug entirely. Drain after each write instead.
                local deferred = Deferred.capture()
                MiniTest.finally(deferred.revert)
                for i = 1, 25 do
                    writer:write_message_chunk(
                        make_message_update("line " .. i .. "\n")
                    )
                    vim.cmd("redraw")
                    deferred.drain()
                end

                local info = vim.fn.getwininfo(winid)[1]
                assert.equal(1, info.topline)
                -- Cursor parked inside the pinned viewport, not at last.
                assert.is_true(vim.api.nvim_win_get_cursor(winid)[1] <= 20)
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

            BufHelpers.scroll_down(winid, 1, 10)
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

            BufHelpers.scroll_down(winid, 1, 10)

            local info = vim.fn.getwininfo(winid)[1]
            assert.equal(25, info.topline)
        end)

        it("holds the view at a cap that binds, cursor inside it", function()
            -- A cursor below the view would make the redraw scroll past the
            -- cap to show it.
            local lines = {}
            for i = 1, 20 do
                lines[i] = "line " .. i
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            vim.api.nvim_win_set_cursor(winid, { 20, 0 })
            -- Grow the last line into many, as a streamed chunk does: the
            -- cursor stays on its row, now below the view's last screen row.
            local more = { "line 20" }
            for i = 21, 50 do
                more[#more + 1] = "line " .. i
            end
            vim.api.nvim_buf_set_text(bufnr, 19, 0, 19, -1, more)

            local held = BufHelpers.scroll_down(winid, 1, 1)

            assert.is_true(held)
            assert.is_true(vim.api.nvim_win_get_cursor(winid)[1] <= 20)
            assert.equal(1, vim.fn.getwininfo(winid)[1].topline)
        end)

        it("leaves a cursor inside the capped viewport in place", function()
            local lines = {}
            for i = 1, 50 do
                lines[i] = "line " .. i
            end
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
            vim.api.nvim_win_set_cursor(winid, { 3, 2 })

            BufHelpers.scroll_down(winid, 1, 1)

            assert.same({ 3, 2 }, vim.api.nvim_win_get_cursor(winid))
        end)

        it(
            "puts the cursor on the last line under a cap that does not bind",
            function()
                local lines = {}
                for i = 1, 10 do
                    lines[i] = "line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
                vim.api.nvim_win_set_cursor(winid, { 3, 0 })

                local held = BufHelpers.scroll_down(winid, 1, 1)

                assert.is_false(held)
                assert.equal(10, vim.api.nvim_win_get_cursor(winid)[1])
            end
        )

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

            BufHelpers.scroll_down(winid, 1, nil)

            local info = vim.fn.getwininfo(winid)[1]
            -- With 50 lines and a 20-line window, natural bottom-scroll puts
            -- topline ~= 31. Without a clamp it should be much greater than 10.
            assert.is_true(info.topline > 10)
        end)

        it("no-ops without error when topline sits on the last line", function()
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

            BufHelpers.scroll_down(winid, 1, nil)

            local info = vim.fn.getwininfo(winid)[1]
            assert.equal(6, info.topline)
        end)

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

                BufHelpers.scroll_down(winid, 1, nil)
                vim.cmd("redraw")

                local info = vim.fn.getwininfo(winid)[1]
                assert.equal(1, info.topline)
                assert.equal(30, info.botline)
            end
        )
    end)

    describe("run time in the footer", function()
        local RunClocks = require("agentic.ui.run_clocks")
        local now_ms
        --- @type TestStub
        local schedule_stub
        --- @type agentic.ui.RunClocks
        local clocks

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            now_ms = 0
            clocks = RunClocks:new(5000, function() end)
            -- Each running clock reads `now_ms`.
            function clocks:elapsed(id)
                return RunClocks.elapsed(self, id) and now_ms
            end
            writer.run_clocks = clocks
        end)

        after_each(function()
            clocks:destroy()
            schedule_stub:revert()
        end)

        --- @param id string
        --- @return string footer The tracked block's footer row
        local function footer(id)
            local _, end_row = writer:_block_rows(writer.tool_call_blocks[id])
            local row = end_row --[[@as integer]]
            return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        end

        it("shows no time below the threshold", function()
            clocks:start("t", true)
            writer:write_tool_call_block(make_tool_call_block("t", "pending"))
            now_ms = 4999
            writer:refresh_status("t")
            assert.truthy(footer("t"):find(" pending $"))
        end)

        it(
            "shows whole seconds at and above the threshold while running",
            function()
                clocks:start("t", true)
                writer:write_tool_call_block(
                    make_tool_call_block("t", "pending")
                )
                now_ms = 7900
                writer:refresh_status("t")
                assert.truthy(footer("t"):find("pending · 7 s $"))
            end
        )

        it("follows the causes", function()
            clocks:start("t", true)
            writer:write_tool_call_block(make_tool_call_block("t", "pending"))
            now_ms = 6000
            writer:update_tool_call_block({
                tool_call_id = "t",
                status = "in_progress",
                causes = { { code = "grant", subject = "/a" } },
            })
            assert.truthy(footer("t"):find("in_progress · grant · 6 s $"))
        end)

        it("shows tenths once the call ends", function()
            clocks:start("t", true)
            writer:write_tool_call_block(make_tool_call_block("t", "pending"))
            now_ms = 6340
            writer:update_tool_call_block({
                tool_call_id = "t",
                status = "completed",
            })
            assert.truthy(footer("t"):find("completed · 6.3 s $"))
        end)

        it("stamps duration_ms on the ending update and keeps it", function()
            clocks:start("t", true)
            writer:write_tool_call_block(make_tool_call_block("t", "pending"))
            now_ms = 192500
            --- @type agentic.ui.MessageWriter.ToolCallBase
            local update = { tool_call_id = "t", status = "completed" }
            writer:update_tool_call_block(update)
            assert.equal(192500, update.duration_ms)
            now_ms = 999999
            writer:update_tool_call_block({
                tool_call_id = "t",
                status = "completed",
                body = { "late" },
            })
            assert.truthy(footer("t"):find("completed · 3m12s $"))
        end)

        it("stamps the calls stamp_open_calls ends", function()
            clocks:start("t", true)
            writer:write_tool_call_block(make_tool_call_block("t", "pending"))
            now_ms = 8000
            local updates = writer:stamp_open_calls("interrupted", "failed")
            assert.equal(8000, updates[1].duration_ms)
        end)

        it("shows a written block's saved time without a clock", function()
            local block = make_tool_call_block("t", "completed")
            block.duration_ms = 61000
            writer:write_tool_call_block(block)
            assert.truthy(footer("t"):find("completed · 1m01s $"))
            assert.is_nil(clocks:elapsed("t"))
        end)

        it("shows no time without clocks", function()
            writer.run_clocks = nil
            local block = make_tool_call_block("t", "completed")
            block.duration_ms = 61000
            writer:write_tool_call_block(block)
            assert.truthy(footer("t"):find(" completed $"))
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

        for word, fields in pairs({
            rejected = {
                status = "failed",
                causes = { { code = "prompt-reject" } },
            },
            interrupted = { status = "failed", ended_as = "interrupted" },
        }) do
            it("shows " .. word .. " in the footer", function()
                writer:write_tool_call_block(
                    make_tool_call_block("status-word", "pending")
                )
                writer:update_tool_call_block(
                    vim.tbl_extend(
                        "force",
                        { tool_call_id = "status-word" },
                        fields
                    ) --[[@as agentic.ui.MessageWriter.ToolCallBase]]
                )

                local text = table.concat(
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                    "\n"
                )
                assert.is_not_nil(text:find(" " .. word .. " ", 1, true))
                assert.is_nil(text:find("failed", 1, true))
            end)
        end

        for note, causes in pairs({
            ["read-only, grant"] = {
                { code = "read-only" },
                { code = "grant", subject = "/a" },
                { code = "grant", subject = "/b" },
            },
            ["fetch"] = { { code = "kind", subject = "fetch" } },
        }) do
            it("notes " .. note .. " in the footer", function()
                writer:write_tool_call_block(
                    make_tool_call_block("noted", "pending")
                )
                writer:update_tool_call_block({
                    tool_call_id = "noted",
                    status = "pending",
                    causes = causes,
                })
                local text = table.concat(
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                    "\n"
                )
                assert.is_not_nil(text:find("· " .. note .. " \n", 1, true))
            end)
        end

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

    describe("set_output_tail", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            local block = make_tool_call_block("bg", "completed")
            block.output_file = "/tmp/tasks/bg.output"
            writer:write_tool_call_block(block)
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        --- Rows of the block between the path row and the footer.
        --- @return string[]
        local function tail_rows()
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local path_row = row_of("/tmp/tasks/bg.output")
            assert.is_not_nil(path_row)
            ---@cast path_row integer
            local rows = {}
            -- Past the path row and the opening fence, up to the closing one.
            for i = path_row + 2, #lines do
                if lines[i]:match("^`+$") then
                    break
                end
                table.insert(rows, lines[i])
            end
            return rows
        end

        --- @return string
        local function footer()
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            for i = #lines, 1, -1 do
                if lines[i] ~= "" then
                    return lines[i]
                end
            end
            return ""
        end

        it("replaces the tail in place", function()
            writer:set_output_tail("bg", { "a", "b", "c" }, true)
            assert.same({ "a", "b", "c" }, tail_rows())

            writer:set_output_tail("bg", { "d" }, true)
            assert.same({ "d" }, tail_rows())
            assert.is_nil(row_of("a"))
        end)

        it("reads background while live and completed after", function()
            writer:set_output_tail("bg", { "a" }, true)
            assert.truthy(footer():find("background", 1, true))
            assert.equal("completed", writer.tool_call_blocks["bg"].status)

            writer:set_output_tail("bg", { "a", "b" }, false)
            assert.truthy(footer():find("completed", 1, true))
            assert.is_nil(footer():find("background", 1, true))
            assert.equal("completed", writer.tool_call_blocks["bg"].status)
        end)

        it("ignores an untracked call", function()
            writer:set_output_tail("other", { "a" }, true)
            assert.is_nil(row_of("a"))
        end)

        it("keeps a row joined under the block across a re-render", function()
            local ns_anchors = vim.api.nvim_create_namespace("agentic_anchors")
            local text = "`/hooks/guard.sh` · 30 ms"
            writer:write_hook_row({ text = text, tool_call_id = "bg" })

            --- Every mark on the hook row, by namespace, as
            --- `{ namespace = { "sign:<text>" | "hl:<group>" | "mark" } }`.
            --- @return table<integer, string[]> marks
            --- @return integer row 0-indexed
            local function marks_on_row()
                local row = (row_of("  " .. text) or 0) - 1
                assert.truthy(row >= 0)
                local out = {}
                for _, ns in ipairs({
                    Renderer.NS_DECORATIONS,
                    Renderer.NS_STATUS,
                    Renderer.NS_DIFF_HIGHLIGHTS,
                    ns_anchors,
                }) do
                    local found = {}
                    for _, mark in
                        ipairs(
                            vim.api.nvim_buf_get_extmarks(
                                bufnr,
                                ns,
                                { row, 0 },
                                { row, -1 },
                                { details = true }
                            )
                        )
                    do
                        local details = mark[4] or {}
                        local sign, hl = details.sign_text, details.hl_group
                        table.insert(
                            found,
                            sign and "sign:" .. sign
                                or hl and "hl:" .. hl
                                or "mark"
                        )
                    end
                    table.sort(found)
                    out[ns] = found
                end
                return out, row
            end

            local before, row_before = marks_on_row()

            writer:set_output_tail("bg", { "a", "b", "c" }, true)

            local after, row_after = marks_on_row()
            assert.same({
                [Renderer.NS_DECORATIONS] = {
                    "hl:AgenticDimmedBlock",
                    "sign:" .. Glyphs.HOOK .. " ",
                },
                [Renderer.NS_STATUS] = {},
                [Renderer.NS_DIFF_HIGHLIGHTS] = {},
                [ns_anchors] = { "mark" },
            }, before)
            assert.same(before, after)
            assert.truthy(row_after > row_before)
            assert.truthy(
                vim.api
                    .nvim_buf_get_lines(bufnr, row_after - 1, row_after, false)[1]
                    :find("background", 1, true)
            )
            assert.equal(
                row_after,
                vim.api.nvim_buf_get_extmark_by_id(
                    bufnr,
                    ns_anchors,
                    writer.tool_call_blocks["bg"].placed.mark_id,
                    {}
                )[1]
            )
            assert_one_sign_per_row()
        end)

        it(
            "reads stopped once another call stopped it, also while live",
            function()
                writer:set_output_tail("bg", { "a" }, true)
                writer:update_tool_call_block({
                    tool_call_id = "bg",
                    status = "completed",
                    stopped_by = "tc-stop",
                })

                assert.truthy(footer():find("stopped", 1, true))
                assert.is_nil(footer():find("background", 1, true))
            end
        )
    end)

    describe("tool_call_row", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("gives the head row of a tracked block, nil otherwise", function()
            writer:write_message_chunk(make_message_update("before"))
            writer:write_tool_call_block(
                make_tool_call_block("tc-a", "completed")
            )

            local row = writer:tool_call_row("tc-a")
            assert.is_not_nil(row)
            ---@cast row integer
            local head =
                vim.api.nvim_buf_get_lines(bufnr, row, row + 1, true)[1]
            assert.truthy(head:match("^###"))
            assert.is_nil(writer:tool_call_row("other"))
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
                assert.equal("###", lines_after_write[1])
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
                assert.equal("###", lines_after_update[1])
                assert.equal("```bash-foldnext", lines_after_update[2])

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

        it("finalize_turn reflow does not corrupt tool call block", function()
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
                if line == "###" then
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
            local decs =
                vim.api.nvim_buf_get_extmarks(bufnr, NS_DECORATIONS, 0, -1, {})
            assert.is_true(#decs > 0, "Decoration extmarks missing")
        end)

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
                    if line == "###" then
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

    describe("message chunk joining", function()
        it("appends each chunk exactly as received", function()
            writer:write_message_chunk(make_message_update("Java"))
            writer:write_message_chunk(make_message_update("Script is"))

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local last = lines[#lines] ~= "" and lines[#lines]
                or lines[#lines - 1]
            assert.truthy(
                last:find("JavaScript is"),
                "Chunks should join verbatim: " .. last
            )
        end)
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

    describe("block highlights", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        --- @return integer[] rows 0-indexed rows holding a search-term extmark
        local function term_rows()
            local ns = vim.api.nvim_create_namespace("agentic_diff_highlights")
            local rows = {}
            local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {
                details = true,
            })
            for _, m in ipairs(marks) do
                if m[4].hl_group == "AgenticSearchMatch" then
                    table.insert(rows, m[2])
                end
            end
            return rows
        end

        it("exist right after an update and follow inserted rows", function()
            writer:write_tool_call_block({
                tool_call_id = "grep-shift",
                status = "pending",
                kind = "execute",
                argument = "grep -n foo f",
            })
            writer:update_tool_call_block({
                tool_call_id = "grep-shift",
                status = "completed",
                body = { "12:foo" },
            })
            assert.equal(1, #term_rows())

            vim.bo[bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "a", "b", "c" })

            local rows = term_rows()
            assert.equal(1, #rows)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal("12:foo", lines[rows[1] + 1])
        end)

        it("leave no stale marks after a second update", function()
            writer:write_tool_call_block({
                tool_call_id = "grep-twice",
                status = "pending",
                kind = "execute",
                argument = "grep -n foo f",
            })
            writer:update_tool_call_block({
                tool_call_id = "grep-twice",
                status = "in_progress",
                body = { "12:foo" },
            })
            writer:update_tool_call_block({
                tool_call_id = "grep-twice",
                status = "completed",
                body = { "13:foo" },
            })

            -- The merged body holds both lines; a mark left by the first
            -- update would be a third.
            assert.equal(2, #term_rows())
        end)

        it("keeps a todowrite body and folds it closed", function()
            writer:write_tool_call_block({
                tool_call_id = "todo-1",
                status = "pending",
                kind = "TodoWrite",
                argument = "todos",
            })
            local body = { '{"todos": [{"content": "a"}, {"content": "b"}]}' }
            writer:update_tool_call_block({
                tool_call_id = "todo-1",
                status = "completed",
                body = body,
            })

            local tracker = writer.tool_call_blocks["todo-1"]
            assert.same(body, tracker.body)
            assert.is_false(tracker.folds[1].open)
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

                assert.equal("## Error", lines[1])
                assert.equal("Authentication required", lines[2])
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
            assert.equal(3, heading_ext[3]) -- col 3 (after "## ")
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
                if line == "## Error" then
                    found_heading = true
                end
                if line == "529 Overloaded." then
                    found_body = true
                end
            end
            assert.is_true(found_heading)
            assert.is_true(found_body)
        end)

        it("wraps the body at wrap_width", function()
            Config.windows.wrap_width = 58

            --- @type agentic.acp.ACPError
            local err = {
                code = -32603,
                message = "You've hit your individual spend limit · run"
                    .. " /usage-credits to ask your admin for a higher limit ·"
                    .. " your session limit resets 7:20pm (Europe/London)",
            }

            writer:write_error_message(err)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.equal("## Error", lines[1])
            assert.is_true(#lines > 3)
            for i = 2, #lines do
                assert.is_true(#lines[i] <= Config.windows.wrap_width)
            end
        end)

        it("signs the heading with the error glyph", function()
            writer:write_error_message({ code = 1, message = "boom" })

            local signs = vim.api.nvim_buf_get_extmarks(
                bufnr,
                Renderer.NS_DECORATIONS,
                0,
                -1,
                { details = true }
            )
            assert.equal(0, signs[1][2])
            assert.equal(Glyphs.ERROR .. " ", signs[1][4].sign_text)
            assert.equal(
                Theme.HL_GROUPS.ERROR_HEADING,
                signs[1][4].sign_hl_group
            )
        end)

        it("rails a multi-line error down to its last words", function()
            writer:write_error_message({
                code = 1,
                message = "first line\nsecond line",
            })

            -- ## Error / first line / second line / (blank)
            local signs = vim.api.nvim_buf_get_extmarks(
                bufnr,
                Renderer.NS_DECORATIONS,
                0,
                -1,
                { details = true }
            )
            local by_row = {}
            for _, mark in ipairs(signs) do
                by_row[mark[2]] = mark[4].sign_text
            end
            assert.equal(Glyphs.ERROR .. " ", by_row[0])
            assert.equal("│ ", by_row[1])
            assert.equal("╰─", by_row[2])
            assert.is_nil(by_row[3])
        end)

        -- The provider streams a fatal error as prose before returning it as
        -- the prompt's error, so these run against a hard-wrapping window: the
        -- prose copy reaches the buffer already broken across rows and the
        -- error copy does not, which is the whole reason the comparison
        -- collapses whitespace rather than matching the text raw.
        describe("deduplicating the streamed copy", function()
            --- The provider's own words, long enough to wrap at any sane width.
            local SAID = "You've hit your individual spend limit · run"
                .. " /usage-credits to ask your admin for a higher limit ·"
                .. " your session limit resets 7:20pm (Europe/London)"

            before_each(function()
                Config.windows.wrap_width = 58
            end)

            --- @param text string
            local function stream(text)
                writer:write_message_chunk({
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = text },
                })
            end

            --- @param line string
            --- @return integer
            local function count_rows(line)
                local n = 0
                for _, row in
                    ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
                do
                    n = n + (row == line and 1 or 0)
                end
                return n
            end

            it("drops the prose copy the provider streamed first", function()
                stream(SAID)
                local streamed_rows = vim.api.nvim_buf_line_count(bufnr)
                    - count_rows("")
                assert.is_true(streamed_rows > 1)

                writer:write_error_message({
                    code = -32603,
                    message = "Internal error: " .. SAID,
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.equal("## Error", lines[1])
                assert.equal(1, count_rows("## Error"))
                -- Same words, once, in the wrapped form the error block writes.
                assert.equal(
                    SAID,
                    table.concat(vim.list_slice(lines, 2, #lines - 1), " ")
                )
            end)

            it("leaves no sign behind on the rows it deletes", function()
                -- Two paragraphs, so the run earns a real ╭─/│/╰─ bracket
                -- before the error deletes the rows carrying it.
                stream("Here is the summary.\n\n" .. SAID)

                writer:write_error_message({
                    code = -32603,
                    message = "Internal error: " .. SAID,
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local heading_row = vim.fn.index(lines, "## Error")
                local signs = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    Renderer.NS_DECORATIONS,
                    0,
                    -1,
                    { details = true }
                )
                for _, mark in ipairs(signs) do
                    assert.is_true(mark[2] >= heading_row)
                end
            end)

            it("drops a copy the run opened a section break for", function()
                -- The run shape a real turn produces: a tool call interrupted
                -- the prose, so the next chunk opens on `###` and a blank.
                writer:write_tool_call_block({
                    tool_call_id = "t1",
                    kind = "read",
                    argument = "init.lua",
                    status = "completed",
                })
                stream(SAID)
                assert.is_true(
                    vim.fn.index(
                        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                        "###"
                    ) >= 0
                )

                writer:write_error_message({
                    code = -32603,
                    message = "Internal error: " .. SAID,
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local heading_row = vim.fn.index(lines, "## Error")
                assert.is_true(heading_row > 0)
                assert.equal(
                    SAID,
                    table.concat(
                        vim.list_slice(lines, heading_row + 2, #lines - 1),
                        " "
                    )
                )
            end)

            -- Wrapping rebuilds a line word by word with one space between, so
            -- any run of whitespace the provider sent survives in the error
            -- copy and not in the prose copy. The only difference the two can
            -- actually have, and the reason the match is not on raw text.
            it("drops a copy whose spacing the wrap collapsed", function()
                local spaced = SAID:gsub(" · ", "  ·  ")
                stream(spaced)

                writer:write_error_message({
                    code = -32603,
                    message = "Internal error: " .. spaced,
                })

                assert.equal(1, count_rows("## Error"))
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.equal("## Error", lines[1])
            end)

            it("keeps prose that says something else", function()
                stream("Running the tests now.")

                writer:write_error_message({
                    code = -32603,
                    message = "Internal error: the provider gave up",
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.same(
                    { "Running the tests now.", "", "## Error" },
                    vim.list_slice(lines, 1, 3)
                )
            end)

            it("keeps the paragraphs above the duplicated one", function()
                stream("Here is the summary.\n\n" .. SAID)

                writer:write_error_message({
                    code = -32603,
                    message = "Internal error: " .. SAID,
                })

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.equal("Here is the summary.", lines[1])
                assert.equal(1, count_rows("## Error"))

                local heading_row = vim.fn.index(lines, "## Error")
                assert.equal(
                    SAID,
                    table.concat(
                        vim.list_slice(lines, heading_row + 2, #lines - 1),
                        " "
                    )
                )
            end)
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

        local NS_ERROR = vim.api.nvim_create_namespace("agentic_error")
        local NS_ANCHORS = vim.api.nvim_create_namespace("agentic_anchors")

        it("appends action text with ERROR_BODY highlight", function()
            -- Pre-fill buffer so action appends
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "## Error", "", "401 Auth failed", "" }
            )

            writer:write_error_action("Run /login to re-authenticate.")

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            -- Action text should be appended after existing content
            local found = false
            for _, line in ipairs(lines) do
                if line == "Run /login to re-authenticate." then
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

        --- Row → sign text of every decoration mark in the chat buffer.
        --- @return table<integer, string>
        local function signs_by_row()
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                Renderer.NS_DECORATIONS,
                0,
                -1,
                { details = true }
            )
            local by_row = {}
            for _, mark in ipairs(marks) do
                by_row[mark[2]] = mark[4].sign_text
            end
            return by_row
        end

        --- 0-indexed rows carrying an ERROR_BODY highlight.
        --- @return integer[]
        local function error_body_rows()
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                NS_ERROR,
                0,
                -1,
                { details = true }
            )
            local rows = {}
            for _, mark in ipairs(marks) do
                if mark[4].hl_group == "AgenticErrorBody" then
                    table.insert(rows, mark[2])
                end
            end
            return rows
        end

        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        local ERROR = { code = 1, message = "out of credit" }
        local ACTION = "Auto-continuing in 3h 7m."

        it("puts a response directly under the error, dimmed", function()
            writer:write_error_message(ERROR)
            writer:write_error_action(ACTION)

            assert.same(
                { "## Error", "out of credit", ACTION, "" },
                buffer_lines()
            )
            local by_row = signs_by_row()
            assert.equal(Glyphs.ERROR .. " ", by_row[0])
            assert.equal("╰─", by_row[1])
            assert.is_nil(by_row[2])
            assert.same({ { 2, 3 } }, dim_ranges())
            assert.same({ 1 }, error_body_rows())
        end)

        it("joins after a row is placed above the error", function()
            writer:write_user_prompt("ask")
            writer:write_error_message(ERROR)
            writer:write_loaded_file({ path = "/r/a.md", after_prompt = true })
            writer:write_error_action(ACTION)

            local lines = buffer_lines()
            assert.same(
                { "## Error", "out of credit", ACTION, "" },
                vim.list_slice(lines, #lines - 3)
            )
            assert.same({ { #lines - 2, #lines - 1 } }, dim_ranges())
        end)

        it("flushes buffered thinking above a standalone action", function()
            writer:write_message_chunk(make_thought_update("a\nb"))
            writer:write_error_action(ACTION)

            local lines = buffer_lines()
            assert.same(
                { "```", "", ACTION, "" },
                vim.list_slice(lines, #lines - 3)
            )
        end)

        it("keeps several responses contiguous and in order", function()
            Config.windows.wrap_width = 30
            writer:write_error_message(ERROR)
            writer:write_error_action(
                "Prompt returned to the input. Edit and send it again."
            )
            writer:write_error_action("1 queued prompt left as draft.")

            local lines = buffer_lines()
            assert.equal("out of credit", lines[2])
            assert.equal("1 queued prompt left as draft.", lines[#lines - 1])
            assert.equal("", lines[#lines])
            for i = 3, #lines - 1 do
                assert.is_true(lines[i] ~= "")
            end
            assert.same(
                { { 2, #lines - 2 }, { #lines - 2, #lines - 1 } },
                dim_ranges()
            )
        end)

        --- Assert `ACTION` stands alone at the end: after one blank, in the
        --- error style, with no sign and no dim.
        local function assert_standalone()
            local lines = buffer_lines()
            assert.same({ "", ACTION, "" }, vim.list_slice(lines, #lines - 2))
            local action_row = #lines - 2
            assert.is_nil(signs_by_row()[action_row])
            assert.is_true(vim.tbl_contains(error_body_rows(), action_row))
            for _, range in ipairs(dim_ranges()) do
                assert.is_true(range[2] <= action_row)
            end
        end

        it("stands alone after the turn ends", function()
            writer:write_error_message(ERROR)
            writer:finalize_turn()
            writer:write_error_action(ACTION)

            assert.same(
                { "## Error", "out of credit", "", ACTION, "" },
                buffer_lines()
            )
            assert_standalone()
            assert.same(
                {},
                vim.api.nvim_buf_get_extmarks(bufnr, NS_ANCHORS, 0, -1, {})
            )
        end)

        it("stands alone after a refresh", function()
            writer:write_error_message(ERROR)
            writer:reset_turn_state()
            writer:write_error_action(ACTION)

            assert_standalone()
        end)

        it("stands alone after prose", function()
            writer:write_error_message(ERROR)
            writer:write_message_chunk(make_message_update("Retrying."))
            writer:write_error_action(ACTION)

            assert_standalone()
        end)

        it("stands alone after a tool call", function()
            writer:write_error_message(ERROR)
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:write_error_action(ACTION)

            assert_standalone()
        end)

        it("joins only the second of two errors", function()
            writer:write_error_message(ERROR)
            writer:write_error_message({ code = 1, message = "again" })
            writer:write_error_action(ACTION)

            assert.same({
                "## Error",
                "out of credit",
                "",
                "## Error",
                "again",
                ACTION,
                "",
            }, buffer_lines())
            assert.equal(
                1,
                #vim.api.nvim_buf_get_extmarks(bufnr, NS_ANCHORS, 0, -1, {})
            )
        end)

        it("stands alone once something else has been written", function()
            writer:write_error_message({ code = 1, message = "out of credit" })
            writer:write_user_prompt("try again")
            writer:write_error_action("Auto-continuing in 3h 7m.")

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local action_row = vim.fn.index(lines, "Auto-continuing in 3h 7m.")
            assert.is_true(action_row > 0)
            assert.is_nil(signs_by_row()[action_row])
        end)

        it("wraps a long action at wrap_width", function()
            Config.windows.wrap_width = 58
            writer:write_error_message({ code = 1, message = "out of credit" })

            writer:write_error_action(
                "Auto-continue gave up after 3 attempts. Send a message"
                    .. " manually when usage resets."
            )

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_true(#lines > 4)
            for _, line in ipairs(lines) do
                assert.is_true(#line <= Config.windows.wrap_width)
            end
        end)
    end)

    describe("block spacing", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        --- @param text string
        local function prose(text)
            writer:write_message_chunk(make_message_update(text))
        end

        --- Assert exactly one blank row separates 1-indexed `row` from the
        --- row with text above it.
        --- @param row integer
        local function assert_one_blank_above(row)
            local lines = buffer_lines()
            assert.equal("", lines[row - 1])
            assert.is_true(lines[row - 2]:match("%S") ~= nil)
        end

        it("puts one blank between a prompt and its reply", function()
            writer:write_user_prompt("ask")
            prose("Answer.")

            assert.same({ "## ask", "", "Answer." }, buffer_lines())
        end)

        it("drops the blank lines a reply starts with", function()
            writer:write_user_prompt("ask")
            prose("\n\nAnswer.")

            assert.same({ "## ask", "", "Answer." }, buffer_lines())
        end)

        it("drops the blank lines a message starts with", function()
            writer:write_user_prompt("ask")
            writer:write_message(make_message_update("\n\nPara."))

            assert.same({ "## ask", "", "Para.", "" }, buffer_lines())
        end)

        it("puts one blank between a block and the prose after it", function()
            local writes = {
                thinking = function()
                    writer:write_message_chunk(make_thought_update("a\nb"))
                end,
                hook = function()
                    writer:write_hook_block({ body = { "a", "b" } })
                end,
                notice = function()
                    writer:write_notice({
                        glyph = "x",
                        title = "n",
                        mid_turn = true,
                    })
                end,
            }
            for _, write in pairs(writes) do
                writer:reset()
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
                writer:write_user_prompt("ask")
                write()
                prose("Answer.")

                local lines = buffer_lines()
                assert.equal("Answer.", lines[#lines])
                assert_one_blank_above(#lines)
            end
        end)

        it("puts one blank between prose and a tool call", function()
            writer:write_user_prompt("ask")
            prose("Looking.")
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )

            assert_one_blank_above(writer:tool_call_row("t1") + 1)
        end)

        it("drops the blank rows prose ends with", function()
            prose("Looking.\n\n")
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )

            assert.equal(3, writer:tool_call_row("t1") + 1)
            assert_one_blank_above(3)
        end)

        it("sets the section close off by one blank each side", function()
            writer:write_user_prompt("ask")
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            prose("Answer.")

            local lines = buffer_lines()
            assert.same(
                { "", "###", "", "Answer." },
                vim.list_slice(lines, #lines - 3)
            )
            assert_one_blank_above(#lines - 2)
        end)

        it("puts one blank before the next prompt", function()
            local turns = {
                prose = function()
                    prose("Done.")
                end,
                tool_call = function()
                    writer:write_tool_call_block(
                        make_tool_call_block("t1", "completed")
                    )
                end,
                thinking = function()
                    writer:write_message_chunk(make_thought_update("a\nb"))
                end,
                hook_row = function()
                    writer:write_hook_row({ text = "ran" })
                end,
                nothing = function() end,
            }
            for _, turn in pairs(turns) do
                writer:reset()
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
                writer:write_user_prompt("ask")
                turn()
                writer:finalize_turn()
                writer:write_user_prompt("next")

                assert_one_blank_above(row_of("## next") --[[@as integer]])
            end
        end)

        it("keeps the usage note on the last row", function()
            local NS_TURN_USAGE =
                vim.api.nvim_create_namespace("agentic_turn_usage")
            writer:write_user_prompt("ask")
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            prose("Done.")
            writer:finalize_turn()
            writer:set_turn_usage({ inputTokens = 1, outputTokens = 1 })

            local function assert_note_last()
                local lines = buffer_lines()
                local marks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    NS_TURN_USAGE,
                    0,
                    -1,
                    {}
                )
                assert.equal(1, #marks)
                assert.equal(#lines - 1, marks[1][2])
                assert.same({ "Done.", "" }, vim.list_slice(lines, #lines - 1))
            end

            assert_note_last()
            writer:write_hook_block({ tool_call_id = "t1", body = { "a", "b" } })
            assert_note_last()
            writer:write_hook_row({ tool_call_id = "t1", text = "ran" })
            assert_note_last()
            writer:write_loaded_file({ path = "/r/a.md", after_prompt = true })
            assert_note_last()
        end)

        it("ends the prose run at an error action", function()
            local NS_ERROR = vim.api.nvim_create_namespace("agentic_error")
            prose("One.")
            writer:write_error_action("Note.")
            prose("Two.\n\nThree.")
            writer:finalize_turn()

            assert.same(
                { "One.", "", "Note.", "", "Two.", "", "Three.", "" },
                buffer_lines()
            )
            local marks =
                vim.api.nvim_buf_get_extmarks(bufnr, NS_ERROR, 0, -1, {})
            assert.equal(1, #marks)
            assert.equal(2, marks[1][2])
        end)

        it("ends the prose run at a message", function()
            prose("One.")
            writer:write_message(make_message_update("**Loaded X**"))
            prose("Two.")
            writer:finalize_turn()

            assert.same(
                { "One.", "", "**Loaded X**", "", "Two.", "" },
                buffer_lines()
            )
        end)

        it("drops the blank lines a message ends with", function()
            writer:write_message(make_message_update("Para.\n\n"))
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )

            assert.equal(3, writer:tool_call_row("t1") + 1)
            assert_one_blank_above(3)
        end)
    end)

    describe("nonfinal_tool_call_ids", function()
        it("returns the ids whose status can still change", function()
            for id, status in pairs({
                still_pending = "pending",
                running = "in_progress",
                done = "completed",
                broke = "failed",
                -- Saved by earlier versions.
                stopped = "cancelled",
            }) do
                --- @diagnostic disable-next-line: param-type-mismatch
                writer:write_tool_call_block(make_tool_call_block(id, status))
            end
            -- An adapter may pass a tracker through with no status at all.
            --- @diagnostic disable-next-line: missing-fields
            writer:write_tool_call_block({
                tool_call_id = "unreported",
                kind = "execute",
                argument = "ls",
            })

            local ids = writer:nonfinal_tool_call_ids()
            table.sort(ids)
            assert.same({ "running", "still_pending", "unreported" }, ids)
        end)
    end)

    describe("stamp_open_calls", function()
        before_each(function()
            writer:write_tool_call_block(
                make_tool_call_block("running", "pending")
            )
            writer:write_tool_call_block(
                make_tool_call_block("done", "completed")
            )
        end)

        it("stamps the non-final blocks and returns the updates", function()
            local updates = writer:stamp_open_calls("max_tokens", "failed")

            assert.same({
                {
                    tool_call_id = "running",
                    status = "failed",
                    ended_as = "max_tokens",
                },
            }, updates)
            assert.equal("failed", writer.tool_call_blocks.running.status)
            assert.equal("completed", writer.tool_call_blocks.done.status)
            assert.is_nil(writer.tool_call_blocks.done.ended_as)
        end)

        it("keeps the status without one", function()
            writer:stamp_open_calls("interrupted")

            local block = writer.tool_call_blocks.running
            assert.equal("pending", block.status)
            assert.equal("interrupted", block.ended_as)
        end)

        it("leaves a subagent's launch block alone", function()
            local launch = make_tool_call_block("launch", "pending")
            launch.kind = "SubAgent"
            launch.subagent =
                { label = "find it", mode = "blocking", confirmed = false }
            writer:write_tool_call_block(launch)

            local updates = writer:stamp_open_calls("max_tokens", "failed")

            assert.same(
                { "running" },
                vim.tbl_map(function(update)
                    return update.tool_call_id
                end, updates)
            )
            assert.equal("pending", writer.tool_call_blocks.launch.status)
            assert.is_nil(writer.tool_call_blocks.launch.ended_as)
        end)

        it("keeps a block's first end word", function()
            writer:stamp_open_calls("interrupted")
            local updates = writer:stamp_open_calls("ended", "failed")

            assert.equal("interrupted", updates[1].ended_as)
            assert.equal(
                "interrupted",
                writer.tool_call_blocks.running.ended_as
            )
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
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            -- Fold ops, and the fold levels they act on, land in scheduled
            -- callbacks. Each test drains them.
            deferred = Deferred.capture()

            -- The chat buffer parses as the private `agentic` language so its
            -- folds query (queries/agentic/folds.scm) drives folding. Mirror
            -- the runtime setup from bootstrap.lua / chat_buffer /
            -- widget_layout.
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
            vim.wo[winid].foldexpr =
                'v:lua.require("agentic.ui.folds").foldexpr()'
            vim.wo[winid].foldenable = true
            vim.wo[winid].foldlevel = 99
            vim.wo[winid].foldminlines = 1
        end)

        after_each(function()
            deferred.revert()
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

        --- Buffer lines (1-indexed) carrying an opening fence whose info
        --- string ends in `suffix`.
        --- @param suffix string
        --- @return integer[]
        local function fence_lines(suffix)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local fences = {}
            for i, line in ipairs(lines) do
                if line:match("^`+[%w]+%-" .. suffix .. "$") then
                    table.insert(fences, i)
                end
            end
            return fences
        end

        --- Buffer lines (1-indexed) carrying a `*-fold` opening fence.
        --- @return integer[]
        local function fold_fence_lines()
            return fence_lines("fold")
        end

        --- First rows of each execute block's command and output folds, for
        --- blocks that all have both.
        --- @return { command: integer, output: integer }[]
        local function execute_folds()
            local outputs = fold_fence_lines()
            local folds = {}
            for i, fence in ipairs(fence_lines("foldnext")) do
                folds[i] = { command = fence + 1, output = outputs[i] + 1 }
            end
            return folds
        end

        it("closes the output fold of a long execute body", function()
            writer:write_tool_call_block({
                tool_call_id = "fold-1",
                status = "completed",
                kind = "execute",
                argument = "build",
                body = long_execute_body(),
            })

            local folds = execute_folds()
            assert.equal(1, #folds)
            deferred.drain()
            -- The fold spans code_fence_content only, so it starts on the
            -- first body line — not the conceal_lines-hidden delimiter. That
            -- keeps the `··· N lines ···` foldtext on a visible screen row.
            -- foldclosed returns the fold's first line for any line inside it.
            assert.equal(folds[1].output, vim.fn.foldclosed(folds[1].output))
            -- The opening delimiter lies outside the output fold.
            assert.equal(-1, vim.fn.foldclosed(folds[1].output - 1))
            assert.equal(-1, vim.fn.foldclosed(folds[1].command))
        end)

        it("closes a read-only command over its closed output", function()
            writer:write_tool_call_block({
                tool_call_id = "fold-ro",
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = long_execute_body(),
            })

            local fold = execute_folds()[1]
            deferred.drain()
            assert.equal(fold.command, vim.fn.foldclosed(fold.output))
            assert.is_nil(
                require("agentic.utils.buf_helpers").set_fold(
                    winid,
                    fold.command,
                    true
                )
            )
            assert.equal(fold.output, vim.fn.foldclosed(fold.output))
        end)

        it("closes the fold over a thought run", function()
            writer:write_message_chunk(
                make_thought_update("first\nsecond\nthird")
            )
            writer:finalize_turn()

            local fences = fold_fence_lines()
            assert.equal(1, #fences)
            local body_start = fences[1] + 1
            deferred.drain()
            assert.equal(body_start, vim.fn.foldclosed(body_start))
        end)

        it(
            "opens both folds of a short command that is not read-only",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "fold-short",
                    status = "completed",
                    kind = "execute",
                    argument = "build",
                    body = { "output 1", "output 2" },
                })

                local folds = execute_folds()
                assert.equal(1, #folds)
                deferred.drain()
                assert.equal(-1, vim.fn.foldclosed(folds[1].command))
                assert.equal(-1, vim.fn.foldclosed(folds[1].output))
            end
        )

        it(
            "closes the output fold when the body grows past the threshold",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "fold-grow",
                    status = "in_progress",
                    kind = "execute",
                    argument = "build",
                    body = { "starting", "still starting" },
                })
                deferred.drain()
                assert.equal(-1, vim.fn.foldclosed(execute_folds()[1].output))

                writer:update_tool_call_block({
                    tool_call_id = "fold-grow",
                    status = "completed",
                    body = long_execute_body(),
                })

                local fold = execute_folds()[1]
                deferred.drain()
                assert.equal(fold.output, vim.fn.foldclosed(fold.output))
                assert.equal(-1, vim.fn.foldclosed(fold.command))
            end
        )

        it(
            "keeps a fold the user closed across a status update and a replay",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "fold-user",
                    status = "in_progress",
                    kind = "execute",
                    argument = "build",
                    body = long_execute_body(),
                })
                local fold = execute_folds()[1]
                deferred.drain()
                vim.api.nvim_win_call(winid, function()
                    vim.cmd(fold.command .. "foldclose")
                end)

                writer:update_tool_call_block({
                    tool_call_id = "fold-user",
                    status = "completed",
                })
                deferred.drain()
                local other = vim.api.nvim_open_win(bufnr, false, {
                    relative = "editor",
                    width = 40,
                    height = 10,
                    row = 0,
                    col = 0,
                })
                vim.wo[other].foldlevel = 99
                vim.wo[other].foldminlines = 1
                writer:replay_folds(other)

                assert.equal(fold.command, vim.fn.foldclosed(fold.command))
                vim.api.nvim_win_call(other, function()
                    assert.equal(-1, vim.fn.foldclosed(fold.command))
                    assert.equal(fold.output, vim.fn.foldclosed(fold.output))
                end)
                vim.api.nvim_win_close(other, true)
            end
        )

        it("opens only the outer fold of a revealed block", function()
            writer:write_tool_call_block({
                tool_call_id = "fold-reveal",
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = long_execute_body(),
            })
            local fold = execute_folds()[1]
            deferred.drain()

            writer:hold_tool_call("fold-reveal", true)
            deferred.drain()
            assert.equal(-1, vim.fn.foldclosed(fold.command))
            assert.equal(fold.output, vim.fn.foldclosed(fold.output))

            writer:release_hold()
            deferred.drain()
            assert.equal(fold.command, vim.fn.foldclosed(fold.command))
        end)

        it("opens the outer fold on a status-only update to failed", function()
            writer:write_tool_call_block({
                tool_call_id = "fold-fail",
                status = "in_progress",
                kind = "execute",
                argument = "ls",
                body = { "out 1", "out 2" },
            })
            local fold = execute_folds()[1]
            deferred.drain()
            assert.equal(fold.command, vim.fn.foldclosed(fold.command))

            writer:update_tool_call_block({
                tool_call_id = "fold-fail",
                status = "failed",
            })
            deferred.drain()

            assert.equal(fold.command, execute_folds()[1].command)
            assert.equal(-1, vim.fn.foldclosed(fold.command))
            assert.equal(-1, vim.fn.foldclosed(fold.output))
        end)

        for _, case in ipairs({
            { status = "completed", command_closed = true },
            { status = "failed", command_closed = false },
        }) do
            it("folds a long " .. case.status .. " search", function()
                local rows = {}
                for i = 1, Config.tool_call_display.search_max_lines + 1 do
                    rows[i] = "match " .. i
                end
                writer:write_tool_call_block({
                    tool_call_id = "fold-search-" .. case.status,
                    status = case.status,
                    kind = "search",
                    argument = "rg foo",
                    body = case.status == "completed" and rows or nil,
                    failure_reason = case.status == "failed" and rows or nil,
                })
                local fold = execute_folds()[1]
                deferred.drain()

                assert.equal(
                    case.command_closed and fold.command or -1,
                    vim.fn.foldclosed(fold.command)
                )
                assert.is_nil(
                    require("agentic.utils.buf_helpers").set_fold(
                        winid,
                        fold.command,
                        true
                    )
                )
                assert.equal(fold.output, vim.fn.foldclosed(fold.output))
            end)
        end

        it("produces two distinct closed folds for adjacent blocks", function()
            writer:write_tool_call_block({
                tool_call_id = "fold-adj-1",
                status = "completed",
                kind = "execute",
                argument = "build",
                body = long_execute_body(),
            })
            writer:write_tool_call_block({
                tool_call_id = "fold-adj-2",
                status = "completed",
                kind = "execute",
                argument = "make",
                body = long_execute_body(),
            })

            local fences = fold_fence_lines()
            assert.equal(2, #fences)
            deferred.drain()
            -- Two separate folds: each body-start line reports itself as its
            -- fold start. A merged fold would make the second report the first.
            assert.equal(fences[1] + 1, vim.fn.foldclosed(fences[1] + 1))
            assert.equal(fences[2] + 1, vim.fn.foldclosed(fences[2] + 1))
        end)

        it("closes a long execute body in the update that adds it", function()
            writer:write_tool_call_block({
                tool_call_id = "fold-status",
                status = "pending",
                kind = "execute",
                argument = "build",
            })
            writer:update_tool_call_block({
                tool_call_id = "fold-status",
                status = "in_progress",
                body = long_execute_body(),
            })
            local body_start = fold_fence_lines()[1] + 1
            deferred.drain()
            assert.equal(body_start, vim.fn.foldclosed(body_start))

            writer:update_tool_call_block({
                tool_call_id = "fold-status",
                status = "completed",
            })
            assert.same({}, writer._pending_fold_ops)
        end)

        it("closes a fold rendered below one the user opened", function()
            writer:write_tool_call_block({
                tool_call_id = "below-open-1",
                status = "completed",
                kind = "execute",
                argument = "build",
                body = long_execute_body(),
            })
            local first_body = fold_fence_lines()[1] + 1
            deferred.drain()
            vim.api.nvim_win_call(winid, function()
                vim.cmd(first_body .. "foldopen")
            end)

            writer:write_tool_call_block({
                tool_call_id = "below-open-2",
                status = "completed",
                kind = "execute",
                argument = "make",
                body = long_execute_body(),
            })
            local second_body = fold_fence_lines()[2] + 1
            deferred.drain()
            assert.equal(second_body, vim.fn.foldclosed(second_body))
            assert.equal(-1, vim.fn.foldclosed(first_body))
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

        --- 1-indexed line of the first diff fence, labelled `text`.
        --- @return integer line
        local function diff_fence_line()
            for i, line in
                ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
            do
                if line:match("^`+text%-") then
                    return i
                end
            end
            error("no diff fence in buffer")
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

        it(
            "folds an edit diff as ONE block with no injected sub-folds",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "diff-onefold",
                    status = "completed",
                    kind = "create",
                    argument = "/tmp/agentic_diff_probe.lua",
                    diff = { old = {}, new = diff_new },
                })

                local fence = diff_fence_line()
                local body_start = fence + 1
                local body_end = closing_fence_after(fence) - 1
                deferred.drain()

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
            end
        )

        it("leaves an applied edit diff foldable but open", function()
            writer:write_tool_call_block({
                tool_call_id = "diff-open",
                status = "completed",
                kind = "create",
                argument = "/tmp/agentic_diff_open.lua",
                diff = { old = {}, new = diff_new },
            })

            local body_start = diff_fence_line() + 1
            deferred.drain()
            -- Foldable (level 1) and explicitly opened for a non-failed edit,
            -- so `zc` works but nothing is collapsed.
            assert.equal(1, vim.fn.foldlevel(body_start))
            assert.equal(-1, vim.fn.foldclosed(body_start))
        end)

        it(
            "closes the diff and shows the reason when the edit fails",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "diff-fail",
                    status = "failed",
                    kind = "edit",
                    argument = "/tmp/agentic_diff_fail.lua",
                    diff = { old = { "stub" }, new = diff_new },
                    failure_reason = { "User refused permission to run tool" },
                })

                local fence = diff_fence_line()
                assert.is_not_nil(fence)
                local body_start = fence + 1
                deferred.drain()
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
            end
        )

        it(
            "closes the diff and appends the reason on the in_progress→failed transition",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "diff-trans",
                    status = "in_progress",
                    kind = "edit",
                    argument = "/tmp/agentic_diff_trans.lua",
                    diff = { old = { "stub" }, new = diff_new },
                })
                -- Open while in progress.
                assert.equal(-1, vim.fn.foldclosed(diff_fence_line() + 1))

                writer:update_tool_call_block({
                    tool_call_id = "diff-trans",
                    status = "failed",
                    failure_reason = { "Load /coding skill first." },
                })

                local fence = diff_fence_line()
                assert.is_not_nil(fence)
                deferred.drain()
                -- Folds closed after the failed transition.
                assert.equal(fence + 1, vim.fn.foldclosed(fence + 1))

                -- The diff was not discarded: its content survives the transition,
                -- and the reason is appended beneath it.
                local text = table.concat(
                    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                    "\n"
                )
                assert.is_not_nil(text:find("local function foo()", 1, true))
                assert.is_not_nil(
                    text:find("Load /coding skill first.", 1, true)
                )
            end
        )

        it(
            "shows a saved cancel as interrupted, leaving the diff open",
            function()
                --- @return string
                local function buffer_text()
                    return table.concat(
                        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
                        "\n"
                    )
                end

                writer:write_tool_call_block({
                    tool_call_id = "diff-cancel",
                    status = "in_progress",
                    kind = "edit",
                    argument = "/tmp/agentic_diff_cancel.lua",
                    diff = { old = { "stub" }, new = diff_new },
                })
                local fence = diff_fence_line()
                assert.equal(-1, vim.fn.foldclosed(fence + 1))
                assert.is_not_nil(buffer_text():find("in_progress", 1, true))

                writer:update_tool_call_block({
                    tool_call_id = "diff-cancel",
                    --- @diagnostic disable-next-line: assign-type-mismatch
                    status = "cancelled",
                })

                -- The footer word is the whole reported symptom.
                local text = buffer_text()
                assert.is_not_nil(text:find("interrupted", 1, true))
                assert.is_nil(text:find("in_progress", 1, true))

                -- A cancellation can have hit disk mid-flight, so `cancelled` takes
                -- the highlight-only path: the diff is neither re-extracted from
                -- the file nor folded away, as a `failed` edit's is.
                assert.is_not_nil(text:find("local function foo()", 1, true))
                assert.equal(fence, diff_fence_line())
                deferred.drain()
                assert.equal(-1, vim.fn.foldclosed(fence + 1))
            end
        )

        for _, first_status in ipairs({ "pending", "completed" }) do
            it(
                "opens an applied edit diff appended after a closed fold, first written at "
                    .. first_status,
                function()
                    -- A closed fold poisons foldexpr: a fold created afterwards
                    -- inherits the closed state. The applied edit must come up
                    -- open anyway (regression for the rejected-edit fold leak).
                    writer:write_tool_call_block({
                        tool_call_id = "leak-exec",
                        status = "completed",
                        kind = "execute",
                        argument = "ls",
                        body = long_execute_body(),
                    })
                    local exec_fence = fence_lines("foldnext")[1]
                    deferred.drain()
                    assert.equal(
                        exec_fence + 1,
                        vim.fn.foldclosed(exec_fence + 1)
                    )

                    writer:write_tool_call_block({
                        tool_call_id = "leak-edit",
                        status = first_status,
                        kind = "create",
                        argument = "/tmp/agentic_diff_leak.lua",
                        diff = { old = {}, new = diff_new },
                    })
                    local edit_body = diff_fence_line() + 1
                    deferred.drain()
                    if first_status == "pending" then
                        writer:update_tool_call_block({
                            tool_call_id = "leak-edit",
                            status = "completed",
                        })
                        deferred.drain()
                    end
                    -- Foldable but open despite the preceding closed fold.
                    assert.equal(-1, vim.fn.foldclosed(edit_body))
                    -- The earlier execute fold stays closed.
                    assert.equal(
                        exec_fence + 1,
                        vim.fn.foldclosed(exec_fence + 1)
                    )
                end
            )
        end

        --- 1-indexed first body row of the hook block titled `title`.
        --- @param title string
        --- @return integer
        local function hook_body_row(title)
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            for i, line in ipairs(lines) do
                if line == title then
                    return i
                end
            end
            error("no hook block titled " .. title)
        end

        for _, anchored in ipairs({ false, true }) do
            it(
                "opens a failed hook block after a closed one"
                    .. (anchored and ", under its call" or ""),
                function()
                    local id = anchored and "anchor" or nil
                    if anchored then
                        writer:write_tool_call_block({
                            tool_call_id = "anchor",
                            status = "completed",
                            kind = "execute",
                            argument = "ls",
                            body = { "out" },
                        })
                    end
                    writer:write_hook_block({
                        body = { "one", "two", "three" },
                        title = "ok.sh",
                        tool_call_id = id,
                    })
                    -- Closed before the failed block's fold exists, which is
                    -- what lets the new fold inherit the closed state.
                    deferred.drain()
                    writer:write_hook_block({
                        body = { "exited 127", "not found", "at line 3" },
                        title = "bad.sh",
                        tool_call_id = id,
                        failed = true,
                    })
                    deferred.drain()

                    local ok_row = hook_body_row("ok.sh")
                    assert.equal(ok_row, vim.fn.foldclosed(ok_row))
                    assert.equal(-1, vim.fn.foldclosed(hook_body_row("bad.sh")))
                end
            )
        end

        it("closes a subagent block at spawn", function()
            writer:write_tool_call_block({
                tool_call_id = "spawn-exec",
                status = "completed",
                kind = "execute",
                argument = "ls",
                body = long_execute_body(),
            })
            writer:write_tool_call_block({
                tool_call_id = "spawn-edit",
                status = "pending",
                kind = "create",
                argument = "/tmp/agentic_diff_spawn.lua",
                diff = { old = {}, new = diff_new },
            })
            deferred.drain()
            writer:update_tool_call_block({
                tool_call_id = "spawn-edit",
                status = "completed",
            })
            deferred.drain()

            writer:write_tool_call_block({
                tool_call_id = "spawn-agent",
                status = "in_progress",
                kind = "SubAgent",
                argument = "finder",
                body = { "first", "", "second", "", "third" },
                subagent = {
                    label = "finder",
                    mode = "blocking",
                    confirmed = true,
                },
            })
            -- Folds in order: the execute output, the edit diff, the subagent.
            local body_start = fold_fence_lines()[3] + 1
            deferred.drain()
            assert.equal(body_start, vim.fn.foldclosed(body_start))
        end)

        it(
            "keeps a subagent prompt the user opened through completion",
            function()
                writer:write_tool_call_block({
                    tool_call_id = "spawn-reopen",
                    status = "in_progress",
                    kind = "SubAgent",
                    argument = "finder",
                    body = { "first", "", "second", "", "third" },
                    subagent = {
                        label = "finder",
                        mode = "blocking",
                        confirmed = true,
                    },
                })
                local body_start = fold_fence_lines()[1] + 1
                deferred.drain()
                assert.equal(body_start, vim.fn.foldclosed(body_start))

                vim.api.nvim_win_call(winid, function()
                    vim.cmd(body_start .. "foldopen")
                end)
                writer:update_tool_call_block({
                    tool_call_id = "spawn-reopen",
                    status = "completed",
                })
                deferred.drain()
                assert.equal(-1, vim.fn.foldclosed(body_start))
            end
        )

        describe("large created file", function()
            --- @type integer|nil
            local original

            before_each(function()
                original = Config.tool_call_display.create_max_lines
                Config.tool_call_display.create_max_lines = 3
            end)

            after_each(function()
                Config.tool_call_display.create_max_lines = original
            end)

            --- Write a pending large create and return its first body line.
            --- @param id string
            --- @return integer body_start
            local function write_large_create(id)
                writer:write_tool_call_block({
                    tool_call_id = id,
                    status = "pending",
                    kind = "create",
                    argument = "/tmp/agentic_diff_" .. id .. ".lua",
                    diff = { old = {}, new = diff_new },
                })
                return diff_fence_line() + 1
            end

            it("is closed at render", function()
                local body_start = write_large_create("create-large")
                deferred.drain()
                assert.equal(body_start, vim.fn.foldclosed(body_start))
            end)

            it("opens under a revealing hold placed after render", function()
                local body_start = write_large_create("hold-after")
                deferred.drain()

                writer:hold_tool_call("hold-after", true)
                deferred.drain()
                assert.equal(-1, vim.fn.foldclosed(body_start))

                writer:release_hold()
                deferred.drain()
                assert.equal(body_start, vim.fn.foldclosed(body_start))
            end)

            it("opens under a revealing hold placed before render", function()
                writer:hold_tool_call("hold-before", true)
                local body_start = write_large_create("hold-before")
                deferred.drain()
                assert.equal(-1, vim.fn.foldclosed(body_start))

                writer:release_hold()
                deferred.drain()
                assert.equal(body_start, vim.fn.foldclosed(body_start))
            end)

            it("moves the reveal with a new hold", function()
                write_large_create("hold-a")
                write_large_create("hold-b")
                local bodies = {}
                for i, line in
                    ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
                do
                    if line:match("^`+text%-") then
                        table.insert(bodies, i + 1)
                    end
                end
                writer:hold_tool_call("hold-a", true)
                deferred.drain()
                assert.equal(-1, vim.fn.foldclosed(bodies[1]))

                writer:hold_tool_call("hold-b", true)
                deferred.drain()
                assert.equal(bodies[1], vim.fn.foldclosed(bodies[1]))
                assert.equal(-1, vim.fn.foldclosed(bodies[2]))
            end)

            it("stays closed under a hold that does not reveal", function()
                write_large_create("hold-quiet")
                deferred.drain()

                writer:hold_tool_call("hold-quiet", false)
                assert.same({}, writer._pending_fold_ops)
            end)
        end)

        it("closes an open edit that re-renders as failed", function()
            writer:write_tool_call_block({
                tool_call_id = "fail-reason",
                status = "pending",
                kind = "edit",
                argument = "/tmp/agentic_diff_reason.lua",
                diff = { old = { "stub" }, new = diff_new },
            })
            local body_start = diff_fence_line() + 1
            deferred.drain()
            assert.equal(-1, vim.fn.foldclosed(body_start))

            writer:update_tool_call_block({
                tool_call_id = "fail-reason",
                status = "failed",
                failure_reason = { "rejected" },
            })
            deferred.drain()
            body_start = diff_fence_line() + 1
            assert.equal(body_start, vim.fn.foldclosed(body_start))
        end)

        it("keeps the open diff of an edit its run's end closed", function()
            writer:write_tool_call_block({
                tool_call_id = "fail-ended",
                status = "in_progress",
                kind = "edit",
                argument = "/tmp/agentic_diff_ended.lua",
                diff = { old = { "stub" }, new = diff_new },
            })
            deferred.drain()
            local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

            writer:stamp_open_calls("interrupted", "failed")
            deferred.drain()

            local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            -- All but the footer and the trailing row.
            assert.same(
                vim.list_slice(before, 1, #before - 2),
                vim.list_slice(after, 1, #after - 2)
            )
            assert.equal(" 󰓛 interrupted ", after[#after - 1])
            local body_start = diff_fence_line() + 1
            assert.equal(-1, vim.fn.foldclosed(body_start))
        end)

        it("closes a failed edit that has no reason", function()
            writer:write_tool_call_block({
                tool_call_id = "fail-no-reason",
                status = "pending",
                kind = "edit",
                argument = "/tmp/agentic_diff_noreason.lua",
                diff = { old = { "stub" }, new = diff_new },
            })
            local body_start = diff_fence_line() + 1
            deferred.drain()
            assert.equal(-1, vim.fn.foldclosed(body_start))

            writer:update_tool_call_block({
                tool_call_id = "fail-no-reason",
                status = "failed",
            })
            deferred.drain()
            assert.is_not_nil(
                vim.api
                    .nvim_buf_get_lines(bufnr, body_start - 2, body_start - 1, false)[1]
                    :match("^`+text%-fold$")
            )
            assert.equal(body_start, vim.fn.foldclosed(body_start))
        end)

        it("folds a failed one-row diff together with its reason", function()
            writer:write_tool_call_block({
                tool_call_id = "fail-one-row",
                status = "failed",
                kind = "create",
                argument = "/tmp/agentic_diff_onerow.lua",
                diff = { old = {}, new = { "local a = 1" } },
                failure_reason = { "reason 1", "reason 2" },
            })
            local fence = diff_fence_line()
            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.is_not_nil(lines[fence]:match("^`+text%-foldnext$"))
            local reason_start = closing_fence_after(fence) + 2
            assert.is_not_nil(
                lines[reason_start - 1]:match("^`+console%-fold$")
            )
            deferred.drain()

            local diff_start = fence + 1
            -- One closed fold spans diff and reason, titled by the diff row.
            assert.equal(diff_start, vim.fn.foldclosed(diff_start))
            assert.equal(diff_start, vim.fn.foldclosed(reason_start + 1))
            local _, skip = Folds.levels(bufnr)
            assert.equal(2, skip[diff_start])

            -- The reason's own fold nests inside, also closed.
            vim.api.nvim_win_call(winid, function()
                vim.cmd(diff_start .. "foldopen")
            end)
            assert.equal(-1, vim.fn.foldclosed(diff_start))
            assert.equal(reason_start, vim.fn.foldclosed(reason_start))
        end)

        describe("a diff rejected while pending", function()
            --- 0-indexed rows of the NS_TITLED marks.
            --- @return integer[]
            local function titled_rows()
                return vim.tbl_map(
                    function(mark)
                        return mark[2]
                    end,
                    vim.api.nvim_buf_get_extmarks(
                        bufnr,
                        Folds.NS_TITLED,
                        0,
                        -1,
                        {}
                    )
                )
            end

            before_each(function()
                writer:write_tool_call_block({
                    tool_call_id = "diff-reject",
                    status = "pending",
                    kind = "edit",
                    argument = "/tmp/agentic_diff_reject.lua",
                    diff = { old = { "stub" }, new = diff_new },
                })
                writer:update_tool_call_block({
                    tool_call_id = "diff-reject",
                    status = "pending",
                    causes = { { code = "prompt-reject" } },
                })
            end)

            it(
                "re-lays out with the diff closed and a reason section",
                function()
                    local fence = diff_fence_line()
                    local lines =
                        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                    assert.is_not_nil(lines[fence]:match("^`+text%-foldfence$"))
                    local reason_fence = closing_fence_after(fence) + 1
                    assert.is_not_nil(lines[reason_fence]:match("^`+console$"))
                    assert.equal(
                        "Rejected at the prompt",
                        lines[reason_fence + 1]
                    )
                    assert.same({ reason_fence - 1 }, titled_rows())

                    deferred.drain()
                    assert.equal(fence + 1, vim.fn.foldclosed(fence + 1))
                    assert.equal(-1, vim.fn.foldclosed(reason_fence + 1))
                end
            )

            it("leaves one titled mark after a re-render", function()
                writer:update_tool_call_block({
                    tool_call_id = "diff-reject",
                    status = "failed",
                    failure_reason = { "The user rejected this.", "Stop." },
                })

                local fence = diff_fence_line()
                local reason_fence = closing_fence_after(fence) + 1
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                assert.is_not_nil(
                    lines[reason_fence]:match("^`+console%-fold$")
                )
                assert.same({ reason_fence - 1 }, titled_rows())
            end)
        end)

        it(
            "keeps a fold the user opened through a repeated completion",
            function()
                Config.tool_call_display.create_max_lines = 3
                writer:write_tool_call_block({
                    tool_call_id = "create-reopen",
                    status = "pending",
                    kind = "create",
                    argument = "/tmp/agentic_diff_reopen.lua",
                    diff = { old = {}, new = diff_new },
                })
                local body_start = diff_fence_line() + 1
                writer:update_tool_call_block({
                    tool_call_id = "create-reopen",
                    status = "completed",
                })
                deferred.drain()
                assert.equal(body_start, vim.fn.foldclosed(body_start))

                vim.api.nvim_win_call(winid, function()
                    vim.cmd(body_start .. "foldopen")
                end)
                writer:update_tool_call_block({
                    tool_call_id = "create-reopen",
                    status = "completed",
                })
                deferred.drain()
                assert.equal(-1, vim.fn.foldclosed(body_start))
            end
        )

        it("drops the stale anchor on the failed transition", function()
            writer:write_tool_call_block({
                tool_call_id = "fail-stale",
                status = "pending",
                kind = "edit",
                argument = "/tmp/agentic_diff_stale.lua",
                diff = { old = { "stub" }, new = diff_new },
            })
            deferred.drain()

            writer:update_tool_call_block({
                tool_call_id = "fail-stale",
                status = "failed",
                failure_reason = { "User refused permission to run tool" },
            })
            deferred.drain()
            local states = vim.tbl_values(writer._fold_states)
            assert.same({ false }, states)
        end)

        it(
            "does not orphan diff highlights past the block on the failed transition",
            function()
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
                    argument = "/tmp/agentic_diff_orphan.lua",
                    diff = { old = {}, new = diff_new },
                })
                writer:update_tool_call_block({
                    tool_call_id = "diff-orphan",
                    status = "failed",
                    failure_reason = { "short" },
                })
                -- The diff body ends at the last added line; no diff highlight
                -- lies below it.
                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                local last_diff_row
                for i, l in ipairs(lines) do
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
                    { details = true }
                )
                for _, m in ipairs(marks) do
                    assert.is_true(
                        m[2] <= last_diff_row,
                        "diff highlight past the diff at row " .. m[2]
                    )
                end
            end
        )
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
                    text:match("### Demo execute folding\n```bash")
                )
                -- No accumulation divider, no double-wrapped console fence.
                assert.is_nil(text:match("\n%-%-%-\n"))
                assert.is_nil(text:match("```console\n```console"))

                local openers = 0
                for _ in text:gmatch("```console[%w%-]*\n") do
                    openers = openers + 1
                end
                assert.equal(1, openers)
                assert.is_not_nil(
                    text:match("```bash%-foldnext\nls\n```\n```console%-fold\n")
                )

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

    describe("response starts", function()
        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        it("separates a new response by a blank line", function()
            writer:write_message_chunk(make_message_update("reviewer."))
            writer:write_message_chunk(
                make_message_update("# Code review"),
                true
            )

            assert.same({ "reviewer.", "", "# Code review" }, buffer_lines())
        end)

        it("completes a blank line after one newline", function()
            writer:write_message_chunk(make_message_update("reviewer.\n"))
            writer:write_message_chunk(
                make_message_update("# Code review"),
                true
            )

            assert.same({ "reviewer.", "", "# Code review" }, buffer_lines())
        end)

        it("adds nothing after a whitespace-only row", function()
            writer:write_message_chunk(make_message_update("reviewer.\n  \n"))
            writer:write_message_chunk(
                make_message_update("# Code review"),
                true
            )

            assert.equal(3, #buffer_lines())
        end)

        it("adds nothing after a blank line", function()
            writer:write_message_chunk(make_message_update("reviewer.\n\n"))
            writer:write_message_chunk(
                make_message_update("# Code review"),
                true
            )

            assert.same({ "reviewer.", "", "# Code review" }, buffer_lines())
        end)

        it("adds nothing at the first chunk of a run", function()
            writer:write_message_chunk(
                make_message_update("# Code review"),
                true
            )

            assert.same({ "# Code review" }, buffer_lines())
        end)

        it("leaves the break after a tool call to the section close", function()
            writer:write_message_chunk(make_message_update("reviewer."))
            writer:write_tool_call_block(
                make_tool_call_block("t1", "completed")
            )
            writer:write_message_chunk(
                make_message_update("# Code review"),
                true
            )

            local lines = buffer_lines()
            assert.same(
                { "###", "", "# Code review" },
                { unpack(lines, #lines - 2) }
            )
        end)
    end)

    describe("prompt payloads", function()
        it(
            "finds the nearest prompt with a payload at or above a row",
            function()
                local first, second = { "first" }, { "second" }
                writer:write_user_prompt("one", nil, nil, first)
                writer:write_message_chunk(make_message_update("answer"))
                writer:write_notice({
                    glyph = "x",
                    title = "notice",
                    mid_turn = true,
                })
                writer:write_notice({
                    glyph = "x",
                    title = "tagged",
                    id = "n1",
                    mid_turn = true,
                })
                writer:write_user_prompt("two", nil, nil, second)
                writer:write_message_chunk(make_message_update("more"))

                local two = row_of("## two") - 1
                assert.same(
                    { payload = first, row = 0 },
                    writer:prompt_payload_at(row_of("## tagged") - 1)
                )
                assert.same(
                    { payload = first, row = 0 },
                    writer:prompt_payload_at(0)
                )
                assert.same(
                    { payload = second, row = two },
                    writer:prompt_payload_at(two)
                )
                assert.same(
                    { payload = second, row = two },
                    writer:prompt_payload_at(row_of("more") - 1)
                )
            end
        )

        it("is nil above the first prompt and for row -1", function()
            writer:write_notice({ glyph = "x", title = "notice" })
            writer:write_user_prompt("one", nil, nil, {})

            assert.is_nil(writer:prompt_payload_at(0))
            assert.is_nil(writer:prompt_payload_at(-1))
        end)

        it("skips a prompt without a payload", function()
            local payload = {}
            writer:write_user_prompt("one", nil, nil, payload)
            writer:write_user_prompt("two")

            assert.equal(
                payload,
                writer:prompt_payload_at(row_of("## two") - 1).payload
            )
        end)

        it("is forgotten by reset", function()
            local payload = {}
            writer:write_user_prompt("one", nil, nil, payload)
            writer:reset()

            assert.is_nil(writer:prompt_payload_at(0))
            assert.is_nil(writer:prompt_mark_of(payload))
        end)

        it("prompt_mark_of finds the heading mark of a payload", function()
            local payload = {}
            writer:write_user_prompt("one")
            writer:write_user_prompt("two", nil, nil, payload)

            local mark = writer:prompt_mark_of(payload) --[[@as integer]]
            assert.equal(
                row_of("## two") - 1,
                vim.api.nvim_buf_get_extmark_by_id(
                    bufnr,
                    MessageWriter.NS_USER_ACTIONS,
                    mark,
                    {}
                )[1]
            )
            assert.is_nil(writer:prompt_mark_of({}))
        end)
    end)

    describe("write_fork_link", function()
        --- @param chat_id string
        --- @return agentic.ui.ChatHistory.ForkLink
        local function link(chat_id)
            return {
                type = "fork_link",
                direction = "to",
                chat_id = chat_id,
                cwd = "/c",
                title = "Other",
            }
        end

        local function buffer_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        --- Rows of the marks in NS_USER_ACTIONS.
        --- @return integer[]
        local function action_rows()
            return vim.tbl_map(
                function(mark)
                    return mark[2]
                end,
                vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    MessageWriter.NS_USER_ACTIONS,
                    0,
                    -1,
                    {}
                )
            )
        end

        it("appends a link at the end without a mark", function()
            writer:write_user_prompt("one")
            writer:write_fork_link(link("sid-other-123"))

            assert.same({
                "## one",
                "",
                "## Other",
                "Forked to agentic://sid-other-123",
                "",
            }, buffer_lines())
            assert.equal("fork:sid-other-123", writer:notice_at(3))
            assert.equal(2, writer:notice_row("fork:sid-other-123"))
        end)

        it("names the source of a from link", function()
            local from = link("sid-src-12345")
            from.direction = "from"
            writer:write_fork_link(from)

            assert.equal(
                "Forked from agentic://sid-src-12345",
                buffer_lines()[2]
            )
        end)

        --- Write a turn: prompt `text` with `payload`, and a reply.
        local function turn(text, payload, reply)
            writer:write_user_prompt(text, nil, nil, payload)
            writer:write_message_chunk(make_message_update(reply))
            writer:finalize_turn()
        end

        it("puts the row above a prompt heading", function()
            local first, second = {}, {}
            turn("one", first, "a1\n\nmore")
            turn("two\nbody", second, "a2")
            local two = row_of("## two") - 1
            local fence_marks_before =
                #vim.api.nvim_buf_get_extmarks(bufnr, -1, { two, 0 }, -1, {})

            writer:write_fork_link(link("sid-x"), writer:prompt_mark_of(second))

            assert.equal("## Other", buffer_lines()[two + 1])
            assert.equal("Forked to agentic://sid-x", buffer_lines()[two + 2])
            assert.equal("", buffer_lines()[two + 3])
            assert.equal("## two", buffer_lines()[two + 4])
            -- The prompt keeps its mark, sign and payload.
            assert.same(
                { payload = second, row = two + 3 },
                writer:prompt_payload_at(two + 3)
            )
            assert.same(
                { payload = first, row = 0 },
                writer:prompt_payload_at(two + 2)
            )
            assert.same({ 0, two, two + 3 }, action_rows())
            assert.equal(
                Glyphs.PROMPT .. " ",
                vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    MessageWriter.NS_USER_ACTIONS,
                    { two + 3, 0 },
                    { two + 3, 0 },
                    { details = true }
                )[1][4].sign_text
            )
            assert.equal("fork:sid-x", writer:notice_at(two + 1))
            assert.equal(two, writer:notice_row("fork:sid-x"))
            -- Every mark below moved with its row: none was lost.
            assert.equal(
                fence_marks_before,
                #vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    -1,
                    { two + 3, 0 },
                    -1,
                    {}
                )
            )
            assert_one_sign_per_row()
        end)

        it("works on row 0", function()
            local payload = {}
            turn("one", payload, "a")

            writer:write_fork_link(
                link("sid-x"),
                writer:prompt_mark_of(payload)
            )

            assert.same(
                { "## Other", "Forked to agentic://sid-x", "", "## one" },
                vim.list_slice(buffer_lines(), 1, 4)
            )
            assert.same(
                { payload = payload, row = 3 },
                writer:prompt_payload_at(3)
            )
            assert.is_nil(writer:prompt_payload_at(2))
            assert.same({ 0, 3 }, action_rows())
        end)

        it("does not grow a dim range that ends above", function()
            local payload = {}
            writer:write_notice({ glyph = "x", title = "t", detail = "dim" })
            writer:write_user_prompt("one", nil, nil, payload)
            local before = dim_ranges()

            writer:write_fork_link(
                link("sid-x"),
                writer:prompt_mark_of(payload)
            )

            -- The notice's own detail row, then the link's.
            assert.same({ before[1], { 4, 5 } }, dim_ranges())
        end)

        it("keeps the prompt anchor on the prompt", function()
            local payload = {}
            writer:write_user_prompt("one", nil, nil, payload)
            writer:write_fork_link(
                link("sid-x"),
                writer:prompt_mark_of(payload)
            )
            writer:write_loaded_file({ path = "/tmp/f", after_prompt = true })

            local lines = buffer_lines()
            assert.equal("## one", lines[4])
            assert.equal("", lines[5])
            assert.truthy(lines[6]:find("/tmp/f", 1, true))
        end)

        it("leaves a prose run below unbroken and the turn open", function()
            local payload = {}
            writer:write_user_prompt("one", nil, nil, payload)
            writer:write_message_chunk(make_message_update("alpha\n\nbe"))
            local finalize = spy.on(writer, "finalize_turn")
            MiniTest.finally(function()
                finalize:revert()
            end)

            writer:write_fork_link(
                link("sid-x"),
                writer:prompt_mark_of(payload)
            )
            writer:write_message_chunk(make_message_update("ta"))
            writer:finalize_turn()

            assert.equal(1, finalize.call_count)
            local lines = buffer_lines()
            assert.equal("## one", lines[4])
            assert.truthy(vim.tbl_contains(lines, "beta"))
            assert.is_nil(row_of("be"))
            assert_one_sign_per_row()
        end)

        it("does not finalize the turn at the end either", function()
            local finalize = spy.on(writer, "finalize_turn")
            MiniTest.finally(function()
                finalize:revert()
            end)

            writer:write_fork_link(link("sid-x"))

            assert.equal(0, finalize.call_count)
        end)
    end)
end)

describe("agentic.ui.MessageWriter wrapped table rows", function()
    local MessageWriter = require("agentic.ui.message_writer")

    -- At a wrap width of 20 the first body row takes three lines.
    local TABLE = {
        "| Name | Description |",
        "|---|---|",
        "| a | one two three four five six |",
        "| b | short |",
        "| c | x |",
    }

    local bufnr, winid, writer, original_windows

    before_each(function()
        original_windows = vim.deepcopy(Config.windows)
        Config.windows.wrap_width = 20
        bufnr = vim.api.nvim_create_buf(false, true)
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
        Config.windows = original_windows
        vim.api.nvim_win_close(winid, true)
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    --- 0-indexed rows carrying the row-end underline, in any namespace.
    --- Asserts each underline spans the row between its outer pipes.
    --- @return integer[]
    local function underlined_rows()
        local rows = {}
        local marks =
            vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })
        for _, mark in ipairs(marks) do
            if mark[4].hl_group == "AgenticTableRowEnd" then
                local line = vim.api.nvim_buf_get_lines(
                    bufnr,
                    mark[2],
                    mark[2] + 1,
                    false
                )[1]
                assert.equal(mark[2], mark[4].end_row)
                assert.equal(
                    line:match("^%s*|(.*)|%s*$"),
                    line:sub(mark[3] + 1, mark[4].end_col)
                )
                rows[#rows + 1] = mark[2]
            end
        end
        return rows
    end

    --- @param text string
    --- @param kind string|nil
    local function update(text, kind)
        return {
            sessionUpdate = kind or "agent_message_chunk",
            content = { type = "text", text = text },
        }
    end

    it("underlines row ends of a message in an empty buffer", function()
        writer:write_message(update(table.concat(TABLE, "\n")))
        assert.equal(
            "|      | five six    |",
            vim.api.nvim_buf_get_lines(bufnr, 4, 5, false)[1]
        )
        assert.same({ 4, 5, 6 }, underlined_rows())
    end)

    it("underlines row ends of a message after content", function()
        writer:write_message(update("intro"))
        writer:write_message(update(table.concat(TABLE, "\n")))
        assert.same({ 6, 7, 8 }, underlined_rows())
    end)

    it("underlines a streamed table once and leaves later prose", function()
        writer:write_message_chunk(
            update("intro\n\n" .. table.concat(TABLE, "\n") .. "\n\n")
        )
        writer:write_message_chunk(update("more prose here"))
        writer:finalize_turn()

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        assert.equal("|      | five six    |", lines[7])
        assert.equal("more prose here", lines[11])
        assert.same({ 6, 7, 8 }, underlined_rows())

        local signs = vim.api.nvim_buf_get_extmarks(
            bufnr,
            require("agentic.ui.tool_call_renderer").NS_DECORATIONS,
            0,
            -1,
            { details = true }
        )
        local last = signs[#signs]
        assert.same({ 10, "╰─" }, { last[2], last[4].sign_text })
    end)

    it("underlines a table in a thought run's body", function()
        writer:write_message_chunk(
            update(table.concat(TABLE, "\n"), "agent_thought_chunk")
        )
        writer:flush_thought_run()
        assert.same({ 5, 6, 7 }, underlined_rows())
    end)

    it("underlines a table in a hook block's body", function()
        writer:write_hook_block({
            body = vim.deepcopy(TABLE),
            title = "`guard.sh`",
        })
        -- One row below a thought run's: the title leads the body.
        assert.same({ 6, 7, 8 }, underlined_rows())
        assert.equal(
            Glyphs.HOOK .. " ",
            vim.api.nvim_buf_get_extmarks(
                bufnr,
                require("agentic.ui.tool_call_renderer").NS_DECORATIONS,
                1,
                1,
                { details = true }
            )[1][4].sign_text
        )
    end)

    it("underlines a table in a user prompt", function()
        writer:write_user_prompt("look\n" .. table.concat(TABLE, "\n"))
        assert.same({ 5, 6, 7 }, underlined_rows())
    end)

    it("underlines a table in a notice's folded body", function()
        writer:write_notice({
            glyph = "x",
            title = "t",
            fold_body = vim.deepcopy(TABLE),
            mid_turn = true,
        })
        assert.same({ 6, 7, 8 }, underlined_rows())
    end)

    it("underlines a table in a hook block placed under its call", function()
        local schedule_stub = spy.stub(vim, "schedule")
        MiniTest.finally(function()
            schedule_stub:revert()
        end)
        writer:write_tool_call_block({
            tool_call_id = "t1",
            status = "completed",
            kind = "execute",
            argument = "ls",
            body = { "output" },
        })
        writer:write_message_chunk(update("after the call"))
        writer:write_hook_block({
            body = vim.deepcopy(TABLE),
            title = "`guard.sh`",
            tool_call_id = "t1",
        })

        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local i_five = vim.iter(ipairs(lines)):find(function(_, line)
            return line == "|      | five six    |"
        end)
        assert.is_true(i_five < #lines - 1)
        assert.equal("after the call", lines[#lines])
        assert.same({ i_five - 1, i_five, i_five + 1 }, underlined_rows())
    end)

    it("underlines a table in a fetch body", function()
        local schedule_stub = spy.stub(vim, "schedule")
        MiniTest.finally(function()
            schedule_stub:revert()
        end)
        writer:write_tool_call_block({
            tool_call_id = "fetch-table",
            status = "completed",
            kind = "fetch",
            argument = "https://example.com prompt",
            body = vim.deepcopy(TABLE),
        })
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local i_five = vim.iter(ipairs(lines)):find(function(_, line)
            return line == "|      | five six    |"
        end)
        assert.same({ i_five - 1, i_five, i_five + 1 }, underlined_rows())
    end)
end)
