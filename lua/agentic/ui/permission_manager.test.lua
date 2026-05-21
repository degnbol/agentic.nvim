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
    local open_stub

    before_each(function()
        schedule_stub = spy.stub(vim, "schedule")

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
        pm = PermissionManager:new(
            writer,
            { chat = bufnr },
            vim.api.nvim_get_current_tabpage()
        )

        open_stub = spy.stub(pm.permission_float, "open")
        open_stub:invokes(function(_, options)
            local mapping = {}
            for i, opt in ipairs(options) do
                mapping[i] = opt.optionId
            end
            return mapping
        end)
    end)

    after_each(function()
        schedule_stub:revert()
        if open_stub then
            open_stub:revert()
        end

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

        --- @param command string|nil
        --- @param tool_call_id string
        --- @return agentic.acp.RequestPermission
        local function make_execute_request(command, tool_call_id)
            return {
                sessionId = "test-session",
                toolCall = {
                    toolCallId = tool_call_id,
                    kind = "execute",
                    rawInput = command
                            and { command = command } --[[@as agentic.acp.RawInput]]
                        or nil,
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

        it("execute caches per exact command", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_execute_request("ls -la /tmp", "tc-exec-1"),
                cb1 --[[@as function]]
            )
            pm:_complete_request("allow-always")

            local cb2 = spy.new(function() end)
            pm:add_request(
                make_execute_request("ls -la /tmp", "tc-exec-2"),
                cb2 --[[@as function]]
            )
            assert.spy(cb2).was.called(1)
            assert.is_true(cb2:called_with("allow-once"))
        end)

        it("execute does not cross-approve different commands", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_execute_request("ls -la /tmp", "tc-exec-3"),
                cb1 --[[@as function]]
            )
            pm:_complete_request("allow-always")

            -- A different command — git commit — must still prompt even
            -- though both share kind="execute".
            local cb2 = spy.new(function() end)
            pm:add_request(
                make_execute_request("git commit -m foo", "tc-exec-4"),
                cb2 --[[@as function]]
            )
            assert.spy(cb2).was.called(0)
            assert.is_not_nil(pm.current_request)
            pm:_complete_request("reject-once")
        end)

        it("execute reject_always scopes to the rejected command", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_execute_request("rm -rf /tmp/junk", "tc-exec-5"),
                cb1 --[[@as function]]
            )
            pm:_complete_request("reject-always")

            local cb2 = spy.new(function() end)
            pm:add_request(
                make_execute_request("rm -rf /tmp/junk", "tc-exec-6"),
                cb2 --[[@as function]]
            )
            assert.spy(cb2).was.called(1)
            assert.is_true(cb2:called_with("reject-once"))

            -- A different rm invocation is not cached, so it prompts.
            local cb3 = spy.new(function() end)
            pm:add_request(
                make_execute_request("rm -rf /tmp/other", "tc-exec-7"),
                cb3 --[[@as function]]
            )
            assert.spy(cb3).was.called(0)
            assert.is_not_nil(pm.current_request)
            pm:_complete_request("reject-once")
        end)

        it("execute without a command is not cached", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_execute_request(nil, "tc-exec-8"),
                cb1 --[[@as function]]
            )
            pm:_complete_request("allow-always")

            -- Without a command we can't form a meaningful key, so the
            -- next execute request must prompt rather than auto-approve.
            local cb2 = spy.new(function() end)
            pm:add_request(
                make_execute_request(nil, "tc-exec-9"),
                cb2 --[[@as function]]
            )
            assert.spy(cb2).was.called(0)
            assert.is_not_nil(pm.current_request)
            pm:_complete_request("reject-once")
        end)

        --- @param kind string
        --- @param raw_input table|nil
        --- @param tool_call_id string
        --- @return agentic.acp.RequestPermission
        local function make_kind_request(kind, raw_input, tool_call_id)
            return {
                sessionId = "test-session",
                toolCall = {
                    toolCallId = tool_call_id,
                    kind = kind --[[@as agentic.acp.ToolKind]],
                    rawInput = raw_input --[[@as agentic.acp.RawInput]],
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

        it("fetch caches per url, not per kind", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_kind_request(
                    "fetch",
                    { url = "https://example.com/a" },
                    "tc-fetch-1"
                ),
                cb1 --[[@as function]]
            )
            pm:_complete_request("allow-always")

            local cb_same = spy.new(function() end)
            pm:add_request(
                make_kind_request(
                    "fetch",
                    { url = "https://example.com/a" },
                    "tc-fetch-2"
                ),
                cb_same --[[@as function]]
            )
            assert.spy(cb_same).was.called(1)
            assert.is_true(cb_same:called_with("allow-once"))

            local cb_diff = spy.new(function() end)
            pm:add_request(
                make_kind_request(
                    "fetch",
                    { url = "https://other.example/" },
                    "tc-fetch-3"
                ),
                cb_diff --[[@as function]]
            )
            assert.spy(cb_diff).was.called(0)
            assert.is_not_nil(pm.current_request)
            pm:_complete_request("reject-once")
        end)

        it(
            "execute key ignores noise fields (description) across calls",
            function()
                -- claude-agent-acp sends rawInput.description as a human-
                -- readable narration; it can vary between identical commands.
                local cb1 = spy.new(function() end)
                pm:add_request(
                    make_kind_request("execute", {
                        command = "make build",
                        description = "Build the project",
                    }, "tc-noise-1"),
                    cb1 --[[@as function]]
                )
                pm:_complete_request("allow-always")

                local cb2 = spy.new(function() end)
                pm:add_request(
                    make_kind_request("execute", {
                        command = "make build",
                        description = "Compile sources",
                    }, "tc-noise-2"),
                    cb2 --[[@as function]]
                )
                assert.spy(cb2).was.called(1)
                assert.is_true(cb2:called_with("allow-once"))
            end
        )

        it("unknown kinds cache via hybrid (rawInput minus noise)", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_kind_request(
                    "other",
                    { target = "/tmp/x", op = "rename" },
                    "tc-other-1"
                ),
                cb1 --[[@as function]]
            )
            pm:_complete_request("allow-always")

            -- Same rawInput minus a noise field — should still match.
            local cb_same = spy.new(function() end)
            pm:add_request(
                make_kind_request("other", {
                    target = "/tmp/x",
                    op = "rename",
                    description = "Renaming a file",
                }, "tc-other-2"),
                cb_same --[[@as function]]
            )
            assert.spy(cb_same).was.called(1)
            assert.is_true(cb_same:called_with("allow-once"))

            -- Different identifying content — should prompt.
            local cb_diff = spy.new(function() end)
            pm:add_request(
                make_kind_request(
                    "other",
                    { target = "/tmp/y", op = "rename" },
                    "tc-other-3"
                ),
                cb_diff --[[@as function]]
            )
            assert.spy(cb_diff).was.called(0)
            assert.is_not_nil(pm.current_request)
            pm:_complete_request("reject-once")
        end)

        it("unknown kind with no rawInput is not cached", function()
            local cb1 = spy.new(function() end)
            pm:add_request(
                make_kind_request("other", nil, "tc-other-noop-1"),
                cb1 --[[@as function]]
            )
            pm:_complete_request("allow-always")

            local cb2 = spy.new(function() end)
            pm:add_request(
                make_kind_request("other", nil, "tc-other-noop-2"),
                cb2 --[[@as function]]
            )
            assert.spy(cb2).was.called(0)
            assert.is_not_nil(pm.current_request)
            pm:_complete_request("reject-once")
        end)
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
                    -- Command outside read_only_commands list so the
                    -- read-only auto-approve layer doesn't fire — the test
                    -- is about trust scope, not command matching.
                    rawInput = { command = "make build" } --[[@as agentic.acp.RawInput]],
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
