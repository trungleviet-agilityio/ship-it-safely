# ADR 0009: Phase 8 PR preview environments on the dev ALB

- Status: accepted (2026-10-30, the user approved Q1 to Q11 with the recommended answers)
- Date: 2026-10-30

## Context

### Goal

FR-17: a pull request from this repository that touches `app/**` gets the image it built running in the dev account. Its own URL is posted as a sticky PR comment, and `/version` shows the PR head SHA. Closing the PR removes what the preview created. The build stays credential-free. The preview job uses the GitHub environment `preview` (required reviewer) and a preview role that can only touch resources tagged `Env=preview`. Fork and Dependabot PRs get no preview.

Fixed by the user and not reopened here:
- The dev ALB is reused, over HTTP, with no domain.
- There is no third-party hosting or tunnel.
- Previews work only while the dev stack is up.
- Display names follow ADR 0008 amendment W: workflow `App Preview` in `app-preview.yml`, short lower-case job names with no expressions.

### Requirements

| ID | What Phase 8 must deliver | State found (branch `docs/working-notes-out-of-repo`, clean) |
|---|---|---|
| FR-17 | Preview per same-repo PR, URL in a sticky comment, `/version` = head SHA, removed on close | Not started. The dev ALB has one listener (port 80) whose default action forwards to `sis-dev-tg`. There are no rules |
| FR-5, FR-11 | Deploy by digest, least privilege, credential-free build | `app-deploy.yml`: `build-scan` (no token) hands an image artifact with sha256 to `deploy` (env `dev`, block mode, Docker exception) |
| FR-8 | The pipeline never reads secret values | The dev exec role may `GetSecretValue` on `sis/dev/app-api-key`. Previews must never get this role |
| FR-12 | Teardown must always work | `terraform-destroy.yml` plans a destroy of `module.app_ecs.` only, then deregisters the `sis-dev-app` family |
| NFR-1 | Account-bearing values are environment secrets | Env `dev`: `AWS_ACCOUNT_ID`, `AWS_DEPLOY_ROLE_ARN`, ... (ADR 0008 P5) |
| NFR-2, NFR-4 | Explicit permissions. harden-runner first; block mode on credentialed jobs | `harden_runner_policy.py` enforces this. `NEEDS_CONTAINERS = (("app-deploy.yml","deploy"),)` |
| NFR-3 | Pins | No new tool or action in this ADR |
| NFR-7 | Session cap; alert on an unexpected OIDC subject | `expected_subs` is built from `local.trust`, so new trusts extend the alert pattern automatically |
| NFR-8 | Tags | CLI-created resources carry `Project`, `Env=preview`, `ManagedBy=app-preview` (precedent: `ManagedBy=app-deploy` on task definitions) |
| NFR-9 | The user runs apply, destroy and secrets | Unchanged. The bootstrap re-apply is a checkpoint step |

### Findings from official docs

1. **ALB quotas.** 50 listeners per ALB. 100 rules per ALB (default rules excluded). 100 target groups per ALB (not adjustable). 3,000 target groups per region. 5 condition values and 5 match evaluations per rule.
2. **ALB rule transforms.**
   - `url-rewrite` rewrites "the path or the query string" with a regex and a replacement. Capture groups (`$1`) are allowed.
   - Only "one host header rewrite transform and one URL rewrite transform per rule". "You can't add a transform to a default rule."
   - "If there is no pattern match, the original request is sent to the target"; "if there is a pattern match but the transform fails, we return an HTTP 500 error."
   - `aws elbv2 create-rule` has `--transforms` (CLI 2.39.2 docs). Rule priority runs from 1 to 50000, and "a listener can't have multiple rules with the same priority". A path pattern is case-sensitive, at most 128 characters, and compared to the path only.
3. **ELB authorization** (service reference JSON):
   - `CreateRule` is authorized on the **listener** resource with `aws:RequestTag`, `aws:ResourceTag` and `aws:TagKeys`. `DeleteRule` and `ModifyRule` are authorized on `listener-rule` with `aws:ResourceTag`.
   - `CreateTargetGroup` is authorized on `targetgroup` with `aws:RequestTag`. `DeleteTargetGroup` and `ModifyTargetGroup` are authorized with `aws:ResourceTag`.
   - `AddTags` carries `elasticloadbalancing:CreateAction`.
   - Describe actions have no resource-level support.
   - Listener ARNs are `listener/app/<lb-name>/<lb-id>/<listener-id>`, so the dev listener and any other listener on the same ALB share the name part. **Only a tag can tell them apart.**
   - ELB tag-on-create: callers "must also have explicit permissions to use the elasticloadbalancing:AddTags action". `CreateAction` scopes it to creation.
4. **ECS authorization** (service reference JSON):
   - `CreateService` on `service` takes `aws:RequestTag` and `ecs:task-definition`. `UpdateService` takes `ecs:task-definition`. `DeleteService` and `DescribeServices` take `aws:ResourceTag` and `ecs:cluster`.
   - `ListServices` has no resource and takes condition `ecs:cluster`.
   - `RegisterTaskDefinition` on `task-definition` takes `aws:RequestTag`, `ecs:task-cpu` and `ecs:task-memory`.
   - **`DeregisterTaskDefinition` has no resource and no condition.**
   - `TagResource` carries `ecs:CreateAction`.
5. **ECS lifecycle.**
   - DeleteCluster: "You can't delete a cluster that contains services" (`ClusterContainsServicesException`), and also not one with active tasks.
   - DeleteService: with `force` "you can delete a service even if it wasn't scaled down to zero tasks". A deleted service moves to `DRAINING` and "is no longer visible in ... ListServices", then to `INACTIVE`.
   - "If you attempt to create a new service with the same name as an existing service in either ACTIVE or DRAINING status, you receive an error."
6. **Execution role.** The AWS trust example is `ecs-tasks.amazonaws.com` with no condition. Fargate uses the execution role for ECR pulls, awslogs and `secrets`.
7. **GitHub `pull_request` event.**
   - The default types are `opened`, `synchronize` and `reopened`. `GITHUB_REF` is `refs/pull/N/merge`.
   - **For a closed PR: "If a pull request was closed but not merged, it will be `refs/pull/PULL_REQUEST_NUMBER/merge`. If a pull request was closed as a result of being merged, it will be the fully qualified ref of the branch it was merged into"** (`refs/heads/main`).
   - "Workflows will not run on `pull_request` activity if the pull request has a merge conflict."
   - Fork PRs: "secrets are not passed" and the token is read-only. "Workflows triggered by Dependabot pull requests are treated as though they are from a forked repository."
8. **`workflow_run`** runs the default-branch file and "is able to access secrets and write tokens, even if the previous workflow was not". "Running untrusted code on the `workflow_run` trigger may lead to security vulnerabilities." zizmor's `dangerous-triggers` audit flags it, and adds that "a `workflow_run` always runs in the context of the target repository".
9. **Environments.**
   - Up to six required reviewers. Self-review prevention is optional.
   - "A job cannot access environment secrets until one of the required reviewers approves it."
   - Branch rules match `GITHUB_REF`, and "adding another branch rule for `refs/pull/*/merge` would also allow workflows triggered by `pull_request` events" to deploy. "Wildcard characters will not match `/`."
   - On GitHub Free, environment secrets exist only on public repos.
10. **OIDC.**
    - `sub` is `repo:O/R:environment:<name>` when the job references an environment.
    - IAM supports `actor`, `actor_id`, `job_workflow_ref`, `repository`, `repository_id`, `repository_owner_id`, `workflow`, `ref`, `environment` and `enterprise_id`. There is **no `event_name`** (lesson 11).
    - `job_workflow_ref` is documented only "for jobs using a reusable workflow". ADR 0007 A0 proved the claim on `main` for top-level files. Its value for a `pull_request` run is not documented (R35).
