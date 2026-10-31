# Shared infrastructure of the PR previews (ADR 0009, V1, V2, V11). Everything is behind var.preview_enabled.
# Terraform owns only what is shared and long lived. The per-PR target group, listener rule and service are created
# and deleted by scripts/preview/*.sh (PR B), so the listener's default action is the only thing Terraform manages
# on it and the dev plan shows no drift.

# A dedicated listener, so a preview role can be limited to rules on this listener by its `Env=preview` tag. The
# dev listener (port 80) stays untouched. A tag on a resource overrides the provider default of the same key.
resource "aws_lb_listener" "preview" {
  count = var.preview_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = var.preview_listener_port
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "No preview at this path"
      status_code  = "404"
    }
  }

  tags = {
    Name = local.names.preview_listener
    Env  = "preview"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_preview" {
  # Indexed and without a CIDR in the description, like alb_http (ADR 0007 S35).
  count = var.preview_enabled ? nonsensitive(length(var.alb_ingress_cidrs)) : 0

  security_group_id = aws_security_group.alb.id
  description       = "Preview HTTP from allowed CIDR ${count.index}"
  ip_protocol       = "tcp"
  from_port         = var.preview_listener_port
  to_port           = var.preview_listener_port
  cidr_ipv4         = var.alb_ingress_cidrs[count.index]
}

# Preview tasks get their own group, so a preview can never reach the dev task group's rules. Like the other
# groups it keeps the stack tags (Env = the environment): the apply role changes only tagged EC2 resources.
resource "aws_security_group" "preview_task" {
  count = var.preview_enabled ? 1 : 0

  name        = local.names.preview_task_sg
  description = "Preview tasks: container port from the ALB, HTTPS out"
  vpc_id      = aws_vpc.this.id

  tags = { Name = local.names.preview_task_sg }
}

resource "aws_vpc_security_group_ingress_rule" "preview_task_from_alb" {
  count = var.preview_enabled ? 1 : 0

  security_group_id            = aws_security_group.preview_task[0].id
  description                  = "Container port from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "preview_task_https" {
  count = var.preview_enabled ? 1 : 0

  security_group_id = aws_security_group.preview_task[0].id
  description       = "HTTPS for image pull and logs"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_preview_task" {
  count = var.preview_enabled ? 1 : 0

  security_group_id            = aws_security_group.alb.id
  description                  = "Container port to the preview tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  referenced_security_group_id = aws_security_group.preview_task[0].id
}

# A separate repository, so a PR image can never be promoted and preview pushes never evict `main` images from the
# dev repository (ADR 0009, V11). Removed with the stack.
resource "aws_ecr_repository" "preview" {
  count = var.preview_enabled ? 1 : 0

  name                 = local.names.preview_repository
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Env = "preview" }
}

# One rule, no "expire untagged" rule, for the same reason as the dev repository (ADR 0004, E10).
resource "aws_ecr_lifecycle_policy" "preview" {
  count = var.preview_enabled ? 1 : 0

  repository = aws_ecr_repository.preview[0].name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last ${var.preview_ecr_keep_images} images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = var.preview_ecr_keep_images
      }
      action = { type = "expire" }
    }]
  })
}

resource "aws_cloudwatch_log_group" "preview" {
  count = var.preview_enabled ? 1 : 0

  name              = local.names.preview_log_group
  retention_in_days = 1

  tags = { Env = "preview" }
}
