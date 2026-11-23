# Plan: option values as grant-scoped write effects
Status: spec
Priority: P3
Depends:

## Relevant files
- `lua/agentic/permissions.json` — `curl`, `http`, `sort`, `shuf`,
  `base64`, `pkg-config`, `pkgconf`, `git`; new `wget`
- `lua/agentic/utils/permission_structured.lua` — `ExistCtx`
  (`flag_cands_at`), `build_exist_ctx`, `match_options`, `arity_of`,
  `every_scope_takers`, `decide_leaf`, `agentic.StructuredCmdEntry`,
  `normalise_structured_entries`, `normalise_arity` (model for a per-entry
  normaliser), `get_entries` (user/bundled merge), `glob_to_lua_pattern`
- `lua/agentic/utils/permission_structured.test.lua`
- `lua/agentic/utils/permission_rules.lua` — `walk_command` (the `rm`
  branch, `parsed_actions`, the structured branch after `decide_leaf`),
  `walk_redirected`, `record_writes`, `cwds_at`, `command_known_safe`,
  `tally_redirected`, `Reason`, `REASON_TEXT`, `evaluate` docstring
- `lua/agentic/utils/permission_rules.test.lua` — curl/gh end-to-end cases,
  "range reasons", the curl expand-twin test
- `lua/agentic/utils/shell_parse.lua` — `delivered_path`, `FileEffect`
- `lua/agentic/ui/permission_manager.lua` — `_bash_effects_clear`,
  `CAUSE_TEXT` (read, not changed)
- `lua/agentic/ui/permission_manager.test.lua` — "grant scopes"
- `doc/agentic.txt` — structured rules paragraph (`option_values`, `arity`)
- `.claude/skills/permissions/SKILL.md` — § Grant scopes (mutation
  producers), § Known limitations
- `notes/FEAT-sed-in-place-grant.md` — the operand producer for `sed -i`;
  whichever plan lands second calls `add_write_effects` and merges the
  `evaluate` docstring edit
- Skills: `permissions`, `implement`, `neovim`, `lua-class`

## Background
Many read-only commands write a file only through an option value:
`curl -o F`, `wget -O F`, `sort -o F`, `http -o F`. The bundled rules gate
these options with `ask` (a prompt, also in auto mode) or `unless` (a
prompt, or the classifier in auto mode). A grant scope cannot approve
them: grants judge file effects, and only a redirect write and an `rm`
operand produce one. The same call with `> F` in place of `-o F` clears
`/tmp` silently.

The producer is data: a `writes` field per command lists the options
whose values are files written. No per-command branch, unlike `rm` and
`sed -i`. The effects over-approximate: every word that names a listed
option in some parse (`ExistCtx.flag_cands_at`, abbreviations included)
gives the value of every reading as a write, whether or not that parse
is the one the program uses. An extra effect can only withhold approval.
So arity hints are not needed to find the writes: `sort -k -o F` reports
`F` even though `-o` may be the value of `-k`. A dynamic word may expand
to a listed option, so it leaves the leaf unmodelled.

A listed option's value is a literal file path, which the grant checks
like any other edit, unless it has a program-specific shape that means
something else. Two such shapes exist, each a glob list on the gate:
- `not_files`: the value names no file (curl and wget take `-` as stdout,
  curl's `--trace` takes `%` as stderr; `/dev/null`, `/dev/stdout`,
  `/dev/stderr`). No effect.
- `opaque`: the value hides the path written (curl replaces `#N` in `-o`
  from URL globbing; `-w`/`--write-out` writes through `%output{F}` and
  reads its format from `@F`). The leaf is not modelled. Checked before
  `not_files`.

`-w` is a gate with `not_files: ["*"]` and an `opaque` for its two file
forms. curl reads `%output{` case-sensitively (measured: `%OUTPUT{f}`
prints literally).

