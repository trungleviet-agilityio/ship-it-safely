# Progress

Phase status for [`PLAN.md`](PLAN.md). Updated after every phase checkpoint. Decisions live in
[`docs/adr/`](docs/adr/); this file only tracks where each phase stands.

Legend: ✅ done · 🟡 partly done · ⏳ next · ⏸ not started

## Summary

| Phase | Status | ADR | PRs | Checkpoint result |
|---|---|---|---|---|
| 0 Scaffold + local env | ✅ | 0001 | #1, #2, #3 | `docker compose up`: `/` shows `local`, the SHA and `secret_loaded: yes`; `/admin` 401; `BREAK=true` gives 500 |
| 1 Bootstrap dev account | ✅ | 0002 | #5, #10, #12 | Bootstrap applied with SSO admin, state in S3 (`bootstrap/terraform.tfstate`); roles, OIDC provider, budget live |
| 2 OIDC smoke test | ✅ | 0003 | #9 | PR run assumed `sis-dev-gha-plan`; N1 (`workflow_dispatch` on main) refused with `AccessDenied`, both seen in CloudTrail |
| 3 Infra pipeline + ECS | ✅ | 0004 | #10, #11, #13 | PR plan comment, approved apply (27 resources), `/health` 200 `ok`; plan role: `explicitDeny` on `GetSecretValue`, `implicitDeny` on creates |
| 4 App pipeline | ✅ | 0005 | #14, #15, #16, #17 | Deploy by digest (`sis-dev-app:5`, then `:6`); checkpoint PR changed the SHA, colour and page; deploy role negative tests pass; stack torn down |
| 5 Hardening & teardown | ✅ | 0006 | #19 | Bootstrap re-applied (deploy role `DescribeSecret` allowed, `GetSecretValue` explicitDeny); stack re-created; N5 deploy refused at Preflight before the secret had a value, then green with `/version` on the `main` SHA by digest; `terraform-destroy` removed 27 resources and deregistered revisions 4, 5, 6, 8 with no account ID in logs; N6 wrong phrase failed with no approval prompt; N7 "nothing to destroy" |
| 6 Supply-chain hardening | ✅ | 0007 | #21 (PR A), #24 (PR B, includes #23) | Checkpoint B passed: the seven credentialed jobs ran in `block` mode with telemetry off and no blocked host: PR plan, guardrails and smoke test; apply 27; deploy pushed to ECR (`/version` on `87cd3c0` by digest); destroy 27 and revision 12 deregistered; no account ID in any log. Dependabot applied the python `ignore` and closed #22. Checkpoint A passed: bootstrap re-applied (12 added, 4 changed); the region pin kept the PR plan assume working; N8 refused the PR token on apply and deploy (`AccessDenied`), N9 refused a 3601 s session; the refused assume reached the inbox as an SNS alert; apply (27), deploy (`/version` on the `main` SHA) and destroy (27, no account ID in the log) ran on the file-pinned trust; `guard (no AWS)` required; push protection on; Dependabot opened #22 (Python 3.15, not merged); `make up` serves all four routes. |
| 7 Prod account, promote and rollback | 🟡 | 0008 | #26 (scripts regroup), #27 (PR A) | Checkpoint A passed on dev: `make new-env` clones an env root, the parity guard keeps roots identical, workflows take the env as an input (reusable plan, composite setup, env-level secrets, fail-closed ALB ingress). On the live stack the #27 apply showed `No changes` (same 27 addresses as Phase 6); deploy green with `/version` on `cc9a4c0`; teardown with input `env=dev` destroyed 27; no account ID in any log. #30 renamed the workflows (ADR 0008 amendment W). PR B (prod account, promote, rollback; `BLUE_GREEN` dropped by amendment S) waits for Q1 (Organizations and the prod account) |
| 8 PR preview environments | ⏸ | | | New in PLAN v3 (deployment path). Needs `/sis-team:plan 8` |

## Live AWS state

