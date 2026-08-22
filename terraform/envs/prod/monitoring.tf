# Logging, monitoring ve alerting

locals {
  monitoring_namespace = "monitoring"
  monitoring_dir       = "${path.module}/../../../monitoring"

  # CRD plan bağımlılığını önlemek için kuralları chart values'a ekle.
  mern_alert_rules = yamldecode(file("${local.monitoring_dir}/alerts/mern-rules.yaml"))

  grafana_dashboards = fileset("${local.monitoring_dir}/dashboards", "*.json")
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = local.monitoring_namespace

    # node-exporter hostPath kullanır.
    labels = {
      name = local.monitoring_namespace
    }
  }

  depends_on = [module.eks]
}

# Grafana admin parolası

resource "random_password" "grafana_admin" {
  length  = 24
  special = false
}

resource "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana-admin"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  }

  type = "Opaque"
}

# kube-prometheus-stack

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  # CRD ve operator kurulumu varsayılan timeout'u aşabilir.
  timeout = 900

  values = concat(
    [
      file("${local.monitoring_dir}/kube-prometheus-stack.values.yaml"),

      # Prometheus alert kuralları.
      yamlencode({
        additionalPrometheusRulesMap = {
          mern = local.mern_alert_rules
        }
      }),
    ],

    # Webhook varsa Slack receiver ayarını ekle.
    var.slack_webhook_url == "" ? [] : [
      templatefile("${local.monitoring_dir}/alertmanager-slack.values.yaml.tftpl", {
        slack_webhook_url = var.slack_webhook_url
        slack_channel     = var.slack_channel
      })
    ],
  )

  depends_on = [
    kubernetes_secret_v1.grafana_admin,
    kubernetes_storage_class_v1.gp3,
  ]
}

# Loki

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.loki_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  timeout = 600

  values = [file("${local.monitoring_dir}/loki.values.yaml")]

  depends_on = [kubernetes_storage_class_v1.gp3]
}

# Grafana Alloy (log toplayıcı)

resource "helm_release" "alloy" {
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [file("${local.monitoring_dir}/alloy.values.yaml")]

  # Alloy'u Loki hazır olduktan sonra başlat.
  depends_on = [helm_release.loki]
}

# Grafana dashboard'ları
# Sidecar, repodaki dashboard'ları etiketli ConfigMap'lerden yükler.

resource "kubernetes_config_map_v1" "grafana_dashboards" {
  for_each = local.grafana_dashboards

  metadata {
    name      = "grafana-dashboard-${trimsuffix(each.value, ".json")}"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

    labels = {
      grafana_dashboard = "1"
    }

    annotations = {
      grafana_folder = "MERN DevOps Case"
    }
  }

  data = {
    (each.value) = file("${local.monitoring_dir}/dashboards/${each.value}")
  }

  depends_on = [helm_release.kube_prometheus_stack]
}
