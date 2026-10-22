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

Commands: `/sis-team:plan <phase>`, `/sis-team:run <phase>`, `/sis-team:review [PR]`.

Guardrails (ADR 0001, D8): no admin AWS credentials in the Claude Code shell, deny rules in
`.claude/settings.json`, and a `PreToolUse` guard hook in the plugin. `terraform apply`/`destroy` and secret
values are always handled by a human at the checkpoint.

## Setup

Prerequisites (macOS):

```bash
brew install tflint actionlint hadolint gitleaks trivy pre-commit
```

Register the repo-local marketplace and install the plugin once (from the repo root):

```bash
claude plugin marketplace add ./
```

```bash
claude plugin install sis-team@sis-lab --scope project
```

Then in Claude Code: `/sis-team:run 0` to build Phase 0 (local app).

## Tonight (Phase 0 to 3)

| Phase | Needs AWS? | You do by hand |
|---|---|---|
| 0 Scaffold + local app | No | `docker compose up`, check `/`, `/admin`, `BREAK=true` |
| 1 Bootstrap dev account | **Yes**: dev account ID, SSO admin login, budget email | `terraform apply` bootstrap, migrate state, GitHub environment `dev` + variables |
| 2 OIDC smoke test | Yes (roles from Phase 1) | Open the PR, read the assumed-role ARN |
| 3 Infra pipeline + ECS | Yes | Approve apply, `put-secret-value`, negative tests |

Cost: ALB + Fargate bill hourly. Destroy `envs/dev` at the end of every session.
