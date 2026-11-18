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
  `cleanup.lua` RENAMES/MOVES, state flags: STATE_RENAMED in `util.lua`; server settings: RENAMED / REMOVED in `main.lua`,
  checked against the last release by `tests/config_update_test.lua`).

## Workflow

- `tools/test.sh` – syntax check, all tests, language check. Run it before every commit.
- `tools/bump.sh patch|minor|x.y.z` – raise the version (client `util.lua` + server `main.lua`).
- Each change in its own branch; never push to `main`. Every push to a branch builds a dev build
  (`SharedCareer-<version>-dev.<commit>.zip`, GitHub pre-release `build-<branch>`) without a version
  bump; a test server installs it with `./server.sh update --dev` (or `--dev=<branch>`).
- Once it works in the game: `tools/bump.sh` in the branch, then a pull request into `main`. Its
  checks run the tests and `tools/version_check.sh` (a change of the mod needs a new version).
  Merging → GitHub Actions builds `SharedCareer-<version>.zip` and creates release `v<version>`.
  Servers install it with `./server.sh update`.
- See `docs/development.md` for the layout of the code and how the mod works inside.

## Branch names

Name every branch after what it does: `<type>/<topic>`, lowercase, words joined with hyphens.

| Type | For | Example |
|---|---|---|
| `feat/` | a new feature or a visible improvement | `feat/rope-ground-marker` |
| `fix/` | a bug fix | `fix/rope-after-reset` |
| `refactor/` | cleaner code, same behavior | `refactor/grab-drawing` |
| `docs/` | documentation only | `docs/server-setup` |
| `ci/` | workflows, build and release tooling | `ci/dev-builds` |
| `chore/` | everything else (versions, cleanup) | `chore/remove-old-settings` |

This also applies in cloud sessions that come with a generated branch name (such as
`claude/<random-words>`): the maintainer's standing permission is to create the branch with the
logical name from `main` and push there instead; don't use the generated one. One branch per topic –
a new topic gets a new branch, even within the same session. Its dev build is then named after it
too (`build-feat-rope-ground-marker`).
