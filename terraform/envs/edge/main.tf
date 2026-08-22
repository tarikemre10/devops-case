# Ingress ALB'yi oluşturduktan sonra uygulanan CloudFront stack'i.

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

# Ana stack çıktılarını kullan.
data "terraform_remote_state" "prod" {
  backend = "s3"

  config = {
    bucket = "mern-devops-case-tfstate-4673c1d7"
    key    = "prod/terraform.tfstate"
    region = var.region
  }
}

# Ingress ile paylaşılan origin doğrulama değerini ana stack'ten oku.
module "edge" {
  source = "../../modules/edge"

  project              = var.project
  cluster_name         = data.terraform_remote_state.prod.outputs.cluster_name
  ingress_stack        = var.ingress_stack
  origin_verify_secret = data.terraform_remote_state.prod.outputs.origin_verify_secret
}
