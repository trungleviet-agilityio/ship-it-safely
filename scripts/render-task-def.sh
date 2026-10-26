#!/usr/bin/env bash
# Turn the family's latest task definition into a RegisterTaskDefinition request that differs only in the
# container image and the tags (ADR 0005, F3, F4). Offline: reads a file, prints JSON on stdout.
#
# The input holds ARNs with the account ID, so nothing from it is printed except key names and rule names.
# Every rule fails with a named message; a new API field fails loudly instead of being copied or dropped.
#
# Usage: scripts/render-task-def.sh <describe.json> <image@digest> <commit sha>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

[ $# -eq 3 ] || die "usage: scripts/render-task-def.sh <describe.json> <image@digest> <commit sha>"
input="$1" image="$2" sha="$3"

require_cmd jq "brew install jq"
[ -f "$input" ] || die "task definition file not found: $input"

image_re='^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/sis-dev-app@sha256:[0-9a-f]{64}$'
printf '%s' "$image" | grep -Eq "$image_re" \
  || die "image argument must be <account>.dkr.ecr.<region>.amazonaws.com/sis-dev-app@sha256:<64 hex> (a tag or another repository is refused)"
printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || die "commit sha must be 40 hex characters"

# Request keys of RegisterTaskDefinition, and the read-only keys of DescribeTaskDefinition (ADR 0005, Finding 6).
request_keys='["containerDefinitions","cpu","enableFaultInjection","ephemeralStorage","executionRoleArn","family","inferenceAccelerators","ipcMode","memory","networkMode","pidMode","placementConstraints","proxyConfiguration","requiresCompatibilities","runtimePlatform","tags","taskRoleArn","volumes"]'
readonly_keys='["taskDefinitionArn","revision","status","requiresAttributes","compatibilities","registeredAt","registeredBy","deregisteredAt","deleteRequestedAt"]'

jq -e 'type == "object"' "$input" >/dev/null 2>&1 || die "task definition file is not a JSON object"

# First failing rule wins. Messages carry rule names and key names only, never values from the input.
problem="$(jq -r --argjson req "$request_keys" --argjson ro "$readonly_keys" '
  (.taskDefinition // .) as $t
  | ($t.containerDefinitions // []) as $c
  | [
      (($t | keys) - $req - $ro | if length > 0 then "unknown top-level key: " + join(", ") + " (new API field; review it before deploying)" else null end),
      (if ($c | length) != 1 then "task definition must have exactly one container" else null end),
      (if $c[0].name != "app" then "the container must be named app" else null end),
      (if ($c[0] | has("command")) or ($c[0] | has("entryPoint")) then "Terraform task definition still has a command or entryPoint; merge and apply the infra change first" else null end),
      (if ($t.cpu // null) == null then "task-level cpu is missing" elif ($t.cpu | tonumber) > 512 then "task-level cpu is above 512" else null end),
      (if ($t.memory // null) == null then "task-level memory is missing" elif ($t.memory | tonumber) > 1024 then "task-level memory is above 1024" else null end),
      (if (($t.executionRoleArn // "") | test("role/sis-dev-ecs-exec$")) | not then "executionRoleArn must end in role/sis-dev-ecs-exec" else null end),
      (if (($t.taskRoleArn // "") | test("role/sis-dev-ecs-task$")) | not then "taskRoleArn must end in role/sis-dev-ecs-task" else null end),
      (if (($c[0].secrets // []) | length) != 1
          or $c[0].secrets[0].name != "APP_API_KEY"
          or (($c[0].secrets[0].valueFrom // "") | test("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:sis/dev/app-api-key-[A-Za-z0-9]{6}$") | not)
        then "secrets must be exactly APP_API_KEY from the secret sis/dev/app-api-key" else null end)
    ]
  | map(select(. != null)) | .[0] // ""
' "$input")" || die "could not read the task definition file"
[ -z "$problem" ] || die "render refused: $problem"

jq --arg image "$image" --arg sha "$sha" --argjson req "$request_keys" '
  (.taskDefinition // .)
  | with_entries(select(.key as $k | $req | index($k)))
  | .containerDefinitions[0].image = $image
  | .tags = [
      {key: "Project", value: "ship-it-safely"},
      {key: "Env", value: "dev"},
      {key: "ManagedBy", value: "app-deploy"},
      {key: "GitSha", value: $sha}
    ]
' "$input"
