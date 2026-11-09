--- Code a command executes that its arguments do not show: shell commands
--- read from a file (`READERS`), and config files that make a tool load code
--- (`runs_code`).
--- @class agentic.utils.ExecutedCode
local M = {}

local ConfigKeys = require("agentic.utils.config_keys")
local FileSystem = require("agentic.utils.file_system")
local JustRecipe = require("agentic.utils.just_recipe")
local Logger = require("agentic.utils.logger")
local MakeRecipe = require("agentic.utils.make_recipe")
local ShellParse = require("agentic.utils.shell_parse")

--- Largest file this module reads.
local MAX_READ_BYTES = 64 * 1024

--- How long a reader waits for a subprocess it runs.
local SUBPROCESS_TIMEOUT_MS = 2000

--- The shell commands a command runs from code it reads.
--- @class agentic.ExecutedCode.Code
--- @field dir string|nil directory the commands start in; nil when unknown
--- @field commands string[] shell source, one entry per separately run command

--- Turns a command into the shell commands it runs from the code it reads.
--- `args` are the delivered words after the name, a static word that names
--- a path given as the path (`ShellParse.delivered_path`). `cwd` is the
--- directory the command runs in, nil when unknown. `read` gives a file's
--- bytes as the command would see them: nil when the file is missing, false
--- when it may exist with unknown bytes. A reader judges a file only by what
--- `read` gives. `memo` is a table the reader may cache in, kept as long as
--- the caller chooses. Returns nil to decline the command.
--- @alias agentic.ExecutedCode.Reader fun(args: string[], args_dynamic: boolean[], cwd: string|nil, read: (fun(path: string): string|false|nil), memo: table): agentic.ExecutedCode.Code|nil

