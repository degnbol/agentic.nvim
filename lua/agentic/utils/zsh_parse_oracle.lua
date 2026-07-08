-- Headless parse-termination oracle. NOT a module — run as a standalone script
-- (`nvim --headless -u NONE -l zsh_parse_oracle.lua <parser.so>`), with the zsh
-- source to test on stdin. Exits 0 once `parse()` returns, 1 on any error.
--
-- The caller (`shell_parse.parse_zsh_untrusted`) runs it under
-- `vim.system():wait(timeout)` so a non-terminating grammar bug is SIGKILLed —
-- a C parse loop cannot be interrupted in-process. Only termination matters
-- here; the tree is discarded and rebuilt in-process once proven to terminate.
-- The parser `.so` path is passed in (resolved by the caller via
-- `nvim_get_runtime_file`) so this stays independent of where the parser lives.

local parser_so = vim.v.argv[#vim.v.argv]
vim.treesitter.language.add("zsh", { path = parser_so })
local src = io.read("*a") or ""
local ok = pcall(function()
    vim.treesitter.get_string_parser(src, "zsh"):parse(true)
end)
os.exit(ok and 0 or 1)
