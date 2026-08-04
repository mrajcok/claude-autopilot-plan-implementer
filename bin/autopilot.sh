#!/usr/bin/env bash
#
# autopilot.sh — run a project's plan file through Claude Code, one step at
# a time. See -h/--help for details.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: autopilot [-h|--help] [plan_file]

Run a project's plan file through Claude Code one step at a time, each in a
fresh context, committing after each successful step.

plan_file, if given, overrides the PLAN_FILE environment variable and the
default location.

Run this from your project's root directory (a git repo). Assumes:
  - a clean working tree — anything uncommitted when the run starts would be
    swept into the first step's commit by `git add -A`, so the run refuses
    to start
  - a single plan file (default docs/plan.md) documents every step, with
    each finished step/sub-step heading marked "— **done**"
  - a ./run_tests.sh that exits non-zero if the project is broken. It is run
    once before the first step — a base branch that is already failing would
    otherwise send every session off fixing unrelated breakage — and again
    before each commit. If it is missing, the run still proceeds but warns
    loudly, since nothing is verifying the work.
  - the plan-step-implementer skill is installed globally (run this tool's
    install.sh once — see its README)

Each fresh Claude session reads the plan file itself and decides which
undone step to work on next — this script doesn't track that. Sessions run
on AUTOPILOT_MODEL at AUTOPILOT_EFFORT (sonnet / medium by default), always
with --dangerously-skip-permissions, since it runs unattended with no one
available to approve tool calls.

