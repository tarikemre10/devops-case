# Remote state altyapısı — tavuk-yumurta sorununun çözümü.
#
# Bu stack YEREL state ile bir kez uygulanır; ürettiği S3 bucket'ı ana stack'in
# (envs/prod) backend'i olur. Kendi state'i git'e girmez.
#
#   terraform init && terraform apply
#
# NOT: DynamoDB kilit tablosu YOK. Terraform 1.10+ ile gelen S3 native lockfile
# (`use_lockfile = true`) aynı işi görüyor — bir kaynak, bir maliyet kalemi ve
# bir hata yüzeyi eksik.

terraform {
  required_version = ">= 1.10"

  required_providers {
    # Bu stack bilinçli olarak AWS provider 6.x kullanır; ana stack (envs/prod)
    # 5.x'te kalır. Sebep: terraform-aws-modules/eks v20 henüz provider 6'yı
    # desteklemiyor (`< 6.0.0` kısıtı). Bootstrap yalnızca S3 kaynakları
    # yönettiği ve tamamen ayrı bir state'e sahip olduğu için bu ayrışma
    # sorun değil; ana stack EKS modülü v21'e geçtiğinde ikisi hizalanır.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = "shared"
      ManagedBy   = "terraform"
      Stack       = "bootstrap"
    }
  }
}

# Bucket adları global olarak benzersiz olmalı.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.project}-tfstate-${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # State bucket'ı kazara silinmemeli. Teslim sonrası temizlik için önce
  # ana stack destroy edilir, sonra bu değer true yapılıp bucket silinir.
  force_destroy = false
}

# Yanlış bir apply'dan sonra state'i geri alabilmenin tek yolu versioning.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State dosyası düz metin secret içerebilir; herkese açık olması felaket olur.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Eski state sürümleri sonsuza kadar birikmesin.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
