#!/usr/bin/env bash
# Install Terraform and tflint for CI with checksum verification (NFR-3, ADR 0004, E29).
# Versions come from mise.toml (one source of truth). Each download is saved under a versioned file name and
# checked against scripts/ci-tools.sha256, so a version bump without a checksum update fails with
# "no checksum for <file>". hashicorp/setup-terraform is not used: it does not verify the download.
# Providers are verified later by `terraform init -lockfile=readonly`; tflint verifies its own plugin download.
#
# Usage: scripts/install-ci-tools.sh <dest dir>
# Test overrides (scratch copies only): CI_TOOLS_MISE_TOML, CI_TOOLS_SHA256.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 1 ] || die "usage: scripts/install-ci-tools.sh <dest dir>"
dest="$1"

require_cmd curl "apt-get install curl"
require_cmd unzip "apt-get install unzip"

mise_toml="${CI_TOOLS_MISE_TOML:-$ROOT/mise.toml}"
sums="${CI_TOOLS_SHA256:-$ROOT/scripts/ci-tools.sha256}"
[ -f "$mise_toml" ] || die "mise.toml not found: $mise_toml"
[ -f "$sums" ] || die "checksum file not found: $sums"

# checksum_line <file>: the checked-in line for that exact file name, or fail before anything is downloaded.
checksum_line() {
  local line
  line="$(grep -E "^[0-9a-f]{64}  ${1//./\\.}\$" "$sums" || true)"
  [ -n "$line" ] || die "no checksum for $1 in ${sums##*/}; add the official SHA-256 after reviewing the release"
  printf '%s' "$line"
}

# sha256_check <dir> <file>: verify <file> in <dir> against the checked-in line.
sha256_check() {
  local dir="$1" file="$2" line
  line="$(checksum_line "$file")"
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$dir" && printf '%s\n' "$line" | sha256sum -c - >/dev/null) || die "checksum mismatch for $file"
  else
    (cd "$dir" && printf '%s\n' "$line" | shasum -a 256 -c - >/dev/null) || die "checksum mismatch for $file"
  fi
  ok "$file matches ${sums##*/}"
}

# tool_version <name>: the pinned version from mise.toml.
tool_version() {
  local v
  v="$(sed -nE "s/^$1[[:space:]]*=[[:space:]]*\"([0-9][^\"]*)\".*/\1/p" "$mise_toml" | head -n1)"
  [ -n "$v" ] || die "$1 is not pinned in ${mise_toml##*/}"
  printf '%s' "$v"
}

tf_version="$(tool_version terraform)"
tflint_version="$(tool_version tflint)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$dest"

tf_zip="terraform_${tf_version}_linux_amd64.zip"
tflint_zip="tflint_${tflint_version}_linux_amd64.zip"

checksum_line "$tf_zip" >/dev/null
checksum_line "$tflint_zip" >/dev/null

log "download terraform $tf_version"
curl -fsSL --retry 3 -o "$work/$tf_zip" \
  "https://releases.hashicorp.com/terraform/${tf_version}/terraform_${tf_version}_linux_amd64.zip"
sha256_check "$work" "$tf_zip"

log "download tflint $tflint_version"
curl -fsSL --retry 3 -o "$work/$tflint_zip" \
  "https://github.com/terraform-linters/tflint/releases/download/v${tflint_version}/tflint_linux_amd64.zip"
sha256_check "$work" "$tflint_zip"

unzip -q -o "$work/$tf_zip" terraform -d "$dest"
unzip -q -o "$work/$tflint_zip" tflint -d "$dest"
chmod +x "$dest/terraform" "$dest/tflint"

if [ -n "${GITHUB_PATH:-}" ]; then
  printf '%s\n' "$(cd "$dest" && pwd)" >>"$GITHUB_PATH"
fi

# The binaries are linux_amd64; on another OS they were only verified and unpacked.
if [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ]; then
  "$dest/terraform" version >&2
  "$dest/tflint" --version >&2
else
  warn "not linux x86_64: tools verified and unpacked, version check skipped"
fi
ok "installed terraform $tf_version and tflint $tflint_version into $dest"
