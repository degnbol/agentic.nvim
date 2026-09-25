--- Search patterns and output layout of a grep-family command, read from its
--- argv the way the tool's own option parser reads it.
--- @class agentic.utils.GrepArgs
local M = {}

--- @param ... string[]
--- @return table<string, true>
local function set_of(...)
    local set = {}
    for _, words in ipairs({ ... }) do
        for _, w in ipairs(words) do
            set[w] = true
        end
    end
    return set
end

--- @alias agentic.utils.GrepArgs.Case "insensitive"|"sensitive"|"smart"

--- What one option does to the output. Absent fields are left as they are.
--- @class agentic.utils.GrepArgs.Effect
--- @field case? agentic.utils.GrepArgs.Case
--- @field filename? boolean prints a `path:` prefix on each match line
--- @field heading? boolean prints the file name above its matches instead
--- @field line_number? boolean
--- @field implies_line_number? true turns line numbers on unless a line-number flag decides
--- @field column? true adds a column-number field
--- @field byte_offset? true adds a byte-offset field
--- @field context? true prints context lines
--- @field stats? true prints summary lines after the matches
--- @field no_text? true the output does not show matched text as `prefix:text`

--- Index each effect by every one of its spellings.
--- @param ... { [1]: string[], [2]: agentic.utils.GrepArgs.Effect }[] rows of spellings and their effect; a later row wins
--- @return table<string, agentic.utils.GrepArgs.Effect> flags by spelling
local function flag_table(...)
    local flags = {}
    for _, rows in ipairs({ ... }) do
        for _, row in ipairs(rows) do
            for _, spelling in ipairs(row[1]) do
                flags[spelling] = row[2]
            end
        end
    end
    return flags
end

local INSENSITIVE = { case = "insensitive" }
local SENSITIVE = { case = "sensitive" }
local SMART = { case = "smart" }
local FILENAME = { filename = true }
local NO_FILENAME = { filename = false }
local HEADING = { heading = true }
local NO_HEADING = { heading = false }
local LINE_NUMBER = { line_number = true }
local NO_LINE_NUMBER = { line_number = false }
local COLUMN = { column = true }
local COLUMN_AND_LINE = { column = true, implies_line_number = true }
local VIMGREP = {
    column = true,
    implies_line_number = true,
    filename = true,
    heading = false,
}
local BYTE_OFFSET = { byte_offset = true }
local CONTEXT = { context = true }
local STATS = { stats = true }
local NO_TEXT = { no_text = true }

-- GNU grep's options, which git grep shares.
local GNU_FLAG_ROWS = {
    { { "-i", "--ignore-case" }, INSENSITIVE },
    { { "--no-ignore-case" }, SENSITIVE },
    { { "-H", "--with-filename" }, FILENAME },
    { { "-h", "--no-filename" }, NO_FILENAME },
    { { "-n", "--line-number" }, LINE_NUMBER },
    { { "-b", "--byte-offset" }, BYTE_OFFSET },
    {
        {
            "-A",
            "-B",
            "-C",
            "--context",
            "--after-context",
            "--before-context",
            -- `-NUM` is `-C NUM`
            "-1",
            "-2",
            "-3",
            "-4",
            "-5",
            "-6",
            "-7",
            "-8",
            "-9",
        },
        CONTEXT,
    },
    {
        {
            "-l",
            "-L",
            "-c",
            "-v",
            "-q",
            "-Z",
            "-z",
            "-T",
            "--files-with-matches",
            "--files-without-match",
            "--count",
            "--invert-match",
            "--quiet",
            "--silent",
            "--null",
            "--null-data",
            "--initial-tab",
        },
        NO_TEXT,
    },
}

-- ugrep does not let a later case flag override an earlier one (`-i -j Foo`
-- stays insensitive); reading it last-wins then gives case-sensitive, which
-- only drops highlights.
local UGREP_FLAG_ROWS = {
    { { "-j", "--smart-case" }, SMART },
    { { "--heading", "-+" }, HEADING },
    { { "--no-heading" }, NO_HEADING },
    { { "-k", "--column-number" }, COLUMN },
    -- GNU's obsolete `-y` is `-i`; as context it only drops highlights.
    { { "-y", "--any-line", "--passthru" }, CONTEXT },
    { { "--stats" }, STATS },
    {
        {
            "-W",
            "-X",
            "-0",
            "-^",
            "--fuzzy",
            "--replace",
            "--format",
            "--json",
            "--csv",
            "--xml",
            "--cpp",
            "--hexdump",
            "--with-hex",
            "--hex",
            "--tree",
            "--only-line-number",
            "--files",
            "--separator",
            "--context-separator",
        },
        NO_TEXT,
    },
}

local GIT_GREP_FLAG_ROWS = {
    { { "--heading" }, HEADING },
    { { "--column" }, COLUMN },
    { { "-p", "--show-function", "-W", "--function-context" }, CONTEXT },
    { { "--name-only", "-O", "--open-files-in-pager" }, NO_TEXT },
}

local RG_FLAGS = flag_table({
    { { "-i", "--ignore-case" }, INSENSITIVE },
    { { "-s", "--case-sensitive" }, SENSITIVE },
    { { "-S", "--smart-case" }, SMART },
    { { "-H", "--with-filename" }, FILENAME },
    { { "-I", "--no-filename" }, NO_FILENAME },
    { { "--heading" }, HEADING },
    { { "-p", "--pretty" }, { heading = true, line_number = true } },
    { { "--no-heading" }, NO_HEADING },
    { { "-n", "--line-number" }, LINE_NUMBER },
    { { "-N", "--no-line-number" }, NO_LINE_NUMBER },
    { { "--column" }, COLUMN_AND_LINE },
    { { "--vimgrep" }, VIMGREP },
    { { "-b", "--byte-offset" }, BYTE_OFFSET },
    {
        {
            "-A",
            "-B",
            "-C",
            "--context",
            "--after-context",
            "--before-context",
            "--passthru",
        },
        CONTEXT,
    },
    { { "--stats" }, STATS },
    {
        {
            "-l",
            "-c",
            "-v",
            "-q",
            "-r",
            "-U",
            "-0",
            "--files-with-matches",
            "--files-without-match",
            "--count",
            "--count-matches",
            "--invert-match",
            "--quiet",
            "--replace",
            "--multiline",
            "--json",
            "--null",
            "--field-match-separator",
        },
        NO_TEXT,
    },
})

local AG_FLAGS = flag_table({
    { { "-i", "--ignore-case" }, INSENSITIVE },
    { { "-s", "--case-sensitive" }, SENSITIVE },
    { { "-S", "--smart-case" }, SMART },
    { { "--filename" }, FILENAME },
    { { "--nofilename" }, NO_FILENAME },
    { { "-H", "--heading", "--group" }, HEADING },
    { { "--noheading", "--nogroup" }, NO_HEADING },
    { { "--numbers" }, LINE_NUMBER },
    { { "--nonumbers" }, NO_LINE_NUMBER },
    { { "--column" }, COLUMN_AND_LINE },
    { { "--vimgrep" }, VIMGREP },
    {
        {
            "-A",
            "-B",
            "-C",
            "--after",
            "--before",
            "--context",
            "--passthrough",
            "--passthru",
        },
        CONTEXT,
    },
    { { "--stats", "--print-all-files" }, STATS },
    {
        {
            "-l",
            "-L",
            "-c",
            "-v",
            "-g",
            "-0",
            "--files-with-matches",
            "--files-without-matches",
            "--count",
            "--invert-match",
            "--null",
            "--print0",
            "--ackmate",
        },
        NO_TEXT,
    },
})

local ACK_FLAGS = flag_table({
    { { "-i", "--ignore-case" }, INSENSITIVE },
    { { "-I", "--no-ignore-case" }, SENSITIVE },
    { { "-S", "--smart-case" }, SMART },
    { { "-H", "--with-filename" }, FILENAME },
    { { "-h", "--no-filename" }, NO_FILENAME },
    { { "--heading", "--group" }, HEADING },
    { { "--noheading", "--nogroup" }, NO_HEADING },
    { { "--column" }, COLUMN_AND_LINE },
    {
        {
            "-A",
            "-B",
            "-C",
            "--context",
            "--after-context",
            "--before-context",
            "--passthru",
        },
        CONTEXT,
    },
    {
        {
            "-l",
            "-L",
            "-c",
            "-v",
            "-f",
            "-g",
            "--files-with-matches",
            "--files-without-match",
            "--files-without-matches",
            "--count",
            "--invert-match",
            "--output",
            "--print0",
        },
        NO_TEXT,
    },
})

