---
name: plan-step-implementer
description: Implements the next unfinished step in this project's plan file, marking it done when complete. Invoked by the autopilot script — not meant to trigger automatically during normal interactive work.
disable-model-invocation: true
---

`$ARGUMENTS` is the path to this project's plan file.

You are running unattended. Nobody can answer questions, so make reasonable,
conservative decisions and keep going — unless a rule below tells you to stop.

Network calls, paid API calls and publishing are allowed where the step needs
them.

**Keep this file lean.** When asked to edit it (interactive sessions only —
Rule 3 forbids it during a run), state what to do, never why. Add no rationale,
background, or justification. Length costs compliance.

## Workflow

Do these in order.

**1. Pick the step.** Read the plan file. Steps are headings numbered
`## Step N` or `### Step N.M`; a finished one ends in `— **done**`. Nothing
else in the file is a step. Take the first step that isn't done — but read the
surrounding prose first: if it gives an ordering or dependency reason ("2.5
moved first because..."), follow that over document order.

If every step is done, print `NO_PENDING_STEPS`, change nothing, and stop.

Print `AUTOPILOT_STEP=<N>` alone on its line, where `<N>` is the number from
the heading (`## Step N` or `### Step N.M` — either way just `N`, no `.M`).

**2. Branch.** Before editing anything:

```bash
git checkout -b "autopilot/$(date -u +%Y%m%d-%H%M%S)-<short-step-slug>"
```

Run `date` for real; don't write a timestamp from memory. The name must start
with `autopilot/`.

**3. Report the branch.** Confirm the checkout worked
(`git branch --show-current`), then print `AUTOPILOT_BRANCH=<branch-name>`
alone on its line, with nothing after it. If it failed, stop per Rule 4 —
without printing a branch line and without having changed any file.

**4. Implement exactly that one step.** Not the next one, not a neighboring
sub-step, and nothing beyond what the step's text describes.

**5. Verify.** Run `./run_tests.sh` once, after your edits are complete, and
make it pass. Fix and re-run as needed; don't run it speculatively between
edits.

**6. Mark it done.** Append `— **done**` to that step's heading, matching how
other finished headings in the file are written — including a `Completed
<date> <time>.` note if they carry one, dated from `date -u +%Y-%m-%d %H:%M:%S`. Touch no
other step's text or status, and never remove a `— **done**` that is already
there.

**7. Write the summary.** Add an `Implementation Summary` subsection one
heading level deeper than the step (`###` under `## Step N`, `####` under
`### Step N.M`), at the very end of that step's content — after its last sub-step,
before the next step's heading. A few sentences or short bullets:

- what changed (files, behavior), especially where you diverged from a
  literal reading of the step
- non-obvious decisions, and why
- issues you found and fixed along the way

Anything you found but left alone because fixing it would exceed this step's
scope goes in the plan's `## Open items` section instead, as a dated bullet
naming the step that surfaced it. Only add to that section; never edit or
resolve entries already in it.

## Rules

1. **One step per session**, even if a neighboring one looks related.

2. **No git beyond the one `git checkout -b`.** No `add`, `commit`, `merge`,
   `push`, `stash`, `reset`; no switching branches again. Read-only git
   (`status`, `diff`, `log`, `show`) is fine. This constrains your own git
   commands, not the project's code.

3. **Never edit `autopilot.sh`, `autopilot_notify.py` or this skill file.**
   If a step calls for it, stop per Rule 4.

4. **Stop when genuinely blocked** — the step is ambiguous in a way that
   changes the outcome, conflicts with existing code, or depends on something
   missing (a credential, a library decision, a prior step that wasn't
   actually done). Explain what's blocking you and what you'd need, print
   `HUMAN_REVIEW_REQUIRED`, and stop.

   Leave the changes you've already made in place; don't revert them. Don't
   mark the step done and don't write an Implementation Summary. A bullet in
   `## Open items` describing the blocker is welcome.

5. **Narrate plainly and briefly.** Say which step you picked (and why, if it
   wasn't simply the next one), what you did — files touched, assumptions
   made, anything a reviewer should look at twice. Facts only: no restating
   the plan's text, no progress commentary, no previewing what you're about to
   do. Your extended thinking and tool output are stripped from the log; this
   narration is all that survives.

   This narration streams straight into the run log with **no reformatting
   and no added line breaks** — the bytes you emit are the bytes that land in
   the log. Never write flowing prose or paragraphs. Every remark is its own
   bullet: a literal newline, then `- `, then one fact. Example, correct:

   ```
   - Picked Step 5: quote_location.py didn't exist yet.
   - Extracted transcript_cache.py so both modules share the loader.
   - Added QUOTE_MATCH_MIN_SIMILARITY; documented in README.
   ```

   Wrong (never do this — no bullets, no line break between remarks):
   `Now let's add the module. Good — settings already exist.`

## Token budget

Context is the run's scarcest resource — spending less of it here means more
steps complete before the usage window closes.

- Read only what the step needs. Prefer `grep`/`rg` with a pattern, or
  `sed -n 'A,Bp'`, over reading a large file whole.
- Never re-read a file you already read this session.
- Don't spawn subagents.
- Prefix commands with `rtk` where this project documents a filter for them
  (see CLAUDE.md) — `rtk test`, `rtk ruff`, `rtk git`, `rtk grep`.
- Don't paste file contents, diffs, or command output into your narration.

## Sentinels

| Line | Meaning |
|---|---|
| `NO_PENDING_STEPS` | every step in the file is already done |
| `AUTOPILOT_STEP=<N>` | the step heading number you picked |
| `AUTOPILOT_BRANCH=<name>` | the branch you created for this step |
| `HUMAN_REVIEW_REQUIRED` | blocked; stopping |

Print one alone on its own line — a blank line before it and a blank line
after it, nothing else sharing either of those lines, no prose, quotes, or
backticks around it — and only when you mean it. If two sentinels both apply
(e.g. `AUTOPILOT_STEP` then `AUTOPILOT_BRANCH`), put a blank line between
them too; never emit two back to back with no line break.

Never put one on a line by itself in any other situation, including inside a
code block, a quote, or an example of what you did. Mentioning one inside a
sentence is safe.
