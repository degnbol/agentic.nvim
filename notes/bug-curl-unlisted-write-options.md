# Bug: curl options that write files are not in the ask list

`permissions.json` `curl` is `read_only` with an ask list of write options.
These options also write a file and are not in the list (from
`curl --help all`):

- `-c`, `--cookie-jar <filename>` — saves cookies after the operation
- `--libcurl <file>` — writes generated C code
- `--etag-save <file>`
- `--stderr <file>`
- `--hsts <filename>`, `--alt-svc <filename>` — cache files

`-w`/`--write-out` also writes a file through its `%output{path}` variable
(`curl -w '%output{/tmp/x}hi' https://x` creates `/tmp/x`, curl 8.7.1).

So `curl -c out https://x` classifies `read_only` in the structured layer.
In compound commands, the settings.json `Bash(curl *)` allow then approves
it.

Fix: add the identifiers to the curl ask gate, with a test per long and
short form.
