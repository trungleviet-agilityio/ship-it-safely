locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  name       = "${var.prefix}-${var.env}"

  # Name contract with bootstrap `resource_names` (ADR 0002): the apply and deploy roles are scoped by these.
  names = {
    cluster        = "${local.name}-cluster"
    service        = "${local.name}-app"
    task_family    = "${local.name}-app"
    ecr_repository = "${local.name}-app"
    log_group      = "/ecs/${local.name}-app"
    alb            = "${local.name}-alb"
    target_group   = "${local.name}-tg"
    exec_role      = "${local.name}-ecs-exec"
    task_role      = "${local.name}-ecs-task"
    secret         = "${var.prefix}/${var.env}/app-api-key"
    boundary       = "${local.name}-ecs-boundary"

    # Shared preview infrastructure (ADR 0009, V2). The per-PR names `${local.name}-preview-<n>` are made by the
    # preview scripts; they all sit under the `${local.name}-*` patterns the apply role already covers.
    preview_listener   = "${local.name}-preview"
    preview_repository = "${local.name}-preview"
    preview_log_group  = "/ecs/${local.name}-preview"
    preview_task_sg    = "${local.name}-preview-task"
  }

  boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${local.names.boundary}"

  container_name = "app"
}
