local assert = require("tests.helpers.assert")

local ClaudeUtils = require("agentic.acp.adapters.claude_utils")

describe("agentic.acp.adapters.ClaudeUtils", function()
    describe("task_stop_instruction", function()
        it("names the agent id and label", function()
            assert.equal(
                'Call TaskStop with task_id "a1b2" to stop the background subagent "Explore auth". Do nothing else.',
                ClaudeUtils.task_stop_instruction("a1b2", "Explore auth")
            )
        end)

        it("escapes quotes in the label", function()
            local text = ClaudeUtils.task_stop_instruction("a1", 'say "hi"')
            assert.is_true(text:find('"say \\"hi\\""', 1, true) ~= nil)
        end)
    end)

    describe("send_message_instruction", function()
        it("names the agent id, label and message", function()
            assert.equal(
                'Call SendMessage with to: "a1b2" and message: "focus on tests", to message the background subagent "Explore auth". Send the message verbatim and do nothing else.',
                ClaudeUtils.send_message_instruction(
                    "a1b2",
                    "Explore auth",
                    "focus on tests"
                )
            )
        end)

        it("keeps a multi-line message on one line", function()
            local text =
                ClaudeUtils.send_message_instruction("a1", "x", 'one\n"two"')
            assert.is_nil(text:find("\n", 1, true))
            assert.is_true(text:find('"one\\n\\"two\\""', 1, true) ~= nil)
        end)
    end)

    describe("config_dir", function()
        it("prefers the provider's env", function()
            assert.equal(
                "/tmp/from-env",
                ClaudeUtils.config_dir({ CLAUDE_CONFIG_DIR = "/tmp/from-env" })
            )
        end)

        it("falls back to ~/.claude", function()
            local saved = vim.env.CLAUDE_CONFIG_DIR
            vim.env.CLAUDE_CONFIG_DIR = nil
            local dir = ClaudeUtils.config_dir(nil)
            vim.env.CLAUDE_CONFIG_DIR = saved
            assert.equal(vim.fs.normalize("~/.claude"), dir)
        end)
    end)

    describe("session files", function()
        local session_id = "0b8f5c2e-1111-2222-3333-444455556666"
        --- @type string
        local config_dir
        --- @type string
        local session_dir

        before_each(function()
            config_dir = vim.fn.tempname()
            session_dir =
                vim.fs.joinpath(config_dir, "projects", "-tmp-b", session_id)
            vim.fn.mkdir(vim.fs.joinpath(config_dir, "projects", "-tmp-a"), "p")
            vim.fn.mkdir(vim.fs.joinpath(session_dir, "subagents"), "p")
            vim.fn.writefile(
                {},
                vim.fs.joinpath(
                    config_dir,
                    "projects",
                    "-tmp-b",
                    session_id .. ".jsonl"
                )
            )
        end)

        after_each(function()
            vim.fs.rm(config_dir, { recursive = true })
        end)

        it("finds a session in any project directory", function()
            assert.equal(
                session_dir,
                ClaudeUtils.find_session_dir(config_dir, session_id)
            )
        end)

        it("finds no directory for an unknown session", function()
            assert.is_nil(ClaudeUtils.find_session_dir(config_dir, "nope"))
        end)

        --- @param agent_id string
        --- @param lines string[]
        local function write_meta(agent_id, lines)
            vim.fn.writefile(
                lines,
                vim.fs.joinpath(
                    session_dir,
                    "subagents",
                    "agent-" .. agent_id .. ".meta.json"
                )
            )
        end

        it("decodes a subagent's meta file", function()
            write_meta("a1", {
                vim.json.encode({
                    agentType = "Explore",
                    description = "d",
                    toolUseId = "toolu_1",
                    spawnDepth = 1,
                    requestShape = "background",
                }),
            })

            assert.same({
                agent_type = "Explore",
                request_shape = "background",
                tool_use_id = "toolu_1",
            }, ClaudeUtils.subagent_meta(session_dir, "a1"))
        end)

        it("returns nil for a missing meta file", function()
            assert.is_nil(ClaudeUtils.subagent_meta(session_dir, "a2"))
        end)

        it("returns nil for a malformed meta file", function()
            write_meta("a3", { "{not json" })
            assert.is_nil(ClaudeUtils.subagent_meta(session_dir, "a3"))
        end)

        it("returns nil for a meta file without the fields", function()
            write_meta("a4", { "[]" })
            assert.is_nil(ClaudeUtils.subagent_meta(session_dir, "a4"))
        end)
    end)

    describe("agent_id", function()
        it("returns a first generation's id unchanged", function()
            local id, generation = ClaudeUtils.agent_id("a1b2c3")
            assert.equal("a1b2c3", id)
            assert.equal(1, generation)
        end)

        it("strips a later generation's suffix", function()
            local id, generation = ClaudeUtils.agent_id("a1b2c3:generation:3")
            assert.equal("a1b2c3", id)
            assert.equal(3, generation)
        end)
    end)
end)
