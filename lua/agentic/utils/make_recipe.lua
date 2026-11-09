local ShellParse = require("agentic.utils.shell_parse")

--- The shell commands `make TARGET…` would run, read from makefile text by a
--- line-level allowlist of GNU make syntax. Any construct whose effect the
--- text alone does not settle (functions, includes, conditionals, names the
--- environment or make itself can change, built-in rules) declines.
--- @class agentic.utils.MakeRecipe
local M = {}

--- @class agentic.MakePatternRule
--- @field target string target pattern with one `%`
--- @field prerequisites string[] prerequisite patterns
--- @field terminal boolean double-colon rule: it applies only when its
---        prerequisites exist, never through a chain

--- @class agentic.MakeVar
--- @field value string
--- @field recursive boolean the value is expanded at each use

--- @class agentic.MakeTargetVar
--- @field name string
--- @field var? agentic.MakeVar the value an `=` or `:=` sets
--- @field append? string the text a `+=` appends, expanded at use

--- @class agentic.MakeRule
--- @field targets string[]
--- @field prerequisites string[]
--- @field recipe? string[] recipe lines without their leading tab

--- @class agentic.Makefile
--- @field vars table<string, agentic.MakeVar> global variables
--- @field rules agentic.MakeRule[] explicit rules in file order
--- @field target_vars table<string, agentic.MakeTargetVar[]>
--- @field mentioned table<string, true> every target and prerequisite

--- @class agentic.MakeTarget
--- @field prerequisites string[] the recipe rule's first, without repeats
--- @field recipe? string[]

local DIRECTIVES = {}
for _, word in ipairs({
    "include",
    "-include",
    "sinclude",
    "load",
    "-load",
    "ifeq",
    "ifneq",
    "ifdef",
    "ifndef",
    "else",
    "endif",
    "define",
    "endef",
    "export",
    "unexport",
    "override",
    "private",
    "undefine",
    "vpath",
}) do
    DIRECTIVES[word] = true
end

local NAME = "^[%w_.%-]+$"
local AUTOMATIC = { ["@"] = true, ["<"] = true, ["^"] = true }

--- Expands the variable references in `text`.
--- @param text string
--- @param lookup fun(name: string): string|nil a variable's value, nil when
---        it cannot be known
--- @return string|nil expanded nil on a function call, a substitution or
---         computed reference, an unterminated reference, or a value
---         `lookup` cannot give
local function expand(text, lookup)
    local parts, i = {}, 1
    while true do
        local dollar = text:find("$", i, true)
        table.insert(parts, text:sub(i, dollar and dollar - 1 or nil))
        if not dollar then
            return table.concat(parts)
        end
        local open = text:sub(dollar + 1, dollar + 1)
        local name
        if open == "$" then
            name, i = nil, dollar + 2
            table.insert(parts, "$")
        elseif open == "(" or open == "{" then
            local close =
                text:find(open == "(" and ")" or "}", dollar + 2, true)
            if not close then
                return nil
            end
            name, i = text:sub(dollar + 2, close - 1), close + 1
        else
            name, i = open, dollar + 2
        end
        if name then
            local value = (name:match(NAME) or AUTOMATIC[name]) and lookup(name)
            if not value then
                return nil
            end
            table.insert(parts, value)
        end
    end
end

--- Variable lookup over `vars`, expanding recursive values in the same
--- scope.
--- @param vars table<string, agentic.MakeVar>
--- @param automatic table<string, string>|nil automatic variable values, nil
---        outside a recipe
--- @return fun(name: string): string|nil lookup nil for an unassigned name or
---         a recursive cycle
local function scope_lookup(vars, automatic)
    local active = {}
    local function lookup(name)
        if AUTOMATIC[name] then
            return automatic and automatic[name]
        end
        local var = vars[name]
        if not var or not var.recursive then
            return var and var.value
        end
        if active[name] then
            return nil
        end
        active[name] = true
        local value = expand(var.value, lookup)
        active[name] = nil
        return value
    end
    return lookup
end

--- The result of a global assignment.
--- @param base agentic.MakeVar|nil the variable's value before it
--- @param op string assignment operator
--- @param value string right-hand side as written
--- @param lookup fun(name: string): string|nil
--- @return agentic.MakeVar|nil var nil for an operator other than `=`, `:=`
---         and `+=`, a `+=` without `base`, or a value that cannot be known
local function assigned(base, op, value, lookup)
    if op == "=" then
        return { value = value, recursive = true }
    end
    if op == ":=" then
        base = nil
    elseif op ~= "+=" or not base then
        return nil
    end
    if base and base.recursive then
        return { value = base.value .. " " .. value, recursive = true }
    end
    local expanded = expand(value, lookup)
    return expanded
        and {
            value = base and base.value .. " " .. expanded or expanded,
            recursive = false,
        }
