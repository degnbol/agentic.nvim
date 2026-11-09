local assert = require("tests.helpers.assert")
local JustRecipe = require("agentic.utils.just_recipe")

--- Decodes a dump as the caller must.
--- @param json string
--- @return table
local function decode(json)
    return vim.json.decode(json, { luanil = { object = true, array = true } })
end

-- `just --dump --dump-format json` (just 1.59.0) of:
--
--     x := "hi"
--     y := x + "/" + 'q'
--
--     [default]
--     a: b && b c
--         echo a {{x}} {{y}}
--
--     b: c
--         echo b
--
--     c:
--         echo c
--
--     d: c && a
--         echo d
--
--     # documented
--     [private]
--     [group('g')]
--     [no-exit-message]
--     lines:
--         -@echo one \
--           two \
--         {{"three"}} four
--         @-echo {{{{lit}} {{ x + "!" }}
--
--         {{""}}
--         # comment
--
--     alias l := lines
--
--     shebang:
--         #!/bin/sh
--         echo sh
--
--     params arg:
--         echo {{arg}}
--
--     [confirm]
--     confirmed:
--         echo confirmed
--
--     dep-args: (params "1")
--         echo dep-args
--
--     fn-call:
--         echo {{shell('ls')}}
--
--     joined:
--         echo {{x / "sub"}}
--
--     uses-shebang: shebang
--         echo uses
local MAIN = [=[
{"assignments":{"x":{"eager":false,"export":false,"name":"x","private":false,"value":"hi"},"y":{"eager":false,"export":false,"name":"y","private":false,"value":["concatenate",["variable","x"],["concatenate","/","q"]]}},"first":"a","doc":null,"groups":[],"module_path":"","modules":{},"aliases":{"l":{"attributes":[],"name":"l","target":"lines"}},"recipes":{"a":{"attributes":["default"],"body":[["echo a ",[["variable","x"]]," ",[["variable","y"]]]],"dependencies":[{"arguments":[],"recipe":"b","star":null},{"arguments":[],"recipe":"b","star":null},{"arguments":[],"recipe":"c","star":null}],"doc":null,"name":"a","parameters":[],"priors":1,"private":false,"quiet":false,"namepath":"a","shebang":false},"b":{"attributes":[],"body":[["echo b"]],"dependencies":[{"arguments":[],"recipe":"c","star":null}],"doc":null,"name":"b","parameters":[],"priors":1,"private":false,"quiet":false,"namepath":"b","shebang":false},"c":{"attributes":[],"body":[["echo c"]],"dependencies":[],"doc":null,"name":"c","parameters":[],"priors":0,"private":false,"quiet":false,"namepath":"c","shebang":false},"confirmed":{"attributes":[{"confirm":null}],"body":[["echo confirmed"]],"dependencies":[],"doc":null,"name":"confirmed","parameters":[],"priors":0,"private":false,"quiet":false,"namepath":"confirmed","shebang":false},"d":{"attributes":[],"body":[["echo d"]],"dependencies":[{"arguments":[],"recipe":"c","star":null},{"arguments":[],"recipe":"a","star":null}],"doc":null,"name":"d","parameters":[],"priors":1,"private":false,"quiet":false,"namepath":"d","shebang":false},"dep-args":{"attributes":[],"body":[["echo dep-args"]],"dependencies":[{"arguments":["1"],"recipe":"params","star":null}],"doc":null,"name":"dep-args","parameters":[],"priors":1,"private":false,"quiet":false,"namepath":"dep-args","shebang":false},"fn-call":{"attributes":[],"body":[["echo ",[["call","shell","ls"]]]],"dependencies":[],"doc":null,"name":"fn-call","parameters":[],"priors":0,"private":false,"quiet":false,"namepath":"fn-call","shebang":false},"joined":{"attributes":[],"body":[["echo ",[["join",["variable","x"],"sub"]]]],"dependencies":[],"doc":null,"name":"joined","parameters":[],"priors":0,"private":false,"quiet":false,"namepath":"joined","shebang":false},"lines":{"attributes":[{"group":"g"},"no-exit-message","private"],"body":[["-@echo one \\"],["  two \\"],[["three"]," four"],["@-echo {{{{lit}} ",[["concatenate",["variable","x"],"!"]]],[],[[""]],["# comment"]],"dependencies":[],"doc":"documented","name":"lines","parameters":[],"priors":0,"private":true,"quiet":false,"namepath":"lines","shebang":false},"params":{"attributes":[],"body":[["echo ",[["variable","arg"]]]],"dependencies":[],"doc":null,"name":"params","parameters":[{"default":null,"export":false,"flag":false,"help":null,"kind":"singular","long":null,"max":null,"min":null,"multiple":false,"name":"arg","pattern":null,"short":null,"value":null}],"priors":0,"private":false,"quiet":false,"namepath":"params","shebang":false},"shebang":{"attributes":[],"body":[["#!/bin/sh"],["echo sh"]],"dependencies":[],"doc":null,"name":"shebang","parameters":[],"priors":0,"private":false,"quiet":false,"namepath":"shebang","shebang":true},"uses-shebang":{"attributes":[],"body":[["echo uses"]],"dependencies":[{"arguments":[],"recipe":"shebang","star":null}],"doc":null,"name":"uses-shebang","parameters":[],"priors":1,"private":false,"quiet":false,"namepath":"uses-shebang","shebang":false}},"settings":{"allow_duplicate_recipes":false,"allow_duplicate_variables":false,"default_list":false,"default_script":false,"dotenv_command":[],"dotenv_filename":null,"dotenv_load":false,"dotenv_override":false,"dotenv_path":null,"dotenv_required":false,"export":false,"fallback":false,"guards":false,"ignore_comments":false,"indentation":null,"lazy":false,"lists":false,"no_cd":false,"no_exit_message":false,"positional_arguments":false,"quiet":false,"shell":null,"tempdir":null,"unstable":false,"windows_powershell":false,"windows_shell":null,"working_directory":null},"source":"/private/tmp/jr/fx/main/justfile","unexports":[],"warnings":[]}
]=]

--- MAIN with top-level fields replaced by fragments of other real dumps.
--- @param fields table<string, string> JSON per replaced field
--- @return table
local function main_with(fields)
    local dump = decode(MAIN)
    for key, json in pairs(fields) do
        dump[key] = decode(json)
    end
    return dump
end

-- Expected commands below are `just --dry-run` output for the same names.
local A = { "echo c", "echo b", "echo a hi hi/q", "echo c", "echo b" }

describe("JustRecipe.recipe_commands", function()
    it("runs the first recipe when no recipe is named", function()
        assert.same(A, JustRecipe.recipe_commands(decode(MAIN), {}))
    end)

    it("runs a named recipe with its dependencies around the body", function()
        assert.same(A, JustRecipe.recipe_commands(decode(MAIN), { "a" }))
    end)

    it("runs a recipe once, unless only a subsequent ran it", function()
        local dump = decode(MAIN)
        assert.same(A, JustRecipe.recipe_commands(dump, { "a", "a" }))
        assert.same(A, JustRecipe.recipe_commands(dump, { "b", "a" }))
        assert.same({
            "echo c",
            "echo d",
            "echo c",
            "echo b",
            "echo a hi hi/q",
            "echo c",
            "echo b",
            "echo b",
            "echo a hi hi/q",
            "echo c",
            "echo b",
        }, JustRecipe.recipe_commands(dump, { "c", "d", "a" }))
    end)

    it("joins continuations, strips sigils and skips empty lines", function()
        assert.same({
            "echo one two three four",
            "echo {{lit}} hi!",
            "# comment",
        }, JustRecipe.recipe_commands(decode(MAIN), { "lines" }))
    end)

    it("resolves an alias", function()
        assert.same(
            JustRecipe.recipe_commands(decode(MAIN), { "lines" }),
            JustRecipe.recipe_commands(decode(MAIN), { "l" })
        )
    end)

    it("declines an unknown recipe name", function()
        assert.is_nil(JustRecipe.recipe_commands(decode(MAIN), { "nope" }))
        assert.is_nil(JustRecipe.recipe_commands(decode(MAIN), { "x=1" }))
    end)

    it("declines a shebang recipe, also as a dependency", function()
        local dump = decode(MAIN)
        assert.is_nil(JustRecipe.recipe_commands(dump, { "shebang" }))
        assert.is_nil(JustRecipe.recipe_commands(dump, { "uses-shebang" }))
    end)

    it("declines parameters and dependency arguments", function()
        local dump = decode(MAIN)
        assert.is_nil(JustRecipe.recipe_commands(dump, { "params" }))
        assert.is_nil(JustRecipe.recipe_commands(dump, { "dep-args" }))
    end)

    it("declines an attribute that may change what runs", function()
        assert.is_nil(JustRecipe.recipe_commands(decode(MAIN), { "confirmed" }))
    end)

    it("declines a function call or path join in a body", function()
        local dump = decode(MAIN)
        assert.is_nil(JustRecipe.recipe_commands(dump, { "fn-call" }))
        assert.is_nil(JustRecipe.recipe_commands(dump, { "joined" }))
    end)

    it("declines an assignment that is not a literal", function()
        -- z := `echo hi`
        local backtick = main_with({
            assignments = [[{"z":{"eager":false,"export":false,"name":"z","private":false,"value":["evaluate","echo hi"]}}]],
        })
        -- x := env("HOME")
        local call = main_with({
            assignments = [[{"x":{"eager":false,"export":false,"name":"x","private":false,"value":["call","env","HOME"]}}]],
        })
        assert.is_nil(JustRecipe.recipe_commands(backtick, { "c" }))
        assert.is_nil(JustRecipe.recipe_commands(call, { "c" }))
    end)

    it("declines an exported assignment", function()
        -- export x := "hi"
        local dump = main_with({
            assignments = [[{"x":{"eager":false,"export":true,"name":"x","private":false,"value":"hi"}}]],
        })
        assert.is_nil(JustRecipe.recipe_commands(dump, { "c" }))
    end)

    it("declines a setting that is not at its default", function()
        -- set quiet
        local dump = main_with({
            settings = [[{"allow_duplicate_recipes":false,"allow_duplicate_variables":false,"default_list":false,"default_script":false,"dotenv_command":[],"dotenv_filename":null,"dotenv_load":false,"dotenv_override":false,"dotenv_path":null,"dotenv_required":false,"export":false,"fallback":false,"guards":false,"ignore_comments":false,"indentation":null,"lazy":false,"lists":false,"no_cd":false,"no_exit_message":false,"positional_arguments":false,"quiet":true,"shell":null,"tempdir":null,"unstable":false,"windows_powershell":false,"windows_shell":null,"working_directory":null}]],
        })
        assert.is_nil(JustRecipe.recipe_commands(dump, { "c" }))
    end)

    it("declines modules and unexports", function()
        -- mod sub
        local module = main_with({
            modules = [=[{"sub":{"assignments":{},"first":"b","doc":null,"groups":[],"module_path":"sub","modules":{},"aliases":{},"recipes":{"b":{"attributes":[],"body":[["echo b"]],"dependencies":[],"doc":null,"name":"b","parameters":[],"priors":0,"private":false,"quiet":false,"namepath":"sub::b","shebang":false}},"settings":{},"source":"/private/tmp/jr/fx/module/sub.just","unexports":[],"warnings":[]}}]=],
        })
        -- unexport FOO
        local unexport = main_with({ unexports = [=[["FOO"]]=] })
        assert.is_nil(JustRecipe.recipe_commands(module, { "c" }))
        assert.is_nil(JustRecipe.recipe_commands(unexport, { "c" }))
    end)

    it("declines no names when the justfile has no recipes", function()
        local dump = decode(MAIN)
        dump.first = nil
        assert.is_nil(JustRecipe.recipe_commands(dump, {}))
    end)

    it("declines a field it does not know", function()
        local recipe_field = decode(MAIN)
        recipe_field.recipes.c.parallel = true
        local top_field = decode(MAIN)
        top_field.overrides = { x = "rm" }
        assert.is_nil(JustRecipe.recipe_commands(recipe_field, { "c" }))
        assert.is_nil(JustRecipe.recipe_commands(top_field, { "c" }))
    end)

    it("declines a dump decoded with nulls as vim.NIL", function()
        assert.is_nil(
            JustRecipe.recipe_commands(vim.json.decode(MAIN), { "c" })
        )
    end)
end)
