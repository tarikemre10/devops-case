output "domain_name" {
  description = "Uygulamanın public HTTPS adresi. Ekran görüntülerinde bu görünmeli."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "url" {
  description = "Tarayıcıya yapıştırılabilir tam URL."
  value       = "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "distribution_id" {
  description = "Cache invalidation için distribution kimliği."
  value       = aws_cloudfront_distribution.this.id
}
