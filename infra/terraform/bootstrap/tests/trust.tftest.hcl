# OIDC trust: exact subjects, StringEquals only, immutable IDs, ref pin on apply and deploy (B12, B13).
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
  aws_account_id  = "123456789012"
  github_owner_id = "111"
  github_repo_id  = "222"
  budget_email    = "ops@example.com"
}

run "subjects_use_immutable_ids" {
  command = plan

  assert {
    condition     = local.gh_sub_prefix == "repo:trungleviet-agilityio@111/ship-it-safely@222"
    error_message = "gh_sub_prefix must carry the owner and repo IDs"
  }

  assert {
    condition = flatten([
      for c in data.aws_iam_policy_document.trust["plan"].statement[0].condition : c.values
      if c.variable == "token.actions.githubusercontent.com:sub"
    ]) == ["repo:trungleviet-agilityio@111/ship-it-safely@222:pull_request"]
    error_message = "plan role sub must be the pull_request subject"
  }

  assert {
    condition = alltrue([
      for k in ["apply", "deploy"] : flatten([
        for c in data.aws_iam_policy_document.trust[k].statement[0].condition : c.values
        if c.variable == "token.actions.githubusercontent.com:sub"
      ]) == ["repo:trungleviet-agilityio@111/ship-it-safely@222:environment:dev"]
    ])
    error_message = "apply and deploy subs must end with :environment:dev"
  }
}

run "conditions_are_exact" {
  command = plan

  assert {
    condition = alltrue([
      for k, d in data.aws_iam_policy_document.trust :
      alltrue([for c in d.statement[0].condition : c.test == "StringEquals"])
    ])
    error_message = "every trust condition must use StringEquals"
  }

  assert {
    condition = alltrue([
      for k, d in data.aws_iam_policy_document.trust : flatten([
        for c in d.statement[0].condition : c.values
        if c.variable == "token.actions.githubusercontent.com:aud"
      ]) == ["sts.amazonaws.com"]
    ])
    error_message = "aud must be sts.amazonaws.com"
  }

  assert {
    condition = alltrue([
      for k, d in data.aws_iam_policy_document.trust : (
        flatten([for c in d.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:repository_id"]) == ["222"]
        && flatten([for c in d.statement[0].condition : c.values if c.variable == "token.actions.githubusercontent.com:repository_owner_id"]) == ["111"]
      )
    ])
    error_message = "repository_id and repository_owner_id must be pinned on every role"
  }

  assert {
    condition = alltrue([
      for k, d in data.aws_iam_policy_document.trust :
      alltrue([for a in d.statement[0].actions : a == "sts:AssumeRoleWithWebIdentity"])
    ])
    error_message = "only sts:AssumeRoleWithWebIdentity may be allowed"
  }
}

run "ref_pinned_on_apply_and_deploy_only" {
  command = plan

  assert {
    condition = alltrue([
      for k in ["apply", "deploy"] : flatten([
        for c in data.aws_iam_policy_document.trust[k].statement[0].condition : c.values
        if c.variable == "token.actions.githubusercontent.com:ref"
      ]) == ["refs/heads/main"]
    ])
    error_message = "apply and deploy must pin ref to refs/heads/main"
  }

  assert {
    condition = length([
      for c in data.aws_iam_policy_document.trust["plan"].statement[0].condition : c
      if c.variable == "token.actions.githubusercontent.com:ref"
    ]) == 0
    error_message = "plan must not pin ref (varies per PR)"
  }
}

run "no_wildcards_and_session_duration" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for k, d in data.aws_iam_policy_document.trust : [
        for c in d.statement[0].condition : [
          for v in c.values : !strcontains(v, "*")
        ] if c.variable == "token.actions.githubusercontent.com:sub"
      ]
    ]))
    error_message = "no sub value may contain a wildcard"
  }

  assert {
    condition = (
      aws_iam_role.plan.max_session_duration == 3600
      && aws_iam_role.apply.max_session_duration == 3600
      && aws_iam_role.deploy.max_session_duration == 3600
      && aws_iam_role.plan.name == "sis-dev-gha-plan"
      && aws_iam_role.apply.name == "sis-dev-gha-apply"
      && aws_iam_role.deploy.name == "sis-dev-gha-deploy"
    )
    error_message = "roles need max_session_duration 3600 and the contract names"
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github.url == "https://token.actions.githubusercontent.com" && aws_iam_openid_connect_provider.github.client_id_list == toset(["sts.amazonaws.com"])
    error_message = "OIDC provider url and client id"
  }
}

run "name_based_subject_fallback" {
  command = plan

  variables {
    github_immutable_subject = false
  }

  assert {
    condition     = local.gh_sub_prefix == "repo:trungleviet-agilityio/ship-it-safely"
    error_message = "fallback prefix must use names"
  }
}
