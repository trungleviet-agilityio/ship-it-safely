# Coding Standards

Current-state conventions for this lab. Anything a linter already enforces is not repeated here.
The Pre-PR Checks in `.claude/skills/pr-conventions/SKILL.md` verify them.

`PLAN.md` holds the requirements, `docs/adr/` the locked decisions. When this file and an ADR
disagree, the ADR wins; update this file.

## Python (`app/`)

### Scope

- Standard library only, no runtime dependencies (ADR D4). Dev tools (ruff, mypy) run through
  pre-commit or `uvx` and never land in the image.
- Keep the app tiny: one module, about 100 lines (`PLAN.md` §6). The app is not the point of the
  lab; the pipeline is.

### Naming, imports

- Module-internal helpers get a leading underscore. Names without one are the public surface.
- Absolute imports only, no wildcard imports. Ruff's `I` and `N` rules handle order and case.

### Type hints

- Every function signature is fully typed; mypy runs in strict mode.
- Use `X | None`, `list[str]`, `dict[str, int]`. No `Optional`, `List`, `Dict`, and no
  `from __future__ import annotations` (Python 3.13). Ruff's `UP` rules flag the old forms.
- `Any` only where the runtime type is genuinely unknown (for example `*args` passed through to a
  base class).

### Docstrings, comments

- A docstring or comment earns its place when it records a contract, invariant or reason that the
  code cannot show. Do not describe what the next line does.
- Every `# noqa` carries the reason on the same line or the line above.

### Secrets and logging

- Never print, log or return the value of `APP_API_KEY` or any secret. Log method, path and
  status only, never headers.
- Compare secrets with `hmac.compare_digest`. An empty or unset expected secret never matches.
- Escape every value placed in HTML (`html.escape`).

### Error handling

- Catch specific exceptions. A broad `except Exception` is acceptable only for an optional,
  best-effort lookup that has a safe fallback (for example the ECS metadata digest returning
  `n/a`).
- When re-raising a different type, chain it: `raise NewError(...) from e`.

### Testing

- stdlib `unittest`; test files are named `test_<module>.py`.
- Every endpoint and branch of behavior the requirements name has a test (`BREAK=true`, 401 cases,
  the secret never appearing in a response).
- Tests never call real external services. Mock `urllib.request.urlopen` for ECS metadata.
- No tests that only assert something exists, and no trivial tests the type checker already
  covers. Test edge cases, not a coverage percentage.

## Dockerfile (`app/Dockerfile`)

- Base images pinned by digest (`python:3.13-slim@sha256:...`), tag kept for readability (NFR-3).
- Multi-stage: tests run in a build stage; the runtime stage copies only `src/`.
- Run as a numeric non-root user (`USER 10001:10001`).
- `HEALTHCHECK` hits `/health` with Python, no extra packages.
- No secrets in `ARG` or `ENV`. `GIT_SHA` is the only build arg. Secrets arrive at runtime
  (compose `env_file` locally, ECS `secrets[]` in AWS).
- `.dockerignore` keeps `.env*` (except `.env.example`), `.git` and caches out of the context.
- No `# syntax=` line unless a feature needs it; if it does, pin it by digest.

## Terraform (`infra/terraform/`)

### Layout

- Each root and module has `versions.tf` (`required_version = ">= 1.11, < 2.0"`, since `use_lockfile` is GA
  from 1.11; providers pinned with `~>`),
  `variables.tf`, `outputs.tf`, and resource files split by concern (`oidc.tf`, `iam_plan.tf`).
- Environments differ only through `terraform.tfvars` (FR-6). Shared logic lives in
  `modules/app-ecs`.
- Roots (`bootstrap/`, `envs/<env>/`) own `providers.tf`, the partial `backend.tf` and their inputs.
  `envs/<env>` stays thin: one `module` call plus variables and outputs. Modules declare
  `required_providers` but never a `provider` or `backend` block.

### READMEs (ADR 0001, D16)

- Every root and module has a `README.md`. Hand-write what the tables cannot say: purpose, what it
  creates, how to run it (or a usage block for a module), constraints such as name contracts, and
  teardown.
