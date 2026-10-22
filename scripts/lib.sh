# shellcheck shell=bash
# Shared helpers for scripts/*.sh. Source it; do not run it.
# Written for the bash 3.2 that ships with macOS: no mapfile, no associative arrays, and an empty
# array must not be expanded under `set -u`.

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

# Colors only on a terminal, so CI logs stay plain (https://no-color.org).
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _blue=$'\033[34m' _green=$'\033[32m' _yellow=$'\033[33m' _red=$'\033[31m' _reset=$'\033[0m'
else
  _blue='' _green='' _yellow='' _red='' _reset=''
fi

# All output goes to stderr, so a script's stdout stays free for data.
log()  { printf '%s==>%s %s\n' "$_blue" "$_reset" "$*" >&2; }
ok()   { printf '%sok%s  %s\n' "$_green" "$_reset" "$*" >&2; }
warn() { printf '%swarn%s %s\n' "$_yellow" "$_reset" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$_red" "$_reset" "$*" >&2; exit 1; }

trap 'die "${BASH_SOURCE[0]##*/}: command failed at line $LINENO"' ERR

# require_cmd <command> <install hint>
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 not found. Install: $2"
}