| Stack | State | Cost |
|---|---|---|
| Bootstrap (state bucket, OIDC provider, plan/apply/deploy roles, guardrails, ECS boundary, budget) | Live | Close to zero |
| Bootstrap security alert (CloudTrail trail and bucket, EventBridge rule, SNS topic and email) | Live (Phase 6) | Close to zero (first trail, 30-day objects) |
| `envs/dev` (VPC, ALB, ECS, ECR, logs, secret shell, ECS roles) | **Destroyed** (2026-10-27, after Phase 7 checkpoint A, by `terraform-destroy` with `env=dev`) | Hourly when up (ALB + Fargate) |

Re-create order for a session: Run workflow on `terraform-iac` (env `dev`) and approve, set the secret value (one
line, your own terminal), Run workflow on `app-deploy` and approve. The `dev` environment needs the secrets
`AWS_ACCOUNT_ID`, `ALB_INGRESS_CIDRS` (the apply refuses it empty), `AWS_APPLY_ROLE_ARN` and `AWS_DEPLOY_ROLE_ARN`. Tear down at the end of the session.

## Plan alignment (checked 2026-10-26 after Phase 5)

Compared with the original hands-on notes and the blog pattern: OIDC provider and role per account, `sub`-based
trust (plan job without `environment`, apply/deploy with `environment:dev`), split plan/apply roles, required
reviewer, destroy workflow, ECS Fargate instead of EKS, S3 native locking instead of DynamoDB, digest deploys,
Secrets Manager shell plus out-of-band value, trunk-based branching and the CodeBuild/CodePipeline notes are all
in place. Deliberate differences: no throwaway S3-bucket step (Phase 3 went straight to ECS); tools installed as
checksum-verified binaries instead of setup actions. Dependabot, the OIDC alert and harden-runner
`block` on the credentialed jobs are in place since Phase 6; env cloning, the parity guard and env-parametrized
workflows since Phase 7 PR A, with one deliberate difference: env roots may also differ in `versions.tf` and the
lock file, so upgrades reach dev first (ADR 0008 P1). PLAN v3 (2026-10-30) refocuses the remaining work on the
deployment path: prod with promote and rollback, no `BLUE_GREEN` (Phase 7 PR B), then PR previews (Phase 8).
Still to do: the items below and those two.

## Open items carried forward

