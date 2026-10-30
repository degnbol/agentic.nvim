--- Safety checks for the /grant scoped auto-approval layer. Nothing here
--- writes; path resolution and scope compilation read the filesystem.
---
--- The orchestrator in PermissionManager handles git and file reads and
--- threads concrete inputs into the per-kind predicate here, so the safety
--- matrix is unit-testable without mocking PermissionManager.

--- @class agentic.utils.GrantSafety
local M = {}

--- @class agentic.utils.GrantSafety.Range
--- @field [1] integer start_line (1-based)
--- @field [2] integer end_line_inclusive

--- @class agentic.utils.GrantSafety.StatSnapshot
--- @field exists boolean
--- @field mtime_sec? integer
--- @field mtime_nsec? integer
--- @field size? integer

--- @class agentic.utils.GrantSafety.ScopeForm
--- @field root string Absolute directory the pattern is anchored at
--- @field pattern vim.lpeg.Pattern Matches a whole absolute path

--- @class agentic.utils.GrantSafety.Scope
--- @field key string Absolute normalised pattern, the scope's identity
--- @field display string The user's input
--- @field root string Literal root: the pattern's leading segments with no glob metacharacter
--- @field forms agentic.utils.GrantSafety.ScopeForm[] The pattern on `root`, and on the resolved `root` when that differs
--- @field dot_segments vim.lpeg.Pattern[] Pattern segments below `root` that start with a literal `.`, each compiled alone

