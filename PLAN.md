# Ship-it-Safely Lab — Requirements & Implementation Plan (v2)

> Hand-off file for Claude Code. Read this whole file first, then work **one phase at a time** and stop at each checkpoint.
> Pattern source: [Configuring Terraform IaC pipelines… (DevOps.dev, Oct 2026)](https://blog.devops.dev/configuring-terraform-iac-pipelines-to-provision-cloud-resources-in-cloud-and-kubernetes-3ff863fe983e)
> v2 changes: ECS Fargate instead of EKS · local/dev/prod environments · multi-account-ready · Secrets Manager per env · supply-chain hardening.

---

## 1. Goal

"Vibe coding an app is easy; shipping it safely is hard." This lab takes a small containerized app, which already runs locally with `docker compose`, and ships it to **AWS ECS Fargate** through GitHub Actions + Terraform. The security lessons are built into every step:

- No long-lived AWS keys. GitHub Actions authenticates with **OIDC**, one set of roles per AWS account.
- Separate roles for plan, apply and deploy, each least privilege.
- One AWS account per cloud environment (dev, later prod). Each environment has its own state and its own secrets.
- App secrets live in **Secrets Manager**. The pipeline never reads secret values.
- Supply-chain hardening: actions pinned by SHA, runner egress monitoring, secret scanning.

## 2. Scope

| In scope | Out of scope |
|---|---|
| `local` env (Docker Compose), `dev` env (AWS account A) | Kubernetes / EKS |
| Bootstrap stack per account (state bucket, OIDC, roles, budget) | CodePipeline / CodeBuild (mentioned in README only) |
| Infra pipeline (Terraform plan/apply) + app pipeline (build → ECR → ECS) | Custom domain + TLS certificate (optional extra) |
| Secrets Manager wired into ECS task definition | Production-grade networking (private subnets + NAT) |
| Destroy workflow, supply-chain hardening | |
| **Stretch:** `prod` env in a second AWS account via AWS Organizations | |

## 3. Inputs to fill before starting

| Variable | Example | Value |
|---|---|---|
| AWS region | `ap-southeast-1` | `ap-southeast-1` |
| Dev account ID | `111111111111` | set in `CLAUDE.local.md` (gitignored; ADR 0001 D2) |
| Prod account ID (stretch) | `222222222222` | `TODO / later` |
| GitHub owner / repo | `my-user/ship-it-safely` | `trungleviet-agilityio/ship-it-safely` (public) |
| Name prefix | `sis` | `sis` |
| Budget alert email / monthly USD | `me@example.com` / `20` | set in `CLAUDE.local.md` (gitignored) / `20` |
| App | existing app with Dockerfile, or generate the sample app (§6) | Generate Ship-it Board in Python 3.13, stdlib only (no dependencies) |

Claude Code: ask the user for any `TODO` value before writing code that depends on it.

## 4. Prerequisites

- Docker + Docker Compose, AWS CLI v2, Terraform `>= 1.10` (S3 native locking), tflint, git, `gh` (optional).
- An admin login to the dev account for the **bootstrap only**. Prefer IAM Identity Center / SSO short-lived credentials over access keys.
- **Do not** export admin credentials in the shell where Claude Code runs.

## 5. Architecture

```
local:  docker compose up  (app + .env with fake values)

GitHub ──OIDC──► AWS STS (per account)
  PR (infra/**)          → <prefix>-gha-plan    (read-only)       sub = repo:O/R:pull_request
  push main (infra/**)   → <prefix>-gha-apply   (Terraform write) sub = repo:O/R:environment:<env>
  push main (app/**)     → <prefix>-gha-deploy  (ECR push, ECS)   sub = repo:O/R:environment:<env>

dev account:  S3 state ─ ECR ─ ECS cluster ─ Fargate service ─ ALB (public)
              Secrets Manager: <prefix>/dev/app-api-key ──(execution role)──► container env APP_API_KEY
prod account (stretch): same module, own state/secrets/roles; deploy = same image digest as dev
```

Notes from official docs:
- The OIDC `sub` claim contains the environment name when the job references an environment. It contains `pull_request` only when the job does **not** reference an environment. So PR plan jobs must not set `environment:`.
- ECS `secrets[].valueFrom` takes the full ARN of a Secrets Manager secret or an SSM parameter.

## 6. Repository layout

```
.
├── PLAN.md  README.md  .gitignore  .tflint.hcl  .pre-commit-config.yaml (gitleaks)
├── app/
│   ├── Dockerfile               # multi-stage, non-root user, HEALTHCHECK
│   ├── docker-compose.yml       # local env
│   ├── .env.example             # fake values, committed; real .env is gitignored
│   └── src/...                  # sample: tiny HTTP API with GET /health and GET /
├── infra/terraform/
│   ├── bootstrap/               # run locally ONCE PER ACCOUNT: -var-file=accounts/<env>.tfvars
│   │   ├── accounts/dev.tfvars  accounts/prod.tfvars
│   │   └── state.tf oidc.tf iam_plan.tf iam_apply.tf iam_deploy.tf budget.tf ...
│   ├── modules/app-ecs/         # network (public subnets), ECR, ECS cluster/service, ALB,
│   │                            # task exec/task roles, Secrets Manager secret shells, log group
│   └── envs/
│       ├── dev/                 # backend → dev account bucket; uses modules/app-ecs
│       └── prod/                # stretch
└── .github/workflows/
    ├── oidc-smoke-test.yml
    ├── terraform-iac.yml        # plan on PR, apply on main (per env)
    ├── app-ci.yml               # PR: build, test, scan image (no AWS)
    ├── app-deploy.yml           # main: build once → push ECR dev → deploy dev; promote digest → prod (stretch)
    └── terraform-destroy.yml    # workflow_dispatch
```

**Demo app: "Ship-it Board".** The app is NOT the target of this lab; keep it tiny (one file, about 100 lines, no database, no frontend framework). Use Node or Python, user's choice.

| Endpoint | Behavior |
|---|---|
| `GET /` | One HTML page showing `APP_ENV` (local/dev/prod), `GIT_SHA` (Docker build arg), deploy/start time, and image digest if available (read from `ECS_CONTAINER_METADATA_URI_V4`; show `n/a` locally). Background color comes from `APP_COLOR`, or is derived from `GIT_SHA`, so a new version is visibly different during blue/green. Shows `secret_loaded: yes/no`. |
| `GET /health` | `200 {"status":"ok"}`. If `BREAK=true`, returns `500` (used to demo alarm-driven rollback). |
| `GET /version` | JSON with env, git SHA, image digest. |
| `GET /admin` | Requires header `X-API-Key` equal to `APP_API_KEY` (from Secrets Manager); returns `401` otherwise. |

Rules: never print or log the value of `APP_API_KEY`. Run as a non-root user. Make the `HEALTHCHECK` hit `/health`.

## 7. Requirements

### Functional

| ID | Requirement |
|---|---|
| FR-1 | `docker compose up` runs the app locally using `.env`. `.env.example` is committed with fake values; `.env` is gitignored. |
| FR-2 | Bootstrap (per account): S3 state bucket (versioning, SSE, public access block, TLS-only policy), GitHub OIDC provider, budget alert at 80%. |
| FR-3 | **Plan role:** trusts `repo:O/R:pull_request`. Permissions: `ReadOnlyAccess` + state read + put/delete `*.tflock`. Explicit **deny** on `secretsmanager:GetSecretValue`. |
| FR-4 | **Apply role:** trusts `repo:O/R:environment:<env>`. Permissions: state read/write + only the services in `modules/app-ecs`. `iam:PassRole` is limited to the module's ECS roles. Explicit **deny** on `secretsmanager:GetSecretValue`. |
| FR-5 | **Deploy role:** trusts `repo:O/R:environment:<env>`. Permissions: push to the one ECR repo, `ecs:RegisterTaskDefinition`, `ecs:DescribeServices`, `ecs:UpdateService` on the one service, `iam:PassRole` on the task + execution roles only. No Secrets Manager read. |
| FR-6 | `envs/<env>` uses the S3 backend in **its own account**, with `use_lockfile = true`. Values differ only through `terraform.tfvars`. |
| FR-7 | `modules/app-ecs`: VPC with 2 public subnets (no NAT, tasks get public IPs, lab only), ALB → target group → Fargate service (0.25 vCPU / 0.5 GB, 1 task), ECR repo (scan on push, immutable tags), CloudWatch log group (7-day retention). |
| FR-8 | Secrets: Terraform creates only the **secret shell** `<prefix>/<env>/app-api-key` (no value, so nothing lands in state). The task definition maps it via `secrets[].valueFrom` = secret ARN. The execution role may `GetSecretValue` on that ARN only. The user sets the value with the AWS CLI, outside git and outside Terraform. |
| FR-9 | `terraform-iac.yml`: on PR touching `infra/**` → fmt, init, validate, tflint, plan, PR comment (plan role, **no** `environment:`). On push to `main` → apply, with `environment: dev`, required reviewer. |
| FR-10 | `app-ci.yml`: on PR touching `app/**` → build image, run tests, scan the image (e.g. Trivy **pinned by version + checksum**), no push. |
| FR-11 | `app-deploy.yml`: on push to `main` touching `app/**` → build once, tag with git SHA, push to dev ECR, register a task definition revision referencing the **image digest**, update the service, wait for stability. |
| FR-12 | `terraform-destroy.yml`: `workflow_dispatch`, input `env`, environment-gated. |
| FR-14 | Branching: trunk-based. Short-lived feature branches → PR → `main`. Merge to `main` deploys dev. A release tag `v*` (or `workflow_dispatch`) promotes the same image digest to prod. No `develop`/`release` branches, no branch-per-env. |
| FR-15 | Release strategy: dev uses ECS `ROLLING` with deployment circuit breaker + auto rollback. Prod (stretch) uses ECS built-in `BLUE_GREEN` (ALB, two target groups, bake time, CloudWatch alarm rollback). `CANARY` is documented in README as the next step once there is real traffic to measure. |
| FR-13 (stretch) | Prod account in AWS Organizations, bootstrapped with `accounts/prod.tfvars`. `envs/prod` added. The prod deploy job copies the **same digest** from dev ECR to prod ECR (or uses ECR cross-account replication), then deploys. Trigger: `workflow_dispatch` or release tag; GitHub environment `prod` requires a reviewer. |

### Non-functional / security

| ID | Requirement |
|---|---|
| NFR-1 | No AWS access keys stored in GitHub. Role ARNs and region go in **GitHub environment variables** (per env), not secrets. |
| NFR-2 | Explicit `permissions:` per workflow and job. `id-token: write` only where a role is assumed. |
| NFR-3 | All third-party actions are pinned to a commit SHA (version in a comment). Tool versions are pinned and binaries are checksum-verified. Look up current versions; do not guess. |
| NFR-4 | `step-security/harden-runner` is the first step of every job (start in `audit` mode). |
| NFR-5 | `.terraform.lock.hcl` committed, with hashes for `linux_amd64` and the dev machine platform. Dependabot enabled for actions, Docker and Terraform. |
| NFR-6 | gitleaks pre-commit + GitHub secret scanning / push protection. |
| NFR-7 | Role `max_session_duration` = 3600 s. CloudTrail (management events) on, plus a metric filter/alarm on `AssumeRoleWithWebIdentity` with an unexpected `sub` (stretch). |
| NFR-8 | Default tags: `Project`, `Env`, `ManagedBy=terraform`. |
| NFR-9 | Claude Code never runs `terraform apply`/`destroy` or `aws secretsmanager put-secret-value` against AWS. It prepares the commands and the user runs them. |

## 8. Implementation plan

### Phase 0 — Scaffold + local env (~30 min)
1. Create the layout, `.gitignore`, `.tflint.hcl`, `.pre-commit-config.yaml` (gitleaks).
2. App: generate the Ship-it Board (§6). Write a Dockerfile (multi-stage, non-root, `GIT_SHA` build arg), `docker-compose.yml` and `.env.example` (`APP_ENV=local`, a fake `APP_API_KEY`, `BREAK=false`). Timebox the app to about 30 minutes.
3. **Checkpoint (user):** `cp app/.env.example app/.env && docker compose -f app/docker-compose.yml up`. Open `/` and check that it shows `local`, the SHA and `secret_loaded: yes`. `/admin` without the key must return 401. With `BREAK=true`, `/health` must return 500.

### Phase 1 — Bootstrap dev account (~45 min)
1. Write `bootstrap/` per FR-2 to FR-5, parameterized by `accounts/<env>.tfvars`. Output the role ARNs and bucket name.
2. fmt / validate / tflint locally.
3. **Checkpoint (user):** `terraform apply -var-file=accounts/dev.tfvars` using SSO credentials, then migrate state into the bucket (key `bootstrap/terraform.tfstate`).
4. **Checkpoint (user):** create GitHub environment `dev` (required reviewer = self), with variables `AWS_REGION`, `AWS_APPLY_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`. Add a repo variable `AWS_PLAN_ROLE_ARN_DEV`.

### Phase 2 — OIDC smoke test (~15 min)
1. `oidc-smoke-test.yml`: assume the plan role, run `aws sts get-caller-identity`.
2. Done when the PR run prints the plan role's assumed-role ARN.

### Phase 3 — Infra pipeline + ECS (~75 min)
1. `modules/app-ecs` per FR-7 and FR-8. `envs/dev` uses it, with a placeholder image (e.g. a public hello image) until Phase 4.
2. `terraform-iac.yml` per FR-9, with NFR-2 to NFR-4.
3. **Checkpoint (user):** PR → read plan comment → merge → approve. Then set the secret value: `aws secretsmanager put-secret-value --secret-id <prefix>/dev/app-api-key --secret-string '<value>'`.
4. Negative tests: the plan role gets AccessDenied on `GetSecretValue`, and the plan role cannot create resources.

### Phase 4 — App pipeline (~60 min)
1. `app-ci.yml` (FR-10) and `app-deploy.yml` (FR-11).
2. **Checkpoint (user):** change `APP_COLOR` or any line of the app in a PR → CI passes → merge → approve → the ALB URL shows the new SHA/color, `APP_ENV=dev` and `secret_loaded: yes`.
3. Confirm the running task definition references an image **digest**, not a tag.

### Phase 5 — Hardening & teardown (~30 min)
1. `terraform-destroy.yml` (FR-12).
2. README: setup, trust conditions explained, cost notes, teardown order, and a "When to move to CodeBuild runners / CodePipeline" section.

### Phase 6 — Supply-chain hardening (~45 min)
1. Pin every action to a SHA and verify tool checksums (NFR-3).
2. Add harden-runner (NFR-4). Review the egress log from one run, then consider `block` mode with an allowlist.
3. Dependabot config, `.terraform.lock.hcl` multi-platform hashes (NFR-5).
4. gitleaks pre-commit + push protection (NFR-6).

### Phase 7 — Stretch: prod account (~90 min)
1. **User:** create AWS Organizations (from a management account with no workloads), create the prod account, and set up IAM Identity Center access.
2. Bootstrap prod with `accounts/prod.tfvars`. Create GitHub environment `prod` (required reviewer) with the prod role ARNs.
3. `envs/prod` (same module, own `tfvars`). Prod deploy job per FR-13.
4. Prod ECS service uses built-in `BLUE_GREEN` (FR-15). Look up the current Terraform `aws_ecs_service` arguments for the deployment strategy; do not guess. Demo: deploy a broken image and watch the alarm trigger an automatic rollback.
5. Negative test: a job in environment `dev` gets AccessDenied when assuming a prod role.

## 9. Cost & cleanup

- ALB and Fargate are billed hourly, so destroy `envs/*` after each session (destroy workflow). No NAT gateway by design.
- S3, Budgets, Organizations and the extra accounts cost close to $0.
- Teardown order: destroy workflow per env → bootstrap per account (empty the bucket first, migrate state back to local).

## 10. Instructions for Claude Code

- Work phase by phase. At every **Checkpoint**, stop, summarize what was created, and list the exact commands for the user.
- Look up current versions and SHAs for: `actions/checkout`, `aws-actions/configure-aws-credentials`, `aws-actions/amazon-ecr-login`, `aws-actions/amazon-ecs-render-task-definition`, `aws-actions/amazon-ecs-deploy-task-definition`, `hashicorp/setup-terraform`, tflint setup, `step-security/harden-runner`, and the image scanner.
- After every change, run `terraform fmt`, `validate` and `tflint`, plus `actionlint` and `hadolint` if available.
- Never write secrets, real `.env` files or state files to git (NFR-9 applies).
- Commit per phase, e.g. `feat(app-ecs): fargate service with secrets manager injection`.
