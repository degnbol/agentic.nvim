--- Translation of grep-family search patterns to very-nomagic Vim patterns
--- (`:help /\V`) that match the same text. Each dialect has a supported
--- subset. A pattern outside it, or one that the tools of a dialect read
--- differently, has no translation.
--- @class agentic.utils.GrepRegex
local M = {}

--- `perl_bytes` is Perl syntax matched byte by byte, as ag and ack do.
--- @alias agentic.utils.GrepDialect "fixed"|"basic"|"extended"|"perl"|"perl_bytes"|"rust"

--- One lexed construct and its `\V` spelling.
--- @class agentic.utils.GrepRegex.Token
--- @field kind "atom"|"anchor"|"open"|"close"|"alt"|"quant"
--- @field vim string
--- @field ascii? true matches as the tools do only on ASCII text

--- A Vim pattern and the conditions under which its matches are the tool's.
--- @class agentic.utils.GrepRegex.Translation
--- @field vim_pattern string to follow `\V`
--- @field first_only boolean only a line's first match is sure to be the
---   tool's. The tool may take a longer match at that start, and so go on
---   from a different place.
--- @field ascii_only boolean no match is sure on a text that holds non-ASCII.
---   A narrower class makes Vim skip text the tool matched, and so go on from
---   a different place.

-- Vim's `\w` is ASCII, while the tools count non-ASCII letters as word
-- characters. A boundary must too, or it matches inside `éfoo`.
local WORD_CHAR = [=[\%(\w\|\[^\x01-\x7f]\)]=]
local WORD_START = [[\%(]] .. WORD_CHAR .. [[\@<!\w\@=\)]]
local WORD_END = [[\%(\w\@<=]] .. WORD_CHAR .. [[\@!\)]]
local WORD_BOUNDARY = [[\%(]]
    .. WORD_CHAR
    .. [[\@<!\w\@=\|\w\@<=]]
    .. WORD_CHAR
    .. [[\@!\)]]

-- The tools' `\s` holds `\v`, `\f` and `\r`; Vim's is space and tab only.
local SPACE_MEMBERS = [[\t\x0b\x0c\r ]]

