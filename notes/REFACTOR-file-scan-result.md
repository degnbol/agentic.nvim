# Plan: one handler for a file scan's output in `FilePicker`
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/ui/file_picker.lua` — `scan_files`, `_try_async_command`,
  `_parse_file_output`
- `lua/agentic/ui/file_picker.test.lua` — `describe("FilePicker:scan_files")`
  (`mocked commands`, `glob fallback`); no `scan_files_async` or
  breadth-first tests exist
- `tests/helpers/deferred.lua`, `tests/helpers/spy.lua`

## Background
`scan_files` (its loop over the scan commands) and `_try_async_command`
(its `vim.system` callback) handle a successful scan command the same way:
test `code == 0` and a non-empty stdout, `_parse_file_output`, log the
truncation, sort by path, store in `self._files`. The glob fallback at the
end of `scan_files` repeats the sort and the store. So the
rule "the file list is sorted by path when it is stored" has three copies,
and the success test has two.

The glob fallback's collection also copies `_parse_file_output`: bucket the
paths by `path_depth`, fill level by level through
`FileSystem.to_smart_path`, stop at `Config.file_picker.max_files`. The two
differ only in what goes in (the glob pre-filters with `vim.fn.simplify`,
`vim.fn.isdirectory` and `_should_exclude`) and in the glob's `seen` dedup
of smart paths. The dedup is needed for the glob (its three patterns
overlap). Command output is not always unique: `git ls-files -c` lists an
unmerged path once per stage (three times during a merge conflict), and
today each copy is a completion item and counts against `max_files`. One
collector with the dedup serves both and lists such a path once.

## Changes
1. Add `FilePicker._collect_breadth_first` (Additions): the buckets, the
   level-by-level fill, the `seen` dedup and the `max_files` stop. It
   returns the files and whether it truncated; it does not log or sort. It
   takes `max_files` as a parameter and does not read `Config`; its callers
   pass `Config.file_picker.max_files or 0`. It does not use `self`, so it is
   a plain function, not a method. It stays a field of `FilePicker` (not a
   local) because the module returns only the class and the
   `_collect_breadth_first` tests call it directly.
2. Delete `_parse_file_output`.
3. Glob fallback in `scan_files`: keep the three globs and the pre-filter
   (`simplify`, `isdirectory`, `_should_exclude`) as one loop that builds a
   path list; replace its buckets, `seen` and fill loop with
   `local files, truncated = FilePicker._collect_breadth_first(paths, Config.file_picker.max_files or 0)`. It keeps
   its "Glob truncated to %d files" log when `truncated`.
4. Add `FilePicker:_set_files` (Additions). The glob fallback ends with
   `self:_set_files(files)` and `return files`.
5. Add `FilePicker:_store_scan_output` (Additions). It holds the success
   test, the stdout split (`gmatch("[^\n]+")`, from `_parse_file_output`),
   the `_collect_breadth_first` call (with `Config.file_picker.max_files or 0`), the
   "Truncated to %d files" log and the `_set_files` call.
6. `scan_files`: the body of the success branch becomes
   `if self:_store_scan_output(result) then return self._files end`. The
   timing log stays at the call site.
7. `_try_async_command`: `if self:_store_scan_output(result) then self._scanning = false else <try next> end`.
   The `Async` timing log stays at the call site.

## Additions
### `file_picker.lua`, above `scan_files`
```lua
--- Up to `max_files` of `paths`, shallowest first, as unique smart paths.
--- Calls `FileSystem.to_smart_path` only on the paths it keeps.
--- @param paths string[]
--- @param max_files integer 0 for no limit
--- @return agentic.ui.FilePickerFile[] files
--- @return boolean truncated `files` reached `max_files`, as today: also true when no path was left out
function FilePicker._collect_breadth_first(paths, max_files)

--- Sort `files` by path and make them the cached list.
--- @param files agentic.ui.FilePickerFile[]
function FilePicker:_set_files(files)

--- Store a scan command's output as the file list when the command
--- succeeded with output.
--- @param result vim.SystemCompleted
--- @return boolean stored
function FilePicker:_store_scan_output(result)
```

### Tests (`file_picker.test.lua`)
Existing `mocked commands` and `glob fallback` cases pass unchanged.

Add `describe("_collect_breadth_first")`; each case calls
`FilePicker._collect_breadth_first(paths, max_files)` and leaves `Config`
unchanged:
- `max_files = 0`, paths `{ "a/b/c.lua", "x.lua", "a/y.lua" }`: all three
  come back, in depth order (`x.lua`, `a/y.lua`, `a/b/c.lua`), and
  `truncated` is false.
- `max_files = 2`, the same paths: `x.lua` and `a/y.lua`, `truncated` true.
- `max_files = 0`, paths `{ "x.lua", "x.lua" }`: one file (the
  `git ls-files` unmerged case).
- `max_files = 2`, paths `{ "x.lua", "x.lua", "y.lua" }`: both files,
  `truncated` true (a duplicate does not count; the two unique files reach
  the limit).

Add a `describe("scan_files_async")` with its own setup. `FilePicker:new`
starts the async scan, so every stub goes in before the picker is made: set
`FilePicker.CMD_RG[1]`, `CMD_FD[1]` and `CMD_GIT[1]` to `"echo"` (restored
in `after_each`, as in `mocked commands`), stub `vim.system` to call its
third argument at once, and capture `vim.schedule` with
`tests/helpers/deferred.lua`. Then `FilePicker:new(buf)` and `drain()`.
- The command returns `{ code = 0, stdout = "b.lua\na.lua\n" }`: `_files`
  is `{ { path = "a.lua" }, { path = "b.lua" } }` and `_scanning` is false.
- The first command returns `code = 1`, the second succeeds: the list comes
  from the second, and `vim.system` was called twice.

## Expected outcome
A path a scan command lists more than once is one completion item and
counts once against `max_files`. No other behaviour change. The command scans and the glob fallback collect
breadth-first through one function and store the list through another, and
the success rule is in one place.

## Non-goals
- The glob patterns and the glob pre-filter.
- The wording of the two truncation logs.

## Open questions
None.
