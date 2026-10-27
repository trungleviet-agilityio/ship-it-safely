#!/usr/bin/env bash
# Self-tests of the CI helper scripts: workflow trigger allowlist and the structure of the workflow files.
# Run by scripts/ci-selftest.sh; also runnable alone. A bad fixture must fail with its message.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

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

# YAML forms a line scanner could miss (ADR 0007 S34): each must fail by name, or by its own reason.
check_triggers() { "$ROOT/scripts/check-workflow-triggers.sh" "$tmp/y.yml"; }
printf 'name: bad\non:\n  pull_request:\n    branches: [main]\n  ? pull_request_target\njobs: {}\n' >"$tmp/y.yml"
expect_fail "explicit ? key" "pull_request_target" check_triggers
printf 'name: bad\non: [\n  push,\n  pull_request_target,\n]\njobs: {}\n' >"$tmp/y.yml"
expect_fail "multi-line flow list" "pull_request_target" check_triggers
printf 'name: bad\nx-triggers: &t [workflow_run]\non: *t\njobs: {}\n' >"$tmp/y.yml"
expect_fail "alias that expands to workflow_run" "workflow_run" check_triggers
printf 'name: bad\n"on":\n  push:\n  issue_comment:\njobs: {}\n' >"$tmp/y.yml"
expect_fail "quoted on key" "issue_comment" check_triggers
printf 'name: bad\non:\n  push:\ntrue:\n  workflow_run:\njobs: {}\n' >"$tmp/y.yml"
expect_fail "on and true (same YAML 1.1 key)" "duplicate key" check_triggers
printf 'name: bad\n"on":\n  push:\ntrue:\n  workflow_run:\njobs: {}\n' >"$tmp/y.yml"
expect_fail "quoted on and true" "both \`on\` and its YAML 1.1 form" check_triggers
printf 'name: bad\non:\n  push:\non:\n  pull_request_target:\njobs: {}\n' >"$tmp/y.yml"
expect_fail "duplicate on keys" "duplicate key" check_triggers
printf 'name: bad\njobs: {}\n' >"$tmp/y.yml"
expect_fail "no on key" "no triggers found" check_triggers
printf -- '- on\n- push\n' >"$tmp/y.yml"
expect_fail "non-mapping document" "not a YAML mapping" check_triggers
printf 'name: bad\non:\n  push: {\njobs: {}\n' >"$tmp/y.yml"
expect_fail "invalid YAML" "invalid YAML" check_triggers
printf 'name: ok\non:\n  push:\n    branches: [main]\n  workflow_dispatch:\njobs: {}\n' >"$tmp/y.yml"
check_triggers >/dev/null 2>&1 || die "selftest: a plain push and dispatch workflow was rejected"
# A missing PyYAML is a clear instruction, not a stack trace.
printf '#!/bin/sh\nexit 1\n' >"$tmp/nopy"
chmod +x "$tmp/nopy"
expect_fail "missing pyyaml" "run make venv" env CI_PYTHON="$tmp/nopy" "$ROOT/scripts/check-workflow-triggers.sh" "$tmp/good.yml"
ok "trigger check reads YAML semantics, not lines"

# No arguments: every file under .github/workflows is scanned, including .yaml and path-filtered ones.
mkdir -p "$tmp/repo/.github/workflows" "$tmp/repo/scripts"
cp "$ROOT/scripts/check-workflow-triggers.sh" "$ROOT/scripts/workflow_triggers.py" "$ROOT/scripts/lib.sh" "$tmp/repo/scripts/"
cp "$tmp/good.yml" "$tmp/repo/.github/workflows/a.yml"
# The copy has its own ROOT, so it cannot find the repo's .venv-ci: hand it the interpreter the real run uses.
ci_python="${CI_PYTHON:-$ROOT/.venv-ci/bin/python}"
[ -x "$ci_python" ] || ci_python=python3
scan_tree() { env CI_PYTHON="$ci_python" "$tmp/repo/scripts/check-workflow-triggers.sh"; }
scan_tree >/dev/null 2>&1 || die "selftest: default scan rejected a good tree"
printf 'name: sneaky\non:\n  pull_request_target:\njobs: {}\n' >"$tmp/repo/.github/workflows/b.yaml"
expect_fail "default scan of a .yaml file" "b.yaml" scan_tree

