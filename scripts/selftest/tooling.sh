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
for s in build-image app-smoke render-task-def image-verify image-export image-import image-name ecr-push check-aws-config; do
  expect_fail "$s without arguments" "usage:" "$ROOT/scripts/$s.sh"
done
# A script that takes none refuses a stray argument.
for s in app-names ecs-preflight ecs-deregister-revisions assert-no-account-id assumed-role-name plan-role-guardrails \
  tf-init tf-destroy-check tf-plan-summary; do
  expect_fail "$s with a stray argument" "usage:" "$ROOT/scripts/$s.sh" x
done
expect_fail "scan-image with one argument" "usage:" "$ROOT/scripts/scan-image.sh" image-only
expect_fail "ecs-wait with two arguments" "usage:" "$ROOT/scripts/ecs-wait-deployment.sh" cluster service
