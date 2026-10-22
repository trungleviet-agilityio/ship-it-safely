locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = var.aws_region
  name       = "${var.prefix}-${var.env}"

  # State bucket (B8) and the only keys the CI roles may touch (B17, B18).
  bucket_name   = "${local.name}-tfstate-${local.account_id}-${local.region}-an"
  bucket_arn    = "arn:${local.partition}:s3:::${local.bucket_name}"
  state_key     = "envs/${var.env}/terraform.tfstate"
  lock_key      = "${local.state_key}.tflock"
  state_arn     = "${local.bucket_arn}/${local.state_key}"
  lock_arn      = "${local.bucket_arn}/${local.lock_key}"
  bootstrap_arn = "${local.bucket_arn}/bootstrap/*"

  # The S3 backend lists the state key and, for workspaces, the "env:/" prefix. Neither exposes object data.
  state_list_prefixes = [local.state_key, "env:/*"]

  # OIDC (B12). The immutable form carries owner and repo IDs.
  gh_sub_prefix = (
    var.github_immutable_subject
    ? "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"
    : "repo:${var.github_owner}/${var.github_repo}"
  )
  oidc_host = "token.actions.githubusercontent.com"

  trust = {
    plan   = { sub = "${local.gh_sub_prefix}:pull_request", ref = null }
    apply  = { sub = "${local.gh_sub_prefix}:environment:${var.env}", ref = "refs/heads/main" }
    deploy = { sub = "${local.gh_sub_prefix}:environment:${var.env}", ref = "refs/heads/main" }
  }

  # Name contract that Phase 3 must follow (ADR 0002).
  resource_names = {
    ecs_cluster    = "${local.name}-cluster"
    ecs_service    = "${local.name}-app"
    task_family    = "${local.name}-app"
    ecr_repository = "${local.name}-app"
    log_group      = "/ecs/${local.name}-app"
    alb            = "${local.name}-alb"
    target_group   = "${local.name}-tg"
    ecs_exec_role  = "${local.name}-ecs-exec"
    ecs_task_role  = "${local.name}-ecs-task"
    secret         = "${var.prefix}/${var.env}/app-api-key"
    boundary       = "${local.name}-ecs-boundary"
  }

  role_names = {
    plan   = "${local.name}-gha-plan"
    apply  = "${local.name}-gha-apply"
    deploy = "${local.name}-gha-deploy"
  }
  guardrails_name = "${local.name}-gha-guardrails"

  # Tags the apply role requires on EC2 resources (B7, B14).
  tag_project = "ship-it-safely"

  # ARN builders.
  iam_arn      = "arn:${local.partition}:iam::${local.account_id}"
  svc_arn      = { for s in ["ecs", "ecr", "logs", "secretsmanager", "elasticloadbalancing", "ec2"] : s => "arn:${local.partition}:${s}:${local.region}:${local.account_id}" }
  boundary_arn = "${local.iam_arn}:policy/${local.resource_names.boundary}"

  ecs_role_arns = [
    "${local.iam_arn}:role/${local.resource_names.ecs_exec_role}",
    "${local.iam_arn}:role/${local.resource_names.ecs_task_role}",
  ]
  ecs_role_pattern = "${local.iam_arn}:role/${local.name}-ecs-*"

  ecr_repo_pattern = "${local.svc_arn["ecr"]}:repository/${local.name}-*"
  ecr_repo_app     = "${local.svc_arn["ecr"]}:repository/${local.resource_names.ecr_repository}"
  secret_pattern   = "${local.svc_arn["secretsmanager"]}:secret:${var.prefix}/${var.env}/*"
  log_group_arns = [
    "${local.svc_arn["logs"]}:log-group:/ecs/${local.name}-*",
    "${local.svc_arn["logs"]}:log-group:/ecs/${local.name}-*:*",
  ]
}