# --- workflows: path filters list every script the pipeline runs, and build-scan holds no deploy credentials
# check_paths <workflow>: every scripts/*.sh the workflow reaches (directly or through other scripts) is a path filter.
script_refs() { { grep -Eo 'scripts/[a-z0-9-]+\.sh([^a-z0-9]|$)' "$1" || true; } | sed -E 's/[^a-z0-9]$//' | sort -u; }
check_paths() {
  local wf="$1" seen="" queue next s
  queue="$(script_refs "$wf")"
  while [ -n "$queue" ]; do
    next=""
    for s in $queue; do
      case " $seen " in *" $s "*) continue ;; esac
      seen="$seen $s"
      next="$next $(script_refs "$ROOT/$s")"
    done
    queue="$next"
  done
  [ -n "$seen" ] && seen="$seen scripts/lib.sh"  # every script sources lib.sh
  for s in $seen; do
    grep -qxF "      - $s" "$wf" || die "selftest: ${wf##*/} runs $s but does not list it under paths"
  done
}
check_paths "$ROOT/.github/workflows/app-ci.yml"
check_paths "$ROOT/.github/workflows/app-deploy.yml"
check_paths "$ROOT/.github/workflows/terraform-iac.yml"
check_paths "$ROOT/.github/workflows/oidc-smoke-test.yml"
# build_scan_isolated <workflow>: the build-scan job holds no OIDC token, environment or secret.
# Coupling: sed cuts the job out by its header lines, from "  build-scan:" up to the next job "  deploy:". Renaming or
# reordering those two jobs (or changing the two-space job indent) must update this range, or the check would read
# nothing and pass. The mutation tests below fail in that case, because the injected credential goes unseen.
build_scan_isolated() {
  ! sed -n '/^  build-scan:/,/^  deploy:/p' "$1" | grep -Eq 'id-token|environment:|secrets\.'
}
deploy_wf="$ROOT/.github/workflows/app-deploy.yml"
build_scan_isolated "$deploy_wf" || die "selftest: the build-scan job must hold no OIDC token, environment or secret"
# The check must fail on a copy of the workflow with each credential added to build-scan.
sed 's/^  build-scan:$/  build-scan:\n    permissions:\n      id-token: write/' "$deploy_wf" >"$tmp/wf-idtoken.yml"
grep -q 'id-token: write' "$tmp/wf-idtoken.yml" || die "selftest: could not mutate build-scan (id-token)"
! build_scan_isolated "$tmp/wf-idtoken.yml" || die "selftest: the isolation check missed id-token in build-scan"
sed 's/^  build-scan:$/  build-scan:\n    env:\n      X: ${{ secrets.X }}/' "$deploy_wf" >"$tmp/wf-secret.yml"
grep -q 'secrets\.X' "$tmp/wf-secret.yml" || die "selftest: could not mutate build-scan (secrets)"
! build_scan_isolated "$tmp/wf-secret.yml" || die "selftest: the isolation check missed secrets in build-scan"