local PATTERN_OPTS = { "-e", "-f", "--regexp", "--file" }
local GNU_VALUE_OPTS = {
    "-A",
    "-B",
    "-C",
    "-m",
    "-d",
    "-D",
    "--include",
    "--exclude",
    "--exclude-dir",
    "--max-count",
    "--context",
    "--after-context",
    "--before-context",
    "--label",
}
local UGREP_VALUE_OPTS = {
    "-N",
    "-t",
    "-g",
    "-O",
    "-M",
    "-J",
    "-K",
    "--neg-regexp",
    "--file-type",
    "--glob",
    "--iglob",
    "--file-extension",
    "--file-magic",
    "--jobs",
    "--range",
}

--- The option grammar and output defaults of one grep-family tool.
--- @class agentic.utils.GrepArgs.Tool
--- @field flags table<string, agentic.utils.GrepArgs.Effect> by full spelling
--- @field value_opts table<string, true> options that take a value, by full
---   spelling; an unlisted one makes its value read as the positional pattern
--- @field number_opts table<string, true> options whose value is optional and
---   numeric: a separate next token is their value only when it is a number
--- @field case agentic.utils.GrepArgs.Case without a case flag
--- @field names integer[] possible counts of `name:` fields without a flag
--- @field line_numbers integer[] possible line-number field counts without a flag
--- @field columns integer[] possible column field counts without a flag
--- @field diagnostic_names string[] names the tool's own messages start with

--- @type table<string, agentic.utils.GrepArgs.Tool>
local TOOLS = {
    -- GNU grep and ugrep together, since `grep` may be either.
    grep = {
        flags = flag_table(GNU_FLAG_ROWS, UGREP_FLAG_ROWS),
        value_opts = set_of(PATTERN_OPTS, GNU_VALUE_OPTS, UGREP_VALUE_OPTS),
        number_opts = {},
        case = "sensitive",
        names = { 0, 1 },
        line_numbers = { 0 },
        columns = { 0 },
        diagnostic_names = { "grep", "ugrep" },
    },
    -- `grep.lineNumber` and `grep.column` in git config can turn both on.
    git = {
        flags = flag_table(GNU_FLAG_ROWS, GIT_GREP_FLAG_ROWS),
        value_opts = set_of(PATTERN_OPTS, GNU_VALUE_OPTS),
        number_opts = {},
        case = "sensitive",
        names = { 1 },
        line_numbers = { 0, 1 },
        columns = { 0, 1 },
        diagnostic_names = { "fatal", "error", "warning" },
    },
    rg = {
        flags = RG_FLAGS,
        value_opts = set_of(PATTERN_OPTS, GNU_VALUE_OPTS, {
            "-g",
            "-t",
            "-T",
            "-j",
            "-M",
            "-E",
            "-r",
            "--glob",
            "--iglob",
            "--type",
            "--type-not",
            "--type-add",
            "--max-depth",
            "--max-filesize",
            "--threads",
            "--max-columns",
            "--encoding",
            "--sort",
            "--sortr",
            "--replace",
            "--color",
            "--colors",
            "--pre",
        }),
        number_opts = {},
        case = "sensitive",
        names = { 0, 1 },
        line_numbers = { 0 },
        columns = { 0 },
        diagnostic_names = { "rg" },
    },
    -- ag omits line numbers when it searches a stream.
    ag = {
        flags = AG_FLAGS,
        value_opts = set_of({
            "-m",
            "-G",
            "-g",
            "-p",
            "-W",
            "--max-count",
            "--file-search-regex",
            "--depth",
            "--ignore",
            "--ignore-dir",
            "--pager",
            "--path-to-ignore",
            "--width",
            "--workers",
        }),
        number_opts = set_of({
            "-A",
            "-B",
            "-C",
            "--after",
            "--before",
            "--context",
        }),
        case = "smart",
        names = { 0, 1 },
        line_numbers = { 0, 1 },
        columns = { 0 },
        diagnostic_names = { "ag" },
    },
    ack = {
        flags = ACK_FLAGS,
        value_opts = set_of({
            "-A",
            "-B",
            "-m",
            "-g",
            "-t",
            "-T",
            "--after-context",
            "--before-context",
            "--max-count",
            "--type",
            "--type-add",
            "--type-set",
            "--type-del",
            "--ignore-dir",
            "--noignore-dir",
            "--ignore-file",
            "--files-from",
            "--ackrc",
            "--pager",
            "--output",
            "--and",
            "--or",
            "--not",
        }),
        number_opts = set_of({ "-C", "--context" }),
        case = "sensitive",
        names = { 0, 1 },
        line_numbers = { 0, 1 },
        columns = { 0 },
        diagnostic_names = { "ack" },
    },
}

