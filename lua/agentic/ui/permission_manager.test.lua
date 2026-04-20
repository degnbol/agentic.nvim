--- @diagnostic disable: invisible, missing-fields
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.PermissionManager", function()
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type agentic.ui.PermissionManager
    local PermissionManager
    --- @type integer
    local bufnr
    --- @type integer
    local winid
    --- @type agentic.ui.MessageWriter
    local writer
    --- @type agentic.ui.PermissionManager
    local pm
    --- @type TestStub
    local schedule_stub
    --- @type TestStub
    local hint_stub
    --- @type TestStub
    local hint_style_stub

    --- @return agentic.acp.RequestPermission
    local function make_request(tool_call_id)
        return {
            sessionId = "test-session",
            toolCall = {
                toolCallId = tool_call_id,
            },
            options = {
                {
                    optionId = "allow-once",
                    name = "Allow once",
                    kind = "allow_once",
                },
                {
                    optionId = "reject-once",
                    name = "Reject once",
                    kind = "reject_once",
                },
            },
        }
    end

    local function inject_content_and_reanchor()
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(
            bufnr,
            -1,
            -1,
            false,
            { "new tool call output line 1", "new tool call output line 2" }
        )
        vim.bo[bufnr].modifiable = false
        writer:_notify_content_changed()
    end

    --- @param mode string
    --- @param lhs string
    --- @return boolean
    local function has_buf_keymap(mode, lhs)
        for _, km in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
            if km.lhs == lhs then
                return true
            end
        end
        return false
    end

    before_each(function()
        schedule_stub = spy.stub(vim, "schedule")

        local DiffPreview = require("agentic.ui.diff_preview")
        hint_stub = spy.stub(DiffPreview, "add_navigation_hint")
        hint_stub:returns(nil)
        hint_style_stub = spy.stub(DiffPreview, "apply_hint_styling")

        MessageWriter = require("agentic.ui.message_writer")
        PermissionManager = require("agentic.ui.permission_manager")

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
        pm = PermissionManager:new(writer, { chat = bufnr })
    end)

    after_each(function()
        schedule_stub:revert()
        hint_stub:revert()
        hint_style_stub:revert()

        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("auto-approve read-only tools", function()
        --- @type agentic.UserConfig
        local Config

        before_each(function()
            Config = require("agentic.config")
        end)

        --- @param kind agentic.acp.ToolKind
        --- @return agentic.acp.RequestPermission
        local function make_request_with_kind(kind)
            return {
                sessionId = "test-session",
                toolCall = {
                    toolCallId = "tc-readonly-" .. kind,
                    kind = kind,
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                    {
                        optionId = "reject-once",
                        name = "Reject once",
                        kind = "reject_once",
                    },
                },
            }
        end

        it("auto-approves read kind", function()
            local cb = spy.new(function() end)
            pm:add_request(
                make_request_with_kind("read"),
                cb --[[@as function]]
            )
            assert.spy(cb).was.called(1)
            assert.is_true(cb:called_with("allow-once"))
            assert.is_nil(pm.current_request)
        end)

        it("auto-approves search kind", function()
            local cb = spy.new(function() end)
            pm:add_request(
                make_request_with_kind("search"),
                cb --[[@as function]]
            )
            assert.spy(cb).was.called(1)
            assert.is_true(cb:called_with("allow-once"))
        end)

        it("does not auto-approve edit kind", function()
            local cb = spy.new(function() end)
            pm:add_request(
                make_request_with_kind("edit"),
                cb --[[@as function]]
            )
            assert.spy(cb).was.called(0)
            assert.is_not_nil(pm.current_request)
            pm:_complete_request("reject-once")
        end)

        it("does not auto-approve execute kind", function()
            local cb = spy.new(function() end)
            pm:add_request(
                make_request_with_kind("execute"),
                cb --[[@as function]]
            )
            assert.spy(cb).was.called(0)
            pm:_complete_request("reject-once")
        end)

        it("respects config toggle", function()
            local original = Config.auto_approve_read_only_tools
            Config.auto_approve_read_only_tools = false

            local cb = spy.new(function() end)
            pm:add_request(
                make_request_with_kind("read"),
                cb --[[@as function]]
            )
            assert.spy(cb).was.called(0)
            pm:_complete_request("reject-once")

            Config.auto_approve_read_only_tools = original
        end)
    end)

    describe("reanchor permission prompt", function()
        it("moves buttons to buffer bottom and preserves keymaps", function()
            pm:add_request(
                make_request("tc-1"),
                spy.new(function() end) --[[@as function]]
            )

            local line_count_before = vim.api.nvim_buf_line_count(bufnr)
            inject_content_and_reanchor()
            local line_count_after = vim.api.nvim_buf_line_count(bufnr)

            assert.is_true(line_count_after > line_count_before)

            local last_lines = vim.api.nvim_buf_get_lines(bufnr, -3, -1, false)
            local found_permission = false
            for _, line in ipairs(last_lines) do
                if line:find("Allow once") or line:find("--- ---") then
                    found_permission = true
                    break
                end
            end
            assert.is_true(found_permission)

            assert.is_true(has_buf_keymap("n", "1"))
            assert.is_true(has_buf_keymap("n", "2"))
        end)

        it("does not trigger recursive on_content_changed", function()
            local notify_spy = spy.on(writer, "_notify_content_changed")

            pm:add_request(
                make_request("tc-2"),
                spy.new(function() end) --[[@as function]]
            )

            notify_spy:reset()
            writer:_notify_content_changed()

            assert.equal(1, notify_spy.call_count)

            notify_spy:revert()
        end)
    end)

    describe("callback lifecycle", function()
        it("_complete_request clears the content changed callback", function()
            pm:add_request(
                make_request("tc-3"),
                spy.new(function() end) --[[@as function]]
            )

            pm:_complete_request("allow-once")

            assert.is_nil(writer._on_content_changed)
        end)

        it("clear() clears the content changed callback", function()
            pm:add_request(
                make_request("tc-4"),
                spy.new(function() end) --[[@as function]]
            )

            pm:clear()

            assert.is_nil(writer._on_content_changed)
        end)
    end)

    describe("allow_always client-side cache", function()
        --- @param kind agentic.acp.ToolKind
        --- @param file_path string|nil
        --- @return agentic.acp.RequestPermission
        local function make_edit_request(kind, file_path)
            return {
                sessionId = "test-session",
                toolCall = {
                    toolCallId = "tc-cache-"
                        .. kind
                        .. "-"
                        .. (file_path or ""),
                    kind = kind,
                    rawInput = file_path and { file_path = file_path } or nil,
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                    {
                        optionId = "allow-always",
                        name = "Allow always",
                        kind = "allow_always",
                    },
                    {
                        optionId = "reject-once",
                        name = "Reject once",
                        kind = "reject_once",
                    },
                    {
                        optionId = "reject-always",
                        name = "Reject always",
                        kind = "reject_always",
                    },
                },
            }
        end

        it("auto-approves after allow_always for same file", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_edit_request("edit", "/tmp/foo.lua"),
                cb1 --[[@as function]]
            )
            -- User presses allow_always
            pm:_complete_request("allow-always")
            assert.spy(cb1).was.called(1)

            -- Next edit to same file should be auto-approved
            local cb2 = spy.new(function() end)
            pm:add_request(
                make_edit_request("edit", "/tmp/foo.lua"),
                cb2 --[[@as function]]
            )
            assert.spy(cb2).was.called(1)
            assert.is_true(cb2:called_with("allow-once"))
            assert.is_nil(pm.current_request)
        end)

        it("does not auto-approve different file after allow_always", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_edit_request("edit", "/tmp/foo.lua"),
                cb1 --[[@as function]]
            )
            pm:_complete_request("allow-always")

            -- Different file should still prompt
            local cb2 = spy.new(function() end)
            pm:add_request(
                make_edit_request("edit", "/tmp/bar.lua"),
                cb2 --[[@as function]]
            )
            assert.spy(cb2).was.called(0)
            assert.is_not_nil(pm.current_request)
            pm:_complete_request("reject-once")
        end)

        it("auto-rejects after reject_always", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_edit_request("edit", "/tmp/foo.lua"),
                cb1 --[[@as function]]
            )
            pm:_complete_request("reject-always")

            local cb2 = spy.new(function() end)
            pm:add_request(
                make_edit_request("edit", "/tmp/foo.lua"),
                cb2 --[[@as function]]
            )
            assert.spy(cb2).was.called(1)
            assert.is_true(cb2:called_with("reject-once"))
        end)

        it("clear() resets the cache", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_edit_request("edit", "/tmp/foo.lua"),
                cb1 --[[@as function]]
            )
            pm:_complete_request("allow-always")

            pm:clear()

            -- Should prompt again after clear
            local cb2 = spy.new(function() end)
            pm:add_request(
                make_edit_request("edit", "/tmp/foo.lua"),
                cb2 --[[@as function]]
            )
            assert.spy(cb2).was.called(0)
            assert.is_not_nil(pm.current_request)
            pm:_complete_request("reject-once")
        end)

        it("non-file-scoped kinds cache by kind alone", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_edit_request("execute", nil),
                cb1 --[[@as function]]
            )
            pm:_complete_request("allow-always")

            local cb2 = spy.new(function() end)
            pm:add_request(
                make_edit_request("execute", nil),
                cb2 --[[@as function]]
            )
            assert.spy(cb2).was.called(1)
            assert.is_true(cb2:called_with("allow-once"))
        end)
    end)

    describe("empty line accumulation during reanchor", function()
        --- @return string[]
        local function get_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        --- @return integer
        local function count_trailing_empty_lines()
            local lines = get_lines()
            local count = 0
            for i = #lines, 1, -1 do
                if lines[i] == "" then
                    count = count + 1
                else
                    break
                end
            end
            return count
        end

        it(
            "single display+remove leaves exactly one trailing separator",
            function()
                vim.bo[bufnr].modifiable = true
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "line 1", "line 2", "line 3" }
                )
                vim.bo[bufnr].modifiable = false

                local lines_before = vim.api.nvim_buf_line_count(bufnr)

                pm:add_request(
                    make_request("tc-sep-1"),
                    spy.new(function() end) --[[@as function]]
                )

                assert.is_true(
                    vim.api.nvim_buf_line_count(bufnr) > lines_before
                )

                pm:_complete_request("allow-once")

                -- remove_permission_buttons replaces the block with {""},
                -- so buffer should be original lines + 1 separator
                assert.equal(
                    lines_before + 1,
                    vim.api.nvim_buf_line_count(bufnr)
                )
                assert.equal(1, count_trailing_empty_lines())
            end
        )

        it(
            "does not accumulate empty lines across multiple reanchors",
            function()
                vim.bo[bufnr].modifiable = true
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "line 1", "line 2", "line 3" }
                )
                vim.bo[bufnr].modifiable = false

                pm:add_request(
                    make_request("tc-accum-1"),
                    spy.new(function() end) --[[@as function]]
                )

                -- Simulate 5 reanchor cycles (new content triggers reanchor)
                for _ = 1, 5 do
                    inject_content_and_reanchor()
                end

                pm:_complete_request("allow-once")

                -- Should have exactly 1 trailing empty line, not 1 per cycle
                assert.equal(1, count_trailing_empty_lines())
            end
        )

        it(
            "reanchor preserves single separator between content and buttons",
            function()
                vim.bo[bufnr].modifiable = true
                vim.api.nvim_buf_set_lines(
                    bufnr,
                    0,
                    -1,
                    false,
                    { "line 1", "line 2", "line 3" }
                )
                vim.bo[bufnr].modifiable = false

                pm:add_request(
                    make_request("tc-sep-2"),
                    spy.new(function() end) --[[@as function]]
                )

                -- Reanchor once
                inject_content_and_reanchor()

                -- Find last injected content line, then count empty lines after it
                local lines = get_lines()
                local last_content_idx = 0
                for i = 1, #lines do
                    if lines[i]:find("new tool call output") then
                        last_content_idx = i
                    end
                end
                assert.is_true(last_content_idx > 0)

                local empty_count = 0
                for i = last_content_idx + 1, #lines do
                    if lines[i] == "" then
                        empty_count = empty_count + 1
                    else
                        break
                    end
                end
                assert.equal(1, empty_count)

                pm:_complete_request("allow-once")
            end
        )
    end)

    describe("trust scope", function()
        --- @type agentic.utils.TrustSafety
        local TrustSafety
        --- @type agentic.utils.GitFiles
        local GitFiles
        --- @type agentic.utils.FileSystem
        local FileSystem
        --- @type TestStub
        local fs_stat_stub
        --- @type TestStub
        local fs_lstat_stub
        --- @type TestStub
        local read_disk_stub
        --- @type TestStub
        local is_tracked_stub
        --- @type TestStub
        local diff_hunks_stub
        --- @type TestStub
        local get_git_root_stub

        --- @param tool_call_id string
        --- @param kind agentic.acp.ToolKind
        --- @param file_path string
        --- @return agentic.acp.RequestPermission
        local function make_trust_request(tool_call_id, kind, file_path)
            return {
                sessionId = "test-session",
                toolCall = {
                    toolCallId = tool_call_id,
                    kind = kind,
                    rawInput = { file_path = file_path },
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                    {
                        optionId = "reject-once",
                        name = "Reject once",
                        kind = "reject_once",
                    },
                },
            }
        end

        before_each(function()
            TrustSafety = require("agentic.utils.trust_safety")
            GitFiles = require("agentic.utils.git_files")
            FileSystem = require("agentic.utils.file_system")

            fs_stat_stub = spy.stub(vim.uv, "fs_stat")
            fs_stat_stub:returns({
                mtime = { sec = 1, nsec = 0 },
                size = 100,
                type = "file",
            })

            fs_lstat_stub = spy.stub(vim.uv, "fs_lstat")
            fs_lstat_stub:returns({
                mtime = { sec = 1, nsec = 0 },
                size = 100,
                type = "file",
            })

            read_disk_stub = spy.stub(FileSystem, "read_from_disk")
            read_disk_stub:invokes(function(_)
                return { "line 1", "line 2" }, nil
            end)

            is_tracked_stub = spy.stub(GitFiles, "is_tracked")
            is_tracked_stub:returns(true)

            diff_hunks_stub = spy.stub(GitFiles, "diff_hunks")
            diff_hunks_stub:returns({})

            get_git_root_stub = spy.stub(GitFiles, "get_git_root")
            get_git_root_stub:returns("/repo")
        end)

        after_each(function()
            fs_stat_stub:revert()
            fs_lstat_stub:revert()
            read_disk_stub:revert()
            is_tracked_stub:revert()
            diff_hunks_stub:revert()
            get_git_root_stub:revert()
        end)

        it("falls through when no scope is set", function()
            local cb = spy.new(function() end)
            pm:add_request(
                make_trust_request("tc-no-scope", "edit", "/repo/a.lua"),
                cb --[[@as function]]
            )
            assert.spy(cb).was.called(0)
            pm:_complete_request("reject-once")
        end)

        it("auto-approves edit on tracked clean file in scope", function()
            pm:set_trust_scope(
                TrustSafety.build_reserved_scope("repo", "/repo", "/repo")
            )

            local cb = spy.new(function() end)
            pm:add_request(
                make_trust_request("tc-clean", "edit", "/repo/a.lua"),
                cb --[[@as function]]
            )
            assert.spy(cb).was.called(1)
            assert.is_true(cb:called_with("allow-once"))
        end)

        it("falls through when path is outside scope", function()
            pm:set_trust_scope(
                TrustSafety.build_reserved_scope("repo", "/repo", "/repo")
            )
            is_tracked_stub:returns(false)

            local cb = spy.new(function() end)
            pm:add_request(
                make_trust_request("tc-outside", "edit", "/elsewhere/a.lua"),
                cb --[[@as function]]
            )
            assert.spy(cb).was.called(0)
            pm:_complete_request("reject-once")
        end)

        it(
            "falls through on dirty tracked file when edit overlaps non-Claude hunk",
            function()
                pm:set_trust_scope(
                    TrustSafety.build_reserved_scope("repo", "/repo", "/repo")
                )
                diff_hunks_stub:returns({
                    { start_line = 1, end_line = 1, count = 1 },
                })
                writer.tool_call_blocks["tc-dirty"] = {
                    tool_call_id = "tc-dirty",
                    status = "pending",
                    kind = "edit",
                    argument = "/repo/a.lua",
                    diff = { old = { "line 1" }, new = { "modified" } },
                }

                local cb = spy.new(function() end)
                pm:add_request(
                    make_trust_request("tc-dirty", "edit", "/repo/a.lua"),
                    cb --[[@as function]]
                )
                assert.spy(cb).was.called(0)
                pm:_complete_request("reject-once")
            end
        )

        it(
            "auto-approves when overlapping dirty hunk is Claude-owned and intact",
            function()
                pm:set_trust_scope(
                    TrustSafety.build_reserved_scope("repo", "/repo", "/repo")
                )
                read_disk_stub:invokes(function(_)
                    return { "claude wrote", "claude wrote 2" }, nil
                end)
                diff_hunks_stub:returns({
                    { start_line = 1, end_line = 2, count = 2 },
                })
                pm._edit_records["earlier-tc"] = {
                    path = "/repo/a.lua",
                    start_line = 1,
                    end_line = 2,
                    new_lines = { "claude wrote", "claude wrote 2" },
                }
                writer.tool_call_blocks["tc-claude-edit"] = {
                    tool_call_id = "tc-claude-edit",
                    status = "pending",
                    kind = "edit",
                    argument = "/repo/a.lua",
                    diff = {
                        old = { "claude wrote", "claude wrote 2" },
                        new = { "next iter", "next iter 2" },
                    },
                }

                local cb = spy.new(function() end)
                pm:add_request(
                    make_trust_request("tc-claude-edit", "edit", "/repo/a.lua"),
                    cb --[[@as function]]
                )
                assert.spy(cb).was.called(1)
                assert.is_true(cb:called_with("allow-once"))
            end
        )

        it(
            "falls through when Claude-owned range was modified by user",
            function()
                pm:set_trust_scope(
                    TrustSafety.build_reserved_scope("repo", "/repo", "/repo")
                )
                read_disk_stub:invokes(function(_)
                    return { "user changed this", "claude wrote 2" }, nil
                end)
                diff_hunks_stub:returns({
                    { start_line = 1, end_line = 2, count = 2 },
                })
                pm._edit_records["earlier-tc"] = {
                    path = "/repo/a.lua",
                    start_line = 1,
                    end_line = 2,
                    new_lines = { "claude wrote", "claude wrote 2" },
                }
                writer.tool_call_blocks["tc-user-edit"] = {
                    tool_call_id = "tc-user-edit",
                    status = "pending",
                    kind = "edit",
                    argument = "/repo/a.lua",
                    diff = {
                        old = { "user changed this", "claude wrote 2" },
                        new = { "next", "next 2" },
                    },
                }

                local cb = spy.new(function() end)
                pm:add_request(
                    make_trust_request("tc-user-edit", "edit", "/repo/a.lua"),
                    cb --[[@as function]]
                )
                assert.spy(cb).was.called(0)
                pm:_complete_request("reject-once")
            end
        )

        it(
            "falls through when stat changes between snapshot and approval",
            function()
                pm:set_trust_scope(
                    TrustSafety.build_reserved_scope("repo", "/repo", "/repo")
                )
                local call_count = 0
                fs_stat_stub:invokes(function(_)
                    call_count = call_count + 1
                    if call_count <= 1 then
                        return {
                            mtime = { sec = 1, nsec = 0 },
                            size = 100,
                            type = "file",
                        }
                    end
                    return {
                        mtime = { sec = 2, nsec = 0 },
                        size = 200,
                        type = "file",
                    }
                end)

                local cb = spy.new(function() end)
                pm:add_request(
                    make_trust_request("tc-toctou", "edit", "/repo/a.lua"),
                    cb --[[@as function]]
                )
                assert.spy(cb).was.called(0)
                pm:_complete_request("reject-once")
            end
        )

        it(
            "cached reject_always wins over a would-be-safe trust scope",
            function()
                pm:set_trust_scope(
                    TrustSafety.build_reserved_scope("repo", "/repo", "/repo")
                )
                pm._always_cache["edit:/repo/a.lua"] = "reject"

                local cb = spy.new(function() end)
                pm:add_request(
                    make_trust_request("tc-rej", "edit", "/repo/a.lua"),
                    cb --[[@as function]]
                )
                assert.spy(cb).was.called(1)
                assert.is_true(cb:called_with("reject-once"))
            end
        )

        it("non-file-scoped kinds fall through even with trust set", function()
            pm:set_trust_scope(
                TrustSafety.build_reserved_scope("repo", "/repo", "/repo")
            )

            local cb = spy.new(function() end)
            pm:add_request({
                sessionId = "test-session",
                toolCall = {
                    toolCallId = "tc-exec",
                    kind = "execute",
                    rawInput = { command = "ls" } --[[@as agentic.acp.RawInput]],
                },
                options = {
                    {
                        optionId = "allow-once",
                        name = "Allow once",
                        kind = "allow_once",
                    },
                    {
                        optionId = "reject-once",
                        name = "Reject once",
                        kind = "reject_once",
                    },
                },
            }, cb --[[@as function]])
            assert.spy(cb).was.called(0)
            pm:_complete_request("reject-once")
        end)

        it("clear() wipes the trust scope", function()
            pm:set_trust_scope(
                TrustSafety.build_reserved_scope("repo", "/repo", "/repo")
            )
            pm:clear()
            assert.is_nil(pm:get_trust_scope())
        end)

        it(
            "record_pending_edit + finalize_edit_range produces a record",
            function()
                pm:record_pending_edit(
                    "tc-42",
                    "/repo/a.lua",
                    10,
                    { "new line 1", "new line 2" }
                )
                pm:finalize_edit_range("tc-42")
                local rec = pm._edit_records["tc-42"]
                assert.is_not_nil(rec)
                assert.equal("/repo/a.lua", rec.path)
                assert.equal(10, rec.start_line)
                assert.equal(11, rec.end_line)
                assert.equal(nil, pm._pending_edits["tc-42"])
            end
        )

        it("drop_pending_edit removes pending without finalizing", function()
            pm:record_pending_edit("tc-x", "/repo/a.lua", 1, { "x" })
            pm:drop_pending_edit("tc-x")
            assert.is_nil(pm._pending_edits["tc-x"])
            assert.is_nil(pm._edit_records["tc-x"])
        end)

        it("clear() wipes edit records and pending", function()
            pm:record_pending_edit("tc-a", "/repo/a.lua", 1, { "x" })
            pm:finalize_edit_range("tc-a")
            pm:record_pending_edit("tc-b", "/repo/a.lua", 5, { "y" })
            pm:clear()
            assert.is_nil(pm._edit_records["tc-a"])
            assert.is_nil(pm._pending_edits["tc-b"])
        end)

        it("respects auto_approve_trust_scope toggle", function()
            local Config = require("agentic.config")
            local original = Config.auto_approve_trust_scope
            Config.auto_approve_trust_scope = false

            pm:set_trust_scope(
                TrustSafety.build_reserved_scope("repo", "/repo", "/repo")
            )

            local cb = spy.new(function() end)
            pm:add_request(
                make_trust_request("tc-toggle", "edit", "/repo/a.lua"),
                cb --[[@as function]]
            )
            assert.spy(cb).was.called(0)
            pm:_complete_request("reject-once")

            Config.auto_approve_trust_scope = original
        end)
    end)
end)
