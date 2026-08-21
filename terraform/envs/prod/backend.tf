# Bucket terraform/bootstrap tarafından oluşturuldu.
#
# DynamoDB kilit tablosu YOK: Terraform 1.10+ ile gelen S3 native lockfile
# (use_lockfile) aynı işi tek kaynakla görüyor.
terraform {
  backend "s3" {
    bucket       = "mern-devops-case-tfstate-4673c1d7"
    key          = "prod/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}
