# ship-it-safely

> Vibe coding an app is easy; shipping it safely is hard.

A small containerized app shipped to AWS ECS Fargate through GitHub Actions + Terraform: OIDC instead of
access keys, separate plan/apply/deploy roles, Secrets Manager per environment, supply-chain hardening.

- Requirements and phases: [`PLAN.md`](PLAN.md)
- Phase status: [`PROGRESS.md`](PROGRESS.md)
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

Create the hash-locked CI venv once (PyYAML for the workflow trigger check, ADR 0007 S34; `make check`
needs it):

```bash
make venv
```

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
| `make venv` | Hash-locked CI venv in `.venv-ci` (PyYAML for the workflow trigger check); created once, then reused |
| `make up` / `make down` | Run or stop the app on http://localhost:8080 (creates `app/.env` from the example) |
| `make test` | App unit tests |
| `make lint` | pre-commit hooks (including gitleaks, zizmor and the account-ID guard), hadolint, shellcheck, actionlint, CI helper self-tests |
| `make tf-check` | Offline Terraform policy rules (with their self-test), README check, `fmt`, `validate`, `terraform test` (no AWS; uses a temporary data dir, so a real S3 `init` in the checkout does not break it) |
| `make docs` | Regenerate the `terraform-docs` tables in Terraform READMEs |
| `make verify` (or `make image` / `make smoke` / `make scan`) | Build the app image the way CI does, run it like Fargate (read-only, UID 10001, root-owned `/tmp`), scan it with Trivy (fixable HIGH or CRITICAL fails). The same recipe as `app-ci` (`scripts/image-verify.sh`). Not part of `make check` |
| `make check` | All of the above checks; what a PR must pass |

There is no `apply` or `destroy` target (ADR 0001, D15): `envs/dev` is applied by `terraform-iac` and destroyed
by `terraform-destroy`, both after your approval; only the bootstrap stack is applied and destroyed by hand.

Then in Claude Code: `/sis-team:run 0` to build Phase 0 (local app).

## Infrastructure

Terraform lives in [`infra/terraform/`](infra/terraform/), and each root and module documents itself in its own
`README.md`: start with [`infra/terraform/README.md`](infra/terraform/README.md). The one-time bootstrap of an
account (state bucket, OIDC provider, roles, budget) is in
[`infra/terraform/bootstrap/README.md`](infra/terraform/bootstrap/README.md).

`envs/dev` uses [`modules/app-ecs`](infra/terraform/modules/app-ecs/README.md): a VPC with two public subnets
(no NAT), an internet-facing ALB on HTTP 80, one Fargate task (0.25 vCPU, 0.5 GB, `ROLLING` with circuit
breaker rollback), ECR, a 7-day log group and the secret shell `sis/dev/app-api-key`. Terraform owns the shape
of the task definition; `app-deploy` only swaps in the app image by digest (ADR 0005 F2). The app runs as UID
10001 with a read-only root and must never write to disk.

## How the trust works

GitHub Actions never holds AWS keys. Each job asks GitHub for an OIDC token and exchanges it with AWS STS for
one role. The role's trust policy decides which tokens it accepts (ADR 0002 B13, ADR 0004 E1 and E2):

| Condition | Value | What it blocks |
|---|---|---|
| `aud` | `sts.amazonaws.com` | Tokens minted for another audience |
| `sub` (immutable format) | `repo:OWNER@OWNER_ID/REPO@REPO_ID:pull_request` (plan) or `...:environment:dev` (apply, deploy) | Other repos, a renamed or re-created repo with the same name, the wrong event or environment |
| `repository_id`, `repository_owner_id` | numeric IDs | The same, as a second check |
| `ref` on the plan role | `StringLike refs/pull/*/merge` | `pull_request_target` runs and dispatched runs, which carry `refs/heads/main` |
| `ref` on apply and deploy | `refs/heads/main` | A branch run that adds `environment: dev` to a job |
| `aws:RequestedRegion` on every role | `ap-southeast-1` | An assumption through another region's STS or the global endpoint, where the security alert does not look (ADR 0007 verify M1) |
| `job_workflow_ref` on apply and deploy | `OWNER/REPO/.github/workflows/terraform-iac.yml@refs/heads/main` and `.../terraform-destroy.yml@refs/heads/main` (apply); `.../app-deploy.yml@refs/heads/main` (deploy) | Any other workflow file, even one that copies a trusted `name:`; a renamed file needs a bootstrap re-apply (ADR 0007 S2) |

