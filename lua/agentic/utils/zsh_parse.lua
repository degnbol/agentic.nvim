--- Parse zsh source into a tree that matches what zsh runs, or nil
--- (fail-closed) when the tree may not match: a parse error, syntax the grammar
--- parses differently from zsh, or a word expansion that can run code.

local ZshArithmetic = require("agentic.utils.zsh_arithmetic")
local ZshParseGuard = require("agentic.utils.zsh_parse_guard")

--- @class agentic.utils.ZshParse
local M = {}

local BACKSLASH = ("\\"):byte()
local BACKTICK = ("`"):byte()

--- 0-based `[start, end)` byte ranges of every node in the tree that satisfies
--- `pred`, in document order.
--- @param root TSNode
--- @param pred fun(node: TSNode): boolean
--- @return [integer, integer][] ranges
local function node_ranges(root, pred)
    local ranges = {}
    local function visit(node)
        if pred(node) then
            local _, _, start_byte, _, _, end_byte = node:range(true)
            table.insert(ranges, { start_byte, end_byte })
        end
        for child in node:iter_children() do
            visit(child)
        end
    end
    visit(root)
    return ranges
end

--- Membership test for the union of `ranges`, answered in amortised O(1) by a
--- cursor that only moves forward.
--- @param ranges [integer, integer][] 0-based `[start, end)` byte ranges, sorted
--- by start
--- @return fun(i: integer): boolean covers true iff 0-based offset `i` lies in
--- the union; successive calls must pass non-decreasing `i`
local function ascending_cover(ranges)
    local merged = {}
    for _, r in ipairs(ranges) do
        local last = merged[#merged]
        if last and r[1] <= last[2] then
            last[2] = math.max(last[2], r[2])
        else
            table.insert(merged, { r[1], r[2] })
        end
    end
    local k = 1
    return function(i)
        while merged[k] and merged[k][2] <= i do
            k = k + 1
        end
        return merged[k] ~= nil and i >= merged[k][1]
    end
end

--- True iff the byte at 0-based offset `i` is escaped: preceded by an odd run
--- of backslashes.
--- @param src string
--- @param i integer
--- @return boolean
local function is_escaped(src, i)
    local n_backslashes = 0
    while i - n_backslashes > 0 and src:byte(i - n_backslashes) == BACKSLASH do
        n_backslashes = n_backslashes + 1
    end
    return n_backslashes % 2 == 1
end

--- True iff a `heredoc_body` node's delimiter is quoted (`<<'EOF'`, `<<"EOF"`,
--- `<<\EOF`). zsh treats any quoting of the delimiter as making the body
--- literal.
--- @param body TSNode heredoc_body node
--- @param src string
--- @return boolean
local function heredoc_is_literal(body, src)
    for child in assert(body:parent()):iter_children() do
        if child:type() == "heredoc_start" then
            return vim.treesitter.get_node_text(child, src):find("['\"\\]")
                ~= nil
        end
    end
    return false
end

--- Byte ranges where zsh neither runs a backtick substitution nor joins a
--- backslash-newline: single-quoted and `$'…'` strings, comments, and
--- quoted-delimiter heredoc bodies.
--- @param root TSNode
--- @param src string
--- @return [integer, integer][] ranges 0-based `[start, end)` byte ranges
local function literal_ranges(root, src)
    return node_ranges(root, function(node)
        local t = node:type()
        return t == "raw_string"
            or t == "ansi_c_string"
            or t == "comment"
            or (t == "heredoc_body" and heredoc_is_literal(node, src))
    end)
end