# --- terraform-destroy.yml (ADR 0006, G16). No check_paths: the workflow has no path filters.
destroy_wf="$ROOT/.github/workflows/terraform-destroy.yml"
iac_wf="$ROOT/.github/workflows/terraform-iac.yml"
# section <workflow> <first line regex> <last line regex>: the lines from the first match to the last match.
# Coupling: the callers below name top-level keys and job headers ("on:", "permissions:", "  confirm:", "  destroy:"),
# so these checks follow the layout of the destroy workflow (jobs in the order confirm, destroy). A layout change
# must change the regexes here; the mutation tests fail if a range stops covering the confirm job.
section() { sed -n "/$2/,/$3/p" "$1"; }
# confirm_isolated <workflow>: the credential-free job holds no OIDC token, environment, secret, checkout or AWS action.
confirm_isolated() {
  ! section "$1" '^  confirm:' '^  destroy:' | grep -Eq 'id-token|environment:|secrets\.|actions/checkout|aws-actions'
}
# only_trigger <workflow> <trigger>: the `on:` block lists exactly that trigger.
only_trigger() {
  [ "$(section "$1" '^on:' '^permissions:' | grep -E '^  [a-z_]+:' | tr -d ' \n')" = "$2:" ]
}
only_trigger "$destroy_wf" workflow_dispatch || die "selftest: terraform-destroy must have workflow_dispatch as its only trigger"
! only_trigger "$iac_wf" workflow_dispatch || die "selftest: the trigger check must fail for a workflow with more triggers"
confirm_isolated "$destroy_wf" || die "selftest: the confirm job must hold no OIDC token, environment, secret or checkout"
# shellcheck disable=SC2016  # the mutations are workflow text, not shell
for add in 'permissions:\n      id-token: write' 'environment: dev' 'env:\n      X: ${{ secrets.X }}' 'steps:\n      - uses: actions/checkout@v1'; do
  # Each mutation adds one credential right under the confirm job header.
  sed "s#^  confirm:\$#  confirm:\n    $add#" "$destroy_wf" >"$tmp/wf-confirm.yml"
  ! cmp -s "$destroy_wf" "$tmp/wf-confirm.yml" || die "selftest: could not mutate confirm ($add)"
  ! confirm_isolated "$tmp/wf-confirm.yml" || die "selftest: the isolation check missed '$add' in confirm"
done
# environment: and id-token: write belong to the destroy job only, never to the top level or confirm.
! sed -n '1,/^jobs:/p' "$destroy_wf" | grep -Eq 'id-token|environment:' || die "selftest: terraform-destroy must set no id-token or environment above its jobs"
destroy_job="$(sed -n '/^  destroy:/,$p' "$destroy_wf")" # the last job of the file
grep -q '^    environment: dev$' <<<"$destroy_job" || die "selftest: the destroy job must use environment dev"
grep -q 'id-token: write' <<<"$destroy_job" || die "selftest: the destroy job must have id-token: write"
# The workflow file path is in the apply and deploy role trust (job_workflow_ref, ADR 0007 S38): every file the bootstrap
# `workflow_files` lists exists, and the two workflows that hold no credentials are never listed.
# workflow_files_ok <locals.tf>: lists the files and checks them against .github/workflows/.
workflow_files_ok() {
  local files f
  files="$(sed -n '/^  workflow_files = {/,/^  }/p' "$1" | grep -Eo '"[A-Za-z0-9._-]+\.ya?ml"' | tr -d '"')"
  [ -n "$files" ] || return 1
  for f in $files; do
    [ -f "$ROOT/.github/workflows/$f" ] || { echo "selftest: workflow_files lists $f, which is not in .github/workflows" >&2; return 1; }
    case "$f" in repo-guard.yml | oidc-smoke-test.yml) echo "selftest: workflow_files must not list $f" >&2; return 1 ;; esac
  done
}
bootstrap_locals="$ROOT/infra/terraform/bootstrap/locals.tf"
workflow_files_ok "$bootstrap_locals" || die "selftest: the bootstrap workflow_files do not match .github/workflows"
for f in terraform-iac.yml terraform-destroy.yml app-deploy.yml; do
  grep -qF "\"$f\"" "$bootstrap_locals" || die "selftest: workflow_files must list $f"
