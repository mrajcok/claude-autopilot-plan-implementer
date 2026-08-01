#!/usr/bin/env python3
"""Send an autopilot run notification by email. Body is read from stdin.

    autopilot_notify.py "subject line" < body.txt

Configuration: ``EMAIL_ENABLED``, ``SMTP_HOST``, ``SMTP_PORT``, ``SMTP_USER``,
``SMTP_PASSWORD``, ``EMAIL_FROM``, ``EMAIL_TO`` (comma-separated). Values come
from the environment first, then this repo's own ``.env`` (see
``.env.example``) — never from the project being worked on. autopilot is used
across many projects; asking each one to carry mail credentials for a tool
that's optional to them is the wrong place to put this config.

Always exits 0. A notification that fails must never turn a successful
autopilot run into a failed one; problems go to stderr, which autopilot.sh
captures in the run log.
"""

import os
import re
import smtplib
import sys
from email.message import EmailMessage
from pathlib import Path

# This repo's own .env, regardless of which project's directory autopilot.sh
# was invoked from.
ENV_FILE = Path(__file__).resolve().parent.parent / ".env"

# Only these keys are ever read out of .env — this script has no business
# parsing the rest of the file.
ENV_KEYS = (
    "EMAIL_ENABLED",
    "SMTP_HOST",
    "SMTP_PORT",
    "SMTP_USER",
    "SMTP_PASSWORD",
    "EMAIL_FROM",
    "EMAIL_TO",
)

_LINE_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def _unquote(value: str) -> str:
    """Strip surrounding quotes, or an unquoted trailing comment."""
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    # python-dotenv only treats ' #' as starting a comment, so a '#' inside an
    # unquoted password survives as long as it isn't preceded by whitespace.
    return re.split(r"\s+#", value, maxsplit=1)[0].strip()


def load_dotenv(path: Path) -> None:
    """Fill in any of ENV_KEYS not already set, from a .env file."""
    if not path.is_file():
        return
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"autopilot_notify: cannot read {path}: {exc}", file=sys.stderr)
        return
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = _LINE_RE.match(line)
        if not match:
            continue
        key, raw = match.group(1), match.group(2)
        if key in ENV_KEYS and key not in os.environ:
            os.environ[key] = _unquote(raw)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: autopilot_notify.py <subject>  (body on stdin)", file=sys.stderr)
        return 0

    subject = sys.argv[1]
    body = sys.stdin.read()

    load_dotenv(ENV_FILE)

    if os.environ.get("EMAIL_ENABLED", "false").lower() != "true":
        print("autopilot_notify: EMAIL_ENABLED is not true — no email sent.", file=sys.stderr)
        return 0

    host = os.environ.get("SMTP_HOST", "")
    sender = os.environ.get("EMAIL_FROM", "")
    recipients = [a.strip() for a in os.environ.get("EMAIL_TO", "").split(",") if a.strip()]
    if not (host and sender and recipients):
        print(
            "autopilot_notify: SMTP_HOST, EMAIL_FROM or EMAIL_TO missing — no email sent.",
            file=sys.stderr,
        )
        return 0

    try:
        port = int(os.environ.get("SMTP_PORT", "587"))
    except ValueError:
        print("autopilot_notify: SMTP_PORT is not a number — no email sent.", file=sys.stderr)
        return 0

    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = ", ".join(recipients)
    msg["Subject"] = subject
    msg.set_content(body)

    user = os.environ.get("SMTP_USER", "")
    password = os.environ.get("SMTP_PASSWORD", "")

    try:
        smtp = smtplib.SMTP_SSL(host, port, timeout=30) if port == 465 else smtplib.SMTP(host, port, timeout=30)
        with smtp:
            if port != 465:
                smtp.starttls()
            if user and password:
                smtp.login(user, password)
            smtp.send_message(msg)
    # Broad on purpose: a broken mail server must not fail an autopilot run.
    except Exception as exc:
        print(f"autopilot_notify: send failed: {exc}", file=sys.stderr)
        return 0

    print(f"autopilot_notify: sent {subject!r} to {', '.join(recipients)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
