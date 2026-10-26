#!/usr/bin/env bash
# Deregister every ACTIVE task definition revision of the app family after the stack is destroyed (ADR 0006, G12;
# closes ADR 0005, F23). Terraform deregisters only the revisions it created, so the ones app-deploy registered
# would stay ACTIVE. INACTIVE revisions cost nothing. Needs the AWS CLI with apply credentials (no new permission:
# DescribeTaskDefinition and DeregisterTaskDefinition are already allowed).
# 1. It runs only when the service is gone (MISSING or INACTIVE), so it never pulls a revision from a live service.
# 2. DescribeTaskDefinition with a family returns the latest ACTIVE revision, and ClientException means none is
#    left. Each revision is deregistered once; one that comes back again fails (eventual consistency).
# MAX_REVISIONS (default 200) caps the loop. Prints DEREGISTERED=<count> on stdout. Names derive from ENV.
#
# Usage: ENV=dev scripts/ecs-deregister-revisions.sh >> "$GITHUB_OUTPUT"

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 0 ] || die "usage: ENV=dev scripts/ecs-deregister-revisions.sh"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
app_names
max_revisions="${MAX_REVISIONS:-200}"

status="$(ecs_service_status "$CLUSTER" "$SERVICE")" || exit 1
case "$status" in
  MISSING | INACTIVE) ;;
  *) die "service ${SERVICE} still exists (${status}); not deregistering" ;;
esac

count=0 seen=" "
while :; do
  run_capture aws ecs describe-task-definition --task-definition "$FAMILY" --query taskDefinition.revision --output text
  if [ "$RUN_RC" -ne 0 ]; then
    case "$RUN_ERR" in
      *ClientException*) break ;; # no ACTIVE revision is left
      *) die "describe-task-definition failed (exit code $RUN_RC): $RUN_ERR" ;;
    esac
  fi
  rev="$RUN_OUT"
  printf '%s' "$rev" | grep -Eq '^[0-9]+$' || die "describe-task-definition returned '${rev}', not a revision number"
  case "$seen" in *" $rev "*) die "revision ${rev} returned again (eventual consistency); re-run the job" ;; esac
  [ "$count" -lt "$max_revisions" ] || die "more than ${max_revisions} active revisions; run the job again"
  run_capture aws ecs deregister-task-definition --task-definition "${FAMILY}:${rev}" --query taskDefinition.status --output text
  [ "$RUN_RC" -eq 0 ] || die "deregister-task-definition failed (exit code $RUN_RC): $RUN_ERR"
  [ "$RUN_OUT" = "INACTIVE" ] || die "revision ${rev} is ${RUN_OUT} after deregistering, expected INACTIVE"
  log "deregistered ${FAMILY}:${rev}"
  seen="${seen}${rev} "
  count=$((count + 1))
done

printf 'DEREGISTERED=%s\n' "$count"