end

--- Global variables with target-specific assignments applied in order.
--- A `+=` makes the variable recursive, keeping a simple base literal.
--- @param globals table<string, agentic.MakeVar>
--- @param scopes agentic.MakeTargetVar[][] outermost first
--- @return table<string, agentic.MakeVar>|nil vars nil when a `+=` has no
---         value to append to
local function scoped_vars(globals, scopes)
    local vars = setmetatable({}, { __index = globals })
    for _, scope in ipairs(scopes) do
        for _, entry in ipairs(scope) do
            local base = vars[entry.name]
            if entry.var then
                vars[entry.name] = entry.var
            elseif not base then
                return nil
            else
                local text = base.recursive and base.value
                    or base.value:gsub("%$", "$$")
                vars[entry.name] = {
                    value = text .. " " .. entry.append,
                    recursive = true,
                }
            end
        end
    end
    return vars
end

--- Whether every variable the makefile assigns expands to known text. make
--- expands each variable it exports (one the environment also has) for every
--- recipe it runs, whether or not the recipe uses it.
--- @param globals table<string, agentic.MakeVar>
--- @param scopes agentic.MakeTargetVar[][] target-specific variables in effect
--- @param lookup fun(name: string): string|nil
--- @return boolean
local function all_expand(globals, scopes, lookup)
    for name in pairs(globals) do
        if not lookup(name) then
            return false
        end
    end
    for _, scope in ipairs(scopes) do
        for _, entry in ipairs(scope) do
            if not lookup(entry.name) then
                return false
            end
        end
    end
    return true
end

