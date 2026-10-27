#!/usr/bin/env bash
# Self-tests of the CI helper scripts: the account ID guard, lib.sh helpers, the tool installer, the AWS config check and every script usage contract.
# Run by scripts/ci-selftest.sh; also runnable alone. A bad fixture must fail with its message.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

# --- assert-no-account-id.sh
[ "$(printf 'commit %s\nok\n' "$commit" | "$ROOT/scripts/assert-no-account-id.sh")" = "$(printf 'commit %s\nok' "$commit")" ] \
  || die "selftest: assert-no-account-id must pass clean text through"
[ "$(printf 'run 0123456789012345678901234567890123456789' | "$ROOT/scripts/assert-no-account-id.sh")" = "run 0123456789012345678901234567890123456789" ] \
  || die "selftest: a long digit string inside a hash must pass"
# shellcheck disable=SC2016  # the inner script is meant to expand in the child shell
expect_fail "summary with a 12-digit run" "12-digit" bash -c 'printf "%s" "$1" | "$2"' _ "role ${leak_id}" "$ROOT/scripts/assert-no-account-id.sh"
# shellcheck disable=SC2016
expect_fail "summary with the exact account" "contains the account ID" bash -c 'printf "%s" "$1" | ACCOUNT=acct-x "$2"' _ "role acct-x" "$ROOT/scripts/assert-no-account-id.sh"
ok "assert-no-account-id passes clean text and refuses account IDs"

# --- lib.sh helpers: die annotation, run_capture, names
# shellcheck disable=SC2016
expect_fail "die inside GitHub Actions" "::error::boom" env GITHUB_ACTIONS=true bash -c 'source "$1/scripts/lib.sh"; die boom' _ "$ROOT"
run_capture bash -c "echo out; echo 'bad ${acct}' >&2; exit 3"
{ [ "$RUN_RC" -eq 3 ] && [ "$RUN_OUT" = "out" ] && [ "$RUN_ERR" = "bad <redacted>" ]; } || die "selftest: run_capture recorded rc=$RUN_RC out=$RUN_OUT err=$RUN_ERR"
names="$(ENV=prod "$ROOT/scripts/app-names.sh")"
[ "$names" = "$(printf 'CLUSTER=sis-prod-cluster\nSERVICE=sis-prod-app\nFAMILY=sis-prod-app\nREPOSITORY=sis-prod-app')" ] || die "selftest: app-names printed: $names"
[ "$("$ROOT/scripts/app-names.sh" | head -n1)" = "CLUSTER=sis-dev-cluster" ] || die "selftest: app-names must default to dev"
[ "$("$ROOT/scripts/image-name.sh" "$commit")" = "sis-app:${commit}" ] || die "selftest: image-name printed the wrong name"
ok "lib helpers: die, run_capture and names"

# --- install-ci-tools.sh on scratch copies: nothing here touches the network (CI_TOOLS_BASE_URL is a directory)
mkdir -p "$tmp/mirror" "$tmp/pack"
for t in terraform tflint trivy hadolint; do
  printf '#!/bin/sh\necho "fake %s"\n' "$t" >"$tmp/pack/$t"
  chmod +x "$tmp/pack/$t"
done
python3 -I - "$tmp" <<'PY'
import sys, zipfile
t = sys.argv[1]
for n in ("terraform", "tflint"):
    with zipfile.ZipFile(f"{t}/mirror/{n}_9.9.9_linux_amd64.zip", "w") as z:
        z.write(f"{t}/pack/{n}", n)
PY
tar -czf "$tmp/mirror/trivy_9.9.9_Linux-64bit.tar.gz" -C "$tmp/pack" trivy
cp "$tmp/pack/hadolint" "$tmp/mirror/hadolint_9.9.9_linux_x86_64"
printf 'terraform = "9.9.9"\ntflint = "9.9.9"\ntrivy = "9.9.9"\nhadolint = "9.9.9"\n' >"$tmp/mise.toml"
: >"$tmp/sums"
for f in terraform_9.9.9_linux_amd64.zip tflint_9.9.9_linux_amd64.zip trivy_9.9.9_Linux-64bit.tar.gz hadolint_9.9.9_linux_x86_64; do
  printf '%s  %s\n' "$(sha256_of "$tmp/mirror/$f")" "$f" >>"$tmp/sums"
done
install_tools() {
  CI_TOOLS_MISE_TOML="$tmp/mise.toml" CI_TOOLS_SHA256="$tmp/sums" CI_TOOLS_BASE_URL="file://$tmp/mirror" \
    "$ROOT/scripts/install-ci-tools.sh" "$@"
}
install_tools "$tmp/bin-default" >"$tmp/install.log" 2>&1 || die "selftest: default install failed: $(cat "$tmp/install.log")"
{ [ -x "$tmp/bin-default/terraform" ] && [ -x "$tmp/bin-default/tflint" ] && [ ! -e "$tmp/bin-default/trivy" ] && [ ! -e "$tmp/bin-default/hadolint" ]; } \
  || die "selftest: no tool arguments must install only terraform and tflint"