--- Top-level directories that are too coarse to silently auto-approve.
--- Used by `is_wide_scope` for the WARN notification.
local WIDE_TOPLEVEL = {
    ["/"] = true,
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

--- @param path string Absolute path or pattern
--- @return string[] segments The non-empty `/`-separated parts
local function segments(path)
    return vim.split(path, "/", { trimempty = true })
end

--- True iff `pat` contains glob metacharacters.
--- @param pat string
--- @return boolean
local function has_glob_meta(pat)
    return pat:find("[%*%?%[{]") ~= nil
end

--- The leading segments of an absolute pattern that hold no glob
--- metacharacter, as a path.
--- @param pattern string Absolute, normalised
--- @return string root
local function literal_root(pattern)
    local literal = {}
    for _, seg in ipairs(segments(pattern)) do
        if has_glob_meta(seg) then
            break
        end
        table.insert(literal, seg)
    end
    return "/" .. table.concat(literal, "/")
end

--- Compile an absolute pattern into a whole-path matcher. A pattern with no
--- glob metacharacter matches itself and every path below it.
--- @param pattern string Absolute, normalised
--- @return vim.lpeg.Pattern
local function compile_pattern(pattern)
    if has_glob_meta(pattern) then
        return vim.glob.to_lpeg(pattern)
    end
    local below = pattern == "/" and "/" or pattern .. "/"
    return vim.lpeg.P(pattern) * -1 + vim.lpeg.P(below)
end

--- @param patterns vim.lpeg.Pattern[]
--- @param s string
--- @return boolean
local function matches_any(patterns, s)
    for _, p in ipairs(patterns) do
        if p:match(s) then
            return true
        end
    end
    return false
end

--- Full realpath of a path that need not exist: the realpath of its deepest
--- existing ancestor, with the remaining segments appended. So a path through
--- a symlinked parent resolves to where a write would land.
--- @param path string Absolute path
--- @return string|nil real Nil when an existing part of the path does not resolve (a broken symlink), or `path` has a `..` segment
function M.resolve(path)
    -- The kernel applies `..` after following a symlink before it, so
    -- `/r/link/../x` lands beside the link's target; normalising would
    -- collapse it to `/r/x` as text.
    if vim.list_contains(segments(path), "..") then
        return nil
    end
    local dir = normalize(path)
    --- @type string[]
    local tail = {}
    while true do
        local real = vim.uv.fs_realpath(dir)
        if real then
            return vim.fs.joinpath(real, unpack(tail))
        end
        if vim.uv.fs_lstat(dir) then
            return nil
        end
        table.insert(tail, 1, vim.fs.basename(dir))
        dir = vim.fs.dirname(dir)
    end
end

--- Compile a path or glob into a scope. The pattern matches in two forms:
--- on its literal root, and on the resolved root, so a path given in either
--- form matches (`/tmp/x` and `/private/tmp/x` on macOS).
---
--- A hidden part below the root (a segment starting with `.`) is excluded
--- unless the pattern names it with a segment that starts with a literal `.`
--- (`/r/**/.github/**` admits `.github`, not `.git`). A hidden name written
--- any other way (`{.a,b}`, `[.]a`) stays excluded.
---
--- A path containing `*`, `?`, `[` or `{` compiles as a glob, so it covers
--- only the paths it matches, not those below them.
--- @param pattern string Absolute path or glob, `~` and env vars expanded
--- @param display string Shown to the user for the scope
--- @return agentic.utils.GrantSafety.Scope
function M.compile_scope(pattern, display)
    local key = normalize(pattern)
    local root = literal_root(key)
    local below = key:sub(#root + 1)

    --- @type agentic.utils.GrantSafety.ScopeForm[]
    local forms = { { root = root, pattern = compile_pattern(key) } }
    local real_root = M.resolve(root)
    if real_root and real_root ~= root then
        table.insert(forms, {
            root = real_root,
            pattern = compile_pattern(real_root .. below),
        })
    end

    --- @type vim.lpeg.Pattern[]
    local dot_segments = {}
    for _, seg in ipairs(segments(below)) do
        if seg:sub(1, 1) == "." then
            table.insert(dot_segments, vim.glob.to_lpeg(seg))
        end
    end

    --- @type agentic.utils.GrantSafety.Scope
    local scope = {
        key = key,
        display = display,
        root = root,
        forms = forms,
        dot_segments = dot_segments,
    }
    return scope
end

--- True iff `path` is in the scope: some form's pattern matches it, and every
--- hidden segment of it below that form's root is named by the pattern (see
--- `compile_scope`).
--- @param scope agentic.utils.GrantSafety.Scope
--- @param path string Absolute, normalised path
--- @return boolean
function M.scope_contains(scope, path)
    for _, form in ipairs(scope.forms) do
        if form.pattern:match(path) then
            local hidden_granted = true
            for _, seg in ipairs(segments(path:sub(#form.root + 1))) do
                if
                    seg:sub(1, 1) == "."
                    and not matches_any(scope.dot_segments, seg)
                then
                    hidden_granted = false
                    break
                end
            end
            if hidden_granted then
                return true
            end
        end
    end
    return false
end

--- The deduplicated temp roots: `/tmp` and the platform `$TMPDIR` (macOS
--- `/var/folders/.../T`), each in **both** its literal and realpath form, so
--- a path matches in either form (`/tmp/x` and `/private/tmp/x`).
--- @return string[]
function M.tmp_roots()
    local roots = {}
    local seen = {}
    local function add(p)
        if not p or p == "" then
            return
        end
        local root = normalize(p):gsub("/+$", "")
        if root ~= "" and not seen[root] then
            seen[root] = true
            table.insert(roots, root)
        end
    end
    for _, p in ipairs({ "/tmp", vim.uv.os_tmpdir() }) do
        add(p)
        add(vim.uv.fs_realpath(p))
    end
    return roots
end

--- True iff `path` lies strictly under one of `roots` (the root itself does not
--- count). `path` is normalised (collapsing `..`); symlink resolution is the
--- caller's job (pass both the original and its realpath).
--- @param path string
--- @param roots string[]
--- @return boolean
function M.is_under_tmp(path, roots)
    local norm = normalize(path):gsub("/+$", "")
    for _, root in ipairs(roots) do
        if vim.startswith(norm, root .. "/") then
            return true
        end
    end
    return false
end

--- Heuristic check for "this scope might cover much more than the user
--- intended": its root is `$HOME` or a top-level directory, in literal or
--- resolved form (`/private/var` is `/var`), and not one of `tmp_roots`.
--- @param scope agentic.utils.GrantSafety.Scope
--- @param tmp_roots string[] Roots that are never wide
--- @return boolean wide
--- @return string|nil reason
function M.is_wide_scope(scope, tmp_roots)
    local root = scope.root
    if vim.tbl_contains(tmp_roots, root) then
        return false, nil
    end
    --- @param dir string
    --- @return boolean
    local function is_root(dir)
        return dir == root or vim.uv.fs_realpath(dir) == root
    end
    if is_root(vim.uv.os_homedir() or "") then
        return true, "covers $HOME"
    end
    for dir in pairs(WIDE_TOPLEVEL) do
        if is_root(dir) then
            return true, "covers a top-level directory: " .. root
        end
    end
    return false, nil
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

--- @param a agentic.utils.GrantSafety.Range
--- @param b agentic.utils.GrantSafety.Range
--- @return boolean
function M.range_overlaps(a, b)
    return not (a[2] < b[1] or b[2] < a[1])
end

--- @param inner agentic.utils.GrantSafety.Range
--- @param outer agentic.utils.GrantSafety.Range
--- @return boolean
function M.range_within(inner, outer)
    return inner[1] >= outer[1] and inner[2] <= outer[2]
end

--- Locate `target_lines` as a contiguous subsequence in `file_lines`, but
--- only return the match position if it is **unique**. If the sequence
--- appears zero or multiple times, returns nil.
---
--- Used for Claude's Edit tool: the tool enforces `old_string` uniqueness
--- at execution time, so a non-unique match here means the surrounding
--- file state has changed since we recorded the diff.
---
--- @param file_lines string[]
--- @param target_lines string[]
--- @return integer|nil start_line 1-based
function M.find_unique_subsequence(file_lines, target_lines)
    local first = M.find_subsequence(file_lines, target_lines, 1)
    if not first then
        return nil
    end
    local second = M.find_subsequence(file_lines, target_lines, first + 1)
    if second then
        return nil
    end
    return first
end

--- @class agentic.utils.GrantSafety.EditRecord
--- @field path string Absolute file path
--- @field start_line integer 1-based inclusive, position of new_lines[1]
--- @field end_line integer 1-based inclusive, position of new_lines[#new_lines]
--- @field new_lines string[] Expected content at start_line..end_line

--- Verify that a recorded edit range still contains the exact content Claude
--- wrote. Returns the range if intact, nil if the user or a later edit has
--- shifted or modified that region. Line numbers in `record` must index into
--- `file_lines` as they currently exist on disk.
---
--- @param record agentic.utils.GrantSafety.EditRecord
--- @param file_lines string[]
--- @return agentic.utils.GrantSafety.Range|nil
function M.verify_edit_range(record, file_lines)
    local expected = record.new_lines
    if not expected or #expected == 0 then
        return nil
    end
    if record.end_line > #file_lines then
        return nil
    end
    for i = 1, #expected do
        if file_lines[record.start_line + i - 1] ~= expected[i] then
            return nil
        end
    end
    return { record.start_line, record.end_line }
end

--- For each recorded Claude edit on `path` (excluding the in-flight call),
--- return the range if the on-disk content at that range still equals the
--- recorded `new_lines`. Any divergence (user edit, later Claude edit
--- shifting lines) drops the record from the result, fall-through-safe.
---
--- @param path string Absolute file path
--- @param records table<string, agentic.utils.GrantSafety.EditRecord>
--- @param exclude_id string|nil The in-flight tool call ID
--- @param file_lines string[] Current on-disk content of `path`
--- @return agentic.utils.GrantSafety.Range[]
function M.claude_owned_ranges(path, records, exclude_id, file_lines)
    --- @type agentic.utils.GrantSafety.Range[]
    local ranges = {}
    for id, record in pairs(records) do
        if id ~= exclude_id and record.path == path then
            local range = M.verify_edit_range(record, file_lines)
            if range then
                table.insert(ranges, range)
            end
        end
    end
    return ranges
end

--- True iff every line of `diff.old` is preserved verbatim inside `diff.new`
--- as a contiguous line-level subsequence. For Claude's str_replace Edit tool
--- that means the edit adds new lines around the user's captured block
--- without removing any of the lines it was anchored against. Such edits are
--- recoverable inside dirty hunks — the user's working-tree content (which
--- must match `old_string` verbatim for the tool to succeed) is still present
--- in the post-edit file.
---
--- Returns false for diff.all (whole-file write), missing diffs, and any
--- shape where `#diff.new < #diff.old`.
--- @param diff agentic.ui.MessageWriter.ToolCallDiff|nil
--- @return boolean
function M.is_pure_addition(diff)
    if not diff or diff.all then
        return false
    end
    local old = diff.old
    local new = diff.new
    if not old or #old == 0 or not new or #new < #old then
        return false
    end
    return M.find_subsequence(new, old, 1) ~= nil
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
--- @return agentic.utils.GrantSafety.Range|nil
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
--- @return agentic.utils.GrantSafety.StatSnapshot
function M.stat_snapshot(path)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        --- @type agentic.utils.GrantSafety.StatSnapshot
        local s = { exists = false }
        return s
    end
    --- @type agentic.utils.GrantSafety.StatSnapshot
    local snap = {
        exists = true,
        mtime_sec = stat.mtime.sec,
        mtime_nsec = stat.mtime.nsec,
        size = stat.size,
    }
    return snap
end

--- @param path string
--- @param snapshot agentic.utils.GrantSafety.StatSnapshot
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

--- @class agentic.utils.GrantSafety.KindArgs
--- @field exists boolean File exists on disk
--- @field tracked boolean File is tracked in the relevant git index
--- @field has_unstaged_hunks boolean Working tree differs from index
--- @field hunks agentic.utils.GitFiles.Hunk[] Unstaged hunk ranges in the new file
--- @field edit_range? agentic.utils.GrantSafety.Range Target range of an Edit
--- @field claude_owned_ranges agentic.utils.GrantSafety.Range[] Verified ranges
--- @field is_pure_addition? boolean diff.old is a contiguous subsequence of diff.new
--- @field write_all? boolean Write replaces the entire file (diff.all)
--- @field tmp? boolean Path and its realpath are under a tmp root
--- @field is_dir? boolean Path is a directory (a symlink to one is not)
--- @field dest? agentic.utils.GrantSafety.KindArgs Destination state for `move`

--- True iff the path is scratch: under a tmp root and not tracked by git.
--- Scratch is write/create/edit-safe with no further check.
--- @param args agentic.utils.GrantSafety.KindArgs
--- @return boolean
function M.is_scratch(args)
    return args.tmp == true and not args.tracked
end

--- Whether a mutation of `kind` leaves the path recoverable. Scratch
--- (`is_scratch`) clears write, create and edit. Otherwise:
---   * create — the file does not exist
---   * write  — a new file, or tracked and clean
---   * delete — a tracked, clean file that is not a directory
---   * edit   — a new file; tracked and clean; a pure addition; an edit range
---     disjoint from the unstaged hunks; or every overlapping hunk inside a
---     verified Claude-owned range
---   * move   — the source passes `edit` and the destination passes `write`
--- @param kind agentic.acp.ToolKind
--- @param args agentic.utils.GrantSafety.KindArgs
--- @return boolean safe
--- @return string|nil reason
function M.safe_for_kind(kind, args)
    if kind == "create" then
        if M.is_scratch(args) then
            return true, "tmp scratch create"
        end
        if args.exists then
            return false, "file already exists"
        end
        return true, "create new file"
    end

    if kind == "write" then
        if M.is_scratch(args) then
            return true, "tmp scratch write"
        end
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
        if args.is_dir then
            return false, "path is a directory"
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
        if M.is_scratch(args) then
            return true, "tmp scratch edit"
        end
        if not args.exists then
            return true, "edit on nonexistent file"
        end
        if not args.tracked then
            return false, "file untracked"
        end
        if not args.has_unstaged_hunks then
            return true, "tracked + clean"
        end
        if args.is_pure_addition then
            return true, "pure addition preserves user content"
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
