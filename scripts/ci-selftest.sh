#!/usr/bin/env bash
# Offline self-test of the CI helper scripts (ADR 0004, L1; ADR 0005, F22): the plan summary, the workflow trigger
# allowlist, the tool installer, the AWS config check, the task definition render and rollout evaluation, and the
# deploy helpers (push, preflight, image archive, summary guard) against stub aws and docker commands.
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

# --- render-task-def.sh (fixtures built at run time; 123456789012 is the AWS documentation account).
# td-good.json mimics describe-task-definition for the Terraform revision, with the defaults ECS adds.
acct=123456789012
digest="$(printf 'a%.0s' $(seq 1 64))"
image="${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app@sha256:${digest}"
commit="$(printf 'b%.0s' $(seq 1 40))"
cat >"$tmp/td-good.json" <<EOF
{
  "taskDefinitionArn": "arn:aws:ecs:ap-southeast-1:${acct}:task-definition/sis-dev-app:7",
  "family": "sis-dev-app", "revision": 7, "status": "ACTIVE",
  "requiresAttributes": [{"name": "com.amazonaws.ecs.capability.logging-driver.awslogs"}, {"name": "ecs.capability.execution-role-awslogs"}, {"name": "ecs.capability.secrets.asm.environment-variables"}], "compatibilities": ["FARGATE"],
  "registeredAt": "2026-10-26T00:00:00Z", "registeredBy": "arn:aws:sts::${acct}:assumed-role/x/y",
  "deregisteredAt": null, "deleteRequestedAt": null,
  "taskRoleArn": "arn:aws:iam::${acct}:role/sis-dev-ecs-task",
  "executionRoleArn": "arn:aws:iam::${acct}:role/sis-dev-ecs-exec",
  "networkMode": "awsvpc", "cpu": "256", "memory": "512",
  "requiresCompatibilities": ["FARGATE"],
  "runtimePlatform": {"operatingSystemFamily": "LINUX", "cpuArchitecture": "X86_64"},
  "volumes": [{"name": "tmp", "host": {}}],
  "tags": [{"key": "ManagedBy", "value": "terraform"}],
  "containerDefinitions": [{
    "name": "app", "image": "public.ecr.aws/docker/library/python:3.13-slim@sha256:${digest}",
    "cpu": 0, "essential": true, "user": "10001:10001", "readonlyRootFilesystem": true,
    "portMappings": [{"containerPort": 8080, "hostPort": 8080, "protocol": "tcp"}],
    "mountPoints": [{"sourceVolume": "tmp", "containerPath": "/tmp", "readOnly": false}],
    "volumesFrom": [], "systemControls": [], "versionConsistency": "enabled",
    "environment": [{"name": "APP_ENV", "value": "dev"}],
    "logConfiguration": {"logDriver": "awslogs", "options": {"awslogs-group": "/ecs/sis-dev-app", "awslogs-region": "ap-southeast-1", "awslogs-stream-prefix": "app"}},
    "secrets": [{"name": "APP_API_KEY", "valueFrom": "arn:aws:secretsmanager:ap-southeast-1:${acct}:secret:sis/dev/app-api-key-AbC123"}]
  }]
}
EOF
render() { "$ROOT/scripts/render-task-def.sh" --env dev "$1" "$image" "$commit"; }
# mutate <name> <jq filter>: a copy of the good fixture with one thing broken.
mutate() { jq "$2" "$tmp/td-good.json" >"$tmp/td-$1.json"; }

render "$tmp/td-good.json" >"$tmp/td-out.json" 2>/dev/null || die "selftest: good task definition rejected"
jq -e --arg image "$image" --arg sha "$commit" --arg acct "$acct" --argjson req "$REQUEST_KEYS_JSON" '
  (keys - $req) == []
  and (has("deleteRequestedAt") | not) and (has("revision") | not) and (has("taskDefinitionArn") | not)
  and .containerDefinitions[0].image == $image
  and (.tags | map({(.key): .value}) | add) == {"Project": "ship-it-safely", "Env": "dev", "ManagedBy": "app-deploy", "GitSha": $sha}
  and .cpu == "256" and .memory == "512" and .volumes == [{"name": "tmp", "host": {}}]
  and .containerDefinitions[0].secrets[0].valueFrom == "arn:aws:secretsmanager:ap-southeast-1:\($acct):secret:sis/dev/app-api-key-AbC123"
  and .executionRoleArn == "arn:aws:iam::\($acct):role/sis-dev-ecs-exec"
