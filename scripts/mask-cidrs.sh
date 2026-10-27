#!/usr/bin/env bash
# Hide the optional ALB ingress CIDRs from the log (ADR 0007 S35). The repository secret ALB_INGRESS_CIDRS_DEV is a
# JSON list; GitHub masks the whole string, but Terraform prints single elements, so each one is masked too.
# Prints workflow commands only: one ::add-mask:: per element, or a notice when the list is empty (the default).
# A value that is not a JSON list of strings fails without being printed.
#
# Usage: scripts/mask-cidrs.sh        Env: CIDRS  the JSON list, or empty

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 0 ] || die "usage: scripts/mask-cidrs.sh (reads CIDRS)"
require_cmd jq "install jq"

if [ -z "${CIDRS:-}" ]; then
  echo "::notice::ALB ingress: default 0.0.0.0/0"
  exit 0
fi

jq -e 'type == "array" and length > 0 and all(type == "string")' <<<"$CIDRS" >/dev/null 2>&1 \
  || die "ALB_INGRESS_CIDRS_DEV must be a JSON list of CIDR strings (the value is not shown)"
jq -r '.[] | "::add-mask::" + .' <<<"$CIDRS"
