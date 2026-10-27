#!/usr/bin/env bash
# Self-tests of the CI helper scripts: workflow trigger allowlist and the structure of the workflow files.
# Run by scripts/ci/selftest.sh; also runnable alone. A bad fixture must fail with its message.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

# --- guard/workflow-triggers.sh
# case_check <check script> <label> <expected> <file>: run the check on the file and require either a pass (expected
# "ok") or a failure whose message holds the expected text.
case_check() {
  if [ "$3" = ok ]; then
    "$ROOT/scripts/$1" "$4" >/dev/null 2>&1 || die "selftest: $2 was rejected"
  else
    expect_fail "$2" "$3" "$ROOT/scripts/$1" "$4"
  fi
}
# case_trigger <label> <expected> <yaml>: write the workflow (printf %b escapes) and check its triggers.
case_trigger() {
  printf '%b' "$3" >"$tmp/y.yml"
  case_check guard/workflow-triggers.sh "$1" "$2" "$tmp/y.yml"
}
good_on='name: good\non:\n  pull_request:\n    branches: [main]\n  push:\n    branches: [main]\n  workflow_dispatch:\njobs: {}\n'
case_trigger "a good workflow" ok "$good_on"
for bad in pull_request_target issue_comment workflow_run schedule; do
  case_trigger "trigger $bad" "$bad" "name: bad\non:\n  pull_request:\n  $bad:\njobs: {}\n"
done
case_trigger "flow-style trigger" pull_request_target 'name: bad\non: [push, pull_request_target]\njobs: {}\n'
case_trigger "scalar trigger" pull_request_target 'name: bad\non: pull_request_target\njobs: {}\n'
case_trigger "double-quoted key" pull_request_target 'name: bad\non:\n  pull_request:\n  "pull_request_target":\njobs: {}\n'
case_trigger "single-quoted key" workflow_run "name: bad\non:\n  push:\n  'workflow_run':\n    workflows: [x]\njobs: {}\n"
case_trigger "flow map" issue_comment 'name: bad\n"on": {push: {}, issue_comment: {}}\njobs: {}\n'
case_trigger "explicit ? key" pull_request_target 'name: bad\non:\n  pull_request:\n    branches: [main]\n  ? pull_request_target\njobs: {}\n'
case_trigger "multi-line flow list" pull_request_target 'name: bad\non: [\n  push,\n  pull_request_target,\n]\njobs: {}\n'
case_trigger "alias that expands to workflow_run" workflow_run 'name: bad\nx-triggers: &t [workflow_run]\non: *t\njobs: {}\n'
case_trigger "quoted on key" issue_comment 'name: bad\n"on":\n  push:\n  issue_comment:\njobs: {}\n'
case_trigger "on and true (same YAML 1.1 key)" "duplicate key" 'name: bad\non:\n  push:\ntrue:\n  workflow_run:\njobs: {}\n'
case_trigger "quoted on and true" "both \`on\` and its YAML 1.1 form" 'name: bad\n"on":\n  push:\ntrue:\n  workflow_run:\njobs: {}\n'
case_trigger "duplicate on keys" "duplicate key" 'name: bad\non:\n  push:\non:\n  pull_request_target:\njobs: {}\n'
case_trigger "no on key" "no triggers found" 'name: bad\njobs: {}\n'
case_trigger "an empty on" "no triggers found" 'name: bad\non:\njobs: {}\n'
case_trigger "non-mapping document" "not a YAML mapping" '- on\n- push\n'
case_trigger "invalid YAML" "invalid YAML" 'name: bad\non:\n  push: {\njobs: {}\n'
case_trigger "push and dispatch" ok 'name: ok\non:\n  push:\n    branches: [main]\n  workflow_dispatch:\njobs: {}\n'
# workflow_call is allowed in reusable-*.yml only, and such a file carries no other trigger (ADR 0008, P8).
call_on='name: r\non:\n  workflow_call:\njobs: {}\n'
printf '%b' "$call_on" >"$tmp/reusable-x.yml"
case_check guard/workflow-triggers.sh "a reusable file with workflow_call only" ok "$tmp/reusable-x.yml"
printf '%b' "$call_on" >"$tmp/not-reusable.yml"
case_check guard/workflow-triggers.sh "workflow_call outside reusable-*.yml" "only allowed in a file named reusable" "$tmp/not-reusable.yml"
printf 'name: r\non:\n  workflow_call:\n  push:\njobs: {}\n' >"$tmp/reusable-y.yml"
case_check guard/workflow-triggers.sh "a reusable file with a second trigger" "must use \`workflow_call\` only, found 'push'" "$tmp/reusable-y.yml"
printf 'name: r\non:\n  push:\njobs: {}\n' >"$tmp/reusable-z.yml"
case_check guard/workflow-triggers.sh "a reusable file without workflow_call" "must use \`workflow_call\`" "$tmp/reusable-z.yml"
# A missing PyYAML is a clear instruction, not a stack trace.
printf '#!/bin/sh\nexit 1\n' >"$tmp/nopy"
chmod +x "$tmp/nopy"
printf '%b' "$good_on" >"$tmp/good.yml"
expect_fail "missing pyyaml" "run make venv" env CI_PYTHON="$tmp/nopy" "$ROOT/scripts/guard/workflow-triggers.sh" "$tmp/good.yml"
ok "trigger check reads YAML semantics, not lines"

