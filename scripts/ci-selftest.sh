#!/usr/bin/env bash
# Offline self-test of the CI helper scripts (ADR 0004, L1; ADR 0005, F22): the plan summary, the workflow trigger
# allowlist, the tool installer, the AWS config check, and the task definition render and rollout evaluation.
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

# --- render-task-def.sh (fixtures built at run time; 123456789012 is the AWS documentation account)
acct=123456789012
digest="$(printf 'a%.0s' $(seq 1 64))"
image="${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app@sha256:${digest}"
commit="$(printf 'b%.0s' $(seq 1 40))"
cat >"$tmp/td-good.json" <<EOF
{
  "taskDefinitionArn": "arn:aws:ecs:ap-southeast-1:${acct}:task-definition/sis-dev-app:7",
  "family": "sis-dev-app", "revision": 7, "status": "ACTIVE",
  "requiresAttributes": [{"name": "x"}], "compatibilities": ["FARGATE"],
  "registeredAt": "2026-10-26T00:00:00Z", "registeredBy": "arn:aws:sts::${acct}:assumed-role/x/y",
  "deregisteredAt": null, "deleteRequestedAt": null,
  "taskRoleArn": "arn:aws:iam::${acct}:role/sis-dev-ecs-task",
  "executionRoleArn": "arn:aws:iam::${acct}:role/sis-dev-ecs-exec",
  "networkMode": "awsvpc", "cpu": "256", "memory": "512",
  "requiresCompatibilities": ["FARGATE"],
  "runtimePlatform": {"operatingSystemFamily": "LINUX", "cpuArchitecture": "X86_64"},
  "volumes": [{"name": "tmp"}],
  "tags": [{"key": "ManagedBy", "value": "terraform"}],
  "containerDefinitions": [{
    "name": "app", "image": "public.ecr.aws/docker/library/python:3.13-slim@sha256:${digest}",
    "essential": true, "user": "10001:10001", "readonlyRootFilesystem": true,
    "environment": [{"name": "APP_ENV", "value": "dev"}],
    "secrets": [{"name": "APP_API_KEY", "valueFrom": "arn:aws:secretsmanager:ap-southeast-1:${acct}:secret:sis/dev/app-api-key-AbC123"}]
  }]
}
EOF
render() { "$ROOT/scripts/render-task-def.sh" "$1" "$image" "$commit"; }
# mutate <name> <jq filter>: a copy of the good fixture with one thing broken.
mutate() { jq "$2" "$tmp/td-good.json" >"$tmp/td-$1.json"; }

render "$tmp/td-good.json" >"$tmp/td-out.json" 2>/dev/null || die "selftest: good task definition rejected"
jq -e --arg image "$image" --arg sha "$commit" --arg acct "$acct" '
  (keys - ["containerDefinitions","cpu","enableFaultInjection","ephemeralStorage","executionRoleArn","family","inferenceAccelerators","ipcMode","memory","networkMode","pidMode","placementConstraints","proxyConfiguration","requiresCompatibilities","runtimePlatform","tags","taskRoleArn","volumes"]) == []
  and (has("deleteRequestedAt") | not) and (has("revision") | not) and (has("taskDefinitionArn") | not)
  and .containerDefinitions[0].image == $image
  and (.tags | map({(.key): .value}) | add) == {"Project": "ship-it-safely", "Env": "dev", "ManagedBy": "app-deploy", "GitSha": $sha}
  and .cpu == "256" and .memory == "512" and .volumes == [{"name": "tmp"}]
  and .containerDefinitions[0].secrets[0].valueFrom == "arn:aws:secretsmanager:ap-southeast-1:\($acct):secret:sis/dev/app-api-key-AbC123"
  and .executionRoleArn == "arn:aws:iam::\($acct):role/sis-dev-ecs-exec"
' "$tmp/td-out.json" >/dev/null || die "selftest: rendered task definition is not as expected"
ok "render keeps the shape and sets image and tags"

