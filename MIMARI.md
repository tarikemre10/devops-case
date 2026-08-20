# Mimari Tasarım Dokümanı

Bu doküman sistemin **hedef mimarisini** ve her bileşenin somut yapılandırmasını tanımlar.
Aşamalar ve çalışma kuralları için: [PROJE_PLANI.md](PROJE_PLANI.md)

---

## 1. Mimari Kararlar (ADR özeti)

| # | Karar | Seçilen | Gerekçe | Elenen alternatif |
|---|---|---|---|---|
| 1 | Bulut | AWS | EKS/ECR/ALB/IRSA olgun, case serbest bırakmış | GCP, HWC |
| 2 | Orkestrasyon | **EKS + managed node group** | Sektör standardı; Fargate DaemonSet ve EBS PVC desteklemediği için Grafana Alloy + MongoDB planını bozardı | EKS Fargate, EC2+k3s |
| 3 | Veritabanı | **Cluster içi MongoDB StatefulSet** | Case "veritabanını da Dockerize et" diyor; Atlas/DocumentDB bunu karşılamaz | MongoDB Atlas, DocumentDB |
| 4 | Manifest & deploy | **Kustomize + kubectl (push-based)** | En az hareketli parça, deploy adımı pipeline'da görünür | Helm, Argo CD |
| 5 | Gözlemlenebilirlik | **kube-prometheus-stack + Loki + Grafana Alloy** | Promtail 2 Mart 2026’da EOL oldu → Grafana’nın önerdiği Alloy kullanılır; alert kuralları repo’da kod olarak durur, Grafana ekran görüntüsü üretir | CloudWatch Container Insights |
| 6 | CI/CD | GitHub Actions + OIDC | Uzun ömürlü AWS anahtarı gerekmez | Jenkins, GitLab CI |
| 7 | Registry | Amazon ECR | Cluster ile aynı hesap, scan-on-push | GHCR |
| 8 | Frontend→API yolu | **Göreli `/api` + nginx reverse proxy** | CRA env'i build-time gömer; göreli yol ile aynı image tüm ortamlarda çalışır, CORS ortadan kalkar | `REACT_APP_API_URL` build-arg |

---

## 2. Sistem Mimarisi

```mermaid
graph TB
    U[Kullanıcı] -->|HTTPS| R53[Route53]
    R53 --> ALB[ALB · ACM TLS<br/>AWS Load Balancer Controller]

    subgraph VPC["VPC 10.0.0.0/16 · 2 AZ"]
        subgraph PUB["Public Subnets"]
            ALB
            NAT[NAT Gateway]
        end
        subgraph PRIV["Private Subnets — EKS Node Group"]
            subgraph NS["namespace: mern"]
                FE["frontend Deployment ×2<br/>nginx:alpine · 8080"]
                BE["backend Deployment ×2<br/>node:20 · 5050"]
                DB[("mongodb StatefulSet ×1<br/>mongo:7 · 27017<br/>PVC gp3 10Gi")]
                CJ["etl CronJob<br/>0 * * * *"]
            end
            subgraph MON["namespace: monitoring"]
                PROM[Prometheus]
                LOKI[Loki]
                GRAF[Grafana]
                AM[Alertmanager]
            end
        end
    end

    ALB -->|Ingress /| FE
    FE -->|nginx proxy /api| BE
    BE --> DB
    CJ -->|HTTPS via NAT| GH[api.github.com]
    PROM -.-> AM -->|webhook| SLACK[Slack / e-posta]
    GRAF -.-> PROM
    GRAF -.-> LOKI
```

### İstek akışı

```
Tarayıcı → https://mern.<domain>/           → ALB → frontend:8080 → nginx → React SPA
Tarayıcı → https://mern.<domain>/api/record → ALB → frontend:8080 → nginx proxy_pass
                                             → backend:5050/record → MongoDB
```

**Kritik nokta:** Backend cluster dışına **açılmaz**. Tek giriş noktası ALB→frontend'dir; `/api` prefix'i nginx tarafından soyulup backend'e iletilir. Böylece tek origin, tek TLS sertifikası, CORS yok.

---

## 3. Bileşen Tasarımı

### 3.1 Frontend (`client`)

| | |
|---|---|
| Image | `mern-client` — stage1 `node:20-alpine` build → stage2 `nginx:1.27-alpine` |
| Port | 8080 (non-root nginx; 80 root gerektirir) |
| Replica | 2 · HPA 2→6 (CPU %70) |
| Resources | req `50m/64Mi` · limit `200m/128Mi` |
| Probe | liveness+readiness → `GET /` :8080 |

