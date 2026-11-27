# Plan: name the file in the "always" options of a file change
Status: spec
Priority: P3
Depends:

## Relevant files
- `lua/agentic/pi/pi_permission.lua` — `OPTION_NAMES`, `M.to_request`
- `lua/agentic/pi/pi_tool_calls.lua` — `KINDS`, `M.kind`
- `lua/agentic/ui/permission_manager.lua` — `CACHE_KEY_FIELDS`,
  `_build_cache_key`
- `lua/agentic/pi/pi_permission.test.lua`
- Skill: `permissions`

## Background
The permission float offers "Allow always" and "Reject always" for every
call (`OPTION_NAMES`). The session cache (`PermissionManager._always_cache`)
keys an `edit` call (pi tools `edit`, `write`) by `path`, so "always" covers
every later change to that file. The label does not say so.

An `execute` call needs no other label: the float highlights the part of
the command that the prompt is for. An `other` call (extension tool) is
cached as this exact call, which "Allow always" already implies.

`PiPermission.to_request` names the options and has the tool kind, so the
wording goes there. The float renders `option.name` unchanged.

## Changes
- `pi_permission.lua`: a module-local `EDIT_NAMES` with
  `allow_always = "Allow this file always"` and
  `reject_always = "Reject this file always"`. `M.to_request` takes the name
  from `EDIT_NAMES[id]` when the kind is `edit` and there is an entry, else
  from `OPTION_NAMES[id]`.
- Tests (`pi_permission.test.lua`): a `write` call and an `edit` call get the
  file names; a `bash` call and an extension tool keep "Allow always" and
  "Reject always"; the `*_once` names do not change.

## Expected outcome
For a file change, the "always" options say that they cover the file.
Other calls keep the generic labels. Cache keys, approval and option order
do not change.

## Non-goals
- Persistent (cross-session) decisions: where the permission decision runs
  is open question 2 of `REFACTOR-pi-only.md`.
- `/trust` scope wording: a separate mechanism.
- The concrete path in the label.
