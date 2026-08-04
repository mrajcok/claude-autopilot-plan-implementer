# claude-autopilot-plan-implementer

Use this project to automatically implement a plan file in a git repo, one step at a time, while you are away from your computer.
Includes Claude usage-limit retry behavior.

Components:

- **`autopilot.sh`** — a bash harness that performs the following:
  1. Runs a project's plan file through Claude Code, one step at a time, using a
     fresh Claude session with the `plan-step-implementer` skill for each step.
  2. After the skill has implemented a step, verifies the result (`./run_tests.sh`),
     and commits/merges on success.
  3. Sends a plain-text email summary (using `autopilot_notify.py`) when a run ends--finished, stopped
     for review, or interrupted.
- **`plan-step-implementer`** (`skills/plan-step-implementer/SKILL.md`) — the
  Claude Code skill that actually reads the plan, creates a branch and implements
  one step.
  
Both pieces are installed globally so they work in any project.

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

Optional: `cp .env.example .env` and fill in `EMAIL_*`/`SMTP_*` if you
want run-summary emails. 

Projects you run autopilot against need nothing —
no config, no dependency, no reference to autopilot at all.

## Use

From any project's root directory (a git repo, with a plan file and ideally
a `./run_tests.sh`):

```bash
tmux new -s autopilot   # then run autopilot inside it
autopilot
```

A run has to outlive its terminal, but tmux isn't the only way. `screen`,
`nohup` and `setsid` are all accepted and detected automatically:

```bash
nohup autopilot > /dev/null 2>&1 &
# or
setsid autopilot > /dev/null 2>&1 &

tail -f logs/autopilot-run.log
```

The choice costs nothing in logging. Every `AP:` line is appended to
`logs/autopilot-run.log` directly rather than by way of the terminal, so
discarding stdout entirely — as above — loses nothing, and the file is
complete even after the shell is gone.

Redirect stdout as shown: without it, `nohup` drops a `nohup.out` in the
project root, which then fails autopilot's clean-tree check. Running attached,
where the run would die with the terminal, is refused unless you set
`AUTOPILOT_ALLOW_NO_TMUX=1`.

See `autopilot --help` for the full contract: how steps are picked, branched,
verified and merged; usage-limit retry and resume behavior; log locations;
environment variables.

By default it looks for plan file `docs/plan.md`. 

### Plan file format

Steps must be markdown headings: `## Step N` or `### Step N.M` for sub-steps. A
finished one will be marked with `— **done**`. 
E.g., 
```
## Step 2 — Source registry and schema
...
### Step 2.1 - `storage/db.py` — one new column — **done**
...
```

The skill picks the first one that isn't marked done and implements only that step.
It marks it done if successfully implemented — see
`skills/plan-step-implementer/SKILL.md` for the full contract, including the
sentinel lines (`AUTOPILOT_STEP=`, `AUTOPILOT_BRANCH=`, `NO_PENDING_STEPS`,
`HUMAN_REVIEW_REQUIRED`) it reports back to `autopilot.sh`.

## Requirements

`claude` (Claude Code CLI), `jq`, and `timeout` (or `gtimeout` on macOS via
`brew install coreutils`) on `PATH`. 

This project was only tested on Linux. As of 2026-08-02 it has only been lightly tested.
