#!/usr/bin/env bash
# Environment parity guard (ADR 0008, P3): the per-environment Terraform roots stay copies of envs/dev, and every
# environment is in every workflow list. The rules are in scripts/guard/env_parity.py.
#
# Usage: scripts/guard/env-parity.sh [repo root]   (default: this repository)
# Env:   CI_PYTHON  interpreter with PyYAML (default: .venv-ci/bin/python from `make venv`, else python3)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -le 1 ] || die "usage: scripts/guard/env-parity.sh [repo root]"
py="$(ci_python)"
rc=0
out="$("$py" -I "$ROOT/scripts/guard/env_parity.py" "${1:-$ROOT}")" || rc=$?
if [ "$rc" -eq 1 ]; then
  printf '%s\n' "$out" | sed 's/^/  - /' >&2
  die "$(grep -c '' <<<"$out") environment parity violation(s)"
fi
[ "$rc" -eq 0 ] || die "env_parity.py failed (exit code $rc)"
ok "environment roots match envs/dev and every workflow lists every environment"