- End it with an empty `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` pair; the `terraform_docs`
  hook fills it from `.terraform-docs.yml` (`make docs`). Never edit between the markers.
- `make tf-check` fails when a directory with `.tf` files has no README or no markers.
- `.terraform.lock.hcl` is committed with `linux_amd64` and dev-machine hashes (NFR-5).

### Naming and inputs

- Resource and variable names are `snake_case`. AWS resource names use `<prefix>-<env>-<thing>`,
  including GitHub Actions roles (`sis-dev-gha-plan`). Names `envs/<env>` creates must match the
  bootstrap `resource_names` output, because the apply and deploy roles are scoped by them
  (ADR 0002).
- Every variable has a `type` and a `description`; add `validation` where a bad value would only
  fail at apply time. Mark secret-adjacent inputs `sensitive = true`.
- No account IDs in code or committed tfvars (ADR D2). Read them from
  `data "aws_caller_identity"` and guard with `allowed_account_ids`.
- Provider `default_tags`: `Project`, `Env`, `ManagedBy = "terraform"` (NFR-8).

### IAM

- Build policies with `data "aws_iam_policy_document"`, not inline JSON strings.
- No `*` in `Action` or `Resource` of an Allow unless the API does not support resource-level
  permissions; then add a comment naming the API and, where possible, a condition. The approved
  list (ADR 0002, B20): `ec2:Describe*`, `elasticloadbalancing:Describe*`,
  `logs:DescribeLogGroups`, `ecs:DescribeTaskDefinition`, `ecs:DeregisterTaskDefinition`,
  `ecr:GetAuthorizationToken`. A `terraform test` enforces it.
- Action wildcards are fine in Deny statements, where they widen protection.
- EC2 resources have random IDs, so scope EC2 writes by tag (`aws:RequestTag`/`aws:ResourceTag`
  on `Project` and `Env`) instead of by ARN.
  Keep `default_tags` on every provider so standalone security group rules are tagged too;
  untagged rules cannot be changed or deleted by the apply role.
- IAM roles that a GitHub role creates carry the bootstrap permissions boundary
  (`iam:PermissionsBoundary` condition).
- `iam:PassRole` names the exact role ARNs and sets `iam:PassedToService`.
- Plan, apply and deploy roles carry an explicit deny on `secretsmanager:GetSecretValue`
  (FR-3, FR-4, FR-5), through the shared guardrail policy.
- OIDC trust policies match `sub` exactly (`StringEquals`, never a wildcard on the repo) and check
  `aud = sts.amazonaws.com`, `repository_id` and `repository_owner_id`. The `sub` uses GitHub's
  immutable format `repo:OWNER@OWNER_ID/REPO@REPO_ID:...`. Apply and deploy roles also pin
  `ref = refs/heads/main`. The plan role pins `StringLike ref = refs/pull/*/merge`, the only
  `StringLike` allowed in a trust policy, so a `pull_request_target` run (base ref) is refused.
  IAM has no `event_name` key for GitHub. Apply and deploy roles also pin the `workflow` name
  (`terraform-iac`, `terraform-destroy`; `app-deploy`), so a workflow's `name:` must match the
  bootstrap `workflow_names` output (ADR 0004 E2). Role `max_session_duration = 3600` (NFR-7).

### Secrets and state

- Terraform creates secret shells only, never values, so nothing secret lands in state (FR-8).
- State buckets: versioning, SSE, public access block, TLS-only policy; `use_lockfile = true`.
- Backend blocks are partial: the bucket name holds the account ID, so it comes from
  `-backend-config="bucket=..."` at init time, never from a committed file.

### Testing

- `terraform test` with `mock_provider` for module logic, since agents have no AWS credentials
  (ADR D12). The real plan runs in CI with the plan role.

## GitHub Actions (`.github/workflows/`)

- Every third-party action is pinned to a full commit SHA with the version in a comment (NFR-3).
  Tool binaries are pinned by version and checksum-verified.
- `step-security/harden-runner` is the first step of every job (NFR-4). Set `egress-policy`
  explicitly (`audit` until Phase 6); its default is `block`.
