data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  name = "${var.project}-${var.environment}"
  azs  = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # EKS cluster ARN'i module.eks ÇIKTISINDAN DEĞİL, adından kuruluyor.
  #
  # Neden: github_oidc modülü DescribeCluster izni için cluster ARN'ine,
  # module.eks ise access entry için github_oidc'nin rol ARN'ine ihtiyaç duyar.
  # İkisi de birbirinin output'unu okursa Terraform "Cycle" hatası verir.
  # ARN tamamen deterministik (bölge + hesap + cluster adı) olduğu için onu
  # elde kurup bağımlılığı tek yöne (eks → github_oidc) çeviriyoruz.
  eks_cluster_arn = "arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/${local.name}"

  # Access entry'nin cluster içinde göründüğü Kubernetes kullanıcı adı.
  # Açıkça sabitleniyor ki aşağıdaki RoleBinding'in subject'i deterministik olsun
  # (varsayılanda AWS rol ARN'inden türetilmiş bir isim üretir).
  ci_username = "github-actions"

  # /20 bloklar: private 10.0.0.0/20, 10.0.16.0/20 · public 10.0.128.0/20, ...
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]
}

# ---------------------------------------------------------------------------
# Ağ
# ---------------------------------------------------------------------------

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

  # Bu tag'ler olmadan AWS Load Balancer Controller ALB'yi hangi subnet'lere
  # koyacağını bulamaz ve Ingress sessizce ADDRESS'siz kalır.
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ---------------------------------------------------------------------------
# EKS
# ---------------------------------------------------------------------------

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

  # EKS artık aws-auth ConfigMap yerine Access Entry API'sini kullanıyor.
  # Bu satır olmadan cluster'ı yaratan kimlik bile kubectl ile bağlanamaz.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # Aşama 5: CI'ın cluster'a bağlanabilmesi için access entry.
  #
  # IAM izni Kubernetes yetkisi DEĞİLDİR: rolün eks:DescribeCluster izni var,
  # yani `aws eks update-kubeconfig` çalışır — ama access entry olmadan her
  # kubectl çağrısı "Unauthorized" döner.
  #
  # policy_associations BİLEREK BOŞ: hazır AmazonEKSClusterAdminPolicy cluster
  # geneli admin verirdi. Yetki tamamen aşağıdaki namespace-scoped Role'den
  # gelir (kubernetes_role_v1.ci_deployer).
  access_entries = {
    github_actions = {
      principal_arn     = module.github_oidc.role_arn
      type              = "STANDARD"
      user_name         = local.ci_username
      kubernetes_groups = []
    }
  }

  # IRSA: pod başına IAM rolü. EBS CSI ve ALB Controller buna dayanıyor.
  enable_irsa = true

  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  # metrics-server addon'ı pod'unu 10251'de servis ediyor, ama modülün
  # varsayılan node güvenlik grubu kuralları control plane'den yalnızca
  # 443 ve 10250'ye (kubelet) izin veriyor. Bu kural olmadan Kubernetes API
  # aggregation layer metrics-server'a ulaşamaz; APIService
  # "FailedDiscoveryCheck" verir, `kubectl top` çalışmaz ve HPA metrik
  # bulamadığı için ölçekleme yapmaz. Pod'lar Running göründüğü için
  # sorunun kaynağı ilk bakışta belli olmaz.
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

  # Case bittiğinde destroy'u kolaylaştırır; log grubu 1 gün sonra silinir.
  cloudwatch_log_group_retention_in_days = 1

  cluster_addons = {
    # DİKKAT: VPC CNI, NetworkPolicy nesnelerini yalnızca bu bayrak açıkken
    # uygular. Kapalıyken `kubectl apply` policy'yi kabul eder, kaynak
    # Kubernetes'te görünür ama HİÇBİR trafiği engellemez — yanlış bir
    # güvenlik hissi verir. Aşama 4'ün default-deny politikası buna bağlı.
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }

    kube-proxy = { most_recent = true }

    # coredns node'lar hazır olmadan kurulamaz.
    coredns = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
    }

    # HPA'nın çalışması için gerekli. AWS bunu artık yönetilen addon olarak
    # sunuyor, ayrı Helm chart'a gerek yok.
    metrics-server = { most_recent = true }

    # KRİTİK: bu addon ve IRSA rolü olmadan MongoDB'nin PVC'si kalıcı olarak
    # Pending'de kalır ve StatefulSet hiç açılmaz (Aşama 4 tamamen durur).
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

      # DİKKAT: modül özel launch template kullandığı için node group üzerindeki
      # `disk_size` alanı YOK SAYILIR — disk boyutu launch template'in block
      # device mapping'inden gelir. Varsayılan 20 GiB; kube-prometheus-stack,
      # Loki ve uygulama imajları çekilince DiskPressure'a girip pod tahliyesi
      # başlatabilir, bu yüzden açıkça büyütülüyor.
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

      # "standard": burst kredisi bitince throttle olur ama sürpriz fatura
      # gelmez. "unlimited" 3 günlük bir demoda gereksiz risk.
      credit_specification = {
        cpu_credits = "standard"
      }

      labels = {
        workload = "general"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# IRSA rolleri
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# gp3 StorageClass
# ---------------------------------------------------------------------------

# EKS varsayılanı gp2'dir. gp3 daha ucuz ve daha hızlıdır; ayrıca MongoDB
# StatefulSet'i bu sınıfı adıyla istiyor.
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

  # WaitForFirstConsumer: volume, pod'un hangi AZ'ye düştüğü belli olduktan
  # sonra yaratılır. Immediate olsaydı volume yanlış AZ'de doğar ve pod
  # kalıcı olarak Pending kalırdı.
  volume_binding_mode = "WaitForFirstConsumer"

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }

  depends_on = [module.eks]
}