11. **Concurrency.** "At most one job or workflow run can be pending". A newer pending run cancels the older pending one. The docs say nothing about jobs that wait for an environment approval.
12. **Cost.**
    - Public IPv4: 0.005 USD per hour.
    - Fargate Linux x86, us-east-1: 0.000011244 USD per vCPU-second and 0.000001235 USD per GB-second. The page does not list ap-southeast-1.
13. **Provider v6.70.0 `aws_lb_listener`** supports a `fixed-response` default action and `tags`; "tags with matching keys will overwrite those defined at the provider-level".

### Repo facts that shape the design

- `scripts/ecs/render-task-def.sh` copies the latest **dev** revision and requires the `APP_API_KEY` secret, the dev exec role and the dev task role. Previews need their own renderer.
- The dev exec role can read the dev secret. A preview able to pass that role could register a task definition with `secrets` pointing at the dev secret, and its own container would receive the value. The preview role must never pass any dev role.
- The dev ECR lifecycle keeps the last 10 images of **any** tag. Preview pushes there would evict `main` images that promote and rollback rely on (ADR 0008 S2).
- The apply role can already delete `sis-dev-*` target groups, rules and any service in `sis-dev-cluster`. It cannot list services.
- Trust policies have one statement per role (`oidc.tf`). `workflow_files` is the pinned-file contract, and `selftest/workflows.sh` checks that each listed file exists.
- The trigger allowlist is `pull_request`, `push`, `workflow_dispatch`, plus `workflow_call` only in `reusable-*.yml`.
- Comment jobs check out `base.sha` scripts only. A PR that introduces the script a comment job calls fails its own comment with exit 127 (lesson 44).

## Decision

### A. Decisions

| # | Decision | Alternatives | Pro | Con |
|---|---|---|---|---|
| V1 | **Routing: a dedicated preview listener** on the dev ALB, port `8000`, created by Terraform, tagged `Env=preview`, default action `fixed-response 404`. **One rule per PR** on that listener: priority `<n>` (the PR number), condition `path-pattern /pr-<n>/*`, action forward to the PR target group, transform `url-rewrite ^/pr-<n>/(.*)$` to `/$1`. URL: `http://<dev ALB DNS>:8000/pr-<n>/` | (a) Path rules on the dev port 80 listener. (b) One listener per PR on a port range. (c) Host-header rules (needs DNS). (d) Path rules plus a `BASE_PATH` in the app | The preview role never touches the dev listener: `CreateRule` is tag-scoped to the preview listener (Finding 3), and the dev ALB ARN cannot express that. No app change. One SG ingress port. Priority = PR number is unique and idempotent. Up to 100 rules per ALB (Finding 1) is far above the cap | A non-standard port; some networks block 8000. Depends on ALB transforms, a newer feature (R36). `/pr-<n>` without the slash gets the listener's 404. (a) would let an approved PR shadow dev traffic with a priority 1 `/*` rule. (b) needs `CreateListener` on the dev ALB (Env=dev, so not tag-scopable) and an SG port range. (c) has no domain. (d) is an app change for an infra concern |
| V2 | **Per-PR resources are created by tested AWS CLI scripts** (`scripts/preview/*.sh`), idempotent by deterministic names and tags. Terraform owns only the shared preview infrastructure in `modules/app-ecs` behind `preview_enabled`: the listener, the SG rules, the preview task SG, the ECR repo `sis-dev-preview` and the log group `/ecs/sis-dev-preview` | (t1) Terraform with a per-PR state key. (t2) `for_each` over open PRs in `envs/dev` | Fast, no state access for a PR-controlled job, offline self-tests with PATH stubs (existing pattern). The dev stack plan shows no drift: listener rules are separate resources and are not managed by `aws_lb_listener` | Imperative code to maintain (about 300 lines plus tests). (t1) needs state write for the preview role, provider downloads and orphaned state keys. (t2) needs the apply role and an approval on every PR |
| V3 | **Four garbage-collection layers:** (1) `closed` runs `down.sh <n>`; (2) every approved deploy sweeps previews of PRs that are no longer open before its cap check; (3) a `workflow_dispatch` sweep on `main`; (4) the dev teardown sweeps everything first (V4) | Only (1) | Covers a merge-conflict close (Finding 7, R38), a failed cleanup, an approval given after close (R39) and a dev teardown | More moving parts; each one is tested |
| V4 | **`terraform-destroy` runs `scripts/preview/sweep.sh --all --no-images` with the apply role before the destroy plan**, waits for the deleted services to be `INACTIVE`, and afterwards deregisters the `sis-<env>-preview` family as well as `sis-<env>-app`. The apply role gains only `ecs:ListServices` (condition `ecs:cluster`) | Let Terraform fail and clean up by hand. A separate job with the cleanup role | Teardown never meets `ClusterContainsServicesException` or ENIs in the SGs (Finding 5). It fails closed: a sweep error stops the job before any delete. Prod is a no-op | One more apply-role action. The sweep runs before the destroy plan is reviewed by the guard; previews are disposable (accepted) |
| V5 | **Preview role `sis-dev-gha-preview`**, trusted only from env `preview` on PR refs (E). It creates, updates and deletes only `Env=preview` resources with `sis-dev-preview-*` names | Reuse the deploy role. One role for deploy and cleanup | Smallest set of rights for PR code that runs after a human approval | A new role and environment |
| V6 | **A separate cleanup role `sis-dev-gha-preview-cleanup` in env `preview-cleanup` with no reviewer.** Delete and describe only, on the same names and tags. No create, no update, no PassRole, no deregister | (a) Cleanup in env `preview` with approval. (b) Cleanup with the preview role and no environment | A close always cleans up, with no human in the loop, so cost stays bounded. An unreviewed token can at most delete previews | Unreviewed PR code (unmerged close) gets a delete-only token (R33). (a) leaves a running task whenever nobody approves. (b) changes `sub` to `pull_request`, which the plan role owns |
| V7 | **A fence policy `sis-dev-gha-preview-fence`** (managed, attached to both preview roles) with explicit denies (F.4), plus the shared guardrails G1 to G6 | Rely on implicit deny | Survives a future Allow edit. Gives N11 to N15 an explicit reason | One more policy and its tests |
| V8 | **Preview execution role `sis-dev-preview-exec`, created by bootstrap**, with the ECS boundary. It may pull from `sis-dev-preview` and write logs to `/ecs/sis-dev-preview` only, with an explicit deny on Secrets Manager and SSM. **No task role.** The preview role may pass only this role | Pass the dev exec role. Create it in the module | The dev secret is out of reach even with a hostile task definition. The role exists without the dev stack, and the apply role cannot edit it (G4 extended) | A bootstrap re-apply |
| V9 | **No app secret in previews**: no `secrets` in the task definition, so `secret_loaded: no` and `/admin` always returns 401 | A preview secret shell. Reuse the dev secret | A preview runs PR code, so any value given to it is readable by the PR author, and a preview secret would be public in effect. Reusing dev's is ruled out (FR-8) | `/admin` cannot be demoed on a preview |
| V10 | **Cap of 3 concurrent previews** (`PREVIEW_MAX=3` in `lib.sh`). The preflight counts `ACTIVE` `sis-dev-preview-*` services after the sweep. At the cap, the deploy job fails before creating anything, and the comment says so and lists the open preview PRs | 2 or 5. A hard cap in IAM | About 0.06 USD per hour at the cap. Clear failure | The PR-controlled script enforces the cap, so it is soft against a hostile approved PR (R34). IAM cannot count |
| V11 | **Images go to a separate repo `sis-dev-preview`** (IMMUTABLE, scan on push, `force_delete`, keep the last 20), with tag `pr-<n>-<sha>` and a task definition by digest. `down.sh` deletes the PR's tags | The dev repo with a `pr-` tag prefix | A PR image can never be promoted (promote reads `sis-dev-app`), and preview pushes never evict `main` images | One more repository |
| V12 | **The build runs in a credential-free job** that checks out `pull_request.head.sha`, builds, tests, smoke-tests and scans with `scripts/image/verify.sh`, and uploads `preview-image` (1 day) plus its sha256. `GIT_SHA` = head SHA | Build the merge commit | `/version` names the exact commit whose content is running | Rebuilds what `App CI` also built (runner minutes only) |
| V13 | **Triggers: `pull_request`** on `main` with types `[opened, synchronize, reopened, closed]` and path filters, plus **`workflow_dispatch`** (sweep, `main` only). No trigger-policy change | `workflow_run` after `App CI` (Alternatives) | Uses only allowed triggers. No dangerous-trigger exception | The deploy job's steps come from the PR, so the approval is the gate (R32) |
| V14 | **Concurrency group `app-preview-pr-<n>`, `cancel-in-progress: false`**, shared by `deploy` and `cleanup`. The build has its own group with cancel-in-progress. `deploy` re-checks with the GitHub API that the PR is still open before it assumes the role | Global group | One writer per PR. A pending deploy is replaced by a newer push or by a close | The interaction between approval waits and concurrency is not documented (R39); the open check and the sweep cover it |
| V15 | **The sticky comment is posted by a separate job** (`pull-requests: write`, no AWS). It checks out `base.sha` scripts and calls a shared `scripts/gh/sticky-comment.sh` (marker, bot-only update, account-ID check). The script lands in PR A, so PR B's comment works on its own run | Post from the deploy job | Never mixes a write token with AWS credentials. Removes the duplicated plan-comment code | The comment job's `run:` text still comes from the PR (accepted residual, as for the plan comment) |
| V16 | **Every job of `app-preview.yml` that runs on `pull_request`** carries `head.repo.full_name == github.repository && user.login != 'dependabot[bot]'` | Rely on missing secrets | Forks and Dependabot raise no approval prompt and no red runs | A self-test pins the condition |
| V17 | **harden-runner:** block mode on `deploy`, `cleanup` and `sweep`. `deploy` is added to `NEEDS_CONTAINERS` (Docker load and push, like app-deploy). `cleanup` and `sweep` disable sudo and containers | crane push without Docker | Reuses the proven push path | PR code with Docker in a credentialed job (R42). Revisit when crane lands (ADR 0008 PR B) |
| V18 | **Environment branch rules:** `preview` allows `refs/pull/*/merge` only. `preview-cleanup` allows `main` and `refs/pull/*/merge`. Prevent self-review is off (sole maintainer) | No branch rules | GitHub refuses the environment for any other ref, before IAM does | Set by hand in the web UI |
| V19 | **The preview roles never deregister task definitions.** Revisions of family `sis-dev-preview` stay `ACTIVE` (no cost) until the dev teardown deregisters them with the apply role | Grant `ecs:DeregisterTaskDefinition` on `*` | `DeregisterTaskDefinition` has no resource scope (Finding 4), so granting it would let an unreviewed cleanup token deregister dev revisions | After a close, one revision per deploy remains until teardown (R41) |
| V20 | **Negative tests N11 to N17** (section K) | Fewer | Proves the fence live on every deploy, without alert emails (only `AssumeRoleWithWebIdentity` refusals send alerts) | More calls per deploy |
| V21 | **Two PRs:** A = shared preview infrastructure in the module, plus `sticky-comment.sh`. B = bootstrap, workflow, scripts, teardown sweep and tests | One PR | A is small, needs no bootstrap re-apply and is provable on dev | B is large: the trust names the file it adds (`workflow_files`), so they ship together |

