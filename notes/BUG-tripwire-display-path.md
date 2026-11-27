# Bug: the background-session tripwire judges an edit by its display path
Priority: P3

`BackgroundSession:_check_tripwire` (`lua/agentic/background_session.lua`)
rebuilds an edit call's input as `{ filePath = tracker.argument }` and asks
`PermissionManager:decide` whether policy would have allowed it.
`tracker.argument` is the block head: `FileSystem.to_smart_path` output,
relative to the editor's cwd or `~/`-prefixed. `_granted_pair`
(`lua/agentic/ui/permission_manager.lua`) returns nil for any path not
starting with `/`, so the grant check fails with "not in a grant scope".

Effect: an unasked edit inside a granted tmp root (`GrantSafety.tmp_roots`,
added in `BackgroundSession` setup) still stops the session when the path
displays as relative (the editor's cwd is inside that root) — a false stop. The tripwire fails closed, so
no unsafe edit is let through.

The block holds no absolute path for a file call (`ToolCallBase` has
`argument` only; the diff's path is not kept).

Reproduce: background-session test with a grant scope on `/tmp/g`, editor
cwd `/tmp/g`, and an unasked `completed` edit whose tracker argument is
`a.txt` (the smart form of `/tmp/g/a.txt`); expect no stop, observe one.
