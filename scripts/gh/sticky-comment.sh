#!/usr/bin/env bash
# Post or update one sticky pull request comment (ADR 0009, V15). The comment is found by its marker line, and only a
# comment written by the bot (BOT_LOGIN, default github-actions[bot]) is ever updated, so a comment that merely copies
# the marker is left alone and a new one is posted. The body is checked for an AWS account ID before it is published
# (the repository is public). Every input arrives through the environment, never through arguments, so a workflow
# step can pass untrusted text through `env:` and not through the script text.
#
# Inputs (environment):
#   GH_TOKEN    token with pull-requests: write (read by gh)
#   REPO        owner/name
#   PR_NUMBER   pull request number
#   MARKER      one line HTML comment that starts the body, e.g. <!-- app-preview:pr -->
#   BODY        comment text without the marker (the script puts the marker first)
#   BOT_LOGIN   optional, author of the comment to update (default github-actions[bot])
#   ACCOUNT     optional, an exact account ID to refuse in addition to any 12-digit run
#
# Usage: GH_TOKEN=... REPO=o/r PR_NUMBER=7 MARKER='<!-- m -->' BODY=text scripts/gh/sticky-comment.sh
# Exit codes: 0 posted or updated, 1 refused or failed.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: GH_TOKEN=... REPO=<owner/name> PR_NUMBER=<n> MARKER='<!-- name -->' BODY=<text> scripts/gh/sticky-comment.sh"

repo="${REPO:-}" pr="${PR_NUMBER:-}" marker="${MARKER:-}" text="${BODY:-}" bot="${BOT_LOGIN:-github-actions[bot]}"
# Patterns sit in variables so they do not depend on bash quoting rules (3.2 and 5 differ).
re_repo='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
re_pr='^[1-9][0-9]{0,8}$'
re_marker='^<!-- [A-Za-z0-9:_.-]+ -->$'
re_bot='^[A-Za-z0-9-]+(\[bot\])?$'
# REPO goes into an API path: no segment may be . or .. (path traversal).
[[ "$repo" =~ $re_repo && "${repo%/*}" != "." && "${repo%/*}" != ".." && "${repo#*/}" != "." && "${repo#*/}" != ".." ]] \
  || die "REPO must look like owner/name, with no . or .. segment"
[[ "$pr" =~ $re_pr ]] || die "PR_NUMBER must be a positive number"
[[ "$marker" =~ $re_marker ]] || die "MARKER must be one HTML comment such as <!-- app-preview:pr -->"
[[ "$bot" =~ $re_bot ]] || die "BOT_LOGIN must be a GitHub login"
[ -n "$text" ] || die "BODY is empty; nothing to post"
require_cmd gh "https://cli.github.com (preinstalled on GitHub runners)"
require_cmd jq "https://jqlang.github.io/jq (preinstalled on GitHub runners)"

body="$(printf '%s\n\n%s\n' "$marker" "$text")"
# Nothing is sent when this fails: the guard runs on the final body, marker included.
printf '%s\n' "$body" | "$ROOT/scripts/aws/assert-no-account-id.sh" >/dev/null || die "the comment body holds an account ID; not posting"

# --paginate prints one JSON array per page; jq reads them as a stream. The whole list is read before one id is
# taken, so no pipe is closed early (pipefail).
comments="$(gh api "repos/${repo}/issues/${pr}/comments" --paginate)"
ids="$(jq -r --arg bot "$bot" --arg marker "$marker" '.[] | select(.user.login == $bot and (.body | startswith($marker))) | .id' <<<"$comments")"
existing="${ids%%$'\n'*}"

if [ -n "$existing" ]; then
  [[ "$existing" =~ ^[0-9]+$ ]] || die "unexpected comment id from the API"
  gh api -X PATCH "repos/${repo}/issues/comments/${existing}" -f body="$body" >/dev/null
  ok "updated the sticky comment on #${pr}"
else
  gh api -X POST "repos/${repo}/issues/${pr}/comments" -f body="$body" >/dev/null
  ok "posted a sticky comment on #${pr}"
fi