### B. URL and routing (V1)

| Item | Value |
|---|---|
| Listener | `aws_lb_listener.preview`, port `var.preview_listener_port` (8000), HTTP, tags `{ Name = "sis-dev-preview", Env = "preview" }`. Default action `fixed-response`, 404, `text/plain`, "No preview at this path" |
| Ingress | `aws_vpc_security_group_ingress_rule.alb_preview`, indexed over `alb_ingress_cidrs` like port 80 (same masking rules, ADR 0007 S35) |
| Rule | Priority `<n>` (refused above 50000). Condition `path-pattern ["/pr-<n>/*"]`. Forward to `sis-dev-preview-<n>`. Transform `[{"Type":"url-rewrite","UrlRewriteConfig":{"Rewrites":[{"Regex":"^/pr-<n>/(.*)$","Replace":"/$1"}]}}]`. Tags `Project`, `Env=preview`, `ManagedBy=app-preview`, `PreviewPr=<n>` |
| Target group | `sis-dev-preview-<n>`, ip, HTTP 8080, VPC of the ALB. Health check `/health`, 200, interval 15, healthy 2, unhealthy 3. `deregistration_delay.timeout_seconds = 5`. Same tags |
| Health check | Goes straight to the targets, so no rewrite is involved |

### C. Resources and lifecycle

| Resource | Name | Owner | Created by | Removed by |
|---|---|---|---|---|
| Preview listener, SG ingress on 8000, preview task SG `sis-dev-preview-task` (ingress 8080 from the ALB SG, egress 443), ALB SG egress to it, ECR `sis-dev-preview` and lifecycle, log group `/ecs/sis-dev-preview` (1 day) | as named | Terraform (module, `preview_enabled`) | dev apply | dev destroy |
| Exec role `sis-dev-preview-exec` | as named | bootstrap | admin | never (bootstrap) |
| Image `pr-<n>-<sha>` | in `sis-dev-preview` | preview role | `deploy` | `down.sh` (tag prefix `pr-<n>-`), lifecycle, repo `force_delete` |
| Task definition revision | `sis-dev-preview:<rev>`, tags incl. `PreviewPr`, `GitSha` | preview role | `deploy` | teardown deregistration (V19) |
| Target group, rule, service `sis-dev-preview-<n>` | as named | preview role | `up.sh` | `down.sh`, `sweep.sh` |

`up.sh <n> <td-arn>`, idempotent:
1. Find the ALB `sis-dev-alb` (VPC, subnets, DNS) and the listener on 8000. Check that the listener carries `Env=preview`.
2. Find or create the target group, then set its attributes.
3. Find the rule by priority `<n>`. If one exists, its `PreviewPr` tag must be `<n>`; otherwise refuse.
4. Service state:
   - `ACTIVE`: `update-service`.
   - `DRAINING`: wait for `INACTIVE`, then create.
   - `MISSING` or `INACTIVE`: `create-service` with launch type FARGATE, desired 1, the preview SG, the ALB subnets, public IP, circuit breaker with rollback, grace 30 s and tags.
5. Print `PREVIEW_URL=http://<dns>:8000/pr-<n>/`.

`down.sh <n> [--no-images]`, idempotent (missing is fine): delete the rule, then `delete-service --force`, then wait for `INACTIVE`, then delete the target group, then delete images with the tag prefix.

`sweep.sh --keep "<numbers>" | --all [--no-images]`:
- Collect PR numbers from `ListServices` names, from `DescribeServices` on the target group names (catches `DRAINING`), and from `Env=preview` rules on the preview listener.
- Act only on names matching `^sis-<env>-preview-[1-9][0-9]{0,4}$`.
- Run `down.sh` for each number not kept.

### D. Teardown interaction (V4)

`terraform-destroy.yml` job `destroy`, after the setup step:
1. **Remove previews:** `scripts/preview/sweep.sh --all --no-images`. This uses the apply role, which already has `DeleteService`, `DeleteRule`, `DeleteTargetGroup` and `Describe*` on `sis-dev-*`, plus the new `ListServices`.
2. The destroy plan, guard and apply run as today. Terraform deletes the listener, SGs, repo (with images) and log group.
3. `deregister-revisions.sh` takes the families `sis-<env>-app` and `sis-<env>-preview`. The preview family is deregistered only when no `sis-<env>-preview-*` service is `ACTIVE` or `DRAINING`.

If dev is destroyed while PRs are open, the previews are gone. After dev is re-created, push a commit or re-run the PR's `deploy` job.

### E. Roles and trust

