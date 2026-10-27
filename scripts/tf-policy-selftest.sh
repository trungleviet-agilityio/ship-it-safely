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
# comments may mention aws_secretsmanager_secret_version, AmazonECSTaskExecutionRolePolicy and provisioner "x"
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
printf 'data "aws_iam_policy_document" "t" {\n  statement {\n    principals {\n      type        = "Service"\n      identifiers = ["ecs-tasks.amazonaws.com"]\n    }\n  }\n}\n' >"$d/modules/m/trust.tf"
printf 'output "name" {\n  # comments may mention module.x.role_arn and account_id\n  value = module.m.name\n}\n' >"$d/envs/dev/outputs.tf"
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

d="$(fixture r2c)"
printf 'resource "aws_security_group" "s" {\n  dynamic "ingress" {\n  }\n}\n' >"$d/modules/m/sg.tf"
expect_fail "$d" 2

d="$(fixture r2d)"
printf 'resource "aws_security_group" "s" {\n  egress = [\n  ]\n}\n' >"$d/modules/m/sg.tf"
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

d="$(fixture r5d)"
rm "$d/envs/dev/backend.tf"
printf 'terraform {}\n' >"$d/envs/dev/main.tf"
expect_fail "$d" 5

d="$(fixture r7a)"
printf 'data "aws_iam_policy_document" "t" {\n  statement {\n    principals {\n      type        = "AWS"\n      identifiers = ["x"]\n    }\n  }\n}\n' >"$d/modules/m/trust.tf"
expect_fail "$d" 7

d="$(fixture r7b)"
printf 'data "aws_iam_policy_document" "t" {\n  statement {\n    principals {\n      type        = "Service"\n      identifiers = ["arn:aws:iam::1:root"]\n    }\n  }\n}\n' >"$d/modules/m/trust.tf"
expect_fail "$d" 7

d="$(fixture r7c)"
printf 'locals {\n  trust = { Principal = { AWS = "x" } }\n}\n' >"$d/modules/m/trust.tf"
expect_fail "$d" 7

d="$(fixture r7d)"
printf 'locals {\n  trust = { Principal = "*" }\n}\n' >"$d/modules/m/trust.tf"
expect_fail "$d" 7

d="$(fixture r7e)"
printf 'data "aws_iam_policy_document" "t" {\n  statement {\n    principals {\n      type = "*"\n      identifiers = ["*"]\n    }\n  }\n}\n' >"$d/modules/m/trust.tf"
expect_fail "$d" 7

d="$(fixture r7f)"
printf 'locals {\n  trust = { Federated = "x" }\n}\n' >"$d/modules/m/trust.tf"
expect_fail "$d" 7

d="$(fixture r8a)"
printf 'output "a" {\n  value = module.m.role.arn\n}\n' >"$d/envs/dev/outputs.tf"
expect_fail "$d" 8

d="$(fixture r8b)"
printf 'output "a" {\n  value = module.m.ecr_repository_url\n}\n' >"$d/envs/dev/outputs.tf"
expect_fail "$d" 8

d="$(fixture r8c)"
printf 'output "a" {\n  value = module.m.role_arn\n}\n' >"$d/envs/dev/outputs.tf"
expect_fail "$d" 8

d="$(fixture r8d)"
printf 'output "a" {\n  value = data.aws_caller_identity.current.account_id\n}\n' >"$d/envs/dev/outputs.tf"
expect_fail "$d" 8

d="$(fixture r6a)"
printf 'provider "aws" {}\n' >"$d/modules/m/prov.tf"
expect_fail "$d" 6

d="$(fixture r6b)"
printf 'terraform {\n  backend "s3" {}\n}\n' >"$d/modules/m/be.tf"
expect_fail "$d" 6

d="$(fixture r9a)"
printf 'resource "terraform_data" "x" {\n  provisioner "local-exec" {\n    command = "true"\n  }\n}\n' >"$d/modules/m/prov.tf"
expect_fail "$d" 9

d="$(fixture r9b)"
printf 'resource "terraform_data" "x" {\n  provisioner "local-exec" {\n    command = "true"\n  }\n}\n' >"$d/envs/dev/prov.tf"
expect_fail "$d" 9

d="$(fixture r9c)"
printf 'data "external" "x" {\n  program = ["true"]\n}\n' >"$d/modules/m/ext.tf"
expect_fail "$d" 9

d="$(fixture r9d)"
printf 'data "external" "x" {\n  program = ["true"]\n}\n' >"$d/envs/dev/ext.tf"
expect_fail "$d" 9

# Rule 9 also catches bare (unquoted) labels.
d="$(fixture r9e)"
printf 'resource "terraform_data" "x" {\n  provisioner local-exec {\n    command = "true"\n  }\n}\n' >"$d/modules/m/prov.tf"
expect_fail "$d" 9

d="$(fixture r9f)"
printf 'data external x {\n  program = ["true"]\n}\n' >"$d/envs/dev/ext.tf"
expect_fail "$d" 9

# Rule 10: a JSON twin of a configuration file escapes every line based rule.
d="$(fixture r10)"
printf '{"resource": {}}\n' >"$d/envs/dev/main.tf.json"
expect_fail "$d" 10

# Rule 11: module sources are local paths.
d="$(fixture r11a)"
printf 'module "x" { source = "git::https://example.com/m.git" }\n' >"$d/envs/dev/mod.tf"
expect_fail "$d" 11

d="$(fixture r11b)"
printf 'module "x" {\n  source  = "terraform-aws-modules/vpc/aws"\n  version = "1.0.0"\n}\n' >"$d/modules/m/mod.tf"
expect_fail "$d" 11

d="$(fixture r11c)"
printf 'module "x" {\n  name = "n"\n  source = "github.com/example/m"\n}\n' >"$d/envs/dev/mod.tf"
expect_fail "$d" 11

# These must pass: local sources, and a required_providers source (not inside a module block).
d="$(fixture r11ok)"
printf 'module "x" { source = "../../modules/app-ecs" }\nmodule "y" {\n  source = "./y"\n}\n' >"$d/envs/dev/mod.tf"
printf 'terraform {\n  required_providers {\n    aws = {\n      source = "hashicorp/aws"\n    }\n  }\n}\n' >"$d/envs/dev/versions.tf"
"$policy" "$d" >/dev/null 2>&1 || die "local module sources and required_providers sources must pass"
ok "local module sources and required_providers pass rule 11"

ok "all $n bad fixtures fail with their rule id"
