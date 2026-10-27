"""Shared YAML reader for the workflow checks in scripts/ (workflow_triggers, harden_runner_policy).

Not run directly. PyYAML comes from the hash-locked CI venv (scripts/ci-venv.sh).
"""

from typing import Any

import yaml


class UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses a mapping holding the same key twice.

    GitHub keeps one of the two values and PyYAML the last, so a duplicate could hide a trigger.
    """

    def construct_mapping(self, node: yaml.MappingNode, deep: bool = False) -> dict[Any, Any]:
        self.flatten_mapping(node)
        seen: set[Any] = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=True)
            try:
                duplicate = key in seen
            except TypeError as e:
                raise yaml.constructor.ConstructorError(
                    None, None, f"unhashable mapping key {key!r}", key_node.start_mark
                ) from e
            if duplicate:
                raise yaml.constructor.ConstructorError(
                    None, None, f"duplicate key {key!r}", key_node.start_mark
                )
            seen.add(key)
        return super().construct_mapping(node, deep=deep)


def load_workflow(text: str) -> Any:
    """Parse one workflow file, refusing duplicate mapping keys. Raises yaml.YAMLError."""
    loader = UniqueKeyLoader(text)
    try:
        return loader.get_single_data()
    finally:
        loader.dispose()
