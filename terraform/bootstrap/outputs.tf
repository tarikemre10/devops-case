output "state_bucket" {
  description = "Ana stack'in backend.tf dosyasına yazılacak bucket adı."
  value       = aws_s3_bucket.state.id
}

output "backend_config" {
  description = "envs/prod/backend.tf içine kopyalanacak hazır yapılandırma."
  value       = <<-EOT
    terraform {
      backend "s3" {
        bucket       = "${aws_s3_bucket.state.id}"
        key          = "prod/terraform.tfstate"
        region       = "${var.region}"
        encrypt      = true
        use_lockfile = true
      }
    }
  EOT
}
