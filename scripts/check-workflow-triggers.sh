#!/usr/bin/env bash
# Trigger allowlist for the workflow that assumes the apply role (ADR 0004, PR 1 verify finding L1).
# The apply trust cannot tell `push` from `pull_request_target`, `issue_comment` or `workflow_run` on main,
# so the repo refuses those triggers where they would be written. zizmor's dangerous-triggers audit is the
# second layer. Reads the top-level `on:` block of a workflow; supports block, flow ([a, b]) and scalar forms.
#
# Usage: scripts/check-workflow-triggers.sh [workflow file ...]   (default: .github/workflows/terraform-iac.yml)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

allowed="pull_request push workflow_dispatch"

files=()
if [ $# -gt 0 ]; then
  for f in "$@"; do files+=("$f"); done
else
  files+=("$ROOT/.github/workflows/terraform-iac.yml")
fi

bad=()
for f in "${files[@]}"; do
  [ -f "$f" ] || die "workflow not found: $f"
  # shellcheck disable=SC2016  # awk program, not shell
  triggers="$(awk '
    /^(on|"on"|'\''on'\''):/ {
      inon = 1
      rest = $0
      sub(/^[^:]*:[[:space:]]*/, "", rest)
      sub(/[[:space:]]*#.*$/, "", rest)
      gsub(/[\[\],"'\'']/, " ", rest)
      n = split(rest, parts, /[[:space:]]+/)
      for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
      next
    }
    inon && /^[^[:space:]#]/ { inon = 0 }
    inon && /^[[:space:]]*#/ { next }
    inon && /^[[:space:]]+[A-Za-z_]+:/ {
      match($0, /^[[:space:]]+/)
      indent = RLENGTH
      if (child == 0) child = indent
      if (indent == child) { key = $1; sub(/:.*/, "", key); print key }
    }
  ' "$f")"
  [ -n "$triggers" ] || { bad+=("${f#"$ROOT"/}: no triggers found under on:"); continue; }
  while IFS= read -r t; do
    case " $allowed " in
      *" $t "*) ;;
      *) bad+=("${f#"$ROOT"/}: trigger '$t' is not allowed (allowed: $allowed)") ;;
    esac
  done <<<"$triggers"
done

if [ ${#bad[@]} -gt 0 ]; then
  for b in "${bad[@]}"; do printf '  - %s\n' "$b" >&2; done
  die "${#bad[@]} workflow trigger violation(s)"
fi
ok "workflow triggers are within the allowlist: $allowed"
