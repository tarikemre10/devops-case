output "app_url" {
  description = "Uygulamanın public HTTPS adresi — teslim ekran görüntülerinde bu görünmeli."
  value       = module.edge.url
}

output "distribution_id" {
  value = module.edge.distribution_id
}