install_tools "$tmp/bin-scan" trivy hadolint >"$tmp/install.log" 2>&1 || die "selftest: trivy and hadolint install failed: $(cat "$tmp/install.log")"
{ [ -x "$tmp/bin-scan/trivy" ] && [ -x "$tmp/bin-scan/hadolint" ] && [ ! -e "$tmp/bin-scan/terraform" ]; } || die "selftest: only the named tools may be installed"
ok "installer installs the named tools only"
expect_fail "installer with an unknown tool" "unknown tool 'kubectl'" install_tools "$tmp/bin-x" kubectl
sed -E 's/^[0-9a-f]{64}  trivy/0000000000000000000000000000000000000000000000000000000000000000  trivy/' "$tmp/sums" >"$tmp/sums-bad"
expect_fail "installer with a corrupted trivy hash" "checksum mismatch" env CI_TOOLS_MISE_TOML="$tmp/mise.toml" \
  CI_TOOLS_SHA256="$tmp/sums-bad" CI_TOOLS_BASE_URL="file://$tmp/mirror" "$ROOT/scripts/install-ci-tools.sh" "$tmp/bin-x" trivy
sed -E 's/^(trivy = ).*/\1"9.9.10"/' "$tmp/mise.toml" >"$tmp/mise-bump.toml"
expect_fail "installer with a bumped trivy version" "no checksum for trivy_9.9.10_Linux-64bit.tar.gz" env \
  CI_TOOLS_MISE_TOML="$tmp/mise-bump.toml" CI_TOOLS_SHA256="$tmp/sums" CI_TOOLS_BASE_URL="file://$tmp/mirror" \
  "$ROOT/scripts/install-ci-tools.sh" "$tmp/bin-x" trivy
# The checked-in pins exist for every tool at the version mise.toml names.
for t in terraform tflint trivy hadolint; do
  v="$(sed -nE "s/^${t}[[:space:]]*=[[:space:]]*\"([0-9][^\"]*)\".*/\1/p" "$ROOT/mise.toml" | head -n1)"
  grep -Eq "^[0-9a-f]{64}  ${t}_${v//./\\.}_" "$ROOT/scripts/ci-tools.sha256" || die "selftest: no checked-in checksum for $t $v"
done
ok "checked-in checksums cover every pinned tool"

# --- check-aws-config.sh
role=sis-dev-gha-deploy
good_arn="arn:aws:iam::${acct}:role/${role}"
check_cfg() { env ROLE_ARN="$1" ACCOUNT="$2" REGION="$3" "$ROOT/scripts/check-aws-config.sh" "$role"; }
out="$(check_cfg "$good_arn" "$acct" ap-southeast-1 2>/dev/null)" || die "selftest: good AWS config rejected"
case "$out" in *"::add-mask::${acct}"*) ok "config check masks the account" ;; *) die "selftest: the account was not masked" ;; esac
expect_fail "config with the plan role" "is not the ${role} role ARN" check_cfg "arn:aws:iam::${acct}:role/sis-dev-gha-plan" "$acct" ap-southeast-1
expect_fail "config with another account" "differs from the account" check_cfg "$good_arn" "$leak_id" ap-southeast-1
expect_fail "config with no region" "AWS_REGION is empty" check_cfg "$good_arn" "$acct" ""
expect_fail "config with no secrets" "is empty or not set" check_cfg "" "" ap-southeast-1

# --- redact-account-ids.sh
redacted="$(printf 'role %s failed' "$acct" | "$ROOT/scripts/redact-account-ids.sh")"
[ "$redacted" = "role <redacted> failed" ] || die "selftest: redact filter output was: $redacted"
ok "redact filter replaces 12-digit runs"

# --- Usage contracts. The Docker-based scripts (build, smoke, scan) run in full in app-ci and in `make image smoke
# scan`, which need Docker and the trivy database; their argument contracts are checked here, with the rest.
# A script that takes arguments prints its usage when called with none.
for s in build-image app-smoke render-task-def image-verify image-export image-import image-name ecr-push check-aws-config \
  assert-web-identity-denied assert-session-cap ci-venv; do
  expect_fail "$s without arguments" "usage:" "$ROOT/scripts/$s.sh"
done
# A script that takes none refuses a stray argument.
for s in app-names ecs-preflight ecs-deregister-revisions assert-no-account-id assumed-role-name plan-role-guardrails \
  tf-init tf-destroy-check tf-plan-summary mask-cidrs tf-destroy-report; do
  expect_fail "$s with a stray argument" "usage:" "$ROOT/scripts/$s.sh" x
