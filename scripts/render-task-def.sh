#!/usr/bin/env bash
# Turn the family's latest task definition into a RegisterTaskDefinition request that differs only in the
# container image and the tags (ADR 0005, F3, F4). Offline: reads a file, prints JSON on stdout.
#
# Terraform owns the shape, so the shape is validated, not copied blindly: unknown keys, and any drift in the
# user, the root filesystem, the environment, the log group, the /tmp volume, the roles, the secret and the size
# caps, fail with a named rule. The input holds ARNs with the account ID, so nothing from it is printed except
# key names and rule names. The names come from the environment (app_names in lib.sh).
#
# Usage: scripts/render-task-def.sh --env <env> <describe.json> <image@digest> <commit sha>

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

usage="usage: scripts/render-task-def.sh --env <env> <describe.json> <image@digest> <commit sha>"
{ [ $# -eq 5 ] && [ "$1" = "--env" ]; } || die "$usage"
ENV="$2" input="$3" image="$4" sha="$5"
app_names

require_cmd jq "brew install jq"
[ -f "$input" ] || die "task definition file not found: $input"

image_re="^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/${REPOSITORY}@sha256:[0-9a-f]{64}\$"
printf '%s' "$image" | grep -Eq "$image_re" \
  || die "image argument must be <account>.dkr.ecr.<region>.amazonaws.com/${REPOSITORY}@sha256:<64 hex> (a tag or another repository is refused)"
printf '%s' "$sha" | grep -Eq '^[0-9a-f]{40}$' || die "commit sha must be 40 hex characters"

# Read-only keys of DescribeTaskDefinition (ADR 0005, Finding 6); the request keys live in lib.sh.
readonly_keys='["taskDefinitionArn","revision","status","requiresAttributes","compatibilities","registeredAt","registeredBy","deregisteredAt","deleteRequestedAt"]'
# Container keys: the ones Terraform sets, plus the defaults the API adds when it describes the definition.
container_keys='["name","image","essential","user","readonlyRootFilesystem","portMappings","mountPoints","environment","secrets","logConfiguration","cpu","volumesFrom","systemControls"]'

jq -e 'type == "object"' "$input" >/dev/null 2>&1 || die "task definition file is not a JSON object"

# First failing rule wins. Messages carry rule names and key names only, never values from the input.
problem="$(jq -r --argjson req "$REQUEST_KEYS_JSON" --argjson ro "$readonly_keys" --argjson ckeys "$container_keys" \
  --arg exec_role "$EXEC_ROLE" --arg task_role "$TASK_ROLE" --arg secret "$SECRET_ID" --arg log_group "$LOG_GROUP" \
  --argjson cpu_max "$TASK_CPU_MAX" --argjson mem_max "$TASK_MEMORY_MAX" '
  (.taskDefinition // .) as $t
  | ($t.containerDefinitions // []) as $c
  | ($c[0] // {}) as $c0
  | [
      (($t | keys) - $req - $ro | if length > 0 then "unknown top-level key: " + join(", ") + " (new API field; review it before deploying)" else null end),
      (if ($c | length) != 1 then "task definition must have exactly one container" else null end),
      (if $c0.name != "app" then "the container must be named app" else null end),
      (if ($c0 | has("command")) or ($c0 | has("entryPoint")) then "Terraform task definition still has a command or entryPoint; merge and apply the infra change first" else null end),
      (($c0 | keys) - $ckeys | if length > 0 then "unknown container key: " + join(", ") + " (new API field; review it before deploying)" else null end),
      (if $c0.user != "10001:10001" then "the container user must be 10001:10001" else null end),
      (if $c0.readonlyRootFilesystem != true then "readonlyRootFilesystem must be true" else null end),
      (if ($c0.environment // [] | map(.name)) != ["APP_ENV"] then "environment must be exactly APP_ENV" else null end),
      (if ($c0.logConfiguration.logDriver // "") != "awslogs" or ($c0.logConfiguration.options["awslogs-group"] // "") != $log_group
        then "logConfiguration must be awslogs with the group " + $log_group else null end),
      (if ($c0.mountPoints // [] | map({sourceVolume, containerPath, readOnly: (.readOnly // false)}))
            != [{sourceVolume: "tmp", containerPath: "/tmp", readOnly: false}]
          or ($t.volumes // [] | map(.name)) != ["tmp"]
        then "mountPoints and volumes must be exactly the /tmp volume (name tmp, writable)" else null end),
      (if ($t.cpu // null) == null then "task-level cpu is missing" elif ($t.cpu | tonumber) > $cpu_max then "task-level cpu is above " + ($cpu_max | tostring) else null end),
      (if ($t.memory // null) == null then "task-level memory is missing" elif ($t.memory | tonumber) > $mem_max then "task-level memory is above " + ($mem_max | tostring) else null end),
      (if (($t.executionRoleArn // "") | endswith("role/" + $exec_role)) | not then "executionRoleArn must end in role/" + $exec_role else null end),
      (if (($t.taskRoleArn // "") | endswith("role/" + $task_role)) | not then "taskRoleArn must end in role/" + $task_role else null end),
      (if (($c0.secrets // []) | length) != 1
          or $c0.secrets[0].name != "APP_API_KEY"
          or (($c0.secrets[0].valueFrom // "") | test("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:" + $secret + "-[A-Za-z0-9]{6}$") | not)
        then "secrets must be exactly APP_API_KEY from the secret " + $secret else null end)
    ]
  | map(select(. != null)) | .[0] // ""
' "$input")" || die "could not read the task definition file"
[ -z "$problem" ] || die "render refused: $problem"

jq --arg image "$image" --arg sha "$sha" --arg env "$ENV" --argjson req "$REQUEST_KEYS_JSON" '
  (.taskDefinition // .)
  | with_entries(select(.key as $k | $req | index($k)))
  | .containerDefinitions[0].image = $image
  | .tags = [
      {key: "Project", value: "ship-it-safely"},
      {key: "Env", value: $env},
      {key: "ManagedBy", value: "app-deploy"},
      {key: "GitSha", value: $sha}
    ]
' "$input"
