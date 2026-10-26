#!/usr/bin/env bash
# Account-free summary of a Terraform plan for the job summary and the PR comment (ADR 0004, E22, E23).
# Reads `terraform show -json <plan>` on stdin and prints markdown: counts and one row per changed resource
# (action and address only, never attribute values). The repo is public, so any bare 12-digit run, which could be
# an AWS account ID, fails the script instead of being printed.
#
# Usage: terraform show -json tfplan | scripts/tf-plan-summary.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

require_cmd jq "apt-get install jq"

max_rows=200

summary="$(
  # shellcheck disable=SC2016  # jq program, not shell
  jq -r --argjson max "$max_rows" '
    def act:
      if (.change.actions | index("delete")) and (.change.actions | index("create")) then "REPLACE"
      elif .change.actions == ["delete"] then "DELETE"
      elif .change.actions == ["create"] then "create"
      elif .change.actions == ["update"] then "update"
      else (.change.actions | join("+")) end;
    [(.resource_changes // [])[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $c
    | ($c | map(act)) as $l
    | "### Terraform plan (dev)",
      "",
      "**Add \($l | map(select(. == "create")) | length), change \($l | map(select(. == "update")) | length), destroy \($l | map(select(. == "DELETE")) | length), replace \($l | map(select(. == "REPLACE")) | length).**",
      "",
      (if ($c | length) == 0 then "No resource changes."
       else
         "| Action | Address |",
         "|---|---|",
         ($c[:$max][] | "| \(act) | `\(.address)` |"),
         (if ($c | length) > $max then "", "Showing the first \($max) of \($c | length) changes." else empty end)
       end)
  '
)"

# Bare 12-digit runs (alphanumeric boundaries, like the pre-commit hook) may be an account ID: refuse to emit them.
if printf '%s\n' "$summary" | grep -Eq '(^|[^0-9A-Za-z])[0-9]{12}([^0-9A-Za-z]|$)'; then
  die "plan summary contains a 12-digit number (possible account ID); not printing it"
fi

printf '%s\n' "$summary"
