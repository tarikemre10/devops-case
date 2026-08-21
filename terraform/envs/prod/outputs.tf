output "cluster_name" {
  description = "EKS cluster adı."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint'i."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Çalışan Kubernetes sürümü."
  value       = module.eks.cluster_version
}

output "configure_kubectl" {
  description = "kubeconfig üretmek için çalıştırılacak komut."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "vpc_id" {
  description = "VPC kimliği (edge stack'i ALB'yi burada arar)."
  value       = module.vpc.vpc_id
}

output "ecr_repository_urls" {
  description = "Imaj push hedefleri."
  value       = module.ecr.repository_urls
}

output "ecr_registry_url" {
  description = "docker login hedefi."
  value       = module.ecr.registry_url
}

output "github_actions_role_arn" {
  description = "GitHub Actions'ta aws-actions/configure-aws-credentials adımına role-to-assume olarak verilir; workflow'da permissions.id-token: write gerekir."
  value       = module.github_oidc.role_arn
}

output "app_namespace" {
  description = "Aşama 4 manifestlerinin hedef namespace'i."
  value       = var.app_namespace
}

output "origin_verify_secret" {
  description = <<-EOT
    ALB'nin CloudFront dışındaki isteklere 403 dönmesini sağlayan paylaşılan
    değer. edge stack bunu remote_state ile okur; Ingress overlay'inde
    __ORIGIN_VERIFY__ yer tutucusuna `terraform output -raw` ile doldurulur.
  EOT
  value       = random_password.origin_verify.result
  sensitive   = true
}
