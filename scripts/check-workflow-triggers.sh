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

files=()
if [ $# -gt 0 ]; then
  for f in "$@"; do files+=("$f"); done
else
  for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
    if [ -f "$f" ]; then files+=("$f"); fi
  done
  [ ${#files[@]} -gt 0 ] || die "no workflow files found under .github/workflows"
fi

py="${CI_PYTHON:-}"
if [ -z "$py" ]; then
  if [ -x "$ROOT/.venv-ci/bin/python" ]; then py="$ROOT/.venv-ci/bin/python"; else py=python3; fi
fi
"$py" -I -c 'import yaml' >/dev/null 2>&1 || die "pyyaml missing: run make venv (hash locked)"

rc=0
out="$("$py" -I "$ROOT/scripts/workflow_triggers.py" "${files[@]}")" || rc=$?
case "$rc" in
  0) ;;
  1)
    count=0
    while IFS= read -r line; do
      printf '  - %s\n' "${line#"$ROOT"/}" >&2
      count=$((count + 1))
    done <<<"$out"
    die "${count} workflow trigger violation(s)"
    ;;
  *) die "workflow_triggers.py failed (exit code $rc)" ;;
esac
ok "workflow triggers are within the allowlist: pull_request push workflow_dispatch"
