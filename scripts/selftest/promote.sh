#!/usr/bin/env bash
# Self-tests of the promotion helpers (ADR 0008, P9, P10, S2): image/promote-resolve.sh against a scratch git repository
# and a stub gh, and image/promote-copy.sh against a stub crane and aws. Offline. A bad fixture must fail with its message.
# Run by scripts/ci/selftest.sh; also runnable alone.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

# --- Stub gh and crane. Replies come from files in $sd, like the aws stub in common.sh:
#   gh:    gh-run.out / .err / .rc                      (gh run list)
#   crane: crane-digest-src.*, crane-digest-tgt.*       (digest of the source or the target repository; a `.N` suffix
#          before the extension applies to the N-th call only), crane-copy.*, crane-auth.*
# Every call is logged to $sd/calls; crane also records the DOCKER_CONFIG it ran with in $sd/docker-config.
cat >"$tmp/stub/gh" <<'EOF'
#!/usr/bin/env bash
dir="${STUB_DIR:?}"
echo "gh $*" >>"$dir/calls"
[ -f "$dir/gh-run.out" ] && cat "$dir/gh-run.out"
[ -f "$dir/gh-run.err" ] && cat "$dir/gh-run.err" >&2
[ -f "$dir/gh-run.rc" ] && exit "$(cat "$dir/gh-run.rc")"
exit 0
EOF
cat >"$tmp/stub/crane" <<'EOF'
#!/usr/bin/env bash
dir="${STUB_DIR:?}"
echo "crane $*" >>"$dir/calls"
echo "${DOCKER_CONFIG:-}" >>"$dir/docker-config"
[ -n "${DOCKER_CONFIG:-}" ] && [ -d "$DOCKER_CONFIG" ] || { echo "no DOCKER_CONFIG directory" >&2; exit 9; }
key="crane-$1"
if [ "$1" = digest ]; then
  case "$2" in *sis-dev-app*) key="$key-src" ;; *) key="$key-tgt" ;; esac
fi
[ "$1" = auth ] && cat >/dev/null
n="$(cat "$dir/$key.n" 2>/dev/null || echo 0)"
echo $((n + 1)) >"$dir/$key.n"
pick() { if [ -f "$dir/$key.$1.$n" ]; then echo "$dir/$key.$1.$n"; elif [ -f "$dir/$key.$1" ]; then echo "$dir/$key.$1"; fi; }
f="$(pick out)"; [ -z "$f" ] || cat "$f"
f="$(pick err)"; [ -z "$f" ] || cat "$f" >&2
f="$(pick rc)"; [ -z "$f" ] || exit "$(cat "$f")"
exit 0
EOF
chmod +x "$tmp/stub/gh" "$tmp/stub/crane"

# === promote-resolve.sh: a scratch repository with main (A, B) and a side commit (C) that main does not hold.
repo="$tmp/resolve-repo"
mkdir -p "$repo"
git_in() { git -C "$repo" -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false "$@"; }
git_in init -q
git_in checkout -q -b main
git_in commit -q --allow-empty -m A
sha_a="$(git_in rev-parse HEAD)"
git_in commit -q --allow-empty -m B
sha_b="$(git_in rev-parse HEAD)"
git_in update-ref refs/remotes/origin/main "$sha_b"
git_in checkout -q -b side "$sha_a"
git_in commit -q --allow-empty -m C
sha_c="$(git_in rev-parse HEAD)"
git_in checkout -q main

resolve() { (cd "$repo" && stubbed "$ROOT/scripts/image/promote-resolve.sh" "$@"); }
run_json() { printf '[{"databaseId": 1, "headSha": "%s", "conclusion": "%s"}]' "$1" "$2"; }

expect_fail "resolve without arguments" "usage:" resolve
for bad in "${sha_a:0:12}" "$(printf '%s' "$sha_a" | tr 'a-f' 'A-F')" "${sha_a}0" "main" "$(printf '%s\n%s' "$sha_a" "$sha_a")" ""; do
  stub_reset
  expect_fail "resolve with the bad commit '${bad//$'\n'/ NEWLINE }'" "40 lowercase hex" resolve "$bad"
  ! calls_have "gh " || die "selftest: a malformed commit must not reach gh"
