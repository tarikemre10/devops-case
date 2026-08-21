# Uygulama imajları için ECR repoları.

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name = "${var.project}/${each.value}"

  # IMMUTABLE: imajlar commit SHA ile etiketleniyor, aynı tag'in üzerine
  # yazılması bir hatadır. Bu ayar "deploy ettiğim imaj hâlâ aynı mı?"
  # sorusunu anlamsız kılar.
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  # Case teslimi sonrası `terraform destroy` içinde imaj kalmış repo yüzünden
  # takılmasın diye. Gerçek prod'da false olurdu.
  force_delete = var.force_delete
}

# Eski imajlar süresiz birikirse depolama ücreti sessizce büyür.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each = aws_ecr_repository.this

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Etiketsiz imajları 1 gün sonra sil"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Son ${var.keep_last_images} imaj dışındakileri sil"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_last_images
        }
        action = { type = "expire" }
      },
    ]
  })
}
