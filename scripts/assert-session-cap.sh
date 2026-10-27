#!/usr/bin/env bash
# Session cap test (PLAN N9, ADR 0007 S32): a role with max_session_duration 3600 refuses a longer session, and a
# short session reports when it ends. Both calls use the job's own token against the named role, so run it where
# that role trusts the token (the plan role on a pull request). Credentials never reach stdout or the log: the
# successful call keeps only the expiration time.
#
# Usage: scripts/assert-session-cap.sh <plan|apply|deploy>
# Env:   ACCOUNT  AWS account ID (masked)   REGION  AWS region   ENV  environment name (default dev)
#        ACTIONS_ID_TOKEN_REQUEST_URL and _TOKEN (set by GitHub when the job has id-token: write)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 1 ] || die "usage: scripts/assert-session-cap.sh <plan|apply|deploy>"
role="$1"
require_cmd jq "install jq"

token="$(oidc_token sts.amazonaws.com)"

# One second over the cap must be refused for the duration, not for the trust.
web_identity_call "$role" "$token" --duration-seconds 3601 --query Credentials.Expiration --output text
if [ "$RUN_RC" -eq 0 ]; then
  die "a 3601 second session was granted on the ${role} role: max_session_duration is above 3600"
fi
case "$RUN_ERR" in
  *DurationSeconds* | *MaxSessionDuration*) ok "a 3601 second session was refused on the ${role} role (duration limit)" ;;
  *) die "the 3601 second call failed, but not for the duration (exit code ${RUN_RC}): ${RUN_ERR}" ;;
esac

# The shortest session STS allows (900 seconds): the answer is the expiration time only.
web_identity_call "$role" "$token" --duration-seconds 900 --query Credentials.Expiration --output text
[ "$RUN_RC" -eq 0 ] || die "a 900 second session was refused on the ${role} role (exit code ${RUN_RC}): ${RUN_ERR}"
printf 'session expires in about 15 minutes (%s)\n' "$RUN_OUT"
