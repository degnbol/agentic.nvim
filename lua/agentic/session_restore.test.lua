local assert = require("tests.helpers.assert")
local MiniTest = require("mini.test")
local Glyphs = require("agentic.glyphs")
local spy = require("tests.helpers.spy")

describe("SessionRestore", function()
    --- @type agentic.SessionRestore
    local SessionRestore
    local ChatHistory
    local SessionRegistry
    local Logger
    local Config

    --- @type TestStub
    local chat_history_list_stub
    --- @type TestStub
    local session_registry_stub
    --- @type TestStub
    local logger_notify_stub
    --- @type TestStub
    local target_win_stub
    --- @type TestStub
    local open_session_stub
    --- @type TestStub
    local read_saved_stub
    --- What `SessionRegistry.target_win()` returns in every case.
    local TARGET_WIN = 4242

    local test_sessions = {
        {
            session_id = "session-1",
            title = "First chat",
            timestamp = 1704067200,
            file_path = "/storage/p/session-1.json",
        },
        {
            session_id = "session-2",
            title = "Second chat",
            timestamp = 1704153600,
            file_path = "/storage/p/session-2.json",
        },
    }

    local function create_mock_session(opts)
        opts = opts or {}
        return {
            session_id = opts.session_id or "current-session",
            agent = { provider_name = opts.provider_name or "claude-acp" },
            widget = { show = spy.new(function() end) },
            load_acp_session = spy.new(function() end),
        }
    end

    local function setup_list_stub(sessions)
        chat_history_list_stub:invokes(function(_cwd, callback)
            callback(sessions or test_sessions)
        end)
    end

    local original_loaded = {}
    local niled_modules = {
        "agentic.session_restore",
        "agentic.session_restore_builtin",
        "agentic.ui.chat_history",
        "agentic.session_registry",
        "agentic.utils.logger",
        "agentic.config",
    }

    before_each(function()
        for _, mod in ipairs(niled_modules) do
            original_loaded[mod] = package.loaded[mod]
            package.loaded[mod] = nil
        end

        SessionRestore = require("agentic.session_restore")
        ChatHistory = require("agentic.ui.chat_history")
        SessionRegistry = require("agentic.session_registry")
        Logger = require("agentic.utils.logger")
        Config = require("agentic.config")

        Config.session_restore = { picker = "builtin", cd_on_load = false }

        chat_history_list_stub = spy.stub(ChatHistory, "list_sessions")
        session_registry_stub = spy.stub(SessionRegistry, "create")
        target_win_stub = spy.stub(SessionRegistry, "target_win")
        target_win_stub:returns(TARGET_WIN)
        open_session_stub = spy.stub(SessionRegistry, "session_for_acp_id")
        open_session_stub:returns(nil)
        read_saved_stub = spy.stub(ChatHistory, "read_saved")
        read_saved_stub:returns(nil)
        logger_notify_stub = spy.stub(Logger, "notify")
    end)

    after_each(function()
        chat_history_list_stub:revert()
        session_registry_stub:revert()
        target_win_stub:revert()
        open_session_stub:revert()
        read_saved_stub:revert()
        logger_notify_stub:revert()

        for _, mod in ipairs(niled_modules) do
            package.loaded[mod] = original_loaded[mod]
        end
    end)

    describe("build_items", function()
        it("formats as date │ title", function()
            local items = SessionRestore.build_items(test_sessions)
            assert.equal(2, #items)
            assert.truthy(items[1].display:match("│ First chat"))
            assert.truthy(items[1].display:match("^%d%d%d%d%-%d%d%-%d%d"))
            assert.equal("session-1", items[1].session_id)
        end)

        it("shows a shortened cwd when asked", function()
            local home = vim.uv.os_homedir() --[[@as string]]
            local cases = {
                { home .. "/a/b/c/d", "…/c/d" },
                { home .. "/a/b", "~/a/b" },
                { home, "~" },
                { "/x/y", "/x/y" },
                { home .. "x/y", home .. "x/y" },
            }
            for _, case in ipairs(cases) do
                local items = SessionRestore.build_items({
                    {
                        session_id = "s",
                        title = "t",
                        timestamp = 0,
                        file_path = "/s.json",
                        cwd = case[1],
                    },
                }, { show_cwd = true })
                assert.truthy(
                    vim.endswith(items[1].display, "[" .. case[2] .. "]"),
                    items[1].display
                )
            end
        end)

        it("uses (no title) for missing titles", function()
            --- @diagnostic disable-next-line: missing-fields
            local items = SessionRestore.build_items({ { session_id = "s1" } })
            assert.truthy(items[1].display:match("%(no title%)"))
        end)

        it("passes prompt_count through to items", function()
            local items = SessionRestore.build_items({
                {
                    session_id = "s1",
                    title = "With count",
                    timestamp = 1704067200,
                    file_path = "/storage/p/s1.json",
                    prompt_count = 5,
                },
                {
                    session_id = "s2",
                    title = "No count",
                    timestamp = 1704067200,
                    file_path = "/storage/p/s2.json",
                },
            })
            assert.equal(5, items[1].prompt_count)
            assert.is_nil(items[2].prompt_count)
        end)

        it("strips newlines from multi-line titles", function()
            local items = SessionRestore.build_items({
                {
                    session_id = "s1",
                    title = "First line\nSecond line\nThird",
                    timestamp = 1704067200,
                    file_path = "/storage/p/s1.json",
                },
            })
            assert.is_nil(items[1].display:find("\n"))
            assert.truthy(items[1].display:match("│ First line"))
        end)
    end)

    --- @diagnostic disable: missing-fields
    describe("format_preview", function()
        it("formats user messages with heading", function()
            local lines = SessionRestore.format_preview({
                { type = "user", text = "Hello world" },
            })
            assert.truthy(vim.tbl_contains(lines, "## You"))
            assert.truthy(vim.tbl_contains(lines, "Hello world"))
        end)

        it("skips a synthetic prompt", function()
            assert.same(
                {},
                SessionRestore.format_preview({
                    { type = "user", text = "continue", synthetic = true },
                })
            )
        end)

        it("formats agent messages with heading", function()
            local lines = SessionRestore.format_preview({
                { type = "agent", text = "Response text" },
            })
            assert.truthy(vim.tbl_contains(lines, "## Agent"))
            assert.truthy(vim.tbl_contains(lines, "Response text"))
        end)

        it("formats a message row as a heading over its text", function()
            local lines = SessionRestore.format_preview({
                {
                    type = "session_message",
                    message_id = "m1",
                    kind = "result",
                    view = "received",
                    text = "Found it.\nIn lib/.",
                },
                { type = "subagent_end", state = "completed" },
                {
                    type = "subagent_end",
                    state = "failed",
                    error = "boom\ntwo",
                },
            })
            assert.same({
                "## Found it.",
                "In lib/.",
                "",
                "## completed",
                "",
                "## failed",
                "boom",
                "two",
                "",
            }, lines)
        end)

        it("truncates long thought blocks", function()
            local long_thought =
                table.concat(vim.fn["repeat"]({ "line" }, 10), "\n")
            local lines = SessionRestore.format_preview({
                { type = "thought", text = long_thought },
            })
            local more_line = vim.tbl_filter(function(l)
                return l:match("more lines")
            end, lines)
            assert.equal(1, #more_line)
        end)

        it("shows tool call with status icon", function()
            local lines = SessionRestore.format_preview({
                {
                    type = "tool_call",
                    kind = "edit",
                    argument = "file.lua",
                    status = "completed",
                },
            })
            local tool_line = vim.tbl_filter(function(l)
                return l:match("edit") and l:match("file.lua")
            end, lines)
            assert.equal(1, #tool_line)
            assert.truthy(tool_line[1]:match("✔"))
        end)

        it("marks a cancelled tool call as over, not running", function()
            local lines = SessionRestore.format_preview({
                {
                    type = "tool_call",
                    kind = "edit",
                    argument = "file.lua",
                    status = "cancelled",
                },
            })
            local tool_line = vim.tbl_filter(function(l)
                return l:match("edit")
            end, lines)
            assert.equal(1, #tool_line)
            -- The preview reads the same glyph vocabulary as the live footer,
            -- so a cancelled call no longer takes the "…" that means the turn
            -- is still working on it.
            assert.truthy(
                tool_line[1]:find(Config.status_icons.cancelled, 1, true)
            )
            assert.is_nil(tool_line[1]:find("…", 1, true))
        end)

        it("produces no lines with embedded newlines", function()
            local lines = SessionRestore.format_preview({
                { type = "user", text = "line1\nline2\nline3" },
                { type = "agent", text = "resp1\nresp2" },
                {
                    type = "tool_call",
                    kind = "edit",
                    argument = "old\nnew",
                    status = "completed",
                },
            })
            for _, line in ipairs(lines) do
                assert.is_nil(line:find("\n"))
            end
        end)
    end)

    describe("show_picker", function()
        --- @type TestStub
        local builtin_show_stub
        --- @type TestStub
        local resume_stub

        before_each(function()
            builtin_show_stub =
                spy.stub(require("agentic.session_restore_builtin"), "show")
            resume_stub = spy.stub(SessionRestore, "resume")
        end)

        after_each(function()
            builtin_show_stub:revert()
            resume_stub:revert()
        end)

        it("notifies and skips picker when no sessions exist", function()
            setup_list_stub({})

            SessionRestore.show_picker()

            assert.spy(logger_notify_stub).was.called(1)
            assert.equal(
                "No saved sessions found",
                logger_notify_stub.calls[1][1]
            )
            assert.equal(vim.log.levels.INFO, logger_notify_stub.calls[1][2])
            assert.spy(builtin_show_stub).was.called(0)
        end)

        it("joins a notice with the empty-list notification", function()
            SessionRestore.show_picker({ sessions = {}, notice = "No match" })

            assert.spy(logger_notify_stub).was.called(1)
            assert.equal(
                "No match\nNo saved sessions found",
                logger_notify_stub.calls[1][1]
            )
        end)

        it(
            "passes the pick and mods to resume, marked_id to the backend",
            function()
                setup_list_stub()
                local mods = { tab = 1 }
                builtin_show_stub:invokes(function(items, on_select)
                    on_select(items[1])
                end)

                SessionRestore.show_picker({
                    mods = mods,
                    marked_id = "session-2",
                })

                local opts = builtin_show_stub.calls[1][3]
                assert.equal("session-2", opts.marked_id)
                assert.equal("local", opts.scope)
                assert.equal("session-1", resume_stub.calls[1][1].session_id)
                assert.equal(mods, resume_stub.calls[1][2])
            end
        )
    end)

    describe("resume", function()
        it("shows an open session and creates nothing", function()
            local open_session = create_mock_session()
            open_session_stub:returns(open_session)
            local mods = { tab = 1 }

            SessionRestore.resume({ session_id = "sid-x" }, mods)

            assert.same(
                { open_session.widget, mods, TARGET_WIN, n = 3 },
                open_session.widget.show.calls[1]
            )
            assert.spy(session_registry_stub).was.called(0)
        end)

        it("creates a session on the provider and loads into it", function()
            Config.acp_providers = { ["codex-acp"] = {} }
            local session = create_mock_session()
            session_registry_stub:returns(session)
            local mods = { vertical = true }

            SessionRestore.resume({
                session_id = "sid-x",
                cwd = "/p",
                provider = "codex-acp",
                model = "m1",
            }, mods)

            assert.equal("codex-acp", session_registry_stub.calls[1][1])
            assert.same(
                { session, "sid-x", "/p", "m1", n = 4 },
                session.load_acp_session.calls[1]
            )
            assert.equal(mods, session.widget.show.calls[1][2])
            assert.equal(TARGET_WIN, session.widget.show.calls[1][3])
            assert.spy(read_saved_stub).was.called(0)
        end)

        it(
            "warns and takes the default rule for an unconfigured provider",
            function()
                Config.acp_providers = {}
                session_registry_stub:returns(create_mock_session())

                SessionRestore.resume({
                    session_id = "sid-x",
                    cwd = "/p",
                    --- @diagnostic disable-next-line: assign-type-mismatch
                    provider = "gone-acp",
                    model = "m1",
                })

                assert.is_nil(session_registry_stub.calls[1][1])
                assert.spy(logger_notify_stub).was.called(1)
                assert.equal(
                    vim.log.levels.WARN,
                    logger_notify_stub.calls[1][2]
                )
            end
        )

        it("fills nil fields from the saved file", function()
            Config.acp_providers = { ["codex-acp"] = {} }
            read_saved_stub:returns({
                session_id = "sid-x",
                cwd = "/saved",
                provider = "codex-acp",
                model = "m-saved",
            })
            local session = create_mock_session()
            session_registry_stub:returns(session)

            SessionRestore.resume({ session_id = "sid-x" })

            assert.equal("codex-acp", session_registry_stub.calls[1][1])
            assert.same(
                { session, "sid-x", "/saved", "m-saved", n = 4 },
                session.load_acp_session.calls[1]
            )
        end)

        it(
            "takes the default rule without a warning when no file is found",
            function()
                session_registry_stub:returns(create_mock_session())

                SessionRestore.resume({ session_id = "sid-x" })

                assert.is_nil(session_registry_stub.calls[1][1])
                assert.spy(logger_notify_stub).was.called(0)
            end
        )

        it("changes directory to the session cwd with cd_on_load", function()
            Config.session_restore.cd_on_load = true
            session_registry_stub:returns(create_mock_session())
            local before = vim.fn.getcwd()
            local dir = vim.fn.tempname()
            vim.fn.mkdir(dir, "p")
            MiniTest.finally(function()
                vim.api.nvim_set_current_dir(before)
            end)

            SessionRestore.resume({ session_id = "sid-x", cwd = dir })

            assert.equal(
                vim.uv.fs_realpath(dir),
                vim.uv.fs_realpath(vim.fn.getcwd())
            )
        end)
    end)

    describe("pick", function()
        --- @type TestStub
        local find_stub
        --- @type TestStub
        local show_picker_stub
        --- @type TestStub
        local resume_stub

        --- Make `find` call back with `matches`.
        local function setup_find(matches)
            find_stub:invokes(function(_, callback)
                callback(matches)
            end)
        end

        before_each(function()
            find_stub = spy.stub(SessionRestore, "find")
            show_picker_stub = spy.stub(SessionRestore, "show_picker")
            resume_stub = spy.stub(SessionRestore, "resume")
        end)

        after_each(function()
            find_stub:revert()
            show_picker_stub:revert()
            resume_stub:revert()
        end)

        it("resumes the one match", function()
            setup_find({ test_sessions[1] })
            local mods = { tab = 1 }

            SessionRestore.pick("First chat", { mods = mods })

            assert.same({ test_sessions[1], mods, n = 2 }, resume_stub.calls[1])
            assert.spy(show_picker_stub).was.called(0)
        end)

        it("picks among several matches in scope all", function()
            setup_find(test_sessions)

            SessionRestore.pick("session", { marked_id = "m" })

            local opts = show_picker_stub.calls[1][1]
            assert.equal("all", opts.scope)
            assert.equal(test_sessions, opts.sessions)
            assert.equal("m", opts.marked_id)
            assert.spy(resume_stub).was.called(0)
        end)

        it("picks in scope local with a notice when nothing matches", function()
            setup_find({})

            SessionRestore.pick("nope")

            local opts = show_picker_stub.calls[1][1]
            assert.is_nil(opts.scope)
            assert.is_nil(opts.sessions)
            assert.equal("No saved session matches: nope", opts.notice)
        end)

        it("picks in scope local for a nil or empty query", function()
            SessionRestore.pick(nil)
            SessionRestore.pick("")

            assert.spy(find_stub).was.called(0)
            for _, call in ipairs(show_picker_stub.calls) do
                assert.is_nil(call[1].scope)
                assert.is_nil(call[1].sessions)
                assert.is_nil(call[1].notice)
            end
            assert.equal(2, #show_picker_stub.calls)
        end)
    end)

    describe("list", function()
        it("lists the project folder of the editor cwd", function()
            setup_list_stub()

            SessionRestore.list("local", function() end)

            assert.equal(vim.fn.getcwd(), chat_history_list_stub.calls[1][1])
        end)
    end)

    describe("replay_messages", function()
        local function no_buffer()
            return nil
        end

        it("skips a synthetic prompt", function()
            local write_prompt_spy = spy.new(function() end)
            local writer = {
                write_user_prompt = write_prompt_spy,
                flush_thought_run = function() end,
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                { { type = "user", text = "continue", synthetic = true } },
                no_buffer
            )

            assert.equal(0, write_prompt_spy.call_count)
        end)

        it("replays user and agent messages", function()
            local write_message_spy = spy.new(function() end)
            local write_prompt_spy = spy.new(function() end)
            local write_chunk_spy = spy.new(function() end)
            local write_tool_spy = spy.new(function() end)
            local flush_spy = spy.new(function() end)

            local writer = {
                write_message = write_message_spy,
                write_user_prompt = write_prompt_spy,
                write_message_chunk = write_chunk_spy,
                write_tool_call_block = write_tool_spy,
                flush_thought_run = flush_spy,
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    { type = "user", text = "Hello" },
                    { type = "agent", text = "Hi there" },
                },
                no_buffer
            )

            assert.equal(1, write_prompt_spy.call_count)
            assert.equal(1, write_message_spy.call_count)
        end)

        it("splits a saved read's range, keeping execute fences", function()
            local write_tool_spy = spy.new(function() end)
            local writer = {
                write_tool_call_block = write_tool_spy,
                flush_thought_run = function() end,
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "tool_call",
                        tool_call_id = "r",
                        kind = "read",
                        status = "completed",
                        argument = "/tmp/f.lua (1 - 2)",
                    },
                    {
                        type = "tool_call",
                        tool_call_id = "e",
                        kind = "execute",
                        status = "completed",
                        argument = "cat x.md",
                        body = { "```", "x", "```" },
                    },
                },
                no_buffer
            )

            -- Method calls: argument 1 is the writer.
            local read = write_tool_spy.calls[1][2]
            assert.equal("/tmp/f.lua", read.argument)
            assert.same({ offset = 1, limit = 2 }, read.read_range)
            assert.same({ "```", "x", "```" }, write_tool_spy.calls[2][2].body)
        end)

        --- Notices `replay_messages` writes for `rows`, as `write_notice` got them.
        --- @param rows agentic.ui.ChatHistory.Message[]
        --- @param buffer_name fun(session_id: string): string|nil
        --- @return agentic.ui.MessageWriter.Notice[]
        local function replayed_notices(rows, buffer_name)
            local notice_spy = spy.new(function() end)
            local writer = {
                write_notice = notice_spy,
                flush_thought_run = spy.new(function() end),
            }
            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                rows,
                buffer_name
            )
            return vim.tbl_map(function(call)
                return call[2]
            end, notice_spy.calls)
        end

        --- A session message row of `kind` and `view`.
        local function message_row(kind, view, text)
            return {
                type = "session_message",
                message_id = "m-" .. kind .. "-" .. view,
                kind = kind,
                view = view,
                sender_session_id = "root",
                recipient_session_id = "c1",
                text = text or "Title\nbody",
            }
        end

        it("signs an end with its status icon, else the flag", function()
            local original_icons = Config.status_icons
            MiniTest.finally(function()
                Config.status_icons = original_icons
            end)
            Config.status_icons =
                { failed = "F", cancelled = "", completed = "❌" }

            local notices = replayed_notices({
                {
                    type = "subagent_end",
                    state = "failed",
                    error = "boom\ntwo",
                },
                { type = "subagent_end", state = "cancelled" },
                { type = "subagent_end", state = "end_turn_odd" },
                { type = "subagent_end", state = "completed" },
            }, no_buffer)

            assert.equal("F", notices[1].glyph)
            assert.equal("failed", notices[1].title)
            assert.same({ "boom", "two" }, notices[1].body)
            assert.is_true(notices[1].mid_turn)
            assert.equal(Glyphs.RUN_ENDED, notices[2].glyph)
            assert.equal(Glyphs.RUN_ENDED, notices[3].glyph)
            -- Too wide for the sign column.
            assert.equal(Glyphs.RUN_ENDED, notices[4].glyph)
        end)

        it(
            "signs a message by its kind, and a plain one by its view",
            function()
                local notices = replayed_notices({
                    message_row("task", "sent"),
                    message_row("result", "received"),
                    message_row("message", "sent"),
                    message_row("message", "received"),
                }, no_buffer)

                assert.same(
                    {
                        Glyphs.MESSAGE.task,
                        Glyphs.MESSAGE.result,
                        Glyphs.KIND.sendmessage,
                        Glyphs.MESSAGE_RECEIVED,
                    },
                    vim.tbl_map(function(n)
                        return n.glyph
                    end, notices)
                )
            end
        )

        it("titles a message by its first line and folds the rest", function()
            local notice = replayed_notices({
                message_row(
                    "task",
                    "sent",
                    "\nFind it.\n\nIn lib/.\nThen tests/.\n"
                ),
            }, no_buffer)[1]

            assert.equal("Find it.", notice.title)
            assert.same({ "In lib/.", "Then tests/." }, notice.fold_body)
            assert.equal("m-task-sent", notice.id)
        end)

        it(
            "titles a message by its first sentence, without heading marks",
            function()
                local notices = replayed_notices({
                    message_row(
                        "message",
                        "sent",
                        "Do it. Then check.\n\nMore."
                    ),
                    message_row("message", "sent", "# Report: done\nbody"),
                }, no_buffer)

                assert.equal("Do it.", notices[1].title)
                assert.same(
                    { "Then check.", "", "More." },
                    notices[1].fold_body
                )
                assert.equal("Report: done", notices[2].title)
                assert.same({ "body" }, notices[2].fold_body)
            end
        )

        it(
            "folds a trailing parenthetical, and titles a bare heading mark by a placeholder",
            function()
                local notices = replayed_notices({
                    message_row(
                        "message",
                        "sent",
                        "Launched (never quote it)\nmore"
                    ),
                    message_row("message", "sent", "## \nbody"),
                }, no_buffer)

                assert.equal("Launched", notices[1].title)
                assert.same(
                    { "(never quote it)", "", "more" },
                    notices[1].fold_body
                )
                assert.equal("(message)", notices[2].title)
                assert.same({ "body" }, notices[2].fold_body)
            end
        )

        it(
            "titles a message with a summary by it, folding the whole text",
            function()
                local row =
                    message_row("task", "sent", "\nReview it.\n\nCarefully.\n")
                row.summary = "Code review"
                local notice = replayed_notices({ row }, no_buffer)[1]

                assert.equal("Code review", notice.title)
                assert.same(
                    { "Review it.", "", "Carefully." },
                    notice.fold_body
                )
            end
        )

        it("gives the other end's buffer as the detail", function()
            local function buffer_name(session_id)
                return session_id == "c1" and "agentic://1/subagent/finder"
                    or nil
            end
            local notices = replayed_notices({
                message_row("task", "sent"),
                message_row("task", "received"),
            }, buffer_name)

            assert.equal("agentic://1/subagent/finder", notices[1].detail)
            -- The sender has no buffer here.
            assert.is_nil(notices[2].detail)
        end)

        it("titles an empty or fenced message by a placeholder", function()
            local notices = replayed_notices({
                message_row("message", "sent", " \n"),
                message_row("message", "sent", "```lua\nx = 1\n```"),
            }, no_buffer)

            assert.equal("(empty message)", notices[1].title)
            assert.same({}, notices[1].fold_body)
            assert.equal("(message)", notices[2].title)
            assert.same({ "```lua", "x = 1", "```" }, notices[2].fold_body)
        end)

        it("replays thought chunks", function()
            local write_message_spy = spy.new(function() end)
            local write_chunk_spy = spy.new(function() end)
            local write_tool_spy = spy.new(function() end)
            local flush_spy = spy.new(function() end)

            local writer = {
                write_message = write_message_spy,
                write_message_chunk = write_chunk_spy,
                write_tool_call_block = write_tool_spy,
                flush_thought_run = flush_spy,
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    { type = "thought", text = "Thinking..." },
                },
                no_buffer
            )

            assert.equal(1, write_chunk_spy.call_count)
            -- Nothing else finalizes the replayed turn, so the run would stay
            -- buffered and surface under the next prompt.
            assert.equal(1, flush_spy.call_count)
        end)

        it("replays tool calls", function()
            local write_message_spy = spy.new(function() end)
            local write_chunk_spy = spy.new(function() end)
            local write_tool_spy = spy.new(function() end)
            local flush_spy = spy.new(function() end)

            local writer = {
                write_message = write_message_spy,
                write_message_chunk = write_chunk_spy,
                write_tool_call_block = write_tool_spy,
                flush_thought_run = flush_spy,
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "tool_call",
                        tool_call_id = "t1",
                        kind = "edit",
                        argument = "file.lua",
                        status = "completed",
                    },
                },
                no_buffer
            )

            assert.equal(1, write_tool_spy.call_count)
        end)

        -- A field the record → block projection leaves out is lost on replay
        -- alone, with the saved session still holding it.
        it("replays the SKILL.md path of a skill call", function()
            local write_tool_spy = spy.new(function() end)

            local writer = {
                write_message = spy.new(function() end),
                write_message_chunk = spy.new(function() end),
                write_tool_call_block = write_tool_spy,
                flush_thought_run = spy.new(function() end),
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "tool_call",
                        tool_call_id = "t-skill",
                        kind = "Skill",
                        argument = "coding",
                        status = "completed",
                        skill_path = "/skills/coding/SKILL.md",
                    },
                },
                no_buffer
            )

            -- Called with `:`, so the block is the second recorded argument.
            assert.equal(
                "/skills/coding/SKILL.md",
                write_tool_spy.calls[1][2].skill_path
            )
        end)

        it("replays the shell of an execute call", function()
            local write_tool_spy = spy.new(function() end)

            local writer = {
                write_message = spy.new(function() end),
                write_message_chunk = spy.new(function() end),
                write_tool_call_block = write_tool_spy,
                flush_thought_run = spy.new(function() end),
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "tool_call",
                        tool_call_id = "t-exec",
                        kind = "execute",
                        argument = "ls",
                        status = "completed",
                        shell = "zsh",
                    },
                },
                no_buffer
            )

            assert.equal("zsh", write_tool_spy.calls[1][2].shell)
        end)

        it("replays a failure reason, read range and search pattern", function()
            local write_tool_spy = spy.new(function() end)

            local writer = {
                write_message = spy.new(function() end),
                write_message_chunk = spy.new(function() end),
                write_tool_call_block = write_tool_spy,
                flush_thought_run = spy.new(function() end),
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "tool_call",
                        tool_call_id = "t-1",
                        kind = "search",
                        argument = "rg foo",
                        status = "failed",
                        search_pattern = "foo",
                        read_range = { offset = 1, limit = 2 },
                        failure_reason = { "denied" },
                    },
                },
                no_buffer
            )

            local block = write_tool_spy.calls[1][2]
            assert.equal("foo", block.search_pattern)
            assert.same({ offset = 1, limit = 2 }, block.read_range)
            assert.same({ "denied" }, block.failure_reason)
        end)

        it("replays what decided a call's permission", function()
            local write_tool_spy = spy.new(function() end)

            local writer = {
                write_message = spy.new(function() end),
                write_message_chunk = spy.new(function() end),
                write_tool_call_block = write_tool_spy,
                flush_thought_run = spy.new(function() end),
            }

            SessionRestore.replay_messages(
                writer --[[@as agentic.ui.MessageWriter]],
                {
                    {
                        type = "tool_call",
                        tool_call_id = "t-grep",
                        kind = "execute",
                        argument = "grep x f > /tmp/out",
                        status = "completed",
                        decided_by = { "read-only", "grant" },
                    },
                },
                no_buffer
            )

            assert.same(
                { "read-only", "grant" },
                write_tool_spy.calls[1][2].decided_by
            )
        end)

        it(
            "replays a foldable search tool call without emitting marker lines",
            function()
                -- Persisted bodies never contained markers, so a clean
                -- re-render must signal foldability via the `-fold` fence
                -- suffix rather than re-inserting markers into buffer content.
                local MessageWriter = require("agentic.ui.message_writer")
                Config = require("agentic.config")
                local original_display = vim.deepcopy(Config.tool_call_display)
                Config.tool_call_display.execute_formatter = false

                local bufnr = vim.api.nvim_create_buf(false, true)
                local writer = MessageWriter:new(bufnr)
                local schedule_stub = spy.stub(vim, "schedule")

                local body = {}
                for i = 1, Config.tool_call_display.search_max_lines + 5 do
                    table.insert(body, "match " .. i)
                end

                SessionRestore.replay_messages(
                    writer --[[@as agentic.ui.MessageWriter]],
                    {
                        {
                            type = "tool_call",
                            tool_call_id = "replay-search",
                            kind = "search",
                            argument = "rg foo",
                            status = "completed",
                            body = body,
                        },
                    },
                    no_buffer
                )

                local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                for _, line in ipairs(lines) do
                    assert.are_not.equal("{{{", line)
                    assert.are_not.equal("}}}", line)
                end

                -- Foldability is encoded in the fence info string (the `-fold`
                -- suffix the writer adds), not in buffer markers or extmarks.
                local has_fold_fence = false
                for _, line in ipairs(lines) do
                    if line:match("^`+[%w]+%-fold$") then
                        has_fold_fence = true
                        break
                    end
                end
                assert.is_true(has_fold_fence)

                schedule_stub:revert()
                Config.tool_call_display = original_display
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )

        it("puts stored side records at their anchors", function()
            local MessageWriter = require("agentic.ui.message_writer")
            local bufnr = vim.api.nvim_create_buf(false, true)
            local writer = MessageWriter:new(bufnr)
            local schedule_stub = spy.stub(vim, "schedule")
            MiniTest.finally(function()
                schedule_stub:revert()
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end)

            --- @param path string
            --- @param anchor agentic.acp.Anchor
            --- @return agentic.acp.SideRecord
            local function loaded(path, anchor)
                return {
                    kind = "loaded_file",
                    loaded_file = vim.tbl_extend(
                        "force",
                        { path = path },
                        anchor
                    ),
                }
            end
            --- @param id string
            --- @param extra table|nil
            --- @return agentic.ui.ChatHistory.ToolCall
            local function tool_call(id, extra)
                return vim.tbl_extend("force", {
                    type = "tool_call",
                    tool_call_id = id,
                    kind = "execute",
                    argument = "ls",
                    status = "completed",
                    body = { "output" },
                }, extra or {}) --[[@as agentic.ui.ChatHistory.ToolCall]]
            end
            --- @param text string
            --- @return agentic.ui.ChatHistory.AgentMessage
            local function agent(text)
                return {
                    type = "agent",
                    text = text .. "\n\n",
                    provider_name = "p",
                }
            end

            SessionRestore.replay_messages(writer, {
                {
                    type = "user",
                    text = "go",
                    timestamp = 0,
                    provider_name = "p",
                },
                agent("intro"),
                tool_call("t1"),
                agent("after the call"),
                tool_call("c-1", { is_compaction = true }),
                agent("resumed"),
                {
                    type = "side_records",
                    records = {
                        loaded("/r/call.md", { tool_call_id = "t1" }),
                        {
                            kind = "hook",
                            hook = {
                                group = "context",
                                body = { "hook context" },
                                tool_call_id = "t1",
                            },
                        },
                        loaded("/r/prompt.md", { after_prompt = true }),
                        loaded("/r/compact.md", { after_compaction = true }),
                        loaded("/r/end.md", {}),
                    },
                },
            }, no_buffer)

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            --- The row of the first line holding `text`.
            --- @param text string
            --- @return integer|nil
            local function row_of(text)
                for i, line in ipairs(lines) do
                    if line:find(text, 1, true) then
                        return i
                    end
                end
            end
            assert.is_true(row_of("go") < row_of("/r/prompt.md"))
            assert.is_true(row_of("/r/prompt.md") < row_of("intro"))
            assert.is_true(row_of("intro") < row_of("/r/call.md"))
            assert.is_true(row_of("intro") < row_of("hook context"))
            assert.is_true(row_of("/r/call.md") < row_of("after the call"))
            assert.is_true(row_of("hook context") < row_of("after the call"))
            assert.is_true(row_of("after the call") < row_of("/r/compact.md"))
            assert.is_true(row_of("/r/compact.md") < row_of("resumed"))
            assert.is_true(row_of("resumed") < row_of("/r/end.md"))
        end)
    end)
end)
