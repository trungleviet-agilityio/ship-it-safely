# envs/dev

The dev environment root (FR-6, ADR 0004, E16 to E18): one call to [`modules/app-ecs`](../../modules/app-ecs/),
the S3 backend for `envs/dev/terraform.tfstate`, and the committed `terraform.tfvars`. Environments differ
only through `terraform.tfvars`.

## Run

CI plans on every pull request that touches `infra/**` and applies on `main` after approval of the `dev`
environment (`.github/workflows/terraform-iac.yml`). To run it by hand (checkpoint, with SSO
admin; the account ID comes from your shell, never from a file in git):

```bash
export AWS_PROFILE=<admin profile> TF_VAR_aws_account_id=<DEV_ACCOUNT_ID>
terraform init -backend-config="bucket=sis-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an"
terraform plan -out=tfplan
```

Offline checks need no credentials: `make tf-check` (init with `-backend=false`, validate, `terraform test`).

## Constraints

- **Account ID.** `aws_account_id` has no default and no tfvars entry. It feeds `allowed_account_ids` and
  nothing else. Outputs never carry it, because apply logs are public.
- **Backend.** Partial: the bucket name holds the account ID, so it arrives through `-backend-config`.
  `use_lockfile = true`, key `envs/dev/terraform.tfstate`.
- **Tags.** `default_tags` (`Project`, `Env`, `ManagedBy`) are identical to bootstrap; the apply role's EC2
  conditions depend on them, and standalone security group rules need them to be changeable.
- **Placeholder image.** `container_image` in `terraform.tfvars` is a digest-pinned image with no command, so
  it never serves. The first deployment after a create stalls by design (ADR 0005, F2) until app-deploy sets
  the real image.
- **First apply.** Run `put-secret-value`, then run the `app-deploy` workflow (no forced deployment). The state of `bootstrap/` is not readable by the CI roles.
- **Teardown.** Run the `terraform-destroy` workflow (Run workflow, env `dev`, confirm `destroy-dev`, then
  approve `dev`). It plans the destroy, refuses anything but deletes under `module.app_ecs`, applies the saved
  plan and deregisters the task definition revisions (ADR 0006). An admin can still run `plan -destroy` by hand;
  a local `init` here does not disturb `make tf-check`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| aws | ~> 6.70 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| app_ecs | ../../modules/app-ecs | n/a |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aws_account_id | Target AWS account ID. Never committed: CI passes TF_VAR_aws_account_id; locally use the shell or a gitignored *.auto.tfvars. | `string` | n/a | yes |
| aws_region | AWS region for every resource. | `string` | n/a | yes |
| azs | Two availability zones for the public subnets. | `list(string)` | n/a | yes |
| container_image | Container image pinned by digest. A public placeholder that never serves: app-deploy sets the real image by digest. | `string` | n/a | yes |
| desired_count | Number of Fargate tasks. | `number` | n/a | yes |
| env | Environment name. | `string` | n/a | yes |
| log_retention_days | Retention of the application log group. | `number` | n/a | yes |
| prefix | Name prefix. Must equal the bootstrap prefix. | `string` | n/a | yes |
| task_cpu | Task-level CPU units. | `number` | n/a | yes |
| task_memory | Task-level memory in MiB. | `number` | n/a | yes |
| vpc_cidr | CIDR block of the VPC. | `string` | n/a | yes |
| alb_ingress_cidrs | CIDR blocks allowed to reach the ALB on port 80. CI can restrict it with TF_VAR_alb_ingress_cidrs (ADR 0004, Q1). | `list(string)` | ```[ "0.0.0.0/0" ]``` | no |
| secret_recovery_window_days | Secrets Manager recovery window; 0 deletes at once (ADR 0004, Q3). | `number` | `0` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alb_url | Public URL of the load balancer (plain HTTP). |
| cluster_name | ECS cluster name. |
| ecr_repository_name | ECR repository name. |
| log_group_name | Application log group. |
| secret_name | Secrets Manager secret name. Set its value by hand (put-secret-value). |
| service_name | ECS service name. |
| task_family | Task definition family. |
<!-- END_TF_DOCS -->
