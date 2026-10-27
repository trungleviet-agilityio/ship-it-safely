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

# The one definition of "looks like an AWS account ID" (the repo is public). ACCOUNT_ID_DIGITS is any run of 12 digits;
# ACCOUNT_ID_RE is a standalone run (alphanumeric boundaries, like the no-aws-account-id pre-commit hook), so a digit
# run inside a hash or a longer number is not a hit.
ACCOUNT_ID_DIGITS='[0-9]{12}'
ACCOUNT_ID_RE="(^|[^0-9A-Za-z])${ACCOUNT_ID_DIGITS}([^0-9A-Za-z]|\$)"

# redact_ids: filter that replaces every run of 12 digits with <redacted>, so AWS error text can be logged on a
# public repo.
redact_ids() { sed -E "s/${ACCOUNT_ID_DIGITS}/<redacted>/g"; }

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

# assert_denied <label> <expected text> <command...>: the call must fail and its stderr must hold the expected text
# (for example AccessDeniedException). A call that succeeds, or fails for any other reason, dies with the redacted
# error, so a broken guardrail and a broken test both turn the job red.
assert_denied() {
  local label="$1" text="$2"
  shift 2
  run_capture "$@"
  [ "$RUN_RC" -ne 0 ] || die "${label} failed: the call succeeded, it must be denied"
  case "$RUN_ERR" in
    *"$text"*) ok "denied as designed (${label}): ${text}" ;;
    *) die "${label} failed for a reason other than ${text} (exit code ${RUN_RC}): ${RUN_ERR}" ;;
  esac
}

# mask <value>: ask the runner to hide a value in every later log line. It prints nothing outside GitHub Actions, so a
# local run or a self-test never carries the value in its output.
mask() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::add-mask::%s\n' "$1" >&2; fi
}

# oidc_token [audience]: (default sts.amazonaws.com) print the job's GitHub OIDC token (needs id-token: write) and mask it. Logs nothing else.
oidc_token() {
  local audience="${1:-sts.amazonaws.com}" response token
  require_cmd jq "install jq"
  [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ] \
    || die "no OIDC token request variables (the job needs id-token: write)"
  # The audience is a query parameter (GitHub OIDC reference).
  response="$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=$audience")" \
    || die "OIDC token request failed (not a role refusal)"
  token="$(jq -r '.value // empty' <<<"$response")"
  [ -n "$token" ] || die "OIDC token response has no value"
  mask "$token"
  printf '%s' "$token"
}

# jwt_claim <token> <claim>: print one claim of a JWT payload (empty when absent). Reads base64url with or without
# padding. Never prints the token.
jwt_claim() {
  local payload
  payload="$(cut -d. -f2 <<<"$1" | tr '_-' '/+')"
  while [ $((${#payload} % 4)) -ne 0 ]; do payload="${payload}="; done
  base64 -d <<<"$payload" | jq -r --arg claim "$2" '.[$claim] // empty'
}

# web_identity_call <role: plan|apply|deploy> <token> [aws args...]: run an unsigned sts assume-role-with-web-identity for
# role sis-<ENV>-gha-<role> in ACCOUNT and REGION (the account is masked). It only builds and runs the command, so
# pass it to assert_denied or run_capture. A success holds credentials: never print its stdout.
web_identity_call() {
  local role="$1" token="$2"
  shift 2
  : "${ACCOUNT:?ACCOUNT is not set}" "${REGION:?REGION is not set}"
  require_env
  case "$role" in plan | apply | deploy) ;; *) die "role must be plan, apply or deploy, got '$role'" ;; esac
  mask "$ACCOUNT"
  # No credentials are needed or sent: --no-sign-request.
  aws sts assume-role-with-web-identity \
    --role-arn "arn:aws:iam::${ACCOUNT}:role/sis-${ENV}-gha-${role}" \
    --role-session-name "gha-oidc-negative-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${role}" \
    --web-identity-token "$token" --region "$REGION" --no-sign-request "$@"
}

# sha256_of <file>: hex digest on Linux and macOS.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# --- App deploy contract: the one place for names and limits the deploy scripts share.

# image_name <commit sha>: the local image name every build, smoke, scan and push step uses.
image_name() { printf 'sis-app:%s' "$1"; }

# valid_env <name>: an environment name is lowercase letters and digits, starting with a letter (ADR 0001, naming).
valid_env() {
  local re='^[a-z][a-z0-9]*$' # [[ =~ ]] matches the whole value, so a newline cannot smuggle a second line past it
  [[ "$1" =~ $re ]]
}

# require_env: ENV defaults to dev and must be a valid environment name.
require_env() {
  ENV="${ENV:-dev}"
  valid_env "$ENV" || die "ENV must be lowercase letters and digits, got '$ENV'"
}

# app_names: derive the resource names of one environment from ENV (default dev; ADR 0001, naming).
app_names() {
  require_env
  CLUSTER="sis-${ENV}-cluster" SERVICE="sis-${ENV}-app" FAMILY="sis-${ENV}-app" REPOSITORY="sis-${ENV}-app"
  EXEC_ROLE="sis-${ENV}-ecs-exec" TASK_ROLE="sis-${ENV}-ecs-task"
  SECRET_ID="sis/${ENV}/app-api-key" LOG_GROUP="/ecs/sis-${ENV}-app"
}

# ecs_service_status <cluster> <service>: set SERVICE_STATUS to ACTIVE, DRAINING, INACTIVE or MISSING. MISSING covers
# no cluster and the answers "None", "MISSING" and empty. Any other error or status dies with redacted text, so a
# new or unexpected answer never reads as "the service is gone".
ecs_service_status() {
  SERVICE_STATUS=""
  run_capture aws ecs describe-services --cluster "$1" --services "$2" --query 'services[0].status' --output text
  if [ "$RUN_RC" -ne 0 ]; then
    case "$RUN_ERR" in
      *ClusterNotFoundException*) SERVICE_STATUS=MISSING; return 0 ;;
      *) die "describe-services failed (exit code $RUN_RC): $RUN_ERR" ;;
    esac
  fi
  case "$RUN_OUT" in
    None | MISSING | "") SERVICE_STATUS=MISSING ;;
    ACTIVE | DRAINING | INACTIVE) SERVICE_STATUS="$RUN_OUT" ;;
    *) die "describe-services returned an unexpected status: $(printf '%s' "$RUN_OUT" | redact_ids)" ;;
  esac
}

# assumed_role_name: print the name of the role the current AWS credentials assumed, never the session name (it
# carries the run ID). Returns 1 when the caller is not an assumed role. Summaries use it because
# configure-aws-credentials masks the whole ARN in logs.
assumed_role_name() {
  local arn
  run_capture aws sts get-caller-identity --query Arn --output text
  [ "$RUN_RC" -eq 0 ] || return 1
  arn="$RUN_OUT"
  case "$arn" in
    *:assumed-role/*) arn="${arn#*:assumed-role/}"; printf '%s\n' "${arn%%/*}" ;;
    *) return 1 ;;
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
