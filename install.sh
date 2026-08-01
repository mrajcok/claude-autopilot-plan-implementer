#!/usr/bin/env bash
# Symlinks autopilot onto PATH and the plan-step-implementer skill into
# Claude Code's global skills directory. Safe to re-run.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SKILLS_DIR="$HOME/.claude/skills"

mkdir -p "$BIN_DIR" "$SKILLS_DIR"
chmod +x "$REPO_DIR/bin/autopilot.sh" "$REPO_DIR/bin/autopilot_notify.py"

ln -sf "$REPO_DIR/bin/autopilot.sh" "$BIN_DIR/autopilot"
ln -sf "$REPO_DIR/skills/plan-step-implementer" "$SKILLS_DIR/plan-step-implementer"

echo "Linked:"
echo "  $BIN_DIR/autopilot -> $REPO_DIR/bin/autopilot.sh"
echo "  $SKILLS_DIR/plan-step-implementer -> $REPO_DIR/skills/plan-step-implementer"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    echo
    echo "NOTE: $BIN_DIR is not on your PATH. Add this to your shell rc:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac
