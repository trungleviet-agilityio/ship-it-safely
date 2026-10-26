#!/usr/bin/env bash
# Self-test for scripts/tf-policy.sh (ADR 0004, E28): each rule must fail on a bad fixture and pass on a good
# one. Fixtures live in a temporary directory outside the repository.
#
# Usage: scripts/tf-policy-selftest.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

policy="$ROOT/scripts/tf-policy.sh"
n=0

# fixture <name>: create an empty tree with a clean module and env, print its path.
fixture() {
  local d="$tmp_root/$1"
  mkdir -p "$d/modules/m" "$d/envs/dev"
  cat >"$d/modules/m/main.tf" <<'EOF'
# comments may mention aws_secretsmanager_secret_version and AmazonECSTaskExecutionRolePolicy
resource "aws_iam_role" "ok" {
  name                 = "x"
  permissions_boundary = "arn"
  assume_role_policy   = "{}"
}
EOF
  cat >"$d/envs/dev/backend.tf" <<'EOF'
terraform {
  backend "s3" {
    key          = "envs/dev/terraform.tfstate"
    use_lockfile = true
  }
}
EOF
  printf '%s' "$d"
}

# expect_fail <fixture dir> <rule id> : the run must fail and name policy[<id>].
expect_fail() {
  local out rc=0
  n=$((n + 1))
  # The subshell inherits the ERR trap from lib.sh; clear it so the expected failure stays quiet.
  out="$(trap - ERR; "$policy" "$1" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || die "rule $2: expected failure, got success ($1)"
  case "$out" in
    *"policy[$2]"*) ok "rule $2 fails on its bad fixture" ;;
    *) die "rule $2: failed without naming policy[$2]: $out" ;;
  esac
}

d="$(fixture good)"
"$policy" "$d" >/dev/null 2>&1 || die "good fixture must pass"
ok "good fixture passes"

"$policy" "$tmp_root/does-not-exist-parent/none" >/dev/null 2>&1 && die "missing root must fail"
mkdir -p "$tmp_root/empty"
"$policy" "$tmp_root/empty" >/dev/null 2>&1 || die "root without modules/ or envs/ must pass"
ok "absent modules/ and envs/ are no-ops"

d="$(fixture r1)"
printf 'resource "aws_secretsmanager_secret_version" "v" {}\n' >"$d/envs/dev/s.tf"
expect_fail "$d" 1

d="$(fixture r2a)"
printf 'resource "aws_security_group_rule" "r" {}\n' >"$d/modules/m/sg.tf"
expect_fail "$d" 2

d="$(fixture r2b)"
printf 'resource "aws_security_group" "s" {\n  ingress {\n  }\n}\n' >"$d/modules/m/sg.tf"
expect_fail "$d" 2

d="$(fixture r3a)"
printf 'locals { p = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" }\n' >"$d/modules/m/p.tf"
expect_fail "$d" 3

d="$(fixture r3b)"
printf 'resource "aws_iam_role_policy_attachment" "a" {}\n' >"$d/modules/m/p.tf"
expect_fail "$d" 3

d="$(fixture r4)"
printf 'resource "aws_iam_role" "bad" {\n  name = "y"\n}\n' >"$d/modules/m/role.tf"
expect_fail "$d" 4

d="$(fixture r5a)"
printf 'terraform {\n  backend "s3" {\n    bucket = "b"\n    key = "envs/dev/terraform.tfstate"\n    use_lockfile = true\n  }\n}\n' >"$d/envs/dev/backend.tf"
expect_fail "$d" 5

d="$(fixture r5b)"
printf 'terraform {\n  backend "s3" {\n    key = "envs/dev/terraform.tfstate"\n  }\n}\n' >"$d/envs/dev/backend.tf"
expect_fail "$d" 5

d="$(fixture r5c)"
printf 'terraform {\n  backend "s3" {\n    key = "envs/prod/terraform.tfstate"\n    use_lockfile = true\n  }\n}\n' >"$d/envs/dev/backend.tf"
expect_fail "$d" 5

d="$(fixture r6a)"
printf 'provider "aws" {}\n' >"$d/modules/m/prov.tf"
expect_fail "$d" 6

d="$(fixture r6b)"
printf 'terraform {\n  backend "s3" {}\n}\n' >"$d/modules/m/be.tf"
expect_fail "$d" 6

ok "all $n bad fixtures fail with their rule id"