done
sed 's/"app-deploy.yml"/"app-deploy.yml", "no-such-file.yml"/' "$bootstrap_locals" >"$tmp/locals-unknown.tf"
! cmp -s "$bootstrap_locals" "$tmp/locals-unknown.tf" || die "selftest: could not mutate workflow_files (unknown file)"
! workflow_files_ok "$tmp/locals-unknown.tf" 2>/dev/null || die "selftest: the file parity check missed an unknown workflow file"
sed 's/"app-deploy.yml"/"app-deploy.yml", "repo-guard.yml"/' "$bootstrap_locals" >"$tmp/locals-guard.tf"
! workflow_files_ok "$tmp/locals-guard.tf" 2>/dev/null || die "selftest: the file parity check missed repo-guard.yml in the trust"
# Both writers of the dev state share one concurrency group.
for wf in "$destroy_wf" "$iac_wf"; do
  grep -qx '      group: terraform-envs-dev' "$wf" || die "selftest: ${wf##*/} must use the concurrency group terraform-envs-dev"
done
! grep -Eq '^ *queue:' "$destroy_wf" "$iac_wf" || die "selftest: no queue: in the shared concurrency group (actionlint rejects it)"
# The environment choice has one list: the case guard in the confirm job equals the options of the dispatch input.
guard_envs="$(sed -n 's/^ *allowed_envs="\(.*\)"$/\1/p' "$destroy_wf")"
input_envs="$(sed -n 's/^ *options: *\[\(.*\)\]$/\1/p' "$destroy_wf" | tr -d ' ' | tr ',' ' ')"
{ [ -n "$guard_envs" ] && [ "$guard_envs" = "$input_envs" ]; } \
  || die "selftest: the confirm job allowed_envs ('$guard_envs') must equal the input options ('$input_envs')"
# The plan summary runs before the guard, so a refused plan still shows its table.
summary_line="$(grep -n 'name: Summarize the plan' "$destroy_wf" | cut -d: -f1)"
guard_line="$(grep -n 'name: Check that the plan only deletes' "$destroy_wf" | cut -d: -f1)"
{ [ -n "$summary_line" ] && [ -n "$guard_line" ] && [ "$summary_line" -lt "$guard_line" ]; } \
  || die "selftest: the destroy workflow must summarize the plan before the guard step"
# The result summary reports the outcome of the apply step: "deleted" only if it succeeded.
# shellcheck disable=SC2016  # workflow text, not shell
grep -qF 'APPLY_OUTCOME: ${{ steps.destroy.outcome }}' "$destroy_wf" || die "selftest: the destroy result summary must read the apply outcome"
ok "terraform-destroy: dispatch only, credential-free confirm job, trusted file, shared concurrency group"

# One source for the task caps: the iam_deploy.tf conditions equal lib.sh.
tf_cap() { grep -A3 "variable = \"ecs:$1\"" "$ROOT/infra/terraform/bootstrap/iam_deploy.tf" | sed -n 's/.*values *= *\["\([0-9]*\)"\].*/\1/p'; }
[ "$(tf_cap task-cpu)" = "$TASK_CPU_MAX" ] || die "selftest: TASK_CPU_MAX in lib.sh differs from iam_deploy.tf"
[ "$(tf_cap task-memory)" = "$TASK_MEMORY_MAX" ] || die "selftest: TASK_MEMORY_MAX in lib.sh differs from iam_deploy.tf"
# One account-ID check and one role-name helper in the summaries of the three pipelines (the OIDC smoke test checks the
# exact ARN on purpose and is left out): no inline 12-digit pattern, no inline assumed-role ARN parse.
summary_wfs=("$iac_wf" "$destroy_wf" "$deploy_wf")
! grep -En '\[0-9\]\{12\}' "${summary_wfs[@]}" || die "selftest: a workflow holds its own 12-digit pattern; use scripts/assert-no-account-id.sh"
! grep -n 'assumed-role/' "${summary_wfs[@]}" || die "selftest: a workflow parses the assumed-role ARN; use scripts/assumed-role-name.sh"
ok "workflow path filters, build-scan isolation, cap parity and one account-ID check"