# Varsayılan gp2 sınıfının "default" işaretini kaldır — iki default sınıf
# olursa Kubernetes hangisini seçeceğini bilemez.
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

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller
# ---------------------------------------------------------------------------

# Aşama 4'teki Ingress kaynağının ALB üretmesini bu controller sağlar.
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

  # IRSA: controller AWS API'lerine node role'ü ile değil, kendi dar
  # yetkili rolüyle erişir.
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

# ---------------------------------------------------------------------------
# Uygulama namespace'i ve secret'ları (ADR 10)
# ---------------------------------------------------------------------------

# Namespace'i Terraform sahiplenir; k8s/base içinde namespace.yaml YOKTUR.
# İki taraf da yaratmaya kalkarsa kustomize apply'ı sahiplik uyarısı verir.
resource "kubernetes_namespace_v1" "app" {
  metadata {
    name = var.app_namespace

    # NetworkPolicy'lerin namespaceSelector'ı ve Aşama 6'daki monitoring
    # seçicileri bu label'a bakar.
    labels = {
      name                                 = var.app_namespace
      "app.kubernetes.io/part-of"          = "mern"
      "pod-security.kubernetes.io/enforce" = "restricted"
    }
  }

  depends_on = [module.eks]
}

# special = false bilinçli: parola connection string'in içine gömülüyor,
# özel karakterler URL-encode edilmek zorunda kalır ve sessiz auth
# hatalarına yol açar.
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

    # Backend hazır bağlantı dizesini alır; parolayı kendisi birleştirmez.
    # StatefulSet'in tek pod'una headless Service üzerinden FQDN ile gidilir.
    ATLAS_URI = format(
      "mongodb://root:%s@mongodb-0.mongodb.%s.svc.cluster.local:27017/%s?authSource=admin",
      random_password.mongo_root.result,
      var.app_namespace,
      var.mongo_database,
    )
  }

  type = "Opaque"
}

# ALB'nin yalnızca CloudFront'tan gelen isteği kabul etmesi için paylaşılan
# gizli değer. edge stack'te değil BURADA üretilir: hem Ingress annotation'ı
# (Aşama 4) hem CloudFront origin header'ı (edge) aynı değere ihtiyaç duyar
# ve edge daha sonra apply edildiği için üretimi orada bırakmak yumurta-tavuk
# yaratırdı. edge onu terraform_remote_state ile okur.
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

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

module "ecr" {
  source = "../../modules/ecr"

  project          = var.project
  repository_names = var.ecr_repositories
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC
# ---------------------------------------------------------------------------

module "github_oidc" {
  source = "../../modules/github-oidc"

  project           = var.project
  github_repository = var.github_repository

  ecr_repository_arns = module.ecr.repository_arns

  # module.eks.cluster_arn DEĞİL: bkz. locals.eks_cluster_arn (döngü kırma).
  eks_cluster_arn = local.eks_cluster_arn
}

# ---------------------------------------------------------------------------
# CI'ın cluster yetkisi (Aşama 5)
# ---------------------------------------------------------------------------
#
# Pipeline cluster'da yalnızca IMAJ TAG'İ değiştirir (`kubectl set image` ve
# CronJob patch'i); tam `kubectl apply -k` yapmaz. Bu yüzden ne Secret, ne
# Ingress, ne StatefulSet, ne de herhangi bir cluster-scope kaynak için yetkisi
# vardır. Manifest YAPISI değişirse dağıtım elle apply edilir (README).

resource "kubernetes_role_v1" "ci_deployer" {
  metadata {
    name      = "ci-deployer"
    namespace = kubernetes_namespace_v1.app.metadata[0].name
  }

  # `kubectl set image` + `rollout status` + `rollout undo`
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "patch"]
  }

  # rollout status/undo revizyon geçmişini ReplicaSet'lerden okur.
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
