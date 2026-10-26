# ship-it-safely

> Vibe coding an app is easy; shipping it safely is hard.

A small containerized app shipped to AWS ECS Fargate through GitHub Actions + Terraform: OIDC instead of
access keys, separate plan/apply/deploy roles, Secrets Manager per environment, supply-chain hardening.

- Requirements and phases: [`PLAN.md`](PLAN.md)
- Locked decisions: [`docs/adr/`](docs/adr/)
- Agent team: [`plugins/sis-team/`](plugins/sis-team/)

## Agent team (Claude Code plugin `sis-team`)

| Agent | Phase | Model | Access | Job |
|---|---|---|---|---|
| `solution-architect` | Plan | opus | Read-only + web | ADR per phase: IAM, OIDC trust, module design, from official docs |
| `backend-dev` | Build | sonnet | Full, own worktree | `app/**`: app, Dockerfile, compose, tests (TDD) |
| `devops-engineer` | Build | sonnet | Full, own worktree, no apply | `infra/**`, `.github/**`: Terraform, workflows, linters |
| `e2e` | Verify | sonnet | Bash, no edits | compose up + endpoint checks, offline `terraform test`, compare with `main` |
| `reviewer` | Verify | sonnet | Read-only | Bugs, logic, coverage of FR/NFR |
| `security-reviewer` | Verify | opus | Read-only | IAM, trust `sub`, `iam:PassRole`, pinning, secret leaks |
| `code-simplifier` | Verify | sonnet | Read-only | Redundant Terraform/YAML/app code |

Docs (`README.md`, `docs/**`) are written by the session that runs `/sis-team:run`, after the merge and before
verify; `reviewer` checks them for drift (ADR 0001, D14).

Commands: `/sis-team:plan <phase>`, `/sis-team:run <phase>`, `/sis-team:review [PR]`, `/sis-team:team` (this
table, generated from the agent files) and `/sis-team:diagram <topic>` (AWS architecture diagrams in
[`docs/diagrams/`](docs/diagrams/)).

Guardrails (ADR 0001, D8): no admin AWS credentials in the Claude Code shell, deny rules in
`.claude/settings.json`, and a `PreToolUse` guard hook in the plugin. `terraform apply`/`destroy` and secret
values are always handled by a human at the checkpoint.

## Setup

