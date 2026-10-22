resource "aws_iam_role" "deploy" {
  name                 = local.role_names.deploy
  description          = "GitHub Actions deploy: push one image, roll one service"
  path                 = "/"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.trust["deploy"].json
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # No resource-level support
  }

  statement {
    sid    = "EcrPushOneRepo"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
    ]
    resources = [local.ecr_repo_app]
  }

  statement {
    sid       = "RegisterTaskDef"
    effect    = "Allow"
    actions   = ["ecs:RegisterTaskDefinition"]
    resources = ["${local.svc_arn["ecs"]}:task-definition/${local.resource_names.task_family}:*"]

    condition {
      test     = "NumericLessThanEquals"
      variable = "ecs:task-cpu"
      values   = ["512"]
    }

    condition {
      test     = "NumericLessThanEquals"
      variable = "ecs:task-memory"
      values   = ["1024"]
    }
  }

  statement {
    sid       = "TagRegisteredTaskDef"
    effect    = "Allow"
    actions   = ["ecs:TagResource"]
    resources = ["${local.svc_arn["ecs"]}:task-definition/${local.resource_names.task_family}:*"]

    condition {
      test     = "StringEquals"
      variable = "ecs:CreateAction"
      values   = ["RegisterTaskDefinition"]
    }
  }

  statement {
    sid       = "DescribeTaskDef"
    effect    = "Allow"
    actions   = ["ecs:DescribeTaskDefinition"]
    resources = ["*"] # No resource-level support
  }

  statement {
    sid       = "DescribeOneService"
    effect    = "Allow"
    actions   = ["ecs:DescribeServices"]
    resources = ["${local.svc_arn["ecs"]}:service/${local.resource_names.ecs_cluster}/${local.resource_names.ecs_service}"]
  }

  statement {
    sid       = "UpdateOneService"
    effect    = "Allow"
    actions   = ["ecs:UpdateService"]
    resources = ["${local.svc_arn["ecs"]}:service/${local.resource_names.ecs_cluster}/${local.resource_names.ecs_service}"]

    condition {
      test     = "ArnLike"
      variable = "ecs:task-definition"
      values   = ["${local.svc_arn["ecs"]}:task-definition/${local.resource_names.task_family}:*"]
    }
  }

  statement {
    sid       = "PassTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.ecs_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
