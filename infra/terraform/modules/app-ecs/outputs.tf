output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.app.name
}

output "task_family" {
  description = "Task definition family."
  value       = aws_ecs_task_definition.app.family
}

output "ecr_repository_name" {
  description = "ECR repository name."
  value       = aws_ecr_repository.app.name
}

output "ecr_repository_url" {
  description = "ECR repository URL (holds the account ID, so the root does not re-export it)."
  value       = aws_ecr_repository.app.repository_url
}

output "log_group_name" {
  description = "Application log group."
  value       = aws_cloudwatch_log_group.app.name
}

output "secret_name" {
  description = "Secrets Manager secret name."
  value       = aws_secretsmanager_secret.app.name
}

output "secret_arn" {
  description = "Secret ARN used in secrets[].valueFrom."
  value       = aws_secretsmanager_secret.app.arn
}

output "exec_role_name" {
  description = "Task execution role name."
  value       = aws_iam_role.exec.name
}

output "task_role_name" {
  description = "Task role name."
  value       = aws_iam_role.task.name
}

output "exec_role_arn" {
  description = "Task execution role ARN."
  value       = aws_iam_role.exec.arn
}

output "task_role_arn" {
  description = "Task role ARN."
  value       = aws_iam_role.task.arn
}

output "target_group_arn" {
  description = "Target group ARN."
  value       = aws_lb_target_group.app.arn
}

output "preview_listener_port" {
  description = "Port of the preview listener, or null while preview_enabled is false."
  value       = one(aws_lb_listener.preview[*].port)
}

output "preview_listener_arn" {
  description = "Preview listener ARN (holds the account ID, so the root does not re-export it), or null while disabled."
  value       = one(aws_lb_listener.preview[*].arn)
}

output "preview_repository_name" {
  description = "Preview ECR repository name, or null while preview_enabled is false."
  value       = one(aws_ecr_repository.preview[*].name)
}

output "preview_task_security_group_id" {
  description = "Security group of the preview tasks, or null while preview_enabled is false."
  value       = one(aws_security_group.preview_task[*].id)
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.this.dns_name
}
