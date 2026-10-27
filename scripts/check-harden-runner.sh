#!/usr/bin/env bash
# harden-runner policy for every workflow job (ADR 0007 S45, NFR-4): a job with `id-token: write` runs block mode with
# telemetry off and an exact `host:port` allowlist (no broad wildcard, no account ID literal); every other job says
# `egress-policy: audit` out loud. The rules and the YAML reading are in scripts/harden_runner_policy.py (PyYAML from the
# hash-locked venv). With no arguments every .github/workflows/*.yml and *.yaml is scanned.
#
# Usage: scripts/check-harden-runner.sh [workflow file ...]
# Env:   CI_PYTHON  interpreter with PyYAML (default: .venv-ci/bin/python from `make venv`, else python3)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

run_workflow_helper harden_runner_policy.py "harden-runner policy" "$@"
ok "harden-runner policy holds: block with exact hosts where credentials live, audit elsewhere"
