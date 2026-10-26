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

run "outputs_hold_no_account_id" {
  command = plan

  assert {
    condition     = !anytrue([for o in [output.cluster_name, output.service_name, output.task_family, output.ecr_repository_name, output.log_group_name, output.secret_name] : strcontains(o, "123456789012")])
    error_message = "root outputs must not carry the account ID (public logs)"
  }
}

run "short_account_id_is_rejected" {
  command = plan

  variables {
    aws_account_id = "12345678901"
  }

  expect_failures = [var.aws_account_id]
}
