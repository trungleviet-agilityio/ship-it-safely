#!/usr/bin/env bash
# Before a deploy, fail early and clearly (ADR 0005, F16, Q2; N4). Needs the AWS CLI with deploy credentials.
# 1. The ECS service must be ACTIVE: a green run must always mean "deployed", so a missing stack fails.
# 2. N4: the deploy role must be denied the secret value (explicit deny, FR-3). The call asks for the secret name
#    only, so even a broken deny could not return the value. Because it is an explicit deny, the answer is
#    AccessDeniedException whether or not the secret exists; anything else is a failure.
# Names derive from ENV (default dev). Error text is printed with 12-digit runs replaced.
#
# Usage: ENV=dev scripts/ecs-preflight.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 0 ] || die "usage: ENV=dev scripts/ecs-preflight.sh"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
app_names

not_up="the ${ENV} stack is not up. Re-create it (terraform-iac, Run workflow), set the secret value, then run app-deploy (Run workflow)."
run_capture aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].status' --output text
if [ "$RUN_RC" -ne 0 ]; then
  case "$RUN_ERR" in
    *ClusterNotFoundException*) die "$not_up" ;;
    *) die "describe-services failed (exit code $RUN_RC): $RUN_ERR" ;;
  esac
fi
[ "$RUN_OUT" = "ACTIVE" ] || die "$not_up"
ok "service is ACTIVE"

run_capture aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query Name --output text
[ "$RUN_RC" -ne 0 ] || die "N4 failed: the deploy role can call GetSecretValue"
case "$RUN_ERR" in
  *AccessDeniedException*) ok "denied as designed (N4): GetSecretValue returned AccessDeniedException" ;;
  *) die "N4 failed for a reason other than access denied (exit code $RUN_RC): $RUN_ERR" ;;
esac
