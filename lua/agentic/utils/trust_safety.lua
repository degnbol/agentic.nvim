--- Pure(-ish) safety checks for the /trust scoped auto-approval layer.
---
--- The orchestrator in PermissionManager handles I/O (git, stat, file read)
--- and threads concrete inputs into the per-kind predicate here. Keeping
--- the predicates and matchers free of side effects lets us unit-test the
--- safety matrix without mocking PermissionManager.

--- @class agentic.utils.TrustSafety
local M = {}

--- @class agentic.utils.TrustSafety.Range
--- @field [1] integer start_line (1-based)
--- @field [2] integer end_line_inclusive

--- @class agentic.utils.TrustSafety.StatSnapshot
--- @field exists boolean
--- @field mtime_sec? integer
--- @field mtime_nsec? integer
--- @field size? integer

--- @class agentic.utils.TrustSafety.Scope
--- @field kind "repo"|"here"|"path"
--- @field display string Original user input or reserved literal
--- @field cwd string Activation cwd (anchors "here", relative paths)
--- @field glob_matcher? fun(path: string): boolean Compiled matcher for "path"

--- Top-level directories that are too coarse to silently auto-approve.
--- Used by `is_wide_scope` for the WARN notification.
local WIDE_TOPLEVEL = {
    ["/"] = true,
    ["/tmp"] = true,
    ["/var"] = true,
    ["/usr"] = true,
    ["/etc"] = true,
    ["/home"] = true,
    ["/Users"] = true,
    ["/opt"] = true,
}

--- @param path string
--- @return string
local function normalize(path)
    return vim.fs.normalize(path, { expand_env = false })
end

--- True iff `pat` contains glob metacharacters.
--- @param pat string
--- @return boolean
local function has_glob_meta(pat)
    return pat:find("[%*%?%[]") ~= nil
end

--- Compile a /trust argument into a TrustScope record.
--- "repo" / "here" / "off" are handled by the caller.
--- @param input string The user's argument (already trimmed, non-empty,
---                     not a reserved literal)
--- @param cwd string Activation cwd
--- @return agentic.utils.TrustSafety.Scope
function M.compile_path_scope(input, cwd)
    local expanded = normalize(input)

    -- Resolve relative paths against cwd.
    local pattern = expanded
    if pattern:sub(1, 1) ~= "/" then
        pattern = cwd .. "/" .. pattern
        pattern = normalize(pattern)
    end

    -- Bare directory with no glob characters → match anything beneath it.
    if not has_glob_meta(pattern) then
        local stat = vim.uv.fs_stat(pattern)
        if stat and stat.type == "directory" then
            pattern = pattern .. "/**"
        end
    end

    local lpeg_pat = vim.glob.to_lpeg(pattern)
    --- @type agentic.utils.TrustSafety.Scope
    local scope = {
        kind = "path",
        display = input,
        cwd = cwd,
        glob_matcher = function(path)
            return lpeg_pat:match(path) ~= nil
        end,
    }
    return scope
end

--- Build a "repo" or "here" scope. The actual tracked-set membership check
--- happens in the orchestrator via git_files.
--- @param kind "repo"|"here"
--- @param cwd string
--- @param git_root? string Used for the display string when kind == "repo"
--- @return agentic.utils.TrustSafety.Scope
function M.build_reserved_scope(kind, cwd, git_root)
    local display
    if kind == "repo" then
        display =
            string.format("git-tracked files in %s", git_root or "<git root>")
    else
        display = string.format("git-tracked files under %s", cwd)
    end
    --- @type agentic.utils.TrustSafety.Scope
    local scope = {
        kind = kind,
        display = display,
        cwd = cwd,
    }
    return scope
end

