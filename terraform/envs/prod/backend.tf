# Bucket bootstrap stack'inden gelir; kilitleme S3 lockfile kullanır.
terraform {
  backend "s3" {
    bucket       = "mern-devops-case-tfstate-4673c1d7"
    key          = "prod/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
