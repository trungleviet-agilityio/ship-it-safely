# Permission policies: guardrails, plan, apply, deploy, boundary (B14 to B20).
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
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/mock" }
  }
}

variables {
  aws_account_id  = "123456789012"
  github_owner_id = "111"
  github_repo_id  = "222"
  budget_email    = "ops@example.com"
}

run "guardrails_deny_and_attach" {
  command = plan

  assert {
    condition = alltrue([
      for a in [
        "secretsmanager:GetSecretValue",
        "secretsmanager:BatchGetSecretValue",
        "secretsmanager:PutSecretValue",
        "ssm:GetParameter*",
        "sts:AssumeRole",
        ] : contains(flatten([
          for s in data.aws_iam_policy_document.guardrails.statement : tolist(s.actions) if s.effect == "Deny"
      ]), a)
    ])
    error_message = "guardrails must deny secret reads, SSM reads and role chaining"
  }

  assert {
    condition = (
      toset(keys(aws_iam_role_policy_attachment.guardrails)) == toset(["plan", "apply", "deploy"])
      && alltrue([for k, a in aws_iam_role_policy_attachment.guardrails : a.policy_arn == aws_iam_policy.guardrails.arn])
    )
    error_message = "guardrails must be attached to all three roles"
  }
}

run "plan_role" {
  command = plan

  assert {
    condition     = aws_iam_role_policy_attachment.plan_read_only.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "plan role needs ReadOnlyAccess"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.plan.statement : (
        s.effect == "Deny"
        && contains(s.actions, "s3:GetObject")
        && length(s.not_resources) == 2
      )
    ])
    error_message = "plan role needs the NotResource s3 read deny"
  }
}

run "pass_role_is_exact" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for doc in [data.aws_iam_policy_document.apply, data.aws_iam_policy_document.deploy] : [
        for s in doc.statement : (
          toset(s.resources) == toset([
            "arn:aws:iam::123456789012:role/sis-dev-ecs-exec",
            "arn:aws:iam::123456789012:role/sis-dev-ecs-task",
          ])
          && anytrue([
            for c in s.condition : c.test == "StringEquals" && c.variable == "iam:PassedToService" && toset(c.values) == toset(["ecs-tasks.amazonaws.com"])
          ])
        ) if contains(s.actions, "iam:PassRole")
      ]
    ]))
    error_message = "every iam:PassRole must name the two ECS roles and set PassedToService"
  }

  assert {
    condition = alltrue([
      for doc in [data.aws_iam_policy_document.apply, data.aws_iam_policy_document.deploy] :
      length([for s in doc.statement : s if contains(s.actions, "iam:PassRole")]) == 1
    ])
    error_message = "apply and deploy each have exactly one PassRole statement"
  }
}

run "deploy_scope" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.deploy.statement : toset(s.resources) == toset(["arn:aws:ecr:ap-southeast-1:123456789012:repository/sis-dev-app"])
      if s.sid == "EcrPushOneRepo"
    ])
    error_message = "deploy ECR push resources must be exactly the one repository"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.deploy.statement : !anytrue([for a in s.actions : startswith(a, "secretsmanager:") || startswith(a, "s3:")])
    ])
    error_message = "deploy has no Secrets Manager or state access"
  }
}

run "apply_iam_requires_boundary" {
  command = plan

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : anytrue([
        for c in s.condition : c.test == "StringEquals" && c.variable == "iam:PermissionsBoundary" && toset(c.values) == toset(["arn:aws:iam::123456789012:policy/sis-dev-ecs-boundary"])
      ]) if contains(s.actions, "iam:CreateRole")
    ])
    error_message = "iam:CreateRole needs the boundary condition"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.apply.statement : s.effect == "Deny" && contains(s.actions, "iam:DeleteRolePermissionsBoundary")
    ])
    error_message = "apply must deny removing the boundary"
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.apply.statement : !anytrue([for a in s.actions : startswith(a, "iam:Attach")])
    ])
    error_message = "apply must not attach managed policies"
  }
}

run "no_broad_allows" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for doc in [
        data.aws_iam_policy_document.plan,
        data.aws_iam_policy_document.apply,
        data.aws_iam_policy_document.deploy,
        data.aws_iam_policy_document.ecs_boundary,
      ] : [for s in doc.statement : !contains(s.actions, "*") if s.effect == "Allow"]
    ]))
    error_message = "no Allow statement may use Action *"
  }

  assert {
    condition = alltrue(flatten([
      for doc in [
        data.aws_iam_policy_document.plan,
        data.aws_iam_policy_document.apply,
        data.aws_iam_policy_document.deploy,
        data.aws_iam_policy_document.ecs_boundary,
        ] : [
        for s in doc.statement : alltrue([
          for a in s.actions : contains([
            "ec2:Describe*",
            "elasticloadbalancing:Describe*",
            "logs:DescribeLogGroups",
            "ecs:DescribeTaskDefinition",
            "ecs:DeregisterTaskDefinition",
            "ecr:GetAuthorizationToken",
          ], a)
        ]) if s.effect == "Allow" && contains(s.resources, "*")
      ]
    ]))
    error_message = "Allow with Resource * is limited to the B20 list"
  }

  assert {
    condition = alltrue(flatten([
      for doc in [
        data.aws_iam_policy_document.plan,
        data.aws_iam_policy_document.apply,
        data.aws_iam_policy_document.deploy,
        data.aws_iam_policy_document.ecs_boundary,
      ] : [for s in doc.statement : alltrue([for a in s.actions : !endswith(a, "*") || endswith(a, ":Describe*")]) if s.effect == "Allow"]
    ]))
    error_message = "action wildcards in Allow are limited to Describe*"
  }
}

run "boundary_contents" {
  command = plan

  assert {
    condition     = aws_iam_policy.ecs_boundary.name == "sis-dev-ecs-boundary"
    error_message = "boundary policy name"
  }

  assert {
    condition = anytrue([
      for s in data.aws_iam_policy_document.ecs_boundary.statement :
      contains(s.actions, "secretsmanager:GetSecretValue") && toset(s.resources) == toset(["arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/*"])
    ])
    error_message = "boundary may read only sis/dev secrets"
  }
}

run "name_contract_output" {
  command = plan

  assert {
    condition = (
      local.resource_names.ecs_cluster == "sis-dev-cluster"
      && local.resource_names.ecs_service == "sis-dev-app"
      && local.resource_names.ecr_repository == "sis-dev-app"
      && local.resource_names.ecs_exec_role == "sis-dev-ecs-exec"
      && local.resource_names.ecs_task_role == "sis-dev-ecs-task"
      && local.resource_names.secret == "sis/dev/app-api-key"
    )
    error_message = "name contract"
  }
}
