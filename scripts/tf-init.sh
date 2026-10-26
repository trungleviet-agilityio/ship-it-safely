#!/usr/bin/env bash
# Initialize and validate one environment root for CI (ADR 0006, G15): the one place for the backend bucket name
# (ADR 0002, B8) and the init flags, shared by the plan, apply and destroy jobs. Only infra/terraform/envs/<env> is
# accepted: bootstrap is never initialized in CI (ADR 0004, E4). Reads ACCOUNT and REGION from the environment.
# The bucket name holds the account ID, so the script never prints it.
#
# Usage: ACCOUNT=... REGION=... scripts/tf-init.sh infra/terraform/envs/<env>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 1 ] || die "usage: ACCOUNT=... REGION=... scripts/tf-init.sh infra/terraform/envs/<env>"
dir="$1"
env_name="${dir#infra/terraform/envs/}"
if [ "$env_name" = "$dir" ] || ! printf '%s' "$env_name" | grep -Eq '^[a-z][a-z0-9]*$'; then
  die "only infra/terraform/envs/<env> (env: lowercase letters and digits) can be initialized, got '$dir'"
fi
account="${ACCOUNT:-}" region="${REGION:-}"
[ -n "$account" ] && [ -n "$region" ] || die "ACCOUNT and REGION must be set"
require_cmd terraform "run scripts/install-ci-tools.sh"

bucket="sis-${env_name}-tfstate-${account}-${region}-an"
terraform -chdir="$dir" init -input=false -lockfile=readonly -backend-config="bucket=${bucket}"
terraform -chdir="$dir" validate -no-color
