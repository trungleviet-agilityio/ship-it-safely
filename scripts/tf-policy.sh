#!/usr/bin/env bash
# Grep-level Terraform policy rules that `terraform test` cannot express (ADR 0004, E28).
# Rules about files that do not exist yet (modules/, envs/) pass when those paths are absent.
# Comment lines (# or //) are ignored. Offline; never touches AWS.
#
# Usage: scripts/tf-policy.sh [root]   (default root: infra/terraform)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

root="${1:-$ROOT/infra/terraform}"
[ -d "$root" ] || die "root not found: $root"

failures=()

# fail <rule id> <message> <matching lines...>
fail() {
  local id="$1" msg="$2"
  shift 2
  failures+=("policy[$id] $msg")
  local line
  for line in "$@"; do printf '       %s\n' "$line" >&2; done
}

# scan <extended regex> <dir>: file:line:text of matching non-comment lines in *.tf under <dir>.
scan() {
  [ -d "$2" ] || return 0
  grep -rEn --include='*.tf' --exclude-dir=.terraform -e "$1" "$2" 2>/dev/null |
    grep -Ev '^[^:]+:[0-9]+:[[:space:]]*(#|//)' || true
}

# report <rule id> <message> <scan output>
report() {
  local out="$3" lines=() line
  [ -n "$out" ] || return 0
  while IFS= read -r line; do lines+=("${line#"$ROOT"/}"); done <<<"$out"
  fail "$1" "$2" "${lines[@]}"
}

# (1) FR-8: Terraform creates secret shells only, never values.
report 1 "aws_secretsmanager_secret_version is forbidden (secret values stay out of state)" \
  "$(scan '^[[:space:]]*resource[[:space:]]+"aws_secretsmanager_secret_version"' "$root")"

# (2) Security group rules are standalone resources so default_tags reach them.
report 2 "aws_security_group_rule is forbidden under modules/ (use aws_vpc_security_group_*_rule)" \
  "$(scan '^[[:space:]]*resource[[:space:]]+"aws_security_group_rule"' "$root/modules")"
report 2 "inline ingress/egress block under modules/ (use standalone rule resources)" \
  "$(scan '^[[:space:]]*(ingress|egress)[[:space:]]*\{' "$root/modules")"

# (3) Inline role policies only; no managed ECS execution policy.
report 3 "AmazonECSTaskExecutionRolePolicy is forbidden under modules/ (inline least-privilege policy)" \
  "$(scan 'AmazonECSTaskExecutionRolePolicy' "$root/modules")"
report 3 "aws_iam_role_policy_attachment is forbidden under modules/ (inline policies only)" \
  "$(scan '^[[:space:]]*resource[[:space:]]+"aws_iam_role_policy_attachment"' "$root/modules")"

# (4) Every role under modules/ carries a permissions boundary.
if [ -d "$root/modules" ]; then
  missing="$(
    # shellcheck disable=SC2016  # awk program, not shell
    find "$root/modules" -name '*.tf' -not -path '*/.terraform/*' -print0 |
      xargs -0 awk '
        function flush() { if (inrole && !has) printf "%s:%d: resource aws_iam_role %s\n", file, start, name; inrole = 0 }
        FNR == 1 { flush(); file = FILENAME }
        /^[[:space:]]*#/ { next }
        /^resource[[:space:]]+"aws_iam_role"/ { flush(); inrole = 1; has = 0; start = FNR; name = $3; next }
        /^}/ { flush(); next }
        inrole && /^[[:space:]]*permissions_boundary[[:space:]]*=/ { has = 1 }
        END { flush() }
      ' 2>/dev/null || true
  )"
  report 4 "aws_iam_role without permissions_boundary under modules/" "$missing"
fi

# (5) Backends: the bucket (it holds the account ID) is never in a file; envs use the state key contract.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  hit="$(grep -En '^[[:space:]]*bucket[[:space:]]*=' "$f" || true)"
  [ -z "$hit" ] || report 5 "bucket must not be set in backend.tf (pass -backend-config=bucket=...)" "$f:$hit"
done < <(find "$root" -name backend.tf -not -path '*/.terraform/*' 2>/dev/null)

if [ -d "$root/envs" ]; then
  for f in "$root"/envs/*/backend.tf; do
    [ -f "$f" ] || continue
    env_dir="$(basename "$(dirname "$f")")"
    grep -Eq '^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true' "$f" ||
      fail 5 "envs/$env_dir/backend.tf needs use_lockfile = true" "${f#"$ROOT"/}"
    grep -Eq "^[[:space:]]*key[[:space:]]*=[[:space:]]*\"envs/$env_dir/terraform.tfstate\"" "$f" ||
      fail 5 "envs/$env_dir/backend.tf needs key = \"envs/$env_dir/terraform.tfstate\"" "${f#"$ROOT"/}"
  done
fi

# (6) Modules inherit providers and backends from their root.
report 6 "provider or backend block under modules/ (modules take them from the root)" \
  "$(scan '^[[:space:]]*(provider|backend)[[:space:]]+"' "$root/modules")"

if [ ${#failures[@]} -gt 0 ]; then
  for f in "${failures[@]}"; do printf '  - %s\n' "$f" >&2; done
  die "${#failures[@]} Terraform policy violation(s)"
fi
ok "terraform policy rules pass"