**nginx yapılandırması:**
```nginx
location /api/ { proxy_pass http://backend.mern.svc.cluster.local:5050/; }
location /     { try_files $uri $uri/ /index.html; }   # SPA fallback
gzip on; server_tokens off;
```

**Gerekli kod değişikliği:** `create.js`, `edit.js`, `recordList.js`, `healthcheck.js` içindeki 6 adet `http://localhost:5050/...` → `/api/...`

### 3.2 Backend (`server`)

| | |
|---|---|
| Image | `mern-server` — `node:20-alpine`, `npm ci --omit=dev`, `USER node`, tini PID1 |
| Port | 5050 |
| Replica | 2 · HPA 2→6 (CPU %70) |
| Resources | req `100m/128Mi` · limit `500m/256Mi` |
| Liveness | `GET /healthcheck` — sadece process canlılığı |
| Readiness | `GET /healthcheck/ready` — Mongo `ping` içerir *(eklenecek)* |

**Env:**
| Değişken | Kaynak |
|---|---|
| `ATLAS_URI` | Secret `mongo-credentials` → `mongodb://$user:$pass@mongodb-0.mongodb:27017/sample_training?authSource=admin` |
| `PORT` | ConfigMap (5050) |
| `NODE_ENV` | `production` |
| `CORS_ORIGIN` | ConfigMap — prod'da yalnızca kendi domaini |

**Gerekli kod değişikliği:** `db/conn.mjs` bağlantı hatasında `conn` undefined kalıp `conn.db()`'de çöküyor → retry/backoff + başarısızsa `process.exit(1)` (restart'ı K8s üstlensin). `server.mjs` `0.0.0.0`'a bind + `PORT` env desteği.

### 3.3 MongoDB

| | |
|---|---|
| Workload | StatefulSet, replica 1, `serviceName: mongodb` (Headless) |
| Image | `mongo:7.0` |
| Storage | `volumeClaimTemplates` → StorageClass `gp3`, 10Gi |
| Service | ClusterIP — **cluster dışına asla açılmaz** |
| Auth | `MONGO_INITDB_ROOT_*` Secret'tan; DB `sample_training`, koleksiyon `records` |
| Probe | `mongosh --eval "db.adminCommand('ping')"` |
| Resources | req `250m/512Mi` · limit `1000m/1Gi` |

> Tek replica bilinçli bir tercihtir: case bir demo dağıtımıdır ve 3 node'lu ReplicaSet + init container'lı seçim mekanizması kapsamı gereksiz büyütür. Prod'a geçişte yol `mongodb-community-operator`'dür — bu README'de not edilir.

### 3.4 ETL CronJob

```yaml
schedule: "0 * * * *"          # README kabul kriteri: saatte 1
concurrencyPolicy: Forbid       # üst üste binme yok
startingDeadlineSeconds: 300
backoffLimit: 2
restartPolicy: OnFailure
successfulJobsHistoryLimit: 3
failedJobsHistoryLimit: 3
```
Image `etl` — `python:3.12-slim`, `requirements.txt` (`requests` pinli), non-root.
`ETL.py`'nin **içeriği değiştirilmez**; `print()` çıktısı stdout’tan Grafana Alloy ile toplanır.

---

## 4. Ağ ve Güvenlik

### NetworkPolicy (default deny)
```
mern namespace: varsayılan tüm ingress/egress kapalı, üstüne:
  ALB/ingress-nginx  → frontend:8080
  frontend           → backend:5050
  backend            → mongodb:27017
  etl                → 0.0.0.0/0:443 (api.github.com)
  tümü               → kube-dns:53
  monitoring         → tüm pod'ların /metrics portu
```

### Katman katman güvenlik

| Katman | Önlem |
|---|---|
| Ağ | Node'lar private subnet; MongoDB ClusterIP; default-deny NetworkPolicy |
| Taşıma | ALB'de ACM sertifikası, HTTP→HTTPS 301 |
| Pod | `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]`, `seccompProfile: RuntimeDefault` |
| Kimlik | IRSA — pod bazlı IAM; node role'ünde geniş yetki yok |
| Secret | AWS Secrets Manager → External Secrets Operator → K8s Secret. Git'te düz secret yok |
| Image | ECR scan-on-push + CI'da Trivy (HIGH/CRITICAL → fail), base image'lar pinli |
| CI | GitHub OIDC → AWS role; uzun ömürlü access key yok |

---

## 5. Repo Yapısı

