#!/usr/bin/env bash
# Print the resource names of one environment as KEY=value lines, ready to append to $GITHUB_ENV.
# ENV selects the environment (default dev); the derivation is app_names in lib.sh.
#
# Usage: ENV=dev scripts/app-names.sh >> "$GITHUB_ENV"

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 0 ] || die "usage: ENV=dev scripts/app-names.sh"
app_names
printf '%s=%s\n' CLUSTER "$CLUSTER" SERVICE "$SERVICE" FAMILY "$FAMILY" REPOSITORY "$REPOSITORY"
