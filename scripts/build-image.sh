#!/usr/bin/env bash
# Build the app image the way CI and the deploy do (ADR 0005, F6). One platform and no attestations keep a single
# image digest everywhere. The unit tests run inside the build (the runtime stage copies from the test stage).
#
# The Dockerfile pins the base image by digest and takes only the registry as PYTHON_IMAGE, so any mirror that
# serves that digest yields the same bits. Anonymous pulls are limited per IP (ECR Public also by data volume),
# and hosted runners share IPs, so on a registry refusal the build moves to the next mirror; after a full round it
# waits and tries again. Any other failure (a test, the Dockerfile) is final on the first attempt.
#
# Usage: scripts/build-image.sh <commit sha> [image name:tag]   (default: image_name in lib.sh)
# Env:   PYTHON_IMAGE_MIRRORS  registries to try in order (default: ECR Public, then Docker Hub)
#        BUILD_RETRY_DELAYS    seconds to wait before each further round (default "30 60"; the self-test sets "0")
# Exit codes: 0 built, 1 build or test failure.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

DEFAULT_MIRRORS="public.ecr.aws/docker/library/python docker.io/library/python"
# Registry answers that mean "try elsewhere or later": rate and data limits, short outages.
REGISTRY_REFUSALS='429 Too Many Requests|toomanyrequests|503 Service Unavailable|TLS handshake timeout|i/o timeout'

{ [ $# -ge 1 ] && [ $# -le 2 ]; } || die "usage: scripts/build-image.sh <commit sha> [image name:tag]"
sha="$1" image="${2:-$(image_name "$1")}"
require_cmd docker "install Docker"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# build_from <registry>: one build attempt with that base registry; output is shown and kept in $log.
build_from() {
  docker buildx build --platform linux/amd64 --provenance=false --sbom=false --load \
    --build-arg PYTHON_IMAGE="$1" --build-arg GIT_SHA="$sha" -t "$image" "$ROOT/app" 2>&1 | tee "$log"
}

attempts=0
for delay in ${BUILD_RETRY_DELAYS:-30 60} final; do
  for mirror in ${PYTHON_IMAGE_MIRRORS:-$DEFAULT_MIRRORS}; do
    attempts=$((attempts + 1))
    if build_from "$mirror"; then
      ok "built $image (base from $mirror)"
      exit 0
    fi
    grep -Eq "$REGISTRY_REFUSALS" "$log" || die "build failed (not a registry refusal)"
    warn "registry refusal from $mirror on attempt $attempts"
  done
  [ "$delay" != final ] || die "build failed: every registry kept refusing after $attempts attempts"
  warn "all mirrors refused; next round in ${delay}s"
  sleep "$delay"
done
