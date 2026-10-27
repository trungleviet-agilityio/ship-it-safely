"""Trigger allowlist for GitHub workflow files (ADR 0007 S34, ADR 0004 L1 and L-a).

The apply and deploy roles cannot tell `push` from `pull_request_target`, `issue_comment` or
`workflow_run` on main, so the repository refuses every trigger outside ALLOWED. This parses real
YAML (PyYAML, from the hash-locked CI venv), so flow lists split across lines, explicit `?` keys,
quoted keys and anchors cannot hide a trigger the way they could from a line scanner.

Usage: python -I scripts/guard/workflow_triggers.py <workflow file>...
Prints one violation per line on stdout, with paths relative to the working directory.
Exit codes: 0 all files pass, 1 violations, 2 usage error.
Run through scripts/guard/workflow-triggers.sh, which picks the interpreter and lists the files.
"""

import os
import sys
from typing import Any

# `python -I` leaves the script directory off sys.path; the helper module sits next to this file.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workflow_yaml import run  # noqa: E402  (import after the path setup above)

ALLOWED = ("pull_request", "push", "workflow_dispatch")


def _triggers(document: Any) -> list[str]:
    """Names under the top-level `on`, or raise ValueError saying why they cannot be read."""
    if not isinstance(document, dict):
        raise ValueError("the workflow is not a YAML mapping")
    # YAML 1.1 (PyYAML) reads an unquoted `on` as True; GitHub reads it as the string "on".
    keys = [k for k in document if k == "on" or k is True]
    if len(keys) > 1:
        raise ValueError("both `on` and its YAML 1.1 form `true` are present")
    value = document[keys[0]] if keys else None
    # A scalar is one trigger; a list or mapping is read by items or keys; anything else names none.
    names: list[Any] = []
    if isinstance(value, str):
        names = [value]
    elif isinstance(value, list | dict):
        names = list(value)
    if not names:
        raise ValueError("no triggers found under on:")
    if not all(isinstance(n, str) for n in names):
        raise ValueError("a trigger name is not a string")
    return names


def check(shown: str, document: Any) -> list[str]:
    """Violations of one parsed workflow, as `<file>: <message>` lines."""
    try:
        names = _triggers(document)
    except ValueError as e:
        return [f"{shown}: {e}"]
    return [
        f"{shown}: trigger '{n}' is not allowed (allowed: {' '.join(ALLOWED)})"
        for n in names
        if n not in ALLOWED
    ]


if __name__ == "__main__":
    sys.exit(run("workflow_triggers.py", check, sys.argv[1:]))
