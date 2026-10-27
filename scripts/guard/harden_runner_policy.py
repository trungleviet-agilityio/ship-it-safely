"""harden-runner policy for GitHub workflow files (ADR 0007 S45, NFR-4).

Jobs that hold AWS credentials (`id-token: write`) must run harden-runner in block mode with
telemetry off and an exact allowlist, so an exfiltration path needs an allowed host and the
account-bearing hostnames never reach a third-party insights page. Every other job must say
`egress-policy: audit` out loud, so a new job cannot ship with the action's silent default (block)
or with no hardening.

Rules, per job:
  1. the first step is step-security/harden-runner, with no `if:` and no `continue-on-error:`;
  2. a job with `id-token: write` has `egress-policy: block`, `disable-telemetry: true` and
     `disable-sudo-and-containers: true` (except the jobs in NEEDS_CONTAINERS), and no
     `container:` or `services:`;
  3. any other job has `egress-policy: audit`;
  4. every allowed endpoint is `host:port` and holds no 12-digit literal (an account ID);
  5. in a credentialed job an endpoint holds no `*`, and the only expressions are the ones in
     ALLOWED_EXPRESSIONS (account hosts come from the secret, never from a literal);
  6. in any other job no endpoint holds a `secrets.` expression.

Usage: python -I scripts/guard/harden_runner_policy.py <workflow file>...
Prints one violation per line on stdout, with paths relative to the working directory.
Exit codes: 0 all files pass, 1 violations, 2 usage error.
Run through scripts/guard/harden-runner.sh, which picks the interpreter and lists the files.
"""

import os
import re
import sys
from typing import Any

# `python -I` leaves the script directory off sys.path; the helper module sits next to this file.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workflow_yaml import run  # noqa: E402  (import after the path setup above)

ACTION = "step-security/harden-runner@"
# One endpoint is a run of non-space characters; `${{ ... }}` may hold spaces and stays whole.
ENDPOINT = re.compile(r"(?:\$\{\{.*?\}\}|\S)+")
EXPRESSION = re.compile(r"\$\{\{\s*(.*?)\s*\}\}")
PORT = re.compile(r":[0-9]{1,5}$")
ACCOUNT_ID = re.compile(r"(?<![0-9A-Za-z])[0-9]{12}(?![0-9A-Za-z])")
ALLOWED_EXPRESSIONS = ("vars.AWS_REGION", "secrets.AWS_ACCOUNT_ID_DEV", "env.ENV")
# The one credentialed job that needs Docker (docker load and docker push), so it cannot disable
# containers. The residual risk is recorded in ADR 0007. Keyed by (workflow file name, job id).
NEEDS_CONTAINERS = (("app-deploy.yml", "deploy"),)


def _has_id_token(permissions: Any) -> bool:
    if permissions == "write-all":
        return True
    return isinstance(permissions, dict) and permissions.get("id-token") == "write"


def _endpoint_problems(endpoint: str, credentialed: bool) -> list[str]:
    problems: list[str] = []
    expressions = EXPRESSION.findall(endpoint)
    literal = EXPRESSION.sub("", endpoint)
    if not PORT.search(endpoint):
        problems.append(f"endpoint '{endpoint}' has no :port")
    if ACCOUNT_ID.search(literal):
        problems.append("an endpoint holds a 12-digit literal (build it from a secret expression)")
    if credentialed:
        if "*" in literal:
            problems.append(f"endpoint '{endpoint}' holds a wildcard (list exact hosts)")
        problems.extend(
            f"endpoint '{endpoint}' uses the expression '{e}' (allowed: "
            f"{', '.join(ALLOWED_EXPRESSIONS)})"
            for e in expressions
            if e not in ALLOWED_EXPRESSIONS
        )
    elif any(e.startswith("secrets.") for e in expressions):
        problems.append(f"endpoint '{endpoint}' reads a secret in a job without credentials")
    return problems


def _step_problems(step: Any, credentialed: bool, needs_containers: bool) -> list[str]:
    uses = step.get("uses") if isinstance(step, dict) else None
    if not isinstance(uses, str) or not uses.startswith(ACTION):
        return ["the first step is not step-security/harden-runner"]
    problems = [
        f"harden-runner must not set `{k}:`" for k in ("if", "continue-on-error") if k in step
    ]
    with_ = step.get("with")
    with_ = with_ if isinstance(with_, dict) else {}
    policy = with_.get("egress-policy")
    if credentialed:
        required = ["disable-telemetry"]
        if not needs_containers:
            required.append("disable-sudo-and-containers")
        if policy != "block":
            problems.append("has id-token: write, so egress-policy must be block")
        problems.extend(
            f"has id-token: write, so {key} must be true"
            for key in required
            if with_.get(key) not in (True, "true")
        )
    elif policy != "audit":
        problems.append("has no id-token: write, so egress-policy must be audit (written out)")
    endpoints = with_.get("allowed-endpoints")
    for endpoint in ENDPOINT.findall(endpoints if isinstance(endpoints, str) else ""):
        problems.extend(_endpoint_problems(endpoint, credentialed))
    return problems


def check(shown: str, document: Any) -> list[str]:
    """Violations of one parsed workflow, as `<file>: job '<id>': <message>` lines."""
    jobs = document.get("jobs") if isinstance(document, dict) else None
    if not isinstance(jobs, dict):
        return [f"{shown}: no jobs mapping"]
    workflow_permissions = document.get("permissions")
    problems: list[str] = []
    for job_id, job in jobs.items():
        job = job if isinstance(job, dict) else {}
        # A job without its own `permissions:` inherits the workflow's.
        credentialed = _has_id_token(job.get("permissions", workflow_permissions))
        steps = job.get("steps")
        first = steps[0] if isinstance(steps, list) and steps else None
        needs_containers = (os.path.basename(shown), job_id) in NEEDS_CONTAINERS
        messages = _step_problems(first, credentialed, needs_containers)
        if credentialed:
            messages += [
                f"has id-token: write, so `{k}:` is not allowed"
                for k in ("container", "services")
                if k in job
            ]
        problems.extend(f"{shown}: job '{job_id}': {m}" for m in messages)
    return problems


if __name__ == "__main__":
    sys.exit(run("harden_runner_policy.py", check, sys.argv[1:]))
