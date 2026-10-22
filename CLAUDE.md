# ship-it-safely

Lab: ship a small containerized app to AWS ECS Fargate through GitHub Actions + Terraform, with OIDC, least
privilege and supply-chain hardening. `PLAN.md` is the requirements source; `docs/adr/` holds locked decisions
(read `0001-lab-decisions.md` first).

## Rules

- Work one phase of `PLAN.md` at a time and stop at every **Checkpoint** with the exact commands for the user.
- Never run `terraform apply`, `terraform destroy`, `terraform import`, `terraform state rm|mv|push`,
  `aws secretsmanager put-secret-value|get-secret-value`, or `aws iam create-access-key`. Prepare the command;
  the user runs it (NFR-9). Guardrails: `.claude/settings.json` deny rules and the `sis-team` guard hook.
- This shell has no AWS credentials on purpose. Do not ask for them or export a profile.
- Never commit secrets, a real `.env`, `*.tfstate`, `*.tfvars` holding account IDs, or plan files.
- Look up current versions and commit SHAs for actions and tools; never guess them (NFR-3).
- Follow `docs/reference/CODING_STANDARDS.md` (Python, Dockerfile, Terraform, GitHub Actions).
- Load the `pr-conventions` skill before committing, branching or opening a PR. It holds the commit and PR title
  format (Conventional Commits, `infra` type for Terraform) and the Pre-PR Checks: ruff, mypy, unittest,
  hadolint, `terraform fmt`/`validate`, `tflint`, `actionlint`, `pre-commit run --all-files`.
- Commit per phase, e.g. `infra(app-ecs): fargate service with secrets manager injection`.
- Trunk-based: short feature branch, PR into `main`, squash merge. No `develop` branch.

## Agent team

The `sis-team` plugin (`plugins/sis-team/`) provides `/sis-team:plan <phase>`, `/sis-team:run <phase>` and
`/sis-team:review`. Build agents work in their own worktree and own disjoint paths:

| Agent | Owns |
|---|---|
| `backend-dev` | `app/**` |
| `devops-engineer` | `infra/**`, `.github/**`, repo tooling config (`.tflint.hcl`, `.pre-commit-config.yaml`) |

The orchestrating session (the one running `/sis-team:run`) owns `README.md` and `docs/**`: it writes ADRs
from the architect's text and updates the docs after the merge. Build agents never edit them (ADR 0001, D14).

Verify agents (`e2e`, `reviewer`, `security-reviewer`, `code-simplifier`) never edit files; `reviewer` also checks docs drift.