done
stub_reset
expect_fail "resolve with a commit that is not in the checkout" "is not in this checkout" resolve "$(printf 'c%.0s' $(seq 1 40))"
stub_reset
stub gh-run out "$(run_json "$sha_c" success)"
expect_fail "resolve with a commit that is not an ancestor of origin/main" "not an ancestor of origin/main" resolve "$sha_c"
! calls_have "gh " || die "selftest: a commit outside main must not reach gh"
stub_reset
stub gh-run out "[]"
expect_fail "resolve with no successful run" "no successful app-deploy run" resolve "$sha_a"
stub_reset
stub gh-run out "$(run_json "$sha_b" success)"
expect_fail "resolve with a run of another commit" "no successful app-deploy run" resolve "$sha_a"
stub_reset
stub gh-run out "$(run_json "$sha_a" failure)"
expect_fail "resolve with a run that did not succeed" "no successful app-deploy run" resolve "$sha_a"
stub_reset
stub gh-run out "not json"
expect_fail "resolve with an unreadable answer" "no successful app-deploy run" resolve "$sha_a"
stub_reset
stub gh-run rc 1
stub gh-run err "HTTP 403"
expect_fail "resolve when gh fails" "gh run list failed" resolve "$sha_a"
stub_reset
stub gh-run out "$(run_json "$sha_a" success)"
resolve "$sha_a" >/dev/null 2>&1 || die "selftest: a green ancestor of origin/main was refused"
for want in "--workflow app-deploy.yml" "--commit ${sha_a}" "--branch main" "--status success"; do
  calls_have "$want" || die "selftest: gh run list was called without '${want}'"
done
stub_reset
stub gh-run out "$(run_json "$sha_b" success)"
resolve "$sha_b" >/dev/null 2>&1 || die "selftest: the tip of origin/main with a green run was refused"
git_in update-ref -d refs/remotes/origin/main
expect_fail "resolve without origin/main" "could not compare" resolve "$sha_a"
git_in update-ref refs/remotes/origin/main "$sha_b"
ok "promote-resolve: only a green ancestor of origin/main passes"

# === promote-copy.sh: stub crane and aws, a temp dir the test inspects afterwards.
other_acct="$(printf '%s%s' 111111 222222)"
src_repo="${acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-dev-app"
tgt_repo="${other_acct}.dkr.ecr.ap-southeast-1.amazonaws.com/sis-prod-app"
dig_src="sha256:${digest}"
dig_other="sha256:$(printf 'c%.0s' $(seq 1 64))"
base="$tmp/crane-base"
mkdir -p "$base"
copy() { stubbed "$ROOT/scripts/image/promote-copy.sh" "$@"; }
copy_default() { copy "$src_repo" "$tgt_repo" "$commit" "$base"; }
no_leftover() { [ -z "$(ls -A "$base")" ] || die "selftest: $1: the DOCKER_CONFIG directory was not removed"; }
# The directory crane saw must have been inside the temp dir the caller passed.
config_inside_base() { grep -q "^${base}/" "$sd/docker-config" || die "selftest: crane ran with a DOCKER_CONFIG outside the temp dir"; }
# no_host_in <text>: neither registry host nor an account ID may appear.
no_host_in() {
  case "$1" in
    *"amazonaws.com"* | *"$acct"* | *"$other_acct"*) die "selftest: the output holds a registry host or an account ID: $1" ;;
  esac
}
not_called() { ! calls_have "$1" || die "selftest: $2"; }

expect_fail "copy without arguments" "usage:" copy
expect_fail "copy with a bad commit" "40 lowercase hex" copy "$src_repo" "$tgt_repo" "abc" "$base"
expect_fail "copy with a tag as the source" "the source repo must be" copy "${src_repo}:latest" "$tgt_repo" "$commit" "$base"
expect_fail "copy with a foreign host" "the target repo must be" copy "$src_repo" "registry.example.com/sis-prod-app" "$commit" "$base"
expect_fail "copy to the source itself" "must differ" copy "$src_repo" "$src_repo" "$commit" "$base"
expect_fail "copy without a temp dir" "a temp dir is needed" stubbed env -u RUNNER_TEMP "$ROOT/scripts/image/promote-copy.sh" "$src_repo" "$tgt_repo" "$commit"
expect_fail "copy with a missing temp dir" "a temp dir is needed" copy "$src_repo" "$tgt_repo" "$commit" "$tmp/nope"

# Fresh copy: the target has no tag; the source digest is copied by digest and read back equal.
stub_reset
stub crane-digest-tgt rc 1 0
stub crane-digest-tgt err "MANIFEST_UNKNOWN: Requested image not found" 0
stub crane-digest-tgt out "$dig_src" 1
stub crane-digest-src out "$dig_src"
out="$(copy_default 2>"$tmp/err")" || die "selftest: a fresh copy failed: $(cat "$tmp/err")"
[ "$out" = "$(printf 'IMAGE_DIGEST=%s\nPROMOTE_COPIED=true' "$dig_src")" ] || die "selftest: a fresh copy printed: $out"
calls_have "crane copy ${src_repo}@${dig_src} ${tgt_repo}:${commit}" || die "selftest: crane copy must name source@digest and target:sha"
calls_have "crane auth login" || die "selftest: crane was not logged in"
no_leftover "fresh copy"
config_inside_base
no_host_in "$(cat "$tmp/err")"
ok "promote-copy: a fresh copy goes by digest and the target digest is read back"

