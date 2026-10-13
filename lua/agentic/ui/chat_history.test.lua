local MiniTest = require("mini.test")
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local TEST_CWD = "/test/project"

describe("ChatHistory", function()
    --- @type agentic.ui.ChatHistory
    local ChatHistory
    --- @type agentic.utils.FileSystem
    local FileSystem
    local original_storage_path
    --- @type TestStub|nil
    local cwd_stub
    --- @type TestStub
    local mkdirp_stub
    --- @type TestStub
    local write_file_stub
    --- @type TestStub
    local read_from_disk_stub
    --- @type table<string, string>
    local mock_files

    before_each(function()
        package.loaded["agentic.ui.chat_history"] = nil

        mock_files = {}

        FileSystem = require("agentic.utils.file_system")

        mkdirp_stub = spy.stub(FileSystem, "mkdirp")
        mkdirp_stub:returns(true)

        write_file_stub = spy.stub(FileSystem, "write_file")
        write_file_stub:invokes(function(path, content, callback)
            mock_files[path] = content
            callback(nil)
        end)

        read_from_disk_stub = spy.stub(FileSystem, "read_from_disk")
        read_from_disk_stub:invokes(function(path)
            local content = mock_files[path]
            if not content then
                return nil, "No such file: " .. path
            end
            return vim.split(content, "\n"), nil
        end)

        local Config = require("agentic.config")
        original_storage_path = Config.session_restore.storage_path
        Config.session_restore.storage_path = "/test/storage"

        ChatHistory = require("agentic.ui.chat_history")
    end)

    after_each(function()
        if cwd_stub then
            cwd_stub:revert()
            cwd_stub = nil
        end
        mkdirp_stub:revert()
        write_file_stub:revert()
        read_from_disk_stub:revert()
        local Config = require("agentic.config")
        Config.session_restore.storage_path = original_storage_path
        package.loaded["agentic.ui.chat_history"] = nil
    end)

    --- Make the process cwd `/other`, so a case can show that no path
    --- comes from it.
    local function stub_process_cwd()
        cwd_stub = spy.stub(vim.uv, "cwd")
        cwd_stub:returns("/other")
    end

    --- Make writes and reads use the disk, in a fresh storage folder.
    local function use_disk()
        require("agentic.config").session_restore.storage_path =
            vim.fn.tempname()
        write_file_stub:invokes(function(path, content, callback)
            vim.fn.mkdir(vim.fs.dirname(path), "p")
            vim.fn.writefile(vim.split(content, "\n"), path)
            callback(nil)
        end)
        read_from_disk_stub:revert()
    end

    --- @param session_id string
    --- @return agentic.ui.ChatHistory
    local function history_with_id(session_id)
        local history = ChatHistory:new()
        history.session_id = session_id
        return history
    end

    describe("get_project_folder", function()
        it("normalizes paths and appends hash suffix", function()
            local test_cases = {
                {
                    path = "/Users/me/projects/myapp",
                    pattern = "Users_me_projects_myapp",
                },
                {
                    path = "/Users/my user/my projects",
                    pattern = "my_user.*my_projects",
                },
                {
                    path = "C:\\Users\\me\\projects",
                    pattern = "C_.*Users_me_projects",
                },
            }

            for _, tc in ipairs(test_cases) do
                local folder = ChatHistory.get_project_folder(tc.path)

                assert.truthy(folder:match(tc.pattern))
                assert.is_nil(folder:match("^_"))

                local hash = folder:match("_(%x+)$")
                assert.is_not_nil(hash)
                assert.equal(8, #hash)
            end
        end)

        it("produces unique hashes for different paths", function()
            assert.are_not.equal(
                ChatHistory.get_project_folder("/path/one"),
                ChatHistory.get_project_folder("/path/two")
            )
        end)

        it("does not depend on the process cwd", function()
            local before = ChatHistory.get_project_folder(TEST_CWD)
            stub_process_cwd()
            assert.equal(before, ChatHistory.get_project_folder(TEST_CWD))
        end)
    end)

    describe("get_file_path", function()
        it(
            "combines storage_path, project_folder, and session_id.json",
            function()
                local path = ChatHistory.get_file_path("session-abc", TEST_CWD)
                local project_folder = ChatHistory.get_project_folder(TEST_CWD)

                assert.truthy(path:match("^" .. vim.pesc("/test/storage")))
                assert.truthy(path:find(project_folder, 1, true))
                assert.truthy(path:match("session%-abc%.json$"))
            end
        )
    end)

    describe("find_files", function()
        before_each(use_disk)

        it("find_files lists every copy, newest first", function()
            assert.is_nil(history_with_id("sid-m"):save("/project/a"))
            assert.is_nil(history_with_id("sid-m"):save("/project/b"))
            assert.is_nil(history_with_id("sid-m"):save("/project/c"))
            local times = { ["/project/a"] = 2000, ["/project/b"] = 3000 }
            times["/project/c"] = 1000
            for cwd, t in pairs(times) do
                vim.uv.fs_utime(ChatHistory.get_file_path("sid-m", cwd), t, t)
            end

            assert.same(
                vim.tbl_map(function(cwd)
                    return ChatHistory.get_file_path("sid-m", cwd)
                end, { "/project/b", "/project/a", "/project/c" }),
                ChatHistory.find_files("sid-m")
            )
        end)

        it("finds the file in another project folder", function()
            assert.is_nil(history_with_id("sid-a"):save("/project/a"))

            assert.equal(
                ChatHistory.get_file_path("sid-a", "/project/a"),
                ChatHistory.find_files("sid-a")[1]
            )
        end)

        for _, aged in ipairs({ "/project/a", "/project/b" }) do
            it(
                "returns the newest file when two folders hold the id, "
                    .. aged
                    .. " older",
                function()
                    assert.is_nil(history_with_id("sid-2"):save("/project/a"))
                    assert.is_nil(history_with_id("sid-2"):save("/project/b"))
                    vim.uv.fs_utime(
                        ChatHistory.get_file_path("sid-2", aged),
                        1000,
                        1000
                    )
                    local newer = aged == "/project/a" and "/project/b"
                        or "/project/a"

                    assert.equal(
                        ChatHistory.get_file_path("sid-2", newer),
                        ChatHistory.find_files("sid-2")[1]
                    )
                end
            )
        end

        it("breaks a same-second tie by nanoseconds", function()
            assert.is_nil(history_with_id("sid-3"):save("/project/a"))
            assert.is_nil(history_with_id("sid-3"):save("/project/b"))
            vim.uv.fs_utime(
                ChatHistory.get_file_path("sid-3", "/project/a"),
                1000.2,
                1000.2
            )
            vim.uv.fs_utime(
                ChatHistory.get_file_path("sid-3", "/project/b"),
                1000.1,
                1000.1
            )

            assert.equal(
                ChatHistory.get_file_path("sid-3", "/project/a"),
                ChatHistory.find_files("sid-3")[1]
            )
        end)

        it("returns nil for an unknown id", function()
            assert.is_nil(history_with_id("sid-k"):save("/project/a"))
            assert.is_nil(ChatHistory.find_files("sid-unknown")[1])
        end)
    end)

    describe("prepend_restored_messages", function()
        --- @param subagent agentic.ui.MessageWriter.SubagentInfo
        --- @return string text
        local function prepended(subagent)
            local prompt = {}
            ChatHistory.prepend_restored_messages({
                {
                    type = "tool_call",
                    tool_call_id = "child-1",
                    kind = "SubAgent",
                    status = "completed",
                    argument = "agentic://1/subagent/map-UI-child-1",
                    body = { "Find the files." },
                    subagent = subagent,
                },
            }, prompt)
            return prompt[1].text
        end

        it("renders a subagent block as type, name and status", function()
            assert.equal(
                'Subagent Explore "map UI": completed',
                prepended({
                    label = "map UI",
                    agent_type = "Explore",
                    mode = "blocking",
                    confirmed = true,
                })
            )
        end)

        it("renders a subagent block without a type", function()
            assert.equal(
                'Subagent "map UI": completed',
                prepended({
                    label = "map UI",
                    mode = "background",
                    confirmed = false,
                })
            )
        end)
    end)

    describe("message operations", function()
        it("marks the history dirty when a subagent's task is set", function()
            local history = ChatHistory:new()

            history:set_subagent_task("child-1", "toolu_1")

            assert.same({ task_id = "toolu_1" }, history.subagents["child-1"])
            assert.is_true(history.dirty)
        end)

        it("moves a subagent's messages to its Task id once known", function()
            local history = ChatHistory:new()
            history:add_message({
                type = "agent",
                text = "early",
                provider_name = "p",
                parent_tool_use_id = "child-1",
            })

            history:set_subagent_task("child-1", "toolu_1")

            assert.equal(
                "toolu_1",
                history.subagent_messages[1].parent_tool_use_id
            )
        end)

        it("messages_for_task keeps one agent's messages, in order", function()
            local history = ChatHistory:new()
            history.subagent_messages = {
                {
                    type = "agent",
                    text = "a1",
                    provider_name = "p",
                    parent_tool_use_id = "a",
                },
                {
                    type = "agent",
                    text = "b1",
                    provider_name = "p",
                    parent_tool_use_id = "b",
                },
                {
                    type = "tool_call",
                    tool_call_id = "a-tool",
                    kind = "read",
                    status = "completed",
                    parent_tool_use_id = "a",
                },
            }

            assert.same(
                { "a1", "a-tool" },
                vim.tbl_map(function(msg)
                    return msg.text or msg.tool_call_id
                end, history:messages_for_task("a"))
            )
        end)

        it("add_message preserves insertion order", function()
            local history = ChatHistory:new()

            history:add_message({
                type = "user",
                text = "First",
                timestamp = os.time(),
                provider_name = "test-provider",
            })
            history:add_message({
                type = "agent",
                text = "Second",
                provider_name = "test-provider",
            })

            assert.equal(2, #history.messages)
            assert.equal("user", history.messages[1].type)
            assert.equal("agent", history.messages[2].type)
        end)

        describe("append_agent_text", function()
            it("creates new or appends based on last message type", function()
                local history = ChatHistory:new()

                history:append_agent_text({
                    type = "agent",
                    text = "Hello",
                    provider_name = "test-provider",
                })
                assert.equal(1, #history.messages)
                assert.equal("Hello", history.messages[1].text)

                history:append_agent_text({
                    type = "agent",
                    text = " World",
                    provider_name = "test-provider",
                })
                assert.equal(1, #history.messages)
                assert.equal("Hello World", history.messages[1].text)

                history:add_message({
                    type = "user",
                    text = "Hi",
                    timestamp = os.time(),
                    provider_name = "test-provider",
                })
                history:append_agent_text({
                    type = "agent",
                    text = "Response",
                    provider_name = "test-provider",
                })
                assert.equal(3, #history.messages)
                assert.equal("agent", history.messages[3].type)
            end)

            it("treats agent and thought as separate types", function()
                local history = ChatHistory:new()

                history:append_agent_text({
                    type = "agent",
                    text = "Response",
                    provider_name = "test-provider",
                })
                history:append_agent_text({
                    type = "thought",
                    text = "Thinking...",
                    provider_name = "test-provider",
                })

                assert.equal(2, #history.messages)
                assert.equal("agent", history.messages[1].type)
                assert.equal("thought", history.messages[2].type)
            end)

            --- Text of one agent message built from `first` then `second`.
            --- @param first string
            --- @param second string
            --- @param starts_response boolean|nil Passed with `second`
            --- @return string
            local function merged(first, second, starts_response)
                local history = ChatHistory:new()
                history:append_agent_text({
                    type = "agent",
                    text = first,
                    provider_name = "test-provider",
                })
                history:append_agent_text({
                    type = "agent",
                    text = second,
                    provider_name = "test-provider",
                }, starts_response)
                assert.equal(1, #history.messages)
                return history.messages[1].text
            end

            it("separates a new response by a blank line", function()
                assert.equal("one.\n\nTwo", merged("one.", "Two", true))
            end)

            it("joins directly within one response", function()
                assert.equal("one.Two", merged("one.", "Two", false))
                assert.equal("one.Two", merged("one.", "Two", nil))
            end)

            it("adds nothing after a blank line", function()
                assert.equal("one.\n\nTwo", merged("one.\n\n", "Two", true))
                assert.equal("one.\n  \nTwo", merged("one.\n  \n", "Two", true))
            end)

            it("merges by parent across another parent's messages", function()
                local history = ChatHistory:new()
                --- @param parent string
                --- @param text string
                --- @param starts_response boolean|nil
                local function append(parent, text, starts_response)
                    history:append_agent_text({
                        type = "agent",
                        text = text,
                        provider_name = "test-provider",
                        parent_tool_use_id = parent,
                    }, starts_response)
                end

                append("task-a", "a1")
                append("task-b", "b1")
                append("task-a", "a2")
                append("task-a", "A", true)

                assert.same({}, history.messages)
                assert.equal(2, #history.subagent_messages)
                assert.equal("a1a2\n\nA", history.subagent_messages[1].text)
                assert.equal("b1", history.subagent_messages[2].text)
                assert.is_true(history.dirty)
            end)

            it("merges across another parent's tool call", function()
                local history = ChatHistory:new()
                --- @param text string
                local function append_a(text)
                    history:append_agent_text({
                        type = "agent",
                        text = text,
                        provider_name = "test-provider",
                        parent_tool_use_id = "task-a",
                    })
                end

                append_a("a1")
                history:add_message({
                    type = "tool_call",
                    tool_call_id = "tc-b",
                    status = "pending",
                    kind = "read",
                    parent_tool_use_id = "task-b",
                })
                append_a("a2")

                assert.same(
                    { "agent", "tool_call" },
                    vim.tbl_map(function(msg)
                        return msg.type
                    end, history.subagent_messages)
                )
                assert.equal("a1a2", history.subagent_messages[1].text)
            end)
        end)

        it("add_message puts a tagged message in subagent_messages", function()
            local history = ChatHistory:new()

            history:add_message({
                type = "tool_call",
                tool_call_id = "tc-sub",
                status = "pending",
                kind = "read",
                parent_tool_use_id = "task-1",
            })

            assert.same({}, history.messages)
            assert.equal(1, #history.subagent_messages)
            assert.is_true(history.dirty)
        end)

        describe("update_tool_call", function()
            it("finds and merges tool_call by ID", function()
                local history = ChatHistory:new()

                history:add_message({
                    type = "tool_call",
                    tool_call_id = "tc-123",
                    status = "pending",
                    kind = "read",
                })

                history:update_tool_call("tc-123", {
                    tool_call_id = "tc-123",
                    status = "completed",
                    body = { "content" },
                    type = "tool_call",
                })

                assert.equal("completed", history.messages[1].status)
                assert.is_not_nil(history.messages[1].body)
            end)

            it("finds a subagent tool_call", function()
                local history = ChatHistory:new()
                history:add_message({
                    type = "tool_call",
                    tool_call_id = "tc-sub",
                    status = "pending",
                    kind = "read",
                    parent_tool_use_id = "task-1",
                })

                history:update_tool_call("tc-sub", {
                    tool_call_id = "tc-sub",
                    status = "completed",
                    type = "tool_call",
                })

                assert.equal("completed", history.subagent_messages[1].status)
                assert.equal(
                    "task-1",
                    history.subagent_messages[1].parent_tool_use_id
                )
            end)

            it("does nothing if tool_call not found", function()
                local history = ChatHistory:new()
                history:add_message({
                    type = "user",
                    text = "Hello",
                    timestamp = os.time(),
                    provider_name = "test-provider",
                })

                history:update_tool_call(
                    "non-existent",
                    { status = "completed", type = "tool_call" }
                )

                assert.equal(1, #history.messages)
                assert.equal("user", history.messages[1].type)
            end)
        end)
    end)

    describe("save and read", function()
        --- The history saved for `session_id` under `TEST_CWD`.
        --- @param session_id string
        --- @return agentic.ui.ChatHistory|nil history
        --- @return string|nil err
        local function read(session_id)
            local data, err = FileSystem.read_json(
                ChatHistory.get_file_path(session_id, TEST_CWD)
            )
            return data and ChatHistory.from_data(data), err
        end

        it("writes to the folder of cwd and records cwd", function()
            stub_process_cwd()
            assert.is_nil(history_with_id("sid-cwd"):save(TEST_CWD))

            local content =
                mock_files[ChatHistory.get_file_path("sid-cwd", TEST_CWD)]
            assert.is_not_nil(content)
            assert.equal(TEST_CWD, vim.json.decode(content).cwd)
            local other_folder = ChatHistory.get_sessions_folder("/other")
            for path in pairs(mock_files) do
                assert.is_nil(path:find(other_folder, 1, true))
            end
        end)

        it("persists and restores ChatHistory instance", function()
            local original = ChatHistory:new()
            original.session_id = "roundtrip-test"
            original.provider = "claude-agent-acp"
            original.provider_version = "0.66.0"
            original:add_message({
                type = "user",
                text = "Test message",
                timestamp = os.time(),
                provider_name = "test-provider",
            })
            original:set_title("Test message")
            assert.is_true(original.dirty)

            assert.is_nil(original:save(TEST_CWD))
            assert.is_false(original.dirty)

            local path =
                ChatHistory.get_file_path(original.session_id, TEST_CWD)
            assert.equal(1, mkdirp_stub.call_count)
            assert.equal(1, write_file_stub.call_count)

            local saved_content = mock_files[path]
            assert.is_not_nil(saved_content)

            local parsed = vim.json.decode(saved_content)
            assert.equal(original.session_id, parsed.session_id)
            assert.equal("Test message", parsed.title)
            assert.is_not_nil(parsed.timestamp)
            assert.equal("claude-agent-acp", parsed.provider)
            assert.equal("0.66.0", parsed.provider_version)

            local loaded, load_err = read(original.session_id)

            assert.is_nil(load_err)
            assert.is_not_nil(loaded)
            --- @cast loaded agentic.ui.ChatHistory
            assert.equal(original.session_id, loaded.session_id)
            assert.equal(original.timestamp, loaded.timestamp)
            assert.equal(original.provider_version, loaded.provider_version)
            assert.equal(1, #loaded.messages)
            assert.equal("Test message", loaded.messages[1].text)
            assert.is_false(loaded.dirty)
        end)

        it("round-trips subagent_messages", function()
            local original = ChatHistory:new()
            original.session_id = "subagent-roundtrip"
            original:add_message({
                type = "agent",
                text = "Found it",
                provider_name = "test-provider",
                parent_tool_use_id = "task-1",
            })
            assert.is_nil(original:save(TEST_CWD))

            local loaded = read(original.session_id)

            --- @cast loaded agentic.ui.ChatHistory
            assert.same(original.subagent_messages, loaded.subagent_messages)
        end)

        it("round-trips subagents", function()
            local original = ChatHistory:new()
            original.session_id = "subagents-roundtrip"
            original:set_subagent_task("child-1", "toolu_1")
            assert.is_nil(original:save(TEST_CWD))

            local loaded = read(original.session_id)

            --- @cast loaded agentic.ui.ChatHistory
            assert.same(
                { ["child-1"] = { task_id = "toolu_1" } },
                loaded.subagents
            )
        end)

        it("loads a file without subagents as empty", function()
            local path = ChatHistory.get_file_path("older-agents", TEST_CWD)
            mock_files[path] = vim.json.encode({
                session_id = "older-agents",
                title = "",
                timestamp = 0,
                messages = {},
            })

            local loaded = read("older-agents")

            --- @cast loaded agentic.ui.ChatHistory
            assert.same({}, loaded.subagents)
        end)

        it("loads a file without subagent_messages as empty", function()
            local path = ChatHistory.get_file_path("older", TEST_CWD)
            mock_files[path] = vim.json.encode({
                session_id = "older",
                title = "",
                timestamp = 0,
                messages = {},
            })

            local loaded = read("older")

            --- @cast loaded agentic.ui.ChatHistory
            assert.same({}, loaded.subagent_messages)
        end)

        it("returns error for missing or corrupted files", function()
            local test_cases = {
                { session_id = "non-existent" },
                {
                    session_id = "corrupted",
                    content = "not valid json {{{",
                },
            }

            for _, tc in ipairs(test_cases) do
                if tc.content then
                    local path =
                        ChatHistory.get_file_path(tc.session_id, TEST_CWD)
                    mock_files[path] = tc.content
                end

                local loaded, load_err = read(tc.session_id)

                assert.is_nil(loaded)
                assert.is_not_nil(load_err)
            end
        end)
    end)

    describe("list_sessions", function()
        before_each(use_disk)

        --- @param cwd string
        --- @return agentic.ui.ChatHistory.SessionMeta[]
        local function list(cwd)
            local sessions = {} --- @type agentic.ui.ChatHistory.SessionMeta[]
            ChatHistory.list_sessions(cwd, function(result)
                sessions = result
            end)
            return sessions
        end

        it("returns empty array when no sessions exist", function()
            assert.equal(0, #list(TEST_CWD))
        end)

        it("returns only the sessions of the folder of cwd", function()
            assert.is_nil(history_with_id("sid-here"):save(TEST_CWD))
            assert.is_nil(history_with_id("sid-there"):save("/project/b"))

            assert.same(
                { "sid-here" },
                vim.tbl_map(function(s)
                    return s.session_id
                end, list(TEST_CWD))
            )
        end)

        it("returns all saved sessions in project folder", function()
            local session_ids = { "session-1", "session-2" }

            for _, id in ipairs(session_ids) do
                local s = ChatHistory:new()
                s.session_id = id
                s:add_message({
                    type = "user",
                    text = id .. " message",
                    timestamp = os.time(),
                    provider_name = "test-provider",
                })

                assert.is_nil(s:save(TEST_CWD))
            end

            local sessions = list(TEST_CWD)

            assert.equal(2, #sessions)

            local ids = {}
            for _, s in ipairs(sessions) do
                ids[s.session_id] = true
            end
            assert.is_true(ids["session-1"])
            assert.is_true(ids["session-2"])
        end)

        it("skips an unreadable file with one warning naming it", function()
            assert.is_nil(history_with_id("sid-valid"):save(TEST_CWD))
            local corrupt_path = ChatHistory.get_file_path("sid-bad", TEST_CWD)
            vim.fn.writefile({ "not valid json {{{" }, corrupt_path)
            local Logger = require("agentic.utils.logger")
            local notify_stub = spy.stub(Logger, "notify")
            MiniTest.finally(function()
                notify_stub:revert()
            end)

            local sessions = list(TEST_CWD)

            assert.equal(1, #sessions)
            assert.equal("sid-valid", sessions[1].session_id)
            assert.equal(1, notify_stub.call_count)
            assert.truthy(
                notify_stub.calls[1][1]:find(corrupt_path, 1, true)
            )
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)
    end)
end)
