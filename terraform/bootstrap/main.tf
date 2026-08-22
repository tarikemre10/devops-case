# Ana stack'in S3 state backend'ini oluşturur.

terraform {
  required_version = ">= 1.10"

  required_providers {
    # EKS modülünden bağımsız olduğu için provider 6.x kullanabilir.
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

# Global benzersiz bucket eki.
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.project}-tfstate-${random_id.suffix.hex}"
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # State bucket'ını kazara silmeye karşı koru.
  force_destroy = false
}

# State geri dönüşü için versioning.
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

# Tüm public erişimi engelle.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Eski state sürümlerini temizle.
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
