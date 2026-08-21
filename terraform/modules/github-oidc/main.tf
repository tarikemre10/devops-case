# GitHub Actions için OIDC federated IAM rolü.
#
# Amaç: CI'da uzun ömürlü AWS_ACCESS_KEY_ID/SECRET secret'ı BULUNMASIN.
# GitHub'ın imzaladığı kısa ömürlü OIDC token'ı ile rol üstlenilir.

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

# Hesapta zaten bir GitHub OIDC provider'ı varsa onu kullan, yoksa oluştur.
# (Hesap başına yalnızca bir tane olabilir.)
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS Ağustos 2023'ten beri bu provider için sertifika zincirini kendi
  # doğruluyor; thumbprint artık işlevsel olarak kullanılmıyor ama alan
  # zorunlu olduğu için GitHub'ın kök thumbprint'i veriliyor.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    # Token'ın bize verildiğini doğrular.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # KRİTİK: bu koşul olmadan İNTERNETTEKİ HERHANGİ BİR GitHub reposu
    # bu rolü üstlenebilir. Erişim yalnızca kendi repomuza kısıtlanır.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for s in var.allowed_subjects : "repo:${var.github_repository}:${s}"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name = "${var.project}-github-actions"
  # AWS IAM description yalnızca ASCII + Latin-1 kabul eder
  # ([\u0009\u000A\u000D\u0020-\u007E\u00A1-\u00FF]); uzun tire (U+2014) reddedilir.
  description = "GitHub Actions OIDC role for ${var.github_repository}"

  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = 3600
}

# ECR: geniş `ecr:*` yerine push/pull için gereken dar liste.
data "aws_iam_policy_document" "ecr" {
  # GetAuthorizationToken kaynak bazlı kısıtlanamaz (API gereği "*").
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

# EKS: pipeline yalnızca kubeconfig üretebilmeli. Cluster üzerindeki gerçek
# yetki Kubernetes RBAC'ten (EKS access entry) gelir — IAM'den değil.
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