mutate cmd '.containerDefinitions[0].command = ["sh"]'
expect_fail "render with a command" "still has a command" render "$tmp/td-cmd.json"
mutate ep '.containerDefinitions[0].entryPoint = ["sh"]'
expect_fail "render with an entryPoint" "still has a command or entryPoint" render "$tmp/td-ep.json"
mutate two '.containerDefinitions += [.containerDefinitions[0]]'
expect_fail "render with two containers" "exactly one container" render "$tmp/td-two.json"
mutate name '.containerDefinitions[0].name = "web"'
expect_fail "render with another container name" "named app" render "$tmp/td-name.json"
mutate key '.fooBar = 1'
expect_fail "render with an unknown top-level key" "unknown top-level key: fooBar" render "$tmp/td-key.json"
mutate nocpu 'del(.cpu)'
expect_fail "render without task-level cpu" "cpu is missing" render "$tmp/td-nocpu.json"
mutate bigmem '.memory = "2048"'
expect_fail "render with memory 2048" "memory is above 1024" render "$tmp/td-bigmem.json"
mutate bigcpu '.cpu = "1024"'
expect_fail "render with cpu 1024" "cpu is above 512" render "$tmp/td-bigcpu.json"
mutate exec '.executionRoleArn |= sub("sis-dev-ecs-exec"; "other")'
expect_fail "render with the wrong exec role" "role/sis-dev-ecs-exec" render "$tmp/td-exec.json"
mutate task '.taskRoleArn |= sub("sis-dev-ecs-task"; "other")'
expect_fail "render with the wrong task role" "role/sis-dev-ecs-task" render "$tmp/td-task.json"
mutate secret '.containerDefinitions[0].secrets[0].valueFrom |= sub("app-api-key"; "other-key")'
expect_fail "render with another secret" "secrets must be exactly APP_API_KEY" render "$tmp/td-secret.json"
mutate secret2 '.containerDefinitions[0].secrets += [.containerDefinitions[0].secrets[0]]'
expect_fail "render with two secrets" "secrets must be exactly APP_API_KEY" render "$tmp/td-secret2.json"
expect_fail "render with a tag instead of a digest" "image argument" \
  "$ROOT/scripts/render-task-def.sh" "$tmp/td-good.json" "${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app:latest" "$commit"
expect_fail "render with another repository" "image argument" \
  "$ROOT/scripts/render-task-def.sh" "$tmp/td-good.json" "${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/other@sha256:${digest}" "$commit"
expect_fail "render with a short commit" "40 hex" "$ROOT/scripts/render-task-def.sh" "$tmp/td-good.json" "$image" abc123
# A describe-task-definition response (wrapped in "taskDefinition") renders the same as the bare object.
jq '{taskDefinition: ., tags: []}' "$tmp/td-good.json" >"$tmp/td-wrapped.json"
render "$tmp/td-wrapped.json" 2>/dev/null | jq -e '.family == "sis-dev-app"' >/dev/null || die "selftest: wrapped describe output rejected"

# --- ecs-wait-deployment.sh --evaluate
td_new="arn:aws:ecs:ap-southeast-1:${acct}:task-definition/sis-dev-app:8"
td_old="arn:aws:ecs:ap-southeast-1:${acct}:task-definition/sis-dev-app:7"
# svc <status> <deployments json> [events json]
svc() { printf '{"services":[{"status":"%s","deployments":%s,"events":%s}],"failures":[]}' "$1" "$2" "${3:-[]}"; }
# eval_json <describe-services json>: run --evaluate on it.
# Always called inside $( ): the ERR trap is cleared there so exit code 10 (continue) is not reported as a crash.
eval_json() {
  trap - ERR
  printf '%s' "$1" | "$ROOT/scripts/ecs-wait-deployment.sh" --evaluate "$td_new"
}
dep() { printf '{"status":"%s","rolloutState":"%s","taskDefinition":"%s","rolloutStateReason":"%s"}' "$1" "$2" "$3" "${4:-}"; }

out="$(eval_json "$(svc ACTIVE "[$(dep PRIMARY COMPLETED "$td_new")]")" 2>/dev/null)" || die "selftest: completed rollout should succeed"
[ "$out" = "SUCCESS" ] || die "selftest: expected SUCCESS, got $out"
rc=0
out="$(eval_json "$(svc ACTIVE "[$(dep PRIMARY IN_PROGRESS "$td_new"),$(dep ACTIVE COMPLETED "$td_old")]")" 2>/dev/null)" || rc=$?
{ [ "$rc" -eq 10 ] && [ "$out" = "CONTINUE" ]; } || die "selftest: in-progress rollout should continue (exit 10), got $rc $out"
ok "evaluate: success and continue"

failed="[$(dep ACTIVE FAILED "$td_new" "tasks failed to start in ${acct}"),$(dep PRIMARY COMPLETED "$td_old")]"
events="[{\"message\":\"service sis-dev-app (task ${acct}) failed\"}]"
expect_fail "evaluate a failed rollout" "rollout failed" eval_json "$(svc ACTIVE "$failed" "$events")"
out="$(eval_json "$(svc ACTIVE "$failed" "$events")" 2>&1 || true)"
case "$out" in
  *"tasks failed to start in <redacted>"*"task <redacted>"*) ;;
  *) die "selftest: reason and events must be printed with 12-digit runs redacted: $out" ;;