--- Position of the first character of `chars` outside variable references.
--- @param text string
--- @param chars string
--- @return integer|nil position nil when there is none
local function find_outside_refs(text, chars)
    local i = 1
    while i <= #text do
        local c = text:sub(i, i)
        local open = text:sub(i + 1, i + 1)
        if c == "$" and (open == "(" or open == "{") then
            local close = text:find(open == "(" and ")" or "}", i + 2, true)
            i = (close or #text) + 1
        elseif c == "$" then
            i = i + 2
        elseif chars:find(c, 1, true) then
            return i
        else
            i = i + 1
        end
    end
    return nil
end

--- Splits a variable assignment.
--- @param text string
--- @return string|nil name nil when the first `:` or `=` outside references
---         does not start an assignment operator
--- @return string op `=`, `:=`, `::=`, `+=`, `?=` or `!=`
--- @return string value right-hand side without leading whitespace
local function split_assignment(text)
    local at = find_outside_refs(text, ":=")
    if not at then
        return nil, "", ""
    end
    local op, name_end
    if text:sub(at, at) == "=" then
        local prefix = text:sub(at - 1, at - 1)
        op = prefix:match("^[+?!]$") and prefix .. "=" or "="
        name_end = at - #op
    else
        op = text:match("^::?=", at)
        name_end = at - 1
    end
    if not op then
        return nil, "", ""
    end
    local value = text:sub(name_end + #op + 1):gsub("^%s+", "")
    return vim.trim(text:sub(1, name_end)), op, value
end

--- Whether a makefile may assign `name` without changing how make runs.
--- @param name string
--- @return boolean
local function settable(name)
    return name:match(NAME) ~= nil
        and (name == ".DEFAULT_GOAL" or ShellParse.is_safe_var_name(name))
end

--- A file name as make reads it: each leading `./` removed with the slashes
--- after it, while a character follows.
--- @param name string
--- @return string
local function strip_dot_slash(name)
    while name:match("^%./.") do
        name = name:sub(3):gsub("^/+", "")
    end
    return name
end

--- Words of a target or prerequisite list, as make reads each file name.
--- @param text string|nil
--- @return string[]|nil words nil for nil `text` or a word that make would
---         read as more than a file name (wildcard, pattern, archive member,
---         `~`, escape) or as nothing
local function file_words(text)
    if not text then
        return nil
    end
    local words = {}
    for word in text:gmatch("%S+") do
        word = strip_dot_slash(word)
        if word == "" or word:find("[%%*?%[%]()~:=;|#\\]") then
            return nil
        end
        table.insert(words, word)
    end
    return words
end

--- Text up to the first `#` that no backslash escapes, with `\#` read as `#`.
--- @param line string
--- @return string
local function strip_comment(line)
    local parts, i = {}, 1
    while true do
        local hash = line:find("#", i, true)
        if not hash then
            table.insert(parts, line:sub(i))
            break
        end
        if line:sub(hash - 1, hash - 1) ~= "\\" then
            table.insert(parts, line:sub(i, hash - 1))
            break
        end
        table.insert(parts, line:sub(i, hash - 2) .. "#")
        i = hash + 1
    end
    return table.concat(parts)
end

--- Whether a line ends in a backslash that escapes its newline.
--- @param line string
--- @return boolean
local function continues(line)
    return #line:match("\\*$") % 2 == 1
end

--- Reads one logical line other than a recipe line into `mk`.
--- @param mk agentic.Makefile
--- @param line string without comment
--- @param makefile string the makefile's own name
--- @return boolean ok false when the line declines
--- @return agentic.MakeRule|nil rule the rule the line starts
local function read_line(mk, line, makefile)
    if DIRECTIVES[line:match("^%s*(%S+)")] then
        return false
    end
    local lookup = scope_lookup(mk.vars)
    local name, op, value = split_assignment(line)
    if name then
        local var = settable(name)
            and assigned(mk.vars[name], op, value, lookup)
        if not var then
            return false
        end
        mk.vars[name] = var
        return true
    end
    local colon = find_outside_refs(line, ":")
    if not colon or line:sub(colon + 1, colon + 1) == ":" then
        return false
    end
    local targets = file_words(expand(line:sub(1, colon - 1), lookup))
    if not targets or #targets == 0 then
        return false
    end
    for _, target in ipairs(targets) do
        local special = target:sub(1, 1) == "."
            and not (target == ".PHONY" and #targets == 1)
        if special or target == makefile then
            return false
        end
        mk.mentioned[target] = true
    end
    local rest = line:sub(colon + 1)
    name, op, value = split_assignment(rest)
    if name then
        --- @type agentic.MakeTargetVar
        local entry = op == "+=" and { name = name, append = value }
            or { name = name, var = assigned(nil, op, value, lookup) }
        if not settable(name) or not (entry.append or entry.var) then
            return false
        end
        for _, target in ipairs(targets) do
            mk.target_vars[target] = mk.target_vars[target] or {}
            table.insert(mk.target_vars[target], entry)
        end
        return true
    end
    if find_outside_refs(rest, ":;|") then
        return false
    end
    local prerequisites = file_words(expand(rest, lookup))
    if not prerequisites then
        return false
    end
    for _, prerequisite in ipairs(prerequisites) do
        if prerequisite:find("^%-l") then
            return false
        end
        mk.mentioned[prerequisite] = true
    end
    --- @type agentic.MakeRule
    local rule = { targets = targets, prerequisites = prerequisites }
    table.insert(mk.rules, rule)
    return true, rule
end

--- Parses makefile text.
--- @param text string
--- @param makefile string the makefile's own name
--- @return agentic.Makefile|nil mk nil when a line declines
local function parse(text, makefile)
    --- @type agentic.Makefile
    local mk = { vars = {}, rules = {}, target_vars = {}, mentioned = {} }
    local lines = vim.split(text, "\n", { plain = true })
    local rule
    local i = 1
    while i <= #lines do
        local line = lines[i]
        local recipe = line:sub(1, 1) == "\t"
        if recipe and not rule then
            return nil
        end
        if recipe then
            line = line:sub(2)
        end
        while continues(line) do
            i = i + 1
            if not lines[i] then
                return nil
            end
            line = recipe and line .. "\n" .. lines[i]:gsub("^\t", "")
                or line:sub(1, -2):gsub("%s+$", "")
                    .. " "
                    .. lines[i]:gsub("^%s+", "")
        end
        if recipe then
            rule.recipe = rule.recipe or {}
            table.insert(rule.recipe, line)
        else
            line = strip_comment(line)
            if line:find("%S") then
                local ok
                ok, rule = read_line(mk, line, makefile)
                if not ok then
                    return nil
                end
            end
        end
        i = i + 1
    end
    return mk
end

--- Merges the rules of each target.
--- @param rules agentic.MakeRule[]
--- @return table<string, agentic.MakeTarget>|nil targets nil when two rules
---         give one target a recipe
local function merge_rules(rules)
    local merged = {}
    for _, rule in ipairs(rules) do
        for _, target in ipairs(rule.targets) do
            local entry = merged[target] or { first = {}, rest = {} }
            merged[target] = entry
            if rule.recipe and entry.recipe then
                return nil
            end
            if rule.recipe then
                entry.recipe, entry.first = rule.recipe, rule.prerequisites
            else
                vim.list_extend(entry.rest, rule.prerequisites)
            end
        end
    end
    --- @type table<string, agentic.MakeTarget>
    local targets = {}
    for name, entry in pairs(merged) do
        local all = vim.list_extend(vim.list_slice(entry.first), entry.rest)
        local seen, prerequisites = {}, {}
        for _, prerequisite in ipairs(all) do
            if not seen[prerequisite] then
                seen[prerequisite] = true
                table.insert(prerequisites, prerequisite)
            end
        end
        targets[name] = { prerequisites = prerequisites, recipe = entry.recipe }
    end
    return targets
end

--- The stem `%` matches when `pattern` matches `name`.
--- @param pattern string
--- @param name string
--- @return string|nil stem nil when the pattern does not match or the stem
---         would be empty
local function pattern_stem(pattern, name)
    local prefix, suffix = pattern:match("^(.-)%%(.*)$")
    if
        not prefix
        or #name <= #prefix + #suffix
        or name:sub(1, #prefix) ~= prefix
        or name:sub(#name - #suffix + 1) ~= suffix
    then
        return nil
    end
    return name:sub(#prefix + 1, #name - #suffix)
end

--- Whether a pattern rule, or a chain of them, can build `path`, by make's
--- implicit rule search: a pattern without `/` matches the file name part,
--- a rule applies when each prerequisite is known or can itself be built
--- (not for a terminal rule), a rule is used once per chain, and a
--- non-terminal match-anything rule never builds an intermediate file.
--- @param path string
--- @param patterns agentic.MakePatternRule[]
--- @param known fun(path: string): boolean whether a file exists or the
---        makefile mentions it
--- @param in_use table<integer, true>|nil rules used in the chain so far
--- @param depth integer|nil chain depth of `path`
--- @return boolean
local function buildable(path, patterns, known, in_use, depth)
    in_use, depth = in_use or {}, depth or 0
    local dir, base = path:match("^(.-)([^/]*)$")
    for i, rule in ipairs(patterns) do
        local intermediate_anything = depth > 0
            and rule.target == "%"
            and not rule.terminal
        local slashed = rule.target:find("/", 1, true) ~= nil
        local stem = not in_use[i]
            and not intermediate_anything
            and pattern_stem(rule.target, slashed and path or base)
        if stem then
            in_use[i] = true
            local applies = true
            for _, pattern in ipairs(rule.prerequisites) do
                local prerequisite = (slashed and "" or dir)
                    .. pattern:gsub("%%", function()
                        return stem
                    end)
                applies = known(prerequisite)
                    or not rule.terminal
                        and buildable(
                            prerequisite,
                            patterns,
                            known,
                            in_use,
                            depth + 1
                        )
                if not applies then
                    break
                end
            end
            in_use[i] = nil
            if applies then
                return true
            end
        end
    end
    return false
end

--- The default goal: `.DEFAULT_GOAL` if assigned, else the first rule target
--- that does not start with `.`.
--- @param mk agentic.Makefile
--- @return string|nil goal nil when there is none or `.DEFAULT_GOAL` is not
---         one word
local function default_goal(mk)
    if mk.vars[".DEFAULT_GOAL"] then
        local words = file_words(scope_lookup(mk.vars)(".DEFAULT_GOAL"))
        return words and #words == 1 and words[1] or nil
    end
    for _, rule in ipairs(mk.rules) do
        for _, target in ipairs(rule.targets) do
            if target:sub(1, 1) ~= "." then
                return target
            end
        end
    end
    return nil
end

--- The shell commands `make` runs for `targets` when every prerequisite is
--- out of date: one per recipe line in execution order, with variables
--- expanded and `@`/`-` prefixes stripped. A recipe line continued with a
--- backslash stays one command, its backslash-newlines kept.
--- @param text string makefile contents
--- @param targets string[] operand targets, empty for the default goal
--- @param builtin_patterns agentic.MakePatternRule[] make's built-in
---        implicit rules
--- @param exists fun(path: string): boolean whether a file exists, relative
---        to the makefile's directory
--- @param makefile string the makefile's name, relative to its directory
--- @return string[]|nil commands nil when the commands cannot be known
---         exactly from the text
function M.commands(text, targets, builtin_patterns, exists, makefile)
    makefile = strip_dot_slash(makefile)
    local mk = parse(text, makefile)
    local rules = mk and merge_rules(mk.rules)
    if not mk or not rules then
        return nil
    end
    local function known(path)
        return mk.mentioned[path] ~= nil or exists(path)
    end
    local phony_rule = rules[".PHONY"] or { prerequisites = {} }
    if phony_rule.recipe or buildable(makefile, builtin_patterns, known) then
        return nil
    end
    local phony = {}
    for _, target in ipairs(phony_rule.prerequisites) do
        phony[target] = true
    end

    local commands, done, active = {}, {}, {}
    --- Appends the commands of `target` and its prerequisites.
    --- @param target string
    --- @param scopes agentic.MakeTargetVar[][] target-specific variables in
    ---        effect, outermost first
    --- @return boolean ok
    local function build(target, scopes)
        if done[target] then
            return true
        end
        local rule = rules[target]
        local recipe = rule and rule.recipe
        local unbuildable = not phony[target]
            and not recipe
            and (
                buildable(target, builtin_patterns, known)
                or not (rule or exists(target))
            )
        if active[target] or unbuildable then
            return false
        end
        active[target] = true
        local inner = { unpack(scopes) }
        if mk.target_vars[target] then
            table.insert(inner, mk.target_vars[target])
        end
        local prerequisites = rule and rule.prerequisites or {}
        for _, prerequisite in ipairs(prerequisites) do
            if not build(prerequisite, inner) then
                return false
            end
        end
        local vars = scoped_vars(mk.vars, inner)
        if not vars then
            return false
        end
        local lookup = scope_lookup(vars, {
            ["@"] = target,
            ["<"] = prerequisites[1] or "",
            ["^"] = table.concat(prerequisites, " "),
        })
        if recipe and not all_expand(mk.vars, inner, lookup) then
            return false
        end
        for _, line in ipairs(recipe or {}) do
            local command = expand(line, lookup)
            if not command then
                return false
            end
            local prefix = command:match("^[%s@+%-]*")
            if prefix:find("+", 1, true) then
                return false
            end
            if #command > #prefix then
                table.insert(commands, command:sub(#prefix + 1))
            end
        end
        active[target], done[target] = nil, true
        return true
    end

    local goals = { default_goal(mk) }
    if #targets > 0 then
        goals = file_words(table.concat(targets, " ")) or {}
    end
    if #goals ~= math.max(#targets, 1) then
        return nil
    end
    for _, goal in ipairs(goals) do
        if not build(goal, {}) then
            return nil
        end
    end
    return commands
end

--- The suffix rules a `.from.to` or `.from` target name reads as, given the
--- known suffixes.
--- @param name string
--- @param suffixes table<string, true>
--- @return agentic.MakePatternRule[] rules every split of `name` into known
---         suffixes, as pattern rules
local function suffix_rules(name, suffixes)
    local rules = {}
    if suffixes[name] then
        table.insert(
            rules,
            { target = "%", prerequisites = { "%" .. name }, terminal = false }
        )
    end
    for k = 2, #name do
        local from, to = name:sub(1, k - 1), name:sub(k)
        if suffixes[from] and suffixes[to] then
            table.insert(rules, {
                target = "%" .. to,
                prerequisites = { "%" .. from },
                terminal = false,
            })
        end
    end
    return rules
end

--- Make's built-in implicit rules that have a recipe, read from the output
--- of `make -p -f /dev/null`: its pattern rules, and its suffix rules
--- (`.c.o:` read as `%.o: %.c`, `.c:` as `%: %.c`) over the `.SUFFIXES`
--- list.
--- @param dump string
--- @return agentic.MakePatternRule[] rules in dump order, without repeats
function M.builtin_patterns(dump)
    local suffixes = {}
    for suffix in (dump:match("\n%.SUFFIXES:([^\n]*)") or ""):gmatch("%S+") do
        suffixes[suffix] = true
    end
    local rules, seen = {}, {}
    --- @param rule agentic.MakePatternRule
    local function add(rule)
        local key = rule.target .. ":" .. table.concat(rule.prerequisites, " ")
        if not seen[key] then
            seen[key] = true
            table.insert(rules, rule)
        end
    end
    local header
    for line in (dump .. "\n"):gmatch("([^\n]*)\n") do
        if line:sub(1, 1) == "\t" and header then
            for name in header.targets:gmatch("%S+") do
                if name:find("%", 1, true) then
                    add({
                        target = name,
                        prerequisites = vim.split(
                            vim.trim(header.rest),
                            "%s+",
                            { trimempty = true }
                        ),
                        terminal = header.colons == "::",
                    })
                elseif vim.trim(header.rest) == "" then
                    for _, rule in ipairs(suffix_rules(name, suffixes)) do
                        add(rule)
                    end
                end
            end
            header = nil
        elseif line == "" or not line:find("^[#\t]") then
            local targets, colons, rest =
                line:match("^([^#%s=:][^=:]*)(::?)([^=]*)$")
            header = targets
                and { targets = targets, colons = colons, rest = rest }
        end
    end
    return rules
end

return M
