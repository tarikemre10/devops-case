# ---------------------------------------------------------------------------
# Aşama 6 — Logging, Monitoring, Alerting
# ---------------------------------------------------------------------------
#
# Yığın: kube-prometheus-stack (metrik + alert + Grafana) · Loki (log deposu) ·
# Grafana Alloy (log toplayıcı). Üç chart da BU stack'te kurulur, ALB
# Controller ile aynı desende (helm_release), böylece tek `terraform apply`
# her şeyi ayağa kaldırır ve `destroy` temiz olur.
#
# Values dosyaları repo kökündeki monitoring/ klasöründedir; buraya gömülmez ki
# `helm upgrade -f` ile elle debug edilebilsinler.

locals {
  monitoring_namespace = "monitoring"
  monitoring_dir       = "${path.module}/../../../monitoring"

  # Alert kuralları YAML olarak repoda durur; buradan chart'ın
  # additionalPrometheusRulesMap değerine gömülür.
  #
  # kubernetes_manifest KULLANILMIYOR: PrometheusRule CRD'si aynı apply'da
  # kuruluyor, o kaynak ise plan aşamasında CRD şemasını API'den okumak
  # zorunda — CRD henüz yokken plan patlar.
  mern_alert_rules = yamldecode(file("${local.monitoring_dir}/alerts/mern-rules.yaml"))

  grafana_dashboards = fileset("${local.monitoring_dir}/dashboards", "*.json")
}

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = local.monitoring_namespace

    # DİKKAT: app namespace'inden farklı olarak burada
    # pod-security.kubernetes.io/enforce=restricted YOKTUR.
    # node-exporter hostPath + hostNetwork kullanır; `restricted` altında
    # admission tarafından reddedilir ve DaemonSet hiç açılmaz.
    labels = {
      name = local.monitoring_namespace
    }
  }

  depends_on = [module.eks]
}

# ---------------------------------------------------------------------------
# Grafana admin parolası
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# kube-prometheus-stack
# ---------------------------------------------------------------------------

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.kube_prometheus_stack_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  # CRD kurulumu + operator + Prometheus StatefulSet'i birlikte 8-10 dakika
  # sürebilir; varsayılan 300s bu chart için yetmez.
  timeout = 900

  values = concat(
    [
      file("${local.monitoring_dir}/kube-prometheus-stack.values.yaml"),

      # Alert kuralları (monitoring/alerts/mern-rules.yaml).
      yamlencode({
        additionalPrometheusRulesMap = {
          mern = local.mern_alert_rules
        }
      }),
    ],

    # Slack webhook verilmediyse yığın "null" receiver ile çalışır (kanıt
    # Alertmanager UI'daki firing listesi). Değişken doldurulursa bu ikinci
    # doküman varsayılan alertmanager.config'in üzerine biner.
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

# ---------------------------------------------------------------------------
# Loki
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Grafana Alloy (log toplayıcı)
# ---------------------------------------------------------------------------

resource "helm_release" "alloy" {
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.alloy_version
  namespace  = kubernetes_namespace_v1.monitoring.metadata[0].name

  values = [file("${local.monitoring_dir}/alloy.values.yaml")]

  # Loki'nin Service'i hazır olmadan Alloy push'ları hata verir (kalıcı sorun
  # değil ama gereksiz gürültü).
  depends_on = [helm_release.loki]
}

# ---------------------------------------------------------------------------
# Grafana dashboard'ları
# ---------------------------------------------------------------------------
#
# Dashboard'lar çalışma anında grafana.com'dan İNDİRİLMEZ: dış kaynağa ve
# değişen dashboard şemasına bağımlı olurdu. JSON'lar repoda durur, buradan
# ConfigMap'e yazılır ve Grafana sidecar'ı `grafana_dashboard=1` label'ını
# görüp otomatik yükler.

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