done
expect_fail "scan-image with one argument" "usage:" "$ROOT/scripts/scan-image.sh" image-only
expect_fail "ecs-wait with two arguments" "usage:" "$ROOT/scripts/ecs-wait-deployment.sh" cluster service

# --- OIDC helpers and the negative tests (ADR 0007 S30 to S32), with stub curl and aws.
# b64url <text> [pad]: base64url without padding, or with it when a second argument is given.
b64url() {
  local out
  out="$(printf '%s' "$1" | base64 | tr -d '\n' | tr '+/' '-_')"
  if [ -z "${2:-}" ]; then out="${out%%=*}"; fi
  printf '%s' "$out"
}
claims='{"sub":"repo:o@1/r@2:pull_request","job_workflow_ref":"o/r/.github/workflows/oidc-smoke-test.yml@refs/pull/7/merge"}'
jwt="$(b64url '{"alg":"none"}').$(b64url "$claims").sig"
claim() { bash -c 'source "$1/scripts/lib.sh"; jwt_claim "$2" "$3"' _ "$ROOT" "$1" "$2"; }
[ "$(claim "$jwt" sub)" = "repo:o@1/r@2:pull_request" ] || die "selftest: jwt_claim could not read an unpadded payload"
# Payloads of every length modulo 4, padded and unpadded.
for v in x xy xyz xyzw; do
  for pad in "" pad; do
    padded_jwt="h.$(b64url "{\"a\":\"$v\"}" "$pad").s"
    [ "$(claim "$padded_jwt" a)" = "$v" ] || die "selftest: jwt_claim failed for value '$v' (padding: '${pad:-none}')"
  done
done
[ -z "$(claim "$jwt" no_such_claim)" ] || die "selftest: an absent claim must read as empty"
ok "jwt_claim decodes padded and unpadded payloads"

cat >"$tmp/stub/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"${STUB_DIR:?}/calls"
[ ! -f "$STUB_DIR/curl.out" ] || cat "$STUB_DIR/curl.out"
[ ! -f "$STUB_DIR/curl.rc" ] || exit "$(cat "$STUB_DIR/curl.rc")"
exit 0
EOF
chmod +x "$tmp/stub/curl"
sts=aws-sts-assume-role-with-web-identity
denied_err="An error occurred (AccessDenied) when calling the AssumeRoleWithWebIdentity operation: Not authorized to perform sts:AssumeRoleWithWebIdentity for ${acct}"
oidc_env() {
  stubbed env ACCOUNT="$acct" REGION=ap-southeast-1 GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 \
    ACTIONS_ID_TOKEN_REQUEST_URL="https://token.example/req?x=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN=request-token "$@"
}
denied_ready() {
  stub_reset
  stub curl out "{\"value\":\"$jwt\"}"
  stub "$sts" rc 254
  stub "$sts" err "$denied_err"
}
# quiet_run <command...>: stdout and stderr together, the failure code kept out of the way.
quiet_run() { ( trap - ERR; "$@" 2>&1 ) || true; }

denied_ready
out="$(oidc_env "$ROOT/scripts/assert-web-identity-denied.sh" plan apply deploy 2>&1)" || die "selftest: refusals of all three roles should pass: $out"
[ "$(cat "$sd/$sts.n")" = 3 ] || die "selftest: one STS call per role expected"
for r in plan apply deploy; do calls_have "role/sis-dev-gha-$r" || die "selftest: the $r role was not tested"; done
calls_have "--no-sign-request" || die "selftest: the STS calls must be unsigned"
case "$out" in
  *"Token sub: repo:o@1/r@2:pull_request"*"Token job_workflow_ref: o/r/.github/workflows/oidc-smoke-test.yml@refs/pull/7/merge"*) ;;
  *) die "selftest: the token claims were not printed: $out" ;;
esac
case "$out" in *"$acct"* | *"$jwt"*) die "selftest: the output holds the account or the token" ;; esac
ok "web identity denial passes when every role refuses, and prints no secret"

