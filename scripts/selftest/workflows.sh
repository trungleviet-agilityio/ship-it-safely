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

# No arguments: every file under .github/workflows is scanned, including .yaml and path-filtered ones.
mkdir -p "$tmp/repo/.github/workflows" "$tmp/repo/scripts"
cp "$ROOT/scripts/check-workflow-triggers.sh" "$ROOT/scripts/lib.sh" "$tmp/repo/scripts/"
cp "$tmp/good.yml" "$tmp/repo/.github/workflows/a.yml"
"$tmp/repo/scripts/check-workflow-triggers.sh" >/dev/null 2>&1 || die "selftest: default scan rejected a good tree"
printf 'name: sneaky\non:\n  pull_request_target:\njobs: {}\n' >"$tmp/repo/.github/workflows/b.yaml"
expect_fail "default scan of a .yaml file" "b.yaml" "$tmp/repo/scripts/check-workflow-triggers.sh"

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
# The workflow name is in the apply role trust, and both writers of the dev state share one concurrency group.
workflow_name="$(sed -n 's/^name: *//p' "$destroy_wf")"
apply_names="$(sed -n 's/^ *apply *= *\[\(.*\)\].*/\1/p' "$ROOT/infra/terraform/bootstrap/locals.tf")"
case ", $apply_names," in
  *", \"$workflow_name\","*) ;;
  *) die "selftest: the workflow name '$workflow_name' is not in the bootstrap workflow_names.apply ($apply_names)" ;;
esac
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
ok "terraform-destroy: dispatch only, credential-free confirm job, trusted name, shared concurrency group"

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

"$ROOT/scripts/check-workflow-triggers.sh"