' "$tmp/td-out.json" >/dev/null || die "selftest: rendered task definition is not as expected"
ok "render keeps the shape and sets image and tags"

mutate cmd '.containerDefinitions[0].command = ["sh"]'
expect_fail "render with a command" "denied container key: command" render "$tmp/td-cmd.json"
mutate ep '.containerDefinitions[0].entryPoint = ["sh"]'
expect_fail "render with an entryPoint" "denied container key: entryPoint" render "$tmp/td-ep.json"
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
# One fixture per rule on the container shape Terraform owns (ADR 0005, M1).
mutate ckey '.containerDefinitions[0].fooBar = true'
expect_fail "render with an unknown container key" "unknown container key: fooBar" render "$tmp/td-ckey.json"
# Every denied key is refused, even though the ECS schema has it (the list is read from the script).
denied_keys="$(sed -n "s/^denied_container_keys='\(.*\)'\$/\1/p" "$ROOT/scripts/render-task-def.sh" | jq -r '.[]')"
[ "$(printf '%s\n' "$denied_keys" | wc -l | tr -d ' ')" -ge 8 ] || die "selftest: could not read the denied container keys"
for k in $denied_keys; do
  mutate "deny-$k" ".containerDefinitions[0].$k = true"
  expect_fail "render with the denied key $k" "denied container key: $k" render "$tmp/td-deny-$k.json"
done
mutate vfrom '.containerDefinitions[0].volumesFrom = [{"sourceContainer": "other"}]'
expect_fail "render with a non-empty volumesFrom" "denied container key: volumesFrom" render "$tmp/td-vfrom.json"
# A schema key that is not denied is accepted.
mutate schemakey '.containerDefinitions[0].workingDirectory = "/"'
render "$tmp/td-schemakey.json" >/dev/null 2>&1 || die "selftest: a schema key that is not denied (workingDirectory) was refused"
mutate user '.containerDefinitions[0].user = "0:0"'
expect_fail "render with another user" "user must be 10001:10001" render "$tmp/td-user.json"
mutate nouser 'del(.containerDefinitions[0].user)'
expect_fail "render without a user" "user must be 10001:10001" render "$tmp/td-nouser.json"
mutate rw '.containerDefinitions[0].readonlyRootFilesystem = false'
expect_fail "render with a writable root" "readonlyRootFilesystem must be true" render "$tmp/td-rw.json"
mutate env2 '.containerDefinitions[0].environment += [{"name": "DEBUG", "value": "1"}]'
expect_fail "render with an extra environment variable" "environment must be exactly APP_ENV" render "$tmp/td-env2.json"
mutate env0 '.containerDefinitions[0].environment = []'
expect_fail "render with no environment" "environment must be exactly APP_ENV" render "$tmp/td-env0.json"
mutate logg '.containerDefinitions[0].logConfiguration.options["awslogs-group"] = "/ecs/other"'
expect_fail "render with another log group" "logConfiguration must be awslogs with the group /ecs/sis-dev-app" render "$tmp/td-logg.json"
mutate logd '.containerDefinitions[0].logConfiguration.logDriver = "splunk"'
expect_fail "render with another log driver" "logConfiguration must be awslogs" render "$tmp/td-logd.json"
mutate mnt '.containerDefinitions[0].mountPoints[0].containerPath = "/data"'
expect_fail "render with another mount path" "exactly the /tmp volume" render "$tmp/td-mnt.json"
mutate mnt2 '.containerDefinitions[0].mountPoints += [{"sourceVolume": "tmp", "containerPath": "/var", "readOnly": false}]'
expect_fail "render with a second mount" "exactly the /tmp volume" render "$tmp/td-mnt2.json"
mutate vol '.volumes += [{"name": "data"}]'
expect_fail "render with a second volume" "exactly the /tmp volume" render "$tmp/td-vol.json"
mutate nocontainers '.containerDefinitions = []'
expect_fail "render with no containers" "exactly one container" render "$tmp/td-nocontainers.json"
# A task definition for another environment renders for that environment only.
sed 's/sis-dev/sis-prod/g; s#sis/dev#sis/prod#g' "$tmp/td-good.json" >"$tmp/td-prod.json"
image_prod="${image/sis-dev-app/sis-prod-app}"
"$ROOT/scripts/render-task-def.sh" --env prod "$tmp/td-prod.json" "$image_prod" "$commit" 2>/dev/null \
  | jq -e '(.tags | map({(.key): .value}) | add).Env == "prod"' >/dev/null || die "selftest: the prod task definition was not rendered with Env prod"
