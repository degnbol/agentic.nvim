local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local ShellFormat = require("agentic.utils.shell_format")

describe("agentic.utils.ShellFormat", function()
    local LONG =
        "cd /some/very/long/project/path && npm install --save-dev typescript && npm run build && npm test"

    it("splits a long command at top-level operators", function()
        assert.equal(
            "cd /some/very/long/project/path &&\nnpm install --save-dev typescript &&\nnpm run build &&\nnpm test",
            ShellFormat.format(LONG, nil)
        )
    end)

    it("leaves a short command as it is", function()
        assert.equal(
            "ls && echo done",
            ShellFormat.format("ls && echo done", nil)
        )
    end)

    it("does not split inside quotes or subshells", function()
        assert.equal(
            'echo "a && b" &&\nx=$(c && d) &&\necho done with a long enough command line here, really',
            ShellFormat.format(
                'echo "a && b" && x=$(c && d) && echo done with a long enough command line here, really',
                nil
            )
        )
    end)

    describe("with a formatter", function()
        local executable_stub
        local system_stub

        before_each(function()
            executable_stub = spy.stub(vim.fn, "executable")
            executable_stub:returns(1)
            system_stub = spy.stub(vim, "system")
            system_stub:invokes(function(cmd)
                return {
                    wait = function()
                        return { code = 0, stdout = cmd[1] .. ":" .. "out\n" }
                    end,
                }
            end)
        end)

        after_each(function()
            executable_stub:revert()
            system_stub:revert()
        end)

        it("returns the formatter's output", function()
            assert.equal("fmt-a:out", ShellFormat.format("cache-a", "fmt-a"))
        end)

        it("keys the cache on the formatter", function()
            assert.equal("fmt-b:out", ShellFormat.format("cache-b", "fmt-b"))
            assert.equal("fmt-c:out", ShellFormat.format("cache-b", "fmt-c"))
            assert.equal(2, system_stub.call_count)
            ShellFormat.format("cache-b", "fmt-b")
            assert.equal(2, system_stub.call_count)
        end)
    end)
end)
