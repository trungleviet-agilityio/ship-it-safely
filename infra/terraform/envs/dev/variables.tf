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
  description = "Environment name. Must equal the directory name of this root (the parity guard checks it)."

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,7}$", var.env))
    error_message = "env must be 2 to 8 lowercase letters and digits, starting with a letter (ADR 0008, P4)."
  }
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

variable "preview_enabled" {
  type        = bool
  description = "Create the shared PR preview infrastructure (listener, repository, log group, task security group; ADR 0009). Off by default."
  default     = false
}

variable "secret_recovery_window_days" {
  type        = number
  description = "Secrets Manager recovery window; 0 deletes at once (ADR 0004, Q3)."
  default     = 0
}

variable "alb_ingress_cidrs_json" {
  type        = string
  description = "JSON list of IPv4 CIDRs allowed to reach the ALB on port 80, e.g. [\"198.51.100.7/32\"]. CI passes the secret ALB_INGRESS_CIDRS. Empty means 0.0.0.0/0 (ADR 0007 S10)."
  default     = ""
  sensitive   = true

  validation {
    condition = var.alb_ingress_cidrs_json == "" || (
      can(jsondecode(var.alb_ingress_cidrs_json))
      && can(tolist(jsondecode(var.alb_ingress_cidrs_json)))
      && length(jsondecode(var.alb_ingress_cidrs_json)) >= 1
      && alltrue([for c in jsondecode(var.alb_ingress_cidrs_json) : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$", c)) && can(cidrhost(c, 0))])
    )
    error_message = "alb_ingress_cidrs_json must be empty or a JSON list of at least one IPv4 CIDR."
  }
}
