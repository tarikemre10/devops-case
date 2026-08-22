data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Deterministik ARN, EKS ile OIDC modülleri arasındaki döngüyü önler.
  eks_cluster_arn = "arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${local.name}"

  ci_username = "github-actions"

  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

# Ağ

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name = local.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true
  enable_dns_support   = true

  # ALB Controller subnet keşfi için gerekli.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# EKS

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = local.name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.cluster_public_access_cidrs
  cluster_endpoint_private_access      = true

  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # Kubernetes yetkisi aşağıdaki namespace-scoped Role ile verilir.
  access_entries = {
    github_actions = {
      principal_arn     = module.github_oidc.role_arn
      type              = "STANDARD"
      user_name         = local.ci_username
      kubernetes_groups = []
    }
  }

  enable_irsa = true

  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  # Control plane'in metrics-server'a erişimi.
  node_security_group_additional_rules = {
    metrics_server = {
      description                   = "Control plane to metrics-server"
      protocol                      = "tcp"
      from_port                     = 10251
      to_port                       = 10251
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  cloudwatch_log_group_retention_in_days = 1

  cluster_addons = {
    # VPC CNI NetworkPolicy enforcement.
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }

    kube-proxy = { most_recent = true }

    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
    }

    metrics-server = { most_recent = true }

    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Modül özel launch template kullandığı için disk burada tanımlanır.
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      credit_specification = {
        cpu_credits = "standard"
      }

      labels = {
        workload = "general"
      }
    }
  }
}

# IRSA rolleri

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name             = "${local.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.48"

  role_name                              = "${local.name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# gp3 StorageClass
resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"

    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  # Volume'u pod ile aynı AZ'de oluşturur.
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }

  depends_on = [module.eks]
}

# Tek bir default StorageClass bırak.
resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  force       = true

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [module.eks]
}

# AWS Load Balancer Controller
resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.10.1"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_controller_irsa.iam_role_arn
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [module.eks]
}

# Uygulama namespace'i ve secret'ları
resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = var.app_namespace

    labels = {
      name                                 = var.app_namespace
      "app.kubernetes.io/part-of"          = "mern"
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }

  depends_on = [module.eks]
}

# URI encoding gerektirmemesi için özel karakter kullanma.
resource "random_password" "mongo_root" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "mongo_credentials" {
  metadata {
    name      = "mongo-credentials"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  data = {
    MONGO_INITDB_ROOT_USERNAME = "root"
    MONGO_INITDB_ROOT_PASSWORD = random_password.mongo_root.result

    ATLAS_URI = format(
      "mongodb://root:%s@mongodb-0.mongodb.%s.svc.cluster.local:27017/%s?authSource=admin",
      random_password.mongo_root.result,
      var.app_namespace,
      var.mongo_database,
    )
  }

  type = "Opaque"
}

# Ingress ve CloudFront'un paylaştığı origin doğrulama değeri.
resource "random_password" "origin_verify" {
  length  = 32
  special = false
}

resource "kubernetes_secret_v1" "origin_verify" {
  metadata {
    name      = "origin-verify"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  data = {
    value = random_password.origin_verify.result
  }

  type = "Opaque"
}

# ECR

module "ecr" {
  source = "../../modules/ecr"

  project          = var.project
  repository_names = var.ecr_repositories
}

# GitHub Actions OIDC

module "github_oidc" {
  source = "../../modules/github-oidc"

  project           = var.project
  github_repository = var.github_repository

  github_repository_immutable = var.github_repository_immutable

  ecr_repository_arns = module.ecr.repository_arns

  eks_cluster_arn = local.eks_cluster_arn
}

# CI yalnız deployment ve CronJob imajlarını günceller.

resource "kubernetes_role_v1" "ci_deployer" {
  metadata {
    name      = "ci-deployer"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "patch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list"]
  }

  # ETL imaj güncellemesi (etl.yml).
  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs"]
    verbs      = ["get", "list", "patch"]
  }

  # etl.yml deploy sonrası CronJob'dan tek seferlik doğrulama Job'ı üretip siler.
  rule {
    api_groups = ["batch"]
    resources  = ["jobs"]
    verbs      = ["get", "list", "watch", "create", "delete"]
  }

  # Yalnızca hata ayıklama çıktısı için; hiçbir yazma fiili yok.
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "events"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_role_binding_v1" "ci_deployer" {
  metadata {
    name      = "ci-deployer"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.ci_deployer.metadata[0].name
  }

  # Access entry'deki user_name ile birebir aynı olmalı.
  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "User"
    name      = local.ci_username
  }
}