Each step is done on its own branch, created by the Claude session itself
(it reports the name back via an AUTOPILOT_BRANCH=<name> line — if that's
missing, the run stops for human review). The name must be under autopilot/,
because that prefix is the only thing that lets the *next* run recognize an
abandoned step branch. On success this script commits on that branch, merges
it into whichever branch was checked out when the run started, and deletes
it. On a blocked step or a test failure, the branch is left checked out,
uncommitted, for you to inspect — so the next run refuses to start from an
autopilot/* branch rather than treating it as the base.

This script never runs `git push` itself. That is not the same as nothing
leaving the machine: a step whose plan text covers publishing or deployment
can push through the project's own code, and the skill permits that where a
step calls for it. Treat "did anything get published?" as something to check
in the run log, not assume.

A step is never committed if it modified autopilot.sh, autopilot_notify.py or
the plan-step-implementer skill — only relevant if you're running this tool
against its own repo, since otherwise none of those paths exist in the
project being worked on. The skill forbids editing them, but `git add -A`
would commit it regardless, and bash reads this script incrementally from
disk — an in-place rewrite can make the *running* interpreter execute
garbage mid-run.

A step is only committed if the session also marked its heading "— **done**"
in the plan file, and didn't un-mark any heading that was already done.
Without those checks a session that finished the work but forgot the marker
would be committed and merged, and the next session would read the same
unmarked plan and redo the same step, repeatedly.

Only headings that name a step count — "## Step 4" or "### Step 7.1" — so an
"### Implementation Summary" or any other prose heading can't satisfy the
gate by accident.

Logs: each step's filtered Claude output plus this script's own messages
(prefixed "AP:") go to logs/autopilot-step-<n>.log, streamed live as the step
runs — `tail -f` it to watch progress. The JSON stream goes to
logs/autopilot-step-<n>.raw.jsonl and Claude's stderr to
logs/autopilot-step-<n>.err (both written after the step finishes). <n> is
the next unused number, so no earlier log is ever overwritten. The logs
directory should be gitignored; the run warns if it isn't.

Every "AP:" line, including the run-level ones that belong to no step, is
also appended to logs/autopilot-run.log — one file per project, across runs.
That is the whole terminal transcript, so a detached run loses nothing when
its terminal goes away, and it is the file to `tail -f` to follow a run.

The run must outlive its terminal. tmux is the default way; to run detached
without it, set AUTOPILOT_ALLOW_NO_TMUX=1 and use nohup:
  AUTOPILOT_ALLOW_NO_TMUX=1 nohup autopilot > /dev/null 2>&1 &
  tail -f logs/autopilot-run.log

The archived .raw.jsonl has the per-token "stream_event" records stripped
out — they are ~99% of the bytes and their text is already in the .log. The
*unfiltered* stream is kept only for the duration of one attempt, in a temp
file, which is what usage-limit detection reads. Without this a 30-step run
leaves multiple GB in a directory you deliberately aren't watching.

Usage limits: if a step ends without creating a branch and without reporting
a verdict, this script checks the raw output for a rate_limit_event with
status "rejected" — an undocumented but observed part of the stream-json
output that includes the exact resetsAt time — and sleeps until then before
retrying. That wait is capped at MAX_LIMIT_SLEEP_SECONDS, and is refused
outright if it would run past the MAX_RUN_SECONDS budget. A resetsAt more
than LIMIT_SANITY_MAX_SECONDS out (or well in the past) is not trusted at
all — that field silently switching to milliseconds would otherwise turn
into a capped 6h sleep that looks deliberate — so it falls back to a blind
wait instead. It also falls back to a blind LIMIT_RETRY_WAIT_SECONDS sleep
when no event is found but the session's stderr or its final result message
still looks limit-related. Either way it retries up to MAX_LIMIT_RETRIES
times before giving up. Long waits sleep in short increments so Ctrl-C and
the run budget are still honoured mid-wait.

A limit hit *after* the session branched is the common case, since the skill
branches before doing any work. If that branch is empty — clean tree, still
pointing at the base commit — there is nothing to lose, so the branch is
deleted and the step retried like any other limit hit. Otherwise this script
does not guess: it stops for review rather than risk abandoning partial work.

Email: when the run ends for any reason — finished, stopped for review,
interrupted — a plain-text summary is sent via autopilot_notify.py, which
reads EMAIL_ENABLED / SMTP_HOST / SMTP_PORT / SMTP_USER / SMTP_PASSWORD /
EMAIL_FROM / EMAIL_TO from the environment, then this tool's own config file
(see its README) — never from the project being worked on. With
EMAIL_ENABLED unset or false nothing is sent, and a mail failure never fails
the run.

Token use: the session's reasoning effort is the largest single consumer, so
AUTOPILOT_EFFORT is the knob to reach for when you want more steps out of one
usage window. --verbose in the invocation below is *not* a token cost: it
controls what the local CLI prints to stdout, and stream-json requires it —
removing it would drop the sentinels this script parses.

Run it inside tmux so it survives your SSH session ending:
  tmux new -s autopilot
  autopilot
  [Ctrl-b then d to detach; `tmux attach -t autopilot` to check on it]

Environment variables:
  PLAN_FILE             Path to the plan file (default: docs/plan.md).
                        Prompted for interactively if it doesn't exist.
                        Overridden by plan_file if given on the command
                        line.
  AUTOPILOT_MODEL       Model each step's session runs on (default: sonnet).
                        An alias ('sonnet', 'opus', 'fable') or a full name
                        like 'claude-sonnet-5'. Passed straight to
                        `claude --model`. Not validated here — a bad name
                        fails the first step, which stops the run and mails
                        you the error.
  AUTOPILOT_EFFORT      Reasoning effort for each session — low, medium,
                        high, xhigh or max (default: medium). Passed straight
                        to `claude --effort`. This is the main lever on how
                        many steps fit in a usage window: higher effort buys
                        deeper reasoning per step and fewer steps per window.
                        Set it to the empty string to pass no --effort at
                        all, so each session reasons at whatever effortLevel
                        your Claude Code settings specify.
  AUTOPILOT_FALLBACK_MODEL
                        Comma-separated models to fall back to when the
                        primary is overloaded (default: none). Passed to
                        `claude --fallback-model` when that flag exists.
  AUTOPILOT_MAX_BUDGET_USD
                        Per-session spend cap, passed to
                        `claude --max-budget-usd` (default: none). Applies to
                        API-key billing; on a subscription it is a no-op.
  MAX_STEPS             Safety cap on steps completed per run of this
                        script (default: 3).
  MAX_RUN_SECONDS       Wall-clock budget for the whole run (default:
                        43200, i.e. 12h). No new step is started once it is
                        spent, and no usage-limit sleep is allowed to run
                        past it. Set to 0 to disable.
  STEP_TIMEOUT_SECONDS  Kill a single Claude session that runs this long
                        (default: 3600, i.e. 1h) and stop for review. A
                        wedged session would otherwise park the run
                        indefinitely.
  TEST_TIMEOUT_SECONDS  Same, for one ./run_tests.sh invocation (default:
                        1800, i.e. 30m).
  SKIP_BASELINE_TESTS   Set to 1 to skip the pre-run ./run_tests.sh check on
                        the base branch (default: 0). Only useful when you
                        already know the base is red and want to proceed.
  MAX_LIMIT_RETRIES     Consecutive suspected usage-limit hits to tolerate
                        on one step before giving up (default: 12).
  LIMIT_RETRY_WAIT_SECONDS
                        Fallback sleep before retrying when a usage-limit
                        hit is suspected but no exact resetsAt time was
                        found in the output (default: 1800, i.e. 30m).
                        When resetsAt *is* found, the script sleeps until
                        that time instead.
  MAX_LIMIT_SLEEP_SECONDS
                        Upper bound on any single usage-limit sleep
                        (default: 21600, i.e. 6h). MAX_RUN_SECONDS is what
                        bounds them in aggregate.
  LIMIT_SANITY_MAX_SECONDS
                        How far in the future a reported resetsAt may be and
                        still be believed (default: 86400, i.e. 24h). Beyond
                        that — or more than 5 minutes in the past — the value
                        is treated as unparseable and the blind wait is used.
  EMAIL_LOG_LINES       Lines from the tail of the last step log to include
                        in the summary email (default: 40).
  AUTOPILOT_ALLOW_NO_TMUX
                        Set to 1 to run outside tmux (default: 0, refuse).
                        The run still has to outlive its terminal — use
                        nohup or setsid. logs/autopilot-run.log keeps the
                        full transcript either way.
  AUTOPILOT_NO_RESUME   Set to 1 to refuse to start when an autopilot/*
                        step branch is checked out (default: 0, which picks
                        that interrupted step back up). A branch whose step
                        printed HUMAN_REVIEW_REQUIRED is never resumed
                        regardless.
  AUTOPILOT_BASE_BRANCH Branch an interrupted step branch was cut from, used
                        only when resuming one. Default: detected as the
                        nearest local non-autopilot ancestor branch.
EOF
}

for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
  esac
done

PLAN_FILE="${1:-${PLAN_FILE:-docs/plan.md}}"
LOG_DIR="logs"

# This script and autopilot_notify.py are installed (symlinked, typically)
# somewhere on PATH — resolve back to where they actually live so the
# notifier can be found regardless of which project's directory we're run
# from. readlink -f follows the install.sh symlink to the real file.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
NOTIFY_BIN="$SCRIPT_DIR/autopilot_notify.py"

# The skill this drives is installed globally (see install.sh), not inside
# whatever project is being worked on — it has to be, since `claude -p` looks
# it up by name regardless of which project's directory we're run from.
SKILL_NAME="plan-step-implementer"
SKILL_INSTALL_PATH="$HOME/.claude/skills/$SKILL_NAME/SKILL.md"

# This tool's own files, as paths relative to whatever project is being
# worked on. They only resolve to something real when that project is this
# tool's own repo (i.e. you're using autopilot on itself) — everywhere else
# these paths simply don't exist, so the harness guard below is a no-op.
SELF_FILE="bin/autopilot.sh"
NOTIFY_SELF_FILE="bin/autopilot_notify.py"
SKILL_SELF_FILE="skills/$SKILL_NAME/SKILL.md"
# Kept outside the repo: a lock file inside it would be swept up by the
# `git add -A` below and committed.
LOCK_FILE="${TMPDIR:-/tmp}/autopilot-$(printf '%s' "$PWD" | cksum | cut -d' ' -f1).lock"
AUTOPILOT_MODEL="${AUTOPILOT_MODEL:-sonnet}"
# Set explicitly to empty to pass no --effort at all, letting a step's session
# reason at whatever effortLevel your Claude Code settings specify.
AUTOPILOT_EFFORT="${AUTOPILOT_EFFORT-medium}"
AUTOPILOT_FALLBACK_MODEL="${AUTOPILOT_FALLBACK_MODEL:-}"
AUTOPILOT_MAX_BUDGET_USD="${AUTOPILOT_MAX_BUDGET_USD:-}"
MAX_STEPS="${MAX_STEPS:-5}"   # safety cap so a bad run can't run forever; increase once we prove out this script and the skill
MAX_RUN_SECONDS="${MAX_RUN_SECONDS:-43200}"                     # 12h
STEP_TIMEOUT_SECONDS="${STEP_TIMEOUT_SECONDS:-3600}"            # 1h
TEST_TIMEOUT_SECONDS="${TEST_TIMEOUT_SECONDS:-1800}"            # 30m
SKIP_BASELINE_TESTS="${SKIP_BASELINE_TESTS:-0}"
MAX_LIMIT_RETRIES="${MAX_LIMIT_RETRIES:-12}"
LIMIT_RETRY_WAIT_SECONDS="${LIMIT_RETRY_WAIT_SECONDS:-1800}"    # 30m
MAX_LIMIT_SLEEP_SECONDS="${MAX_LIMIT_SLEEP_SECONDS:-21600}"     # 6h
LIMIT_SANITY_MAX_SECONDS="${LIMIT_SANITY_MAX_SECONDS:-86400}"   # 24h
EMAIL_LOG_LINES="${EMAIL_LOG_LINES:-40}"
# How far a reported resetsAt may lag "now" before it reads as stale rather
# than as a real (already-expired) limit.
LIMIT_SANITY_PAST_SECONDS=300

EFFORT_DESC="${AUTOPILOT_EFFORT:-inherited from your Claude Code settings}"

# Only ever matched against Claude's stderr and its final result message —
# never against the model's own narration, which in a project like this one
# routinely discusses rate limiting and would otherwise self-trigger.
# 'session limit' and the bare 'resets <time>' form are both from a real
# exhaustion message: "You've hit your session limit · resets 11:30pm
# (America/New_York)" — which the earlier 'resets at' alternative did not match.
LIMIT_TEXT_RE='usage limit|rate limit|session limit|limit reached|quota exceeded|too many requests|out of credits|resets? (at )?[0-9]'

# A heading only counts as a finished step if it *names* a step: "## Step 4"
# or "### Step 7.1". Plan files carry plenty of other headings — Implementation
# Summary, Scope, Not in scope — and one of those picking up a "**done**"
# marker must not be able to satisfy the commit gate.
DONE_HEADING_RE='^#+ +Step +[0-9]+(\.[0-9]+)?\b.*\*\*done\*\*'

# Set once $LOG_DIR is known to exist (below). Until then these lines can only
# go to the terminal — nothing before that point has anywhere to write.
RUN_LOG=""

# Top-level messages, not tied to a specific step. They go to the terminal
# *and* to the run log: with the run detached (tmux, nohup) the terminal may be
# gone by the time anyone looks, and these lines — the run banner, the baseline
# check, limit sleeps, the final summary — appear in no per-step log.
say() {
  local line
  line="AP: $(date '+%Y-%m-%d %H:%M:%S') | $*"
  echo "$line"
  [[ -n "$RUN_LOG" ]] && echo "$line" >> "$RUN_LOG"
  return 0
}

# GNU date wants -d @<epoch>, BSD/macOS date wants -r <epoch>.
fmt_epoch() {
  date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
    || date -r "$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
    || echo "epoch $1"
}

# Sleep to an absolute epoch in short hops. A single long `sleep` would hold
# off the TERM/HUP trap for its whole duration — up to MAX_LIMIT_SLEEP_SECONDS
# — so killing the tmux session during a limit wait would leave this script and
# its lock alive for hours.
sleep_until() {
  local target=$1 now left
  while :; do
    now=$(date +%s)
    (( now >= target )) && break
    left=$(( target - now ))
    (( left > 30 )) && left=30
    sleep "$left"
  done
}

# The requirement is that the run outlive the terminal, not tmux specifically.
# nohup/setsid do that too, and are easier to page through afterwards — the run
# log holds everything the terminal would have shown. Opting out is explicit so
# that simply forgetting tmux still fails loudly.
if [[ -z "${TMUX:-}" ]]; then
  if [[ "${AUTOPILOT_ALLOW_NO_TMUX:-0}" == "1" ]]; then
    say "Not inside tmux; running anyway (AUTOPILOT_ALLOW_NO_TMUX=1). Make sure this survives the terminal — e.g. 'nohup autopilot ... &'."
  else
    say "ERROR: not running inside tmux. If this shell dies (e.g. your SSH session drops), the run stops with it."
    say "Either: tmux new -s autopilot   — then re-run this script inside that session."
    say "Or, to run detached without tmux:"
    say "  AUTOPILOT_ALLOW_NO_TMUX=1 nohup autopilot > /dev/null 2>&1 &"
    say "  tail -f $LOG_DIR/autopilot-run.log"
    exit 1
  fi
fi

if ! command -v claude >/dev/null 2>&1; then
  say "ERROR: 'claude' is not on PATH. Install Claude Code, or start the shell that has it, then re-run."
  exit 1
fi

case "$AUTOPILOT_EFFORT" in
  ""|low|medium|high|xhigh|max) ;;
  *)
    say "ERROR: AUTOPILOT_EFFORT must be empty (inherit your Claude Code setting) or one of low, medium, high, xhigh, max (got '$AUTOPILOT_EFFORT')."
    exit 1
    ;;
esac

# Checked once here rather than discovered when step 1 dies with "unknown
# option" mid-run. --include-partial-messages and --output-format matter as
# much as the others: the sentinels this script parses only exist because of
# them, and a CLI that stopped emitting them would read as "the session did
# nothing" on every step.
claude_help="$(claude --help 2>&1)"
has_flag() { grep -qE -- "(^|[[:space:],])$1([[:space:],=]|$)" <<<"$claude_help"; }
for flag in --model --effort --print --output-format --include-partial-messages --dangerously-skip-permissions; do
  if ! has_flag "$flag"; then
    say "ERROR: this Claude Code ($(claude --version 2>/dev/null)) has no '$flag' option. Upgrade it, or edit the invocation below."
    exit 1
  fi
done

# Optional flags, each used only if this CLI has it, so an older or newer
# Claude Code doesn't hard-fail the run over a nicety.
claude_extra_flags=()
if has_flag --exclude-dynamic-system-prompt-sections; then
  # Moves cwd/env/git-status out of the system prompt, so the cached prefix is
  # identical across steps instead of being invalidated by every commit. Pure
  # win here: every session runs in the same directory on the same project.
  claude_extra_flags+=(--exclude-dynamic-system-prompt-sections)
fi
if [[ -n "$AUTOPILOT_FALLBACK_MODEL" ]]; then
  if has_flag --fallback-model; then
    claude_extra_flags+=(--fallback-model "$AUTOPILOT_FALLBACK_MODEL")
  else
    say "WARNING: AUTOPILOT_FALLBACK_MODEL is set but this Claude Code has no --fallback-model. Ignoring it."
  fi
fi
if [[ -n "$AUTOPILOT_MAX_BUDGET_USD" ]]; then
  if has_flag --max-budget-usd; then
    claude_extra_flags+=(--max-budget-usd "$AUTOPILOT_MAX_BUDGET_USD")
  else
    say "WARNING: AUTOPILOT_MAX_BUDGET_USD is set but this Claude Code has no --max-budget-usd. Ignoring it."
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  say "ERROR: jq is required (used to filter Claude's output down to plain text, dropping thinking/tool detail)."
  say "Install it, e.g. 'apt install jq' or 'brew install jq', then re-run."
  exit 1
fi

# A hung session or a hung test suite would otherwise silently consume the
# whole run, so both children are wrapped in timeout when it's available.
TIMEOUT_BIN=""
for candidate in timeout gtimeout; do
  if command -v "$candidate" >/dev/null 2>&1; then
    TIMEOUT_BIN="$candidate"
    break
  fi
done
if [[ -z "$TIMEOUT_BIN" ]]; then
  say "WARNING: no 'timeout' (or 'gtimeout') on PATH — a wedged Claude session or test run can park this script indefinitely."
  say "On macOS: brew install coreutils."
  step_timeout=()
  test_timeout=()
else
  step_timeout=("$TIMEOUT_BIN" -k 30 "$STEP_TIMEOUT_SECONDS")
  test_timeout=("$TIMEOUT_BIN" -k 30 "$TEST_TIMEOUT_SECONDS")
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  say "ERROR: not inside a git repository. Run this from your project root."
  exit 1
fi

# Opened as early as the repo is confirmed, so the startup phase — base-branch
# detection, the resume decision, the baseline test run — is on disk too. One
# appended file across runs: it is the thing to `tail -f`, and the thing to
# read after a detached run ends.
mkdir -p "$LOG_DIR"
RUN_LOG="$LOG_DIR/autopilot-run.log"
{
  echo
  echo "=== autopilot run started $(date '+%Y-%m-%d %H:%M:%S') (pid $$) in $PWD ==="
} >> "$RUN_LOG"

if [[ ! -f "$SKILL_INSTALL_PATH" ]]; then
  say "ERROR: $SKILL_INSTALL_PATH not found — that skill is what actually implements each step."
  say "Run install.sh in the claude-autopilot-plan-implementer repo first."
  exit 1
fi

BASE_BRANCH="$(git branch --show-current)"
if [[ -z "$BASE_BRANCH" ]]; then
  say "ERROR: not currently on a branch (detached HEAD?). Check out the branch you want steps merged into and re-run."
  exit 1
fi

# The branch an autopilot/* step branch was cut from: the nearest local
# non-autopilot branch that is an ancestor of it. Ties (several branches at the
# same commit, the usual case since a step branch starts level with its base)
# go to the conventional default names before anything else.
detect_base_branch() {
  local head="$1" b best="" nb nbest
  while read -r b; do
    [[ -z "$b" || "$b" == autopilot/* ]] && continue
    git merge-base --is-ancestor "$b" "$head" 2>/dev/null || continue
    if [[ -z "$best" ]]; then
      best="$b"
      continue
    fi
    nb=$(git rev-list --count "$b..$head" 2>/dev/null || echo 999999)
    nbest=$(git rev-list --count "$best..$head" 2>/dev/null || echo 999999)
    if (( nb < nbest )); then
      best="$b"
    elif (( nb == nbest )) && [[ "$best" != main && "$best" != master ]] \
         && [[ "$b" == main || "$b" == master ]]; then
      best="$b"
    fi
  done < <(git for-each-ref --format='%(refname:short)' refs/heads/)
  printf '%s' "$best"
}

# A step branch left checked out is a step that was interrupted — a usage limit
# that outlasted the run budget, a stopped-for-review, or a killed run. Starting
# a fresh run from here would quietly make that abandoned branch the merge
# target for everything after it, so it is never simply used as the base.
#
# Instead the run picks that step back up: the partial work is committed to its
# own branch, the real base is checked out, and the first step of this run
# resumes that branch rather than starting the step over. Set
# AUTOPILOT_NO_RESUME=1 for the old behaviour of refusing to start.
STARTUP_RESUME_BRANCH=""
STARTUP_RESUME_STEP=""
if [[ "$BASE_BRANCH" == autopilot/* ]]; then
  if [[ "${AUTOPILOT_NO_RESUME:-0}" == "1" ]]; then
    say "ERROR: currently on '$BASE_BRANCH', which looks like an abandoned autopilot step branch."
    say "A previous run probably stopped for review here. Inspect it, then check out your real base branch (e.g. 'git checkout main') and re-run."
    exit 1
  fi
  STARTUP_RESUME_BRANCH="$BASE_BRANCH"
  BASE_BRANCH="${AUTOPILOT_BASE_BRANCH:-$(detect_base_branch "$STARTUP_RESUME_BRANCH")}"
  if [[ -z "$BASE_BRANCH" ]]; then
    say "ERROR: currently on '$STARTUP_RESUME_BRANCH', an autopilot step branch, and I can't tell which branch it was cut from."
    say "Check out your real base branch (e.g. 'git checkout main') and re-run, or set AUTOPILOT_BASE_BRANCH."
    exit 1
  fi
  if ! git rev-parse -q --verify "refs/heads/$BASE_BRANCH" >/dev/null 2>&1; then
    say "ERROR: AUTOPILOT_BASE_BRANCH='$BASE_BRANCH' is not a local branch."
    exit 1
  fi

  # The interrupted step's own logs are still on disk, and they name the branch
  # they were working on — which is exactly the branch being resumed. Found
  # before anything is committed, because what that log says decides whether
  # this run may proceed at all.
  #
  # Matched on the sentinel the earlier session printed rather than on any
  # bookkeeping file this script writes: it needs no new state, and it works on
  # logs written before this resume path existed.
  prior_log=""
  if [[ -d "$LOG_DIR" ]]; then
    prior_log="$(grep -lF "AUTOPILOT_BRANCH=$STARTUP_RESUME_BRANCH" \
                   "$LOG_DIR"/autopilot-step-*.log 2>/dev/null \
                 | xargs -r ls -1t 2>/dev/null | head -n1)"
  fi

  # Not every step branch left checked out is one to pick back up. A step that
  # printed HUMAN_REVIEW_REQUIRED stopped *on purpose* and asked for a human;
  # the checked-out branch is how it blocks the next run. Auto-resuming that
  # would silently overrule the request, so the refusal stands — and being able
  # to name the blocker beats the old generic "abandoned branch" message.
  if [[ -n "$prior_log" ]] \
     && grep -qE '^[[:space:]]*HUMAN_REVIEW_REQUIRED[[:space:]]*$' "$prior_log"; then
    say "ERROR: currently on '$STARTUP_RESUME_BRANCH', where a step stopped and asked for human review — it is not an interrupted step to resume."
    say "What blocked it is in $prior_log. Review the branch, then check out your base branch (e.g. 'git checkout $BASE_BRANCH') and re-run."
    exit 1
  fi

  say "Found an interrupted step on '$STARTUP_RESUME_BRANCH' (base branch looks like '$BASE_BRANCH')."
  if [[ -n "$prior_log" ]]; then
    prior_num="$(basename "$prior_log")"
    prior_num="${prior_num#autopilot-step-}"
    prior_num="${prior_num%.log}"
    # Appending keeps one step's two halves in one file. Otherwise the run
    # claims the next free slot, and the rename-on-AUTOPILOT_STEP logic then
    # pushes the first half aside as ".stale-<ts>" — which it is not; it is the
    # front half of this same step.
    if [[ "$prior_num" =~ ^[0-9]+$ ]]; then
      STARTUP_RESUME_STEP="$prior_num"
      say "That step logged to $prior_log — this run appends to it rather than opening a new one."
    fi
  else
    say "NOTE: found no earlier log naming that branch, so this run opens a fresh step log."
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    say "Committing its uncommitted work to that branch so this run can resume it:"
    git status --short
    if ! git add -A || ! git commit -m "Autopilot WIP (interrupted step, resumed by a later run)"; then
      say "ERROR: couldn't commit the partial work on '$STARTUP_RESUME_BRANCH'. Sort it out by hand, then re-run."
      exit 1
    fi
  else
    say "Its work is already committed."
  fi
  if ! git checkout "$BASE_BRANCH"; then
    say "ERROR: couldn't check out '$BASE_BRANCH'. Sort it out by hand, then re-run."
    exit 1
  fi
  say "This run's first step will resume '$STARTUP_RESUME_BRANCH' instead of starting a new step."
fi

# A merge this script failed to complete leaves conflict markers on the base
# branch — which is *not* an autopilot/* branch, so the guard above misses
# it. Starting a new run there would `git add -A` those markers into a step
# commit.
if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  say "ERROR: a merge is in progress on '$BASE_BRANCH' — a previous run's merge probably conflicted."
  say "Resolve or abort it ('git merge --abort'), then re-run."
  exit 1
fi

# Every step is committed with `git add -A`, so anything already dirty would
# ride along into the first step's commit and get merged into the base branch.
if [[ -n "$(git status --porcelain)" ]]; then
  say "ERROR: the working tree isn't clean. Autopilot commits with 'git add -A', so uncommitted work would be swept into a step's commit."
  say "If you didn't leave these: a previous run may have stopped for review before its session got as far as branching, leaving the step's partial work here on '$BASE_BRANCH'. Check the newest logs/autopilot-step-*.log."
  say "Commit, stash, or discard your changes, then re-run. Current status:"
  git status --short
  exit 1
fi

if [[ ! -f "$PLAN_FILE" ]]; then
  say "Plan file '$PLAN_FILE' not found."
  read -r -p "AP: Enter the plan file's path, relative to the project root: " PLAN_FILE
  if [[ ! -f "$PLAN_FILE" ]]; then
    say "ERROR: '$PLAN_FILE' does not exist. Aborting."
    exit 1
  fi
fi

if [[ ! -x "./run_tests.sh" ]]; then
  say "WARNING: no executable ./run_tests.sh — nothing will verify a step before it is committed and merged."
fi

# Refuse to run two autopilots against the same working tree. A lock left by
# a killed run (tmux kill-session sends SIGHUP) is taken over rather than
# blocking the next run entirely.
if ! ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
  lock_pid="$(cat "$LOCK_FILE" 2>/dev/null)"
  if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
    say "ERROR: another autopilot (pid $lock_pid) is already running against this working tree."
    say "If that's wrong, remove the lock: rm $LOCK_FILE"
    exit 1
  fi
  say "WARNING: stale lock $LOCK_FILE (pid ${lock_pid:-unknown} is not running). Taking it over."
  echo "$$" > "$LOCK_FILE"
fi

SCRATCH_DIR="$(mktemp -d)"

RUN_START=$(date +%s)
run_deadline=$(( RUN_START + MAX_RUN_SECONDS ))
steps_run=0
retry_pending=0
# Set when a step that had already branched was interrupted — by a usage limit
# mid-run, or by an earlier run that ended with the branch still checked out.
# The next step resumes that branch instead of starting the step over.
resume_branch="$STARTUP_RESUME_BRANCH"
limit_hits=0
step_log=""
raw_log=""
err_log=""
step_num=0
step_num_confirmed=0
finish_reason=""
stopped_for_review=0
email_sent=0
completed_steps=()
completed_step_nums=()

# Folds a list of step numbers into "5-9" / "5,7-9" style ranges, for the
# email subject.
format_step_range() {
  local sorted start prev n ranges=()
  mapfile -t sorted < <(printf '%s\n' "$@" | sort -n)
  start=${sorted[0]}
  prev=$start
  for n in "${sorted[@]:1}"; do
    if (( n == prev + 1 )); then
      prev=$n
      continue
    fi
    ranges+=("$([[ $start == "$prev" ]] && echo "$start" || echo "$start-$prev")")
    start=$n
    prev=$n
  done
  ranges+=("$([[ $start == "$prev" ]] && echo "$start" || echo "$start-$prev")")
  local IFS=,
  echo "${ranges[*]}"
}

# Summarize the run and mail it. Called from the exit path and from the signal
# traps, so it has to be safe to call twice.
send_run_email() {
  (( email_sent )) && return 0
  email_sent=1
  [[ -x "$NOTIFY_BIN" ]] || return 0

  local outcome="$1" elapsed subject body
  elapsed=$(( $(date +%s) - RUN_START ))

  local steps_desc
  if (( ${#completed_step_nums[@]} == 0 )); then
    steps_desc="0 steps"
  elif (( ${#completed_step_nums[@]} == 1 )); then
    steps_desc="step ${completed_step_nums[0]}"
  else
    steps_desc="steps $(format_step_range "${completed_step_nums[@]}")"
  fi
  subject="[autopilot] $(basename "$PWD"): ${outcome} — ${steps_desc}"
  {
    echo "Project:   $(basename "$PWD") ($PWD)"
    echo "Plan file: $PLAN_FILE"
    echo "Base:      $BASE_BRANCH"
    echo "Model:     $AUTOPILOT_MODEL (effort $EFFORT_DESC)"
    echo "Started:   $(fmt_epoch "$RUN_START")"
    echo "Ended:     $(fmt_epoch "$(date +%s)")  (${elapsed}s)"
    echo "Outcome:   $outcome"
    echo
    if (( ${#completed_steps[@]} )); then
      echo "Steps committed and merged into $BASE_BRANCH:"
      printf '  - %s\n' "${completed_steps[@]}"
    else
      echo "No steps were committed."
    fi
    echo
    if [[ -n "$finish_reason" ]]; then
      echo "Why it ended:"
      echo "  $finish_reason"
      echo
    fi
    echo "Working tree now: $(git branch --show-current 2>/dev/null || echo '?')"
    local dirty
    dirty="$(git status --short 2>/dev/null)"
    if [[ -n "$dirty" ]]; then
      echo "Uncommitted changes are present:"
      printf '%s\n' "$dirty" | sed 's/^/  /'
    else
      echo "Working tree is clean."
    fi
    echo
    echo "Nothing was pushed by autopilot itself. If a step exercised the"
    echo "publisher or a deploy path, check the log below for what it did."
    echo
    if [[ -n "$step_log" && -f "$step_log" ]]; then
      echo "Last ${EMAIL_LOG_LINES} lines of $step_log:"
      echo "----------------------------------------------------------------"
      tail -n "$EMAIL_LOG_LINES" "$step_log"
    fi
  } > "$SCRATCH_DIR/email-body.txt" 2>/dev/null

  body="$SCRATCH_DIR/email-body.txt"
  if [[ -n "$step_log" && -f "$step_log" ]]; then
    "$NOTIFY_BIN" "$subject" < "$body" >> "$step_log" 2>&1
  else
    "$NOTIFY_BIN" "$subject" < "$body"
  fi
}

cleanup() {
  rm -f "$LOCK_FILE"
  rm -rf "$SCRATCH_DIR"
}

# `timeout` (without --foreground, which we deliberately don't pass — see the
# "readers die with the writer" note below) puts COMMAND in a process group
# of its own specifically so it does NOT get TTY signals like Ctrl-C's
# SIGINT. That's what lets `timeout` alone manage the kill on expiry, but it
# also means Ctrl-C aimed at this script never reaches Claude or its
# pipeline on its own. run_interruptible backgrounds the timeout-wrapped
# command, records both its pid and its child's pgid, and `wait`s — a
# trapped signal interrupts `wait` immediately, unlike a foreground command,
# where bash defers the trap until the command returns. kill_running (called
# from the traps below) then kills that recorded pgid directly.
running_timeout_pid=""
running_child_pgid=""

run_interruptible() {
  "$@" &
  running_timeout_pid=$!
  # The child hasn't been forked+exec'd the instant $! is captured; give it
  # a moment to show up so kill_running has a pgid to target right away.
  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    running_child_pgid="$(pgrep -P "$running_timeout_pid" 2>/dev/null | head -n1)"
    [[ -n "$running_child_pgid" ]] && break
    sleep 0.1
  done
  wait "$running_timeout_pid"
  local status=$?
  running_timeout_pid=""
  running_child_pgid=""
  return "$status"
}

kill_running() {
  [[ -n "$running_child_pgid" ]] && kill -TERM -- "-$running_child_pgid" 2>/dev/null
  [[ -n "$running_timeout_pid" ]] && kill -TERM "$running_timeout_pid" 2>/dev/null
}

# EXIT alone doesn't fire on an untrapped SIGTERM/SIGHUP, which is exactly how
# this script dies when a tmux session is killed. The stale-lock takeover
# above is the backstop for whatever slips through kill_running.
trap cleanup EXIT
trap 'finish_reason="interrupted (Ctrl-C)"; kill_running; send_run_email interrupted; cleanup; exit 130' INT
trap 'finish_reason="terminated by signal"; kill_running; send_run_email interrupted; cleanup; exit 143' TERM HUP

attempt_text="$SCRATCH_DIR/attempt.txt"
attempt_raw="$SCRATCH_DIR/attempt.jsonl"
attempt_err="$SCRATCH_DIR/attempt.err"
attempt_status="$SCRATCH_DIR/attempt.status"
done_before="$SCRATCH_DIR/done-before.txt"
done_after="$SCRATCH_DIR/done-after.txt"

# jq programs live in files so the pipeline can stay legible inside the
# `bash -c` wrapper below, which is already one level of quoting deep.
#
# All of these read with -R and parse per line via `fromjson?`: jq exits
# (status 5) on the first malformed line otherwise, discarding everything
# after it — and a stream truncated mid-line is exactly what killing Claude
# produces. Losing the tail of the stream means losing the sentinels and the
# AUTOPILOT_BRANCH line, which this script then misreads as "did nothing".
#
# The text is emitted with jq -j (no separator), so consecutive assistant
# messages would otherwise concatenate with nothing between them: an assistant
# turn's text never ends in a newline (trailing whitespace is stripped at
# message end), and the skill's narration is split across many turns by its
# tool calls. That is what produced log lines like
# "...conversation flow.AUTOPILOT_STEP=9AUTOPILOT_BRANCH=autopilot/...".
# No skill instruction can fix it — the model *did* print each sentinel alone
# on its line, in three separate messages. message_stop marks each of those
# boundaries, so emit the paragraph break there.
#
# Run with -n so `inputs` drives the loop: the separator is only emitted for a
# message that actually produced text, so the many text-less messages (a turn
# that only calls a tool) don't stack up runs of blank lines in the log.
text_filter="$SCRATCH_DIR/text-delta.jq"
cat > "$text_filter" <<'EOF'
foreach inputs as $line ({emit: "", intext: false};
  ($line | fromjson?) as $e
  | if $e == null or $e.type != "stream_event" then
      {emit: "", intext: .intext}
    elif $e.event.delta.type? == "text_delta" then
      {emit: $e.event.delta.text, intext: true}
    elif $e.event.type == "message_stop" and .intext then
      {emit: "\n\n", intext: false}
    else
      {emit: "", intext: .intext}
    end;
  .emit)
EOF

# Fallback for when no partial-message events arrived at all: pull the text
# straight off the completed assistant messages. Same content, one message at
# a time instead of one token at a time.
whole_text_filter="$SCRATCH_DIR/whole-text.jq"
cat > "$whole_text_filter" <<'EOF'
fromjson?
| select(.type == "assistant")
| .message.content[]?
| select(.type == "text")
| .text
EOF

# Passes every line through unchanged except the per-token stream_event
# records, whose text is already in the .log. Malformed lines are kept:
# they're the interesting ones when something went wrong.
archive_filter="$SCRATCH_DIR/archive.jq"
cat > "$archive_filter" <<'EOF'
if (try (fromjson | .type) catch "") == "stream_event" then empty else . end
EOF

# Probed with a filename rather than the bare directory: check-ignore reports
# a directory as un-ignored when it holds a tracked file (logs/.gitkeep).
if ! git check-ignore -q "$LOG_DIR/autopilot-probe.log" 2>/dev/null; then
  say "WARNING: '$LOG_DIR/' is not gitignored — 'git add -A' will commit this run's logs along with each step."
  say "Add '$LOG_DIR/' to .gitignore."
fi

# writes an AP-prefixed line to the current step's log AND the terminal
ap() {
  local line
  line="AP: $(date '+%Y-%m-%d %H:%M:%S') | $*"
  echo "$line"
  [[ -n "$RUN_LOG" ]] && echo "$line" >> "$RUN_LOG"
  [[ -n "$step_log" ]] && echo "$line" >> "$step_log"
  return 0
}

# Logs the 5h rolling-window usage percentage after a step, so a run's log
# shows how much of the current window each step cost. `/usage` is a
# metadata query, not a model turn — it reports 0 cost and 0 tokens — so
# this doesn't itself eat into the window it's reporting on. Best-effort:
# a parse or CLI failure here must never fail the step it's reporting on.
report_usage_pct() {
  local usage_json pct
  usage_json="$(timeout 30 claude -p "/usage" --output-format json 2>/dev/null)"
  pct="$(printf '%s' "$usage_json" \
           | jq -r '.result // ""' 2>/dev/null \
           | sed -nE 's/.*Current session: ([0-9]+)% used.*/\1/p')"
  [[ -n "$pct" ]] && ap "5h token spend: ${pct}%"
}