| Item | From | Target |
|---|---|---|
| Pin `job_workflow_ref` instead of the workflow `name:` in deploy/apply trust (reusable workflows) | ADR 0005 L2 | Built in Phase 6 PR A (ADR 0007 S2); proven live at checkpoint A7 (apply, deploy and destroy) |
| harden-runner insights may show hostnames with the account ID (Q1; ADR 0006 step 10 not run) | ADR 0005 Q1 | Checked at A6: insights need a GitHub login and the plan job lists the state bucket host (holds the account ID). Treated as visible to any GitHub user: PR B turned telemetry off on credentialed jobs (closed at checkpoint B) |
| YAML-parser trigger allowlist (multi-line flow lists, explicit keys) | ADR 0004 L-a | Built in Phase 6 PR A (ADR 0007 S9) |
| ALB ingress from the optional secret `ALB_INGRESS_CIDRS_DEV` (`TF_VAR_alb_ingress_cidrs_json`) | ADR 0004 L4 | Built in Phase 6 PR A (ADR 0007 S10); not set at A7 (default `0.0.0.0/0`, masked notice seen in the destroy log) |
| Deploy preflight: check the secret has an `AWSCURRENT` version (needs `DescribeSecret` in bootstrap) | Phase 4 run 3 | Built in Phase 5 (G14); proven live by N5 at the checkpoint |
| Deregister deploy-registered task definition revisions at teardown | ADR 0005 F23 | Built in Phase 5 (G12, `terraform-destroy`) |
| Make `guard (no AWS)` a required status check in the `main` ruleset | ADR 0004 L-b | Done at checkpoint A8 (read back from the ruleset API) |
| 10 code-simplifier suggestions from Phase 3 (workflow duplication) | ADR 0004 | Fixed in Phases 4 to 6; the composite action for the AWS preamble is deferred to Phase 7 |
| CloudTrail trail plus a metric filter and alarm on `AssumeRoleWithWebIdentity` with an unexpected `sub` (NFR-7 stretch) | ADR 0002 Q2, hands-on notes Phase 6 | Built in Phase 6 PR A (ADR 0007 S8, EventBridge and SNS instead of a metric filter); alerts cover the bootstrap region only |
| Negative test: a PR job cannot assume the apply or deploy role (AccessDenied); demo that credentials expire after 1 hour | Hands-on notes, talk demo | Built in Phase 6 PR A (ADR 0007 S15: N8, N9 in `oidc-smoke-test`) |
| `tf-policy.sh` rule 9 misses unquoted labels, `*.tf.json` and remote module sources | ADR 0006 security re-check | Built in Phase 6 PR A (ADR 0007 S11; rules 9 to 12 plus `tf-resolved-sources.sh`) |
| Destroy summary says "Destroyed" in its heading even when the apply failed | ADR 0006 security re-check | Built in Phase 6 PR A (ADR 0007 S12, `tf-destroy-report.sh`) |
| `terraform-destroy.yml` comment says the typed phrase is never echoed, but GitHub prints the step `env:` block | Phase 5 checkpoint | Built in Phase 6 PR A (ADR 0007 S13) |
| Optional: delete the `INACTIVE` task definitions (`DeleteTaskDefinitions`) so they stop showing in the Tagging API | Phase 5 checkpoint | Dropped (ADR 0007 S14: they cost nothing) |
| harden-runner `block` with an explicit allowlist on the credentialed jobs | ADR 0007 S4, S39 to S47 | Built in PR B (#24), proven at checkpoint B |
| Monthly manual check: `mise.toml` tool versions with `scripts/ci/tools.sha256`, and `scripts/ci/requirements.txt` (not covered by Dependabot) | ADR 0007 B | Ongoing |
| Turn on "require review from code owners" when a second maintainer joins | ADR 0007 Q6 | Later |
| Workflow self-tests on a YAML loader instead of `sed` ranges | ADR 0007 verify | Built in Phase 7 PR A (#27) |
| harden-runner policy: refuse any expression mentioning `secrets` in audit jobs' endpoints, and `env` values built from secrets (N1, Low) | ADR 0007 PR B verify round 2 | Built in Phase 7 PR A (#27): audit endpoints allow only `vars.X` and untainted `env.X` |
| Residual risks: `deploy` keeps Docker (root through the docker group) in block mode; a PR author with push access can change the plan job's egress before review | ADR 0007 PR B verify H1, M1 | Accepted |
| A PR plan against a live stack exercises the extra AWS hosts on `plan` (checkpoint B planned an empty stack) | ADR 0007 hand-back | Closed at Phase 7 checkpoint A: the #27 apply refreshed all 27 live resources in block mode with the same host list as the plan job (`No changes`) |
| harden-runner taint check follows `env` one level and matches `secrets` case-sensitively (N1, Low) | ADR 0008 PR A verify round 2 | When the policy is next touched |
| A self-test that pins the step order in `.github/actions/terraform-setup` (select and CIDR mask before the role) | ADR 0008 PR A verify round 2 | Phase 7 PR B (it edits the composite) |
| A CI guard that no repo-level secret shadows an environment secret name (`AWS_ACCOUNT_ID`, `ALB_INGRESS_CIDRS`, role ARNs) | ADR 0008 PR A verify round 2 (N2) | Checked by hand at each checkpoint; a guard needs `gh` access in CI |
| PAT: environment secrets need "Environments: write"; the checkpoint used the web UI instead (lesson 1) | Phase 7 checkpoint A | Accepted (token stays least privilege) |
| Dependabot `ignore` for Python minor and major base-image bumps (#22 jumped 3.13 to 3.15); close #22 | ADR 0007 checkpoint A10 | Built in PR B (S46); Dependabot logged the ignore and closed #22 |
| Confirm Insights > Dependency graph > Dependabot shows no ecosystem error (Terraform 1.17, R17; pre-commit `# frozen:`, Q4) | ADR 0007 checkpoint A10 | User check, before PR B merges |
| Optional: EventBridge input transformer so the alert email is one readable line instead of raw JSON | ADR 0007 checkpoint A5 | Declined for PR B (user, 2026-10-27); optional later |
| Refused STS probes in other regions are not alerted (the region pin makes them harmless) | ADR 0007 verify M1 | Accepted |
