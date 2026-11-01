-- Headless parse-termination oracle. NOT a module — run as a standalone script
-- (`nvim --headless -u NONE -l zsh_parse_oracle.lua <parser.so>`), with the zsh
-- source to test on stdin. Exits 0 once `parse()` returns, 1 on any error.
--
-- Run it under a timeout: a C parse loop cannot be interrupted in-process, so a
-- non-terminating grammar bug can only be killed from outside. Only termination
-- matters; the tree is discarded. The parser `.so` path is an argument so this
-- stays independent of where the parser lives.

local parser_so = vim.v.argv[#vim.v.argv]
vim.treesitter.language.add("zsh", { path = parser_so })
local src = io.read("*a") or ""
local ok = pcall(function()
    vim.treesitter.get_string_parser(src, "zsh"):parse(true)
end)
os.exit(ok and 0 or 1)