# ap() plus "this is why the run ended", for the summary email. First reason
# wins: it's the one that actually stopped things. Only this marks a run as
# needing review — reaching MAX_STEPS or the time budget also ends the loop,
# but those are the run working as configured, and a subject line that cried
# "stopped" for them would train you to ignore the ones that matter.
stop() {
  ap "$*"
  [[ -n "$finish_reason" ]] || finish_reason="$*"
  stopped_for_review=1
  return 0
}

# The base branch has to be green before the first step. If it isn't, every
# session will run into the same pre-existing failure at its Verify stage and
# either burn the step trying to fix unrelated code or trip the commit gate —
# and the run log will read as though the step broke something.
if [[ -x "./run_tests.sh" ]] && (( ! SKIP_BASELINE_TESTS )); then
  say "Checking that '$BASE_BRANCH' is green before starting (./run_tests.sh)..."
  baseline_log="$LOG_DIR/autopilot-baseline.log"
  : > "$baseline_log"
  run_interruptible "${test_timeout[@]}" ./run_tests.sh >> "$baseline_log" 2>&1
  baseline_exit=$?
  if (( baseline_exit != 0 )); then
    say "ERROR: ./run_tests.sh fails on '$BASE_BRANCH' before any step has run (exit $baseline_exit)."
    say "Autopilot would send every session into the same failure. Fix the base branch, or set SKIP_BASELINE_TESTS=1 to override."
    say "Output: $baseline_log — last 20 lines:"
    tail -n 20 "$baseline_log" | sed 's/^/    /'
    finish_reason="base branch '$BASE_BRANCH' failed ./run_tests.sh before the run started"
    send_run_email "aborted"
    exit 1
  fi
  say "Base branch is green."