# No arguments: every file under .github/workflows is scanned, including .yaml and path-filtered ones.
mkdir -p "$tmp/repo/.github/workflows" "$tmp/repo/scripts/guard"
cp "$ROOT/scripts/guard/workflow-triggers.sh" "$ROOT/scripts/guard/workflow_triggers.py" "$ROOT/scripts/guard/workflow_yaml.py" "$tmp/repo/scripts/guard/"
cp "$ROOT/scripts/lib.sh" "$tmp/repo/scripts/"
cp "$tmp/good.yml" "$tmp/repo/.github/workflows/a.yml"
# The copy has its own ROOT, so it cannot find the repo's .venv-ci: hand it the interpreter the real run uses.
ci_python="${CI_PYTHON:-$ROOT/.venv-ci/bin/python}"
[ -x "$ci_python" ] || ci_python=python3
scan_tree() { env CI_PYTHON="$ci_python" "$tmp/repo/scripts/guard/workflow-triggers.sh"; }
scan_tree >/dev/null 2>&1 || die "selftest: default scan rejected a good tree"
printf 'name: sneaky\non:\n  pull_request_target:\njobs: {}\n' >"$tmp/repo/.github/workflows/b.yaml"
expect_fail "default scan of a .yaml file" "b.yaml" scan_tree