Gates outside the trust policy:

- **Environment `dev`:** your approval, and deployments only from `main`.
- **Guardrails** on every GitHub role: no secret values, no SSM parameters, no role chaining, no writes to the
  GitHub roles, guardrails, boundary or OIDC provider, no access to the bootstrap state.
- **ECS role boundary:** any role the apply role creates is capped by `sis-dev-ecs-boundary`.
- **Exact `iam:PassRole`:** only the two ECS roles, only to `ecs-tasks.amazonaws.com`.
- **`repo-guard`:** every workflow may only use `pull_request`, `push` or `workflow_dispatch` (checked with a
  real YAML parser).
- **Security alert:** a CloudTrail trail plus an EventBridge rule email you (SNS) about every refused
  `AssumeRoleWithWebIdentity` in ap-southeast-1 and any assumption with a `sub` other than the two trusted ones
  (ADR 0007 S8). The region pin means a success can only happen there; refused probes in other regions are not
  alerted (accepted: they grant nothing).

## Pipelines (`.github/workflows/`)

| Workflow | Trigger | Does |
|---|---|---|
| [`terraform-iac.yml`](.github/workflows/terraform-iac.yml) | PR to `main` touching `infra/**` (and its scripts) | `checks` (no AWS: policy rules, fmt, validate, `terraform test`, tflint), then `plan` with the plan role (no `environment:`), plan-role negative tests, and one sticky PR comment with counts and changed addresses (no account ID). PR plans queue instead of cancelling, so a state lock is never left behind |
| | push to `main` touching `envs/dev`, `modules/` or the workflow file, or `workflow_dispatch` | `apply` in environment `dev` (your approval required) with the apply role: plan, then apply that saved plan |
| [`terraform-destroy.yml`](.github/workflows/terraform-destroy.yml) | `workflow_dispatch` only: input `env` (`dev`) and `confirm`, which must be typed as `destroy-dev` | Job `confirm` (no AWS, no secrets) rejects a wrong phrase before any approval is requested. Job `destroy` (environment `dev`, your approval, apply role): `plan -destroy`, a guard that refuses any action other than delete, apply of that same saved plan, then deregisters the task definition revisions `app-deploy` registered. Green with "nothing to destroy" when the stack is already gone. Shares one concurrency group with the `terraform-iac` apply |
| [`app-ci.yml`](.github/workflows/app-ci.yml) | PR to `main` touching `app/**` (and its scripts) | No AWS, no secrets: hadolint, build once (unit tests run inside the build), Fargate-like smoke test, Trivy gate. Never pushes |
| [`app-deploy.yml`](.github/workflows/app-deploy.yml) | push to `main` touching `app/**` or the scripts it runs, or `workflow_dispatch` | Two jobs. `build-scan` has **no OIDC, no environment and no secrets**: build, smoke, Trivy, then the image tar as a one-day artifact with its sha256. `deploy` (environment `dev`, your approval) verifies the sha256 before `docker load`, checks the stack is up and the secret has a value, then pushes once to ECR with the git SHA tag, registers a task definition revision that references the image **digest** (only `image` changes; the hardened shape is validated), updates the service and waits until the rollout is `COMPLETED` (a circuit-breaker rollback fails the run). The file path is in the deploy role trust: renaming the file needs a bootstrap re-apply |
| [`repo-guard.yml`](.github/workflows/repo-guard.yml) | every PR to `main` and push to `main`, no path filter | No AWS, no secrets: zizmor, the account-ID guard, gitleaks, the workflow trigger allowlist and the CI helper self-tests. It must never be listed in the bootstrap `workflow_files` |
| [`oidc-smoke-test.yml`](.github/workflows/oidc-smoke-test.yml) | PR to `main` that changes the workflow file or its scripts; `workflow_dispatch` | Diagnostic and negative tests. On a PR: the token is refused by the apply and deploy roles (N8), a 3601 s session on the plan role is refused and a 900 s one shows its expiry (N9), then the plan role is assumed. On dispatch: every role refuses the non-PR token (N1). Each refusal also sends a security alert email, by design |

