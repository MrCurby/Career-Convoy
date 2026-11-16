# SharedCareer – notes for working on this repository

BeamMP mod that brings the normal BeamNG.drive career to multiplayer. Overview: `README.md`; details: `docs/`.

## Language: English only

Everything in this repository is written in **English**:
code comments, docstrings, strings, log lines, console and chat output, UI texts, test
descriptions, tool output, commit messages and documentation.

This applies to every change, including small fixes and new files. `tests/language_check.py`
enforces it: it runs in `tools/test.sh` and fails on German umlauts or typical German words, and
GitHub then builds no release. If it flags a false positive, rephrase the English text rather than
weakening the check.

(The person maintaining the project may talk to you in German – answer in their language, but keep
the repository English.)

## Clean code

The maintainer puts a lot of weight on tidy code. Keep it that way with every change:

- Names say what a thing does. When a part grows beyond its name (the menu that was called
  "Time"), rename it everywhere: files, folders, identifiers, guihooks, settings, comments, docs.
- Each file does what its name says; move code that drifted into the wrong place.
- No duplicated helpers: shared ones go to `util.lua` (client) – e.g. `U.careerActive()`.
- No stale comments or docs: when behavior changes, fix every comment that describes it.
- No leftovers: remove old names, aliases ("old name for older callers") and dead code instead of
  keeping them around. Data on players' PCs or servers is migrated once instead (layouts:
  `cleanup.lua` RENAMES/MOVES, state flags: STATE_RENAMED; server settings: RENAMED in `main.lua`).

## Workflow

- `tools/test.sh` – syntax check, all tests, language check. Run it before every commit.
- `tools/bump.sh patch|minor|x.y.z` – raise the version (client `util.lua` + server `main.lua`).
- Push to `main` → GitHub Actions tests, builds `SharedCareer-<version>.zip` and creates release
  `v<version>` if it doesn't exist yet. Servers install it with `./server.sh update`.
- See `docs/development.md` for the layout of the code and how the mod works inside.
