local Logger = require("agentic.utils.logger")

--- @class agentic.utils.GitFiles
local M = {}

--- @class agentic.utils.GitFiles.Cache
--- @field index_path string Absolute path to this worktree's index file
--- @field index_mtime number mtime.sec of index_path at last load
--- @field tracked table<string, boolean> Set of absolute tracked paths

--- Per-git-root caches.
--- @type table<string, agentic.utils.GitFiles.Cache>
local caches = {}

--- Resolve git root for a given directory. Returns absolute path or nil.
--- @param cwd string
--- @return string|nil
function M.get_git_root(cwd)
    local result = vim.system({
        "git",
        "-C",
        cwd,
        "rev-parse",
        "--show-toplevel",
    }, { text = true }):wait()
    if result.code ~= 0 then
        return nil
    end
    local root = vim.trim(result.stdout)
    if root == "" then
        return nil
    end
    return root
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
        return nil
    end
    local rel = vim.trim(result.stdout)
    if rel == "" then
        return nil
    end
    if rel:sub(1, 1) == "/" then
        return rel
    end
    return git_root .. "/" .. rel
end

--- @param path string
--- @return number
local function mtime_of(path)
    local stat = vim.uv.fs_stat(path)
    if stat then
        return stat.mtime.sec
    end
    return 0
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

    local current_mtime = mtime_of(index_path)
    if cache and cache.index_mtime == current_mtime then
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
        Logger.debug("git_files: ls-files failed for", git_root, result.stderr)
        return nil
    end

    local tracked = {}
    for entry in (result.stdout or ""):gmatch("([^%z]+)") do
        tracked[git_root .. "/" .. entry] = true
    end

    --- @type agentic.utils.GitFiles.Cache
    local new_cache = {
        index_path = index_path,
        index_mtime = current_mtime,
        tracked = tracked,
    }
    caches[git_root] = new_cache
    return new_cache
end

--- Check whether an absolute path is tracked in `git_root`'s index.
--- @param path string Absolute path
--- @param git_root string
--- @return boolean
function M.is_tracked(path, git_root)
    local cache = load_cache(git_root)
    if not cache then
        return false
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
--- @param git_root string
--- @param path string Absolute path
--- @return agentic.utils.GitFiles.Hunk[]
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
        return {}
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

--- Drop all caches (test helper / `:checktime`-style invalidation).
function M.invalidate()
    caches = {}
end

return M
