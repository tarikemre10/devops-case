# GitHub Actions için kısa ömürlü OIDC kimlik doğrulaması.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}

data "aws_caller_identity" "current" {}

# Hesaptaki GitHub OIDC provider'ını kullan veya oluştur.
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # Alan zorunlu olduğu için GitHub kök thumbprint'i verilir.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"

  # Klasik ve immutable GitHub repository subject biçimleri.
  repository_patterns = compact([
    var.github_repository,
    var.github_repository_immutable,
  ])

  allowed_sub_values = flatten([
    for repo in local.repository_patterns : [
      for subject in var.allowed_subjects : "repo:${repo}:${subject}"
    ]
  ])
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    # Token audience kontrolü.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Rolü yalnız belirtilen repo üstlenebilir.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.allowed_sub_values
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name = "${var.project}-github-actions"
  # IAM description ASCII tutulur.
  description = "GitHub Actions OIDC role for ${var.github_repository}"

  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = 3600
}

# ECR push/pull izinleri.
data "aws_iam_policy_document" "ecr" {
  # GetAuthorizationToken kaynak bazlı kısıtlanamaz.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr" {
  name   = "ecr-push"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.ecr.json
}

# EKS erişiminin geri kalanı Kubernetes RBAC ile sınırlandırılır.
data "aws_iam_policy_document" "eks" {
  statement {
    sid       = "EksDescribe"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [var.eks_cluster_arn]
  }
}

resource "aws_iam_role_policy" "eks" {
  name   = "eks-describe"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.eks.json
}
