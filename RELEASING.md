# Releasing

## Versioning

[Semantic versioning](https://semver.org): `MAJOR.MINOR.PATCH`.

- **PATCH** (`0.1.0 → 0.1.1`) — bug fixes only. Behaviour and config
  surface unchanged.
- **MINOR** (`0.1.1 → 0.2.0`) — new features. Backwards compatible:
  existing configs keep working, defaults preserved.
- **MAJOR** (`0.x → 1.0`, `1.x → 2.0`) — breaking changes. Removed
  or renamed config keys, changed default behaviour users may rely on,
  dropped Neovim version support.

Tags are `v<MAJOR>.<MINOR>.<PATCH>` (`v0.1.0`, etc.).

## Path to 0.1.0

Goal: drive the **Bugs** section of `TODO.md` to empty (or to
"Known minor") and cut `v0.1.0` as the first stable release. Until then
the plugin is pre-release — config keys and behaviour may still shift
without a major bump.

## Per release

- Update `CHANGELOG.md` (TBD — not yet started).
- Tag: `git tag -a v0.1.2 -m "v0.1.2"`.
- Push tag: `git push origin v0.1.2`.

## Changelog format

When `CHANGELOG.md` is created, follow [Keep a Changelog](https://keepachangelog.com/):
sections `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`,
grouped under each version with date.