expect_fail "render of the dev task definition for prod" "the group /ecs/sis-prod-app" \
  "$ROOT/scripts/render-task-def.sh" --env prod "$tmp/td-good.json" "$image_prod" "$commit"
expect_fail "render without --env" "usage:" "$ROOT/scripts/render-task-def.sh" "$tmp/td-good.json" "$image" "$commit"
expect_fail "render with an invalid env" "ENV must be lowercase" "$ROOT/scripts/render-task-def.sh" --env "../x" "$tmp/td-good.json" "$image" "$commit"
expect_fail "render with a tag instead of a digest" "image argument" \
  "$ROOT/scripts/render-task-def.sh" --env dev "$tmp/td-good.json" "${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app:latest" "$commit"
expect_fail "render with another repository" "image argument" \
  "$ROOT/scripts/render-task-def.sh" --env dev "$tmp/td-good.json" "${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/other@sha256:${digest}" "$commit"
expect_fail "render with a short commit" "40 hex" "$ROOT/scripts/render-task-def.sh" --env dev "$tmp/td-good.json" "$image" abc123
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
expect_fail "evaluate an empty services list" "stack is not up" eval_json '{"services":[],"failures":[]}'
expect_fail "evaluate a MISSING failure" "stack is not up" eval_json '{"services":[],"failures":[{"reason":"MISSING"}]}'
expect_fail "evaluate an inactive service" "stack is not up" eval_json "$(svc DRAINING "[$(dep PRIMARY COMPLETED "$td_new")]")"

# --- Stub aws and docker: file-driven replies, so the scripts that call them run offline.
# The stub answers a call from files in $sd: <key>.out (stdout), <key>.err (stderr) and <key>.rc (exit code, default
# 0). A suffix .N applies to the N-th call only (0-based). The key is aws-<service>-<operation> or docker-<command>.
mkdir -p "$tmp/stub"
cat >"$tmp/stub/aws" <<'EOF'
#!/usr/bin/env bash
dir="${STUB_DIR:?}" name="$(basename "$0")"
key="$name-$1"
[ "$name" = aws ] && key="$key-$2"
n="$(cat "$dir/$key.n" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$dir/$key.n"
echo "$name $*" >>"$dir/calls"
[ "$name" = docker ] && echo "${DOCKER_CONFIG:-}" >>"$dir/docker-config"
[ "$key" = docker-login ] && cat >/dev/null
[ "$key" = docker-save ] && printf 'image tar' >"$3"
pick() { if [ -f "$dir/$key.$1.$n" ]; then echo "$dir/$key.$1.$n"; elif [ -f "$dir/$key.$1" ]; then echo "$dir/$key.$1"; fi; }
f="$(pick out)"; [ -z "$f" ] || cat "$f"
f="$(pick err)"; [ -z "$f" ] || cat "$f" >&2
f="$(pick rc)"; [ -z "$f" ] || exit "$(cat "$f")"
exit 0
EOF
chmod +x "$tmp/stub/aws"
cp "$tmp/stub/aws" "$tmp/stub/docker"
sd=""
# stub_reset: a fresh reply directory. stub <key> <out|err|rc> <content> [call number]: set one reply.
stub_reset() { sd="$(mktemp -d "$tmp/stub-replies.XXXXXX")"; }
stub() { printf '%s' "$3" >"$sd/$1.$2${4:+.$4}"; }
# stubbed <command...>: run with the stubs first on PATH.
stubbed() { env PATH="$tmp/stub:$PATH" STUB_DIR="$sd" "$@"; }
# calls_have <text>: did the stubs see a call containing it?
calls_have() { grep -qF -- "$1" "$sd/calls" 2>/dev/null; }

# --- build-image.sh mirror policy: a registry refusal moves to the next mirror (same digest); other failures are final.
build() { stubbed env BUILD_RETRY_DELAYS="0" PYTHON_IMAGE_MIRRORS="mirror-a mirror-b" "$ROOT/scripts/build-image.sh" "$commit" sis-app:test; }
data_limit="429 Too Many Requests - Server message: toomanyrequests: Data limit exceeded"
stub_reset
stub docker-buildx rc 1 0
stub docker-buildx err "$data_limit" 0
build >/dev/null 2>&1 || die "selftest: build should succeed from the second mirror"
[ "$(cat "$sd/docker-buildx.n")" = 2 ] || die "selftest: build should have run twice"
for m in mirror-a mirror-b; do
  grep -q "PYTHON_IMAGE=$m" "$sd/calls" || die "selftest: build should have tried $m"
