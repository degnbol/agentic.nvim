local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("ACPPayloads", function()
    --- @type agentic.acp.ACPPayloads
    local Payloads
    --- @type agentic.utils.FileSystem
    local FileSystem

    local fs_stat_stub
    local read_base64_stub

    before_each(function()
        FileSystem = require("agentic.utils.file_system")
        Payloads = require("agentic.acp.acp_payloads")
    end)

    after_each(function()
        if fs_stat_stub then
            fs_stat_stub:revert()
            fs_stat_stub = nil
        end
        if read_base64_stub then
            read_base64_stub:revert()
            read_base64_stub = nil
        end
    end)

    describe("generate_user_message", function()
        it("creates user message from string", function()
            local msg = Payloads.generate_user_message("hello world")

            assert.equal("user_message_chunk", msg.sessionUpdate)
            assert.equal("text", msg.content.type)
            assert.equal("hello world", msg.content.text)
        end)

        it("creates user message from string array", function()
            local msg =
                Payloads.generate_user_message({ "line 1", "line 2", "line 3" })

            assert.equal("user_message_chunk", msg.sessionUpdate)
            assert.equal("line 1\nline 2\nline 3", msg.content.text)
        end)

        it("creates user message from empty string", function()
            local msg = Payloads.generate_user_message("")
            assert.equal("", msg.content.text)
        end)

        it("creates user message from empty table", function()
            local msg = Payloads.generate_user_message({})
            assert.equal("", msg.content.text)
        end)
    end)

    describe("generate_agent_message", function()
        it("creates agent message from string", function()
            local msg = Payloads.generate_agent_message("agent response")

            assert.equal("agent_message_chunk", msg.sessionUpdate)
            assert.equal("text", msg.content.type)
            assert.equal("agent response", msg.content.text)
        end)

        it("creates agent message from string array", function()
            local msg = Payloads.generate_agent_message({ "first", "second" })

            assert.equal("agent_message_chunk", msg.sessionUpdate)
            assert.equal("first\nsecond", msg.content.text)
        end)
    end)

    describe("_generate_message_chunk", function()
        it("handles non-string non-table input via vim.inspect", function()
            --- @diagnostic disable: invisible, param-type-mismatch
            local msg = Payloads._generate_message_chunk(
                42 --[[@as string]],
                "user_message_chunk"
            )
            --- @diagnostic enable: invisible, param-type-mismatch
            assert.equal("42", msg.content.text)
        end)

        it("sets the correct role", function()
            --- @diagnostic disable: invisible
            local msg =
                Payloads._generate_message_chunk("text", "agent_thought_chunk")
            --- @diagnostic enable: invisible
            assert.equal("agent_thought_chunk", msg.sessionUpdate)
        end)
    end)

    describe("create_resource_link_content", function()
        it("creates resource link with correct URI and name", function()
            local result =
                Payloads.create_resource_link_content("/tmp/test.lua")

            assert.equal("resource_link", result.type)
            assert.equal("file:///tmp/test.lua", result.uri)
            assert.equal("test.lua", result.name)
        end)
    end)

    describe("create_file_content", function()
        it("returns image content for image extensions", function()
            read_base64_stub = spy.stub(FileSystem, "read_file_base64")
            read_base64_stub:returns("base64data")

            local result = Payloads.create_file_content("/tmp/photo.png")

            assert.equal("image", result.type)
            --- @cast result agentic.acp.ImageContent
            assert.equal("image/png", result.mimeType)
            assert.equal("base64data", result.data)
            assert.spy(read_base64_stub).was.called(1)
        end)

        it("returns audio content for audio extensions", function()
            read_base64_stub = spy.stub(FileSystem, "read_file_base64")
            read_base64_stub:returns("audiobase64")

            local result = Payloads.create_file_content("/tmp/song.mp3")

            assert.equal("audio", result.type)
            --- @cast result agentic.acp.AudioContent
            assert.equal("audio/mpeg", result.mimeType)
            assert.equal("audiobase64", result.data)
        end)

        it("returns resource link for non-media files", function()
            local result = Payloads.create_file_content("/tmp/code.lua")

            assert.equal("resource_link", result.type)
            --- @cast result agentic.acp.ResourceLinkContent
            assert.equal("code.lua", result.name)
        end)
    end)
end)