--- Tool whose option grammar each command name follows.
--- @type table<string, string>
local TOOL_OF_COMMAND = {
    grep = "grep",
    ugrep = "grep",
    rg = "rg",
    ag = "ag",
    ack = "ack",
}

--- git global options that take the next token as their value.
local GIT_VALUE_OPTS =
    set_of({ "-C", "-c", "--git-dir", "--work-tree", "--namespace" })

--- Index of the first token after `grep` in a git argv, skipping git's global
--- options.
--- @param argv string[] tokens after `git`
--- @return integer|nil i nil = the subcommand is not `grep`
local function git_grep_start(argv)
    local i = 1
    while argv[i] and argv[i]:sub(1, 1) == "-" do
        i = i + (GIT_VALUE_OPTS[argv[i]] and 2 or 1)
    end
    if argv[i] ~= "grep" then
        return nil
    end
    return i + 1
end

--- The shapes a match line of one grep run can take.
--- @class agentic.utils.GrepArgs.Layout
--- @field names integer[] possible counts of `name:` fields that open a match
---   line: a file name, and for git grep a revision before it
--- @field fields integer[] possible counts of numeric `N:` fields after them,
---   empty when the output shows no matched text

--- One grep-family command, parsed.
--- @class agentic.utils.GrepArgs.Invocation
--- @field patterns string[] its patterns, as written; empty when any pattern's
---   text is unknown (dynamic, or read from a file)
--- @field ignore_case boolean every pattern matches case-insensitively, smart case resolved
--- @field line_numbers boolean line numbers are on by flag
--- @field layout agentic.utils.GrepArgs.Layout
--- @field diagnostic_names string[] names the tool's own messages start with

--- Whether smart case matches every pattern case-insensitively: none holds an
--- ASCII uppercase letter, a non-ASCII byte, or a `\x`/`\u` escape.
--- @param patterns string[]
--- @return boolean
local function smart_case_folds(patterns)
    for _, pattern in ipairs(patterns) do
        if pattern:find("[A-Z\128-\255]") or pattern:find("\\[xu]") then
            return false
        end
    end
    return true
end

--- Every sum of one count from `a` and one from `b`, ascending.
--- @param a integer[]
--- @param b integer[]
--- @return integer[]
local function sums(a, b)
    local out = {}
    for _, x in ipairs(a) do
        for _, y in ipairs(b) do
            if not vim.list_contains(out, x + y) then
                table.insert(out, x + y)
            end
        end
    end
    table.sort(out)
    return out
end

