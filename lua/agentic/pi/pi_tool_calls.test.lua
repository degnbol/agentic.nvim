local PiToolCalls = require("agentic.pi.pi_tool_calls")
local assert = require("tests.helpers.assert")

describe("agentic.pi.PiToolCalls", function()
    describe("resolve_path", function()
        it("reads relative, @-prefixed and ~ paths as pi does", function()
            assert.equal(
                "/w/a/b.lua",
                PiToolCalls.resolve_path("a/b.lua", "/w")
            )
            assert.equal("/w/a.lua", PiToolCalls.resolve_path("@a.lua", "/w"))
            assert.equal("/abs/x", PiToolCalls.resolve_path("/abs/x", "/w"))
            assert.equal(
                vim.fs.normalize("~") .. "/x",
                PiToolCalls.resolve_path("~/x", "/w")
            )
        end)
    end)

    describe("from_start", function()
        it("puts a bash command in the argument", function()
            local block = PiToolCalls.from_start({
                toolCallId = "c1",
                toolName = "bash",
                args = { command = "ls -la" },
            }, "/w")
            assert.same({
                tool_call_id = "c1",
                kind = "execute",
                argument = "ls -la",
                status = "pending",
            }, block)
        end)

        it("resolves a read's path and keeps its line range", function()
            local block = PiToolCalls.from_start({
                toolCallId = "c2",
                toolName = "read",
                args = { path = "f.txt", offset = 10, limit = 5 },
            }, "/w")
            assert.equal("/w/f.txt", block.argument)
            assert.same({ offset = 10, limit = 5 }, block.read_range)
        end)

        it("gives a write its content as the new side", function()
            local block = PiToolCalls.from_start({
                toolCallId = "c3",
                toolName = "write",
                args = { path = "f.txt", content = "a\nb" },
            }, "/w")
            assert.same({ old = {}, new = { "a", "b" } }, block.diff)
        end)

        it("names an unknown tool by itself", function()
            local block = PiToolCalls.from_start({
                toolCallId = "c4",
                toolName = "web_fetch",
                args = { url = "https://x" },
            }, "/w")
            assert.equal("other", block.kind)
            assert.equal("web_fetch", block.argument)
        end)
    end)

    describe("from_end", function()
        it("rejects a failed call without durationMs", function()
            local update = PiToolCalls.from_end({
                toolCallId = "c1",
                toolName = "edit",
                isError = true,
                result = {
                    content = { { type = "text", text = "bad args\ndetail" } },
                },
            })
            assert.same({
                tool_call_id = "c1",
                status = "failed",
                rejection = "bad args",
                failure_reason = { "detail" },
            }, update)
        end)

        it("keeps a failed run's whole text as its failure", function()
            local update = PiToolCalls.from_end({
                toolCallId = "c1",
                toolName = "bash",
                isError = true,
                durationMs = 3,
                result = { content = { { type = "text", text = "exit 1" } } },
            })
            assert.is_nil(update.rejection)
            assert.same({ "exit 1" }, update.failure_reason)
        end)

        it("gives a run's text as body, except for edit and write", function()
            local bash = PiToolCalls.from_end({
                toolCallId = "c1",
                toolName = "bash",
                isError = false,
                durationMs = 3,
                result = { content = { { type = "text", text = "x\ny" } } },
            })
            assert.same({ "x", "y" }, bash.body)
            assert.is_nil(bash.rejection)
            local edit = PiToolCalls.from_end({
                toolCallId = "c2",
                toolName = "edit",
                isError = false,
                durationMs = 3,
                result = { content = { { type = "text", text = "ok" } } },
            })
            assert.is_nil(edit.body)
        end)
    end)

    describe("edit_diff", function()
        local dir, path

        before_each(function()
            dir = vim.fn.tempname()
            vim.fn.mkdir(dir, "p")
            path = dir .. "/f.txt"
            vim.fn.writefile({ "one", "two", "three", "four", "five" }, path)
        end)

        after_each(function()
            vim.fs.rm(dir, { recursive = true })
        end)

        it("covers every replacement with one pair of whole lines", function()
            local diff = PiToolCalls.edit_diff({
                path = "f.txt",
                edits = {
                    { oldText = "our", newText = "OUR" },
                    { oldText = "tw", newText = "TW" },
                },
            }, dir)
            assert.same({
                old = { "two", "three", "four" },
                new = { "TWo", "three", "fOUR" },
            }, diff)
        end)

        it("is nil when an oldText is not in the file", function()
            assert.is_nil(PiToolCalls.edit_diff({
                path = path,
                edits = { { oldText = "six", newText = "6" } },
            }, dir))
        end)
    end)
end)
