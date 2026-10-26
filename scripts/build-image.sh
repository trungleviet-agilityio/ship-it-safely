#!/usr/bin/env bash
# Build the app image the way CI and the deploy do (ADR 0005, F6). One platform and no attestations keep a single
# image digest everywhere. The unit tests run inside the build (the runtime stage copies from the test stage).
#
# Usage: scripts/build-image.sh <commit sha> [image name:tag]   (default: image_name in lib.sh)
# Exit codes: 0 built, 1 build or test failure.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

{ [ $# -ge 1 ] && [ $# -le 2 ]; } || die "usage: scripts/build-image.sh <commit sha> [image name:tag]"
sha="$1" image="${2:-$(image_name "$1")}"
require_cmd docker "install Docker"

docker buildx build --platform linux/amd64 --provenance=false --sbom=false --load \
  --build-arg GIT_SHA="$sha" -t "$image" "$ROOT/app"
ok "built $image"