--- Run a command and wait for it, at most `SUBPROCESS_TIMEOUT_MS`. A failure
--- to start it is notified.
--- @param cmd string[]
--- @param cwd string|nil
--- @return vim.SystemCompleted|nil result nil when it did not start
local function run(cmd, cwd)
    local ok, result = pcall(function()
        return vim.system(cmd, { text = true, cwd = cwd })
            :wait(SUBPROCESS_TIMEOUT_MS)
    end)
    if not ok then
        Logger.notify(
            "Could not run " .. cmd[1] .. ": " .. tostring(result),
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return nil
    end
    return result
end

--- Whether any word is dynamic, an option, or a `NAME=value` assignment.
--- @param args string[]
--- @param args_dynamic boolean[] parallel to `args`
--- @return boolean
local function has_unread_word(args, args_dynamic)
    for i, arg in ipairs(args) do
        if
            args_dynamic[i]
            or arg:sub(1, 1) == "-"
            or arg:find("=", 1, true)
        then
            return true
        end
    end
    return false
end

--- A reader for a shell that runs or sources a script file: the file's text
--- as one command, in the shell's cwd.
--- @param cmd_name string
--- @return agentic.ExecutedCode.Reader
local function shell_reader(cmd_name)
    return function(args, args_dynamic, cwd, read)
        local operand =
            ShellParse.script_file_source(cmd_name, args, args_dynamic)
        local paths = operand
            and ShellParse.script_paths(
                cmd_name,
                operand,
                cwd and { dirs = { cwd }, unknown = false }
                    or ShellParse.unknown_cwds()
            )
        local text = paths and read(paths[1].path)
        --- @type agentic.ExecutedCode.Code|nil
        local code = text and { dir = cwd, commands = { text } } or nil
        return code
    end
end

--- The bytes of a regular file of at most `MAX_READ_BYTES`.
--- @param path string
--- @return string|nil
local function read_file(path)
    return FileSystem.read_regular_file(path, MAX_READ_BYTES)
end

--- Built-in implicit rules of each make binary, keyed by its path.
--- @type table<string, agentic.MakePatternRule[]>
local builtin_rules_by_make = {}

--- The built-in implicit rules of the `make` on `PATH`, from its database.
--- Memoised per binary once read.
--- @return agentic.MakePatternRule[]|nil rules nil when there is no
---         `make` or its database cannot be read
local function builtin_rules()
    local make = vim.fn.exepath("make")
    if make == "" then
        return nil
    end
    if not builtin_rules_by_make[make] then
        local result = run({ make, "-p", "-f", "/dev/null" })
        if not result or not result.stdout or result.stdout == "" then
            return nil
        end
        builtin_rules_by_make[make] = MakeRecipe.builtin_patterns(result.stdout)
    end
    return builtin_rules_by_make[make]
end

--- GNU make's makefile names, in the order it looks for them.
local MAKEFILE_NAMES = { "GNUmakefile", "makefile", "Makefile" }

--- The commands GNU make runs for `args`, from the makefile it picks in
--- `cwd`. Declines on an unknown `cwd`, any dynamic word, option or
--- assignment, no makefile, or no readable built-in rules.
--- @type agentic.ExecutedCode.Reader
local function make_reader(args, args_dynamic, cwd, read)
    if not cwd or has_unread_word(args, args_dynamic) then
        return nil
    end
    --- @type string|nil
    local makefile
    --- @type string|false|nil
    local text
    for _, name in ipairs(MAKEFILE_NAMES) do
        text = read(vim.fs.joinpath(cwd, name))
        if text ~= nil then
            makefile = name
            break
        end
    end
    local rules = text and builtin_rules()
    local commands = rules
        and MakeRecipe.commands(
            text --[[@as string]],
            args,
            rules,
            -- A file of unknown bytes may exist.
            function(path)
                return read(vim.fs.joinpath(cwd, path)) ~= nil
            end,
            makefile --[[@as string]]
        )
    --- @type agentic.ExecutedCode.Code|nil
    local code = commands and { dir = cwd, commands = commands } or nil
    return code
end

--- just's own parse of the justfile that `cwd` finds, decoded. Memoised in
--- `memo` per directory.
--- @param cwd string
--- @param memo table
--- @return table|nil dump nil when there is no `just`, no justfile, or the
---         dump fails
local function just_dump(cwd, memo)
    memo.just_dumps = memo.just_dumps or {}
    local cached = memo.just_dumps[cwd]
    if cached == nil then
        cached = false
        local just = vim.fn.exepath("just")
        local result = just ~= ""
            and run({ just, "--dump", "--dump-format", "json" }, cwd)
        if result and result.code == 0 then
            local decoded, dump =
                pcall(vim.json.decode, result.stdout, JustRecipe.DECODE_OPTS)
            cached = decoded and type(dump) == "table" and dump or false
        end
        memo.just_dumps[cwd] = cached
    end
    return cached or nil
end

--- Whether a justfile may hold text the dump does not show as written: an
--- `import` (the dump merges the imported file in), or a shell-expanded
--- `x'…'` string (the dump holds its value under the environment that ran
--- the dump, not the one `just` will run in). Over-approximates by text.
--- @param text string
--- @return boolean
local function justfile_hides_text(text)
    return text:find("%f[%w_]x['\"]") ~= nil
        or ("\n" .. text):find("\n%s*import[%s?]") ~= nil
end

--- The commands `just` runs for `args`, from its own parse of the justfile
--- `cwd` finds. Declines on an unknown `cwd`, any dynamic word, option or
--- assignment, a justfile whose `read` bytes differ from disk (`just` reads
--- the disk itself), or one the parse may not show as written.
--- @type agentic.ExecutedCode.Reader
local function just_reader(args, args_dynamic, cwd, read, memo)
    if not cwd or has_unread_word(args, args_dynamic) then
        return nil
    end
    local dump = just_dump(cwd, memo)
    local source = dump and dump.source
    local text = type(source) == "string" and read_file(source)
    if
        not text
        or read(source --[[@as string]]) ~= text
        or justfile_hides_text(text)
    then
        return nil
    end
    local commands = JustRecipe.recipe_commands(dump --[[@as table]], args)
    --- @type agentic.ExecutedCode.Code|nil
    local code = commands
            and { dir = vim.fs.dirname(source), commands = commands }
        or nil
    return code
end

--- The reader of each command name that runs code it reads.
--- @type table<string, agentic.ExecutedCode.Reader>
M.READERS = { make = make_reader, just = just_reader }
for _, name in ipairs({ "source", "." }) do
    M.READERS[name] = shell_reader(name)
end
for name in pairs(ShellParse.SHELL_C_COMMANDS) do
    M.READERS[name] = shell_reader(name)
end

--- Whether a key path lies at or below one of the dotted prefixes. Paths
--- compare joined with `.`, so a key that holds a dot (`{ "a.b": 1 }`) reads
--- as the nested keys it spells, as tools that accept both forms read it.
--- @param key_path string[]
--- @param prefixes string[] dotted, `*` matching one segment
--- @return boolean
local function under_any(key_path, prefixes)
    local dotted = table.concat(key_path, ".") .. "."
    return vim.iter(prefixes):any(function(prefix)
        local pattern = vim.pesc(prefix .. "."):gsub("%%%*", "[^.]+")
        return dotted:find("^" .. pattern) ~= nil
    end)
end

--- Whether a config file's content makes an item match. A file that cannot
--- be read or parsed matches.
--- @param item agentic.PermRunsItem
--- @param path string
--- @return boolean
local function file_matches(item, path)
    if not item.keys and not item.except_keys then
        return true
    end
    local text = read_file(path)
    local key_paths = text
        and ConfigKeys.key_paths(
            text,
            item.format --[[@as agentic.ConfigFormat]]
        )
    if not key_paths then
        return true
    end
    return vim.iter(key_paths):any(function(key_path)
        return (item.keys ~= nil and under_any(key_path, item.keys))
            or (
                item.except_keys ~= nil
                and not under_any(key_path, item.except_keys)
            )
    end)
end

--- The non-directory files a glob relative to `dir` names, ignoring case (a
--- file system may). Only its last segment may hold glob syntax.
--- @param dir string
--- @param glob string
--- @return string[] paths
local function glob_files(dir, glob)
    local parent, base = glob:match("^(.*)/([^/]*)$")
    local search = parent and vim.fs.joinpath(dir, parent) or dir
    local pattern = vim.glob.to_lpeg((base or glob):lower())
    local paths = {}
    for name, type in vim.fs.dir(search) do
        if type ~= "directory" and pattern:match(name:lower()) then
            table.insert(paths, vim.fs.joinpath(search, name))
        end
    end
    return paths
end

--- `dir` and each of its parents.
--- @param dir string absolute
--- @return string[] dirs
local function search_dirs(dir)
    local dirs = { dir }
    for parent in vim.fs.parents(dir) do
        table.insert(dirs, parent)
    end
    return dirs
end

--- The directory an item's `path` is relative to.
--- @param item agentic.PermRunsItem
--- @param args string[]
--- @param args_dynamic boolean[] parallel to `args`
--- @param cwd string
--- @return string|nil dir nil for the operand anchor unless exactly one
---         argument is a directory (an option's value may be one) and no
---         word is dynamic
local function anchor_dir(item, args, args_dynamic, cwd)
    if item.anchor ~= "operand" then
        return cwd
    end
    --- @type string[]
    local dirs = {}
    for i, arg in ipairs(args) do
        if args_dynamic[i] then
            return nil
        end
        local path = arg:sub(1, 1) ~= "-"
                and ShellParse.resolve_against_cwd(arg, cwd)
            or nil
        local st = path and vim.uv.fs_stat(path)
        if st and st.type == "directory" then
            table.insert(dirs, path)
        end
    end
    return #dirs == 1 and dirs[1] or nil
end

--- Whether a command may load code from a config file one of `items`
--- matches, as the files are on disk. An item whose anchor directory is
--- unknown counts as a match.
--- @param items agentic.PermRunsItem[]
--- @param args string[] delivered words after the command name
--- @param args_dynamic boolean[] parallel to `args`
--- @param cwd string absolute directory the command runs in
--- @return boolean
function M.runs_code(items, args, args_dynamic, cwd)
    return vim.iter(items):any(function(item)
        local anchor = anchor_dir(item, args, args_dynamic, cwd)
        if not anchor then
            return true
        end
        local dirs = item.up and search_dirs(anchor) or { anchor }
        return vim.iter(dirs):any(function(dir)
            return vim.iter(glob_files(dir, item.path)):any(function(path)
                return file_matches(item, path)
            end)
        end)
    end)
end

return M