```
.
├── mern-project/{client,server}/       # uygulama kaynağı (+ Aşama 1 düzeltmeleri)
├── python-project/                     # ETL.py (dokunulmaz) + requirements.txt
├── docker/
│   ├── Dockerfile.client · Dockerfile.server · Dockerfile.etl
│   ├── nginx.conf
│   └── docker-compose.yml              # lokal uçtan uca doğrulama
├── k8s/
│   ├── base/                           # namespace, deployment, sts, cronjob,
│   │                                   # svc, ingress, hpa, pdb, netpol, externalsecret
│   └── overlays/{dev,prod}/            # replica, resource, domain farkları
├── terraform/
│   ├── modules/{network,eks,ecr,iam,addons}/
│   └── envs/{dev,prod}/                # backend.tf (S3+DynamoDB), tfvars
├── monitoring/                         # values.yaml + PrometheusRule + dashboard json
├── .github/workflows/{mern.yml,etl.yml}
└── docs/{ARCHITECTURE.md,CHALLENGES.md,screenshots/}
```

---

## 6. CI/CD Akışı

```mermaid
graph LR
    PR[PR açılır] --> L[lint + unit test]
    L --> E2E[compose up → Cypress e2e]
    E2E --> M{main'e merge?}
    M -->|hayır| STOP[dur]
    M -->|evet| B[buildx → image:GIT_SHA]
    B --> T[Trivy scan<br/>HIGH/CRITICAL → fail]
    T --> P[ECR push]
    P --> K[kustomize set image<br/>kubectl apply -k overlays/prod]
    K --> RS[rollout status<br/>başarısız → rollout undo]
    RS --> S[smoke: /healthcheck 200<br/>/api/record 200]
```

- Image tag = **git commit SHA** (mutable `latest` deploy'a girmez → her deploy izlenebilir ve geri alınabilir).
- `main` korumalı; prod deploy GitHub Environments ile manuel onaylı.
- `etl.yml` ayrı pipeline: `ruff` → build → Trivy → push → CronJob image güncelle.

---

## 7. Gözlemlenebilirlik

**Loglar:** uygulama stdout → Grafana Alloy (DaemonSet) → Loki → Grafana. Retention 14 gün. Backend `pino` ile JSON log.

**Metrikler:** kube-prometheus-stack. Backend `prom-client` ile `/metrics`: istek sayısı, hata oranı, p95 latency.

**Alert kuralları** (`monitoring/PrometheusRule.yaml` → Alertmanager → Slack):

| Alert | Koşul | Severity |
|---|---|---|
| `PodCrashLooping` | restart artışı > 0, 5 dk | critical |
| `BackendHighErrorRate` | 5xx oranı > %5, 5 dk | critical |
| `BackendNotReady` | readiness fail > 2 dk | critical |
| `MongoDiskFilling` | PVC doluluk > %80 | warning |
| **`ETLJobMissing`** | **son 1 saatte başarılı job yok** | critical |
| `NodeNotReady` | node NotReady > 5 dk | critical |

> `ETLJobMissing` mimarinin en kritik alert'idir: bir web servisi çökerse kullanıcı fark eder, bir CronJob sessizce çalışmayı bırakırsa **kimse fark etmez**. README'deki "saatte 1 çalışmalı" kriterinin tek gerçek doğrulaması budur.

---

## 8. Ölçeklenebilirlik ve Dayanıklılık

| Senaryo | Yanıt |
|---|---|
| Trafik artışı | HPA frontend/backend 2→6; Cluster Autoscaler node ekler |
| Pod ölümü | Deployment yeniden yaratır; readiness hazır olmadan trafik gitmez |
| Node kaybı | 2 AZ + PDB (`minAvailable: 1`) ile en az 1 replica ayakta |
| Kötü deploy | `maxUnavailable: 0` rolling update; rollout fail → otomatik `rollout undo` |
| DB verisi | EBS PVC kalıcı; StatefulSet yeniden planlanınca aynı volume bağlanır |
| Bilinen sınır | MongoDB tek replica → yeniden planlanma sırasında kısa kesinti. Kabul edildi, README'de belirtildi |

---

## 9. Ortam Farkları

| | dev | prod |
|---|---|---|
| Replica (fe/be) | 1 / 1 | 2 / 2 |
| HPA | kapalı | açık (2→6) |
| Domain | `dev.<domain>` | `mern.<domain>` |
| Log seviyesi | debug | info |
| Deploy | main'e merge → otomatik | manuel onay (GitHub Environment) |
