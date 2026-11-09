--- The shell commands a `just` invocation runs, read from the justfile's
--- `just --dump --dump-format json`, decoded with `M.DECODE_OPTS`.
--- Pure over the decoded table. Declines whenever the commands cannot be
--- known exactly from the dump.
--- @class agentic.utils.JustRecipe
local M = {}

--- `vim.json.decode` options for the dump: a null field is absent.
M.DECODE_OPTS = { luanil = { object = true, array = true } }

--- @param keys string[]
--- @return table<string, true>
local function set(keys)
    local s = {}
    for _, key in ipairs(keys) do
        s[key] = true
    end
    return s
end

--- Fields each kind of dump object may have. An unknown field declines.
local KNOWN_KEYS = {
    dump = set({
        "assignments",
        "first",
        "doc",
        "groups",
        "module_path",
        "modules",
        "aliases",
        "recipes",
        "settings",
        "source",
        "unexports",
        "warnings",
    }),
    assignment = set({ "eager", "export", "name", "private", "value" }),
    alias = set({ "attributes", "name", "target" }),
    recipe = set({
        "attributes",
        "body",
        "dependencies",
        "doc",
        "name",
        "parameters",
        "priors",
        "private",
        "quiet",
        "namepath",
        "shebang",
    }),
    dependency = set({ "arguments", "recipe", "star" }),
}

--- The settings of a justfile that sets none. Null-valued defaults are
--- absent once decoded with `luanil`.
local DEFAULT_SETTINGS = {
    allow_duplicate_recipes = false,
    allow_duplicate_variables = false,
    default_list = false,
    default_script = false,
    dotenv_command = {},
    dotenv_load = false,
    dotenv_override = false,
    dotenv_required = false,
    export = false,
    fallback = false,
    guards = false,
    ignore_comments = false,
    lazy = false,
    lists = false,
    no_cd = false,
    no_exit_message = false,
    positional_arguments = false,
    quiet = false,
    unstable = false,
    windows_powershell = false,
}

local FLAG_ATTRIBUTES = set({ "private", "no-exit-message", "default" })
local VALUE_ATTRIBUTES = set({ "doc", "group" })

--- Whether `t` is a table whose keys all lie in `keys`.
--- @param t any
--- @param keys table<string, true>
--- @return boolean known
local function has_known_keys(t, keys)
    if type(t) ~= "table" then
        return false
    end
    for key in pairs(t) do
        if not keys[key] then
            return false
        end
    end
    return true
end

--- Whether an attribute leaves the commands a recipe runs unchanged.
--- @param attribute any a decoded attribute: `"private"` or `{ group = "g" }`
--- @return boolean inert
local function is_inert_attribute(attribute)
    if type(attribute) == "string" then
        return FLAG_ATTRIBUTES[attribute] == true
    end
    if type(attribute) ~= "table" then
        return false
    end
    local name, value = next(attribute)
    return VALUE_ATTRIBUTES[name] == true
        and type(value) == "string"
        and next(attribute, name) == nil
end

--- Evaluates a string literal, a variable naming such an assignment, or a
--- `+` concatenation of those.
--- @param expression any a decoded expression: `"lit"`,
---        `{ "variable", name }` or `{ "concatenate", lhs, rhs }`
--- @param assignments table<string, table> decoded assignments by name
--- @param pending table<string, true> variables under evaluation
--- @return string|nil value nil for any other expression or a cycle
local function evaluate(expression, assignments, pending)
    if type(expression) == "string" then
        return expression
    end
    if type(expression) ~= "table" then
        return nil
    end
    local op = expression[1]
    if op == "variable" and #expression == 2 then
        local name = expression[2]
        local assignment = assignments[name]
        if type(assignment) ~= "table" or pending[name] then
            return nil
        end
        pending[name] = true
        local value = evaluate(assignment.value, assignments, pending)
        pending[name] = nil
        return value
    end
    if op == "concatenate" and #expression == 3 then
        local lhs = evaluate(expression[2], assignments, pending)
        local rhs = evaluate(expression[3], assignments, pending)
        return lhs and rhs and lhs .. rhs
    end
    return nil