- Pin `runs-on` to a versioned label (`ubuntu-24.04`), not `ubuntu-latest`.
- No `actions/checkout` and no `contents: read` unless the job needs repo files.
- `permissions:` at workflow level is `{}` or read-only; each job grants what it needs.
  `id-token: write` only on jobs that assume a role (NFR-2).
- Never store AWS access keys (NFR-1). Values that contain the account ID (role ARNs) are GitHub
  **secrets**, because variables print unmasked in public logs; names and the region are
  **variables** (ADR 0003 C10). Set `mask-aws-account-id: true` on `configure-aws-credentials`.
- Jobs that need an OIDC token skip fork and Dependabot PRs, which get none:
  `github.event.pull_request.head.repo.full_name == github.repository` and
  `github.event.pull_request.user.login != 'dependabot[bot]'` (not `github.actor`, which zizmor
  flags as spoofable).
- Never use `pull_request_target`. zizmor (pre-commit) must pass with no ignore comments.
- PR plan jobs do not set `environment:` (the OIDC `sub` must be `pull_request`); apply, deploy
  and destroy jobs do.
- Never interpolate `${{ github.event.* }}` or other user-controlled values directly in `run:`.
  Pass them through `env:` and quote them in the shell.
- Set `timeout-minutes` on every job and `concurrency` on workflows that change AWS state.

- Steps that run third-party or build code (build, tests, scanners) never share a job with `id-token: write`,
  an `environment:` or secrets: GitHub permissions are per job, not per step. Hand results to the credentialed
  job as an artifact whose checksum is verified before use (ADR 0005, H1 decision).
- Prefer the runner's AWS CLI over third-party actions for steps that hold credentials; install scanners as
  checksum-verified binaries, never through their actions.
- Workflow steps stay short: logic longer than a few lines lives in `scripts/` with a usage line and a
  `ci-selftest.sh` case, so it can run and be tested outside CI.
- Images are single-platform `linux/amd64`, built once, pushed once by an immutable git-SHA tag, and deployed by
  digest. Never print the registry host, image URI or any ARN with the account ID.

## App runtime (Fargate)

- The app runs as UID 10001 with a read-only root filesystem and a root-owned `/tmp`: it must never write to
  disk. `make smoke` runs the image that way.
- Handle SIGTERM and exit 0 quickly, so rolling deploys and `docker compose down` are fast.
- Never show the ECS metadata `Image` field (it holds the registry host with the account ID); `ImageID` only.

## Tool versions (`mise.toml`)

- Every CLI the repo runs locally (Terraform, linters, scanners, pre-commit, uv) is pinned to an exact
  version in `mise.toml`, and `mise install` sets up a machine. Do not document `brew install` for
  them.
- CI pins the same versions (Terraform in `a checksum-verified Terraform binary (`scripts/install-ci-tools.sh`)`, tools by version and
  checksum), so local and CI results match (NFR-3).
- Bump a version in its own `chore(repo)` commit and run `make check` before pushing.
- Python packages stay in `pyproject.toml` and run through `uv` / `uvx`, not mise.

## Makefile and shell scripts (`Makefile`, `scripts/`)

- The `Makefile` stays thin: each target is one or two lines and has a `## description` for
  `make help`. Anything longer goes in `scripts/<name>.sh`. Never add `apply` or `destroy` targets
  (ADR 0001, D15).
- Targets must work with the GNU Make 3.81 that ships with macOS (no `.ONESHELL`, no
  `.SHELLFLAGS`).
- Scripts start with `#!/usr/bin/env bash` and `source "$(dirname "$0")/lib.sh"`, which sets
  `set -Eeuo pipefail`, `ROOT`, `log`/`ok`/`warn`/`die` and `require_cmd`. Messages go to stderr.
- Write for bash 3.2: no `mapfile`, no associative arrays, and never expand an empty array under
  `set -u`; check `${#arr[@]}` first.
- Use `terraform -chdir=<dir>` or a subshell instead of `cd` and back.
- When looping over many directories, collect failures, finish the loop, then print a summary and
  exit non-zero.
- `shellcheck -x scripts/*.sh` passes (run by `make lint`).