--- Parse a grep-family command: its search patterns, case rule and output
--- layout, read from its argv the way the tool's own option parser reads it.
--- Explicit `-e`/`--regexp` patterns win; without them (and without
--- `-f`/`--file`) the first positional is the pattern, wherever it sits among
--- the options (GNU argument permutation). Empty patterns are dropped.
--- `rg --files` and `rg --type-list` search nothing, so yield no patterns.
--- Output state the flags leave open (whether a file name shows, git config)
--- gives every possible layout.
--- @param name string command name, `git` included for `git grep`
--- @param argv string[] tokens after the name, in source order
--- @param argv_dynamic boolean[] parallel to `argv`: true where the token is
---   not a static literal
--- @return agentic.utils.GrepArgs.Invocation|nil invocation nil = not a grep-family command
function M.parse(name, argv, argv_dynamic)
    local tool_name = TOOL_OF_COMMAND[name]
    local i = 1
    if name == "git" then
        local start = git_grep_start(argv)
        if not start then
            return nil
        end
        tool_name, i = "git", start
    end
    local tool = TOOLS[tool_name]
    if not tool then
        return nil
    end

    --- @type string[]
    local patterns = {}
    --- @type agentic.utils.GrepArgs.Effect
    local state = { case = tool.case }
    -- `-e`/`-f` seen: every positional is a file
    local has_pattern_option = false
    -- a pattern whose text is unknown: dynamic, or read from a file
    local has_unknown_pattern = false
    local lists_files = false
    -- positionals before a `--`, the pattern among them unless given by option
    local n_positionals = 0
    --- @type string|nil
    local first_positional
    --- @type boolean|nil
    local first_positional_dynamic

    --- @param effect agentic.utils.GrepArgs.Effect|nil
    local function apply(effect)
        for key, value in pairs(effect or {}) do
            state[key] = value
        end
    end

    --- @param option string full spelling
    --- @param next_token string|nil the token after the option
    --- @return boolean
    local function takes_next(option, next_token)
        return tool.value_opts[option]
            or (tool.number_opts[option] and (next_token or ""):match("^%d+$"))
            or false
    end

    --- @param token string|nil
    --- @param dynamic boolean|nil
    local function add_pattern(token, dynamic)
        if dynamic then
            has_unknown_pattern = true
        elseif token and token ~= "" then
            table.insert(patterns, token)
        end
    end

    --- @param option string full spelling (`-e`, `--regexp`)
    --- @param value string|nil
    --- @param dynamic boolean|nil
    local function take_value(option, value, dynamic)
        if option == "-e" or option == "--regexp" then
            has_pattern_option = true
            add_pattern(value, dynamic)
        elseif option == "-f" or option == "--file" then
            has_pattern_option = true
            has_unknown_pattern = true
        end
    end

    --- @param token string|nil
    --- @param dynamic boolean|nil
    local function add_positional(token, dynamic)
        if first_positional == nil then
            first_positional, first_positional_dynamic = token, dynamic
        end
    end

    while i <= #argv do
        local token = argv[i]
        if token == "--" then
            add_positional(argv[i + 1], argv_dynamic[i + 1])
            break
        elseif token:sub(1, 2) == "--" then
            local long, value = token:match("^(%-%-[^=]+)=(.*)$")
            local dynamic = argv_dynamic[i]
            if not long then
                long = token
                if takes_next(long, argv[i + 1]) then
                    i = i + 1
                    value, dynamic = argv[i], argv_dynamic[i]
                end
            end
            apply(tool.flags[long])
            if
                tool_name == "rg"
                and (long == "--files" or long == "--type-list")
            then
                lists_files = true
            elseif takes_next(long, value) then
                take_value(long, value, dynamic)
            end
        elseif token:sub(1, 1) == "-" and #token > 1 then
            for c = 2, #token do
                local option = "-" .. token:sub(c, c)
                apply(tool.flags[option])
                if tool.value_opts[option] or tool.number_opts[option] then
                    local value, dynamic = token:sub(c + 1), argv_dynamic[i]
                    if value == "" and takes_next(option, argv[i + 1]) then
                        i = i + 1
                        value, dynamic = argv[i], argv_dynamic[i]
                    end
                    take_value(option, value, dynamic)
                    break
                end
            end
        else
            n_positionals = n_positionals + 1
            add_positional(token, argv_dynamic[i])
        end
        i = i + 1
    end

    if not lists_files and not has_pattern_option then
        add_pattern(first_positional, first_positional_dynamic)
    end
    -- The tool matches all its patterns together, so an unknown one can take
    -- the text a known one would highlight.
    if lists_files or has_unknown_pattern then
        patterns = {}
    end

    local names = tool.names
    if state.filename ~= nil then
        names = { state.filename and 1 or 0 }
    end
    -- git grep prints `rev:path:` for a revision, and one may sit among the
    -- positionals after the pattern.
    local n_pattern_positionals = has_pattern_option and 0 or 1
    if
        tool_name == "git"
        and state.filename ~= false
        and n_positionals > n_pattern_positionals
    then
        names = { 1, 2 }
    end
    local line_number = state.line_number
    if line_number == nil and state.implies_line_number then
        line_number = true
    end
    local line_numbers = tool.line_numbers
    if line_number ~= nil then
        line_numbers = { line_number and 1 or 0 }
    end
    local fields = sums(
        sums(line_numbers, state.column and { 1 } or tool.columns),
        { state.byte_offset and 1 or 0 }
    )
    if state.heading then
        names = { 0 }
        fields = vim.tbl_filter(function(n)
            return n > 0
        end, fields)
    end
    -- Without a numeric field, a context line with a file name parses as a
    -- match line: whole (`d/a.lua-x`, path included) under a no-file-name
    -- layout, or from its first `:` (`d/a.lua-x:y`, mid-line) under a
    -- file-name layout. A summary line (`2 matches`) parses whole.
    local has_bare_layout = vim.list_contains(fields, 0)
    if
        state.no_text
        or (state.stats and has_bare_layout)
        or (
            state.context
            and has_bare_layout
            and vim.iter(names):any(function(n)
                return n > 0
            end)
        )
    then
        fields = {}
    end

    --- @type agentic.utils.GrepArgs.Invocation
    local invocation = {
        patterns = patterns,
        ignore_case = state.case == "insensitive"
            or (state.case == "smart" and smart_case_folds(patterns)),
        line_numbers = line_number == true,
        layout = { names = names, fields = fields },
        diagnostic_names = tool.diagnostic_names,
    }
    return invocation
end

return M
