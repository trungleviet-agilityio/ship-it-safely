#!/usr/bin/env bash
# Build the app image the way CI and the deploy do (ADR 0005, F6). One platform and no attestations keep a single
# image digest everywhere. The unit tests run inside the build (the runtime stage copies from the test stage).
# Anonymous base-image pulls from ECR Public are rate limited per IP, and hosted runners share IPs, so a build that
# fails only on a transient registry error is retried with backoff. Any other failure (a test, the Dockerfile) is
# final on the first attempt.
#
# Usage: scripts/build-image.sh <commit sha> [image name:tag]   (default: image_name in lib.sh)
# Env:   BUILD_RETRY_DELAYS  seconds to wait before each retry (default "15 30 60"; the self-test sets "0 0")
# Exit codes: 0 built, 1 build or test failure.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# Registry answers worth retrying: rate limits and short outages. Matched against the build output.
TRANSIENT_REGISTRY_ERRORS='429 Too Many Requests|toomanyrequests|503 Service Unavailable|TLS handshake timeout|i/o timeout'

{ [ $# -ge 1 ] && [ $# -le 2 ]; } || die "usage: scripts/build-image.sh <commit sha> [image name:tag]"
sha="$1" image="${2:-$(image_name "$1")}"
require_cmd docker "install Docker"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# build_once: one build attempt; the output is shown and kept in $log for classification.
build_once() {
  docker buildx build --platform linux/amd64 --provenance=false --sbom=false --load \
    --build-arg GIT_SHA="$sha" -t "$image" "$ROOT/app" 2>&1 | tee "$log"
}

attempt=1
for delay in ${BUILD_RETRY_DELAYS:-15 30 60} final; do
  if build_once; then
    ok "built $image"
    exit 0
  fi
  grep -Eq "$TRANSIENT_REGISTRY_ERRORS" "$log" || die "build failed (not a transient registry error)"
  [ "$delay" != final ] || die "build failed: the registry kept refusing after $attempt attempts"
  warn "transient registry error on attempt $attempt; retrying in ${delay}s"
  sleep "$delay"
  attempt=$((attempt + 1))
done
