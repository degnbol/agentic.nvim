--- @diagnostic disable: invisible, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.ui.FileActivity", function()
    --- @type agentic.ui.FileActivity
    local FileActivity
    --- @type integer
    local bufnr
    --- @type integer
    local changes

    --- The tally canonicalises paths through fs_realpath, which would resolve
    --- these fixtures against the real filesystem. Stub it to the identity so
    --- the recorded paths are the ones the tests write.
    --- @type TestStub
    local realpath_stub
    --- @type TestStub
    local cwd_stub

    --- @return agentic.ui.FileActivity
    local function make_activity()
        return FileActivity:new(bufnr, function()
            changes = changes + 1
        end)
    end

    --- @param activity agentic.ui.FileActivity
    --- @param id string
    --- @param path string
    --- @param op agentic.ui.FileActivity.OpClass
    --- @return boolean
    local function record(activity, id, path, op)
        return activity:record({ tool_call_id = id, path = path, op = op })
    end

    --- @return string[]
    local function buffer_lines()
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    before_each(function()
        FileActivity = require("agentic.ui.file_activity")
        bufnr = vim.api.nvim_create_buf(false, true)
        changes = 0

        realpath_stub = spy.stub(vim.uv, "fs_realpath")
        realpath_stub:invokes(function(path)
            return path
        end)

        cwd_stub = spy.stub(vim.uv, "cwd")
        cwd_stub:returns("/repo")
    end)

    after_each(function()
        realpath_stub:revert()
        cwd_stub:revert()
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("record", function()
        it("appends one op and renders a row", function()
            local activity = make_activity()

            assert.is_true(record(activity, "tc-1", "/repo/a.lua", "edit"))

            local rows = activity:rows()
            assert.equal(1, #rows)
            assert.equal("/repo/a.lua", rows[1].path)
            assert.equal("edit", rows[1].op)
        end)

        it("ignores a repeated tool call id", function()
            local activity = make_activity()

            assert.is_true(record(activity, "tc-1", "/repo/a.lua", "edit"))
            assert.is_false(record(activity, "tc-1", "/repo/a.lua", "edit"))

            assert.equal(1, #activity:rows())
            assert.equal(1, activity:count())
        end)

        it("collapses repeated edits of one path into one row", function()
            local activity = make_activity()

            record(activity, "tc-1", "/repo/a.lua", "edit")
            record(activity, "tc-2", "/repo/a.lua", "edit")

            assert.equal(1, #activity:rows())
        end)

        it("marks a path by its newest op class", function()
            local activity = make_activity()

            record(activity, "tc-1", "/repo/a.lua", "create")
            record(activity, "tc-2", "/repo/a.lua", "edit")

            assert.equal("edit", activity:rows()[1].op)
        end)

        it("collects every op's ranges onto the path's row", function()
            local activity = make_activity()

            activity:record({
                tool_call_id = "tc-1",
                path = "/repo/a.lua",
                op = "edit",
                ranges = { { start_line = 3, end_line = 4 } },
            })
            activity:record({
                tool_call_id = "tc-2",
                path = "/repo/a.lua",
                op = "edit",
                ranges = { { start_line = 40, end_line = 40 } },
            })

            assert.same({
                { start_line = 3, end_line = 4 },
                { start_line = 40, end_line = 40 },
            }, activity:rows()[1].ranges)
        end)
    end)

    describe("count", function()
        it("counts paths, not ops, and excludes reads", function()
            local activity = make_activity()

            record(activity, "tc-1", "/repo/a.lua", "edit")
            record(activity, "tc-2", "/repo/a.lua", "edit")
            record(activity, "tc-3", "/repo/b.lua", "create")
            record(activity, "tc-4", "/repo/c.lua", "read")

            assert.equal(2, activity:count())
        end)
    end)

    describe("rows: sorting", function()
        it("puts mutations above reads", function()
            local activity = make_activity()

            record(activity, "tc-1", "/repo/a-read.lua", "read")
            record(activity, "tc-2", "/repo/z-edit.lua", "edit")

            local rows = activity:rows()
            assert.equal("/repo/z-edit.lua", rows[1].path)
            assert.equal("/repo/a-read.lua", rows[2].path)
        end)

        it("orders project files, then elsewhere, then scratch", function()
            local activity = make_activity()

            record(activity, "tc-1", "/tmp/scratch.lua", "edit")
            record(activity, "tc-2", "/elsewhere/other.lua", "edit")
            record(activity, "tc-3", "/repo/mine.lua", "edit")

            assert.same(
                {
                    "/repo/mine.lua",
                    "/elsewhere/other.lua",
                    "/tmp/scratch.lua",
                },
                vim.tbl_map(function(row)
                    return row.path
                end, activity:rows())
            )
        end)

        it("sorts alphabetically within a tier", function()
            local activity = make_activity()

            record(activity, "tc-1", "/repo/b.lua", "edit")
            record(activity, "tc-2", "/repo/a.lua", "create")
            record(activity, "tc-3", "/repo/c.lua", "delete")

            assert.same(
                {
                    "/repo/a.lua",
                    "/repo/b.lua",
                    "/repo/c.lua",
                },
                vim.tbl_map(function(row)
                    return row.path
                end, activity:rows())
            )
        end)
    end)

    describe("render", function()
        it(
            "writes a placeholder rather than leaving the buffer empty",
            function()
                make_activity()
                assert.equal(1, #buffer_lines())
                assert.truthy(buffer_lines()[1]:match("%S"))
            end
        )

        it("prefixes each row with its op marker", function()
            local activity = make_activity()

            record(activity, "tc-1", "/repo/a.lua", "create")
            record(activity, "tc-2", "/repo/b.lua", "edit")
            record(activity, "tc-3", "/repo/c.lua", "delete")
            record(activity, "tc-4", "/repo/d.lua", "read")

            -- strcharpart, not sub: the read marker is multibyte.
            local markers = vim.tbl_map(function(line)
                return vim.fn.strcharpart(line, 0, 1)
            end, buffer_lines())
            assert.same({ "+", "~", "-", "·" }, markers)
        end)

        it("notifies the owner after every render", function()
            local activity = make_activity()
            local before = changes

            record(activity, "tc-1", "/repo/a.lua", "edit")

            assert.is_true(changes > before)
        end)
    end)

    describe("unseen marker", function()
        --- Count of sign-column marks in the buffer.
        --- @return integer
        local function unseen_marks()
            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                vim.api.nvim_create_namespace("agentic_file_activity"),
                0,
                -1,
                { details = true }
            )
            local total = 0
            for _, mark in ipairs(marks) do
                if mark[4].sign_text then
                    total = total + 1
                end
            end
            return total
        end

        it(
            "draws the mark in the gutter, leaving the row text alone",
            function()
                local activity = make_activity()

                record(activity, "tc-1", "/repo/marked.lua", "edit")
                local marked = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
                activity:mark_viewed()
                local unmarked =
                    vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]

                -- The row must be byte-identical either way, or the path column
                -- would jump as rows are viewed.
                assert.equal(marked, unmarked)
                assert.equal("~ /repo/marked.lua", marked)
            end
        )

        it("marks every row of a tally that has never been viewed", function()
            local activity = make_activity()

            record(activity, "tc-1", "/repo/a.lua", "edit")
            record(activity, "tc-2", "/repo/b.lua", "edit")

            assert.equal(2, unseen_marks())
        end)

        it("clears the marks once viewed", function()
            local activity = make_activity()

            record(activity, "tc-1", "/repo/a.lua", "edit")
            activity:mark_viewed()

            assert.equal(0, unseen_marks())
        end)

        it("marks only what changed after the last view", function()
            local activity = make_activity()

            record(activity, "tc-1", "/repo/a.lua", "edit")
            activity:mark_viewed()
            record(activity, "tc-2", "/repo/b.lua", "edit")

            assert.equal(1, unseen_marks())
        end)

        it("re-marks a path edited again after being viewed", function()
            local activity = make_activity()

            record(activity, "tc-1", "/repo/a.lua", "edit")
            activity:mark_viewed()
            record(activity, "tc-2", "/repo/a.lua", "edit")

            assert.equal(1, unseen_marks())
        end)
    end)

    describe("serialize and load", function()
        it("round-trips the log and the viewed watermark", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "create")
            record(activity, "tc-2", "/repo/b.lua", "edit")
            activity:mark_viewed()

            local restored = make_activity()
            restored:load(activity:serialize())

            assert.same(activity:rows(), restored:rows())
            assert.equal(2, restored:count())
        end)

        it("keeps stored seq numbers so the watermark still applies", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "edit")
            activity:mark_viewed()
            record(activity, "tc-2", "/repo/b.lua", "edit")

            local restored = make_activity()
            restored:load(activity:serialize())

            -- b.lua landed after the view; a.lua did not.
            assert.equal(2, #restored:rows())
            assert.equal(1, #vim.tbl_filter(function(row)
                return row.seq > 1
            end, restored:rows()))
        end)

        it("drops replayed ops the stored log already holds", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "edit")
            local stored = activity:serialize()

            -- session/load replays the same tool calls before the stored log
            -- has been read off disk.
            local replayed = make_activity()
            record(replayed, "tc-1", "/repo/a.lua", "edit")
            replayed:load(stored)

            assert.equal(1, #replayed:rows())
        end)

        it("keeps ops recorded before the stored log arrived", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "edit")
            local stored = activity:serialize()

            local live = make_activity()
            record(live, "tc-new", "/repo/b.lua", "edit")
            live:load(stored)

            assert.equal(2, #live:rows())
            assert.equal(2, live:count())
        end)

        it("is a no-op for a session file with no tally", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "edit")

            activity:load(nil)

            assert.equal(1, #activity:rows())
        end)
    end)

    describe("clear", function()
        it("empties the log and the viewed watermark", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "edit")
            activity:mark_viewed()

            activity:clear()

            assert.equal(0, activity:count())
            assert.equal(0, #activity:rows())
            -- The same tool call is recordable again in the new conversation.
            assert.is_true(record(activity, "tc-1", "/repo/a.lua", "edit"))
        end)
    end)

    describe("reconcile", function()
        --- @type TestStub
        local fs_stat_stub
        --- @type TestStub
        local root_stub
        --- @type TestStub
        local dirty_stub
        --- @type TestStub
        local tracked_stub
        --- @type table<string, boolean>
        local on_disk
        --- @type table<string, boolean>
        local dirty
        --- @type table<string, boolean>
        local tracked

        before_each(function()
            local GitFiles = require("agentic.utils.git_files")
            on_disk = {}
            dirty = {}
            tracked = {}

            fs_stat_stub = spy.stub(vim.uv, "fs_stat")
            fs_stat_stub:invokes(function(path)
                return on_disk[path] and { type = "file" } or nil
            end)

            root_stub = spy.stub(vim.fs, "root")
            root_stub:returns("/repo")

            dirty_stub = spy.stub(GitFiles, "dirty_paths")
            dirty_stub:invokes(function(_root, callback)
                callback(dirty)
            end)

            tracked_stub = spy.stub(GitFiles, "is_tracked")
            tracked_stub:invokes(function(path)
                return tracked[path] == true
            end)
        end)

        after_each(function()
            fs_stat_stub:revert()
            root_stub:revert()
            dirty_stub:revert()
            tracked_stub:revert()
        end)

        --- @return string[]
        local function row_paths(activity)
            return vim.tbl_map(function(row)
                return row.path
            end, activity:rows())
        end

        it("hides a created file that no longer exists", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/gone.lua", "create")
            record(activity, "tc-2", "/repo/kept.lua", "create")
            on_disk["/repo/kept.lua"] = true

            activity:reconcile()

            assert.same({ "/repo/kept.lua" }, row_paths(activity))
        end)

        it(
            "hides a file that vanished after being edited, not created",
            function()
                local activity = make_activity()
                record(activity, "tc-1", "/repo/gone.lua", "create")
                record(activity, "tc-2", "/repo/gone.lua", "edit")

                activity:reconcile()

                assert.same({}, row_paths(activity))
            end
        )

        it("hides a tracked file git no longer reports as changed", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/reverted.lua", "edit")
            record(activity, "tc-2", "/repo/changed.lua", "edit")
            on_disk["/repo/reverted.lua"] = true
            on_disk["/repo/changed.lua"] = true
            tracked["/repo/reverted.lua"] = true
            tracked["/repo/changed.lua"] = true
            dirty["/repo/changed.lua"] = true

            activity:reconcile()

            assert.same({ "/repo/changed.lua" }, row_paths(activity))
        end)

        it(
            "keeps an existing untracked edit, having nothing to compare against",
            function()
                local activity = make_activity()
                record(activity, "tc-1", "/repo/untracked.lua", "edit")
                on_disk["/repo/untracked.lua"] = true

                activity:reconcile()

                assert.same({ "/repo/untracked.lua" }, row_paths(activity))
            end
        )

        it("keeps a deletion git still reports", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/deleted.lua", "delete")
            tracked["/repo/deleted.lua"] = true
            dirty["/repo/deleted.lua"] = true

            activity:reconcile()

            assert.same({ "/repo/deleted.lua" }, row_paths(activity))
        end)

        it("keeps every existing file outside a repository", function()
            root_stub:returns(nil)
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "edit")
            on_disk["/repo/a.lua"] = true

            activity:reconcile()

            assert.same({ "/repo/a.lua" }, row_paths(activity))
            assert.stub(dirty_stub).was.called(0)
        end)

        it("keeps every row when git could not answer", function()
            -- An empty set means a clean tree; nil means the probe failed, and
            -- reading that as "nothing changed" would blank the panel.
            dirty_stub:invokes(function(_root, callback)
                callback(nil)
            end)
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "edit")
            record(activity, "tc-2", "/repo/vanished.lua", "create")
            on_disk["/repo/a.lua"] = true
            tracked["/repo/a.lua"] = true

            activity:reconcile()

            assert.equal(2, #activity:rows())
        end)

        it("revives a row that changed again after being hidden", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "edit")
            on_disk["/repo/a.lua"] = true
            tracked["/repo/a.lua"] = true

            activity:reconcile()
            assert.equal(0, #activity:rows())

            dirty["/repo/a.lua"] = true
            activity:reconcile()
            assert.equal(1, #activity:rows())
        end)

        it("skips the git probe when only reads are recorded", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "read")

            activity:reconcile()

            assert.stub(dirty_stub).was.called(0)
            assert.equal(1, #activity:rows())
        end)
    end)

    describe("to_quickfix", function()
        --- @type TestStub
        local setqflist_stub
        --- @type table|nil
        local captured

        before_each(function()
            setqflist_stub = spy.stub(vim.fn, "setqflist")
            setqflist_stub:invokes(function(_list, _action, what)
                captured = what
            end)
        end)

        after_each(function()
            setqflist_stub:revert()
        end)

        it("positions each entry at the file's first recorded hunk", function()
            local activity = make_activity()
            activity:record({
                tool_call_id = "tc-1",
                path = "/repo/a.lua",
                op = "edit",
                ranges = { { start_line = 17, end_line = 18 } },
            })
            record(activity, "tc-2", "/repo/b.lua", "create")

            assert.equal(2, activity:to_quickfix())
            local items = (captured or {}).items or {}
            assert.equal("/repo/a.lua", items[1].filename)
            assert.equal(17, items[1].lnum)
            -- No range reported: the top of the file is the honest fallback.
            assert.equal(1, items[2].lnum)
        end)
    end)

    describe("row_at", function()
        it("maps a buffer line to its row", function()
            local activity = make_activity()
            record(activity, "tc-1", "/repo/a.lua", "edit")
            record(activity, "tc-2", "/repo/b.lua", "edit")

            assert.equal("/repo/b.lua", activity:row_at(2).path)
        end)

        it("has no row on the placeholder line", function()
            local activity = make_activity()
            assert.is_nil(activity:row_at(1))
        end)
    end)
end)