done
ok "build falls back to the next mirror on a registry refusal"
stub_reset
stub docker-buildx rc 1
stub docker-buildx err "FAIL: test_health_ok (test_app.BoardTest)"
expect_fail "build with a failing test" "not a registry refusal" build
[ "$(cat "$sd/docker-buildx.n")" = 1 ] || die "selftest: a failing test must not be retried"
stub_reset
stub docker-buildx rc 1
stub docker-buildx err "$data_limit"
expect_fail "build when every registry keeps refusing" "kept refusing after 4 attempts" build

# --- ecs-wait-deployment.sh polling loop
progress="$(svc ACTIVE "[$(dep PRIMARY IN_PROGRESS "$td_new")]")"
completed="$(svc ACTIVE "[$(dep PRIMARY COMPLETED "$td_new")]")"
wait_script() { stubbed env ECS_WAIT_POLL=0 "$ROOT/scripts/ecs-wait-deployment.sh" c s "$td_new" "$@"; }
stub_reset
stub aws-ecs-describe-services out "$progress" 0
stub aws-ecs-describe-services out "$completed"
wait_script 30 >/dev/null 2>&1 || die "selftest: the wait loop should succeed after one poll"
stub_reset
stub aws-ecs-describe-services out "$progress"
expect_fail "wait that never completes" "timeout after 0s" wait_script 0
throttle="An error occurred (ThrottlingException) when calling the DescribeServices operation for ${acct}"
stub_reset
for n in 0 1; do
  stub aws-ecs-describe-services rc 255 "$n"
  stub aws-ecs-describe-services err "$throttle" "$n"
done
stub aws-ecs-describe-services out "$completed"
out="$(wait_script 30 2>&1)" || die "selftest: two describe-services failures in a row must be tolerated: $out"
case "$out" in *"ThrottlingException"*"<redacted>"*) ;; *) die "selftest: the redacted failure text was not printed: $out" ;; esac
stub_reset
stub aws-ecs-describe-services rc 255
stub aws-ecs-describe-services err "An error occurred (AccessDeniedException) for ${acct}"
out="$(wait_script 30 2>&1 || true)"
case "$out" in
  *"failed 3 times in a row"*"AccessDeniedException"*) ;;
  *) die "selftest: three describe-services failures must stop the wait with the error: $out" ;;
esac
case "$out" in *"stack is not up"* | *"$acct"*) die "selftest: the failure must not blame the stack or print digits: $out" ;; esac
ok "wait loop polls, tolerates two failures, stops on three, and times out"

# --- ecr-push.sh
ref_digest="sha256:${digest}"
oci="application/vnd.oci.image.manifest.v1+json"
ecr_line() { printf '%s\t%s\n' "$1" "$2"; }
ecr_push() { stubbed env ACCOUNT="$acct" REGION=ap-southeast-1 "$ROOT/scripts/ecr-push.sh" sis-dev-app "$commit" sis-app:local; }
stub_reset
stub aws-ecr-describe-images out "$(ecr_line "$ref_digest" "$oci")"
out="$(ecr_push 2>/dev/null)" || die "selftest: ecr-push of an existing tag failed"
[ "$out" = "$(printf 'IMAGE_DIGEST=%s\nIMAGE_REF=%s.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app@%s' "$ref_digest" "$acct" "$ref_digest")" ] \
  || die "selftest: unexpected ecr-push output: $out"
! calls_have "docker push" || die "selftest: an existing tag must not be pushed again"
ok "ecr-push reuses an existing tag"
stub_reset
stub aws-ecr-describe-images rc 254 0
stub aws-ecr-describe-images err "An error occurred (ImageNotFoundException) when calling DescribeImages" 0
stub aws-ecr-describe-images out "$(ecr_line "$ref_digest" "$oci")" 1
ecr_push >/dev/null 2>&1 || die "selftest: ecr-push of a new tag failed"
calls_have "docker push --quiet ${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app:${commit}" || die "selftest: the image was not pushed"
login_dir="$(head -n1 "$sd/docker-config")"
{ [ -n "$login_dir" ] && [ ! -e "$login_dir" ]; } || die "selftest: the temporary registry login was not removed"
ok "ecr-push pushes a new tag with a temporary docker config that is removed"
stub_reset
stub aws-ecr-describe-images rc 254
stub aws-ecr-describe-images err "An error occurred (AccessDeniedException) for ${acct}"
expect_fail "ecr-push on another error" "describe-images failed (exit code 254): An error occurred (AccessDeniedException) for <redacted>" ecr_push
stub_reset
stub aws-ecr-describe-images out "$(ecr_line "$ref_digest" "application/vnd.oci.image.index.v1+json")"
expect_fail "ecr-push of an image index" "not a single image manifest" ecr_push
stub_reset
stub aws-ecr-describe-images out "$(ecr_line "sha256:abc" "$oci")"
expect_fail "ecr-push with a malformed digest" "unexpected format" ecr_push
expect_fail "ecr-push without arguments" "usage:" "$ROOT/scripts/ecr-push.sh"
expect_fail "ecr-push without ACCOUNT" "ACCOUNT and REGION" env -u ACCOUNT "$ROOT/scripts/ecr-push.sh" r t i

