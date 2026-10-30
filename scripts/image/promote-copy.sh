#!/usr/bin/env bash
# Copy one image between ECR repositories by digest and prove the digest survived (ADR 0008, P9 steps 4 and 5, S2).
# Needs the AWS CLI (for the registry login) and crane, with credentials that may pull the source and push the target.
#
#   1. If the target tag <sha> exists, its digest is used and nothing is copied. This is the rollback path: promoting
#      an earlier green commit again deploys the digest prod already holds. When the source still has that tag too,
#      its digest must be equal, or the run fails (a tag that points at two images is never deployed). A source that
#      aged out of its repository is fine.
#   2. Otherwise the source digest is read, `crane copy` copies source@digest to target:<sha>, and the target digest
#      is read again and must equal the source digest.
#
# crane logs in through a temporary DOCKER_CONFIG directory created under <temp dir> (default $RUNNER_TEMP) and removed
# on exit, success or failure. Registry hosts hold the account ID, so nothing prints them: logs carry the digest and the
# commit only, and failure text goes through the account ID redaction.
#
# Prints on stdout: IMAGE_DIGEST=<sha256:...> and PROMOTE_COPIED=<true|false>.
#
# Usage: scripts/image/promote-copy.sh <source repo> <target repo> <commit sha> [temp dir]
#   a repo is <account>.dkr.ecr.<region>.amazonaws.com/<repository name>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

usage="usage: scripts/image/promote-copy.sh <source repo> <target repo> <commit sha> [temp dir]"
{ [ $# -eq 3 ] || [ $# -eq 4 ]; } || die "$usage"
source_repo="$1" target_repo="$2" sha="$3" temp_base="${4:-${RUNNER_TEMP:-}}"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd crane "scripts/ci/install-tools.sh <dir> crane"

[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "the commit must be 40 lowercase hex characters"
repo_re='^[0-9]{12}\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com/[a-z0-9][a-z0-9._/-]*$'
[[ "$source_repo" =~ $repo_re ]] || die "the source repo must be <account>.dkr.ecr.<region>.amazonaws.com/<repository>"
[[ "$target_repo" =~ $repo_re ]] || die "the target repo must be <account>.dkr.ecr.<region>.amazonaws.com/<repository>"
[ "$source_repo" != "$target_repo" ] || die "the source and the target repository must differ"
[ -n "$temp_base" ] && [ -d "$temp_base" ] || die "a temp dir is needed: pass one or set RUNNER_TEMP"

DOCKER_CONFIG="$(mktemp -d "${temp_base%/}/crane-config.XXXXXX")" || die "cannot create a temp directory under the temp dir"
export DOCKER_CONFIG
trap 'rm -rf "$DOCKER_CONFIG"' EXIT

# registry_login <repo>: log crane in to the host of the repo. The password travels through a pipe, never an argument.
registry_login() {
  local host="${1%%/*}" region
  [[ "$1" =~ $repo_re ]] && region="${BASH_REMATCH[1]}"
  aws ecr get-login-password --region "$region" | crane auth login "$host" --username AWS --password-stdin
}

# login_once <repo>: log in to a host the first time it is needed (the host is in the repo string, never printed).
logged_in=" "
login_once() {
  local host="${1%%/*}"
  case "$logged_in" in *" ${host} "*) return 0 ;; esac
  run_capture registry_login "$1"
  [ "$RUN_RC" -eq 0 ] || die "registry login failed (exit code ${RUN_RC}): ${RUN_ERR}"
  logged_in="${logged_in}${host} "
}

# read_digest <repo>: set DIGEST to the digest of <repo>:<sha>, or to "" when the tag (or the repository) is gone. Any
# other failure, such as a denied pull, dies: a missing image and a broken call must never look alike.
read_digest() {
  login_once "$1"
  run_capture crane digest "${1}:${sha}"
  DIGEST=""
  if [ "$RUN_RC" -eq 0 ]; then
    DIGEST="$RUN_OUT"
    [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || die "crane returned a digest in an unexpected format"
  else
    case "$RUN_ERR" in
      *MANIFEST_UNKNOWN* | *NAME_UNKNOWN*) ;;
      *) die "crane digest failed (exit code ${RUN_RC}): ${RUN_ERR}" ;;
    esac
  fi
}

read_digest "$target_repo"
target_digest="$DIGEST"
if [ -n "$target_digest" ]; then
  read_digest "$source_repo"
  if [ -n "$DIGEST" ] && [ "$DIGEST" != "$target_digest" ]; then
    die "the target tag ${sha} holds ${target_digest} but the source holds ${DIGEST}: one tag, two images; stopped"
  fi
  log "the target tag ${sha} exists (digest ${target_digest}); nothing is copied"
  printf 'IMAGE_DIGEST=%s\nPROMOTE_COPIED=false\n' "$target_digest"
  exit 0
fi

read_digest "$source_repo"
source_digest="$DIGEST"
[ -n "$source_digest" ] || die "the source has no image tagged ${sha} (it may have aged out of the repository)"
log "copying ${sha} by digest ${source_digest}"
run_capture crane copy "${source_repo}@${source_digest}" "${target_repo}:${sha}"
[ "$RUN_RC" -eq 0 ] || die "crane copy failed (exit code ${RUN_RC}): ${RUN_ERR}"

read_digest "$target_repo"
[ "$DIGEST" = "$source_digest" ] || die "digest mismatch after the copy: the source is ${source_digest}, the target is ${DIGEST:-missing}"
ok "target digest equals source digest: ${source_digest}"
printf 'IMAGE_DIGEST=%s\nPROMOTE_COPIED=true\n' "$source_digest"