--- True iff a backtick in `src` is neither a `command_substitution` delimiter
--- nor literal text, i.e. a substitution zsh runs that has no node in the tree.
--- Any other backtick inside a backtick body counts, even in quotes or a
--- comment: zsh ends the body at the first unescaped one, and the grammar emits
--- no node for an escaped (nested) one.
--- @param root TSNode
--- @param src string
--- @param literal [integer, integer][] 0-based `[start, end)` byte ranges where
--- a backtick is literal text, sorted by start
--- @return boolean
local function hides_backtick_substitution(root, src, literal)
    if not src:find("`", 1, true) then
        return false
    end
    local substitutions = node_ranges(root, function(node)
        return node:type() == "command_substitution"
    end)
    local delimiters = {}
    local bodies = {}
    for _, r in ipairs(substitutions) do
        if src:byte(r[1] + 1) == BACKTICK then
            delimiters[r[1]] = true
            delimiters[r[2] - 1] = true
            table.insert(bodies, { r[1] + 1, r[2] - 1 })
        end
    end
    local in_body = ascending_cover(bodies)
    local in_literal = ascending_cover(literal)
    local i = src:find("`", 1, true)
    while i do
        local offset = i - 1
        if in_body(offset) then
            return true
        end
        if
            not delimiters[offset]
            and not in_literal(offset)
            and not is_escaped(src, offset)
        then
            return true
        end
        i = src:find("`", i + 1, true)
    end
    return false
end

--- True iff an unescaped, unquoted backslash-newline directly follows a word
--- byte (anything but a blank or `|`, `&`, `;`). zsh removes the pair before
--- splitting words, so `a\<newline>b` is the word `ab` and `a\<newline>  b`
--- continues the command. The grammar ends the command at the newline in both.
--- @param root TSNode
--- @param src string
--- @param literal [integer, integer][] 0-based `[start, end)` byte ranges where
--- a backslash-newline is literal text, sorted by start
--- @return boolean
local function continues_inside_word(root, src, literal)
    if not src:find("\\\n", 1, true) then
        return false
    end
    local in_literal = ascending_cover(literal)
    local in_quoted = ascending_cover(node_ranges(root, function(node)
        local t = node:type()
        return t == "string_content" or t == "heredoc_body"
    end))
    local i = src:find("\\\n", 1, true)
    while i do
        local offset = i - 1
        if
            offset > 0
            and not src:sub(i - 1, i - 1):match("[%s|&;]")
            and not is_escaped(src, offset)
            and not in_literal(offset)
            and not in_quoted(offset)
        then
            return true
        end
        i = src:find("\\\n", i + 1, true)
    end
    return false
end

--- True iff the text of `node` matches any of the Lua `patterns`.
--- @param node TSNode
--- @param src string
--- @param patterns string[]
--- @return boolean
local function text_finds(node, src, patterns)
    local text = vim.treesitter.get_node_text(node, src)
    for _, pattern in ipairs(patterns) do
        if text:find(pattern) then
            return true
        end
    end
    return false
end

--- True iff a subscript of `node` (the text between its anonymous `[` and `]`
--- children) reads a value. Subscripts are arithmetic.
--- @param node TSNode
--- @param src string
--- @return boolean
local function subscript_reads_value(node, src)
    local open
    for child in node:iter_children() do
        if child:type() == "[" and not child:named() then
            local _, _, start_byte = child:start()
            open = start_byte + child:byte_length()
        elseif child:type() == "]" and not child:named() and open then
            local _, _, close = child:start()
            if ZshArithmetic.reads_value(src:sub(open + 1, close)) then
                return true
            end
            open = nil
        end
    end
    return false
end

--- `[[ … ]]` operators whose operands zsh evaluates as arithmetic.
local ARITHMETIC_TEST_OPERATORS = {
    ["-eq"] = true,
    ["-ne"] = true,
    ["-lt"] = true,
    ["-le"] = true,
    ["-gt"] = true,
    ["-ge"] = true,
}

