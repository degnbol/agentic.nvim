local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Logger = require("agentic.utils.logger")

describe("agentic.utils.git_files", function()
    --- @type agentic.utils.GitFiles
    local GitFiles
    --- @type TestStub
    local system_stub
    --- @type TestStub
    local fs_stat_stub

    --- Map from joined argv string to a `vim.system` result.
    --- @type table<string, { code: integer, stdout: string, stderr: string }>
    local responses = {}
    --- @type table<string, { mtime: { sec: integer, nsec: integer } }|nil>
    local fs_results = {}

    --- Encode an argv array as a stable lookup key.
    --- @param argv string[]
    --- @return string
    local function key_of(argv)
        return table.concat(argv, " ")
    end

    --- Stand-in for the `Process` returned by `vim.system`.
    --- @param result { code: integer, stdout: string, stderr: string }
    --- @return { wait: fun(): { code: integer, stdout: string, stderr: string } }
    local function fake_process(result)
        return {
            wait = function()
                return result
            end,
        }
    end

    before_each(function()
        package.loaded["agentic.utils.git_files"] = nil
        GitFiles = require("agentic.utils.git_files")
        GitFiles.invalidate()

        responses = {}
        fs_results = {}

        system_stub = spy.stub(vim, "system")
        system_stub:invokes(function(argv, _opts)
            local result = responses[key_of(argv)]
                or {
                    code = 1,
                    stdout = "",
                    stderr = "no stub for: " .. key_of(argv),
                }
            return fake_process(result)
        end)

        fs_stat_stub = spy.stub(vim.uv, "fs_stat")
        fs_stat_stub:invokes(function(path)
            return fs_results[path]
        end)
    end)

    after_each(function()
        system_stub:revert()
        fs_stat_stub:revert()
    end)

    describe("is_tracked", function()
        local function set_repo(git_root, index_rel, tracked_paths)
            responses[key_of({
                "git",
                "-C",
                git_root,
                "rev-parse",
                "--git-path",
                "index",
            })] =
                { code = 0, stdout = index_rel .. "\n", stderr = "" }

            local nul = string.char(0)
            responses[key_of({
                "git",
                "-C",
                git_root,
                "ls-files",
                "-z",
                "--full-name",
            })] =
                {
                    code = 0,
                    stdout = table.concat(tracked_paths, nul) .. nul,
                    stderr = "",
                }

            local index_abs = index_rel:sub(1, 1) == "/" and index_rel
                or git_root .. "/" .. index_rel
            fs_results[index_abs] = { mtime = { sec = 1, nsec = 0 } }
        end

        it("matches absolute paths in the tracked set", function()
            set_repo("/repo", ".git/index", { "src/a.lua", "README.md" })

            assert.is_true(GitFiles.is_tracked("/repo/src/a.lua", "/repo"))
            assert.is_true(GitFiles.is_tracked("/repo/README.md", "/repo"))
            assert.is_false(GitFiles.is_tracked("/repo/src/b.lua", "/repo"))
        end)

        it("uses the worktree-resolved index path", function()
            -- Worktree stores its index outside .git/, e.g. .git/worktrees/foo/index
            set_repo(
                "/repo",
                ".git/worktrees/feature/index",
                { "src/feature.lua" }
            )

            assert.is_true(
                GitFiles.is_tracked("/repo/src/feature.lua", "/repo")
            )

            -- Verify the worktree index path was the one stat'd.
            local stat_args = fs_stat_stub.calls[1]
            assert.equal("/repo/.git/worktrees/feature/index", stat_args[1])
        end)

        it("invalidates cache when the index mtime changes", function()
            set_repo("/repo", ".git/index", { "src/a.lua" })
            assert.is_true(GitFiles.is_tracked("/repo/src/a.lua", "/repo"))

            local ls_count_after_first = 0
            for _, c in ipairs(system_stub.calls) do
                if c[1][4] == "ls-files" then
                    ls_count_after_first = ls_count_after_first + 1
                end
            end
            assert.equal(1, ls_count_after_first)

            -- Same mtime → cache hit, no second ls-files
            assert.is_true(GitFiles.is_tracked("/repo/src/a.lua", "/repo"))
            local ls_count_after_second = 0
            for _, c in ipairs(system_stub.calls) do
                if c[1][4] == "ls-files" then
                    ls_count_after_second = ls_count_after_second + 1
                end
            end
            assert.equal(1, ls_count_after_second)

            -- mtime changes + new tracked set
            fs_results["/repo/.git/index"] = { mtime = { sec = 2, nsec = 0 } }
            local nul = string.char(0)
            responses[key_of({
                "git",
                "-C",
                "/repo",
                "ls-files",
                "-z",
                "--full-name",
            })] =
                {
                    code = 0,
                    stdout = "src/a.lua" .. nul .. "src/b.lua" .. nul,
                    stderr = "",
                }

            assert.is_true(GitFiles.is_tracked("/repo/src/b.lua", "/repo"))
        end)
    end)

    describe("diff_hunks", function()
        local function set_diff(git_root, path, stdout)
            responses[key_of({
                "git",
                "-C",
                git_root,
                "diff",
                "--no-color",
                "-U0",
                "--",
                path,
            })] =
                { code = 0, stdout = stdout, stderr = "" }
        end

        it("parses single-line and multi-line additions", function()
            set_diff("/repo", "/repo/a.lua", table.concat({
                "diff --git a/a.lua b/a.lua",
                "@@ -10 +10 @@",
                "-old",
                "+new",
                "@@ -20,0 +21,3 @@",
                "+x",
                "+y",
                "+z",
            }, "\n") .. "\n")

            local hunks = GitFiles.diff_hunks("/repo", "/repo/a.lua")
            assert.equal(2, #hunks)
            assert.equal(10, hunks[1].start_line)
            assert.equal(10, hunks[1].end_line)
            assert.equal(1, hunks[1].count)
            assert.equal(21, hunks[2].start_line)
            assert.equal(23, hunks[2].end_line)
            assert.equal(3, hunks[2].count)
        end)

        it("flags pure deletions with count == 0", function()
            set_diff(
                "/repo",
                "/repo/a.lua",
                "@@ -5,2 +4,0 @@\n-line one\n-line two\n"
            )

            local hunks = GitFiles.diff_hunks("/repo", "/repo/a.lua")
            assert.equal(1, #hunks)
            assert.equal(0, hunks[1].count)
            assert.equal(4, hunks[1].start_line)
            assert.equal(4, hunks[1].end_line)
        end)

        it("returns empty list when git diff fails", function()
            responses[key_of({
                "git",
                "-C",
                "/repo",
                "diff",
                "--no-color",
                "-U0",
                "--",
                "/repo/missing.lua",
            })] =
                { code = 128, stdout = "", stderr = "fatal" }

            local hunks = GitFiles.diff_hunks("/repo", "/repo/missing.lua")
            assert.equal(0, #hunks)
        end)
    end)

    describe("dirty_paths", function()
        local NUL = string.char(0)
        --- @type TestStub
        local schedule_stub

        --- Run `dirty_paths` against a canned `git status -z` payload.
        --- @param result { code: integer, stdout: string, stderr: string }
        --- @return table<string, boolean>|nil
        --- @return boolean called
        local function collect(result)
            system_stub:invokes(function(_argv, _opts, callback)
                callback(result)
                return fake_process(result)
            end)

            --- @type table<string, boolean>|nil
            local captured
            local called = false
            GitFiles.dirty_paths("/repo", function(paths)
                captured = paths
                called = true
            end)
            return captured, called
        end

        --- `collect` for the success path, where the set is never nil.
        --- @param stdout string
        --- @return table<string, boolean>
        local function collect_ok(stdout)
            return collect({ code = 0, stdout = stdout, stderr = "" }) or {}
        end

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("resolves each entry against the git root", function()
            local paths =
                collect_ok(" M lua/a.lua" .. NUL .. "?? notes/b.md" .. NUL)

            assert.is_true(paths["/repo/lua/a.lua"])
            assert.is_true(paths["/repo/notes/b.md"])
        end)

        it("keeps paths containing spaces intact", function()
            local paths = collect_ok(" M dir with space/a b.lua" .. NUL)

            assert.is_true(paths["/repo/dir with space/a b.lua"])
        end)

        it("reports both sides of a rename", function()
            -- A rename entry spends two NUL-terminated fields: destination
            -- first, then source.
            local paths = collect_ok(
                "R  new.lua" .. NUL .. "old.lua" .. NUL .. " M other.lua" .. NUL
            )

            assert.is_true(paths["/repo/new.lua"])
            assert.is_true(paths["/repo/old.lua"])
            -- The entry after the rename source must still be read as an entry.
            assert.is_true(paths["/repo/other.lua"])
        end)

        it("yields nil when git fails, distinct from a clean tree", function()
            local notify_stub = spy.stub(Logger, "notify")

            local paths, called =
                collect({ code = 128, stdout = "", stderr = "fatal: no repo" })

            assert.is_true(called)
            assert.is_nil(paths)
            -- Silent failure would look identical to a clean tree to callers.
            assert.stub(notify_stub).was.called(1)

            notify_stub:revert()
        end)

        it("yields an empty set for a clean tree", function()
            assert.equal(0, vim.tbl_count(collect_ok("")))
        end)
    end)
end)