All trusts keep `aud = sts.amazonaws.com`, `repository_id`, `repository_owner_id` and `aws:RequestedRegion` (StringEquals). `oidc.tf` gains one statement per **leg**. Plan, apply and deploy keep one leg each, and their JSON must stay byte-identical (a test checks it).

| Role | `sub` (StringEquals) | Leg | `ref` | `job_workflow_ref` |
|---|---|---|---|---|
| `sis-dev-gha-preview` | `<P>:environment:preview` | PR | StringLike `refs/pull/*/merge` | StringLike `O/R/.github/workflows/app-preview.yml@refs/pull/*/merge` |
| `sis-dev-gha-preview-cleanup` | `<P>:environment:preview-cleanup` | PR (unmerged close) | StringLike `refs/pull/*/merge` | StringLike `.../app-preview.yml@refs/pull/*/merge` |
| same | same | main (merged close, dispatch sweep) | StringEquals `refs/heads/main` | StringEquals `.../app-preview.yml@refs/heads/main` |

`<P>` is the immutable prefix (`gh_sub_prefix`). The only wildcard is the PR number position.

Key risk, stated plainly: on `pull_request` the workflow file and scripts come from the PR merge ref. `job_workflow_ref` therefore pins the file **path**, not its content. The human gate is the `preview` approval, and the approver must read the PR's `.github/**` and `scripts/**` changes before approving.

Bootstrap changes (PR B):
- `variables.tf`: `preview_enabled` (bool, default false). `accounts/dev.tfvars.example` sets it to true.
- `locals.tf`:
  - `workflow_files.preview = ["app-preview.yml"]` (when enabled).
  - `trust` entries become `{ sub, legs = [{ ref, ref_test, workflows, workflows_test }] }`.
  - `resource_names` gains `preview_family`, `preview_repository`, `preview_log_group`, `preview_exec_role`, `preview_name_prefix = "sis-dev-preview-"`, `preview_task_sg` and `preview_listener_port`.
  - `role_names` gains `preview` and `preview_cleanup`.
- `iam_preview.tf` (new): the two roles (3600 s), their inline policies, the fence policy, and the exec role with boundary and inline policy.
- `iam_apply.tf`: `EcsListServicesInCluster`.
- `iam_guardrails.tf`:
  - The guardrails attachment map adds both preview roles.
  - G4 resources add `role/sis-dev-preview-exec`. The fence name already matches `policy/sis-dev-gha-*`.
- `outputs.tf`: `preview_role_arn`, `preview_cleanup_role_arn`.
- `monitoring.tf`: no edit. `expected_subs` picks up both new subs.

### F. Least privilege

Region and account are omitted below. `<C>` = `sis-dev-cluster`, `<A>` = `sis-dev-alb`.

**F.1 `sis-dev-gha-preview`**

| Sid | Actions | Resource | Conditions | `*` justification |
|---|---|---|---|---|
| EcrAuth | `ecr:GetAuthorizationToken` | `*` | none | No resource-level support |
| EcrPushPreviewRepo | BatchCheckLayerAvailability, InitiateLayerUpload, UploadLayerPart, CompleteLayerUpload, PutImage, BatchGetImage, DescribeImages, ListImages, BatchDeleteImage | `repository/sis-dev-preview` | none | |
| RegisterPreviewTaskDef | `ecs:RegisterTaskDefinition` | `task-definition/sis-dev-preview:*` | `aws:RequestTag/Env = preview`, `aws:RequestTag/Project = ship-it-safely`, `ecs:task-cpu <= 256`, `ecs:task-memory <= 512` | |
| EcsTagOnCreate | `ecs:TagResource` | `task-definition/sis-dev-preview:*`, `service/<C>/sis-dev-preview-*` | `ecs:CreateAction` in [RegisterTaskDefinition, CreateService] | |
| CreatePreviewService | `ecs:CreateService` | `service/<C>/sis-dev-preview-*` | RequestTag Env and Project; ArnLike `ecs:task-definition = task-definition/sis-dev-preview:*` | |
| UpdatePreviewService | `ecs:UpdateService` | same | ArnLike `ecs:task-definition` as above | |
| ReadPreviewServices | `ecs:DescribeServices` | same | none | |
| DeletePreviewService | `ecs:DeleteService` | same | `aws:ResourceTag/Env = preview` | |
| ListServicesInCluster | `ecs:ListServices` | `*` | ArnEquals `ecs:cluster = cluster/<C>` | No resource (Finding 4); condition-scoped |
| ElbRead | `elasticloadbalancing:Describe*` | `*` | none | No resource-level support |
| CreatePreviewTargetGroup | `CreateTargetGroup` | `targetgroup/sis-dev-preview-*/*` | RequestTag Env and Project | |
| ManagePreviewTargetGroup | `ModifyTargetGroup`, `ModifyTargetGroupAttributes`, `DeleteTargetGroup` | same | `aws:ResourceTag/Env = preview` | |
| CreateRuleOnPreviewListener | `CreateRule` | `listener/app/<A>/*/*` | `aws:ResourceTag/Env = preview` (the listener), RequestTag Env and Project | ID wildcards only; the tag selects the listener |
| ManagePreviewRule | `ModifyRule`, `DeleteRule` | `listener-rule/app/<A>/*/*/*` | `aws:ResourceTag/Env = preview` | as above |
| ElbTagOnCreate | `AddTags` | `targetgroup/sis-dev-preview-*/*`, `listener-rule/app/<A>/*/*/*` | `elasticloadbalancing:CreateAction` in [CreateTargetGroup, CreateRule]; `aws:RequestTag/Env = preview` | |
| Ec2FindPreviewSg | `ec2:DescribeSecurityGroups` | `*` | none | No resource-level support (subset of the approved `ec2:Describe*`) |
| PassPreviewExecRole | `iam:PassRole` | `role/sis-dev-preview-exec` | `iam:PassedToService = ecs-tasks.amazonaws.com` | |

**`iam:PassRole` (highest risk)** reaches one role. That role cannot read any secret or SSM parameter, cannot pull from `sis-dev-app` and writes only to the preview log group. No task role is passed. **Tag escalation is closed:** `AddTags` and `ecs:TagResource` work only on create, so the role can never relabel a dev resource as `Env=preview`.

**F.2 `sis-dev-gha-preview-cleanup`**
- `ElbRead`, `ListServicesInCluster`, `ReadPreviewServices`, `DeletePreviewService`, `ManagePreviewRule` (DeleteRule only), `ManagePreviewTargetGroup` (DeleteTargetGroup only).
- `ecr:ListImages` and `ecr:BatchDeleteImage` on `repository/sis-dev-preview`.
- Nothing else: no create, update, register, tag or PassRole.

**F.3 `sis-dev-preview-exec`** (boundary `sis-dev-ecs-boundary`; trust `ecs-tasks.amazonaws.com`, as AWS documents and as the dev exec role has)
- Allow `ecr:GetAuthorizationToken` on `*` (no resource-level support).
- Allow ECR pull (`BatchCheckLayerAvailability`, `GetDownloadUrlForLayer`, `BatchGetImage`) on `repository/sis-dev-preview`.
- Allow `logs:CreateLogStream` and `logs:PutLogEvents` on `log-group:/ecs/sis-dev-preview:*`.
- Deny `secretsmanager:*`, `ssm:*` and `kms:Decrypt` on `*`.

**F.4 Fence `sis-dev-gha-preview-fence`** (Deny; action wildcards only here)

