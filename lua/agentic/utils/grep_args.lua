--- Search patterns of a grep-family command, read from its argv the way the
--- tool's own option parser reads it.
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

local PATTERN_OPTS = { "-e", "-f", "--regexp", "--file" }
local GREP_VALUE_OPTS = {
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

--- Options that take a value, per tool, by full spelling. An unlisted one
--- makes its value read as the positional pattern.
--- @type table<string, table<string, true>>
local VALUE_OPTS = {
    grep = set_of(PATTERN_OPTS, GREP_VALUE_OPTS),
    rg = set_of(PATTERN_OPTS, GREP_VALUE_OPTS, {
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
    ag = set_of(PATTERN_OPTS, { "-A", "-B", "-C", "-m", "-G", "--ignore-dir" }),
}
VALUE_OPTS.ack = VALUE_OPTS.ag

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

--- @class agentic.utils.GrepArgs.Terms
--- @field patterns string[] statically known patterns, as written, maybe empty
--- @field ignore_case boolean `-i` or `--ignore-case` given

--- Read the search patterns of a grep-family command. Explicit `-e`/`--regexp`
--- patterns win; without them (and without `-f`/`--file`) the first positional
--- is the pattern, wherever it sits among the options (GNU argument
--- permutation). Dynamic and empty patterns are dropped, not guessed at.
--- `rg --files` and `rg --type-list` search nothing, so yield no patterns.
--- @param name string command name, `git` included for `git grep`
--- @param argv string[] tokens after the name, in source order
--- @param argv_dynamic boolean[] parallel to `argv`: true where the token is
---   not a static literal
--- @return agentic.utils.GrepArgs.Terms|nil terms nil = not a grep-family command
function M.search_terms(name, argv, argv_dynamic)
    local tool = TOOL_OF_COMMAND[name]
    local i = 1
    if name == "git" then
        local start = git_grep_start(argv)
        if not start then
            return nil
        end
        tool, i = "grep", start
    end
    if not tool then
        return nil
    end
    local value_opts = VALUE_OPTS[tool]

    --- @type agentic.utils.GrepArgs.Terms
    local terms = { patterns = {}, ignore_case = false }
    -- `-e`/`-f` seen: every positional is a file
    local has_pattern_option = false
    local lists_files = false
    --- @type string|nil
    local first_positional
    --- @type boolean|nil
    local first_positional_dynamic

    --- @param token string|nil
    --- @param dynamic boolean|nil
    local function add_pattern(token, dynamic)
        if token and token ~= "" and not dynamic then
            table.insert(terms.patterns, token)
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
                if value_opts[long] then
                    i = i + 1
                    value, dynamic = argv[i], argv_dynamic[i]
                end
            end
            if long == "--ignore-case" then
                terms.ignore_case = true
            elseif
                tool == "rg"
                and (long == "--files" or long == "--type-list")
            then
                lists_files = true
            else
                take_value(long, value, dynamic)
            end
        elseif token:sub(1, 1) == "-" and #token > 1 then
            for c = 2, #token do
                local char = token:sub(c, c)
                if char == "i" then
                    terms.ignore_case = true
                elseif value_opts["-" .. char] then
                    local value, dynamic = token:sub(c + 1), argv_dynamic[i]
                    if value == "" then
                        i = i + 1
                        value, dynamic = argv[i], argv_dynamic[i]
                    end
                    take_value("-" .. char, value, dynamic)
                    break
                end
            end
        else
            add_positional(token, argv_dynamic[i])
        end
        i = i + 1
    end

    if lists_files then
        terms.patterns = {}
    elseif not has_pattern_option then
        add_pattern(first_positional, first_positional_dynamic)
    end
    return terms
end

return M
