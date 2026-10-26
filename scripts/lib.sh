# shellcheck shell=bash disable=SC2034  # the variables are read by the scripts that source this file
# Shared helpers for scripts/*.sh. Source it; do not run it.
# Written for the bash 3.2 that ships with macOS: no mapfile, no associative arrays, and an empty
# array must not be expanded under `set -u`.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# Colors only on a terminal, so CI logs stay plain (https://no-color.org).
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _blue=$'\033[34m' _green=$'\033[32m' _yellow=$'\033[33m' _red=$'\033[31m' _reset=$'\033[0m'
else
  _blue='' _green='' _yellow='' _red='' _reset=''
fi

# All output goes to stderr, so a script's stdout stays free for data.
log()  { printf '%s==>%s %s\n' "$_blue" "$_reset" "$*" >&2; }
ok()   { printf '%sok%s  %s\n' "$_green" "$_reset" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$_yellow" "$_reset" "$*" >&2; }
# In GitHub Actions the failure also becomes an annotation (the runner reads workflow commands on stderr too).
die() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error::%s\n' "$*" >&2
  else
    printf '%serror%s %s\n' "$_red" "$_reset" "$*" >&2
  fi
  exit 1
}

trap 'die "${BASH_SOURCE[0]##*/}: command failed at line $LINENO"' ERR

# require_cmd <command> <install hint>
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found. Install: $2"
}

# redact_ids: filter that replaces every run of 12 digits with <redacted>, so AWS error text can be logged on a
# public repo.
redact_ids() { sed -E 's/[0-9]{12}/<redacted>/g'; }

# run_capture <command...>: run it without failing the script and record the result in globals:
#   RUN_RC (exit code), RUN_OUT (stdout), RUN_ERR (stderr with 12-digit runs redacted; safe to print).
run_capture() {
  local err_file
  err_file="$(mktemp)"
  RUN_RC=0
  # errtrace (set -E) copies the ERR trap into the substitution, where it would report the expected failure.
  RUN_OUT="$(
    trap - ERR
    "$@" 2>"$err_file"
  )" || RUN_RC=$?
  RUN_ERR="$(redact_ids <"$err_file")"
  rm -f "$err_file"
}

# sha256_of <file>: hex digest on Linux and macOS.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# --- App deploy contract: the one place for names and limits the deploy scripts share.

# image_name <commit sha>: the local image name every build, smoke, scan and push step uses.
image_name() { printf 'sis-app:%s' "$1"; }

# app_names: derive the resource names of one environment from ENV (default dev; ADR 0001, naming).
app_names() {
  ENV="${ENV:-dev}"
  printf '%s' "$ENV" | grep -Eq '^[a-z][a-z0-9]*$' || die "ENV must be lowercase letters and digits, got '$ENV'"
  CLUSTER="sis-${ENV}-cluster" SERVICE="sis-${ENV}-app" FAMILY="sis-${ENV}-app" REPOSITORY="sis-${ENV}-app"
  EXEC_ROLE="sis-${ENV}-ecs-exec" TASK_ROLE="sis-${ENV}-ecs-task"
  SECRET_ID="sis/${ENV}/app-api-key" LOG_GROUP="/ecs/sis-${ENV}-app"
}

# ecs_service_status <cluster> <service>: print ACTIVE, DRAINING, INACTIVE or MISSING (no cluster, no service, or
# an empty answer). Any other error dies with redacted text. Call it as `x="$(ecs_service_status c s)" || exit 1`: the
# helper has already printed the error.
ecs_service_status() {
  run_capture aws ecs describe-services --cluster "$1" --services "$2" --query 'services[0].status' --output text
  if [ "$RUN_RC" -ne 0 ]; then
    case "$RUN_ERR" in
      *ClusterNotFoundException*) printf 'MISSING\n'; return 0 ;;
      *) die "describe-services failed (exit code $RUN_RC): $RUN_ERR" ;;
    esac
  fi
  case "$RUN_OUT" in
    ACTIVE | DRAINING | INACTIVE) printf '%s\n' "$RUN_OUT" ;;
    *) printf 'MISSING\n' ;; # "None", "MISSING" or empty: the service is not there
  esac
}

# Seconds the rollout wait allows before it gives up.
DEFAULT_WAIT_TIMEOUT=1200

# Task-level caps the deploy role allows (ecs:task-cpu and ecs:task-memory conditions in
# infra/terraform/bootstrap/iam_deploy.tf). Keep them equal to that file.
TASK_CPU_MAX=512
TASK_MEMORY_MAX=1024

# Keys of RegisterTaskDefinition (ADR 0005, Finding 6). Shared by render-task-def.sh and its self-test.
REQUEST_KEYS_JSON='["containerDefinitions","cpu","enableFaultInjection","ephemeralStorage","executionRoleArn","family","inferenceAccelerators","ipcMode","memory","networkMode","pidMode","placementConstraints","proxyConfiguration","requiresCompatibilities","runtimePlatform","tags","taskRoleArn","volumes"]'
