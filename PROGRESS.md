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
| 5 Hardening & teardown | ⏳ | 0006 (planned) | | |
| 6 Supply-chain hardening | 🟡 | | | Done early: SHA pins, checksum-verified tools, harden-runner (audit) in every job, gitleaks pre-commit and push protection, multi-platform lock files. Left: Dependabot (NFR-5), harden-runner `block` with an allowlist, Q1 exposure check |
| 7 Stretch: prod account | ⏸ | | | Needs AWS Organizations and a prod account (user). Deploy scripts are already parameterized by `ENV` |

## Live AWS state

| Stack | State | Cost |
|---|---|---|
| Bootstrap (state bucket, OIDC provider, plan/apply/deploy roles, guardrails, ECS boundary, budget) | Live | Close to zero |
| `envs/dev` (VPC, ALB, ECS, ECR, logs, secret shell, ECS roles) | **Destroyed** (2026-10-26) | Hourly when up (ALB + Fargate) |

Re-create order for a session: Run workflow on `terraform-iac` and approve, set the secret value (one line, your
own terminal), Run workflow on `app-deploy` and approve. Tear down at the end of the session.

## Open items carried forward

| Item | From | Target |
|---|---|---|
| Pin `job_workflow_ref` instead of the workflow `name:` in deploy/apply trust (reusable workflows) | ADR 0005 L2 | Phase 6 |
| harden-runner insights may show hostnames with the account ID (Q1) | ADR 0005 Q1 | Phase 6 check |
| YAML-parser trigger allowlist (multi-line flow lists, explicit keys) | ADR 0004 L-a | Phase 5 or 6 |
| Wire `TF_VAR_alb_ingress_cidrs` from a secret to narrow the ALB | ADR 0004 L4 | Phase 5 |
| Deploy preflight: check the secret has an `AWSCURRENT` version (needs `DescribeSecret` in bootstrap) | Phase 4 run 3 | Phase 5 |
| Deregister deploy-registered task definition revisions at teardown | ADR 0005 F23 | Phase 5 |
| Make `guard (no AWS)` a required status check in the `main` ruleset | ADR 0004 L-b | User setting |
| 10 code-simplifier suggestions from Phase 3 (workflow duplication) | ADR 0004 | Mostly fixed in Phase 4; re-check in Phase 5 |