| Sid | Deny | Resource | Condition |
|---|---|---|---|
| FenceDevService | `ecs:*` | `service/<C>/sis-dev-app`, `task-definition/sis-dev-app:*` | none |
| FenceDevRepo | `ecr:*` | `repository/sis-dev-app` | none |
| FenceSecrets | `secretsmanager:*` | `*` | none (no metadata either) |
| FenceIamWrites | `iam:Create*`, `Put*`, `Update*`, `Delete*`, `Attach*`, `Detach*`, `Add*`, `Remove*`, `Tag*`, `Untag*`, `*PermissionsBoundary`, `*PolicyVersion`, `Set*`, `Upload*` | `*` | none |
| FenceNonPreviewElb | `CreateListener`, `ModifyListener`, `DeleteListener`, `CreateRule`, `ModifyRule`, `DeleteRule`, `SetRulePriorities`, `ModifyTargetGroup`, `ModifyTargetGroupAttributes`, `DeleteTargetGroup`, `RegisterTargets`, `DeregisterTargets`, `DeleteLoadBalancer`, `ModifyLoadBalancerAttributes`, `SetSecurityGroups`, `SetSubnets`, `RemoveTags` | `*` | `StringNotEquals aws:ResourceTag/Env = preview` (a missing tag also denies). Create-only actions are not listed, because they have no resource tag yet |

**F.5 Apply role delta:** `EcsListServicesInCluster` (`ecs:ListServices`, `*`, ArnEquals `ecs:cluster`). Nothing else.

**Standards amendments** (orchestrator): add `ecs:ListServices` (with `ecs:cluster`) to the approved `*` list. The trust rule now allows StringLike `ref` and `job_workflow_ref` on the preview legs, wildcard on the PR number only.

### G. App secret (V9)

None. The preview task definition has no `secrets`, and the preview exec role denies Secrets Manager. The dev secret and its ARN never appear in the preview path. Nothing is added to Terraform state.

### H. Cap and cost (V10)

| Item | Value |
|---|---|
| Per preview | 0.25 vCPU, 0.5 GB, 1 task, one public IPv4. At us-east-1 rates about 0.0124 USD per hour Fargate plus 0.005 USD IPv4, so about 0.02 USD per hour. ap-southeast-1 is somewhat higher (not on the page, not checked) |
| Cap | 3, so about 0.06 USD per hour at the cap. The ALB, rules and target groups add nothing measurable |
| Timeouts | build 15 min, deploy 30 min (rollout wait 1200 s), cleanup 10, sweep 15, comment 5. All are under the 60-minute session |
| At the cap | The deploy fails before any create, and the comment lists the open previews. Close one, then "Re-run failed jobs" |
| Backstops | Teardown after each session (V4); the 20 USD budget alert at 80% |

### I. Image (V11, V12)

- `build-scan` uploads `preview-image` and outputs `image-sha256`.
- `deploy` downloads it and runs `scripts/image/import.sh` (sha256 from the job output), then `scripts/image/ecr-push.sh sis-dev-preview pr-<n>-<sha> <image>`. A re-run reuses the tag.
- `scripts/preview/render-task-def.sh --env dev --pr <n> <image@digest> <sha>` builds the task definition **from a template**, offline:
  - family `sis-dev-preview`, FARGATE, awsvpc, cpu 256, memory 512, LINUX/X86_64;
  - exec role ARN built from `ACCOUNT` (never printed); no task role;
  - volume `tmp`; container `app` with user `10001:10001`, read-only root, port 8080, `/tmp` mount, `environment [{APP_ENV: preview}]`, no `secrets`;
  - awslogs `/ecs/sis-dev-preview`, prefix `pr-<n>`;
  - tags `Project`, `Env=preview`, `ManagedBy=app-preview`, `PreviewPr`, `GitSha`.
- The image must match `^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/sis-dev-preview@sha256:[0-9a-f]{64}$`.

### J. Workflow `.github/workflows/app-preview.yml`

- `name: App Preview`. `run-name`: `Sweep previews by <actor>` on dispatch, else `Preview PR #<n> (<action>) by <actor>`.
- `permissions: {}`. `env: ENV: dev`.
- `on.pull_request`: `branches: [main]`, `types: [opened, synchronize, reopened, closed]`. Paths: `app/**`, `.github/workflows/app-preview.yml`, `scripts/preview/**`, `scripts/image/*.sh`, `scripts/lib.sh`, `scripts/names.sh`, `scripts/aws/check-config.sh`, `scripts/ecs/wait-deployment.sh`, `scripts/ci/install-tools.sh`, `scripts/ci/tools.sha256`, `mise.toml`.
- `on.workflow_dispatch`: no inputs.

| Job id | `name:` | `if` (plus the fork and Dependabot condition on every PR job) | Env | Permissions | harden-runner |
|---|---|---|---|---|---|
| `build-scan` | `build, scan` | PR event, action != closed | none | contents: read | audit |
| `deploy` | `deploy (preview)` | needs build-scan; action != closed | `preview` | contents: read, id-token: write, pull-requests: read | block, telemetry off, containers allowed (V17) |
| `cleanup` | `cleanup (preview)` | action == closed | `preview-cleanup` | contents: read, id-token: write | block, telemetry off, sudo and containers off |
| `comment` | `sticky comment` | `always()`, and deploy or cleanup did not skip | none | contents: read, pull-requests: write | audit |
| `sweep` | `sweep (preview)` | `workflow_dispatch` and `github.ref == 'refs/heads/main'` | `preview-cleanup` | contents: read, id-token: write, pull-requests: read | block, sudo and containers off |

**`deploy` steps:**
1. harden-runner, checkout.
2. Check that the PR is open (`gh api repos/$REPO/pulls/$PR --jq .state`, inputs via `env:`).
3. Download the artifact, import with sha256 check.
4. `check-config.sh sis-dev-gha-preview`.
5. Assume the role: session `gha-preview-<run_id>-<attempt>`, `mask-aws-account-id: true`.
6. N11 to N15 (`scripts/preview/assert-isolation.sh`).
7. Sweep closed PRs (`sweep.sh --keep "$(gh pr list --state open --limit 100 --json number --jq '.[].number')"`).
8. Preflight: listener present, cap.
9. Push, render, register, `up.sh`, `wait-deployment.sh`.
10. Outputs `url`, `digest`. Summary through `assert-no-account-id.sh`. Remove temp files.

**`cleanup` steps:** `down.sh <n>`, then summary.

**`sweep` steps:** the sweep, then N16.

**`comment` steps:** checkout `base.sha` with sparse `scripts`, then `scripts/gh/sticky-comment.sh` with marker `<!-- app-preview:pr -->`. The body holds the URL, the head SHA, the digest, the result and the run link, or "Preview removed" on close. Every value reaches the step through `env:`.

**Concurrency:** `deploy` and `cleanup` use `app-preview-pr-${{ github.event.pull_request.number }}`, cancel false. `build-scan` uses `app-preview-build-<n>`, cancel true. `sweep` uses `app-preview-sweep`.

**Allowlists** (only `vars.AWS_REGION`, `secrets.AWS_ACCOUNT_ID`, `env.ENV` expressions):
- `deploy`: `github.com`, `api.github.com`, `sts.<r>`, `api.ecr.<r>`, `<acct>.dkr.ecr.<r>`, `prod-<r>-starport-layer-bucket.s3.<r>`, `ecs.<r>`, `elasticloadbalancing.<r>`, `ec2.<r>`, `secretsmanager.<r>` (N12), `iam.amazonaws.com` (N15). All on port 443.
- `cleanup`: `github.com`, `sts`, `ecs`, `elasticloadbalancing`, `api.ecr`.
- `sweep`: those of `cleanup` plus `api.github.com`.

**Policy and self-test changes:**
- `NEEDS_CONTAINERS` adds `("app-preview.yml","deploy")`.
- Self-tests:
  - every `app-preview.yml` job on `pull_request` has the fork/Dependabot condition;
  - `deploy` and `cleanup` share the concurrency group;
  - `comment` checks out `base.sha`;
  - no job holds both `id-token: write` and `pull-requests: write`;
  - `workflow_files` lists `app-preview.yml`.

### K. Negative tests