denied_ready
stub "$sts" rc 0 1
stub "$sts" err "" 1
stub "$sts" out '{"Credentials":{"SecretAccessKey":"never-printed"}}' 1
out="$(quiet_run oidc_env "$ROOT/scripts/assert-web-identity-denied.sh" plan apply deploy)"
case "$out" in *"the apply role was assumed with a token it must refuse: trust too broad"*) ;; *) die "selftest: a success must fail with trust too broad: $out" ;; esac
case "$out" in *never-printed*) die "selftest: credentials reached the output" ;; esac
[ "$(cat "$sd/$sts.n")" = 2 ] || die "selftest: the run must stop at the first role that accepts the token"
denied_ready
stub "$sts" err "Could not connect to the endpoint URL ${acct}"
expect_fail "web identity denial on a network error" "not as a role refusal" oidc_env "$ROOT/scripts/assert-web-identity-denied.sh" plan
out="$(quiet_run oidc_env "$ROOT/scripts/assert-web-identity-denied.sh" plan)"
case "$out" in *"$acct"*) die "selftest: an error message leaked the account" ;; esac
denied_ready
stub curl rc 22
expect_fail "web identity denial when the token request fails" "OIDC token request failed" oidc_env "$ROOT/scripts/assert-web-identity-denied.sh" plan
denied_ready
stub curl out '{"value":""}'
expect_fail "web identity denial with an empty token" "no value" oidc_env "$ROOT/scripts/assert-web-identity-denied.sh" plan
denied_ready
expect_fail "web identity denial with an unknown role" "role must be plan, apply or deploy" oidc_env "$ROOT/scripts/assert-web-identity-denied.sh" admin
ok "web identity denial fails on success, other errors and token problems"

cap_ready() {
  stub_reset
  stub curl out "{\"value\":\"$jwt\"}"
  stub "$sts" rc 254 0
  stub "$sts" err "An error occurred (ValidationError) when calling the AssumeRoleWithWebIdentity operation: The requested DurationSeconds exceeds the MaxSessionDuration set for this role." 0
  stub "$sts" out "2026-10-27T10:15:00+00:00" 1
}
cap_ready
out="$(oidc_env "$ROOT/scripts/assert-session-cap.sh" plan 2>&1)" || die "selftest: a refused 3601 and a granted 900 should pass: $out"
case "$out" in *"session expires in about 15 minutes (2026-10-27T10:15:00+00:00)"*) ;; *) die "selftest: the expiry line is missing: $out" ;; esac
calls_have "--duration-seconds 3601" || die "selftest: the over-cap duration must be requested"
calls_have "--duration-seconds 900" || die "selftest: the short duration must be requested"
case "$out" in *"$acct"* | *"$jwt"* | *Credentials* | *SecretAccessKey*) die "selftest: the session cap output holds a secret" ;; esac
cap_ready
stub "$sts" rc 0 0
expect_fail "session cap when 3601 seconds is granted" "max_session_duration is above 3600" oidc_env "$ROOT/scripts/assert-session-cap.sh" plan
cap_ready
stub "$sts" err "An error occurred (AccessDenied) for ${acct}" 0
expect_fail "session cap when 3601 fails for another reason" "not for the duration" oidc_env "$ROOT/scripts/assert-session-cap.sh" plan
cap_ready
stub "$sts" rc 254 1
stub "$sts" err "An error occurred (AccessDenied)" 1
expect_fail "session cap when 900 seconds is refused" "a 900 second session was refused" oidc_env "$ROOT/scripts/assert-session-cap.sh" plan
ok "session cap: 3601 refused for the duration, 900 reports its expiry"

# --- mask-cidrs.sh
[ "$(CIDRS="" "$ROOT/scripts/mask-cidrs.sh" 2>/dev/null)" = "::notice::ALB ingress: default 0.0.0.0/0" ] || die "selftest: an empty list must print only the notice"
masks="$(CIDRS='["198.51.100.7/32","203.0.113.0/24"]' "$ROOT/scripts/mask-cidrs.sh" 2>/dev/null)"
[ "$masks" = "$(printf '::add-mask::198.51.100.7/32\n::add-mask::203.0.113.0/24')" ] || die "selftest: expected one add-mask per element, got: $masks"
expect_fail "mask-cidrs with non-JSON" "must be a JSON list" env CIDRS="not json" "$ROOT/scripts/mask-cidrs.sh"
expect_fail "mask-cidrs with a JSON object" "must be a JSON list" env CIDRS='{"a":"198.51.100.7/32"}' "$ROOT/scripts/mask-cidrs.sh"
out="$(quiet_run env CIDRS="bad 198.51.100.7" "$ROOT/scripts/mask-cidrs.sh")"
case "$out" in *198.51.100.7*) die "selftest: mask-cidrs echoed a bad value" ;; esac
ok "mask-cidrs masks each element and refuses anything but a JSON list"

# --- Script modes (ADR 0007 S19): libraries are only sourced, so they are not executable; everything else is.
modes="$(git -C "$ROOT" ls-files -s 'scripts/*.sh' 2>/dev/null || true)"
if [ -z "$modes" ]; then
  warn "no git index here, skipping the script mode check"
else
  while read -r mode _ _ path; do
    case "$path" in
      scripts/lib.sh | scripts/selftest/common.sh) want=100644 ;;
      *) want=100755 ;;
    esac
    [ "$mode" = "$want" ] || die "selftest: $path is mode $mode, expected $want (libraries 100644, scripts 100755)"
  done <<<"$modes"
  ok "libraries are not executable and every script is"
fi