Every job starts with `step-security/harden-runner` in `audit` mode, every action is pinned to a commit SHA, and
tools (Terraform, tflint, Trivy, hadolint) are checksum-verified binaries. Fork and Dependabot PRs get no OIDC
token, so the jobs that assume a role skip them.

### Dependabot

[`.github/dependabot.yml`](.github/dependabot.yml) opens one grouped PR a month per ecosystem (GitHub Actions,
the Docker base image, Terraform providers, pre-commit hooks), each after a 7-day cooldown; security updates come
at once. Two rules when you handle them:

- **Terraform PRs get no plan** (Dependabot has no secrets). Before merging one, re-open it from your own
  branch: `gh pr checkout <N>`, `git switch -c deps/terraform-<date>`, `git push -u origin HEAD`, open a PR,
  read its plan comment, merge it, and close the Dependabot PR.
- **Merging an actions PR touches every workflow**, so the `terraform-iac` apply and `app-deploy` start. If the
  stack is down, **reject** the pending apply: approving it re-creates the stack.

Not covered by Dependabot, so check them monthly by hand: the tool versions in `mise.toml` with
`scripts/ci-tools.sha256`, and `scripts/ci-requirements.txt`.

### Repo configuration the pipelines read

| Where | Name | Kind |
|---|---|---|
| Repo | `AWS_PLAN_ROLE_ARN_DEV`, `AWS_ACCOUNT_ID_DEV` | secrets (they hold the account ID; variables would print unmasked in public logs) |
| Repo | `AWS_REGION` | variable |
| Repo | `ALB_INGRESS_CIDRS_DEV` (optional) | secret: a JSON list such as `["<your IP>/32"]`. Unset means `0.0.0.0/0`. The plan masks each CIDR and the rules hold no CIDR in their names (ADR 0007 S10) |
| Environment `dev` | `AWS_APPLY_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN` | secrets, only readable by jobs you approved |
| Environment `dev` | required reviewer (you), deployment branches: `main` only | protection rules |
| Repo | ruleset on the default branch: PR required, no force push, no deletion, status check `guard (no AWS)` required | ruleset |
| Repo | [`.github/CODEOWNERS`](.github/CODEOWNERS) (`* @trungleviet-agilityio`); "require review from code owners" stays off while there is one maintainer | file |

The state bucket name is derived from the account ID and region, so it is not stored anywhere (ADR 0004 E22).

## Session flow

Re-create the dev stack:

1. **Run workflow** on `terraform-iac` (branch `main`), then approve it in `dev`. About 4 minutes.
2. Set the secret value, you and never Claude, in your own terminal, in one line so the key never lands in
   history or another shell:

```bash
APP_API_KEY_VALUE="$(openssl rand -hex 24)" && AWS_PROFILE=sis-dev-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/dev/app-api-key --secret-string "$APP_API_KEY_VALUE" --query VersionId --output text && unset APP_API_KEY_VALUE
```

3. **Run workflow** on `app-deploy` (branch `main`), then approve the `deploy` job. If you skipped step 2, the
   deploy stops at the preflight with a message saying so, instead of a failed rollout.

End of the session:

4. **Run workflow** on `terraform-destroy`: `env` = `dev`, `confirm` = `destroy-dev`, then approve.