--- Heuristic check for "this scope might cover much more than the user
--- intended." Reserved literals never warn.
--- @param scope agentic.utils.TrustSafety.Scope
--- @return boolean wide
--- @return string|nil reason
function M.is_wide_scope(scope)
    if scope.kind ~= "path" then
        return false, nil
    end

    local raw = scope.display
    local expanded = normalize(raw)
    if expanded:sub(1, 1) ~= "/" then
        expanded = scope.cwd .. "/" .. expanded
        expanded = normalize(expanded)
    end

    local home = vim.uv.os_homedir() or ""
    if expanded == home or expanded == home .. "/**" then
        return true, "covers $HOME"
    end

    -- Strip a trailing /** to inspect the underlying root.
    local base = expanded:gsub("/%*%*$", "")
    if WIDE_TOPLEVEL[base] then
        return true, "covers a top-level directory: " .. base
    end

    -- A glob with no anchoring prefix (`**/...`).
    if raw:sub(1, 2) == "**" then
        return true, "unanchored ** glob"
    end

    return false, nil
end

--- Resolve a path's symlink endpoints. Returns the original normalised path
--- and its realpath. realpath equals path when the file is not a symlink or
--- does not yet exist (the latter applies to `create`/`write` of new files).
--- Returns nil if the symlink is broken.
--- @param path string Absolute path
--- @return string|nil orig
--- @return string|nil real
function M.resolve_symlink_pair(path)
    local norm = normalize(path)
    local lstat = vim.uv.fs_lstat(norm)
    if not lstat then
        return norm, norm
    end
    if lstat.type == "link" then
        local real = vim.uv.fs_realpath(norm)
        if not real then
            return nil, nil
        end
        return norm, real
    end
    return norm, norm
end

--- True iff target_lines occurs as a contiguous subsequence in file_lines,
--- searching from `start_at` (1-based, default 1). Returns the 1-based start
--- index of the match, or nil.
--- @param file_lines string[]
--- @param target_lines string[]
--- @param start_at? integer
--- @return integer|nil match_start
function M.find_subsequence(file_lines, target_lines, start_at)
    local m = #target_lines
    if m == 0 then
        return nil
    end
    local n = #file_lines
    if n < m then
        return nil
    end
    local from = math.max(1, start_at or 1)
    for i = from, n - m + 1 do
        local ok = true
        for j = 1, m do
            if file_lines[i + j - 1] ~= target_lines[j] then
                ok = false
                break
            end
        end
        if ok then
            return i
        end
    end
    return nil
end

--- @param a agentic.utils.TrustSafety.Range
--- @param b agentic.utils.TrustSafety.Range
--- @return boolean
function M.range_overlaps(a, b)
    return not (a[2] < b[1] or b[2] < a[1])
end

--- @param inner agentic.utils.TrustSafety.Range
--- @param outer agentic.utils.TrustSafety.Range
--- @return boolean
function M.range_within(inner, outer)
    return inner[1] >= outer[1] and inner[2] <= outer[2]
end

--- @param target agentic.utils.TrustSafety.Range
--- @param ranges agentic.utils.TrustSafety.Range[]
--- @return boolean
function M.any_overlap(target, ranges)
    for _, r in ipairs(ranges) do
        if M.range_overlaps(target, r) then
            return true
        end
    end
    return false
end

--- For each prior tool_call_blocks entry on `path` (excluding `exclude_id`),
--- locate its `diff.new` lines as a contiguous subsequence in the current
--- on-disk content. Each successful match yields a range that the user has
--- demonstrably not modified since Claude wrote it.
---
--- The check requires exact line-sequence equality. Any user edit to those
--- lines breaks the match and the range is omitted, fall-through-safe.
---
--- @param path string Absolute file path
--- @param tool_call_blocks table<string, agentic.ui.MessageWriter.ToolCallBlock>
--- @param exclude_id string The in-flight tool call ID
--- @param file_lines string[] Current on-disk content of `path`
--- @return agentic.utils.TrustSafety.Range[]
function M.claude_owned_ranges(path, tool_call_blocks, exclude_id, file_lines)
    --- @type agentic.utils.TrustSafety.Range[]
    local ranges = {}
    for id, block in pairs(tool_call_blocks) do
        if id ~= exclude_id and block.argument == path then
            local new_lines = block.diff and block.diff.new
            if new_lines and #new_lines > 0 then
                local start = M.find_subsequence(file_lines, new_lines, 1)
                if start then
                    table.insert(ranges, { start, start + #new_lines - 1 })
                end
            end
        end
    end
    return ranges
end

--- Locate the target range of an Edit / Write in the current file using the
--- diff already attached to the in-flight tool call's tool_call_blocks entry.
---
--- - For Write with `diff.all == true`, returns the whole-file range.
--- - For Edit, finds `diff.old` as a contiguous subsequence and returns its
---   span. If `diff.old` is not line-aligned (rare), returns nil — caller
---   falls through.
---
--- @param diff agentic.ui.MessageWriter.ToolCallDiff|nil
--- @param file_lines string[]
--- @return agentic.utils.TrustSafety.Range|nil
function M.edit_target_range(diff, file_lines)
    if not diff then
        return nil
    end
    if diff.all then
        if #file_lines == 0 then
            return { 1, 1 }
        end
        return { 1, #file_lines }
    end
    local old = diff.old
    if not old or #old == 0 then
        -- Pure insertion: target is a single anchor line. Without position
        -- info, we cannot reason about overlap — fall through.
        return nil
    end
    local start = M.find_subsequence(file_lines, old, 1)
    if not start then
        return nil
    end
    return { start, start + #old - 1 }
end

--- Capture mtime+size of a file, or `{exists=false}` when it doesn't exist.
--- Used to bracket the safety check and detect concurrent user writes.
--- @param path string Absolute path
--- @return agentic.utils.TrustSafety.StatSnapshot
function M.stat_snapshot(path)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        --- @type agentic.utils.TrustSafety.StatSnapshot
        local s = { exists = false }
        return s
    end
    --- @type agentic.utils.TrustSafety.StatSnapshot
    local snap = {
        exists = true,
        mtime_sec = stat.mtime.sec,
        mtime_nsec = stat.mtime.nsec,
        size = stat.size,
    }
    return snap
end

--- @param path string
--- @param snapshot agentic.utils.TrustSafety.StatSnapshot
--- @return boolean
function M.stat_unchanged(path, snapshot)
    local current = M.stat_snapshot(path)
    if current.exists ~= snapshot.exists then
        return false
    end
    if not current.exists then
        return true
    end
    return current.mtime_sec == snapshot.mtime_sec
        and current.mtime_nsec == snapshot.mtime_nsec
        and current.size == snapshot.size
end

--- @class agentic.utils.TrustSafety.KindArgs
--- @field exists boolean File exists on disk
--- @field tracked boolean File is tracked in the relevant git index
--- @field has_unstaged_hunks boolean Working tree differs from index
--- @field hunks agentic.utils.GitFiles.Hunk[] Unstaged hunk ranges in the new file
--- @field edit_range? agentic.utils.TrustSafety.Range Target range of an Edit
--- @field claude_owned_ranges agentic.utils.TrustSafety.Range[] Verified ranges
--- @field write_all? boolean Write replaces the entire file (diff.all)
--- @field dest? agentic.utils.TrustSafety.KindArgs Destination state for `move`

--- Per-kind safety predicate. See plan §"Per-kind predicates".
--- @param kind agentic.acp.ToolKind
--- @param args agentic.utils.TrustSafety.KindArgs
--- @return boolean safe
--- @return string|nil reason
function M.safe_for_kind(kind, args)
    if kind == "create" then
        if args.exists then
            return false, "file already exists"
        end
        return true, "create new file"
    end

    if kind == "write" then
        if not args.exists then
            return true, "write new file"
        end
        if not args.tracked then
            return false, "file untracked"
        end
        if args.has_unstaged_hunks then
            return false, "file has unstaged changes"
        end
        return true, "tracked + clean"
    end

    if kind == "delete" then
        if not args.exists then
            return false, "file does not exist"
        end
        if not args.tracked then
            return false, "file untracked"
        end
        if args.has_unstaged_hunks then
            return false, "file has unstaged changes"
        end
        return true, "tracked + clean"
    end

    if kind == "edit" then
        if not args.exists then
            return true, "edit on nonexistent file"
        end
        if not args.tracked then
            return false, "file untracked"
        end
        if not args.has_unstaged_hunks then
            return true, "tracked + clean"
        end
        if not args.edit_range then
            return false, "could not locate edit target range"
        end
        local overlapping = {}
        for _, h in ipairs(args.hunks) do
            local hr = { h.start_line, h.end_line }
            if M.range_overlaps(args.edit_range, hr) then
                if h.count == 0 then
                    -- Pure deletion — no on-disk content to verify against
                    -- diff.new. Conservatively treat as user-owned.
                    return false, "overlapping pure deletion hunk"
                end
                table.insert(overlapping, hr)
            end
        end
        if #overlapping == 0 then
            return true, "edit range disjoint from unstaged hunks"
        end
        for _, hr in ipairs(overlapping) do
            local owned = false
            for _, owned_range in ipairs(args.claude_owned_ranges) do
                if M.range_within(hr, owned_range) then
                    owned = true
                    break
                end
            end
            if not owned then
                return false, "overlapping hunk not Claude-owned"
            end
        end
        return true, "all overlapping hunks are Claude-owned"
    end

    if kind == "move" then
        local source_safe, source_reason = M.safe_for_kind("edit", args)
        if not source_safe then
            return false, "source: " .. (source_reason or "unsafe")
        end
        if not args.dest then
            return false, "missing destination state"
        end
        local dest_safe, dest_reason = M.safe_for_kind("write", args.dest)
        if not dest_safe then
            return false, "destination: " .. (dest_reason or "unsafe")
        end
        return true, "source + destination safe"
    end

    return false, "unsupported tool kind: " .. tostring(kind)
end

return M
