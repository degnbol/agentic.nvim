local assert = require("tests.helpers.assert")

describe("agentic.utils.trust_safety", function()
    --- @type agentic.utils.TrustSafety
    local TrustSafety

    before_each(function()
        TrustSafety = require("agentic.utils.trust_safety")
    end)

    describe("find_subsequence", function()
        it("matches at the start", function()
            local idx = TrustSafety.find_subsequence(
                { "a", "b", "c", "d" },
                { "a", "b" }
            )
            assert.equal(1, idx)
        end)

        it("matches in the middle", function()
            local idx = TrustSafety.find_subsequence(
                { "a", "b", "c", "d" },
                { "b", "c" }
            )
            assert.equal(2, idx)
        end)

        it("returns nil when missing", function()
            local idx = TrustSafety.find_subsequence(
                { "a", "b", "c" },
                { "x", "y" }
            )
            assert.is_nil(idx)
        end)

        it("returns nil for empty target", function()
            assert.is_nil(TrustSafety.find_subsequence({ "a" }, {}))
        end)

        it("respects start_at", function()
            local idx = TrustSafety.find_subsequence(
                { "a", "b", "a", "b" },
                { "a", "b" },
                2
            )
            assert.equal(3, idx)
        end)
    end)

    describe("range helpers", function()
        it("range_overlaps detects touching ranges", function()
            assert.is_true(TrustSafety.range_overlaps({ 1, 5 }, { 5, 10 }))
            assert.is_true(TrustSafety.range_overlaps({ 1, 5 }, { 3, 4 }))
            assert.is_false(TrustSafety.range_overlaps({ 1, 5 }, { 6, 10 }))
        end)

        it("range_within is strict containment", function()
            assert.is_true(TrustSafety.range_within({ 3, 4 }, { 1, 5 }))
            assert.is_true(TrustSafety.range_within({ 1, 5 }, { 1, 5 }))
            assert.is_false(TrustSafety.range_within({ 1, 6 }, { 1, 5 }))
        end)
    end)

    describe("claude_owned_ranges", function()
        it("returns ranges where diff.new still matches disk", function()
            local file_lines = {
                "untouched header",
                "claude line 1",
                "claude line 2",
                "untouched footer",
            }
            local blocks = {
                ["t1"] = {
                    argument = "/repo/a.lua",
                    diff = { new = { "claude line 1", "claude line 2" } },
                },
            }
            local ranges = TrustSafety.claude_owned_ranges(
                "/repo/a.lua",
                blocks,
                "in-flight",
                file_lines
            )
            assert.equal(1, #ranges)
            assert.equal(2, ranges[1][1])
            assert.equal(3, ranges[1][2])
        end)

        it("omits ranges where the user has edited Claude's output", function()
            local file_lines = {
                "claude line 1",
                "user-modified line",
            }
            local blocks = {
                ["t1"] = {
                    argument = "/repo/a.lua",
                    diff = { new = { "claude line 1", "claude line 2" } },
                },
            }
            local ranges = TrustSafety.claude_owned_ranges(
                "/repo/a.lua",
                blocks,
                "in-flight",
                file_lines
            )
            assert.equal(0, #ranges)
        end)

        it("excludes the in-flight tool call", function()
            local file_lines = { "claude" }
            local blocks = {
                ["self"] = {
                    argument = "/repo/a.lua",
                    diff = { new = { "claude" } },
                },
            }
            local ranges = TrustSafety.claude_owned_ranges(
                "/repo/a.lua",
                blocks,
                "self",
                file_lines
            )
            assert.equal(0, #ranges)
        end)

        it("filters out blocks for other paths", function()
            local file_lines = { "claude" }
            local blocks = {
                ["t1"] = {
                    argument = "/repo/other.lua",
                    diff = { new = { "claude" } },
                },
            }
            local ranges = TrustSafety.claude_owned_ranges(
                "/repo/a.lua",
                blocks,
                "in-flight",
                file_lines
            )
            assert.equal(0, #ranges)
        end)
    end)

    describe("edit_target_range", function()
        it("returns whole-file range for diff.all", function()
            local r = TrustSafety.edit_target_range(
                { all = true, old = {}, new = {} },
                { "a", "b", "c" }
            ) --[[@as agentic.utils.TrustSafety.Range]]
            assert.is_not_nil(r)
            assert.equal(1, r[1])
            assert.equal(3, r[2])
        end)

        it("locates diff.old in the file", function()
            local r = TrustSafety.edit_target_range(
                { old = { "b", "c" }, new = { "B", "C" } },
                { "a", "b", "c", "d" }
            ) --[[@as agentic.utils.TrustSafety.Range]]
            assert.is_not_nil(r)
            assert.equal(2, r[1])
            assert.equal(3, r[2])
        end)

        it("returns nil when diff.old missing", function()
            assert.is_nil(
                TrustSafety.edit_target_range(
                    { old = {}, new = { "x" } },
                    { "a" }
                )
            )
        end)

        it("returns nil when diff.old not in file", function()
            assert.is_nil(
                TrustSafety.edit_target_range(
                    { old = { "ghost" }, new = { "x" } },
                    { "a", "b" }
                )
            )
        end)
    end)

    describe("safe_for_kind", function()
        it("create on nonexistent file is safe", function()
            local ok = TrustSafety.safe_for_kind("create", {
                exists = false,
                tracked = false,
                has_unstaged_hunks = false,
                hunks = {},
                claude_owned_ranges = {},
            })
            assert.is_true(ok)
        end)

        it("create on existing file is unsafe", function()
            local ok = TrustSafety.safe_for_kind("create", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = false,
                hunks = {},
                claude_owned_ranges = {},
            })
            assert.is_false(ok)
        end)

        it("write on tracked + clean is safe", function()
            local ok = TrustSafety.safe_for_kind("write", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = false,
                hunks = {},
                claude_owned_ranges = {},
            })
            assert.is_true(ok)
        end)

        it("write on dirty tracked file is unsafe", function()
            local ok = TrustSafety.safe_for_kind("write", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = true,
                hunks = { { start_line = 1, end_line = 1, count = 1 } },
                claude_owned_ranges = {},
            })
            assert.is_false(ok)
        end)

        it("write on untracked existing file is unsafe", function()
            local ok = TrustSafety.safe_for_kind("write", {
                exists = true,
                tracked = false,
                has_unstaged_hunks = false,
                hunks = {},
                claude_owned_ranges = {},
            })
            assert.is_false(ok)
        end)

        it("delete on tracked + clean is safe", function()
            local ok = TrustSafety.safe_for_kind("delete", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = false,
                hunks = {},
                claude_owned_ranges = {},
            })
            assert.is_true(ok)
        end)

        it("delete on dirty tracked file is unsafe", function()
            local ok = TrustSafety.safe_for_kind("delete", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = true,
                hunks = { { start_line = 1, end_line = 1, count = 1 } },
                claude_owned_ranges = {},
            })
            assert.is_false(ok)
        end)

        it("edit on clean tracked file is safe", function()
            local ok = TrustSafety.safe_for_kind("edit", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = false,
                hunks = {},
                edit_range = { 5, 5 },
                claude_owned_ranges = {},
            })
            assert.is_true(ok)
        end)

        it("edit disjoint from unstaged hunks is safe", function()
            local ok = TrustSafety.safe_for_kind("edit", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = true,
                hunks = { { start_line = 100, end_line = 105, count = 6 } },
                edit_range = { 5, 8 },
                claude_owned_ranges = {},
            })
            assert.is_true(ok)
        end)

        it("edit overlapping a Claude-owned (intact) hunk is safe", function()
            local ok = TrustSafety.safe_for_kind("edit", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = true,
                hunks = { { start_line = 5, end_line = 8, count = 4 } },
                edit_range = { 5, 8 },
                claude_owned_ranges = { { 5, 8 } },
            })
            assert.is_true(ok)
        end)

        it(
            "edit overlapping a hunk that is NOT Claude-owned is unsafe",
            function()
                local ok = TrustSafety.safe_for_kind("edit", {
                    exists = true,
                    tracked = true,
                    has_unstaged_hunks = true,
                    hunks = { { start_line = 5, end_line = 8, count = 4 } },
                    edit_range = { 5, 8 },
                    claude_owned_ranges = {},
                })
                assert.is_false(ok)
            end
        )

        it("edit overlapping a pure-deletion hunk is unsafe", function()
            local ok = TrustSafety.safe_for_kind("edit", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = true,
                hunks = { { start_line = 5, end_line = 5, count = 0 } },
                edit_range = { 4, 6 },
                claude_owned_ranges = { { 1, 100 } },
            })
            assert.is_false(ok)
        end)

        it(
            "edit on dirty file with no locatable target range is unsafe",
            function()
                local ok = TrustSafety.safe_for_kind("edit", {
                    exists = true,
                    tracked = true,
                    has_unstaged_hunks = true,
                    hunks = { { start_line = 5, end_line = 5, count = 1 } },
                    edit_range = nil,
                    claude_owned_ranges = {},
                })
                assert.is_false(ok)
            end
        )

        it("move requires both source and destination safe", function()
            local clean = {
                exists = true,
                tracked = true,
                has_unstaged_hunks = false,
                hunks = {},
                edit_range = { 1, 10 },
                claude_owned_ranges = {},
            }
            local dirty_dest = {
                exists = true,
                tracked = true,
                has_unstaged_hunks = true,
                hunks = { { start_line = 1, end_line = 1, count = 1 } },
                claude_owned_ranges = {},
            }

            local source_safe = vim.deepcopy(clean)
            source_safe.dest = vim.deepcopy(clean)
            assert.is_true(TrustSafety.safe_for_kind("move", source_safe))

            local source_ok_dest_dirty = vim.deepcopy(clean)
            source_ok_dest_dirty.dest = vim.deepcopy(dirty_dest)
            assert.is_false(
                TrustSafety.safe_for_kind("move", source_ok_dest_dirty)
            )
        end)
    end)

    describe("is_wide_scope", function()
        it("never warns for reserved literals", function()
            assert.is_false(TrustSafety.is_wide_scope({
                kind = "repo",
                display = "git-tracked files in /repo",
                cwd = "/repo",
            }))
            assert.is_false(TrustSafety.is_wide_scope({
                kind = "here",
                display = "git-tracked files under /repo/sub",
                cwd = "/repo/sub",
            }))
        end)

        it("warns for /tmp", function()
            local wide = TrustSafety.is_wide_scope({
                kind = "path",
                display = "/tmp",
                cwd = "/repo",
            })
            assert.is_true(wide)
        end)

        it("warns for unanchored ** glob", function()
            local wide = TrustSafety.is_wide_scope({
                kind = "path",
                display = "**/*.lua",
                cwd = "/repo",
            })
            assert.is_true(wide)
        end)

        it("does not warn for a focused subdirectory", function()
            local wide = TrustSafety.is_wide_scope({
                kind = "path",
                display = "/repo/src",
                cwd = "/repo",
            })
            assert.is_false(wide)
        end)
    end)
end)
