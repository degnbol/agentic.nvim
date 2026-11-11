local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Claims = require("agentic.skeptic.claims")
local Config = require("agentic.config")
local TextModel = require("agentic.utils.text_model")

describe("agentic.skeptic.Claims", function()
    describe("parse", function()
        it("reads a bare JSON array", function()
            assert.same({ "a", "b" }, Claims.parse('["a", "b"]'))
        end)

        it("reads an array in a fenced block", function()
            assert.same({ "a" }, Claims.parse('Here:\n```json\n["a"]\n```\n'))
        end)

        it("reads no claims", function()
            assert.same({}, Claims.parse("[]"))
        end)

        it("fails on a reply that is not an array of strings", function()
            local claims, err = Claims.parse('{"a": 1}')
            assert.is_nil(claims)
            assert.truthy(err)

            claims, err = Claims.parse("[1]")
            assert.is_nil(claims)
            assert.truthy(err)
        end)
    end)

    describe("extract", function()
        --- @type TestStub
        local complete_stub

        before_each(function()
            complete_stub = spy.stub(TextModel, "complete")
        end)

        after_each(function()
            complete_stub:revert()
        end)

        it("sends the turn and the checked claims to the extractor", function()
            complete_stub:invokes(function(_request, on_done)
                on_done('["x is 2"]', nil)
            end)
            local result

            Claims.extract({
                prompts = { "fix x" },
                text = "x is 2 now",
                diffs = { "--- a\n+++ a\n" },
                reports = {},
            }, { "y is 1" }, function(claims, err)
                result = { claims = claims, err = err }
            end)

            local request = complete_stub.calls[1][1]
            assert.equal(Config.skeptic.extractor.model, request.model)
            assert.truthy(
                request.input:find("## User prompts\n\nfix x", 1, true)
            )
            assert.truthy(
                request.input:find("## Agent text\n\nx is 2 now", 1, true)
            )
            assert.truthy(request.input:find("## Diffs", 1, true))
            assert.truthy(
                request.input:find(
                    "## Claims already checked\n\ny is 1",
                    1,
                    true
                )
            )
            assert.is_nil(request.input:find("Subagent reports", 1, true))
            assert.same({ claims = { "x is 2" } }, result)
        end)

        it("passes on the text model's error", function()
            complete_stub:invokes(function(_request, on_done)
                on_done(nil, "timeout")
            end)
            local result

            Claims.extract(
                { prompts = {}, text = "t", diffs = {}, reports = {} },
                {},
                function(claims, err)
                    result = { claims = claims, err = err }
                end
            )

            assert.same({ err = "timeout" }, result)
        end)
    end)
end)
