local Logger = require("agentic.utils.logger")

--- @class agentic.utils.GitFiles
local M = {}

--- @class agentic.utils.GitFiles.Cache
--- @field index_path string Absolute path to this worktree's index file
--- @field index_key string Version key (mtime, size, inode) of index_path at last load
--- @field tracked table<string, boolean> Set of absolute tracked paths

--- Per-git-root caches.
--- @type table<string, agentic.utils.GitFiles.Cache>
local caches = {}

--- Show a WARN notification for a failed git command.
--- @param what string What failed, e.g. "git diff failed in /repo"
--- @param stderr string|nil The command's stderr
local function warn_failure(what, stderr)
    Logger.notify(
        string.format("%s: %s", what, vim.trim(stderr or "")),
        vim.log.levels.WARN,
        { title = "Agentic" }
    )
end

--- Resolve the worktree's actual index file path. For `git worktree`
--- checkouts, `.git` is a file pointing to `.git/worktrees/<name>/`, and the
--- index lives under that path — `.git/index` is wrong.
--- @param git_root string
--- @return string|nil
local function resolve_index_path(git_root)
    local result = vim.system({
        "git",
        "-C",
        git_root,
        "rev-parse",
        "--git-path",
        "index",
    }, { text = true }):wait()
    if result.code ~= 0 then
        warn_failure("git rev-parse failed in " .. git_root, result.stderr)
        return nil
    end
    local rel = vim.trim(result.stdout)
    if rel == "" then
        return nil
    end
    if rel:sub(1, 1) == "/" then
        return rel
    end
    return vim.fs.joinpath(git_root, rel)
end

--- Identity of a file's current version: mtime (sec and nsec), size and
--- inode. The inode catches a file replaced by rename (as git does with
--- `index.lock`) even where mtime resolution is too coarse to change.
--- @param path string
--- @return string key `""` when the file is missing
local function index_key_of(path)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return ""
    end
    return string.format(
        "%d.%d:%d:%d",
        stat.mtime.sec,
        stat.mtime.nsec,
        stat.size,
        stat.ino
    )
end

--- Load (or refresh) the tracked-files set for a git root.
--- @param git_root string
--- @return agentic.utils.GitFiles.Cache|nil
local function load_cache(git_root)
    local cache = caches[git_root]
    local index_path = cache and cache.index_path
        or resolve_index_path(git_root)
    if not index_path then
        return nil
    end

    local index_key = index_key_of(index_path)
    if cache and cache.index_key == index_key then
        return cache
    end

    local result = vim.system({
        "git",
        "-C",
        git_root,
        "ls-files",
        "-z",
        "--full-name",
    }, { text = true }):wait()
    if result.code ~= 0 then
        warn_failure("git ls-files failed in " .. git_root, result.stderr)
        return nil
    end

    local tracked = {}
    for entry in (result.stdout or ""):gmatch("([^%z]+)") do
        tracked[vim.fs.joinpath(git_root, entry)] = true
    end

    --- @type agentic.utils.GitFiles.Cache
    local new_cache = {
        index_path = index_path,
        index_key = index_key,
        tracked = tracked,
    }
    caches[git_root] = new_cache
    return new_cache
end

--- Check whether an absolute path is tracked in `git_root`'s index.
--- A failed git command shows a WARN notification.
--- @param path string Absolute path
--- @param git_root string
--- @return boolean|nil tracked nil, not false, when git could not read the index
function M.is_tracked(path, git_root)
    local cache = load_cache(git_root)
    if not cache then
        return nil
    end
    return cache.tracked[path] == true
end

--- @class agentic.utils.GitFiles.Hunk
--- @field start_line integer 1-based start line in the new (post-edit) file
--- @field end_line integer 1-based inclusive end line (== start when count==0)
--- @field count integer Number of lines in the new file (0 == pure deletion)

--- Parse `git diff --no-color -U0 -- <path>` output for unstaged hunk ranges
--- (working tree vs index). For a 0-line hunk (pure deletion), `start_line`
--- is the line *before* which deletion occurred and `end_line == start_line`.
--- A failed `git diff` shows a WARN notification.
--- @param git_root string
--- @param path string Absolute path
--- @return agentic.utils.GitFiles.Hunk[]|nil hunks Empty when there are no unstaged changes, nil when git diff failed
function M.diff_hunks(git_root, path)
    local result = vim.system({
        "git",
        "-C",
        git_root,
        "diff",
        "--no-color",
        "-U0",
        "--",
        path,
    }, { text = true }):wait()
    if result.code ~= 0 then
        warn_failure(
            string.format("git diff failed in %s for %s", git_root, path),
            result.stderr
        )
        return nil
    end

    --- @type agentic.utils.GitFiles.Hunk[]
    local hunks = {}
    for line in (result.stdout or ""):gmatch("([^\n]+)") do
        local start_str, count_str = line:match("^@@ %-%S+ %+(%d+),?(%d*) @@")
        if start_str then
            local start = tonumber(start_str) or 0
            local count = count_str == "" and 1 or tonumber(count_str) or 0
            local end_line = count == 0 and start or start + count - 1
            table.insert(hunks, {
                start_line = start,
                end_line = end_line,
                count = count,
            })
        end
    end
    return hunks
end

--- Absolute paths git reports as differing from HEAD in `git_root`, whether
--- staged, unstaged or untracked. A path absent from the result has the same
--- content as HEAD.
---
--- The only asynchronous entry point in this module: it runs against a working
--- tree of arbitrary size rather than against the index, so a caller must be
--- able to show something before the answer arrives. `callback` is invoked on
--- the main loop.
---
--- Failure yields nil, not an empty set. An empty set is a real answer — a clean
--- tree — and a caller reading "absent from the set" as "unchanged" would
--- otherwise treat a held `index.lock`, a missing `git`, or an unreadable repo
--- as every path being unchanged.
---
--- `-z` rather than the default quoting: paths with spaces or non-ASCII bytes
--- come back double-quoted and C-escaped otherwise, and a rename entry is
--- `XY <new>\0<old>` — two NUL-terminated fields for one entry.
--- @param git_root string
--- @param callback fun(paths: table<string, boolean>|nil)
function M.dirty_paths(git_root, callback)
    vim.system({
        "git",
        "-C",
        git_root,
        "status",
        "--porcelain",
        "-z",
    }, { text = true }, function(result)
        if result.code ~= 0 then
            vim.schedule(function()
                warn_failure("git status failed in " .. git_root, result.stderr)
                callback(nil)
            end)
            return
        end

        local paths = {}
        local fields = vim.split(result.stdout or "", "\0", { plain = true })
        local i = 1
        while i <= #fields do
            local entry = fields[i]
            i = i + 1
            -- "XY " prefix plus at least one path byte.
            if #entry > 3 then
                paths[vim.fs.joinpath(git_root, entry:sub(4))] = true
                local status = entry:sub(1, 2)
                if status:find("[RC]") then
                    local source = fields[i]
                    i = i + 1
                    if source and source ~= "" then
                        paths[vim.fs.joinpath(git_root, source)] = true
                    end
                end
            end
        end

        vim.schedule(function()
            callback(paths)
        end)
    end)
end

--- Drop all caches (test helper / `:checktime`-style invalidation).
function M.invalidate()
    caches = {}
end

return M
