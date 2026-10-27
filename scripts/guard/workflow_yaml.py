"""Shared reader and entry point for the workflow checks (workflow_triggers, harden_runner_policy).

Not run directly. PyYAML comes from the hash-locked CI venv (scripts/ci/venv.sh).
"""

import os
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

import yaml


class UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses a mapping holding the same key twice.

    GitHub keeps one of the two values and PyYAML the last, so a duplicate could hide a trigger.
    """

    def construct_mapping(self, node: yaml.MappingNode, deep: bool = False) -> dict[Any, Any]:
        self.flatten_mapping(node)  # expand `<<` merge keys first: the pair count is then real
        mapping = super().construct_mapping(node, deep=deep)
        if len(mapping) != len(node.value):
            raise yaml.constructor.ConstructorError(
                None, None, "duplicate key in a mapping", node.start_mark
            )
        return mapping


def load_workflow(text: str) -> Any:
    """Parse one workflow file, refusing duplicate mapping keys. Raises yaml.YAMLError."""
    loader = UniqueKeyLoader(text)
    try:
        return loader.get_single_data()
    finally:
        loader.dispose()


def run(prog: str, check: Callable[[str, Any], list[str]], argv: list[str]) -> int:
    """Run `check(shown path, parsed document)` over each file and print its violations.

    Exit codes: 0 all files pass, 1 violations, 2 usage error.
    """
    if not argv:
        print(f"usage: {prog} <workflow file>...", file=sys.stderr)
        return 2
    problems: list[str] = []
    for name in argv:
        path = Path(name)
        shown = os.path.relpath(path)
        if not path.is_file():
            problems.append(f"{shown}: workflow not found")
            continue
        try:
            document = load_workflow(path.read_text(encoding="utf-8"))
        except yaml.YAMLError as e:
            problems.append(
                f"{shown}: invalid YAML: {getattr(e, 'problem', None) or 'parse error'}"
            )
            continue
        problems.extend(check(shown, document))
    for line in problems:
        print(line)
    return 1 if problems else 0