--- True iff `node` is a `[[ … ]]` arithmetic comparison with an operand that
--- reads a value. `[ … ]` and `test` compare without arithmetic.
--- @param node TSNode
--- @param src string
--- @return boolean
local function comparison_reads_value(node, src)
    local test = node:parent()
    while test and test:type() ~= "test_command" do
        test = test:parent()
    end
    if not (test and test:child(0):type() == "[[") then
        return false
    end
    local arithmetic, reads = false, false
    for child in node:iter_children() do
        local text = vim.treesitter.get_node_text(child, src)
        if child:type() == "test_operator" then
            arithmetic = ARITHMETIC_TEST_OPERATORS[text] == true
        elseif child:named() and ZshArithmetic.reads_value(text) then
            reads = true
        end
    end
    return arithmetic and reads
end

--- Per node type, the test for syntax that makes zsh run code, or assign a
--- parameter, while it expands a word (zshexpn(1) § Parameter Expansion,
--- § Parameter Expansion Flags, § Glob Qualifiers). Flag and
--- qualifier patterns match the whole text, arguments included, so a delimiter
--- character can only add a false positive, never hide a flag.
--- @type table<string, fun(node: TSNode, src: string): boolean>
local SIDE_EFFECT_SYNTAX = {
    -- `e` re-expands the value, `P` reads it as a parameter name (whose
    -- subscript runs substitutions), `#`/`l`/`r`/`I` evaluate arithmetic, and
    -- `%` prompt-expands, which runs substitutions under PROMPT_SUBST.
    expansion_flags = function(node, src)
        return text_finds(node, src, { "[ePlrI#%%]" })
    end,
    -- `+cmd`, `e…` and `oe…` run code, `[…]` evaluates arithmetic, and zsh
    -- substitutes a `$` or backtick in an argument (`P:…:`, `:s/…/…/`).
    zsh_glob_qualifier = function(node, src)
        return text_finds(node, src, { "[e%[%$`]", "%+[%a_]" })
    end,
    -- `~` (GLOB_SUBST) applies glob qualifiers in the value, code-running ones
    -- included.
    expansion_style = function(node, src)
        return text_finds(node, src, { "~" })
    end,
    arithmetic_expansion = function(node, src)
        return ZshArithmetic.reads_value(
            vim.treesitter.get_node_text(node, src):sub(2)
        )
    end,
    expansion_substring = function(node, src)
        for _, field in ipairs({ "offset", "length" }) do
            local part = node:field(field)[1]
            if
                part
                and ZshArithmetic.reads_value(
                    vim.treesitter.get_node_text(part, src)
                )
            then
                return true
            end
        end
        return false
    end,
    -- An element's `[key]=` index; the grammar parses it as a glob.
    array = function(node, src)
        for child in node:iter_children() do
            local key =
                vim.treesitter.get_node_text(child, src):match("^%[(.-)%]=")
            if key and ZshArithmetic.reads_value(key) then
                return true
            end
        end
        return false
    end,
    binary_expression = comparison_reads_value,
    -- `=`, `:=` and `::=` assign the parameter, and the name may be one that
    -- changes execution (`${path::=…}`).
    expansion_default = function(node)
        for child in node:iter_children() do
            local t = child:type()
            if t == "=" or t == ":=" or t == "::=" then
                return true
            end
        end
        return false
    end,
}

--- True iff expanding a word in the tree has a side effect (zsh runs code or
--- assigns a parameter): a node that fails its `SIDE_EFFECT_SYNTAX` test, or a
--- subscript that reads a value.
--- @param root TSNode
--- @param src string
--- @return boolean
local function expansion_has_side_effect(root, src)
    local matches = node_ranges(root, function(node)
        local t = node:type()
        local test = SIDE_EFFECT_SYNTAX[t]
        if test and test(node, src) then
            return true
        end
        return (
            t == "subscript"
            or t == "variable_ref"
            or t:find("^expansion") ~= nil
        ) and subscript_reads_value(node, src)
    end)
    return #matches > 0
end

