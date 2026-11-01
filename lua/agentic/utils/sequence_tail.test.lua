local SequenceTail = require("agentic.utils.sequence_tail")
local assert = require("tests.helpers.assert")

--- A keyed entry that may start a tail.
--- @param key string
--- @return agentic.utils.SequenceTail.Entry
local function S(key)
    return { key = key, starts = true }
end

--- A keyed entry that never starts a tail.
--- @param key string
--- @return agentic.utils.SequenceTail.Entry
local function K(key)
    return { key = key, starts = false }
end

--- An unkeyed entry.
--- @type agentic.utils.SequenceTail.Entry
local U = { starts = false }

describe("agentic.utils.SequenceTail", function()
    describe("tail_start", function()
        it("finds no tail when both sides hold the same rows", function()
            local rows = { S("p:a"), U, S("t:1"), U }
            assert.equal(5, SequenceTail.tail_start(rows, rows))
        end)

        it("starts at a new starting row after the file's end", function()
            local file = { S("p:a"), S("t:1"), U }
            local replay = { S("p:a"), S("t:1"), U, S("p:b"), U }
            assert.equal(4, SequenceTail.tail_start(file, replay))
        end)

        it(
            "finds no tail in unkeyed and non-starting rows after the match",
            function()
                local file = { S("p:a"), U }
                local replay = { S("p:a"), U, U, K("p:summary"), U }
                assert.equal(6, SequenceTail.tail_start(file, replay))
            end
        )

        it(
            "continues a sequence cut off in the file after its last match",
            function()
                local file = { S("p:a"), U, S("t:1") }
                local replay = { S("p:a"), U, S("t:1"), U, K("p:x"), S("t:2") }
                assert.equal(4, SequenceTail.tail_start(file, replay))
            end
        )

        it("skips a new non-starting row after a cut-off file", function()
            local file = { S("p:a"), U, S("t:1") }
            local replay = { S("p:a"), U, S("t:1"), K("p:interrupted") }
            assert.equal(5, SequenceTail.tail_start(file, replay))
        end)

        it("continues a cut-off file after a new non-starting row", function()
            local file = { S("p:a"), S("t:1") }
            local replay = { S("p:a"), S("t:1"), K("p:summary"), U }
            assert.equal(4, SequenceTail.tail_start(file, replay))
        end)

        it(
            "starts at a new starting row with no new prompt before it",
            function()
                local file = { S("p:a"), S("t:1"), U }
                local replay = { S("p:a"), S("t:1"), U, U, S("t:2"), U }
                assert.equal(5, SequenceTail.tail_start(file, replay))
            end
        )

        it("matches past file rows the replay never has", function()
            local file = { S("p:a"), S("t:hidden"), S("p:b"), U }
            local replay = { S("p:a"), S("p:b"), U, S("p:c") }
            assert.equal(4, SequenceTail.tail_start(file, replay))
        end)

        it(
            "finds no tail when a row moved past another at the file's end",
            function()
                local file = { S("p:a"), S("t:1"), S("p:b"), S("t:2"), U }
                local replay = { S("p:a"), S("t:1"), S("t:2"), U, S("p:b") }
                assert.equal(6, SequenceTail.tail_start(file, replay))
            end
        )

        it(
            "finds no tail when a cut-off file's last row moved earlier",
            function()
                local file = { S("p:a"), S("t:1"), S("p:b") }
                local replay = { S("p:a"), S("p:b"), S("t:1") }
                assert.equal(4, SequenceTail.tail_start(file, replay))
            end
        )

        it("matches repeated keys by count", function()
            local file = { S("p:go"), U, S("p:go"), U }
            local replay = { S("p:go"), U, S("p:go"), U, S("p:go"), U }
            assert.equal(5, SequenceTail.tail_start(file, replay))
        end)

        it("skips a replay-only first row with no match", function()
            local file = { S("p:a"), U }
            local replay = { K("p:summary"), U, S("p:b"), U }
            assert.equal(3, SequenceTail.tail_start(file, replay))
        end)

        it("returns nil when both sides have keys and none match", function()
            local file = { S("p:a"), U }
            local replay = { S("p:b"), U }
            assert.is_nil(SequenceTail.tail_start(file, replay))
        end)

        it("finds no tail in a replay without keys", function()
            assert.equal(3, SequenceTail.tail_start({ S("p:a") }, { U, U }))
        end)

        it("takes the whole replay against an empty file", function()
            assert.equal(1, SequenceTail.tail_start({}, { U, S("p:a") }))
        end)

        it("aligns keys with newlines as single rows", function()
            local file = { S("p:a\nb"), U }
            local replay = { S("p:a\nb"), U, S("p:a"), U }
            assert.equal(3, SequenceTail.tail_start(file, replay))
        end)
    end)
end)