wget writes its HSTS database (`~/.wget-hsts`) once a server sends an HSTS
header, unless `--no-hsts` is given, and for FTP directory and glob URLs a
transient `./.listing`. Both are wget's own state, like the index `git
status` refreshes; they are accepted, not modelled.

git takes `--output=F` and `--output F` in every command that parses diff
options (`log`, `show`, `diff`, `diff-tree`, `whatchanged`,
`format-patch`, `blame` measured), and refuses an abbreviation (`--outp`).
The bundled `git` rules approve `git log --output F` today with no effect.
A `writes` gate needs no subcommand scope: a git command that does not
write through `--output` only gets a write effect it does not make, which
can withhold approval but never grants it.

In auto mode the result goes to the classifier, not the plugin prompt:
an out-of-grant write gets a `grant` cause and an opaque write an
`opaque-write` cause, and `permission_hook.lua` returns `ask` only for
an `ask` cause. This is intended.

## Changes
### `permission_structured.lua`
```lua
--- @class agentic.PermWriteGate
--- @field options string[] dashless identifiers whose values are files written
--- @field not_files? string[] value globs that name no file (`-`, `/dev/null`): no effect
--- @field opaque? string[] value globs that hide the path written (`#N`, `%output{F}`): the leaf is not modelled
```
`agentic.StructuredCmdEntry` gets `--- @field writes? agentic.PermWriteGate[]`.

- New:
  ```lua
  --- Every value a listed option may get in some parse: for each word in
  --- `exist.flag_cands_at` that may name one of `options` (abbreviations
  --- included), `--name=v` gives `v`; `--name` gives the next word; in a
  --- cluster, each listed letter gives the rest of the word (and the rest
  --- without a leading `=`), or the next word when it is the last letter.
  --- @param options string[] dashless identifiers
  --- @param exist agentic.PermStructured.ExistCtx
  --- @return { value: string, word: integer }[] candidates in word order; `word` is the index of the word holding the value
  local function possible_values(options, exist)
  ```
  Iterates words `1..#exist.words` for a stable order.
- New:
  ```lua
  --- The values a leaf writes files through, per its command's `writes`
  --- gates: every `possible_values` candidate that matches no `not_files`
  --- glob. A gate's `opaque` globs are checked first.
  --- @param entries agentic.StructuredEntries
  --- @param parsed agentic.ParsedLeaf
  --- @return { value: string, word: integer }[]|nil writes see `possible_values`. Nil when a candidate matches an `opaque` glob, its value word is dynamic (any truthy `args_dynamic`), or the leaf has a word that may expand to an option (`has_dynamic`) and its command has `writes`.
  function M.write_values(entries, parsed)
  ```
  Reads the command's own entry only. Builds the existential context as
  `decide_leaf` does (`arity_of`, `build_exist_ctx(…, every_scope_takers(arity))`).
- `normalise_structured_entries`: a `normalise_writes(writes, cmd)` keeps
  valid gates (dashless `options`, string lists), warns on others like
  `normalise_arity`, and drops `writes` on `"*"`. In `get_entries`, a user
  `writes` replaces the bundled one, as the gate lists do.

### `permission_rules.lua`
- New local, used by `walk_redirected` and the branch below:
  ```lua
  --- Record writes to `paths`: one `write` effect each, their keys in
  --- `ctx.written` (`record_writes`), and the taint when any.
  --- @param ctx agentic.utils.PermissionRules.WalkCtx
  --- @param paths string[] delivered paths
  --- @param content string|nil bytes each file will hold; nil = unknown
  --- @param node TSNode the command the writes belong to
  local function add_write_effects(ctx, paths, content, node)
  ```
- `walk_command`: where the structured branch has an `allow_kind` and the
  leaf is not `user_allowed`, call `PermissionStructured.write_values`. A
  settings.json allow or a remembered leaf is the user's override, as in
  the `rm` branch. Nil → `return false`. When `parsed_actions`
  replaced `args`, a non-empty result → `return false` (`arg_nodes` no
  longer lines up). Each value's path is
  `ShellParse.delivered_path(value, arg_nodes[word], src)`: for a value
  glued to its option word the node text starts with `-`, so a leading
  `~` gets `./`. Then `add_write_effects(ctx, paths, nil, node)`.
- `Reason`: add `"opaque-write"` — "it writes a file whose path the
  check cannot name".
- `command_known_safe`: where the leaf would be `struct_safe`, call
  `write_values`. Nil → return `false, nil, nil, reason` with no leaf
  signature, so allow-always keeps the whole-command fallback, as for an
  `ask` leaf. The reason is `"dynamic"` for a leaf with a dynamic word,
  else `"opaque-write"`. Non-nil → set `ctx.taint.set` and
  `record_writes` the paths, as `tally_redirected` does for a redirect.
- `evaluate` docstring: effects are "(redirect writes, `writes` option
  values, `rm` operands)".

