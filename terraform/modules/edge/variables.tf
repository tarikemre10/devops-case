variable "project" {
  description = "Distribution açıklamasında kullanılır."
  type        = string
}

variable "cluster_name" {
  description = "ALB'yi tag üzerinden bulmak için EKS cluster adı."
  type        = string
}

variable "ingress_stack" {
  description = <<-EOT
    ALB Controller'ın Ingress'e koyduğu stack tag'i: "<namespace>/<ingress-adı>".
    Örn. "mern/mern-ingress".
  EOT
  type        = string
}

variable "origin_verify_secret" {
  description = "CloudFront'un origin'e eklediği paylaşılan gizli başlık değeri."
  type        = string
  sensitive   = true
}
