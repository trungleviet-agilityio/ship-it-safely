# No thumbprint_list: AWS validates GitHub's TLS chain against its own trusted CAs (B11).
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
}

# One trust policy per role (B13): StringEquals except the plan role's pull request merge ref, immutable IDs,
# ref pinned on every role.
data "aws_iam_policy_document" "trust" {
  for_each = local.trust

  statement {
    sid     = "GitHubOidc"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = [each.value.sub]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_id"
      values   = [var.github_repo_id]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:repository_owner_id"
      values   = [var.github_owner_id]
    }

    condition {
      test     = each.value.ref_test
      variable = "${local.oidc_host}:ref"
      values   = [each.value.ref]
    }

    dynamic "condition" {
      for_each = each.value.workflows == null ? [] : [each.value.workflows]

      content {
        test     = "StringEquals"
        variable = "${local.oidc_host}:workflow"
        values   = condition.value
      }
    }
  }
}