### `shell_parse.lua`
- `FileEffect.kind` doc: "A redirect write, an option value a `writes`
  gate lists, or an `rm` operand".

### `permissions.json`
- `curl`: remove `o`, `output`, `D`, `dump-header`, `c`, `cookie-jar`,
  `trace`, `trace-ascii`, `libcurl`, `etag-save`, `stderr`, `w`,
  `write-out` from the `read_only` gate's `unless`, and its nested
  `option_values` exception. Add `no-clobber` (it writes `F.1`…`F.100`
  beside `F`). `expand-*` twins, `output-dir`, `create-dirs`, `O`, `J`,
  `remote-*`, `hsts`, `alt-svc`, `ssl-sessions` stay. `--output F` matches
  the `output-dir` prefix and stays undecided; `-o F` approves. Add:
  ```json
  "writes": [
    { "options": ["o", "output"],
      "not_files": ["/dev/null", "/dev/stdout", "/dev/stderr", "-"], "opaque": ["*#*"] },
    { "options": ["D", "dump-header", "c", "cookie-jar", "stderr"],
      "not_files": ["/dev/null", "/dev/stdout", "/dev/stderr", "-"] },
    { "options": ["trace", "trace-ascii"],
      "not_files": ["/dev/null", "/dev/stdout", "/dev/stderr", "-", "%"] },
    { "options": ["libcurl", "etag-save"],
      "not_files": ["/dev/null", "/dev/stdout", "/dev/stderr"] },
    { "options": ["w", "write-out"], "not_files": ["*"], "opaque": ["@*", "*%output{*"] }
  ]
  ```
  `man curl` states `-` is stdout for `-o`, `-c`, `--trace`, `--trace-ascii`
  and `--stderr`, and `%` is stderr for `--trace`/`--trace-ascii`; `-D -`
  is approved today. `--libcurl` and `--etag-save` state no `-` rule.
- `wget` (new): `read_only: [{ "options": ["O", "output-document"],
  "unless": [<every option that writes another file, sends a local file,
  runs a program, or loads options>] }]` — `o`, `output-file`, `a`,
  `append-output`, `rejected-log`, `b`, `background`, `P`,
  `directory-prefix`, `x`, `force-directories`, `r`, `recursive`, `m`,
  `mirror`, `p`, `page-requisites`, `k`, `convert-links`, `K`,
  `backup-converted`, `backups`, `delete-after`, `no-remove-listing`,
  `save-cookies`, `warc-file`, `warc-cdx`, `warc-tempdir`, `e`, `execute`,
  `config`, `use-askpass`, `i`, `input-file`, `B`, `base`,
  `input-metalink`, `metalink-over-http`, `metalink-index`,
  `preferred-location`, `post-data`, `post-file`, `method`, `body-data`,
  `body-file`, `hsts-file`.
  `writes: [{ "options": ["O", "output-document"], "not_files": ["/dev/null", "/dev/stdout", "/dev/stderr", "-"] }]`.
  `arity.*`: wget is the one command here whose gate needs hints. Without
  `-O` it writes a file named from the URL, so the gate must find `-O` as
  an option in every parse, and an unhinted option before it may take it
  as its value. Takers for every valued option in `wget --help`, `-n`
  included (it reads its own letters: `-nv` is `-n v`); booleans
  `-q`, `--quiet`, `-v`, `--verbose`, `-S`, `--server-response`, `-N`,
  `--timestamping`, `-c`, `--continue`, `-4`, `-6`, `--no-hsts`,
  `--spider`, `--no-check-certificate`.
- `http`: `o`/`output` move from `ask` to `writes: [{ "options": ["o",
  "output"], "not_files": ["/dev/null", "/dev/stdout", "/dev/stderr", "-"] }]`;
  `d`/`download` stay in `ask`.
- `sort`, `shuf`, `base64`: `o`/`output` move from `ask` to `writes`.
- `pkg-config`, `pkgconf`: `log-file` moves from `ask` to `writes`.
- `git`: `writes: [{ "options": ["output"], "not_files": ["/dev/null",
  "/dev/stdout", "/dev/stderr"] }]`.

### Tests
- `permission_structured.test.lua`, `write_values`: `-o F`, `-oF`,
  `-o=F` (`=F` and `F`), `-sSo F`, `--output=F`, `--output F`, `--out F`
  (abbreviation, `F`), two `-o` occurrences in word order, `-k -o F` with
  `-k` unhinted (`F`), `-o` as the last word (`{}`), a `not_files` value,
  an `opaque` value, a `w` value matching both lists (→ nil), a dynamic
  word anywhere → nil, a command with no `writes` → `{}`.
