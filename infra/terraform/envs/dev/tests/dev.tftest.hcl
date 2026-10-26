# envs/dev stays thin and consistent with bootstrap (ADR 0004, E16 to E18). Offline: nothing talks to AWS.
# The committed terraform.tfvars is loaded by terraform test; only the account ID (never committed) is set here.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
}

variables {
  aws_account_id = "123456789012"
}

run "default_tags_match_bootstrap" {
  command = plan

  assert {
    condition = local.default_tags == {
      Project   = "ship-it-safely"
      Env       = "dev"
      ManagedBy = "terraform"
    }
    error_message = "default_tags must be identical to bootstrap (NFR-8)"
  }
}

run "committed_tfvars_plan_the_dev_stack" {
  command = plan

  assert {
    condition     = module.app_ecs.cluster_name == "sis-dev-cluster" && module.app_ecs.service_name == "sis-dev-app"
    error_message = "the committed tfvars must produce the bootstrap name contract"
  }

  assert {
    condition     = module.app_ecs.secret_name == "sis/dev/app-api-key"
    error_message = "secret shell name follows the contract"
  }
}

# terraform test cannot enumerate `output`, so the declared names are read from outputs.tf and the values are pinned.
run "root_outputs_are_exactly_the_account_free_set" {
  command = plan

  assert {
    condition = (
      toset([for m in regexall("(?m)^output \"([a-z_]+)\"", file("outputs.tf")) : m[0]]) == toset([
        "alb_url", "cluster_name", "service_name", "task_family", "ecr_repository_name", "log_group_name", "secret_name",
      ])
      && output.cluster_name != ""
    )
    error_message = "root outputs must be exactly this set; ARNs, the ECR URL and account IDs stay module outputs (public logs)"
  }

  assert {
    condition = (
      output.cluster_name == "sis-dev-cluster"
      && output.service_name == "sis-dev-app"
      && output.task_family == "sis-dev-app"
      && output.ecr_repository_name == "sis-dev-app"
      && output.log_group_name == "/ecs/sis-dev-app"
      && output.secret_name == "sis/dev/app-api-key"
    )
    error_message = "output values must be the plain names from the bootstrap contract"
  }
}

run "short_account_id_is_rejected" {
  command = plan

  variables {
    aws_account_id = "12345678901"
  }

  expect_failures = [var.aws_account_id]
}
