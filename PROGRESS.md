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
| 6 Supply-chain hardening | 🟡 | | | Done early: SHA pins, checksum-verified tools, harden-runner (audit) in every job, gitleaks pre-commit and push protection, multi-platform lock files. Left: Dependabot (NFR-5), harden-runner `block` with an allowlist, Q1 exposure check |
| 7 Stretch: prod account | ⏸ | | | Needs AWS Organizations and a prod account (user). Deploy scripts are already parameterized by `ENV` |

## Live AWS state

| Stack | State | Cost |
|---|---|---|
| Bootstrap (state bucket, OIDC provider, plan/apply/deploy roles, guardrails, ECS boundary, budget) | Live | Close to zero |
| `envs/dev` (VPC, ALB, ECS, ECR, logs, secret shell, ECS roles) | **Destroyed** (2026-10-26, by `terraform-destroy`) | Hourly when up (ALB + Fargate) |

Re-create order for a session: Run workflow on `terraform-iac` and approve, set the secret value (one line, your
own terminal), Run workflow on `app-deploy` and approve. Tear down at the end of the session.

## Plan alignment (checked 2026-10-26 after Phase 5)

Compared with the original hands-on notes and the blog pattern: OIDC provider and role per account, `sub`-based
trust (plan job without `environment`, apply/deploy with `environment:dev`), split plan/apply roles, required
reviewer, destroy workflow, ECS Fargate instead of EKS, S3 native locking instead of DynamoDB, digest deploys,
Secrets Manager shell plus out-of-band value, trunk-based branching and the CodeBuild/CodePipeline notes are all
in place. Deliberate differences: no throwaway S3-bucket step (Phase 3 went straight to ECS); tools installed as
checksum-verified binaries instead of setup actions. Still to do: the items below plus Dependabot and
harden-runner `block` (Phase 6) and the prod account with `BLUE_GREEN` (Phase 7).

## Open items carried forward

| Item | From | Target |
|---|---|---|
| Pin `job_workflow_ref` instead of the workflow `name:` in deploy/apply trust (reusable workflows) | ADR 0005 L2 | Phase 6 |
| harden-runner insights may show hostnames with the account ID (Q1; ADR 0006 step 10 not run) | ADR 0005 Q1 | Phase 6 check |
| YAML-parser trigger allowlist (multi-line flow lists, explicit keys) | ADR 0004 L-a | Phase 6 (moved by ADR 0006) |
| Wire `TF_VAR_alb_ingress_cidrs` from a secret to narrow the ALB | ADR 0004 L4 | Phase 6 (moved by ADR 0006) |
| Deploy preflight: check the secret has an `AWSCURRENT` version (needs `DescribeSecret` in bootstrap) | Phase 4 run 3 | Built in Phase 5 (G14); proven live by N5 at the checkpoint |
| Deregister deploy-registered task definition revisions at teardown | ADR 0005 F23 | Built in Phase 5 (G12, `terraform-destroy`) |
| Make `guard (no AWS)` a required status check in the `main` ruleset | ADR 0004 L-b | User setting |
| 10 code-simplifier suggestions from Phase 3 (workflow duplication) | ADR 0004 | Fixed in Phases 4 and 5; the composite action for the AWS preamble is deferred to Phase 7 |
| CloudTrail trail plus a metric filter and alarm on `AssumeRoleWithWebIdentity` with an unexpected `sub` (NFR-7 stretch) | ADR 0002 Q2, hands-on notes Phase 6 | Phase 6 (decide trail cost) or Phase 7 |
| Negative test: a PR job cannot assume the apply or deploy role (AccessDenied); demo that credentials expire after 1 hour | Hands-on notes, talk demo | Phase 6 checkpoint |
| `tf-policy.sh` rule 9 misses unquoted labels, `*.tf.json` and remote module sources | ADR 0006 security re-check | Phase 6 |
| Destroy summary says "Destroyed" in its heading even when the apply failed | ADR 0006 security re-check | Phase 6 |
| `terraform-destroy.yml` comment says the typed phrase is never echoed, but GitHub prints the step `env:` block | Phase 5 checkpoint | Phase 6 |
| Optional: delete the `INACTIVE` task definitions (`DeleteTaskDefinitions`) so they stop showing in the Tagging API | Phase 5 checkpoint | Phase 6 (optional) |