# --- ecs-preflight.sh
secret_denied="An error occurred (AccessDeniedException) when calling the GetSecretValue operation for ${acct}"
preflight() { stubbed env ENV="${PREFLIGHT_ENV:-dev}" "$ROOT/scripts/ecs-preflight.sh"; }
preflight_ready() {
  stub_reset
  stub aws-ecs-describe-services out ACTIVE
  stub aws-secretsmanager-get-secret-value rc 254
  stub aws-secretsmanager-get-secret-value err "$secret_denied"
}
preflight_ready
preflight >/dev/null 2>&1 || die "selftest: the preflight of a healthy stack failed"
calls_have "--cluster sis-dev-cluster --services sis-dev-app" || die "selftest: the preflight did not derive the dev names"
calls_have "--secret-id sis/dev/app-api-key" || die "selftest: the preflight did not derive the dev secret"
PREFLIGHT_ENV=prod preflight >/dev/null 2>&1 || die "selftest: the prod preflight failed"
calls_have "--cluster sis-prod-cluster" || die "selftest: the preflight did not derive the prod names"
ok "preflight passes for an active stack and a denied secret"
preflight_ready
stub aws-ecs-describe-services rc 254
stub aws-ecs-describe-services err "An error occurred (ClusterNotFoundException) when calling DescribeServices"
expect_fail "preflight without a cluster" "the dev stack is not up" preflight
preflight_ready
stub aws-ecs-describe-services rc 254
stub aws-ecs-describe-services err "An error occurred (ThrottlingException) for ${acct}"
expect_fail "preflight with throttling" "describe-services failed (exit code 254): An error occurred (ThrottlingException) for <redacted>" preflight
for status in INACTIVE None; do
  preflight_ready
  stub aws-ecs-describe-services out "$status"
  expect_fail "preflight with service status $status" "the dev stack is not up" preflight
done
preflight_ready
stub aws-secretsmanager-get-secret-value rc 0
stub aws-secretsmanager-get-secret-value out "sis/dev/app-api-key"
expect_fail "preflight when the deploy role can read the secret" "N4 failed: the deploy role can call GetSecretValue" preflight
preflight_ready
stub aws-secretsmanager-get-secret-value err "An error occurred (ResourceNotFoundException)"
expect_fail "preflight with another N4 error" "N4 failed for a reason other than access denied" preflight

# --- image-export.sh, image-import.sh
stub_reset
export_out="$(stubbed "$ROOT/scripts/image-export.sh" "$commit" "$tmp/export" 2>/dev/null)" || die "selftest: image-export failed"
[ "$export_out" = "sha256=$(sha256_of "$tmp/export/image.tar")" ] || die "selftest: image-export printed: $export_out"
calls_have "docker save -o $tmp/export/image.tar sis-app:${commit}" || die "selftest: image-export saved the wrong image"
tar_sum="$(sha256_of "$tmp/export/image.tar")"
stub_reset
stubbed "$ROOT/scripts/image-import.sh" "$tmp/export/image.tar" "$tar_sum" >/dev/null 2>&1 || die "selftest: image-import of the right archive failed"
calls_have "docker load -i $tmp/export/image.tar" || die "selftest: image-import did not load the archive"
stub_reset
expect_fail "image-import with the wrong sha256" "differs from the build job output" stubbed "$ROOT/scripts/image-import.sh" "$tmp/export/image.tar" "$digest"
! calls_have "docker load" || die "selftest: a tampered archive must not be loaded"
expect_fail "image-import with a malformed sha256" "64 hex" stubbed "$ROOT/scripts/image-import.sh" "$tmp/export/image.tar" abc
expect_fail "image-import without arguments" "usage:" "$ROOT/scripts/image-import.sh"
ok "image export and import verify the archive before docker load"