--- @type table<string, agentic.utils.GrepRegex.Token>
local COMMON_ESCAPES = {
    w = { kind = "atom", vim = [[\w]], ascii = true },
    W = { kind = "atom", vim = [[\W]], ascii = true },
    s = { kind = "atom", vim = [[\[]] .. SPACE_MEMBERS .. "]", ascii = true },
    S = { kind = "atom", vim = [[\[^]] .. SPACE_MEMBERS .. "]", ascii = true },
    b = { kind = "anchor", vim = WORD_BOUNDARY },
}
local WORD_ANCHOR_ESCAPES = {
    ["<"] = { kind = "anchor", vim = WORD_START },
    [">"] = { kind = "anchor", vim = WORD_END },
}
local PERL_ESCAPES = {
    d = { kind = "atom", vim = [[\d]], ascii = true },
    D = { kind = "atom", vim = [[\D]], ascii = true },
    t = { kind = "atom", vim = "\t" },
}

--- The constructs one dialect supports.
--- @class agentic.utils.GrepRegex.Syntax
--- @field bare_ops boolean `( ) | + ? {` are operators as written. Else they
---   are literal, and `\(` and so on are the operators.
--- @field escapes table<string, agentic.utils.GrepRegex.Token> by the char after `\`
--- @field literal_escapes string Lua pattern for a char that `\` makes literal
--- @field perl_style boolean the dialect has lazy quantifiers, `(?:` groups,
---   escapes in brackets, empty alternatives, and `^`/`$` anywhere

local PERL_SYNTAX = {
    bare_ops = true,
    escapes = vim.tbl_extend("error", COMMON_ESCAPES, PERL_ESCAPES),
    literal_escapes = "^%p$",
    perl_style = true,
}

--- @type table<agentic.utils.GrepDialect, agentic.utils.GrepRegex.Syntax>
local SYNTAX = {
    basic = {
        bare_ops = false,
        escapes = vim.tbl_extend("error", COMMON_ESCAPES, WORD_ANCHOR_ESCAPES),
        literal_escapes = "^[.*[%]^$\\/]$",
        perl_style = false,
    },
    extended = {
        bare_ops = true,
        escapes = vim.tbl_extend("error", COMMON_ESCAPES, WORD_ANCHOR_ESCAPES),
        literal_escapes = "^[.*[%]^$\\/{}()|+?]$",
        perl_style = false,
    },
    perl = PERL_SYNTAX,
    perl_bytes = PERL_SYNTAX,
    rust = {
        bare_ops = true,
        escapes = vim.tbl_extend(
            "error",
            COMMON_ESCAPES,
            WORD_ANCHOR_ESCAPES,
            PERL_ESCAPES
        ),
        literal_escapes = "^%p$",
        perl_style = true,
    },
}

local OPERATORS = {
    ["("] = true,
    [")"] = true,
    ["|"] = true,
    ["+"] = true,
    ["?"] = true,
    ["{"] = true,
}

-- Members of the ASCII part of each POSIX class. Vim's own classes follow
-- 8-bit tables and `'isprint'`, so they are spelled out. `[:upper:]` and
-- `[:lower:]` are left out: under `-i` the tools match both cases with them.
local POSIX_CLASS_MEMBERS = {
    alpha = "a-zA-Z",
    digit = "0-9",
    alnum = "a-zA-Z0-9",
    space = SPACE_MEMBERS,
    blank = [[ \t]],
    cntrl = [[\x01-\x1f\x7f]],
    graph = [[\x21-\x7e]],
    print = [[\x20-\x7e]],
    xdigit = "0-9A-Fa-f",
    punct = [[\x21-\x2f\x3a-\x40\x5b-\x60\x7b-\x7e]],
}
local PERL_BRACKET_CLASS_MEMBERS =
    { d = "0-9", s = SPACE_MEMBERS, w = "a-zA-Z0-9_" }

local UTF8_CHAR = "^[%z\1-\127\194-\244][\128-\191]*"

--- Escape a literal char for `\V`, where only `\` is special.
--- @param char string
--- @return string
local function literal(char)
    return char == "\\" and "\\\\" or char
end

--- Escape a literal member of a `\V` bracket set (`:help /[]`).
--- @param char string
--- @return string
local function bracket_literal(char)
    return char:match("^[\\%]^-]$") and "\\" .. char or char
end

--- Read one literal char of a bracket set.
--- @param part string
--- @param i integer 1-based index of the char
--- @param perl_style boolean `\` escapes ASCII punctuation
--- @return string|nil char nil = not a literal char
--- @return integer|nil next index after it
local function bracket_char(part, i, perl_style)
    local c = part:sub(i, i)
    if c == "\\" then
        local escaped = part:sub(i + 1, i + 1)
        if perl_style and escaped:match("^%p$") then
            return escaped, i + 2
        end
        return nil, nil
    end
    local char = part:match(UTF8_CHAR, i)
    if not char or c == "[" then
        return nil, nil
    end
    return char, i + #char
end

--- Lex a bracket set `[…]`.
--- @param part string
--- @param i integer 1-based index of the `[`
--- @param dialect agentic.utils.GrepDialect
--- @return agentic.utils.GrepRegex.Token|nil token nil = outside the supported set
--- @return integer|nil next index after the closing `]`
local function lex_bracket(part, i, dialect)
    local perl_style = SYNTAX[dialect].perl_style
    local j = i + 1
    local negated = part:sub(j, j) == "^"
    if negated then
        j = j + 1
    end
    local first = j
    local members = {}
    local has_class = false
    while true do
        local c = part:sub(j, j)
        if c == "" then
            return nil, nil
        elseif c == "]" and j > first then
            break
        elseif
            dialect == "rust"
            and vim.list_contains({ "&&", "--", "~~" }, part:sub(j, j + 1))
        then
            return nil, nil
        end
        local name, after = part:match("^%[:(%a+):%]()", j)
        local escaped_class = perl_style
            and c == "\\"
            and PERL_BRACKET_CLASS_MEMBERS[part:sub(j + 1, j + 1)]
        if name or escaped_class then
            -- ugrep's basic and extended `[:punct:]` leaves out `$+<=>^`|~`.
            if
                name
                and (
                    not POSIX_CLASS_MEMBERS[name]
                    or (name == "punct" and not perl_style)
                )
            then
                return nil, nil
            end
            table.insert(
                members,
                name and POSIX_CLASS_MEMBERS[name] or escaped_class
            )
            has_class = true
            j = name and after or j + 2
        elseif c == "-" and j > first and part:sub(j + 1, j + 1) ~= "]" then
            return nil, nil
        else
            local char, next_j = bracket_char(part, j, perl_style)
            if not char then
                return nil, nil
            end
            --- @cast next_j integer
            j = next_j
            if part:sub(j, j) == "-" and not part:match("^%-%]", j) then
                local last, after_last = bracket_char(part, j + 1, perl_style)
                if
                    not last
                    or #char > 1
                    or #last > 1
                    or last < char
                    or (dialect == "rust" and last == "-")
                then
                    return nil, nil
                end
                --- @cast after_last integer
                table.insert(
                    members,
                    bracket_literal(char) .. "-" .. bracket_literal(last)
                )
                j = after_last
            else
                table.insert(members, bracket_literal(char))
            end
        end
    end
    --- @type agentic.utils.GrepRegex.Token
    local token = {
        kind = "atom",
        vim = "\\[" .. (negated and "^" or "") .. table.concat(members) .. "]",
        ascii = has_class or nil,
    }
    return token, j + 1
end

--- `\V` spelling of a quantifier.
--- @param min integer
--- @param max integer|nil nil = unbounded
--- @param lazy boolean
--- @return string
local function quantifier(min, max, lazy)
    local bound = max == min and "" or "," .. (max or "")
    return "\\{" .. (lazy and "-" or "") .. min .. bound .. "}"
end

--- Lex one pattern of a regex dialect.
--- @param part string one pattern, without newlines
--- @param dialect agentic.utils.GrepDialect not `fixed`
--- @return agentic.utils.GrepRegex.Token[]|nil tokens nil = outside the supported set
local function lex_regex(part, dialect)
    local syntax = SYNTAX[dialect]
    --- @type agentic.utils.GrepRegex.Token[]
    local tokens = {}
    local depth = 0

    --- @param kind "atom"|"anchor"|"open"|"close"|"alt"|"quant"
    --- @param vim_text string
    local function push(kind, vim_text)
        table.insert(tokens, { kind = kind, vim = vim_text })
    end

    --- @return string|nil
    local function prev_kind()
        local prev = tokens[#tokens]
        return prev and prev.kind
    end

    -- ugrep and BSD grep reject an empty alternative or group in basic and
    -- extended, and ugrep echoes the pattern in its error.
    --- @return boolean
    local function ends_empty_alternative()
        local prev = prev_kind()
        return not syntax.perl_style
            and (prev == nil or prev == "open" or prev == "alt")
    end

    --- @param min integer
    --- @param max integer|nil
    --- @param j integer index after the quantifier
    --- @return integer|nil next nil = nothing to quantify
    local function quantify(min, max, j)
        if prev_kind() ~= "atom" and prev_kind() ~= "close" then
            return nil
        end
        local lazy = syntax.perl_style and part:sub(j, j) == "?"
        push("quant", quantifier(min, max, lazy))
        return lazy and j + 1 or j
    end

    --- Whether the operator at `j` ends an alternative.
    --- @param j integer
    --- @return boolean
    local function ends_alternative(j)
        local rest = part:sub(j, syntax.bare_ops and j or j + 1)
        return rest == ""
            or vim.list_contains(
                syntax.bare_ops and { "|", ")" } or { "\\|", "\\)" },
                rest
            )
    end

    local i = 1
    while i <= #part do
        local c = part:sub(i, i)
        --- @type string|nil
        local op
        -- index after the char or operator at `i`
        local op_end = i + 1
        if syntax.bare_ops and OPERATORS[c] then
            op = c
        elseif
            not syntax.bare_ops
            and c == "\\"
            and OPERATORS[part:sub(i + 1, i + 1)]
        then
            op, op_end = part:sub(i + 1, i + 1), i + 2
        end
        --- @type integer|nil index after the construct at `i`, nil = unsupported
        local j = op_end

        if op == "(" then
            if syntax.perl_style and part:sub(op_end, op_end) == "?" then
                j = part:match("^%?:()", op_end)
                    or part:match("^%?P?<[%a_][%w_]*>()", op_end)
            end
            depth = depth + 1
            push("open", [[\%(]])
        elseif op == ")" then
            if depth == 0 or ends_empty_alternative() then
                return nil
            end
            depth = depth - 1
            push("close", [[\)]])
        elseif op == "|" then
            if ends_empty_alternative() then
                return nil
            end
            push("alt", [[\|]])
        elseif op == "+" then
            j = quantify(1, nil, op_end)
        elseif op == "?" then
            j = quantify(0, 1, op_end)
        elseif op == "{" then
            local close = syntax.bare_ops and "}" or "\\}"
            local n, comma, m, after =
                part:match("^(%d+)(,?)(%d*)" .. vim.pesc(close) .. "()", op_end)
            local min = tonumber(n)
            local max = comma == "" and min or tonumber(m)
            if not min or min > 255 or (max and (max < min or max > 255)) then
                return nil
            end
            --- @cast min integer
            j = quantify(min, max, after)
        elseif c == "*" then
            j = quantify(0, nil, op_end)
        elseif c == "." then
            push("atom", [[\.]])
        elseif c == "[" then
            local token
            token, j = lex_bracket(part, i, dialect)
            table.insert(tokens, token)
        elseif c == "^" then
            local prev = prev_kind()
            if
                not syntax.perl_style
                and prev ~= nil
                and prev ~= "alt"
                and prev ~= "open"
            then
                return nil
            end
            push("anchor", [[\_^]])
        elseif c == "$" then
            if not syntax.perl_style and not ends_alternative(op_end) then
                return nil
            end
            push("anchor", [[\_$]])
        elseif c == "\\" then
            local escaped = part:sub(i + 1, i + 1)
            local token = syntax.escapes[escaped]
            j = i + 2
            if token then
                table.insert(tokens, token)
            elseif escaped:match(syntax.literal_escapes) then
                push("atom", literal(escaped))
            else
                return nil
            end
        else
            local char = part:match(UTF8_CHAR, i)
            if not char then
                return nil
            end
            push("atom", literal(char))
            j = i + #char
        end
        if not j then
            return nil
        end
        i = j
    end
    if depth ~= 0 or (#tokens > 0 and ends_empty_alternative()) then
        return nil
    end
    return tokens
end

--- Lex one pattern.
--- @param part string one pattern, without newlines
--- @param dialect agentic.utils.GrepDialect
--- @return agentic.utils.GrepRegex.Token[]|nil tokens nil = outside the supported set
local function lex(part, dialect)
    if dialect ~= "fixed" then
        return lex_regex(part, dialect)
    end
    --- @type agentic.utils.GrepRegex.Token[]
    local tokens = {}
    local i = 1
    while i <= #part do
        local char = part:match(UTF8_CHAR, i)
        if not char then
            return nil
        end
        table.insert(tokens, { kind = "atom", vim = literal(char) })
        i = i + #char
    end
    return tokens
end

--- Whether POSIX leftmost-longest matching can pick a different match than
--- Vim's leftmost-first: the tokens hold an alternation or a quantified group.
--- @param tokens agentic.utils.GrepRegex.Token[]
--- @return boolean
local function order_may_differ(tokens)
    for k, token in ipairs(tokens) do
        if
            token.kind == "alt"
            or (token.kind == "quant" and tokens[k - 1].kind == "close")
        then
            return true
        end
    end
    return false
end

local LEFTMOST_LONGEST = { basic = true, extended = true }

--- `M.translate` for one dialect.
--- @param patterns string[]
--- @param dialect agentic.utils.GrepDialect
--- @param whole "word"|"line"|nil
--- @return agentic.utils.GrepRegex.Translation|nil translation
local function translate_dialect(patterns, dialect, whole)
    local alternatives = {}
    local order_differs = false
    local ascii_only = dialect == "perl_bytes"
    for _, pattern in ipairs(patterns) do
        local tokens = not pattern:find("\n") and lex(pattern, dialect)
        if not tokens then
            return nil
        end
        order_differs = order_differs or order_may_differ(tokens)
        local vim_texts = {}
        for _, token in ipairs(tokens) do
            table.insert(vim_texts, token.vim)
            ascii_only = ascii_only or token.ascii == true
        end
        table.insert(alternatives, [[\%(]] .. table.concat(vim_texts) .. [[\)]])
    end
    local vim_pattern = table.concat(alternatives, [[\|]])
    if whole == "word" then
        vim_pattern = WORD_CHAR
            .. [[\@<!\%(]]
            .. vim_pattern
            .. [[\)]]
            .. WORD_CHAR
            .. [[\@!]]
    elseif whole == "line" then
        vim_pattern = [[\_^\%(]] .. vim_pattern .. [[\)\_$]]
    end
    --- @type agentic.utils.GrepRegex.Translation
    local translation = {
        vim_pattern = vim_pattern,
        -- Only rg's rust engine is known to try several patterns as one
        -- leftmost-first alternation. git grep, for one, takes the longest
        -- of those that match at the same start.
        first_only = (#patterns > 1 and dialect ~= "rust")
            or (LEFTMOST_LONGEST[dialect] and order_differs)
            or false,
        ascii_only = ascii_only,
    }
    return translation
end

--- Translate the patterns of one grep run, any of which may match, to one
--- very-nomagic Vim pattern that matches the same text.
--- @param patterns string[] in command order. A newline gives no translation.
--- @param dialects agentic.utils.GrepDialect[] every dialect the patterns may
---   be read in
--- @param whole "word"|"line"|nil the match must be a whole word or line
--- @return agentic.utils.GrepRegex.Translation|nil translation nil = outside
---   the supported set, or the dialects give different patterns
function M.translate(patterns, dialects, whole)
    --- @type agentic.utils.GrepRegex.Translation|nil
    local translation
    for _, dialect in ipairs(dialects) do
        local candidate = translate_dialect(patterns, dialect, whole)
        if
            not candidate
            or (
                translation
                and candidate.vim_pattern ~= translation.vim_pattern
            )
        then
            return nil
        end
        if translation then
            candidate.first_only = candidate.first_only
                or translation.first_only
            candidate.ascii_only = candidate.ascii_only
                or translation.ascii_only
        end
        translation = candidate
    end
    -- A safety net: no pattern is known that the lexers accept and Vim
    -- rejects.
    if
        not translation
        or not pcall(vim.regex, "\\V" .. translation.vim_pattern)
    then
        return nil
    end
    return translation
end

return M