Wait about a minute after a destroy before re-creating. Before merging an infra PR while the stack is torn
down, reject the pending `terraform-iac` apply run (or merge later), otherwise approving it re-creates the stack.

## Cost

Prices for `ap-southeast-1`, on demand, at the time of writing (see the AWS pricing pages for
[Elastic Load Balancing](https://aws.amazon.com/elasticloadbalancing/pricing/),
[Fargate](https://aws.amazon.com/fargate/pricing/),
[public IPv4 addresses](https://aws.amazon.com/vpc/pricing/) and
[Secrets Manager](https://aws.amazon.com/secrets-manager/pricing/)):

| Item | Hourly (USD) |
|---|---|
| ALB | 0.0252 |
| ALB capacity (LCU, upper bound: lab traffic is a small fraction of one LCU) | up to 0.008 |
| Fargate task: 0.25 vCPU x 0.05056 + 0.5 GB x 0.00553 | 0.0154 |
| Public IPv4: two ALB nodes and one task, 3 x 0.005 | 0.015 |
| Secret | about 0.0006 |
| **Total while the stack is up** | **about 0.056 to 0.064** |

That is 0.17 to 0.19 USD for a 3-hour session, or 1.35 to 1.54 USD a day. Left running for 30 days it would
cost about 40 to 46 USD, twice the 20 USD budget; the 80% budget alert would fire after about 10 to 12 days.
ECR storage, logs, the S3 state bucket and the budget cost cents, and GitHub-hosted minutes are free on a
public repo. **Destroy `envs/dev` at the end of every session.**

## Teardown order

Every session: `terraform-destroy` for `dev`, as in the session flow above. The bootstrap stack stays.

End of the lab (PLAN §9), in this order:

1. `terraform-destroy` for every environment (prod first, once Phase 7 exists). Run it once more and check it
   reports "nothing to destroy".
2. Bootstrap, per account, as admin, locally (CI can never touch the bootstrap state). From
   `infra/terraform/bootstrap`, with `AWS_PROFILE=sis-dev-admin`:
   1. Move the state back to local: write a `backend_override.tf` containing `terraform { backend "local" {} }`,
      run `terraform init -migrate-state -force-copy`, and check `terraform state list`.
   2. Before emptying anything, check that nothing is left: `terraform -chdir=infra/terraform/envs/dev state list`
      prints nothing (after an `init` with the backend config), and the Resource Groups Tagging API shows only
      bootstrap resources for `Project=ship-it-safely` (ADR 0006 checkpoint step 8). Then empty the state bucket
      `sis-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an`, including every object version and delete marker (the
      bucket has `force_destroy = false`): list them with `aws s3api list-object-versions` and remove them with
      `aws s3api delete-objects`, at most 1000 keys per call. Double-check the bucket name: deleted versions
      cannot be recovered.
   3. `terraform plan -destroy -var-file=accounts/dev.tfvars -out=destroy.tfplan`, read it, then apply that
      saved plan.
   4. Delete `backend_override.tf`, `destroy.tfplan` and the local state files.
3. Optionally delete the GitHub environment `dev` and the repo and environment secrets, which now point at
   deleted roles. Service-linked roles and `INACTIVE` task definitions cost nothing and can stay.

Troubleshooting:

- **Stale state lock** after a cancelled or crashed run: first check in Actions that no `terraform-iac` or
  `terraform-destroy` run is running or waiting (a destroy can legitimately hold the lock for over 30 minutes
  while the ALB network interfaces drain), and that the lock's `Who` and `Created` match the run that died.
  Only then, as admin: `terraform -chdir=infra/terraform/envs/dev init -backend-config="bucket=<state bucket>"`
  and `terraform -chdir=infra/terraform/envs/dev force-unlock <lock id>`. Never from CI. Unlocking a live lock
  lets two runs write the state, which can orphan billable resources.
- **A pending run disappeared:** `terraform-iac` apply and `terraform-destroy` share one concurrency group, so
  a newer pending run replaces an older pending one. Start the one you want again.
- **Re-create fails on the secret name:** wait a minute after a destroy; the secret is deleted immediately
  (`recovery_window_in_days = 0`), but the name can take a moment to free up.

## Release strategy

| Env | Strategy | Why |
|---|---|---|
| dev | ECS `ROLLING` with the deployment circuit breaker and automatic rollback (built) | Cheap and simple; `ecs-wait-deployment.sh` fails the run on a rollback |
| prod (Phase 7) | ECS built-in `BLUE_GREEN`: two target groups, bake time, CloudWatch alarm rollback | All traffic moves once green is healthy; fast rollback during the bake time; needs up to twice the tasks during a deploy |
| Later | ECS built-in `CANARY` or `LINEAR` | Needs real traffic and alarms that mean something: 10% of almost no requests gives no signal |

Branching is trunk-based (FR-14): merge to `main` deploys dev; a release tag or `workflow_dispatch` promotes the
same image digest to prod. No `develop` or per-env branches.

## When to move to CodeBuild runners or CodePipeline

**Stay on GitHub-hosted runners and GitHub Actions for this lab.** They are free on a public repo, and every
trust condition above is built on their OIDC token.

**CodeBuild-hosted runners** keep these workflows and change `runs-on` to a CodeBuild project label. Move when
jobs need private VPC access (database migrations, private endpoints), larger, ARM or GPU compute, or egress
control inside your VPC. Trade-offs:

- They cost build minutes, while hosted minutes are free here.
- GitHub advises against self-hosted runners on public repos, and this repo is public.
- The CodeBuild project's service role gives credentials to any job that targets its label, which bypasses the
  `sub`, `ref` and `job_workflow_ref` trust. If you move, give that role nothing beyond logs and keep assuming the OIDC
  roles from the job.
- A GitHub connection credential then lives in AWS.

**CodePipeline (V2)** fits when the organisation needs AWS-native approvals and audit (CloudTrail),
cross-account promotion with AWS identities only (the Phase 7 prod account), or deploys that must not depend
on GitHub Actions being available. The pieces would be a CodeConnections GitHub source (push, PR and tag
triggers), a manual approval action, and the ECS deploy action (or CodeDeploy for blue/green). Its ECS action
builds from the service's current revision, not Terraform's latest family revision, which differs from how
`app-deploy` works here (ADR 0005 F3).

## Phases

Status per phase: [`PROGRESS.md`](PROGRESS.md).

| Phase | Needs AWS? | You do by hand |
|---|---|---|
| 0 Scaffold + local app | No | `docker compose up`, check `/`, `/admin`, `BREAK=true` |
| 1 Bootstrap dev account | **Yes**: dev account ID, SSO admin login, budget email | Apply bootstrap, migrate state, GitHub environment `dev` and secrets |
| 2 OIDC smoke test | Yes (roles from Phase 1) | Set secret `AWS_PLAN_ROLE_ARN_DEV`, read the assumed-role ARN in the PR run, run N1 after merge |
| 3 Infra pipeline + ECS | Yes | Re-apply bootstrap, environment `dev` and secrets, approve apply, `put-secret-value`, negative tests, teardown |
| 4 App pipeline | Yes | Environment secret `AWS_DEPLOY_ROLE_ARN`, re-create the stack, approve `app-deploy`, verify the digest, merge the one-line checkpoint PR, negative tests, teardown |
| 5 Hardening and teardown | Yes | Re-apply bootstrap (deploy role reads secret metadata), re-create, negative tests N5 and N6, destroy through `terraform-destroy`, N7 |
| 6 Supply-chain hardening | Yes | Read the `job_workflow_ref` claim, re-apply bootstrap (file-pinned trust, region pin, trail and alert), confirm the alert email, read harden-runner insights, merge and prove the new trust with a re-create, deploy and destroy round, require `guard (no AWS)`. Then PR B: block mode from the collected egress list |