# --- assert-no-account-id.sh
[ "$(printf 'commit %s\nok\n' "$commit" | "$ROOT/scripts/assert-no-account-id.sh")" = "$(printf 'commit %s\nok' "$commit")" ] \
  || die "selftest: assert-no-account-id must pass clean text through"
[ "$(printf 'run 0123456789012345678901234567890123456789' | "$ROOT/scripts/assert-no-account-id.sh")" = "run 0123456789012345678901234567890123456789" ] \
  || die "selftest: a long digit string inside a hash must pass"
# shellcheck disable=SC2016  # the inner script is meant to expand in the child shell
expect_fail "summary with a 12-digit run" "12-digit" bash -c 'printf "%s" "$1" | "$2"' _ "role ${leak_id}" "$ROOT/scripts/assert-no-account-id.sh"
# shellcheck disable=SC2016
expect_fail "summary with the exact account" "contains the account ID" bash -c 'printf "%s" "$1" | ACCOUNT=acct-x "$2"' _ "role acct-x" "$ROOT/scripts/assert-no-account-id.sh"
ok "assert-no-account-id passes clean text and refuses account IDs"

# --- lib.sh helpers: die annotation, run_capture, names
# shellcheck disable=SC2016
expect_fail "die inside GitHub Actions" "::error::boom" env GITHUB_ACTIONS=true bash -c 'source "$1/scripts/lib.sh"; die boom' _ "$ROOT"
run_capture bash -c "echo out; echo 'bad ${acct}' >&2; exit 3"
{ [ "$RUN_RC" -eq 3 ] && [ "$RUN_OUT" = "out" ] && [ "$RUN_ERR" = "bad <redacted>" ]; } || die "selftest: run_capture recorded rc=$RUN_RC out=$RUN_OUT err=$RUN_ERR"
names="$(ENV=prod "$ROOT/scripts/app-names.sh")"
[ "$names" = "$(printf 'CLUSTER=sis-prod-cluster\nSERVICE=sis-prod-app\nFAMILY=sis-prod-app\nREPOSITORY=sis-prod-app')" ] || die "selftest: app-names printed: $names"
[ "$("$ROOT/scripts/app-names.sh" | head -n1)" = "CLUSTER=sis-dev-cluster" ] || die "selftest: app-names must default to dev"
[ "$("$ROOT/scripts/image-name.sh" "$commit")" = "sis-app:${commit}" ] || die "selftest: image-name printed the wrong name"
ok "lib helpers: die, run_capture and names"

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
# One source for the task caps: the iam_deploy.tf conditions equal lib.sh.
tf_cap() { grep -A3 "variable = \"ecs:$1\"" "$ROOT/infra/terraform/bootstrap/iam_deploy.tf" | sed -n 's/.*values *= *\["\([0-9]*\)"\].*/\1/p'; }
[ "$(tf_cap task-cpu)" = "$TASK_CPU_MAX" ] || die "selftest: TASK_CPU_MAX in lib.sh differs from iam_deploy.tf"
[ "$(tf_cap task-memory)" = "$TASK_MEMORY_MAX" ] || die "selftest: TASK_MEMORY_MAX in lib.sh differs from iam_deploy.tf"
ok "workflow path filters, build-scan isolation and cap parity"

# --- install-ci-tools.sh on scratch copies: nothing here touches the network (CI_TOOLS_BASE_URL is a directory)
mkdir -p "$tmp/mirror" "$tmp/pack"
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
expect_fail "image-verify without arguments" "usage:" "$ROOT/scripts/image-verify.sh"
expect_fail "image-export without arguments" "usage:" "$ROOT/scripts/image-export.sh"
expect_fail "image-name without arguments" "usage:" "$ROOT/scripts/image-name.sh"
expect_fail "app-names with an argument" "usage:" "$ROOT/scripts/app-names.sh" x
expect_fail "ecs-preflight with an argument" "usage:" "$ROOT/scripts/ecs-preflight.sh" x
expect_fail "assert-no-account-id with an argument" "usage:" "$ROOT/scripts/assert-no-account-id.sh" x
expect_fail "check-aws-config without arguments" "usage:" "$ROOT/scripts/check-aws-config.sh"

"$ROOT/scripts/check-workflow-triggers.sh"
ok "ci helper self-tests pass"
