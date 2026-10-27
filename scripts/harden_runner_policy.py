"""harden-runner policy for GitHub workflow files (ADR 0007 S45, NFR-4).

Jobs that hold AWS credentials (`id-token: write`) must run harden-runner in block mode with
telemetry off and an exact allowlist, so an exfiltration path needs an allowed host and the
account-bearing hostnames never reach a third-party insights page. Every other job must say
`egress-policy: audit` out loud, so a new job cannot ship with the action's silent default (block)
or with no hardening.

Rules, per job:
  1. the first step is step-security/harden-runner;
  2. a job with `id-token: write` has `egress-policy: block` and `disable-telemetry: true`;
  3. any other job has `egress-policy: audit`;
  4. every allowed endpoint is `host:port`;
  5. no broad wildcard: `*`, `*.amazonaws.com`, `*.githubusercontent.com`, `*.github.com` or any
     wildcard S3 host (`*.s3.*`);
  6. no 12-digit literal (an account ID): account hosts are written from `${{ secrets.* }}`
     expressions.

Usage: python -I scripts/harden_runner_policy.py <workflow file>...
Prints one violation per line on stdout, with paths relative to the working directory.
Exit codes: 0 all files pass, 1 violations, 2 usage error.
Run through scripts/check-harden-runner.sh, which picks the interpreter and lists the files.
"""

import os
import re
import sys
from pathlib import Path
from typing import Any

import yaml

# `python -I` leaves the script directory off sys.path; the helper module sits next to this file.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workflow_yaml import load_workflow  # noqa: E402  (import after the path setup above)

ACTION = "step-security/harden-runner@"
# One endpoint is a run of non-space characters; `${{ ... }}` may hold spaces and stays whole.
ENDPOINT = re.compile(r"(?:\$\{\{.*?\}\}|\S)+")
EXPRESSION = re.compile(r"\$\{\{.*?\}\}")
PORT = re.compile(r":[0-9]{1,5}$")
ACCOUNT_ID = re.compile(r"(?<![0-9A-Za-z])[0-9]{12}(?![0-9A-Za-z])")
BROAD_HOSTS = ("*", "*.amazonaws.com", "*.githubusercontent.com", "*.github.com")


def _has_id_token(permissions: Any) -> bool:
    if permissions == "write-all":
        return True
    return isinstance(permissions, dict) and permissions.get("id-token") == "write"


def _endpoint_problems(endpoint: str) -> list[str]:
    problems: list[str] = []
    if not PORT.search(endpoint):
        problems.append(f"endpoint '{endpoint}' has no :port")
    host = PORT.sub("", endpoint)
    if host in BROAD_HOSTS or ("*" in host and re.search(r"\.s3[.-]", host)):
        problems.append(f"endpoint '{endpoint}' is a broad wildcard")
    if ACCOUNT_ID.search(EXPRESSION.sub("", endpoint)):
        problems.append("an endpoint holds a 12-digit literal (build it from a secret expression)")
    return problems


def _step_problems(step: Any, credentialed: bool) -> list[str]:
    uses = step.get("uses") if isinstance(step, dict) else None
    if not isinstance(uses, str) or not uses.startswith(ACTION):
        return ["the first step is not step-security/harden-runner"]
    with_ = step.get("with")
    with_ = with_ if isinstance(with_, dict) else {}
    policy = with_.get("egress-policy")
    problems: list[str] = []
    if credentialed:
        if policy != "block":
            problems.append("has id-token: write, so egress-policy must be block")
        if with_.get("disable-telemetry") not in (True, "true"):
            problems.append("has id-token: write, so disable-telemetry must be true")
    elif policy != "audit":
        problems.append("has no id-token: write, so egress-policy must be audit (written out)")
    endpoints = with_.get("allowed-endpoints")
    for endpoint in ENDPOINT.findall(endpoints if isinstance(endpoints, str) else ""):
        problems.extend(_endpoint_problems(endpoint))
    return problems


def check(path: Path) -> list[str]:
    """Violations of one workflow file, as `<file>: job '<id>': <message>` lines."""
    shown = os.path.relpath(path)
    try:
        document = load_workflow(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        return [f"{shown}: invalid YAML: {getattr(e, 'problem', None) or 'parse error'}"]
    jobs = document.get("jobs") if isinstance(document, dict) else None
    if not isinstance(jobs, dict):
        return [f"{shown}: no jobs mapping"]
    workflow_permissions = document.get("permissions")
    problems: list[str] = []
    for job_id, job in jobs.items():
        job = job if isinstance(job, dict) else {}
        # A job without its own `permissions:` inherits the workflow's.
        permissions = job.get("permissions", workflow_permissions)
        steps = job.get("steps")
        first = steps[0] if isinstance(steps, list) and steps else None
        problems.extend(
            f"{shown}: job '{job_id}': {message}"
            for message in _step_problems(first, _has_id_token(permissions))
        )
    return problems


def main(argv: list[str]) -> int:
    if not argv:
        print("usage: harden_runner_policy.py <workflow file>...", file=sys.stderr)
        return 2
    problems: list[str] = []
    for name in argv:
        path = Path(name)
        if not path.is_file():
            problems.append(f"{os.path.relpath(path)}: workflow not found")
            continue
        problems.extend(check(path))
    for line in problems:
        print(line)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
