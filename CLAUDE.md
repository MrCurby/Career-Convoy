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

## Workflow

- `tools/test.sh` – syntax check, all tests, language check. Run it before every commit.
- `tools/bump.sh patch|minor|x.y.z` – raise the version (client `util.lua` + server `main.lua`).
- Push to `main` → GitHub Actions tests, builds `SharedCareer-<version>.zip` and creates release
  `v<version>` if it doesn't exist yet. Servers install it with `./server.sh update`.
- See `docs/development.md` for the layout of the code and how the mod works inside.
