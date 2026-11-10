local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local deferred_helper = require("tests.helpers.deferred")

local Config = require("agentic.config")
local TextModel = require("agentic.utils.text_model")

describe("agentic.utils.TextModel", function()
    local original_text_model
    local system_stub
    local deferred
    --- Arguments of the last `vim.system` call
    local cmd, opts, on_exit
    --- Body file contents, read while the stubbed process "runs"
    local body

    --- Collects the `on_done` arguments.
    local function collector()
        local got = { called = 0 }
        return got,
            function(text, err)
                got.called = got.called + 1
                got.text, got.err = text, err
            end
    end

    --- Ends the stubbed process with `result` and runs scheduled callbacks.
    --- @param result table
    local function finish(result)
        on_exit(vim.tbl_extend("keep", result, {
            code = 0,
            signal = 0,
            stdout = "",
            stderr = "",
        }))
        deferred.drain()
    end

    --- Path of the body file named by `--data-binary @<path>`.
    --- @param argv string[]
    --- @return string
    local function data_path(argv)
        for i, arg in ipairs(argv) do
            if arg == "--data-binary" then
                return argv[i + 1]:sub(2)
            end
        end
        error("no --data-binary in argv")
    end

    local function exists(path)
        return vim.uv.fs_stat(path) ~= nil
    end

    before_each(function()
        original_text_model = Config.text_model
        Config.text_model = {
            url = "http://localhost:4000/v1/",
            timeout_ms = 1000,
        }
        cmd, opts, on_exit, body = nil, nil, nil, nil
        system_stub = spy.stub(vim, "system")
        system_stub:invokes(function(c, o, cb)
            cmd, opts, on_exit = c, o, cb
            body = vim.json.decode(vim.fn.readblob(data_path(c)))
            return {}
        end)
        deferred = deferred_helper.capture()
    end)

    after_each(function()
        deferred.revert()
        system_stub:revert()
        Config.text_model = original_text_model
        vim.env.TEXT_MODEL_TEST_KEY = nil
    end)

    it("is available only with a url", function()
        assert.is_true(TextModel.available())
        Config.text_model.url = nil
        assert.is_false(TextModel.available())
    end)

    it("schedules an error when not available", function()
        Config.text_model.url = nil
        local got, on_done = collector()
        assert.is_nil(TextModel.complete({ model = "m", input = "x" }, on_done))
        assert.equal(0, got.called)
        deferred.drain()
        assert.equal(1, got.called)
        assert.is_nil(got.text)
        assert.is_not_nil(got.err)
        assert.equal(0, system_stub.call_count)
    end)

    it("posts the request body to the chat completions endpoint", function()
        TextModel.complete(
            { model = "m", system = "be brief", input = "hi", max_tokens = 5 },
            function() end
        )
        assert.equal("curl", cmd[1])
        assert.equal("http://localhost:4000/v1/chat/completions", cmd[#cmd])
        assert.same({
            model = "m",
            max_tokens = 5,
            messages = {
                { role = "system", content = "be brief" },
                { role = "user", content = "hi" },
            },
        }, body)
        assert.equal(1000, opts.timeout)
    end)

    it("sends only the user message without a system prompt", function()
        TextModel.complete({ model = "m", input = "hi" }, function() end)
        assert.same({ { role = "user", content = "hi" } }, body.messages)
    end)

    it("passes the key on stdin, escaped, never on argv", function()
        Config.text_model.api_key_env = "TEXT_MODEL_TEST_KEY"
        vim.env.TEXT_MODEL_TEST_KEY = [[se"c\ret]]
        TextModel.complete({ model = "m", input = "hi" }, function() end)
        for _, arg in ipairs(cmd) do
            assert.is_nil(arg:find("c\\ret", 1, true))
        end
        assert.equal(
            [[header = "Authorization: Bearer se\"c\\ret"]] .. "\n",
            opts.stdin
        )
    end)

    it("sends no Authorization header without api_key_env", function()
        TextModel.complete({ model = "m", input = "hi" }, function() end)
        assert.equal("", opts.stdin)
    end)

    it("errors when the key env var is unset", function()
        Config.text_model.api_key_env = "TEXT_MODEL_TEST_KEY"
        local got, on_done = collector()
        assert.is_nil(TextModel.complete({ model = "m", input = "x" }, on_done))
        assert.equal(0, got.called)
        deferred.drain()
        assert.is_nil(got.text)
        assert.truthy(got.err:find("TEXT_MODEL_TEST_KEY", 1, true))
        assert.equal(0, system_stub.call_count)
    end)

    it("returns the reply text and removes the body file", function()
        local got, on_done = collector()
        TextModel.complete({ model = "m", input = "hi" }, on_done)
        local path = data_path(cmd)
        assert.is_true(exists(path))
        finish({
            stdout = vim.json.encode({
                choices = { { message = { content = "hello" } } },
            }),
        })
        assert.equal("hello", got.text)
        assert.is_nil(got.err)
        assert.is_false(exists(path))
    end)

    it("reports curl's stderr and body on a non-zero exit", function()
        local got, on_done = collector()
        TextModel.complete({ model = "m", input = "hi" }, on_done)
        local path = data_path(cmd)
        finish({
            code = 22,
            stderr = "curl: (22) error: 401\n",
            stdout = "bad key",
        })
        assert.is_nil(got.text)
        assert.truthy(got.err:find("401", 1, true))
        assert.truthy(got.err:find("bad key", 1, true))
        assert.is_false(exists(path))
    end)

    it("calls on_done scheduled after the process exits", function()
        local got, on_done = collector()
        TextModel.complete({ model = "m", input = "hi" }, on_done)
        on_exit({ code = 7, signal = 0, stdout = "", stderr = "refused" })
        assert.equal(0, got.called)
        deferred.drain()
        assert.equal(1, got.called)
    end)

    it("reports a timeout", function()
        local got, on_done = collector()
        TextModel.complete({ model = "m", input = "hi" }, on_done)
        finish({ code = 124, signal = 15 })
        assert.is_nil(got.text)
        assert.equal("timeout after 1000 ms", got.err)
    end)

    it("reports a killed job without output, not as a timeout", function()
        local got, on_done = collector()
        TextModel.complete({ model = "m", input = "hi" }, on_done)
        finish({ code = 0, signal = 15 })
        assert.is_nil(got.text)
        assert.equal("curl exited with code 0, signal 15", got.err)
    end)

    it("reports a failed spawn and removes the body file", function()
        local path
        system_stub:invokes(function(c)
            path = data_path(c)
            error("ENOENT: no such file or directory")
        end)
        local got, on_done = collector()
        assert.is_nil(
            TextModel.complete({ model = "m", input = "hi" }, on_done)
        )
        assert.equal(0, got.called)
        deferred.drain()
        assert.is_nil(got.text)
        assert.truthy(got.err:find("ENOENT", 1, true))
        assert.is_false(exists(path))
    end)

    it("reports an undecodable body", function()
        local got, on_done = collector()
        TextModel.complete({ model = "m", input = "hi" }, on_done)
        finish({ stdout = "<html>" })
        assert.is_nil(got.text)
        assert.truthy(got.err:find("<html>", 1, true))
    end)

    it("reports a null content field", function()
        local got, on_done = collector()
        TextModel.complete({ model = "m", input = "hi" }, on_done)
        local reply = '{"choices":[{"message":{"content":null}}]}'
        finish({ stdout = reply })
        assert.is_nil(got.text)
        assert.truthy(got.err:find(reply, 1, true))
    end)

    it("reports missing choices", function()
        local got, on_done = collector()
        TextModel.complete({ model = "m", input = "hi" }, on_done)
        finish({ stdout = "{}" })
        assert.is_nil(got.text)
        assert.truthy(got.err:find("{}", 1, true))
    end)
end)