fi

say "=== Autopilot run starting on '$PLAN_FILE' (max $MAX_STEPS steps this run, base branch '$BASE_BRANCH') ==="
say "Model: $AUTOPILOT_MODEL, effort: $EFFORT_DESC."
if (( MAX_RUN_SECONDS > 0 )); then
  say "Run budget: ${MAX_RUN_SECONDS}s — no new step will start after $(fmt_epoch "$run_deadline")."
fi

while (( steps_run < MAX_STEPS )); do
  if (( MAX_RUN_SECONDS > 0 )) && (( $(date +%s) >= run_deadline )); then
    say "Reached the ${MAX_RUN_SECONDS}s run budget. Not starting another step."
    finish_reason="${finish_reason:-reached the ${MAX_RUN_SECONDS}s run budget}"
    break
  fi

  current_branch="$(git branch --show-current)"
  if [[ "$current_branch" != "$BASE_BRANCH" ]]; then
    stop "ERROR: expected to be on '$BASE_BRANCH' at the start of a step but am on '$current_branch'. Stopping."
    break
  fi

  # Snapshot which step headings are already marked done. The gate before the
  # commit compares against this rather than reading the diff: a diff shows a
  # '+' line for an existing done heading that was merely reworded, which
  # would pass a "did it mark something done?" check without any step
  # actually having been finished.
  grep -E "$DONE_HEADING_RE" "$PLAN_FILE" | sort > "$done_before"
  done_before_count=$(grep -cE "$DONE_HEADING_RE" "$PLAN_FILE")

  # The real step number isn't known until the skill reports it via the
  # AUTOPILOT_STEP sentinel (parsed below, after the attempt runs) — plan
  # headings don't map 1:1 onto done_before_count, since sub-steps like
  # 2.1-2.7 each get their own '**done**' marker. Until then, claim a provisional,
  # unused log number so no earlier log — including a failed step's, which is
  # the one you most want to keep — is ever overwritten. A usage-limit retry
  # keeps appending to its own (by then possibly-renamed) logs.
  if [[ -n "$resume_branch" && -n "$STARTUP_RESUME_STEP" ]]; then
    # Resuming a step an earlier run started: reopen that step's logs and
    # append. The number came from the log that named this branch, so it is
    # already the real plan step number — no rename is pending.
    step_num="$STARTUP_RESUME_STEP"
    step_num_confirmed=1
    step_log="$LOG_DIR/autopilot-step-${step_num}.log"
    raw_log="$LOG_DIR/autopilot-step-${step_num}.raw.jsonl"
    err_log="$LOG_DIR/autopilot-step-${step_num}.err"
    touch "$step_log" "$raw_log" "$err_log"
    STARTUP_RESUME_STEP=""   # first step of the run only
    {
      echo
      echo "=== resumed $(date '+%Y-%m-%d %H:%M:%S') by a later autopilot run ==="
    } >> "$step_log"
  elif (( ! retry_pending )); then
    step_num=$(( done_before_count + 1 ))
    while [[ -e "$LOG_DIR/autopilot-step-${step_num}.log" ]]; do
      step_num=$((step_num + 1))
    done
    step_num_confirmed=0
    step_log="$LOG_DIR/autopilot-step-${step_num}.log"
    raw_log="$LOG_DIR/autopilot-step-${step_num}.raw.jsonl"
    err_log="$LOG_DIR/autopilot-step-${step_num}.err"
    : > "$step_log"
    : > "$raw_log"
    : > "$err_log"
  fi
  is_retry=$retry_pending
  retry_pending=0

  # A resumed step goes back onto its own branch, carrying the WIP commit the
  # limit interrupted. The skill is told the branch name so it skips its own
  # `git checkout -b` and works out what's already done from the diff.
  step_prompt="/plan-step-implementer \"$PLAN_FILE\""
  if [[ -n "$resume_branch" ]]; then
    if git rev-parse -q --verify "refs/heads/$resume_branch" >/dev/null 2>&1 \
       && git checkout "$resume_branch" >> "$step_log" 2>&1; then
      step_prompt="$step_prompt RESUME_BRANCH=$resume_branch"
      if (( is_retry )); then
        ap "Resuming step $step_num on '$resume_branch' after a usage-limit wait ($limit_hits of $MAX_LIMIT_RETRIES tolerated hits so far). The session continues that branch's partial work."
      else
        ap "Resuming the step interrupted by an earlier run, on '$resume_branch'. The session continues that branch's partial work rather than starting a new step."
      fi
    else
      ap "WARNING: couldn't check out '$resume_branch' to resume step $step_num; starting the step over from $BASE_BRANCH instead."
      resume_branch=""
      ap "Starting the next step (session will pick the next undone step from $PLAN_FILE and branch off $BASE_BRANCH)"
    fi
  elif (( is_retry )); then
    ap "Retrying step $step_num after a usage-limit wait ($limit_hits of $MAX_LIMIT_RETRIES tolerated hits so far)"
  else
    ap "Starting the next step (session will pick the next undone step from $PLAN_FILE and branch off $BASE_BRANCH)"
  fi
  if (( step_num_confirmed )); then
    say "Starting attempt (log: $step_log)"
  else
    # $step_num is only a free-slot counter this early; the log is renamed to
    # the real plan step number as soon as the skill reports AUTOPILOT_STEP.
    # Saying so beats printing a number that won't match the final filename.
    say "Starting attempt (log: $step_log — renamed to the real step number once the session reports it)"
  fi

  # Each attempt writes to its own scratch files — stdout, raw stream *and*
  # stderr — so the checks below only ever see *this* attempt's output. A
  # stale limit message from a previous attempt lingering in a cumulative
  # file would otherwise re-trigger the retry logic on every later attempt.
  # The scratch files are appended to the cumulative logs afterward for
  # auditing. stderr gets its own file rather than sharing stdout's: two
  # processes appending concurrently can interleave mid-line and corrupt the
  # JSON that usage-limit detection parses.
  : > "$attempt_text"
  : > "$attempt_raw"
  : > "$attempt_err"
  : > "$attempt_status"

  # The whole pipeline runs under one `timeout`, not just Claude. Wrapping
  # only Claude leaves the shell waiting on `jq`, which blocks until every
  # writer closes the pipe — and Claude's own Bash tool can leave a
  # backgrounded process holding that inherited fd. The run would then park
  # past STEP_TIMEOUT_SECONDS anyway, which is the one thing the timeout
  # exists to prevent. timeout signals the whole process group here, so the
  # readers die with the writer.
  #
  # --verbose is not a token cost: it controls what the local CLI prints, and
  # stream-json output requires it. Without it there is no stream to parse and
  # no AUTOPILOT_BRANCH line.
  #
  # Claude's exit status has to come back through a file: PIPESTATUS belongs
  # to the inner shell. The skill reads the plan file path via $ARGUMENTS and
  # figures out which undone step to work on.
  # shellcheck disable=SC2016  # $1..$9 are the inner shell's positional args,
  # passed after the script string below — expanding them here is exactly wrong.
  # Text is tee'd live into $step_log (not just the scratch file) as it
  # streams, so `tail -f logs/autopilot-step-N.log` shows progress during the
  # step instead of going silent until the whole attempt finishes.
  run_interruptible "${step_timeout[@]}" bash -c '
    set -uo pipefail
    prompt=$1; model=$2; effort=$3; out=$4; err=$5; raw=$6; filter=$7; status=$8; log=$9
    shift 9
    eff=()
    [[ -n "$effort" ]] && eff=(--effort "$effort")
    claude -p "$prompt" \
      --model "$model" \
      "${eff[@]+"${eff[@]}"}" \
      --dangerously-skip-permissions \
      --output-format stream-json \
      --verbose \
      --include-partial-messages \
      "$@" \
      2>>"$err" \
      | tee -a "$raw" \
      | jq -n --unbuffered -Rrj -f "$filter" \
      | tee -a "$out" >> "$log"
    echo "${PIPESTATUS[0]}" > "$status"
  ' autopilot-attempt \
      "$step_prompt" "$AUTOPILOT_MODEL" "$AUTOPILOT_EFFORT" \
      "$attempt_text" "$attempt_err" "$attempt_raw" "$text_filter" "$attempt_status" "$step_log" \
      "${claude_extra_flags[@]+"${claude_extra_flags[@]}"}"
  wrapper_exit=$?

  # Empty status file = the wrapper never reached that line, i.e. it was
  # killed; its own exit code (124/137 from timeout) is the real story.
  claude_exit="$(tr -dc '0-9' < "$attempt_status" 2>/dev/null)"
  [[ -n "$claude_exit" ]] || claude_exit=$wrapper_exit

  # No text at all, but a stream that did arrive, means the partial-message
  # events this filter depends on weren't emitted. Recover the same text from
  # the completed assistant messages rather than reporting the step as having
  # done nothing. Nothing was tee'd live into $step_log in this case (the
  # normal stream_event-driven tee never fired), so it's appended here.
  if [[ ! -s "$attempt_text" ]] && [[ -s "$attempt_raw" ]]; then
    jq -Rr -f "$whole_text_filter" "$attempt_raw" >> "$attempt_text" 2>/dev/null
    if [[ -s "$attempt_text" ]]; then
      ap "NOTE: no partial-message events in the stream; recovered this step's text from the completed assistant messages. Check whether Claude Code's --include-partial-messages behaviour changed."
      cat "$attempt_text" >> "$step_log"
    fi
  fi

  echo >> "$attempt_text"   # ensure the next AP: line starts on its own line
  echo >> "$step_log"       # matches, since normal-path text is already there

  jq -Rr -f "$archive_filter" "$attempt_raw" >> "$raw_log" 2>/dev/null
  cat "$attempt_err"  >> "$err_log"

  # Sentinels are matched as whole lines: the model discusses them by name
  # ("I am not printing NO_PENDING_STEPS because ..."), so a substring match
  # would produce false positives. Surrounding whitespace is tolerated —
  # a single trailing space shouldn't cost a run.
  saw_no_pending=0
  saw_review=0
  grep -qE '^[[:space:]]*NO_PENDING_STEPS[[:space:]]*$'      "$attempt_text" && saw_no_pending=1
  grep -qE '^[[:space:]]*HUMAN_REVIEW_REQUIRED[[:space:]]*$' "$attempt_text" && saw_review=1
  # Anchored to characters git actually allows in a ref, so prose glued to
  # either side of the sentinel on the same line (the streamed text has no
  # guaranteed newline before or after it) yields just the branch rather than
  # failing to match at all, which would then mismatch the checked-out branch
  # and stop a step that had in fact succeeded.
  branch_name=$(sed -nE 's|.*AUTOPILOT_BRANCH=([A-Za-z0-9._/-]+).*|\1|p' \
                  "$attempt_text" | tail -n1)

  # That character class can't tell a branch name from the prose glued to its
  # end when the stream emits no newline after the sentinel — observed:
  # "...-publisher-registry-badgesGood, that part is..." yielding a branch
  # ending in "Good". The checked-out branch is ground truth, so when the
  # extracted name is that branch plus a suffix, trust git and drop the
  # suffix: otherwise the mismatch check below stops a step that in fact
  # succeeded. Only ever trims — a genuinely different name still mismatches.
  reported_branch="$branch_name"
  actual_now="$(git branch --show-current 2>/dev/null)"
  if [[ -n "$branch_name" && -n "$actual_now" ]] \
     && [[ "$actual_now" == autopilot/* ]] \
     && [[ "$branch_name" != "$actual_now" ]] \
     && [[ "$branch_name" == "$actual_now"* ]]; then
    ap "NOTE: the AUTOPILOT_BRANCH line ran into the prose after it ('$reported_branch'); using the checked-out branch '$actual_now'."
    branch_name="$actual_now"
  fi

  # A resumed step is already standing on its branch when the session starts,
  # so the skill has no checkout to report. It is told to echo the name back
  # anyway, but not reporting it must not fail a step whose branch this script
  # chose itself and can see is still checked out.
  if [[ -z "$branch_name" && -n "$resume_branch" && "$actual_now" == "$resume_branch" ]]; then
    ap "NOTE: the resumed session didn't echo AUTOPILOT_BRANCH; using the branch it was resumed on ('$resume_branch')."
    branch_name="$resume_branch"
  fi

  # The provisional step_num above is just an unused-log-slot counter, not
  # the plan's actual step number (see the comment where it's assigned).
  # AUTOPILOT_STEP=<N> is the skill's ground truth for which heading it
  # picked; once it's seen, rename this step's logs to match so
  # autopilot-step-N.log lines up with '## Step N' in the plan file.
  # Not anchored to line start/end: the streamed text has no guaranteed
  # newline around the sentinel, so it can end up glued to the prose before
  # or after it on the same line (observed: "...directory.AUTOPILOT_STEP=5"),
  # which a whole-line match would silently miss, leaving the log stuck under
  # its provisional slot number.
  if (( ! step_num_confirmed )); then
    reported_step=$(sed -nE 's|.*AUTOPILOT_STEP=([0-9]+).*|\1|p' \
                      "$attempt_text" | tail -n1)
    if [[ -n "$reported_step" ]]; then
      real_num=$reported_step
      real_log="$LOG_DIR/autopilot-step-${real_num}.log"
      real_raw="$LOG_DIR/autopilot-step-${real_num}.raw.jsonl"
      real_err="$LOG_DIR/autopilot-step-${real_num}.err"
      # A file already sitting at the real number is one of two things, told
      # apart by whether a heading numbered $real_num was already done
      # *before* this attempt started: a parent "## Step N" and its
      # sub-steps "### Step N.1/N.2/..." all report the same bare N (SKILL.md
      # strips the ".M"), so a done N-heading means this collision is a
      # real, already-completed sibling's log -- give this attempt a
      # suffixed name instead of touching it. Otherwise the existing file is
      # a stale provisional log from an earlier attempt at this same step
      # that failed or was killed before reaching this point, so it never
      # got renamed off its provisional slot -- move it aside. Either way,
      # never just bump this step's number up past it: that would let stale
      # leftovers permanently steal numbers, drifting every later step
      # further from its actual plan heading.
      if [[ -e "$real_log" ]] && [[ "$real_log" != "$step_log" ]]; then
        if grep -qE "^#+ +Step +${real_num}(\.[0-9]+)?\b" "$done_before"; then
          attempt_n=2
          while [[ -e "${real_log}-attempt${attempt_n}" ]]; do
            attempt_n=$((attempt_n + 1))
          done
          real_log="${real_log}-attempt${attempt_n}"
          real_raw="${real_raw}-attempt${attempt_n}"
          real_err="${real_err}-attempt${attempt_n}"
        else
          stale_suffix=".stale-$(date -u +%Y%m%dT%H%M%SZ)"
          mv -f "$real_log" "${real_log}${stale_suffix}"
          [[ -e "$real_raw" ]] && mv -f "$real_raw" "${real_raw}${stale_suffix}"
          [[ -e "$real_err" ]] && mv -f "$real_err" "${real_err}${stale_suffix}"
        fi
      fi
      if [[ "$real_log" != "$step_log" ]]; then
        mv -f "$step_log" "$real_log"
        mv -f "$raw_log" "$real_raw"
        mv -f "$err_log" "$real_err"
        step_log="$real_log"
        raw_log="$real_raw"
        err_log="$real_err"
        step_num=$real_num
        ap "This step is plan step $real_num; its logs are now $step_log"
      fi
      step_num_confirmed=1
    fi
  fi

  # The skill branches before doing any work, so the most common way to be
  # rate-limited is *after* a branch exists — which used to disqualify the
  # step from the retry path below and end the run on an autopilot/* branch,
  # which in turn stopped the *next* run from starting. One limit cost two runs.
  #
  # An empty branch is not partial work: clean tree, still pointing at the
  # base commit. Discarding it is lossless and puts the step back in exactly
  # the state the retry path expects.
  #
  # The autopilot/ prefix is part of the precondition, not just a later check:
  # this block runs `git branch -D` on whatever name came back, and a reported
  # name that happened to be a real branch of yours has no business being
  # deleted here.
  discarded_empty_branch=0
  if [[ -n "$branch_name" ]] && [[ "$branch_name" == autopilot/* ]] \
     && [[ "$branch_name" != "$BASE_BRANCH" ]] \
     && (( ! saw_no_pending )) && (( ! saw_review )) \
     && [[ "$(git branch --show-current)" == "$branch_name" ]] \
     && [[ -z "$(git status --porcelain)" ]] \
     && [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$BASE_BRANCH")" ]]; then
    ap "Step $step_num branched to '$branch_name' but produced nothing. Discarding the empty branch and returning to $BASE_BRANCH."
    if git checkout "$BASE_BRANCH" >> "$step_log" 2>&1 \
       && git branch -D "$branch_name" >> "$step_log" 2>&1; then
      discarded_empty_branch=1
      branch_name=""
    else
      ap "WARNING: couldn't discard '$branch_name' (now on '$(git branch --show-current)'). Leaving it for review."
    fi
  fi

  # Usage/rate-limit detection. Claude emits a structured
  # {"type":"rate_limit_event","rate_limit_info":{"status":...,"resetsAt":
  # <unix epoch>,"rateLimitType":...}} line on every request in the
  # stream-json output — confirmed by inspecting actual output, not
  # documented, so treat as liable to change. status "rejected" means that
  # request was hard-blocked; resetsAt says when to retry.
  #
  # The precondition is that the session accomplished nothing: no branch (or
  # only the empty one just discarded above), no verdict sentinel, still on
  # the base branch. That means retrying is safe — there's no partial work to
  # abandon. Deliberately *not* gated on a non-zero exit code: `claude -p`
  # doesn't reliably exit non-zero when a request is refused.
  # Detection runs unconditionally, *before* any of those preconditions are
  # applied. Gating the detection itself on "accomplished nothing" is what let
  # a mid-step limit be reported as a bare "Claude exited with code 1 ...
  # (stderr: ...)" against an empty .err file: the limit never reaches stderr,
  # it arrives on the JSON stream. Whether the run can *retry* is a separate
  # question, decided below.
  saw_limit=0
  limit_wait_seconds=0
  limit_wait_desc=""

  # Parsed with jq rather than grepped: a whitespace change in the stream's
  # JSON formatting would silently disable a grep for '"type":"..."'. Read
  # per line via fromjson? for the same reason as the text filter — one
  # truncated line must not take the whole parse down with it.
  rl_info=$(jq -Rr 'fromjson?
                    | select(.type == "rate_limit_event")
                    | .rate_limit_info
                    | select(.status == "rejected")
                    | "\(.resetsAt // "") \(.rateLimitType // "unknown")"' \
                "$attempt_raw" 2>/dev/null | tail -n1)
  rl_resets_at="${rl_info%% *}"
  rl_type="${rl_info##* }"
  saw_rejection=0
  [[ -n "$rl_info" ]] && saw_rejection=1

  # The final result record carries the HTTP status directly. This is the
  # sturdiest signal of the three — it needs no prose matching and no
  # rate_limit_event — so it is checked alongside them rather than only as a
  # last resort. Observed on a real exhaustion: api_error_status 429 with
  # subtype "success" and is_error true, so neither subtype nor exit code can
  # be trusted to classify this.
  result_text=$(jq -Rr 'fromjson?
                        | select(.type == "result")
                        | [.result?, .error?]
                        | map(select(. != null) | tostring)
                        | join(" ")' "$attempt_raw" 2>/dev/null)
  saw_429=0
  if jq -e -Rr 'fromjson? | select(.type == "result")
                | select((.api_error_status? // 0) == 429)' \
        "$attempt_raw" >/dev/null 2>&1; then
    saw_429=1
  fi

  if (( saw_rejection )) || (( saw_429 )) \
     || grep -qiE "$LIMIT_TEXT_RE" <<<"$result_text" \
     || grep -qiE "$LIMIT_TEXT_RE" "$attempt_err"; then
    saw_limit=1
  fi

  if (( saw_limit )); then
    # A resetsAt is only believed if it lands in a plausible window. The
    # failure this guards against is the field's units changing (epoch
    # milliseconds reads as a date ~55,000 years out): the cap below would
    # quietly turn that into a deliberate-looking 6h sleep. A timestamp in
    # the past is just as wrong, and clamping it to 60s would burn every
    # retry in twelve minutes against a limit that hasn't moved.
    rl_trusted=0
    if [[ "$rl_resets_at" =~ ^[0-9]+$ ]]; then
      rl_delta=$(( rl_resets_at - $(date +%s) ))
      if (( rl_delta >= -LIMIT_SANITY_PAST_SECONDS && rl_delta <= LIMIT_SANITY_MAX_SECONDS )); then
        rl_trusted=1
      else
        ap "Ignoring reported reset time $rl_resets_at (${rl_delta}s away) — outside the plausible window, so the field's meaning may have changed. Falling back to a blind wait."
      fi
    fi

    if (( rl_trusted )); then
      limit_wait_seconds=$(( rl_delta + 15 ))
      limit_wait_desc="until the reported ${rl_type:-unknown} reset time ($(fmt_epoch "$rl_resets_at"))"
      if (( limit_wait_seconds > MAX_LIMIT_SLEEP_SECONDS )); then
        limit_wait_desc="$limit_wait_desc, capped at ${MAX_LIMIT_SLEEP_SECONDS}s"
        limit_wait_seconds=$MAX_LIMIT_SLEEP_SECONDS
      fi
      (( limit_wait_seconds < 60 )) && limit_wait_seconds=60
    else
      limit_wait_seconds=$LIMIT_RETRY_WAIT_SECONDS
      limit_wait_desc="a blind ${LIMIT_RETRY_WAIT_SECONDS}s wait (no usable reset time reported)"
    fi
  fi

  # Now decide whether this limit is retryable. The retry path re-runs the
  # step from scratch, so it needs the same starting state every step gets:
  # on $BASE_BRANCH with a clean tree. Three cases reach that state.
  usage_limit_hit=0
  if (( saw_limit )) && (( ! saw_no_pending )) && (( ! saw_review )); then
    cur_branch="$(git branch --show-current)"
    if [[ -z "$branch_name" ]] && [[ "$cur_branch" == "$BASE_BRANCH" ]] \
       && [[ -z "$(git status --porcelain)" ]]; then
      # Nothing happened before the limit landed. Retry outright.
      usage_limit_hit=1

    elif [[ -n "$branch_name" ]] && [[ "$branch_name" == autopilot/* ]] \
         && [[ "$branch_name" != "$BASE_BRANCH" ]] \
         && [[ "$cur_branch" == "$branch_name" ]]; then
      # The usual case: the skill branched, edited files, then ran out mid-step.
      # The partial work is committed to its own branch and the branch is kept:
      # the retry *resumes* on it rather than starting the step over, so those
      # edits are the whole point. Committing rather than leaving the tree
      # dirty is what makes the work survive the wait — a 5h sleep is ample
      # time for the run to be killed, and a dirty tree would then block the
      # next run from starting at all.
      #
      # Base is checked out for the duration of the sleep so that a run killed
      # mid-wait leaves the repo somewhere sane; the retry checks the branch
      # back out at the top of the loop.
      ap "Usage limit hit mid-step on '$branch_name'. Committing its partial work so step $step_num can resume on that branch after the wait."
      if git add -A >> "$step_log" 2>&1 \
         && { [[ -z "$(git status --porcelain)" ]] \
              || git commit -m "Autopilot WIP (usage limit): partial step $step_num" >> "$step_log" 2>&1; } \
         && git checkout "$BASE_BRANCH" >> "$step_log" 2>&1; then
        ap "Parked. Step $step_num will resume on '$branch_name' — the next session picks up where this one stopped."
        usage_limit_hit=1
        resume_branch="$branch_name"
        branch_name=""
      else
        ap "WARNING: couldn't park the partial work on '$branch_name' (now on '$(git branch --show-current)')."
      fi

    elif [[ -z "$branch_name" ]] && [[ "$cur_branch" == "$BASE_BRANCH" ]]; then
      # Ran out after editing but before branching (the skill branches first,
      # so this needs the checkout itself to have failed). Stashing is
      # lossless and recoverable via `git stash list`.
      ap "Usage limit hit before step $step_num branched, with changes on $BASE_BRANCH. Stashing them so the step can be retried."
      if git stash push -u -m "autopilot: partial step $step_num before usage limit" >> "$step_log" 2>&1; then
        ap "Stashed. Recover with 'git stash list' / 'git stash show -p'; retrying step $step_num from scratch after the wait."
        usage_limit_hit=1
      else
        ap "WARNING: couldn't stash the partial work on $BASE_BRANCH."
      fi
    fi
  fi

  # A limit that could not be made retryable still gets named as a limit,
  # rather than falling through to the generic non-zero-exit message.
  if (( saw_limit )) && (( ! usage_limit_hit )) \
     && (( ! saw_no_pending )) && (( ! saw_review )); then
    stop "Claude hit a usage limit on step $step_num and the run could not be put back into a retryable state (on '$(git branch --show-current)', branch '${branch_name:-none}'). Stopping for review — the limit resets $( [[ "$rl_resets_at" =~ ^[0-9]+$ ]] && fmt_epoch "$rl_resets_at" || echo "at an unreported time")."
    break
  fi

  if (( usage_limit_hit )); then
    limit_hits=$((limit_hits + 1))
    if (( limit_hits > MAX_LIMIT_RETRIES )); then
      stop "Hit a usage limit $limit_hits times in a row on step $step_num. Giving up — stopping for review."
      break
    fi
    if (( MAX_RUN_SECONDS > 0 )); then
      remaining=$(( run_deadline - $(date +%s) ))
      if (( limit_wait_seconds >= remaining )); then
        stop "Usage limit on step $step_num would need a ${limit_wait_seconds}s wait, but only ${remaining}s of the ${MAX_RUN_SECONDS}s run budget remain. Stopping."
        break
      fi
    fi
    ap "Claude hit a usage/rate limit before starting work on step $step_num (attempt $limit_hits/$MAX_LIMIT_RETRIES). Sleeping ${limit_wait_seconds}s ($limit_wait_desc) before retrying."
    say "Usage limit; sleeping ${limit_wait_seconds}s before retrying step $step_num."
    sleep_until $(( $(date +%s) + limit_wait_seconds ))
    retry_pending=1
    continue
  fi
  limit_hits=0

  # 124 is timeout's own exit code; 137 is a SIGKILL from its -k grace period.
  if (( claude_exit == 124 || claude_exit == 137 )); then
    stop "Claude exceeded the ${STEP_TIMEOUT_SECONDS}s step timeout on step $step_num and was killed. Stopping for review."
    break
  fi

  if [[ $claude_exit -ne 0 ]]; then
    # Only point at the .err file when it has something in it. API-side
    # failures (usage limits, 429s, overload) never touch stderr — they come
    # back on the JSON stream — so citing an empty file sends you looking in
    # the one place the answer is guaranteed not to be.
    if [[ -s "$err_log" ]]; then
      stop "Claude exited with code $claude_exit on step $step_num. Stopping for review (stderr: $err_log)."
    else
      stop "Claude exited with code $claude_exit on step $step_num, with nothing on stderr. Stopping for review — the reason will be in the stream: jq -Rr 'fromjson? | select(.type==\"result\" or .type==\"rate_limit_event\")' $raw_log | tail -5"
    fi
    break
  fi

  if (( saw_no_pending )); then
    ap "No pending steps remain in $PLAN_FILE. Nothing left to do."
    finish_reason="${finish_reason:-every step in $PLAN_FILE is marked done}"
    # Kept, not deleted: if that verdict is wrong (a misread heading, a
    # truncated file), this log is the only record of the reasoning. Renamed
    # so it isn't mistaken for a step that ran, and so the number stays free.
    for f in "$step_log" "$raw_log" "$err_log"; do
      [[ -e "$f" ]] && mv "$f" "$f.nopending"
    done
    step_log="$step_log.nopending"
    break
  fi

  # Checked before the branch-name check: a session blocked before it could
  # pick a step has no branch to report, and the real blocker is the more
  # useful thing to surface. A blocked step always ends the run.
  if (( saw_review )); then
    if [[ -n "$branch_name" ]]; then
      stop "Claude flagged step $step_num as blocked and needs human review. Leaving branch '$branch_name' checked out with its changes uncommitted — which is also what stops the next run from starting here."
    elif [[ -n "$(git status --porcelain)" ]]; then
      # It never got as far as branching, so its partial work is sitting on
      # the base branch. Say so plainly: the next run's only complaint will
      # be "working tree isn't clean", which reads like the user's own mess.
      stop "Claude flagged step $step_num as blocked before it created a branch, and left changes uncommitted on '$BASE_BRANCH'. Stopping for review — the next run will refuse to start until this tree is clean."
      git status --short >> "$step_log"
    else
      stop "Claude flagged step $step_num as blocked before it created a branch, and changed nothing. Stopping for review — the repo is untouched on '$BASE_BRANCH'."
    fi
    break
  fi

  # The skill creates and checks out its own branch for the step and reports
  # its name this way — this is the only way we learn it.
  if [[ -z "$branch_name" ]]; then
    if (( discarded_empty_branch )); then
      stop "Step $step_num branched but produced nothing, and it doesn't look like a usage limit. Stopping for review (the empty branch was discarded; stderr: $err_log)."
    else
      stop "Claude didn't report a branch name (AUTOPILOT_BRANCH=<name>) for step $step_num. Stopping for review."
    fi
    break
  fi

  # The autopilot/ prefix isn't cosmetic: it is the only thing the *next*
  # run's abandoned-branch guard recognizes. A step branch named anything
  # else that gets left checked out would silently become the base branch
  # everything after it merges into.
  if [[ "$branch_name" != autopilot/* ]]; then
    stop "Claude reported branch '$branch_name', which isn't under 'autopilot/'. Stopping for review — a step branch outside that namespace defeats the next run's abandoned-branch check."
    break
  fi

  # If the skill's `git checkout -b` silently failed, we'd otherwise commit
  # the step's work straight onto the base branch.
  actual_branch="$(git branch --show-current)"
  if [[ "$actual_branch" != "$branch_name" ]]; then
    stop "Claude reported branch '$branch_name' but the repo is on '$actual_branch'. Stopping for review — refusing to commit to the wrong branch."
    break
  fi

  # The step branch has to sit on top of the base branch. `git checkout -b`
  # with a start-point, or a base branch that moved underneath us, would
  # otherwise produce a commit on an unrelated ancestor and drag whatever
  # else is on that line of history into the merge.
  if ! git merge-base --is-ancestor "$BASE_BRANCH" HEAD 2>/dev/null; then
    stop "Branch '$branch_name' isn't descended from '$BASE_BRANCH' — it was cut from somewhere else. Stopping for review rather than merging an unrelated history."
    break
  fi

  if [[ -z "$(git status --porcelain)" ]]; then
    stop "No file changes were produced for step $step_num on branch '$branch_name'. Stopping for review — this usually means something went wrong."
    break
  fi

  # The skill forbids the session from editing its own harness, but nothing
  # stopped `git add -A` from committing it anyway — and bash reads this
  # script incrementally from disk, so an in-place rewrite can make the
  # *running* interpreter execute garbage from a shifted byte offset. That is
  # not a failure you can diagnose from a log. Only matters when the project
  # being worked on is this tool's own repo — see where these paths are set.
  harness_edits="$(git status --porcelain -- "$SELF_FILE" "$SKILL_SELF_FILE" "$NOTIFY_SELF_FILE")"
  if [[ -n "$harness_edits" ]]; then
    stop "Step $step_num modified its own harness. Stopping for review — refusing to commit changes to $SELF_FILE, $SKILL_SELF_FILE or $NOTIFY_SELF_FILE:"
    printf '%s\n' "$harness_edits" | tee -a "$step_log"
    break
  fi

  if [[ -x "./run_tests.sh" ]]; then
    ap "Running tests..."
    run_interruptible "${test_timeout[@]}" ./run_tests.sh >> "$step_log" 2>&1
    test_exit=$?
    if (( test_exit == 124 || test_exit == 137 )); then
      stop "./run_tests.sh exceeded the ${TEST_TIMEOUT_SECONDS}s timeout on step $step_num and was killed. Stopping for review — leaving changes uncommitted."
      break
    fi
    if (( test_exit != 0 )); then
      stop "Tests failed after step $step_num on branch '$branch_name'. Stopping for review — leaving changes uncommitted."
      break
    fi
  else
    ap "WARNING: no ./run_tests.sh — committing step $step_num unverified."
  fi

  # `git add -A` sweeps in whatever else is lying around — a throwaway
  # verification harness, a stray fixture, anything the test run just wrote.
  # Taken *after* the tests for that last reason: a snapshot from before them
  # would omit exactly the files that show up in the commit unexplained.
  git status --porcelain >> "$step_log"
  untracked="$(git ls-files --others --exclude-standard)"
  if [[ -n "$untracked" ]]; then
    ap "Step $step_num added $(printf '%s\n' "$untracked" | wc -l | tr -d ' ') new file(s), all of which 'git add -A' will commit:"
    printf '%s\n' "$untracked" | sed 's/^/    /' | tee -a "$step_log"
  fi

  # The plan file is the only record of which steps are finished, so a
  # session that did the work but didn't mark the heading would be redone,
  # identically, by every session after it.
  #
  # Compared against the snapshot taken at the top of this step, not against
  # the diff: a diff shows a '+' line for a done heading that was merely
  # reworded or re-indented, which would satisfy a "did it add a **done**
  # heading?" check while no step was actually finished.
  grep -E "$DONE_HEADING_RE" "$PLAN_FILE" | sort > "$done_after"
  done_after_count=$(grep -cE "$DONE_HEADING_RE" "$PLAN_FILE")

  # Checked before the count, and separately from it: a session that un-marks
  # one step while marking two still comes out ahead on the count, and the
  # step it un-marked would then be redone by a later session as though it had
  # never been finished.
  done_removed="$(comm -23 "$done_before" "$done_after")"
  if [[ -n "$done_removed" ]]; then
    stop "Step $step_num removed the '**done**' marker from a heading that was already finished. Stopping for review — leaving changes uncommitted:"
    printf '%s\n' "$done_removed" | sed 's/^/    /' | tee -a "$step_log"
    break
  fi

  if (( done_after_count <= done_before_count )); then
    stop "Step $step_num didn't mark any new step heading '**done**' in $PLAN_FILE ($done_before_count before, $done_after_count now). Stopping for review — committing this would let the next session redo the same step."
    ap "The work is on branch '$branch_name', uncommitted, and tests passed; mark the heading and merge by hand if it's good."
    break
  fi
  done_headings="$(comm -13 "$done_before" "$done_after")"

  # Name the commit after the heading the skill just marked done. Prefer the
  # most specific one: a session finishing sub-step 2.8 may also mark its
  # parent Step 2 done, and "2.8" is the more accurate label for this commit.
  # Depth is the length of the leading run of '#' only — counting every '#' on
  # the line would rank a heading that merely mentions one as the deepest.
  step_name=$(printf '%s\n' "$done_headings" \
    | awk 'NF { match($0, /^#+/); print RLENGTH, $0 }' \
    | sort -rn \
    | head -n1 \
    | sed -E 's/^[0-9]+ #+ //' \
    | sed -E 's/[[:space:]]*(—|–|--|-)?[[:space:]]*\*\*done\*\*.*$//')
  step_name="${step_name:-step $step_num}"

  git add -A
  if ! git commit -m "Autopilot: ${step_name}" >> "$step_log" 2>&1; then
    stop "git commit failed for step $step_num on branch '$branch_name' (a hook may have rejected it). Stopping for review."
    break
  fi

  ap "Merging '$branch_name' into $BASE_BRANCH..."
  if ! git checkout "$BASE_BRANCH" >> "$step_log" 2>&1 \
      || ! git merge --no-ff "$branch_name" -m "Merge $branch_name: ${step_name}" >> "$step_log" 2>&1; then
    stop "Merging '$branch_name' into $BASE_BRANCH failed. Stopping for review — resolve manually (currently on '$(git branch --show-current)')."
    break
  fi
  if ! git branch -d "$branch_name" >> "$step_log" 2>&1; then
    # Harmless — the work is merged — but an unexplained leftover autopilot/*
    # branch looks exactly like a step that failed.
    ap "WARNING: couldn't delete '$branch_name' after merging it. The step is committed and merged; clean up with: git branch -D '$branch_name'"
  fi

  # The step is merged and its branch gone, so any pending resume is settled.
  # Leaving it set would send the *next* step onto a deleted branch.
  resume_branch=""
  steps_run=$((steps_run + 1))
  completed_steps+=("$step_name")
  completed_step_nums+=("$step_num")
  ap "Finished step $step_num: $step_name (merged '$branch_name' into $BASE_BRANCH)"
  report_usage_pct
  say "Finished step $step_num: $step_name"
done

if (( steps_run >= MAX_STEPS )); then
  finish_reason="${finish_reason:-reached the MAX_STEPS cap of $MAX_STEPS}"
fi

if (( stopped_for_review )); then
  run_outcome="NEEDS REVIEW"
else
  run_outcome="finished"
fi

say "=== Autopilot run finished. $steps_run step(s) completed this run. ==="
say "Autopilot ran no 'git push' of its own; if a step touched publishing, check its log. Review before you push."
send_run_email "$run_outcome"
