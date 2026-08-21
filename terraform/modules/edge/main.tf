# CloudFront — HTTPS giriş noktası.
#
# NEDEN CLOUDFRONT: kayıtlı bir domain yok, dolayısıyla Route53 + ACM ile
# sertifika alınamıyor. CloudFront ücretsiz ve geçerli bir *.cloudfront.net
# sertifikası verir; case'in "public URL üzerinden erişilebilir sistem"
# beklentisi domain satın almadan, tarayıcı uyarısı olmadan karşılanır.
#
# SIRA UYARISI: bu stack ana stack'ten SONRA, Aşama 4'teki Ingress uygulanıp
# ALB gerçekten yaratıldıktan sonra apply edilir. Origin'i bir data source ile
# bulur; ALB yoksa plan hata verir.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}

# ALB'yi Terraform yaratmaz — AWS Load Balancer Controller, Ingress kaynağına
# bakarak yaratır. Bu yüzden tag üzerinden bulunur.
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

      # ALB'ye HTTP ile gidilir: TLS CloudFront'ta sonlanır, ALB'de sertifika
      # yok (domain olmadığı için olamaz da). Bağlantı AWS omurgası içinde
      # kalır ve ALB Security Group'u yalnız CloudFront prefix list'ine açıktır.
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    # Origin'in gerçekten CloudFront'tan geldiğini ALB tarafında da
    # doğrulayabilmek için paylaşılan gizli başlık.
    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_verify_secret
    }
  }

  # --- Varsayılan davranış: statik SPA içeriği ---
  default_cache_behavior {
    target_origin_id = local.origin_id

    # Case'in "HTTP→HTTPS yönlendirme" maddesi.
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    # AWS yönetimli politikalar (elle cache ayarı yazmaktan daha güvenli):
    cache_policy_id          = data.aws_cloudfront_cache_policy.optimized.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  # --- /api/*: cache KAPALI ---
  #
  # Bu blok olmadan uygulama BOZULUR:
  #   1. Varsayılan behavior yalnız GET/HEAD/OPTIONS'a izin verir → kayıt
  #      oluşturma (POST), güncelleme (PATCH) ve silme (DELETE) 403 alır.
  #   2. Cache açık kalırsa GET /api/record bayat veri döndürür; yeni eklenen
  #      kayıt listede görünmez.
  ordered_cache_behavior {
    path_pattern     = "/api/*"
    target_origin_id = local.origin_id

    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]
    compress        = true

    cache_policy_id = data.aws_cloudfront_cache_policy.disabled.id

    # AllViewerExceptHostHeader: Host başlığı hariç her şey origin'e iletilir.
    # Host iletilseydi ALB kendi adını değil CloudFront adını görür ve
    # yönlendirme kuralları şaşardı.
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # Domain olmadığı için CloudFront'un kendi sertifikası kullanılır.
  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }
}

# --- AWS yönetimli politikalar ---------------------------------------------

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}
