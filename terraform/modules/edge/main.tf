# Özel domain olmadan HTTPS sağlayan CloudFront katmanı.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}

# Controller'ın oluşturduğu ALB'yi tag ile bul.
data "aws_lb" "ingress" {
  tags = {
    "elbv2.k8s.aws/cluster"    = var.cluster_name
    "ingress.k8s.aws/stack"    = var.ingress_stack
    "ingress.k8s.aws/resource" = "LoadBalancer"
  }
}

locals {
  origin_id = "alb-${var.cluster_name}"
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "${var.project} MERN application entry point"
  price_class     = "PriceClass_100" # yalnızca AB/KD Amerika edge'leri; en ucuz
  http_version    = "http2"
  is_ipv6_enabled = true

  origin {
    domain_name = data.aws_lb.ingress.dns_name
    origin_id   = local.origin_id

    custom_origin_config {
      http_port  = 80
      https_port = 443

      # TLS CloudFront'ta sonlanır.
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # ALB'nin doğruladığı origin başlığı.
    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_verify_secret
    }
  }

  # Statik SPA içeriği.
  default_cache_behavior {
    target_origin_id = local.origin_id

    # HTTP isteklerini HTTPS'e yönlendir.
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    # AWS yönetimli cache politikası.
    cache_policy_id          = data.aws_cloudfront_cache_policy.optimized.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  # API: tüm CRUD metotlarına izin ver, cache'i kapat.
  ordered_cache_behavior {
    path_pattern     = "/api/*"
    target_origin_id = local.origin_id

    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    cache_policy_id = data.aws_cloudfront_cache_policy.disabled.id

    # Host hariç viewer verilerini origin'e ilet.
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # CloudFront sertifikasını kullan.
  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }
}

# AWS yönetimli politikalar.

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}
