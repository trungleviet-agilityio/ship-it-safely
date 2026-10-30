#!/usr/bin/env bash
# shellcheck disable=SC2119,SC2120  # sticky() takes optional overrides; most calls pass none
# Self-tests of the GitHub helper scripts: the sticky pull request comment. Run by scripts/ci/selftest.sh; also
# runnable alone. A bad fixture must fail with its message. The gh stub answers from files (see common.sh); the
# first `gh api` call lists the comments, the second one writes.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

cp "$tmp/stub/aws" "$tmp/stub/gh"
marker='<!-- app-preview:pr -->'
bot='github-actions[bot]'

# sticky [VAR=value...]: the script under test with valid inputs, then the overrides.
sticky() {
  stubbed env GH_TOKEN=token REPO=owner/repo PR_NUMBER=7 MARKER="$marker" BODY="Preview ready" "$@" "$ROOT/scripts/gh/sticky-comment.sh"
}

# --- No comment with the marker yet: post a new one.
stub_reset
stub gh-api out '[]' 0
sticky >/dev/null 2>&1 || die "selftest: sticky comment should post when none exists"
calls_have "gh api -X POST repos/owner/repo/issues/7/comments" || die "selftest: a missing comment must be posted"
! calls_have "-X PATCH" || die "selftest: nothing may be patched when none exists"
calls_have "$marker" || die "selftest: the body must start with the marker"
ok "sticky comment posts a new comment when none carries the marker"

# --- The bot's own comment: update it, through a paginated stream of arrays, and never post a second one.
stub_reset
stub gh-api out "[{\"id\":11,\"user\":{\"login\":\"someone\"},\"body\":\"hi\"}][{\"id\":4242,\"user\":{\"login\":\"${bot}\"},\"body\":\"${marker}\\n\\nold\"}]" 0
sticky >/dev/null 2>&1 || die "selftest: sticky comment should update the bot comment"
calls_have "gh api -X PATCH repos/owner/repo/issues/comments/4242" || die "selftest: the bot comment must be updated by id"
! calls_have "-X POST" || die "selftest: an update must not post a second comment"
ok "sticky comment updates the bot comment and posts nothing else"

# --- A comment by someone else that copies the marker is never touched.
stub_reset
stub gh-api out "[{\"id\":99,\"user\":{\"login\":\"mallory\"},\"body\":\"${marker}\\n\\nfake\"}]" 0
sticky >/dev/null 2>&1 || die "selftest: sticky comment should post next to a copied marker"
! calls_have "-X PATCH" || die "selftest: a non-bot comment must never be updated"
calls_have "gh api -X POST repos/owner/repo/issues/7/comments" || die "selftest: a copied marker must lead to a new comment"
ok "sticky comment refuses to update a comment that is not the bot's"

# --- A marker that is not the first thing of the body does not match.
stub_reset
stub gh-api out "[{\"id\":5,\"user\":{\"login\":\"${bot}\"},\"body\":\"text ${marker}\"}]" 0
sticky >/dev/null 2>&1 || die "selftest: sticky comment should post when the marker is not at the start"
! calls_have "-X PATCH" || die "selftest: the marker must start the body to match"
ok "sticky comment matches on the leading marker only"

# --- A 12-digit run or the exact account in the body is refused before any API call.
stub_reset
expect_fail "sticky comment with an account ID" "account ID" sticky "BODY=role ${leak_id} ready"
[ ! -e "$sd/calls" ] || die "selftest: a refused body must not reach the API"
stub_reset
expect_fail "sticky comment with the exact account" "account ID" sticky ACCOUNT=acct-x "BODY=in acct-x now"
[ ! -e "$sd/calls" ] || die "selftest: a refused body must not reach the API"
ok "sticky comment refuses a body that holds an account ID"

# --- Bad inputs fail before any API call.
stub_reset
expect_fail "sticky comment with a bad repo" "REPO must" sticky "REPO=owner;rm"
expect_fail "sticky comment with a bad PR number" "PR_NUMBER must" sticky PR_NUMBER=0
expect_fail "sticky comment with a PR number that is text" "PR_NUMBER must" sticky "PR_NUMBER=7;x"
expect_fail "sticky comment with a bare marker" "MARKER must" sticky "MARKER=app-preview"
expect_fail "sticky comment with a marker holding a quote" "MARKER must" sticky 'MARKER=<!-- a" -->'
expect_fail "sticky comment with a bad bot name" "BOT_LOGIN must" sticky 'BOT_LOGIN=x" or true or "'
expect_fail "sticky comment with an empty body" "BODY is empty" sticky BODY=
expect_fail "sticky comment with an argument" "usage:" stubbed env "$ROOT/scripts/gh/sticky-comment.sh" x
[ ! -e "$sd/calls" ] || die "selftest: a bad input must not reach the API"
ok "sticky comment refuses bad inputs before any API call"

# --- An API failure stops the script: no write after a failed list.
stub_reset
stub gh-api rc 1 0
stub gh-api err "HTTP 403" 0
expect_fail "sticky comment when the list fails" "" sticky
! calls_have "-X POST" || die "selftest: a failed list must not lead to a post"
ok "sticky comment writes nothing when the list call fails"