# Rollback path: the target tag exists and the source is gone (aged out). The digest comes from the target, no copy.
stub_reset
stub crane-digest-tgt out "$dig_src"
stub crane-digest-src rc 1
stub crane-digest-src err "MANIFEST_UNKNOWN: Requested image not found"
out="$(copy_default 2>"$tmp/err")" || die "selftest: the rollback path failed: $(cat "$tmp/err")"
[ "$out" = "$(printf 'IMAGE_DIGEST=%s\nPROMOTE_COPIED=false' "$dig_src")" ] || die "selftest: the rollback path printed: $out"
not_called "crane copy" "an existing target tag must not be copied over"
no_leftover "rollback path"
no_host_in "$(cat "$tmp/err")"

# The target tag exists and the source still holds the same digest: no copy.
stub_reset
stub crane-digest-tgt out "$dig_src"
stub crane-digest-src out "$dig_src"
copy_default >/dev/null 2>&1 || die "selftest: an existing tag with the same digest failed"
not_called "crane copy" "an existing tag with the same digest must not be copied"
no_leftover "same digest"
ok "promote-copy: an existing target tag is reused, with or without the source"

# The target tag exists with another digest than the source: refused, nothing copied.
stub_reset
stub crane-digest-tgt out "$dig_other"
stub crane-digest-src out "$dig_src"
expect_fail "copy where the target tag holds another digest" "one tag, two images" copy_default
not_called "crane copy" "a conflicting target tag must not be overwritten"
no_leftover "conflicting tag"

# The copy lands with another digest: refused, and the message names both digests but no host.
stub_reset
stub crane-digest-tgt rc 1 0
stub crane-digest-tgt err "MANIFEST_UNKNOWN: Requested image not found" 0
stub crane-digest-tgt out "$dig_other" 1
stub crane-digest-src out "$dig_src"
expect_fail "copy that lands with another digest" "digest mismatch after the copy" copy_default
out="$(copy_default 2>&1 || true)"
no_host_in "$out"
no_leftover "digest mismatch"

# A source that never had the tag, a failed copy, a denied digest read and a failed login all stop the run.
stub_reset
stub crane-digest-tgt rc 1
stub crane-digest-tgt err "MANIFEST_UNKNOWN: Requested image not found"
stub crane-digest-src rc 1
stub crane-digest-src err "MANIFEST_UNKNOWN: Requested image not found"
expect_fail "copy with the tag missing on both sides" "the source has no image tagged" copy_default
no_leftover "missing source"
stub_reset
stub crane-digest-tgt rc 1
stub crane-digest-tgt err "MANIFEST_UNKNOWN: Requested image not found"
stub crane-digest-src out "$dig_src"
stub crane-copy rc 1
stub crane-copy err "denied: not authorized to perform ecr:PutImage on ${other_acct}"
expect_fail "copy where crane copy fails" "crane copy failed" copy_default
out="$(copy_default 2>&1 || true)"
case "$out" in *"$other_acct"*) die "selftest: a crane error leaked an account ID" ;; esac
no_leftover "failed copy"
stub_reset
stub crane-digest-tgt rc 1
stub crane-digest-tgt err "denied: not authorized to perform ecr:BatchGetImage"
expect_fail "copy where the target read is denied" "crane digest failed" copy_default
no_leftover "denied read"
stub_reset
stub crane-auth rc 1
stub crane-auth err "login failed"
expect_fail "copy where the registry login fails" "registry login failed" copy_default
no_leftover "failed login"
stub_reset
stub crane-digest-tgt out "not a digest"
expect_fail "copy where crane prints no digest" "unexpected format" copy_default
no_leftover "bad digest"
# RUNNER_TEMP is the default temp dir.
stub_reset
stub crane-digest-tgt out "$dig_src"
stub crane-digest-src out "$dig_src"
RUNNER_TEMP="$base" stubbed "$ROOT/scripts/image/promote-copy.sh" "$src_repo" "$tgt_repo" "$commit" >/dev/null 2>&1 \
  || die "selftest: RUNNER_TEMP was not used as the default temp dir"
no_leftover "RUNNER_TEMP default"
ok "promote-copy: every failure stops the run, leaves no DOCKER_CONFIG and prints no host"
