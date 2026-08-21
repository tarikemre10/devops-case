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
