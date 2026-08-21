variable "project" {
  description = "Kaynak adlarında ve etiketlerde kullanılan proje öneki."
  type        = string
  default     = "mern-devops-case"
}

variable "environment" {
  description = "Ortam adı."
  type        = string
  default     = "prod"
}

variable "region" {
  description = "AWS bölgesi."
  type        = string
  default     = "eu-central-1"
}

# --- Ağ ---------------------------------------------------------------------

variable "vpc_cidr" {
  description = "VPC CIDR bloğu."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Kullanılacak AZ sayısı. ALB en az 2 subnet ister."
  type        = number
  default     = 2
}

variable "single_nat_gateway" {
  description = <<-EOT
    true ise tek NAT Gateway kullanılır (~1.2 $/gün tasarruf).
    Bilinen sınır: o AZ düşerse private subnet'lerin internet çıkışı kesilir.
    Gerçek prod'da AZ başına bir NAT olmalıdır.
  EOT
  type        = bool
  default     = true
}

# --- EKS --------------------------------------------------------------------

variable "cluster_version" {
  description = <<-EOT
    Kubernetes minor sürümü.

    MALİYET UYARISI: standart destekten çıkmış bir sürüm seçilirse control plane
    ücreti 0.10 $/saat yerine 0.60 $/saat olur (6×) ve extended support yeni
    cluster'larda VARSAYILAN OLARAK AÇIKTIR. Değiştirmeden önce:
      aws eks describe-cluster-versions --region <bölge> \
        --query "clusterVersions[?clusterVersion=='<sürüm>'].status"
    çıktısı STANDARD_SUPPORT olmalıdır.

    1.34 seçildi: 2 Aralık 2026'ya kadar standart destekte ve addon/chart
    ekosisteminde en olgun sürüm.
  EOT
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = <<-EOT
    Node grubu instance tipi.

    Kota: eu-central-1 vCPU limiti 16 (başlangıçta 5'ti, artırıldı).
    3 × t3.medium = 6 vCPU kullanır, bolca marj kalır.

    Ölçülen kapasite (t3.medium): allocatable ~3.37 GiB bellek, max-pods 17.
    3 node ile ~10.1 GiB / 51 pod → monitoring + uygulama + HPA rahat sığar.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "node_desired_size" {
  description = "Node grubundaki istenen node sayısı."
  type        = number
  default     = 3
}

variable "node_min_size" {
  description = "Node grubu alt sınırı."
  type        = number
  default     = 3
}

variable "node_max_size" {
  description = <<-EOT
    Node grubu üst sınırı. Cluster Autoscaler kapsam dışı olduğu için bu değer
    kendiliğinden kullanılmaz; elle `terraform apply` ile büyütmek istenirse
    diye desired'ın bir üstünde bırakıldı. 4 × 2 = 8 vCPU, kota 16.
  EOT
  type        = number
  default     = 4
}

variable "node_disk_size" {
  description = "Node kök diski (GiB)."
  type        = number
  default     = 30
}

variable "cluster_public_access_cidrs" {
  description = <<-EOT
    Kubernetes API endpoint'ine erişebilecek CIDR'ler.
    Varsayılan 0.0.0.0/0'dır çünkü CI runner'larının IP'si sabit değil;
    gerçek yetki IAM + EKS access entry'lerinden gelir.
    Sabit IP'li bir ortamda mutlaka daraltılmalıdır.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- CI ---------------------------------------------------------------------

variable "github_repository" {
  description = "OWNER/REPO — GitHub Actions OIDC trust policy bununla kısıtlanır."
  type        = string
  default     = "tarikemre10/devops-case"
}

# --- Uygulama ---------------------------------------------------------------

variable "ecr_repositories" {
  description = "Oluşturulacak ECR repoları."
  type        = list(string)
  default     = ["mern-server", "mern-client", "mern-etl"]
}

variable "app_namespace" {
  description = "Uygulamanın çalışacağı Kubernetes namespace'i (Aşama 4)."
  type        = string
  default     = "mern"
}

variable "mongo_database" {
  description = <<-EOT
    Uygulama veritabanı adı. ATLAS_URI bundan üretilir; k8s ConfigMap'teki
    MONGO_DB ile AYNI olmalıdır (k8s/base/configmap.yaml).
  EOT
  type        = string
  default     = "sample_training"
}