| N | Where | Call | Pass when |
|---|---|---|---|
| N1 (ext) | `oidc-smoke-test` dispatch | `assert-web-identity-denied.sh plan apply deploy preview preview-cleanup` | AccessDenied from all five |
| N8 (ext) | `oidc-smoke-test` PR | PR token (sub `pull_request`) against `apply deploy preview preview-cleanup` | AccessDenied |
| N11 | `deploy` (preview role) | `ecs update-service --cluster sis-dev-cluster --service sis-dev-app --task-definition sis-dev-preview:999999` | AccessDenied (fence). Any other error fails without side effect |
| N12 | `deploy` | `secretsmanager get-secret-value` and `describe-secret` on `sis/dev/app-api-key` (`--query Name`) | AccessDeniedException |
| N13 | `deploy` | `ecr describe-images --repository-name sis-dev-app` | AccessDenied |
| N14 | `deploy` | `elbv2 create-rule` on the dev port 80 listener, priority 50000, path `/n14-never-routed`, fixed 404, tag `Env=preview` | AccessDenied. If it ever succeeds, the script deletes the rule and fails |
| N15 | `deploy` | `iam tag-role --role-name sis-dev-preview-exec --tags Key=N15,Value=probe` | AccessDenied |
| N16 | `sweep` (env `preview-cleanup` token) | `assert-web-identity-denied.sh preview` | AccessDenied; one alert email per dispatch |
| N17 | static plus live | The self-test above; a fork PR or a Dependabot Docker PR touching `app/Dockerfile` | App Preview jobs skipped, no approval request |

`web_identity_call` accepts `preview` and `preview-cleanup`. They map to `sis-${ENV}-gha-preview` and `sis-${ENV}-gha-preview-cleanup`.

### L. Secrets and state

| Name | Level | Used by |
|---|---|---|
| `AWS_ACCOUNT_ID`, `AWS_PREVIEW_ROLE_ARN` | env `preview` | `deploy` |
| `AWS_ACCOUNT_ID`, `AWS_PREVIEW_CLEANUP_ROLE_ARN` | env `preview-cleanup` | `cleanup`, `sweep` |

- No repo-level secret with these names (ADR 0008 N2).
- Kept out of Terraform state: every per-PR resource (CLI-managed), any app secret value (none exists), ECR tokens (temp `DOCKER_CONFIG`).
- In state as today: role ARNs and account IDs inside ARNs.

### M. PR split (V21)

- **PR A, `infra(app-ecs): shared preview listener, repository and log group`:**
  - `modules/app-ecs/preview.tf`, its variables, outputs, tests and README;
  - `envs/dev` variable and `preview_enabled = true` in `terraform.tfvars` (prod, when it exists, sets false; the parity guard is unaffected);
  - `scripts/gh/sticky-comment.sh` plus its self-test (not yet called).
  - No bootstrap re-apply. About 9 resources added to dev.
- **PR B, `infra(bootstrap): preview roles and app preview workflow`:**
  - bootstrap E and F, `app-preview.yml`, `scripts/preview/*`;
  - `terraform-destroy` sweep and the family loop, N1/N8 extension;
  - the plan comment switched to `sticky-comment.sh`;
  - policy and self-tests.
  - The bootstrap is re-applied from the PR branch before merge, so PR B previews itself.

## Alternatives considered

- **`workflow_run` after `App CI` (credentialed code always from `main`).** The trust could pin `app-preview.yml@refs/heads/main`, and PR code would never hold AWS credentials. It is the stronger isolation in principle, and it is the main rejected option. It was rejected because:
  - it needs a trigger-policy exception;
  - zizmor `dangerous-triggers` flags it, and the docs warn that attackers "often find ways" in;
  - the PR number and artifacts would come from an untrusted run;
  - closes would need a signal workflow;
  - workflow changes take effect only after merge.
  The approval plus the fenced role bounds the blast radius to `Env=preview` resources. Kept as Q4.
- **Path rules on the dev port 80 listener.** Simplest URL, but the role would need `CreateRule` on the dev listener (Env=dev). A hostile approved PR could add a priority 1 `/*` rule and hijack dev. Rejected.
- **A listener per PR port.** No rewrite needed. But `CreateListener` is authorized on the dev ALB, which cannot be tag-scoped, and an SG port range opens more surface. Rejected.
- **Terraform per-PR state.** Declarative, but state write for PR code, slow init and orphaned keys. Rejected.
- **Cleanup behind approval.** One role fewer, but an unapproved close leaves a billed task. Kept as Q2.
- **Reusing the dev exec role or the dev secret.** It would let PR code read the dev secret. Rejected (FR-8).

## Consequences

### Risks

| R | Risk | Mitigation |
|---|---|---|
| R32 | Approved PR code holds the preview role (the workflow comes from the PR) | Reviewer approval reading `.github/**` and `scripts/**`; fence plus guardrails; tag- and name-scoped allows; env branch rule `refs/pull/*/merge`; no secrets; PassRole to one role with no secret access |
| R33 | The unapproved cleanup token (unmerged close) runs PR code | Delete-only on `Env=preview` names; no create, PassRole or register |
| R34 | The cap and N-tests run in PR-controlled scripts | Approval; budget alert; teardown sweep. Residual, accepted |
| R35 | `job_workflow_ref` for `pull_request` runs is undocumented | Fails closed. Step B0 reads it from a real PR token before the trust is relied on |
| R36 | ALB URL rewrite unavailable or misbehaving | Smoke at B5. Fallback: `BASE_PATH` support in the app (backend-dev, small) with plain path rules |
| R37 | Merged close runs on `refs/heads/main` (Finding 7) | Cleanup main leg pinned to `app-preview.yml@main`; env `preview-cleanup` allows `main` |
| R38 | A PR closed with a merge conflict triggers no run | Sweep in the next deploy, dispatch sweep, teardown |
| R39 | Late approval after close; approval and concurrency interplay undocumented | The deploy re-checks that the PR is open; sweeps |
| R40 | The preview URL (dev ALB hostname) is public in a public PR comment | The `ALB_INGRESS_CIDRS` rules cover port 8000; previews hold no secret |
| R41 | Task definition revisions stay `ACTIVE` after close | No cost; deregistered at teardown (V19) |
| R42 | A Docker-enabled credentialed job runs PR code | Same exception as app-deploy; move to crane once ADR 0008 PR B lands |
| R43 | The ECR lifecycle (keep 20) may expire an image of a long-lived preview, so a restart fails | Push again; 20 is far above 3 previews times a few pushes |
| R44 | The comment job's step text comes from the PR while it holds a write token | Same accepted residual as the plan comment; base-SHA scripts |
| R45 | A sweep bug run by the apply role could delete the dev service | Strict name regex; self-test that `sis-dev-app` never matches |
| R46 | Every push to a PR needs a new approval | Intended: new code, new review |

### Other consequences

- **Cost:** see H. Dev gains a free listener, an SG and a repo with tens of MB.
- **Alerts:** N16 and the extended N1/N8 send alert emails by design. N11 to N15 do not (not STS refusals).
- **Docs** (orchestrator, D14):
  - requirements FR-17 status;
  - README (preview flow, URL form, approvals, teardown);
  - `ci-cd.md` (app-preview exception, cleanup environment, comment script);
  - `terraform.md` (approved `*` list, StringLike legs);
  - ADR 0002 name contract (`sis-dev-preview-*`);
  - ADR 0007 exception lists;
  - a diagram of the preview path.

## Checkpoint commands (the user runs these; NFR-9)

Run from the repo root. Each block is one command per line for zsh, with no packed arguments (lesson 37). Dispatches and approvals use the web UI (the PAT has Actions read-only, lesson 31).

### PR A

**A1. Checks.** With the PR A branch checked out:
```bash
gh pr checks --watch
```
Expect green `guard`, `checks` and `plan (dev) / terraform plan`. The sticky plan comment lists the new `module.app_ecs` preview addresses (about 9) and no change to existing ones.

