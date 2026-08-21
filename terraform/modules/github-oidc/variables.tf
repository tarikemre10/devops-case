variable "project" {
  description = "Rol adı öneki."
  type        = string
}

variable "github_repository" {
  description = "OWNER/REPO biçiminde GitHub deposu. Trust policy bununla kısıtlanır."
  type        = string

  validation {
    condition     = can(regex("^[^/]+/[^/]+$", var.github_repository))
    error_message = "github_repository OWNER/REPO biçiminde olmalı (örn. tarikemre10/devops-case)."
  }
}

variable "github_repository_immutable" {
  description = <<-EOT
    GitHub'ın OIDC token'ında kullandığı IMMUTABLE ID biçimi:
    OWNER@<owner_id>/REPO@<repo_id> (örn. tarikemre10@102986030/devops-case@1341157652).

    GitHub, `sub` claim'ini bu biçimde üretmeye başladı; klasik OWNER/REPO
    kalıbıyla yazılmış trust policy'ler sessizce eşleşmiyor ve
    "Not authorized to perform sts:AssumeRoleWithWebIdentity" hatası veriyor.

    Değeri bulmak için başarısız çağrının CloudTrail kaydına bakın:
      aws cloudtrail lookup-events \
        --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
        --query 'Events[0].CloudTrailEvent'
    userIdentity.userName alanı tam `sub` değerini içerir.

    Boş bırakılırsa yalnızca klasik biçim kabul edilir.
  EOT
  type        = string
  default     = ""
}

variable "allowed_subjects" {
  description = <<-EOT
    Rolü üstlenebilecek GitHub context'leri (repo: öneki olmadan).
    Varsayılan tüm dallar/PR'lar içindir; daraltmak için örneğin
    ["ref:refs/heads/main", "environment:prod"] verilebilir.
  EOT
  type        = list(string)
  default     = ["*"]
}

variable "create_oidc_provider" {
  description = "GitHub OIDC provider'ı bu stack oluştursun mu. Hesapta zaten varsa false yapın."
  type        = bool
  default     = true
}

variable "ecr_repository_arns" {
  description = "Push izni verilecek ECR repo ARN'leri."
  type        = list(string)
}

variable "eks_cluster_arn" {
  description = "DescribeCluster izni verilecek cluster ARN'i."
  type        = string
}