esac
case "$out" in *"$acct"*) die "selftest: the failed rollout output holds a 12-digit run" ;; esac
ok "evaluate: failure prints the reason and redacts digits"

expect_fail "evaluate a rolled-back rollout" "rolled back by the circuit breaker" \
  eval_json "$(svc ACTIVE "[$(dep PRIMARY COMPLETED "$td_old")]")"
expect_fail "evaluate an empty services list" "dev stack is not up" eval_json '{"services":[],"failures":[]}'
expect_fail "evaluate a MISSING failure" "dev stack is not up" eval_json '{"services":[],"failures":[{"reason":"MISSING"}]}'
expect_fail "evaluate an inactive service" "dev stack is not up" eval_json "$(svc DRAINING "[$(dep PRIMARY COMPLETED "$td_new")]")"

# The polling loop, with a stub aws: IN_PROGRESS for the first answers, then COMPLETED; and a rollout that never ends.
mkdir -p "$tmp/stub"
cat >"$tmp/stub/aws" <<EOF
#!/usr/bin/env bash
n=\$(cat "\$STUB_COUNT" 2>/dev/null || echo 0)
echo \$((n + 1)) >"\$STUB_COUNT"
if [ "\$n" -ge "\${STUB_DONE_AFTER:-1}" ]; then state=COMPLETED; else state=IN_PROGRESS; fi
printf '{"services":[{"status":"ACTIVE","events":[],"deployments":[{"status":"PRIMARY","rolloutState":"%s","taskDefinition":"$td_new"}]}],"failures":[]}' "\$state"
EOF
chmod +x "$tmp/stub/aws"
env PATH="$tmp/stub:$PATH" ECS_WAIT_POLL=0 STUB_COUNT="$tmp/stub/count1" "$ROOT/scripts/ecs-wait-deployment.sh" c s "$td_new" 30 >/dev/null 2>&1 \
  || die "selftest: the wait loop should succeed after one poll"
expect_fail "wait that never completes" "timeout after 0s" env PATH="$tmp/stub:$PATH" ECS_WAIT_POLL=0 STUB_DONE_AFTER=99 \
  STUB_COUNT="$tmp/stub/count2" "$ROOT/scripts/ecs-wait-deployment.sh" c s "$td_new" 0
ok "wait loop polls and times out"

# --- install-ci-tools.sh on scratch copies: nothing here touches the network (CI_TOOLS_BASE_URL is a directory)
mkdir -p "$tmp/mirror" "$tmp/pack"
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
for t in terraform tflint trivy hadolint; do
  printf '#!/bin/sh\necho "fake %s"\n' "$t" >"$tmp/pack/$t"
  chmod +x "$tmp/pack/$t"
done
python3 -I - "$tmp" <<'PY'
import sys, zipfile
t = sys.argv[1]
for n in ("terraform", "tflint"):
    with zipfile.ZipFile(f"{t}/mirror/{n}_9.9.9_linux_amd64.zip", "w") as z:
        z.write(f"{t}/pack/{n}", n)
PY
tar -czf "$tmp/mirror/trivy_9.9.9_Linux-64bit.tar.gz" -C "$tmp/pack" trivy
cp "$tmp/pack/hadolint" "$tmp/mirror/hadolint_9.9.9_linux_x86_64"
printf 'terraform = "9.9.9"\ntflint = "9.9.9"\ntrivy = "9.9.9"\nhadolint = "9.9.9"\n' >"$tmp/mise.toml"
: >"$tmp/sums"
for f in terraform_9.9.9_linux_amd64.zip tflint_9.9.9_linux_amd64.zip trivy_9.9.9_Linux-64bit.tar.gz hadolint_9.9.9_linux_x86_64; do
  printf '%s  %s\n' "$(sha256_of "$tmp/mirror/$f")" "$f" >>"$tmp/sums"
done
install_tools() {
  CI_TOOLS_MISE_TOML="$tmp/mise.toml" CI_TOOLS_SHA256="$tmp/sums" CI_TOOLS_BASE_URL="file://$tmp/mirror" \
    "$ROOT/scripts/install-ci-tools.sh" "$@"
}
install_tools "$tmp/bin-default" >"$tmp/install.log" 2>&1 || die "selftest: default install failed: $(cat "$tmp/install.log")"
{ [ -x "$tmp/bin-default/terraform" ] && [ -x "$tmp/bin-default/tflint" ] && [ ! -e "$tmp/bin-default/trivy" ] && [ ! -e "$tmp/bin-default/hadolint" ]; } \
  || die "selftest: no tool arguments must install only terraform and tflint"
