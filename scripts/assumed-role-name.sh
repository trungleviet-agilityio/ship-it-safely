#!/usr/bin/env bash
# Print the name of the AWS role the job assumed (never the session name, which carries the run ID), for a job
# summary. Exits 1 when no role is assumed; a summary step turns that into "not assumed". Needs the AWS CLI.
#
# Usage: role="$(scripts/assumed-role-name.sh 2>/dev/null)" || role="not assumed"

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 0 ] || die "usage: scripts/assumed-role-name.sh"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
assumed_role_name || die "the credentials are not an assumed role"