end

--- Evaluates one body line as just does: text with `{{{{` unescaped,
--- interpolations evaluated. A continued line loses its leading whitespace.
--- @param line any a decoded line: a list of text strings and
---        `{ expression }` interpolations
--- @param continued boolean whether the previous line ended in `\`
--- @param assignments table<string, table>
--- @return string|nil text nil when an interpolation cannot be evaluated
local function evaluate_line(line, continued, assignments)
    if type(line) ~= "table" then
        return nil
    end
    local parts = {}
    for i, fragment in ipairs(line) do
        local part
        if type(fragment) == "string" then
            part = fragment:gsub("{{{{", "{{")
            if continued and i == 1 then
                part = part:match("^%s*(.*)$")
                -- just also trims Unicode whitespace.
                if part:find("^[\128-\255]") then
                    return nil
                end
            end
        elseif type(fragment) == "table" and #fragment == 1 then
            part = evaluate(fragment[1], assignments, {})
        end
        if not part then
            return nil
        end
        table.insert(parts, part)
    end
    return table.concat(parts)
end

--- Joins body lines into the commands just's linewise runner executes.
--- Lines ending in `\` continue onto the next, the `@`/`-` sigils of a
--- command's first line are stripped, and empty commands are skipped.
--- @param body any a decoded recipe body: a list of lines
--- @param assignments table<string, table>
--- @return string[]|nil commands nil when a line cannot be evaluated
local function body_commands(body, assignments)
    if type(body) ~= "table" then
        return nil
    end
    local commands = {}
    local i = 1
    while i <= #body do
        local first = type(body[i]) == "table" and body[i][1]
        local head = type(first) == "string" and first or ""
        local n_sigils = (head:find("^%-?@") and 1 or 0)
            + (head:find("^@?%-") and 1 or 0)
        local command = ""
        local continued = false
        repeat
            local line = body[i]
            local text = evaluate_line(line, continued, assignments)
            if not text then
                return nil
            end
            local last = line[#line]
            continued = type(last) == "string" and last:sub(-1) == "\\"
            command = command .. (continued and text:sub(1, -2) or text)
            i = i + 1
        until not continued or i > #body
        command = command:sub(n_sigils + 1)
        if command ~= "" then
            table.insert(commands, command)
        end
    end
    return commands
end

--- Whether a recipe's dependencies are plain recipe names.
--- @param dependencies any decoded dependency list
--- @param priors any count of dependencies listed before `&&`
--- @return boolean plain
local function has_plain_dependencies(dependencies, priors)
    if type(dependencies) ~= "table" or type(priors) ~= "number" then
        return false
    end
    if priors < 0 or priors > #dependencies or priors % 1 ~= 0 then
        return false
    end
    for _, dependency in ipairs(dependencies) do
        if
            not has_known_keys(dependency, KNOWN_KEYS.dependency)
            or type(dependency.recipe) ~= "string"
            or dependency.star ~= nil
            or type(dependency.arguments) ~= "table"
            or #dependency.arguments > 0
        then
            return false
        end
    end
    return true
end

--- Whether a recipe runs its body line by line with no inputs and no
--- attribute that changes what runs.
--- @param recipe any a decoded recipe
--- @return boolean plain
local function is_plain_recipe(recipe)
    if
        not has_known_keys(recipe, KNOWN_KEYS.recipe)
        or recipe.shebang ~= false
        or type(recipe.parameters) ~= "table"
        or #recipe.parameters > 0
        or type(recipe.attributes) ~= "table"
        or not has_plain_dependencies(recipe.dependencies, recipe.priors)
    then
        return false
    end
    for _, attribute in ipairs(recipe.attributes) do
        if not is_inert_attribute(attribute) then
            return false
        end
    end
    return true
end

--- Whether the justfile as a whole runs recipe bodies verbatim: no modules,
--- unexports or non-default settings, and every assignment a non-exported
--- value `evaluate` resolves. just evaluates every assignment, used or not.
--- @param dump table
--- @return boolean plain
local function is_plain_justfile(dump)
    if
        not has_known_keys(dump, KNOWN_KEYS.dump)
        or type(dump.recipes) ~= "table"
        or type(dump.aliases) ~= "table"
        or type(dump.assignments) ~= "table"
        or type(dump.modules) ~= "table"
        or next(dump.modules) ~= nil
        or type(dump.unexports) ~= "table"
        or next(dump.unexports) ~= nil
        or not vim.deep_equal(dump.settings, DEFAULT_SETTINGS)
    then
        return false
    end
    for _, assignment in pairs(dump.assignments) do
        if
            not has_known_keys(assignment, KNOWN_KEYS.assignment)
            or assignment.export ~= false
            or not evaluate(assignment.value, dump.assignments, {})
        then
            return false
        end
    end
    return true
end

--- The recipe a command-line name runs: a recipe, or an alias's target.
--- @param dump table
--- @param name string
--- @return string|nil recipe_name nil for an unknown name or an alias with
---         an attribute other than `private`
local function resolve_name(dump, name)
    if dump.recipes[name] ~= nil then
        return name
    end
    local alias = dump.aliases[name]
    if
        not has_known_keys(alias, KNOWN_KEYS.alias)
        or type(alias.target) ~= "string"
        or type(alias.attributes) ~= "table"
    then
        return nil
    end
    for _, attribute in ipairs(alias.attributes) do
        if attribute ~= "private" then
            return nil
        end
    end
    return alias.target
end

--- Shell commands `just NAMES…` runs, in execution order: each recipe's
--- dependencies before `&&`, its body, then the dependencies after `&&`.
--- A recipe runs once per invocation, except that the dependencies after
--- `&&` run against their own record of what ran (just 1.59 behaviour).
--- @param dump table the dump decoded with `M.DECODE_OPTS`. One holding
---        `vim.NIL` declines.
--- @param names string[] the recipe operands; empty runs `dump.first`
--- @return string[]|nil commands one per executed body line, interpolations
---         resolved and `@`/`-` sigils stripped. nil (decline) on any
---         assignment, setting, module, unexport, recipe, attribute,
---         dependency or interpolation whose effect is not known exactly,
---         an unknown name, or an unrecognised dump field.
function M.recipe_commands(dump, names)
    if not is_plain_justfile(dump) or (#names == 0 and dump.first == nil) then
        return nil
    end
    local commands = {}
    local active = {}

    --- @param name string
    --- @param ran table<string, true>
    --- @return boolean ok
    local function run(name, ran)
        if ran[name] then
            return true
        end
        local recipe = dump.recipes[name]
        if active[name] or not is_plain_recipe(recipe) then
            return false
        end
        local body = body_commands(recipe.body, dump.assignments)
        if not body then
            return false
        end
        active[name] = true
        local dependencies = recipe.dependencies
        for i = 1, recipe.priors do
            if not run(dependencies[i].recipe, ran) then
                return false
            end
        end
        vim.list_extend(commands, body)
        local subsequent_ran = {}
        for i = recipe.priors + 1, #dependencies do
            if not run(dependencies[i].recipe, subsequent_ran) then
                return false
            end
        end
        active[name] = nil
        ran[name] = true
        return true
    end

    if #names == 0 then
        names = { dump.first }
    end
    local ran = {}
    for _, name in ipairs(names) do
        local recipe_name = type(name) == "string" and resolve_name(dump, name)
        if not recipe_name or not run(recipe_name, ran) then
            return nil
        end
    end
    return commands
end

return M
