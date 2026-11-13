local assert = require("tests.helpers.assert")

local UnifiedDiff = require("agentic.utils.unified_diff")

describe("agentic.utils.UnifiedDiff", function()
    describe("hunks", function()
        it("splits each hunk into its old and new side", function()
            local patch = table.concat({
                "diff --git /tmp/a.lua /tmp/a.lua",
                "--- /tmp/a.lua",
                "+++ /tmp/a.lua",
                "@@ -1,3 +1,3 @@",
                " local x = 1",
                "-local y = 2",
                "+local y = 3",
                " return x",
                "@@ -10,2 +10,3 @@",
                " a",
                "+b",
                " c",
                "",
            }, "\n")
            assert.same({
                {
                    old_lines = { "local x = 1", "local y = 2", "return x" },
                    new_lines = { "local x = 1", "local y = 3", "return x" },
                },
                { old_lines = { "a", "c" }, new_lines = { "a", "b", "c" } },
            }, UnifiedDiff.hunks(patch))
        end)

        it("reads a removed line that looks like a file header", function()
            local patch = table.concat({
                "--- a/x",
                "+++ b/x",
                "@@ -1,2 +1 @@",
                "--- a comment",
                " kept",
            }, "\n")
            assert.same({
                {
                    old_lines = { "-- a comment", "kept" },
                    new_lines = { "kept" },
                },
            }, UnifiedDiff.hunks(patch))
        end)

        it("skips the no-newline marker", function()
            local patch = table.concat({
                "--- /dev/null",
                "+++ /tmp/new",
                "@@ -0,0 +1,2 @@",
                "+one",
                "+two",
                "\\ No newline at end of file",
            }, "\n")
            assert.same(
                { { old_lines = {}, new_lines = { "one", "two" } } },
                UnifiedDiff.hunks(patch)
            )
        end)

        it("is empty for text without hunks", function()
            assert.same({}, UnifiedDiff.hunks("diff --git a b\n"))
        end)
    end)
end)