Prerequisites (macOS): Docker, the GitHub CLI and [mise](https://mise.jdx.dev). Every other CLI the repo
uses (Terraform 1.17.0, terraform-docs, tflint, actionlint, hadolint, shellcheck, gitleaks, trivy, pre-commit,
uv) is pinned in [`mise.toml`](mise.toml). Install them once from the repo root:

```bash
brew install mise
```

```bash
mise install
```

For `/sis-team:diagram` exports, also `brew install --cask drawio` (draw.io Desktop and its CLI; mise has no
draw.io).

Add `eval "$(mise activate zsh)"` to `~/.zshrc` so the pinned versions come first on `PATH` inside the repo
(`which terraform` should point into `~/.local/share/mise`). Another version manager that also ships
`terraform` (for example asdf) must not come before mise on `PATH`.

Install the git hooks once:

```bash
pre-commit install
```

Register the repo-local marketplace and install the plugin once (from the repo root):

```bash
claude plugin marketplace add ./
```

```bash
claude plugin install sis-team@sis-lab --scope project
```

Day to day, run everything through `make` (`make help` lists the targets):

| Target | Does |
|---|---|
| `make up` / `make down` | Run or stop the app on http://localhost:8080 (creates `app/.env` from the example) |
| `make test` | App unit tests |
| `make lint` | pre-commit hooks (including gitleaks, zizmor and the account-ID guard), hadolint, shellcheck, actionlint |
| `make tf-check` | Offline Terraform policy rules (with their self-test), README check, `fmt`, `validate`, `terraform test` (no AWS; uses a temporary data dir, so a real S3 `init` in the checkout does not break it) |
| `make docs` | Regenerate the `terraform-docs` tables in Terraform READMEs |
| `make check` | All of the above checks; what a PR must pass |

There is no `apply` or `destroy` target: you run those by hand at the checkpoint (ADR 0001, D15).

Then in Claude Code: `/sis-team:run 0` to build Phase 0 (local app).

## Infrastructure

Terraform lives in [`infra/terraform/`](infra/terraform/), and each root and module documents itself in its own
`README.md`: start with [`infra/terraform/README.md`](infra/terraform/README.md). Phase 1 (bootstrap a dev
account) is in [`infra/terraform/bootstrap/README.md`](infra/terraform/bootstrap/README.md).

## Pipelines (`.github/workflows/`)

| Workflow | Trigger | Does |
|---|---|---|
| [`terraform-iac.yml`](.github/workflows/terraform-iac.yml) | PR to `main` touching `infra/**` (and its scripts) | `checks` (no AWS: policy rules, fmt, validate, `terraform test`, tflint, trigger allowlist, account-ID guard), then `plan` with the plan role (no `environment:`), plan-role negative tests, and one sticky PR comment with counts and changed addresses (no account ID) |
| | push to `main` touching `envs/dev` or `modules/`, or `workflow_dispatch` | `apply` in environment `dev` (your approval required) with the apply role: plan, then apply that saved plan |
| [`oidc-smoke-test.yml`](.github/workflows/oidc-smoke-test.yml) | PR to `main` that changes the workflow file | Assumes `sis-dev-gha-plan` through OIDC and runs `aws sts get-caller-identity`; prints the assumed-role ARN with the account masked |
| | `workflow_dispatch` (run it with `--ref main`) | Negative test N1: the plan role must refuse a non-PR token, so the job passes only when the assume step is denied |

Repo configuration it reads: secret `AWS_PLAN_ROLE_ARN_DEV` (a secret, not a variable, so the account ID in
the ARN never shows in public logs; ADR 0003 C10) and variable `AWS_REGION`. No AWS keys are stored anywhere.
Fork and Dependabot PRs skip the job, since GitHub gives them no OIDC token. The workflow is a diagnostic,
not a required status check.

Every job starts with `step-security/harden-runner` in `audit` mode, every action is pinned to a commit SHA,
and pre-commit runs [zizmor](https://docs.zizmor.sh/) on workflows (rejects `pull_request_target`, unpinned
actions, template injection). After the Phase 1 checkpoint, set the secret (you run this, not Claude; the
bootstrap state is in S3, so log in with `aws sso login --profile sis-dev-admin` and export
`AWS_PROFILE=sis-dev-admin` first):

```bash
terraform -chdir=infra/terraform/bootstrap output -raw plan_role_arn | gh secret set AWS_PLAN_ROLE_ARN_DEV
```

After merge, run the negative test from `main`:

```bash
gh workflow run oidc-smoke-test.yml --ref main
```

The full checkpoint (log checks, CloudTrail cross-check) is in
[ADR 0003](docs/adr/0003-phase-2-oidc-smoke-test.md#checkpoint-steps-the-user-runs-these-claude-never-does-nfr-9).

### Repo configuration the pipelines read

| Where | Name | Kind |
|---|---|---|
| Repo | `AWS_PLAN_ROLE_ARN_DEV`, `AWS_ACCOUNT_ID_DEV` | secrets (they hold the account ID) |
| Repo | `AWS_REGION` | variable |
| Environment `dev` | `AWS_APPLY_ROLE_ARN` | secret |
| Environment `dev` | required reviewer (you), deployment branches: `main` only | protection rules |

The state bucket name is derived from the account ID and region, so it is not stored anywhere (ADR 0004 E22).
Workflow `name:` values are part of the AWS trust: `terraform-iac` and `terraform-destroy` may use the apply
role, `app-deploy` the deploy role (ADR 0004 E2).

### Dev stack, cost and teardown

`envs/dev` uses [`modules/app-ecs`](infra/terraform/modules/app-ecs/README.md): a VPC with two public subnets
(no NAT), an internet-facing ALB on HTTP 80, one Fargate task (0.25 vCPU, 0.5 GB, `ROLLING` with circuit
breaker rollback), ECR, a 7-day log group and the secret shell `sis/dev/app-api-key`. Until Phase 4 the task
runs a pinned placeholder image that only answers `/health`.

The ALB and Fargate bill by the hour. **Destroy `envs/dev` at the end of every session** with the teardown
steps in [ADR 0004 B8](docs/adr/0004-phase-3-infra-pipeline-ecs.md) (a local, admin-run destroy until Phase 5
adds `terraform-destroy.yml`), and re-create it next time with **Run workflow** on `terraform-iac`. The
bootstrap stack (state bucket, roles, budget) costs close to nothing and stays.

After the first apply the service waits for the secret value: set it (you, never Claude) and force a new
deployment, as in ADR 0004 B5.

## Tonight (Phase 0 to 3)

| Phase | Needs AWS? | You do by hand |
|---|---|---|
| 0 Scaffold + local app | No | `docker compose up`, check `/`, `/admin`, `BREAK=true` |
| 1 Bootstrap dev account | **Yes**: dev account ID, SSO admin login, budget email | `terraform apply` bootstrap, migrate state, GitHub environment `dev` + variables |
| 2 OIDC smoke test | Yes (roles from Phase 1) | Set secret `AWS_PLAN_ROLE_ARN_DEV`, read the assumed-role ARN in the PR run, run N1 after merge |
| 3 Infra pipeline + ECS | Yes | Re-apply bootstrap (PR 1), environment `dev` and secrets, approve apply, `put-secret-value`, negative tests, teardown |

Cost: ALB + Fargate bill hourly. Destroy `envs/dev` at the end of every session.