# --- workflows: path filters list every script the pipeline runs, and build-scan holds no deploy credentials
# check_paths <workflow> [callee workflow...]: every scripts/*.sh the workflow (and the reusable workflows it calls)
# reaches, directly or through other scripts, is a path filter of the workflow. The callee must be a path filter too.
script_refs() { { grep -Eo 'scripts/[a-z0-9/_-]+\.sh([^a-z0-9]|$)' "$1" || true; } | sed -E 's/[^a-z0-9]$//' | sort -u; }
check_paths() {
  local wf="$1" seen="" queue next s callee
  queue="$(script_refs "$wf")"
  shift
  for callee in "$@"; do
    queue="$queue $(script_refs "$callee")"
    grep -qxF "      - .github/workflows/${callee##*/}" "$wf" || die "selftest: ${wf##*/} calls ${callee##*/} but does not list it under paths"
  done
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
check_paths "$ROOT/.github/workflows/terraform-iac.yml" "$ROOT/.github/workflows/reusable-terraform-plan.yml"
check_paths "$ROOT/.github/workflows/oidc-smoke-test.yml"

# The facts below come from the parsed YAML (selftest/workflow_facts.py on the shared loader), not from text ranges: a
# job is found by its id, and a mutation is a change to the parsed job. `facts <command> <file> [args]`.
py="$(ci_python)"
facts() { "$py" -I "$ROOT/scripts/selftest/workflow_facts.py" "$@"; }
# credential_free <job json> <extra pattern>: the job holds no OIDC token, environment or secret (nor the extra pattern).
credential_free() { ! grep -Eq "id-token|\"environment\"|secrets\\.${2:+|$2}" <<<"$1"; }
# job_json <file> <job id>: the job as JSON. A job that cannot be found fails the self-test (a check must not pass by
# reading nothing).
job_json() { facts job "$1" "$2" || die "selftest: ${1##*/} has no job '$2'"; }
# build_scan_isolated: the build-scan job holds no OIDC token, environment or secret.
deploy_wf="$ROOT/.github/workflows/app-deploy.yml"
credential_free "$(job_json "$deploy_wf" build-scan)" || die "selftest: the build-scan job must hold no OIDC token, environment or secret"
# The check must fail on the job with each credential added.
# shellcheck disable=SC2016  # the mutations are workflow text, not shell
for add in '{"permissions":{"id-token":"write"}}' '{"env":{"X":"${{ secrets.X }}"}}' '{"environment":"dev"}'; do
  credential_free "$(facts merge "$deploy_wf" build-scan "$add")" && die "selftest: the isolation check missed '$add' in build-scan"
done

# --- terraform-destroy.yml (ADR 0006, G16, ADR 0008). No check_paths: the workflow has no path filters.
destroy_wf="$ROOT/.github/workflows/terraform-destroy.yml"
iac_wf="$ROOT/.github/workflows/terraform-iac.yml"
# only_trigger <workflow> <trigger>: the workflow has exactly that trigger.
only_trigger() { [ "$(facts on "$1" | tr -d '\n')" = "$2" ]; }
# confirm_isolated <job json>: the credential-free job holds no OIDC token, environment, secret, checkout or AWS action.
confirm_isolated() { credential_free "$1" 'actions/checkout|aws-actions'; }
only_trigger "$destroy_wf" workflow_dispatch || die "selftest: terraform-destroy must have workflow_dispatch as its only trigger"
only_trigger "$iac_wf" workflow_dispatch && die "selftest: the trigger check must fail for a workflow with more triggers"
confirm_isolated "$(job_json "$destroy_wf" confirm)" || die "selftest: the confirm job must hold no OIDC token, environment, secret or checkout"
# shellcheck disable=SC2016  # the mutations are workflow text, not shell
for add in '{"permissions":{"id-token":"write"}}' '{"environment":"dev"}' '{"env":{"X":"${{ secrets.X }}"}}' \
  '{"steps":[{"uses":"actions/checkout@v1"}]}' '{"steps":[{"uses":"aws-actions/configure-aws-credentials@v1"}]}'; do
  confirm_isolated "$(facts merge "$destroy_wf" confirm "$add")" && die "selftest: the isolation check missed '$add' in confirm"
done
# environment: and id-token: write belong to the destroy job only, never to the top level or confirm.
credential_free "$(facts top "$destroy_wf")" || die "selftest: terraform-destroy must set no id-token or environment above its jobs"
destroy_job="$(job_json "$destroy_wf" destroy)"
# shellcheck disable=SC2016  # workflow expressions, not shell
grep -qF '"environment": "${{ inputs.env }}"' <<<"$destroy_job" || die "selftest: the destroy job must use the environment of the input"
grep -qF '"id-token": "write"' <<<"$destroy_job" || die "selftest: the destroy job must have id-token: write"
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
# Both writers of an environment's state share one concurrency group: the apply job (a push has no input, so dev) and the
# destroy job name it from the same input.
iac_group="$(facts group "$iac_wf" apply | sed "s/ || 'dev'//")"
destroy_group="$(facts group "$destroy_wf" destroy)"
# shellcheck disable=SC2016  # workflow expression, not shell
{ [ "$iac_group" = 'terraform-envs-${{ inputs.env }}' ] && [ "$destroy_group" = "$iac_group" ]; } \
  || die "selftest: apply and destroy must share the concurrency group terraform-envs-<env> (got '$iac_group' and '$destroy_group')"
! grep -Eq '^ *queue:' "$destroy_wf" "$iac_wf" || die "selftest: no queue: in the shared concurrency group (actionlint rejects it)"
# The environment choice has one list: the case guard in the confirm job equals the options of the dispatch input.
guard_envs="$(facts step-run "$destroy_wf" confirm "Check the branch" | sed -n 's/^ *allowed_envs="\(.*\)"$/\1/p')"
input_envs="$(facts options "$destroy_wf" env | tr '\n' ' ' | sed 's/ $//')"
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
summary_wfs=("$iac_wf" "$destroy_wf" "$deploy_wf" "$ROOT/.github/workflows/reusable-terraform-plan.yml")
! grep -En '\[0-9\]\{12\}' "${summary_wfs[@]}" || die "selftest: a workflow holds its own 12-digit pattern; use scripts/aws/assert-no-account-id.sh"
! grep -n 'assumed-role/' "${summary_wfs[@]}" || die "selftest: a workflow parses the assumed-role ARN; use scripts/names.sh role"
ok "workflow path filters, build-scan isolation, cap parity and one account-ID check"

# The comment job holds the only write token, so its checkout must be the trusted base commit and never the PR head.
# The job lives in the reusable plan workflow (ADR 0008, P6) and is read by its id from the parsed YAML.
plan_wf="$ROOT/.github/workflows/reusable-terraform-plan.yml"
# shellcheck disable=SC2016  # workflow text, not shell
base_ref='"ref": "${{ github.event.pull_request.base.sha }}"'
# comment_uses_base <job json>: the checkout pins the base commit, and no `ref` names the PR head.
comment_uses_base() {
  grep -qF "$base_ref" <<<"$1" && ! grep -Eo '"ref": "[^"]*"' <<<"$1" | grep -Eq 'pull_request\.head\.(sha|ref)|github\.head_ref'
}
comment_job="$(job_json "$plan_wf" comment)"
comment_uses_base "$comment_job" || die "selftest: the comment job must check out github.event.pull_request.base.sha and never the head"
comment_uses_base "${comment_job//"$base_ref"/}" && die "selftest: the base-ref check missed a comment checkout without ref"
# shellcheck disable=SC2016  # workflow text, not shell
comment_uses_base "${comment_job//base.sha/head.sha}" && die "selftest: the base-ref check missed a head ref in the comment checkout"
# shellcheck disable=SC2016  # workflow text, not shell
comment_uses_base "$(facts merge "$plan_wf" comment '{"steps":[{"uses":"actions/checkout@v1","with":{"ref":"${{ github.head_ref }}"}}]}')" && die "selftest: the base-ref check missed a second checkout of the head"
ok "comment job checks out the base commit only"
# The plan jobs of the reusable workflow keep the plan role shape: no environment (it would change the OIDC subject),
# and the caller passes secrets by name.
credential_ok_plan() { ! grep -Eq '"environment"' <<<"$1"; }
for j in plan plan-role-guardrails comment; do
  credential_ok_plan "$(job_json "$plan_wf" "$j")" || die "selftest: the reusable plan job '$j' must not set an environment (the plan role trusts the pull_request subject only)"
done
credential_ok_plan "$(facts merge "$plan_wf" plan '{"environment":"dev"}')" && die "selftest: the plan environment check missed an environment"
caller="$(job_json "$iac_wf" plan-dev)"
grep -qF '"uses": "./.github/workflows/reusable-terraform-plan.yml"' <<<"$caller" || die "selftest: plan-dev must call the reusable plan workflow"
grep -qF '"secrets": {' <<<"$caller" || die "selftest: plan-dev must map its secrets by name (never secrets: inherit)"
! grep -qF '"environment"' <<<"$caller" || die "selftest: the plan-dev caller must not set an environment"
ok "reusable plan: no environment on any job, explicit secrets in the caller"

# Action pins (NFR-3, ADR 0007 S1): every `uses:` is a full commit SHA with its version in a comment, and one action
# has one SHA across all workflows, so a half-finished bump (or a tag-only pin) fails here and not only in zizmor.
# pins_ok <workflow file>...
pins_ok() {
  local bad shas
  # A local reusable workflow (./.github/workflows/reusable-*.yml) is the same commit as its caller: no pin.
  bad="$(grep -hE '^[[:space:]]*(-[[:space:]]+)?uses:' "$@" | grep -vE 'uses:[[:space:]]+\./\.github/workflows/reusable-[A-Za-z0-9._-]+\.yml[[:space:]]*$' | grep -vE 'uses:[[:space:]]+[A-Za-z0-9._/-]+@[0-9a-f]{40}[[:space:]]+# v[0-9]' || true)"
  [ -z "$bad" ] || { printf 'selftest: unpinned action: %s\n' "$bad" >&2; return 1; }
  shas="$(grep -hEo 'uses:[[:space:]]+[A-Za-z0-9._/-]+@[0-9a-f]{40}' "$@" | sed -E 's/uses:[[:space:]]+//' | sort -u | cut -d@ -f1 | uniq -d)"
  [ -z "$shas" ] || { printf 'selftest: more than one SHA for: %s\n' "$shas" >&2; return 1; }
}
all_workflows=()
for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
  if [ -f "$f" ]; then all_workflows+=("$f"); fi
done
# A .yaml workflow is read like a .yml one: a tag-only pin in it fails the same check.
printf 'jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n' >"$tmp/wf-yaml-ext.yaml"
! pins_ok "$tmp/wf-yaml-ext.yaml" 2>/dev/null || die "selftest: the pin check missed a tag-only action in a .yaml file"
pins_ok "${all_workflows[@]}" || die "selftest: a workflow action is not pinned to a SHA with a version comment"
sed -E 's/@[0-9a-f]{40} # v[0-9.]+/@v4/' "$deploy_wf" >"$tmp/wf-tag.yml"
! cmp -s "$deploy_wf" "$tmp/wf-tag.yml" || die "selftest: could not mutate an action pin (tag)"
! pins_ok "$tmp/wf-tag.yml" 2>/dev/null || die "selftest: the pin check missed a tag-only action"
# Same action, other SHA: only the first pinned line of the copy changes.
awk '!done && /uses:.*@[0-9a-f]{40} # v/ { sub(/@[0-9a-f]{40}/, "@0000000000000000000000000000000000000000"); done = 1 } { print }' "$deploy_wf" >"$tmp/wf-other-sha.yml"
! cmp -s "$deploy_wf" "$tmp/wf-other-sha.yml" || die "selftest: could not mutate an action pin (second SHA)"
! pins_ok "$deploy_wf" "$tmp/wf-other-sha.yml" 2>/dev/null || die "selftest: the pin check missed two SHAs for one action"
ok "every action is pinned to one SHA with a version comment"

"$ROOT/scripts/guard/workflow-triggers.sh"

# --- guard/harden-runner.sh (ADR 0007 S45)
# write_hardening <file> <job id> <permissions line> <with: lines> [job line] [step line]: a one-job workflow whose
# first step is harden-runner. The with, job and step lines are printf %b text and start with their indent.
write_hardening() {
  printf 'name: x\non: push\njobs:\n  %s:\n    runs-on: ubuntu-24.04\n    permissions:\n      %s\n%b    steps:\n      - uses: step-security/harden-runner@%s # v2.22.2\n%b        with:\n%b      - run: echo hi\n' \
    "$2" "$3" "${5:-}" "$commit" "${6:-}" "$4" >"$1"
}
# case_hardening <label> <expected> <permissions line> <with: lines> [job line] [step line]
case_hardening() {
  write_hardening "$tmp/h.yml" j "$3" "$4" "${5:-}" "${6:-}"
  case_check guard/harden-runner.sh "$1" "$2" "$tmp/h.yml"
}
cred="id-token: write"
audit_with='          egress-policy: audit\n'
block_with='          egress-policy: block\n          disable-telemetry: true\n          disable-sudo-and-containers: true\n'
hosts_head='          allowed-endpoints: >\n'
# shellcheck disable=SC2016  # the ${{ }} is literal fixture text, not a shell expansion
{
good_hosts='            github.com:443\n            sts.${{ vars.AWS_REGION }}.amazonaws.com:443\n            ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.${{ vars.AWS_REGION }}.amazonaws.com:443\n            sis-${{ env.ENV }}-x.s3.${{ vars.AWS_REGION }}.amazonaws.com:443\n'
case_hardening "credentialed job in block with exact hosts" ok "$cred" "${block_with}${hosts_head}${good_hosts}"
case_hardening "credentialed job with another expression" "uses the expression" "$cred" "${block_with}${hosts_head}            \${{ secrets.OTHER }}.example.com:443\n"
case_hardening "credentialed job with a github context host" "uses the expression" "$cred" "${block_with}${hosts_head}            \${{ github.actor }}.example.com:443\n"
case_hardening "credential-free job with a secret host" "reads a secret in a job without credentials" "contents: read" "${audit_with}${hosts_head}            \${{ secrets.AWS_ACCOUNT_ID }}.example.com:443\n"
case_hardening "credential-free job with a non-secret expression" ok "contents: read" "${audit_with}${hosts_head}            \${{ vars.AWS_REGION }}.example.com:443\n"
case_hardening "the old repo-level account secret in a credentialed job" "uses the expression" "$cred" "${block_with}${hosts_head}            \${{ secrets.AWS_ACCOUNT_ID_DEV }}.example.com:443\n"
case_hardening "secrets[ in an audit job" "reads a secret in a job without credentials" "contents: read" "${audit_with}${hosts_head}            \${{ secrets['X'] }}.example.com:443\n"
case_hardening "toJSON(secrets) in an audit job" "reads a secret in a job without credentials" "contents: read" "${audit_with}${hosts_head}            \${{ toJSON(secrets) }}.example.com:443\n"
case_hardening "an env built from a secret in an audit job" "built from a secret" "contents: read" "${audit_with}${hosts_head}            \${{ env.HOST }}.example.com:443\n" '    env:\n      HOST: ${{ secrets.X }}\n'
case_hardening "an env without a secret in an audit job" ok "contents: read" "${audit_with}${hosts_head}            \${{ env.HOST }}.example.com:443\n" '    env:\n      HOST: plain\n'
# A job that calls a reusable workflow has no steps: it must target a local reusable-*.yml and name its secrets.
printf 'name: x\non: push\njobs:\n  c:\n    uses: ./.github/workflows/reusable-x.yml\n    permissions:\n      id-token: write\n    secrets:\n      A: ${{ secrets.B }}\n' >"$tmp/h.yml"
case_check guard/harden-runner.sh "a reusable call with named secrets" ok "$tmp/h.yml"
printf 'name: x\non: push\njobs:\n  c:\n    uses: ./.github/workflows/reusable-x.yml\n    secrets: inherit\n' >"$tmp/h.yml"
case_check guard/harden-runner.sh "a reusable call with secrets: inherit" "never \`secrets: inherit\`" "$tmp/h.yml"
printf 'name: x\non: push\njobs:\n  c:\n    uses: ./.github/workflows/other.yml\n' >"$tmp/h.yml"
case_check guard/harden-runner.sh "a call of a workflow that is not reusable-*.yml" "must target ./.github/workflows/reusable" "$tmp/h.yml"
printf 'name: x\non: push\njobs:\n  c:\n    uses: octo/repo/.github/workflows/reusable-x.yml@main\n' >"$tmp/h.yml"
case_check guard/harden-runner.sh "a call of a remote workflow" "must target ./.github/workflows/reusable" "$tmp/h.yml"
for wild in '*:443''*' '*.amazonaws.com:443' '*.githubusercontent.com:443' '*.github.com:443' '*.s3.ap-southeast-1.amazonaws.com:443' '*.data.mcr.microsoft.com:443' 'sis-*.example.com:443'; do
  case_hardening "wildcard $wild" "holds a wildcard" "$cred" "${block_with}${hosts_head}            ${wild}\n"
done
case_hardening "wildcard in an audit job passes" ok "contents: read" "${audit_with}${hosts_head}            *.data.mcr.microsoft.com:443\n"
}
case_hardening "credential-free job in audit" ok "contents: read" "$audit_with"
case_hardening "credentialed job in audit" "egress-policy must be block" "$cred" "$audit_with"
case_hardening "credentialed job with no policy" "egress-policy must be block" "$cred" '          disable-telemetry: true\n          disable-sudo-and-containers: true\n'
case_hardening "credentialed job with telemetry on" "disable-telemetry must be true" "$cred" '          egress-policy: block\n          disable-sudo-and-containers: true\n'
case_hardening "credentialed job with telemetry false" "disable-telemetry must be true" "$cred" '          egress-policy: block\n          disable-telemetry: false\n          disable-sudo-and-containers: true\n'
case_hardening "credentialed job with sudo and containers on" "disable-sudo-and-containers must be true" "$cred" '          egress-policy: block\n          disable-telemetry: true\n'
case_hardening "credential-free job in block" "egress-policy must be audit" "contents: read" "$block_with"
case_hardening "credential-free job with no policy" "egress-policy must be audit" "contents: read" '          disable-telemetry: true\n'
case_hardening "endpoint without a port" "has no :port" "$cred" "${block_with}${hosts_head}            github.com:443\n            api.github.com\n"
case_hardening "endpoint with a text port" "has no :port" "$cred" "${block_with}${hosts_head}            github.com:https\n"
case_hardening "account ID literal in a host" "12-digit literal" "$cred" "${block_with}${hosts_head}            ${acct}.dkr.ecr.ap-southeast-1.amazonaws.com:443\n"
case_hardening "account ID inside the bucket name" "12-digit literal" "$cred" "${block_with}${hosts_head}            sis-dev-tfstate-${acct}-ap-southeast-1-an.s3.ap-southeast-1.amazonaws.com:443\n"
case_hardening "no allowlist is still block" ok "$cred" "$block_with"
# The harden-runner step must always run and must not be allowed to fail.
case_hardening "harden-runner with if" "must not set \`if:\`" "$cred" "$block_with" "" '        if: always()\n'
case_hardening "harden-runner with continue-on-error" "must not set \`continue-on-error:\`" "$cred" "$block_with" "" '        continue-on-error: true\n'
# A credentialed job runs no container of its own and no service containers.
case_hardening "credentialed job with container" "\`container:\` is not allowed" "$cred" "$block_with" '    container: alpine\n'
case_hardening "credentialed job with services" "\`services:\` is not allowed" "$cred" "$block_with" '    services:\n      db:\n        image: postgres\n'
case_hardening "credential-free job with container" ok "contents: read" "$audit_with" '    container: alpine\n'
# The one named exception: app-deploy.yml deploy needs docker, so it may leave containers on; any other job may not.
mkdir -p "$tmp/exc"
write_hardening "$tmp/exc/app-deploy.yml" deploy "$cred" '          egress-policy: block\n          disable-telemetry: true\n'
case_check guard/harden-runner.sh "app-deploy deploy without disable-sudo-and-containers" ok "$tmp/exc/app-deploy.yml"
write_hardening "$tmp/exc/app-deploy.yml" other "$cred" '          egress-policy: block\n          disable-telemetry: true\n'
case_check guard/harden-runner.sh "another app-deploy job without it" "disable-sudo-and-containers must be true" "$tmp/exc/app-deploy.yml"
write_hardening "$tmp/exc/other.yml" deploy "$cred" '          egress-policy: block\n          disable-telemetry: true\n'
case_check guard/harden-runner.sh "deploy in another file without it" "disable-sudo-and-containers must be true" "$tmp/exc/other.yml"
# A job without credentials in audit may list nothing; a missing harden-runner first step fails.
printf 'name: x\non: push\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n    steps:\n      - run: echo hi\n' >"$tmp/h.yml"
expect_fail "job with no harden-runner first step" "first step is not step-security/harden-runner" "$ROOT/scripts/guard/harden-runner.sh" "$tmp/h.yml"
printf 'name: x\non: push\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    permissions:\n      contents: read\n    steps:\n      - run: echo hi\n      - uses: step-security/harden-runner@%s # v2.22.2\n        with:\n          egress-policy: audit\n' "$commit" >"$tmp/h.yml"
expect_fail "harden-runner not first" "first step is not step-security/harden-runner" "$ROOT/scripts/guard/harden-runner.sh" "$tmp/h.yml"
# A job inherits the workflow permissions: id-token at the top makes every job credentialed.
printf 'name: x\non: push\npermissions:\n  id-token: write\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: step-security/harden-runner@%s # v2.22.2\n        with:\n          egress-policy: audit\n' "$commit" >"$tmp/h.yml"
expect_fail "workflow-level id-token" "egress-policy must be block" "$ROOT/scripts/guard/harden-runner.sh" "$tmp/h.yml"
printf 'name: x\non: push\njobs: {\n' >"$tmp/h.yml"
expect_fail "invalid YAML" "invalid YAML" "$ROOT/scripts/guard/harden-runner.sh" "$tmp/h.yml"
ok "harden-runner policy reads YAML and enforces each rule"

"$ROOT/scripts/guard/harden-runner.sh"
