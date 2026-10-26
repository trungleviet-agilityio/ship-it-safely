#!/usr/bin/env bash
# Print the local image name for a commit (the single definition is image_name in lib.sh).
#
# Usage: scripts/image-name.sh <commit sha>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 1 ] || die "usage: scripts/image-name.sh <commit sha>"
image_name "$1"
echo
