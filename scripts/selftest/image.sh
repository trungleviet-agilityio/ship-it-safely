#!/usr/bin/env bash
# Self-tests of the CI helper scripts: the image build mirror policy, the ECR push and the image archive export and import.
# Run by scripts/ci-selftest.sh; also runnable alone. A bad fixture must fail with its message.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

# --- build-image.sh mirror policy: a registry refusal moves to the next mirror (same digest); other failures are final.
build() { stubbed env BUILD_RETRY_DELAYS="0" PYTHON_IMAGE_MIRRORS="mirror-a mirror-b" "$ROOT/scripts/build-image.sh" "$commit" sis-app:test; }
data_limit="429 Too Many Requests - Server message: toomanyrequests: Data limit exceeded"
stub_reset
stub docker-buildx rc 1 0
stub docker-buildx err "$data_limit" 0
build >/dev/null 2>&1 || die "selftest: build should succeed from the second mirror"
[ "$(cat "$sd/docker-buildx.n")" = 2 ] || die "selftest: build should have run twice"
for m in mirror-a mirror-b; do
  grep -q "PYTHON_IMAGE=$m" "$sd/calls" || die "selftest: build should have tried $m"
done
ok "build falls back to the next mirror on a registry refusal"
stub_reset
stub docker-buildx rc 1
stub docker-buildx err "FAIL: test_health_ok (test_app.BoardTest)"
expect_fail "build with a failing test" "not a registry refusal" build
[ "$(cat "$sd/docker-buildx.n")" = 1 ] || die "selftest: a failing test must not be retried"
stub_reset
stub docker-buildx rc 1
stub docker-buildx err "$data_limit"
expect_fail "build when every registry keeps refusing" "kept refusing after 4 attempts" build

# --- ecr-push.sh
ref_digest="sha256:${digest}"
oci="application/vnd.oci.image.manifest.v1+json"
ecr_line() { printf '%s\t%s\n' "$1" "$2"; }
ecr_push() { stubbed env ACCOUNT="$acct" REGION=ap-southeast-1 "$ROOT/scripts/ecr-push.sh" sis-dev-app "$commit" sis-app:local; }
stub_reset
stub aws-ecr-describe-images out "$(ecr_line "$ref_digest" "$oci")"
out="$(ecr_push 2>/dev/null)" || die "selftest: ecr-push of an existing tag failed"
[ "$out" = "$(printf 'IMAGE_DIGEST=%s\nIMAGE_REF=%s.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app@%s' "$ref_digest" "$acct" "$ref_digest")" ] \
  || die "selftest: unexpected ecr-push output: $out"
! calls_have "docker push" || die "selftest: an existing tag must not be pushed again"
ok "ecr-push reuses an existing tag"
stub_reset
stub aws-ecr-describe-images rc 254 0
stub aws-ecr-describe-images err "An error occurred (ImageNotFoundException) when calling DescribeImages" 0
stub aws-ecr-describe-images out "$(ecr_line "$ref_digest" "$oci")" 1
ecr_push >/dev/null 2>&1 || die "selftest: ecr-push of a new tag failed"
calls_have "docker push --quiet ${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app:${commit}" || die "selftest: the image was not pushed"
login_dir="$(head -n1 "$sd/docker-config")"
{ [ -n "$login_dir" ] && [ ! -e "$login_dir" ]; } || die "selftest: the temporary registry login was not removed"
ok "ecr-push pushes a new tag with a temporary docker config that is removed"
stub_reset
stub aws-ecr-describe-images rc 254
stub aws-ecr-describe-images err "An error occurred (AccessDeniedException) for ${acct}"
expect_fail "ecr-push on another error" "describe-images failed (exit code 254): An error occurred (AccessDeniedException) for <redacted>" ecr_push
stub_reset
stub aws-ecr-describe-images out "$(ecr_line "$ref_digest" "application/vnd.oci.image.index.v1+json")"
expect_fail "ecr-push of an image index" "not a single image manifest" ecr_push
stub_reset
stub aws-ecr-describe-images out "$(ecr_line "sha256:abc" "$oci")"
expect_fail "ecr-push with a malformed digest" "unexpected format" ecr_push

# --- image-export.sh, image-import.sh
stub_reset
export_out="$(stubbed "$ROOT/scripts/image-export.sh" "$commit" "$tmp/export" 2>/dev/null)" || die "selftest: image-export failed"
[ "$export_out" = "sha256=$(sha256_of "$tmp/export/image.tar")" ] || die "selftest: image-export printed: $export_out"
calls_have "docker save -o $tmp/export/image.tar sis-app:${commit}" || die "selftest: image-export saved the wrong image"
tar_sum="$(sha256_of "$tmp/export/image.tar")"
stub_reset
stubbed "$ROOT/scripts/image-import.sh" "$tmp/export/image.tar" "$tar_sum" >/dev/null 2>&1 || die "selftest: image-import of the right archive failed"
calls_have "docker load -i $tmp/export/image.tar" || die "selftest: image-import did not load the archive"
stub_reset
expect_fail "image-import with the wrong sha256" "differs from the build job output" stubbed "$ROOT/scripts/image-import.sh" "$tmp/export/image.tar" "$digest"
! calls_have "docker load" || die "selftest: a tampered archive must not be loaded"
expect_fail "image-import with a malformed sha256" "64 hex" stubbed "$ROOT/scripts/image-import.sh" "$tmp/export/image.tar" abc
ok "image export and import verify the archive before docker load"
