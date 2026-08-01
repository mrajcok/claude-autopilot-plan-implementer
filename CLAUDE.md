# CLAUDE.md — claude-autopilot-plan-implementer

A bash + Python CLI tool, installed via `install.sh` onto `PATH` and into
`~/.claude/skills/`. Not a project with its own plan/build/test pipeline.

## Layout

- `bin/autopilot.sh` — the harness. Bash, `set -uo pipefail`, no
  dependencies beyond `claude`, `jq`, `timeout`.
- `bin/autopilot_notify.py` — email notifier. Stdlib only, no dependencies.
- `skills/plan-step-implementer/SKILL.md` — the Claude Code skill
  `autopilot.sh` invokes per step.
- `install.sh` — symlinks the above into place.

## Rules

- Both scripts run unattended, invoked by users in other projects' repos.
  Never assume the current working directory is this repo — resolve this
  repo's own path via `SCRIPT_DIR`/`readlink -f` where needed, and read
  everything else relative to the caller's CWD.
- Keep `autopilot_notify.py` dependency-free (stdlib only) — it must run
  under any project's Python without a venv.
- `skills/plan-step-implementer/SKILL.md` is prompt content: no rationale or
  background prose, state what to do. Keep it lean — length costs
  compliance.
- Validate changes to `autopilot.sh` with `bash -n` and `shellcheck`.

## Commit and push

"Commit and push" means exactly that: one commit, one-line message, one
push, one sentence back.