--- Parse a command string with the zsh grammar. Returns the root node, or nil
--- (fail-closed) on missing parser, parse error, any error node, syntax the
--- grammar parses differently from zsh (a hidden backtick substitution, a line
--- continuation inside a word), or a word expansion or arithmetic that can run
--- code.
---
--- Bails before parsing on the tree-sitter-zsh hang trigger (see
--- `zsh_parse_guard`): `parse()` would never return and no in-process mechanism
--- can interrupt it, so nil is the only safe outcome. For untrusted source,
--- `parse_untrusted` adds an out-of-process guard.
--- @param src string
--- @return TSNode|nil
function M.parse(src)
    if ZshParseGuard.contains_hang_trigger(src) then
        return nil
    end
    local ok, root = pcall(function()
        local parser = vim.treesitter.get_string_parser(src, "zsh")
        return parser:parse(false)[1]:root()
    end)
    if not ok or not root or root:has_error() then
        return nil
    end
    if src:find("[`\\]") then
        local literal = literal_ranges(root, src)
        if
            hides_backtick_substitution(root, src, literal)
            or continues_inside_word(root, src, literal)
        then
            return nil
        end
    end
    if expansion_has_side_effect(root, src) then
        return nil
    end
    return root
end

--- Byte cap on shell source to parse.
M.MAX_SOURCE_BYTES = 65536

--- Parse a whole command string. Nil when `command` is not a string, is
--- empty, is over `MAX_SOURCE_BYTES`, or does not parse (see `parse`).
--- @param command any
--- @return TSNode|nil root
function M.parse_command(command)
    if
        type(command) ~= "string"
        or command == ""
        or #command > M.MAX_SOURCE_BYTES
    then
        return nil
    end
    return M.parse(command)
end

--- Absolute path to the headless parse-termination oracle script (sibling file).
local ORACLE_SCRIPT = vim.fn.fnamemodify(
    debug.getinfo(1, "S").source:sub(2),
    ":h"
) .. "/zsh_parse_oracle.lua"

--- Upper bound on a legitimate parse of a 64 KB body. A terminating parse is
--- ~100 ms; this only bounds how long the editor blocks before SIGKILLing a
--- genuinely-hung grammar.
local ORACLE_TIMEOUT_MS = 5000

--- Whether the zsh grammar terminates when parsing `body`, proven by parsing it
--- in a killable subprocess. Returns false on timeout (the hang), spawn/parse
--- failure, or a missing parser.
---
--- Re-entrancy: `SystemObj:wait` polls with `vim.wait(…, fast_only=true)`, which
--- DOES run libuv callbacks — the ACP transport's `uv` `read_start` fires and
--- parses provider bytes during this wait — but does NOT dispatch neovim's
--- deferred queue (`vim.schedule`, autocmds). Every state-mutating ACP handler
--- (`session/update`, `session/request_permission`) is `vim.schedule`-deferred
--- (see `acp_client`), so it runs only after this returns, never re-entering the
--- in-flight permission walk. The synchronous read-callback work is inert here
--- (byte accumulation + JSON decode + enqueue).
--- @param body string
--- @return boolean
local function oracle_terminates(body)
    local parser_so = vim.api.nvim_get_runtime_file("parser/zsh.so", false)[1]
    if not parser_so then
        return false
    end
    local done = vim.system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-l",
        ORACLE_SCRIPT,
        parser_so,
    }, { stdin = body }):wait(ORACLE_TIMEOUT_MS)
    return done.code == 0 and done.signal == 0
end

--- `parse` for untrusted source, which first proves in a killable subprocess
--- that the grammar terminates on `body`. This catches non-terminating grammar
--- bugs other than the known hang trigger, since a C parse loop cannot be
--- interrupted in-process. Nil also on timeout, spawn failure or a missing
--- parser.
--- @param body string
--- @return TSNode|nil
function M.parse_untrusted(body)
    if ZshParseGuard.contains_hang_trigger(body) then
        return nil
    end
    if not oracle_terminates(body) then
        return nil
    end
    return M.parse(body)
end

return M