**A2. Merge, then bring dev up.** Approve the push apply. Then:
```bash
AWS_PROFILE=sis-dev-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/dev/app-api-key --secret-string "$(openssl rand -hex 24)" --query Name --output text
```
Approve App Deploy if it starts. Then:
```bash
ALB_DNS="$(AWS_PROFILE=sis-dev-admin aws elbv2 describe-load-balancers --region ap-southeast-1 --names sis-dev-alb --query 'LoadBalancers[0].DNSName' --output text)"
curl -s -o /dev/null -w '%{http_code}\n' "http://${ALB_DNS}:8000/pr-1/"
curl -s "http://${ALB_DNS}/version"
```
Expect `404` from the preview listener, and the dev `/version` unchanged. Keep dev up for PR B, or destroy it (Run workflow Terraform Destroy, env `dev`, type **destroy-dev**).

### PR B

**B0. Read the PR `job_workflow_ref` format.** Open PR B's OIDC Smoke Test run, job "prove plan role identity", step N8. Expect the line `Token job_workflow_ref: trungleviet-agilityio/ship-it-safely/.github/workflows/oidc-smoke-test.yml@refs/pull/` followed by the PR number and `/merge`. If it differs, stop and report (R35).

**B1. Enable previews in the gitignored dev inputs.**
```bash
printf 'preview_enabled = true\n' >> infra/terraform/bootstrap/accounts/dev.tfvars
```

**B2. Dev bootstrap re-apply from the PR B branch.**
```bash
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap init -backend-config="bucket=sis-dev-tfstate-$(AWS_PROFILE=sis-dev-admin aws sts get-caller-identity --query Account --output text)-ap-southeast-1-an"
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/dev.tfvars -out=bootstrap.tfplan
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap apply bootstrap.tfplan
rm infra/terraform/bootstrap/bootstrap.tfplan
```
Expect about 11 to add:
- `aws_iam_role.preview`, `aws_iam_role.preview_cleanup`, `aws_iam_role.preview_exec`;
- their 3 inline policies;
- `aws_iam_policy.preview_fence`;
- 4 attachments.

Expect 3 to change (`aws_iam_role_policy.apply`, `aws_iam_policy.guardrails`, `aws_cloudwatch_event_rule.oidc_unexpected`) and 0 to destroy. The plan, apply and deploy trusts must show no change.

**B3. GitHub environments (web UI, Settings > Environments).**
- `preview`: Required reviewers = you; Prevent self-review **off**; Deployment branches and tags = Selected, add branch rule **refs/pull/*/merge**.
- `preview-cleanup`: no reviewers; Selected, add branch rules **main** and **refs/pull/*/merge**.

Then the secrets. If a `gh secret set --env` line is refused (PAT without Environments write), add the same secret in the web UI.
```bash
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap output -raw preview_role_arn | gh secret set AWS_PREVIEW_ROLE_ARN --env preview --repo trungleviet-agilityio/ship-it-safely
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap output -raw preview_cleanup_role_arn | gh secret set AWS_PREVIEW_CLEANUP_ROLE_ARN --env preview-cleanup --repo trungleviet-agilityio/ship-it-safely
AWS_PROFILE=sis-dev-admin aws sts get-caller-identity --query Account --output text | gh secret set AWS_ACCOUNT_ID --env preview --repo trungleviet-agilityio/ship-it-safely
AWS_PROFILE=sis-dev-admin aws sts get-caller-identity --query Account --output text | gh secret set AWS_ACCOUNT_ID --env preview-cleanup --repo trungleviet-agilityio/ship-it-safely
gh secret list --env preview --repo trungleviet-agilityio/ship-it-safely
gh secret list --env preview-cleanup --repo trungleviet-agilityio/ship-it-safely
gh secret list --repo trungleviet-agilityio/ship-it-safely
```
The repo-level list must not contain `AWS_PREVIEW_ROLE_ARN`, `AWS_PREVIEW_CLEANUP_ROLE_ARN` or `AWS_ACCOUNT_ID`.

**B4. Dev up.** If dev is down: Run workflow Terraform (env `dev`), approve, run the A2 `put-secret-value` line, then Run workflow App Deploy and approve.

**B5. PR B previews itself.** Approve `preview` on the App Preview run. Expect:
- the deploy log shows "denied as designed" for N11 to N15;
- a bot comment with the URL.

Then:
```bash
ALB_DNS="$(AWS_PROFILE=sis-dev-admin aws elbv2 describe-load-balancers --region ap-southeast-1 --names sis-dev-alb --query 'LoadBalancers[0].DNSName' --output text)"
curl -s "http://${ALB_DNS}:8000/pr-$(gh pr view --json number --jq .number)/version"
gh pr view --json headRefOid --jq .headRefOid
```
`git_sha` must equal the head SHA, and `env` must be `preview`. Then `curl -s "http://${ALB_DNS}/version"` must still show the dev SHA.

**B6. Merge PR B** (squash). Expect `cleanup (preview)` to run with no approval on the `main` leg, and PR B's preview to be gone. App Deploy starts because `scripts/lib.sh` changed: approve it.

**B7. Two demo PRs from main.**
```bash
git switch -c demo/preview-a origin/main
printf '# preview demo a\n' >> app/src/board.py
git commit -am "chore(app): preview demo a"
git push -u origin demo/preview-a
gh pr create --repo trungleviet-agilityio/ship-it-safely --fill
git switch -c demo/preview-b origin/main
printf '# preview demo b\n' >> app/src/board.py
git commit -am "chore(app): preview demo b"
git push -u origin demo/preview-b
gh pr create --repo trungleviet-agilityio/ship-it-safely --fill
```
Approve both. Expect two comments with different `/pr-<number>/` URLs, each `/version` showing its own head SHA.

**B8. Close both without merging** (keeps `main` clean; B6 proved the merged leg).
```bash
gh pr close demo/preview-a --repo trungleviet-agilityio/ship-it-safely --delete-branch
gh pr close demo/preview-b --repo trungleviet-agilityio/ship-it-safely --delete-branch
AWS_PROFILE=sis-dev-admin aws ecs list-services --region ap-southeast-1 --cluster sis-dev-cluster --query 'serviceArns[]' --output text | tr '\t' '\n' | sed 's|.*/||'
AWS_PROFILE=sis-dev-admin aws elbv2 describe-target-groups --region ap-southeast-1 --query 'TargetGroups[].TargetGroupName' --output text
AWS_PROFILE=sis-dev-admin aws ecr list-images --region ap-southeast-1 --repository-name sis-dev-preview --query 'imageIds[].imageTag' --output text
```
Expect:
- only `sis-dev-app` in the service list;
- only `sis-dev-tg` in the target group list;
- no `pr-` tag of the closed PRs in the repo;
- the comments updated to "Preview removed";
- the URLs answering 404.

**B9. Fork and Dependabot (N17).** If you have a second GitHub account, fork the repo and open a PR touching `app/`. Otherwise wait for the next Dependabot Docker PR. Expect App Preview jobs skipped and no approval request.

**B10. Sweep and N16.** Run workflow App Preview on `main` (no approval needed). Expect the sweep summary, the line "the preview role denied as designed", and one alert email.

**B11. N1 and N8.** Run workflow OIDC Smoke Test. Expect refusals from plan, apply, deploy, preview and preview-cleanup.

**B12. Teardown with a preview open.** Open a third demo PR as in B7 and approve its preview. Then Run workflow Terraform Destroy: env `dev`, type **destroy-dev**, approve. Expect:
- the step "Remove previews" reports one removed;
- the destroy deletes all dev resources (about 36);
- revisions are deregistered for both families.

Then close the demo PR. Its cleanup finds nothing and ends green.

## Open questions (recommendation first)

