#!/usr/bin/env bash
# Trigger allowlist for the workflow that assumes the apply role (ADR 0004, PR 1 verify finding L1; ADR 0007 S34).
# The apply trust cannot tell `push` from `pull_request_target`, `issue_comment` or `workflow_run` on main,
# so the repo refuses those triggers where they would be written. zizmor's dangerous-triggers audit is the
# second layer. The parsing is real YAML (scripts/workflow_triggers.py, PyYAML from the hash-locked venv): block,
# flow, scalar, quoted and explicit-key forms all read the same way GitHub reads them.
#
# The role trust pins the workflow file path, so any workflow file can matter, path-filtered or not. With no
# arguments every .github/workflows/*.yml and *.yaml is scanned.
#
# Usage: scripts/check-workflow-triggers.sh [workflow file ...]
# Env:   CI_PYTHON  interpreter with PyYAML (default: .venv-ci/bin/python from `make venv`, else python3)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

run_workflow_helper workflow_triggers.py "workflow trigger" "$@"
ok "workflow triggers are within the allowlist: pull_request push workflow_dispatch"
