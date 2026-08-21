# CloudFront stack'i — ANA STACK'TEN VE AŞAMA 4'TEN SONRA uygulanır.
#
# Sıra:
#   1. envs/prod apply        → VPC, EKS, ECR, IAM
#   2. k8s manifestleri apply → Ingress, ALB Controller ALB'yi yaratır
#   3. BURASI apply           → CloudFront, ALB'yi tag ile bulup önüne geçer
#
# 2. adım atlanırsa `data "aws_lb"` eşleşme bulamaz ve plan hata verir.
# Bu kasıtlıdır: sessizce yanlış bir origin'e bağlanmaktansa açıkça durur.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }

  backend "s3" {
    bucket       = "mern-devops-case-tfstate-4673c1d7"
    key          = "edge/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = var.project
      Environment = "prod"
      ManagedBy   = "terraform"
      Stack       = "edge"
    }
  }
}

# Ana stack'in çıktıları okunur; cluster adı elle yazılmaz.
data "terraform_remote_state" "prod" {
  backend = "s3"

  config = {
    bucket = "mern-devops-case-tfstate-4673c1d7"
    key    = "prod/terraform.tfstate"
    region = var.region
  }
}

# ALB'nin yalnızca CloudFront'tan istek kabul ettiğini doğrulamak için
# paylaşılan gizli değer ANA STACK'TE üretilir ve buradan okunur.
# Sebep: aynı değeri Ingress annotation'ı da (Aşama 4, edge'den ÖNCE apply
# edilir) kullanmak zorunda. Burada üretilseydi ALB kuralı henüz var olmayan
# bir değere bağlanacaktı.
module "edge" {
  source = "../../modules/edge"

  project              = var.project
  cluster_name         = data.terraform_remote_state.prod.outputs.cluster_name
  ingress_stack        = var.ingress_stack
  origin_verify_secret = data.terraform_remote_state.prod.outputs.origin_verify_secret
}