# The comment job holds the only write token, so its checkout must be the trusted base commit and never the PR head.
# Coupling: the job is cut out from "  comment:" up to the next job "  apply:"; renaming or reordering them must update
# this range (the mutations below fail if it reads nothing).
# shellcheck disable=SC2016  # workflow text, not shell
comment_uses_base() {
  local job
  job="$(sed -n '/^  comment:/,/^  apply:/p' "$1")"
  grep -qF 'ref: ${{ github.event.pull_request.base.sha }}' <<<"$job" \
    && ! grep -Eq 'pull_request\.head\.(sha|ref)|github\.head_ref' < <(grep -E '^\s+ref:' <<<"$job")
}
comment_uses_base "$iac_wf" || die "selftest: the comment job must check out github.event.pull_request.base.sha and never the head"
# shellcheck disable=SC2016  # workflow text, not shell
grep -v 'ref: \${{ github.event.pull_request.base.sha }}' "$iac_wf" >"$tmp/wf-noref.yml"
! cmp -s "$iac_wf" "$tmp/wf-noref.yml" || die "selftest: could not mutate the comment checkout (no ref)"
! comment_uses_base "$tmp/wf-noref.yml" || die "selftest: the base-ref check missed a comment checkout without ref"
# shellcheck disable=SC2016  # workflow text, not shell
sed 's#ref: \${{ github.event.pull_request.base.sha }}#ref: ${{ github.event.pull_request.head.sha }}#' "$iac_wf" >"$tmp/wf-head.yml"
! cmp -s "$iac_wf" "$tmp/wf-head.yml" || die "selftest: could not mutate the comment checkout (head ref)"
! comment_uses_base "$tmp/wf-head.yml" || die "selftest: the base-ref check missed a head ref in the comment checkout"
ok "comment job checks out the base commit only"

# Action pins (NFR-3, ADR 0007 S1): every `uses:` is a full commit SHA with its version in a comment, and one action
# has one SHA across all workflows, so a half-finished bump (or a tag-only pin) fails here and not only in zizmor.
# pins_ok <workflow file>...
pins_ok() {
  local bad shas
  bad="$(grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:' "$@" | grep -vE 'uses:[[:space:]]+[A-Za-z0-9._/-]+@[0-9a-f]{40}[[:space:]]+# v[0-9]' || true)"
  [ -z "$bad" ] || { printf 'selftest: unpinned action: %s\n' "$bad" >&2; return 1; }
  shas="$(grep -hEo 'uses:[[:space:]]+[A-Za-z0-9._/-]+@[0-9a-f]{40}' "$@" | sed -E 's/uses:[[:space:]]+//' | sort -u | cut -d@ -f1 | uniq -d)"
  [ -z "$shas" ] || { printf 'selftest: more than one SHA for: %s\n' "$shas" >&2; return 1; }
}
all_workflows=("$ROOT"/.github/workflows/*.yml)
pins_ok "${all_workflows[@]}" || die "selftest: a workflow action is not pinned to a SHA with a version comment"
sed -E 's/@[0-9a-f]{40} # v[0-9.]+/@v4/' "$deploy_wf" >"$tmp/wf-tag.yml"
! cmp -s "$deploy_wf" "$tmp/wf-tag.yml" || die "selftest: could not mutate an action pin (tag)"
! pins_ok "$tmp/wf-tag.yml" 2>/dev/null || die "selftest: the pin check missed a tag-only action"
# Same action, other SHA: only the first pinned line of the copy changes.
awk '!done && /uses:.*@[0-9a-f]{40} # v/ { sub(/@[0-9a-f]{40}/, "@0000000000000000000000000000000000000000"); done = 1 } { print }' "$deploy_wf" >"$tmp/wf-other-sha.yml"
! cmp -s "$deploy_wf" "$tmp/wf-other-sha.yml" || die "selftest: could not mutate an action pin (second SHA)"
! pins_ok "$deploy_wf" "$tmp/wf-other-sha.yml" 2>/dev/null || die "selftest: the pin check missed two SHAs for one action"
ok "every action is pinned to one SHA with a version comment"

"$ROOT/scripts/check-workflow-triggers.sh"