| Q | Recommendation | Alternatives |
|---|---|---|
| Q1 | Dedicated preview listener on port 8000 with path rules and URL rewrite (V1) | Port 8080 or 81; a port per PR; path rules on port 80 |
| Q2 | No-approval cleanup with the delete-only role (V6) | Cleanup behind the `preview` approval (one role fewer) |
| Q3 | Cap 3 | 2 (cheaper) or 5 |
| Q4 | `pull_request` with approval and the fenced role (V13) | `workflow_run` with a pinned-on-`main` trust (Alternatives) |
| Q5 | Leave preview revisions `ACTIVE` until teardown (V19) | `ecs:DeregisterTaskDefinition` on `*` for the approved role only |
| Q6 | Separate repo `sis-dev-preview` (V11) | Dev repo with a `pr-` tag prefix and a second lifecycle rule |
| Q7 | Fork proof through a Dependabot Docker PR if there is no second account | A second GitHub account |
| Q8 | No `actor_id` pin on the preview trusts (the approval is the gate) | Pin `actor_id` to your user (blocks collaborators' PRs; a close by someone else would not clean up) |
| Q9 | Build the head SHA (V12) | Build the merge commit like App CI |
| Q10 | Fail the deploy (red) with a clear comment when dev is down (ADR 0005 F16: green means deployed) | End green with a notice |
| Q11 | Previews for draft PRs too (the approval still gates them) | Skip drafts (`draft == false`; then add the `ready_for_review` type) |

## Build briefs

### devops-engineer, PR A (owns `infra/**`, `.github/**`, `scripts/**`, `Makefile`, repo tooling)

Branch from `main` (lesson 25). Read this ADR at its absolute path under `docs/adr/`.

**Files**
- `infra/terraform/modules/app-ecs/preview.tf` (new):
  - `aws_lb_listener.preview` (fixed-response 404, tags with `Env = "preview"`);
  - `aws_vpc_security_group_ingress_rule.alb_preview` (indexed over CIDRs, port `preview_listener_port`);
  - `aws_security_group.preview_task` and its rules (ingress container port from the ALB SG, egress 443), plus `aws_vpc_security_group_egress_rule.alb_to_preview_task`;
  - `aws_ecr_repository.preview` (IMMUTABLE, scan on push, AES256, `force_delete`, `Env = "preview"`) and its lifecycle (keep `preview_ecr_keep_images`, default 20);
  - `aws_cloudwatch_log_group.preview` (1 day, `Env = "preview"`).
  - Everything uses `count = var.preview_enabled ? 1 : 0`.
- Module `variables.tf`: `preview_enabled` (default false), `preview_listener_port` (default 8000, 1024 to 65535, not 80, not the container port), `preview_ecr_keep_images`.
- Module `locals.tf`: names from the contract.
- Module `outputs.tf`: `preview_listener_port`, `preview_repository_name` (no ARN).
- README.
- `envs/dev`: the variable and `preview_enabled = true` in `terraform.tfvars`; README.
- `scripts/gh/sticky-comment.sh` (marker, bot-only update, `assert-no-account-id.sh` on the body, env-only inputs) and its case in `scripts/selftest/`.

**Tests first**
- `app_ecs.tftest.hcl`:
  - disabled means zero preview resources;
  - enabled means listener port, `Env=preview` tag, default 404, no forward;
  - one ingress per CIDR on the preview port, no CIDR in descriptions;
  - preview SG rules exact;
  - ECR immutable, scan and force delete;
  - log retention 1;
  - names equal the contract.
- Sticky comment: create, update, refuse to update a non-bot comment, refuse a 12-digit run.

**Done**
- `make check` green; actionlint and zizmor clean.
- `terraform test` passes offline.
- The plan shows additions only under `module.app_ecs` (preview addresses).
- No 12-digit literal anywhere.

### devops-engineer, PR B

**Files**
- Bootstrap: `variables.tf`, `locals.tf` (legs, names, `workflow_files`), `oidc.tf` (dynamic statement per leg), `iam_preview.tf` (new), `iam_apply.tf`, `iam_guardrails.tf`, `outputs.tf`, `accounts/dev.tfvars.example`, README. Tests in `trust.tftest.hcl`, `iam.tftest.hcl` and `monitoring.tftest.hcl`.
- `scripts/lib.sh`:
  - `preview_names <n>` (validates `^[1-9][0-9]{0,4}$` and at most 50000);
  - `PREVIEW_MAX=3`;
  - `web_identity_call` accepts `preview` and `preview-cleanup`.
- `scripts/preview/`: `render-task-def.sh`, `preflight.sh`, `up.sh`, `down.sh`, `sweep.sh`, `assert-isolation.sh`.
- `scripts/ecs/deregister-revisions.sh`: loop over both families, with the preview precondition.
- `scripts/guard/harden_runner_policy.py`: `NEEDS_CONTAINERS` entry.
- Self-tests: `scripts/selftest/preview.sh` (new), plus `workflows.sh`, `ecs.sh` and `render.sh`.
- Workflows:
  - `app-preview.yml` (J);
  - `terraform-destroy.yml` ("Remove previews" before the plan, summary line);
  - `oidc-smoke-test.yml` (N1, N8 lists);
  - `reusable-terraform-plan.yml` comment job calls `scripts/gh/sticky-comment.sh`.

**Tests first**
- Bootstrap:
  - plan, apply and deploy trust JSON unchanged (golden documents);
  - preview trust has exactly one leg, the `environment:preview` sub and StringLike ref and `job_workflow_ref` on `app-preview.yml@refs/pull/*/merge`;
  - cleanup trust has exactly two legs (PR, main);
  - no preview resources when disabled;
  - PassRole only on `sis-dev-preview-exec` with `PassedToService`;
  - every Allow `*` resource is on the approved list;
  - `AddTags` and `ecs:TagResource` only with `CreateAction`;
  - the fence statements as in F.4;
  - the exec role has the boundary, no secret allow and the explicit deny;
  - `expected_subs` contains both new subs;
  - the apply `ListServices` carries the `ecs:cluster` condition.
- Scripts (PATH-stubbed `aws` and `gh`):
  - `up.sh` creates, then updates on a second run, waits on `DRAINING`, and refuses a priority held by another `PreviewPr`;
  - `down.sh` handles each missing piece;
  - `sweep.sh` keeps open PRs, never touches `sis-dev-app`, and catches a `DRAINING` service;
  - preflight at, below and above the cap, and with no listener;
  - renderer refuses a foreign repo, a tag, a bad SHA or a bad PR number, and outputs no `secrets` and no `taskRoleArn`;
  - `assert-isolation.sh` passes only on AccessDenied, and N14 deletes the rule on an unexpected success.
- Workflow self-tests (J).

**Done**
- `make check` green; zizmor and actionlint clean; trigger policy unchanged.
- `terraform test` passes for bootstrap and module.
- The hand-back lists the expected bootstrap plan counts (B2) and every allowlist host with its line.
- No `apply` or `destroy` target. No 12-digit literal. No `<...>` placeholder in a runnable command.

### backend-dev

No change: the ALB URL rewrite removes the need for a base path, and the preview shows `APP_ENV=preview` and `secret_loaded: no` with the current code. Only if R36 triggers: add an optional `BASE_PATH` prefix strip in `app/src/board.py` with tests.

## Sources

- https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-limits.html
- https://docs.aws.amazon.com/elasticloadbalancing/latest/application/rule-transforms.html
- https://docs.aws.amazon.com/cli/latest/reference/elbv2/create-rule.html
- https://servicereference.us-east-1.amazonaws.com/v1/elasticloadbalancing/elasticloadbalancing.json
- https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/tagging-resources-during-creation.html (read through the search result summary)
- https://servicereference.us-east-1.amazonaws.com/v1/ecs/ecs.json
- https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DeleteService.html
- https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DeleteCluster.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html
- https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html
- https://aws.amazon.com/vpc/pricing/
- https://aws.amazon.com/fargate/pricing/
- https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v6.70.0/website/docs/r/lb_listener.html.markdown
- https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows
- https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments
- https://docs.github.com/en/actions/reference/security/oidc
- https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency
- https://docs.zizmor.sh/audits/
