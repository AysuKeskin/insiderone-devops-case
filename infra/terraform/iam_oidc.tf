data "aws_caller_identity" "current" {}

data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "gha_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restrict to this repo's main branch and v* tags only. No PR workflows
    # can assume this role. Both subject shapes are listed: GitHub now issues
    # the ID-bearing form (owner@id/repo@id), which survives a repo rename,
    # but the plain form is kept so a rollback on their side doesn't break
    # deploys.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/tags/v*",
        "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:ref:refs/heads/main",
        "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}:ref:refs/tags/v*",
      ]
    }
  }
}

resource "aws_iam_role" "gha_deploy" {
  name               = "gha-deploy-${var.github_repo}"
  assume_role_policy = data.aws_iam_policy_document.gha_deploy_trust.json
}

# Permissions: just enough to run a helm upgrade on the EC2 box via SSM
# Send-Command, and to poll the command result. Scoped to this one instance.
data "aws_iam_policy_document" "gha_deploy_perms" {
  statement {
    sid     = "RunHelmUpgradeViaSSM"
    effect  = "Allow"
    actions = ["ssm:SendCommand"]
    resources = [
      aws_instance.app.arn,
      "arn:aws:ssm:${var.region}::document/AWS-RunShellScript",
    ]
  }

  statement {
    sid       = "PollSSMCommandResult"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gha_deploy" {
  name   = "ssm-send-command"
  role   = aws_iam_role.gha_deploy.id
  policy = data.aws_iam_policy_document.gha_deploy_perms.json
}
