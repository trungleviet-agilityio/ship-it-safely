variable "aws_account_id" {
  type        = string
  description = "Target AWS account ID. Never committed: CI passes TF_VAR_aws_account_id; locally use the shell or a gitignored *.auto.tfvars."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must be exactly 12 digits."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for every resource."
}

variable "prefix" {
  type        = string
  description = "Name prefix. Must equal the bootstrap prefix."
}

variable "env" {
  type        = string
  description = "Environment name."
}

variable "azs" {
  type        = list(string)
  description = "Two availability zones for the public subnets."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block of the VPC."
}

variable "container_image" {
  type        = string
  description = "Container image pinned by digest. A public placeholder that never serves: app-deploy sets the real image by digest."
}

variable "desired_count" {
  type        = number
  description = "Number of Fargate tasks."
}

variable "task_cpu" {
  type        = number
  description = "Task-level CPU units."
}

variable "task_memory" {
  type        = number
  description = "Task-level memory in MiB."
}

variable "log_retention_days" {
  type        = number
  description = "Retention of the application log group."
}

variable "secret_recovery_window_days" {
  type        = number
  description = "Secrets Manager recovery window; 0 deletes at once (ADR 0004, Q3)."
  default     = 0
}

variable "alb_ingress_cidrs" {
  type        = list(string)
  description = "CIDR blocks allowed to reach the ALB on port 80. CI can restrict it with TF_VAR_alb_ingress_cidrs (ADR 0004, Q1)."
  default     = ["0.0.0.0/0"]
}
