# Explicit denies shared by plan, apply and deploy (B16). Action wildcards appear only in Deny statements.
data "aws_iam_policy_document" "guardrails" {
  statement {
    sid    = "G1DenySecretValues"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:BatchGetSecretValue",
      "secretsmanager:PutSecretValue",
      "secretsmanager:UpdateSecretVersionStage",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "G2DenySsmParameterReads"
    effect    = "Deny"
    actions   = ["ssm:GetParameter*"] # Deny only: covers all four read APIs
    resources = ["*"]
  }

  statement {
    sid       = "G3DenyRoleChaining"
    effect    = "Deny"
    actions   = ["sts:AssumeRole"]
    resources = ["*"]
  }

  statement {
    sid    = "G4DenyBootstrapIamWrites"
    effect = "Deny"
    actions = [
      "iam:Create*",
      "iam:Put*",
      "iam:Update*",
      "iam:Delete*",
      "iam:Attach*",
      "iam:Detach*",
      "iam:Add*",
      "iam:Remove*",
      "iam:Tag*",
      "iam:Untag*",
      "iam:*PermissionsBoundary",
      "iam:*PolicyVersion",
    ]
    resources = [
      "${local.iam_arn}:role/${local.name}-gha-*",
      "${local.iam_arn}:policy/${local.name}-gha-*",
      local.boundary_arn,
      "${local.iam_arn}:oidc-provider/*",
    ]
  }

  statement {
    sid    = "G5DenyBootstrapState"
    effect = "Deny"
    actions = [
      "s3:GetObject*",
      "s3:PutObject*",
      "s3:DeleteObject*",
    ]
    resources = [local.bootstrap_arn]
  }
}

resource "aws_iam_policy" "guardrails" {
  name        = local.guardrails_name
  description = "Explicit denies attached to every GitHub Actions role"
  policy      = data.aws_iam_policy_document.guardrails.json
}

resource "aws_iam_role_policy_attachment" "guardrails" {
  for_each = {
    plan   = aws_iam_role.plan.name
    apply  = aws_iam_role.apply.name
    deploy = aws_iam_role.deploy.name
  }

  role       = each.value
  policy_arn = aws_iam_policy.guardrails.arn
}