- `permission_rules.test.lua`, `evaluate`: `curl -sS -o /tmp/s.out -w
  '[%{http_code}]' URL` gives ok with one write `/tmp/s.out`; `curl -w
  '%output{f}x' URL` and `curl -o 'f_#1' URL` are not ok with reason
  `opaque-write`; `curl --no-clobber -o /tmp/x URL` not ok; `curl -o
  /dev/null URL`, `curl -D - URL` keep no effect; `curl -o '~/x' URL` and
  `curl -o~/x URL` give the effect `./~/x`; `wget -O /tmp/x URL` and
  `wget -q -nv -O /tmp/x URL` one write, `wget URL` not ok, `wget -O x -r
  URL` not ok, `wget -b -O x URL` not ok; `sort -r -o /tmp/x f` one
  write; `git log --output /tmp/x`, `git -C /r show --output=/tmp/x` and
  `git log --outp=/tmp/x` one write each. A glob allow (`Bash(sort *)`) on `sort -o F` approves with no
  effect.
- `tally_unapproved`: `curl -o /tmp/s.sh URL; bash /tmp/s.sh` judges the
  script as unknown, as the walk does; `curl -o 'f_#1' URL` gives no leaf.
- The curl expand-twin test collects options from both the `unless` gates
  and `writes`.
- `permission_manager.test.lua` "grant scopes": `curl -o /tmp/x URL`
  approves with a `grant` cause under the default grants; `curl -o
  <tracked dirty file> URL` gives a `grant` cause with `file has unstaged
  changes`.

### Docs
- `doc/agentic.txt`, structured rules paragraph: one sentence for
  `writes` (options whose values are files written; each must fall in a
  grant scope) and its two glob lists.
- `permissions` skill: § Grant scopes adds `writes` option values to the
  Bash producers; § Known limitations notes that an option outside a
  `writes` gate's list still decides nothing about files.

## Expected outcome
- `curl -sSL -o /tmp/s.out -w '[%{http_code}] %{content_type}' URL` runs
  with no prompt under the default grants, with `grant /tmp/s.out` in the
  footer. In auto mode the hook returns `allow`.
- The same call writing outside every grant scope, or to a tracked file
  with unstaged changes, gets a `grant` cause: a prompt, or the classifier
  in auto mode.
- `wget -O F URL`, `sort -o F`, `shuf -o F`, `base64 -o F`, `http -o F`,
  `pkg-config --log-file F`, `git log --output=F` behave the same. A
  `git log --output=F` outside every grant scope no longer approves.
- A call with a dynamic word anywhere (`curl -o F "https://host/$p"`)
  stays undecided: a dynamic word may expand to an option.
  `FEAT-single-word-dynamic.md` lifts this for a quoted word that cannot.
  A dynamic value word (`curl -o "/tmp/$x"`) stays undecided under both
  plans.
- An opaque write (`curl -o 'a_#1'`, `-w @fmt`) is undecided with reason
  `opaque-write`.

## Non-goals
- Operands that a flag turns into write targets (`gofmt -w`,
  `prettier --write`, `shfmt -w`, `typos -w`, `latexindent -w`, `biome
  --write`): a directory operand recurses, some tools expand glob operands
  themselves, and no operand often means the current directory. Grants
  judge one file per effect. `FEAT-sed-in-place-grant.md` covers `sed -i`.
- `latexindent -o`: its value takes `+`/`++` prefixes that derive the path
  from the input name.
- Commands that derive the output name (`curl -O`/`-J`, `wget` without
  `-O`, `http -d`, `yt-dlp`).
- Relative paths: `_bash_effects_clear` refuses them, as for redirects and
  `rm`.
- `~/.curlrc`, `~/.wgetrc`, `CURL_HOME`, `WGETRC`: unchanged from today's
  `curl` `read_only` gate, which does not read them.
- Folding `rm` into `writes`: its operands are positionals and its effect
  is a delete.
- Listing these writes in the file activity panel (`ShellParse.file_effects`);
  `FEAT-shell-changes-from-git.md` covers program writes there.
- Gaps in today's `read_only` gates that this plan does not touch: curl
  `-H @file`/`--url-query @file`, httpie `--session`, `sort
  --compress-program`.

## Open questions
