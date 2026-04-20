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

    describe("find_unique_subsequence", function()
        it("returns start when match is unique", function()
            local idx = TrustSafety.find_unique_subsequence(
                { "a", "b", "c", "d" },
                { "b", "c" }
            )
            assert.equal(2, idx)
        end)

        it("returns nil when match appears more than once", function()
            local idx = TrustSafety.find_unique_subsequence(
                { "a", "b", "a", "b" },
                { "a", "b" }
            )
            assert.is_nil(idx)
        end)

        it("returns nil when no match", function()
            local idx = TrustSafety.find_unique_subsequence(
                { "a", "b" },
                { "x" }
            )
            assert.is_nil(idx)
        end)
    end)

    describe("verify_edit_range", function()
        it("returns range when content at range still matches", function()
            local file_lines = { "untouched", "c1", "c2", "footer" }
            local record = {
                path = "/repo/a.lua",
                start_line = 2,
                end_line = 3,
                new_lines = { "c1", "c2" },
            }
            local r = TrustSafety.verify_edit_range(record, file_lines) --[[@as agentic.utils.TrustSafety.Range]]
            assert.is_not_nil(r)
            assert.equal(2, r[1])
            assert.equal(3, r[2])
        end)

        it("returns nil when user modified one of the lines", function()
            local file_lines = { "c1", "user-edit" }
            local record = {
                path = "/repo/a.lua",
                start_line = 1,
                end_line = 2,
                new_lines = { "c1", "c2" },
            }
            assert.is_nil(TrustSafety.verify_edit_range(record, file_lines))
        end)

        it("returns nil when range extends past end of file", function()
            local file_lines = { "c1" }
            local record = {
                path = "/repo/a.lua",
                start_line = 1,
                end_line = 2,
                new_lines = { "c1", "c2" },
            }
            assert.is_nil(TrustSafety.verify_edit_range(record, file_lines))
        end)
    end)

    describe("claude_owned_ranges", function()
        it(
            "returns ranges whose recorded content still matches disk",
            function()
                local file_lines = { "header", "c1", "c2", "footer" }
                local records = {
                    ["t1"] = {
                        path = "/repo/a.lua",
                        start_line = 2,
                        end_line = 3,
                        new_lines = { "c1", "c2" },
                    },
                }
                local ranges = TrustSafety.claude_owned_ranges(
                    "/repo/a.lua",
                    records,
                    "in-flight",
                    file_lines
                )
                assert.equal(1, #ranges)
                assert.equal(2, ranges[1][1])
                assert.equal(3, ranges[1][2])
            end
        )

        it("omits ranges where the user modified Claude's output", function()
            local file_lines = { "c1", "user-modified" }
            local records = {
                ["t1"] = {
                    path = "/repo/a.lua",
                    start_line = 1,
                    end_line = 2,
                    new_lines = { "c1", "c2" },
                },
            }
            local ranges = TrustSafety.claude_owned_ranges(
                "/repo/a.lua",
                records,
                "in-flight",
                file_lines
            )
            assert.equal(0, #ranges)
        end)

        it(
            "omits ranges shifted by a later edit (duplicate-content safe)",
            function()
                -- Early Claude edit recorded ["end"] at line 5. Later a user
                -- hunk at line 10 happens to also contain "end". With the old
                -- first-match semantics we would have mis-attributed line 10
                -- to Claude. Now we verify the recorded range, so mismatch at
                -- line 5 (where something else now sits) → correctly drops.
                local file_lines = {
                    "a",
                    "b",
                    "c",
                    "d",
                    "something_else",
                    "f",
                    "g",
                    "h",
                    "i",
                    "end",
                }
                local records = {
                    ["t1"] = {
                        path = "/repo/a.lua",
                        start_line = 5,
                        end_line = 5,
                        new_lines = { "end" },
                    },
                }
                local ranges = TrustSafety.claude_owned_ranges(
                    "/repo/a.lua",
                    records,
                    "in-flight",
                    file_lines
                )
                assert.equal(0, #ranges)
            end
        )

        it("excludes the in-flight tool call", function()
            local file_lines = { "claude" }
            local records = {
                ["self"] = {
                    path = "/repo/a.lua",
                    start_line = 1,
                    end_line = 1,
                    new_lines = { "claude" },
                },
            }
            local ranges = TrustSafety.claude_owned_ranges(
                "/repo/a.lua",
                records,
                "self",
                file_lines
            )
            assert.equal(0, #ranges)
        end)

        it("filters out records for other paths", function()
            local file_lines = { "claude" }
            local records = {
                ["t1"] = {
                    path = "/repo/other.lua",
                    start_line = 1,
                    end_line = 1,
                    new_lines = { "claude" },
                },
            }
            local ranges = TrustSafety.claude_owned_ranges(
                "/repo/a.lua",
                records,
                "in-flight",
                file_lines
            )
            assert.equal(0, #ranges)
        end)
    end)

    describe("is_pure_addition", function()
        it("returns true when new prepends lines around old", function()
            assert.is_true(TrustSafety.is_pure_addition({
                old = { "foo", "bar" },
                new = { "header", "foo", "bar" },
            }))
        end)

        it("returns true when new appends lines around old", function()
            assert.is_true(TrustSafety.is_pure_addition({
                old = { "foo", "bar" },
                new = { "foo", "bar", "footer" },
            }))
        end)

        it("returns true for no-op (old == new)", function()
            assert.is_true(TrustSafety.is_pure_addition({
                old = { "foo" },
                new = { "foo" },
            }))
        end)

        it("returns false when old is split by inserted lines", function()
            -- Non-contiguous: "foo" and "baz" separated by "bar" in new.
            -- Safe in principle but narrower contiguous check rejects it.
            assert.is_false(TrustSafety.is_pure_addition({
                old = { "foo", "baz" },
                new = { "foo", "bar", "baz" },
            }))
        end)

        it("returns false when any line of old is missing from new", function()
            assert.is_false(TrustSafety.is_pure_addition({
                old = { "foo", "bar" },
                new = { "foo", "baz" },
            }))
        end)

        it("returns false when new is shorter than old", function()
            assert.is_false(TrustSafety.is_pure_addition({
                old = { "foo", "bar" },
                new = { "foo" },
            }))
        end)

        it("returns false for diff.all (whole-file write)", function()
            assert.is_false(TrustSafety.is_pure_addition({
                all = true,
                old = {},
                new = { "anything" },
            }))
        end)

        it("returns false for nil diff", function()
            assert.is_false(TrustSafety.is_pure_addition(nil))
        end)

        it("returns false when old is empty (pure insertion)", function()
            -- Edit tool enforces non-empty old_string, so this shouldn't arise
            -- in practice — but guard against it anyway.
            assert.is_false(TrustSafety.is_pure_addition({
                old = {},
                new = { "new content" },
            }))
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

        it("pure addition overlapping a non-Claude hunk is safe", function()
            local ok, reason = TrustSafety.safe_for_kind("edit", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = true,
                hunks = { { start_line = 5, end_line = 8, count = 4 } },
                edit_range = { 5, 8 },
                claude_owned_ranges = {},
                is_pure_addition = true,
            })
            assert.is_true(ok)
            assert.equal("pure addition preserves user content", reason)
        end)

        it("pure addition overlapping a pure-deletion hunk is safe", function()
            -- Without pure-addition, a count=0 hunk rejects outright.
            -- Pure addition bypasses that because user content is
            -- preserved inside diff.new regardless of hunk type.
            local ok = TrustSafety.safe_for_kind("edit", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = true,
                hunks = { { start_line = 5, end_line = 5, count = 0 } },
                edit_range = { 4, 6 },
                claude_owned_ranges = {},
                is_pure_addition = true,
            })
            assert.is_true(ok)
        end)

        it("pure addition on dirty file without edit_range is safe", function()
            -- Pure-addition recoverability is a property of diff alone;
            -- an unlocatable edit_range just means the edit will fail at
            -- tool level, which is still safe for the user.
            local ok = TrustSafety.safe_for_kind("edit", {
                exists = true,
                tracked = true,
                has_unstaged_hunks = true,
                hunks = { { start_line = 5, end_line = 5, count = 1 } },
                edit_range = nil,
                claude_owned_ranges = {},
                is_pure_addition = true,
            })
            assert.is_true(ok)
        end)

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
