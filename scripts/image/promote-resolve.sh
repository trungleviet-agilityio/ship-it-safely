#!/usr/bin/env bash
# Refuse to promote a commit that was not green in dev (ADR 0008, P10). No AWS and no registry: only git and the GitHub
# API. The commit must be 40 lowercase hex characters, an ancestor of origin/main, and have a successful app-deploy run
# on branch main. Run it from a checkout whose history holds origin/main (fetch-depth: 0); the credential-free
# `resolve` job of the promote workflow does that, with `actions: read` for gh.
#
# Prints nothing on stdout. Exit codes: 0 promotable, 1 refused.
#
# Usage: scripts/image/promote-resolve.sh <commit sha>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 1 ] || die "usage: scripts/image/promote-resolve.sh <commit sha>"
sha="$1"
require_cmd git "install git"
require_cmd gh "the GitHub CLI is preinstalled on GitHub runners"
require_cmd jq "install jq"

# [[ =~ ]] matches the whole value, so a newline cannot smuggle a second line past it.
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "the commit must be 40 lowercase hex characters"

git cat-file -e "${sha}^{commit}" 2>/dev/null || die "commit ${sha} is not in this checkout (fetch the full history of main)"
# merge-base --is-ancestor exits 1 for "not an ancestor" and 128 for an error such as a missing origin/main.
rc=0
git merge-base --is-ancestor "$sha" origin/main 2>/dev/null || rc=$?
case "$rc" in
  0) ;;
  1) die "commit ${sha} is not an ancestor of origin/main" ;;
  *) die "could not compare ${sha} with origin/main (is origin/main fetched?)" ;;
esac
ok "${sha} is on main"

# The run list is filtered on the API side; the headSha and conclusion are checked again, so a stale or loose answer
# never passes.
run_capture gh run list --workflow app-deploy.yml --commit "$sha" --branch main --status success \
  --json databaseId,headSha,conclusion --limit 20
[ "$RUN_RC" -eq 0 ] || die "gh run list failed (exit code ${RUN_RC}): ${RUN_ERR}"
jq -e --arg sha "$sha" 'type == "array" and any(.[]; .headSha == $sha and .conclusion == "success")' <<<"$RUN_OUT" >/dev/null 2>&1 \
  || die "no successful app-deploy run on main for ${sha}; it was never green in dev"
ok "${sha} has a successful app-deploy run on main"
