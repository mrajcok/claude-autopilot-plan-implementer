# claude-autopilot-plan-implementer

Run a project's plan file through Claude Code, one step at a time, each in a
fresh session, committing after each step that passes its tests.

Two pieces:

- **`autopilot.sh`** — a bash harness. Reads a plan file (default
  `docs/plan.md`) in whatever project you run it from, invokes a fresh
  `claude -p` session per step via the `plan-step-implementer` skill,
  verifies the result (`./run_tests.sh`), and commits/merges on success. Full
  behavior, environment variables and guarantees are documented in its own
  `-h`/`--help`.
- **`autopilot_notify.py`** — sends a plain-text email summary when a run
  ends (finished, stopped for review, or interrupted). Configured via
  `EMAIL_ENABLED` and `SMTP_*`/`EMAIL_*` vars in **this repo's own `.env`**
  (copy `.env.example`) — never the project being worked on. One setup
  covers every project you run autopilot in.
- **`plan-step-implementer`** (`skills/plan-step-implementer/SKILL.md`) — the
  Claude Code skill that actually reads the plan and implements one step.
  Installed globally so it works in any project.

## Install

```bash
./install.sh
```

Symlinks:

- `bin/autopilot.sh` → `~/.local/bin/autopilot`
- `skills/plan-step-implementer` → `~/.claude/skills/plan-step-implementer`

Make sure `~/.local/bin` is on your `PATH` (`install.sh` warns if it isn't).
Re-run `install.sh` any time after pulling changes — the symlinks mean you
usually don't need to.

Optional: `cp .env.example .env` and fill in `EMAIL_*`/`SMTP_*` here if you
want run-summary emails. Projects you run autopilot against need nothing —
no config, no dependency, no reference to autopilot at all. Using it is
entirely your call, not theirs.

## Use

From any project's root directory (a git repo, with a plan file and ideally
a `./run_tests.sh`):

```bash
tmux new -s autopilot   # autopilot refuses to run outside tmux
autopilot
```

See `autopilot --help` for the full contract: how steps are picked, branched,
verified and merged; usage-limit retry behavior; log locations; every
environment variable.

## Requirements

`claude` (Claude Code CLI), `jq`, and `timeout` (or `gtimeout` on macOS via
`brew install coreutils`) on `PATH`.

## Plan file format

Steps are markdown headings: `## Step N` or `### Na.` for sub-steps. A
finished one ends in `— **done**`. The skill picks the first one that isn't,
implements only that step, and marks it done — see
`skills/plan-step-implementer/SKILL.md` for the full contract, including the
sentinel lines (`AUTOPILOT_STEP=`, `AUTOPILOT_BRANCH=`, `NO_PENDING_STEPS`,
`HUMAN_REVIEW_REQUIRED`) it reports back to `autopilot.sh`.

## Developing this repo with itself

If you point `autopilot` at this repo's own plan file, `bin/autopilot.sh`,
`bin/autopilot_notify.py` and `skills/plan-step-implementer/SKILL.md` are
protected the same way any other project's harness files would be if it
happened to contain them: a step that edits them is never committed.
