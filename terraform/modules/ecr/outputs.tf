output "repository_urls" {
  description = "docker push için kullanılacak repo URL'leri (kısa ad -> URL)."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "CI'ın push izni bu ARN'lerle sınırlanır."
  value       = [for v in aws_ecr_repository.this : v.arn]
}

output "registry_url" {
  description = "Hesabın ECR registry adresi (docker login hedefi)."
  value       = length(aws_ecr_repository.this) > 0 ? split("/", values(aws_ecr_repository.this)[0].repository_url)[0] : ""
}