install_tools "$tmp/bin-scan" trivy hadolint >"$tmp/install.log" 2>&1 || die "selftest: trivy and hadolint install failed: $(cat "$tmp/install.log")"
{ [ -x "$tmp/bin-scan/trivy" ] && [ -x "$tmp/bin-scan/hadolint" ] && [ ! -e "$tmp/bin-scan/terraform" ]; } || die "selftest: only the named tools may be installed"
ok "installer installs the named tools only"
expect_fail "installer with an unknown tool" "unknown tool 'kubectl'" install_tools "$tmp/bin-x" kubectl
sed -E 's/^[0-9a-f]{64}  trivy/0000000000000000000000000000000000000000000000000000000000000000  trivy/' "$tmp/sums" >"$tmp/sums-bad"
expect_fail "installer with a corrupted trivy hash" "checksum mismatch" env CI_TOOLS_MISE_TOML="$tmp/mise.toml" \
  CI_TOOLS_SHA256="$tmp/sums-bad" CI_TOOLS_BASE_URL="file://$tmp/mirror" "$ROOT/scripts/install-ci-tools.sh" "$tmp/bin-x" trivy
sed -E 's/^(trivy = ).*/\1"9.9.10"/' "$tmp/mise.toml" >"$tmp/mise-bump.toml"
expect_fail "installer with a bumped trivy version" "no checksum for trivy_9.9.10_Linux-64bit.tar.gz" env \
  CI_TOOLS_MISE_TOML="$tmp/mise-bump.toml" CI_TOOLS_SHA256="$tmp/sums" CI_TOOLS_BASE_URL="file://$tmp/mirror" \
  "$ROOT/scripts/install-ci-tools.sh" "$tmp/bin-x" trivy
# The checked-in pins exist for every tool at the version mise.toml names.
for t in terraform tflint trivy hadolint; do
  v="$(sed -nE "s/^${t}[[:space:]]*=[[:space:]]*\"([0-9][^\"]*)\".*/\1/p" "$ROOT/mise.toml" | head -n1)"
  grep -Eq "^[0-9a-f]{64}  ${t}_${v//./\\.}_" "$ROOT/scripts/ci-tools.sha256" || die "selftest: no checked-in checksum for $t $v"
done
ok "checked-in checksums cover every pinned tool"

# --- check-aws-config.sh
role=sis-dev-gha-deploy
good_arn="arn:aws:iam::${acct}:role/${role}"
check_cfg() { env ROLE_ARN="$1" ACCOUNT="$2" REGION="$3" "$ROOT/scripts/check-aws-config.sh" "$role"; }
out="$(check_cfg "$good_arn" "$acct" ap-southeast-1 2>/dev/null)" || die "selftest: good AWS config rejected"
case "$out" in *"::add-mask::${acct}"*) ok "config check masks the account" ;; *) die "selftest: the account was not masked" ;; esac
expect_fail "config with the plan role" "is not the ${role} role ARN" check_cfg "arn:aws:iam::${acct}:role/sis-dev-gha-plan" "$acct" ap-southeast-1
expect_fail "config with another account" "differs from the account" check_cfg "$good_arn" "$leak_id" ap-southeast-1
expect_fail "config with no region" "AWS_REGION is empty" check_cfg "$good_arn" "$acct" ""
expect_fail "config with no secrets" "is empty or not set" check_cfg "" "" ap-southeast-1

# --- redact-account-ids.sh
redacted="$(printf 'role %s failed' "$acct" | "$ROOT/scripts/redact-account-ids.sh")"
[ "$redacted" = "role <redacted> failed" ] || die "selftest: redact filter output was: $redacted"
ok "redact filter replaces 12-digit runs"

# --- Docker-based scripts: their argument contracts are checked here; the full runs (build, smoke, scan) happen in
# app-ci and in `make image smoke scan`, which need Docker and the trivy database.
expect_fail "build-image without arguments" "usage:" "$ROOT/scripts/build-image.sh"
expect_fail "app-smoke without arguments" "usage:" "$ROOT/scripts/app-smoke.sh"
expect_fail "scan-image with one argument" "usage:" "$ROOT/scripts/scan-image.sh" image-only
expect_fail "ecs-wait with two arguments" "usage:" "$ROOT/scripts/ecs-wait-deployment.sh" cluster service
expect_fail "render-task-def without arguments" "usage:" "$ROOT/scripts/render-task-def.sh"

"$ROOT/scripts/check-workflow-triggers.sh"
ok "ci helper self-tests pass"
