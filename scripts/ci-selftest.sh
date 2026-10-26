#!/usr/bin/env bash
# Offline self-test of the CI helper scripts (ADR 0004, L1): the plan summary and the workflow trigger allowlist.
# A bad fixture must fail with its message; the real workflow must pass.
#
# Usage: scripts/ci-selftest.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# expect_fail <label> <expected stderr text> <command...>
expect_fail() {
  local label="$1" text="$2" out rc=0
  shift 2
  # The ERR trap from lib.sh would print a second error inside the subshell; the exit code is checked here.
  out="$(
    trap - ERR
    "$@" 2>&1
  )" || rc=$?
  [ "$rc" -ne 0 ] || die "selftest: $label should have failed"
  case "$out" in
    *"$text"*) ok "$label fails as expected" ;;
    *) die "selftest: $label failed without '$text': $out" ;;
  esac
}

# --- tf-plan-summary.sh
good_plan='{"resource_changes":[
 {"address":"module.app_ecs.aws_vpc.this","change":{"actions":["create"]}},
 {"address":"module.app_ecs.aws_lb.this","change":{"actions":["delete","create"]}},
 {"address":"module.app_ecs.aws_ecr_repository.app","change":{"actions":["delete"]}},
 {"address":"module.app_ecs.aws_route.internet","change":{"actions":["no-op"]}}]}'
out="$(printf '%s' "$good_plan" | "$ROOT/scripts/tf-plan-summary.sh")"
case "$out" in
  *"Add 1, change 0, destroy 1, replace 1."*"| REPLACE | \`module.app_ecs.aws_lb.this\` |"*"| DELETE |"*) ok "plan summary counts and flags" ;;
  *) die "selftest: unexpected plan summary: $out" ;;
esac
case "$out" in
  *aws_route.internet*) die "selftest: no-op change must not be listed" ;;
esac
# Built at run time so this file holds no 12-digit literal (the account-ID hook scans it).
leak_id="$(printf '%s%s' 210987 654321)"
leak_plan="{\"resource_changes\":[{\"address\":\"aws_iam_role.x-${leak_id}\",\"change\":{\"actions\":[\"create\"]}}]}"
# shellcheck disable=SC2016  # the inner script is meant to expand in the child shell
expect_fail "plan summary with a 12-digit run" "12-digit" bash -c 'printf "%s" "$1" | "$2"' _ "$leak_plan" "$ROOT/scripts/tf-plan-summary.sh"

# --- check-workflow-triggers.sh
cat >"$tmp/good.yml" <<'EOF'
name: good
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:
jobs: {}
EOF
"$ROOT/scripts/check-workflow-triggers.sh" "$tmp/good.yml" 2>/dev/null || die "selftest: good workflow rejected"
for bad in pull_request_target issue_comment workflow_run schedule; do
  printf 'name: bad\non:\n  pull_request:\n  %s:\njobs: {}\n' "$bad" >"$tmp/bad.yml"
  expect_fail "trigger $bad" "$bad" "$ROOT/scripts/check-workflow-triggers.sh" "$tmp/bad.yml"
done
printf 'name: bad\non: [push, pull_request_target]\njobs: {}\n' >"$tmp/flow.yml"
expect_fail "flow-style trigger" "pull_request_target" "$ROOT/scripts/check-workflow-triggers.sh" "$tmp/flow.yml"
printf 'name: bad\non: pull_request_target\njobs: {}\n' >"$tmp/scalar.yml"
expect_fail "scalar trigger" "pull_request_target" "$ROOT/scripts/check-workflow-triggers.sh" "$tmp/scalar.yml"

printf 'name: bad\non:\n  pull_request:\n  "pull_request_target":\njobs: {}\n' >"$tmp/qd.yml"
expect_fail "double-quoted key" "pull_request_target" "$ROOT/scripts/check-workflow-triggers.sh" "$tmp/qd.yml"
printf "name: bad\non:\n  push:\n  'workflow_run':\n    workflows: [x]\njobs: {}\n" >"$tmp/qs.yml"
expect_fail "single-quoted key" "workflow_run" "$ROOT/scripts/check-workflow-triggers.sh" "$tmp/qs.yml"
printf 'name: bad\n"on": {push: {}, issue_comment: {}}\njobs: {}\n' >"$tmp/fm.yml"
expect_fail "flow map" "issue_comment" "$ROOT/scripts/check-workflow-triggers.sh" "$tmp/fm.yml"

# No arguments: every file under .github/workflows is scanned, including .yaml and path-filtered ones.
mkdir -p "$tmp/repo/.github/workflows" "$tmp/repo/scripts"
cp "$ROOT/scripts/check-workflow-triggers.sh" "$ROOT/scripts/lib.sh" "$tmp/repo/scripts/"
cp "$tmp/good.yml" "$tmp/repo/.github/workflows/a.yml"
"$tmp/repo/scripts/check-workflow-triggers.sh" >/dev/null 2>&1 || die "selftest: default scan rejected a good tree"
printf 'name: sneaky\non:\n  pull_request_target:\njobs: {}\n' >"$tmp/repo/.github/workflows/b.yaml"
expect_fail "default scan of a .yaml file" "b.yaml" "$tmp/repo/scripts/check-workflow-triggers.sh"

"$ROOT/scripts/check-workflow-triggers.sh"
ok "ci helper self-tests pass"
