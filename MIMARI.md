# Mimari Tasarım Dokümanı

Bu doküman sistemin **hedef mimarisini** ve her bileşenin somut yapılandırmasını tanımlar.
Aşamalar, kesim listesi ve çalışma kuralları için: [PROJE_PLANI.md](PROJE_PLANI.md)

> **Durum:** Aşama 1–3 **uygulandı ve doğrulandı**; §1–3 artık çalışan gerçeği
> anlatıyor. Aşama 4 ve sonrası hedef tasarımdır.
> Doğrulama kanıtları: [docs/KARSILASILAN_ZORLUKLAR.md](docs/KARSILASILAN_ZORLUKLAR.md)

---

## 1. Mimari Kararlar (ADR özeti)

| # | Karar | Seçilen | Gerekçe | Elenen alternatif |
|---|---|---|---|---|
| 1 | Bulut | AWS · `eu-central-1` | EKS/ECR/ALB/IRSA olgun, case serbest bırakmış | GCP, HWC |
| 2 | Orkestrasyon | **EKS 1.34 + managed node group** (**3 × `t3.medium`**) | Fargate DaemonSet ve EBS PVC desteklemediği için Alloy + MongoDB planını bozardı. Node sayısı önce vCPU kotasıyla (5) 2'ye düşmüştü; kota 16'ya çıkınca ölçülen kapasiteye dayanarak 3'e döndü (2 node'da HPA + tam monitoring `max-pods` limitine takılıyordu). Sürüm bir maliyet kararı: 1.33 standart destekten çıkmış, extended support control plane'i 6× pahalı yapar ve varsayılan olarak açıktır | EKS Fargate, EC2+k3s, 2×`t3.large`, 3×`t3.medium` (kotayı aşıyor), EKS 1.33 (extended) |
| 3 | Veritabanı | **Cluster içi MongoDB StatefulSet** | Case "veritabanını da Dockerize et" diyor; Atlas/DocumentDB bunu karşılamaz | MongoDB Atlas, DocumentDB |
| 4 | Manifest & deploy | **Kustomize + kubectl (push-based)** | En az hareketli parça, deploy adımı pipeline'da görünür | Helm, Argo CD |
| 5 | **TLS / giriş noktası** | **CloudFront → ALB** | **Kayıtlı domain yok.** CloudFront ücretsiz ve geçerli `*.cloudfront.net` sertifikası verir; case'in "public URL + HTTPS" beklentisi domain satın almadan karşılanır | Route53 + ACM (domain gerekir), ALB'de düz HTTP (TLS yok), self-signed (tarayıcı uyarısı) |
| 6 | Gözlemlenebilirlik | **kube-prometheus-stack + Loki + Grafana Alloy** | Promtail 2 Mart 2026'da EOL oldu → Grafana'nın önerdiği Alloy kullanılır; alert kuralları repo'da kod olarak durur | CloudWatch Container Insights |
| 7 | CI/CD | GitHub Actions + OIDC | Uzun ömürlü AWS anahtarı gerekmez | Jenkins, GitLab CI |
| 8 | Registry | Amazon ECR | Cluster ile aynı hesap, scan-on-push | GHCR |
| 9 | Frontend→API yolu | **Göreli `/api` + nginx reverse proxy** | CRA env'i build-time gömer; göreli yol ile aynı image tüm ortamlarda çalışır, CORS ortadan kalkar | `REACT_APP_API_URL` build-arg |
| 10 | Secret yönetimi | **Terraform `random_password` → K8s Secret** | Git'te düz secret bulunmaması hedefini 3 gün içinde karşılar; ESO ayrı IRSA+CRD maliyeti getirirdi | External Secrets Operator + Secrets Manager (prod yolu) |
| 11 | Terraform state | **S3 + native lockfile** (`use_lockfile`) | Terraform 1.10+ ile DynamoDB kilit tablosu gereksizleşti — bir kaynak, bir maliyet kalemi, bir hata yüzeyi eksik | S3 + DynamoDB |
| 12 | TF modülleri | **`terraform-aws-modules/{vpc,eks,iam}`** sürüm pinli | OIDC provider, access entries, launch template, IRSA gibi kolay hata yapılan kısımları doğru kurar; 3 günde ham kaynak yazmak riskli | Ham `aws_eks_cluster` vb. |

---

## 2. Sistem Mimarisi

```mermaid
graph TB
    U[Kullanıcı] -->|HTTPS| CF["CloudFront<br/>d123.cloudfront.net<br/>varsayılan TLS sertifikası<br/>redirect-to-https"]
    CF -->|HTTP · yalnız CloudFront prefix list| ALB["ALB<br/>AWS Load Balancer Controller"]

    subgraph VPC["VPC 10.0.0.0/16 · 2 AZ"]
        subgraph PUB["Public Subnets"]
            ALB
            NAT["NAT Gateway ×1<br/>(maliyet kısıtı)"]
        end
        subgraph PRIV["Private Subnets — EKS Node Group 3×t3.medium"]
            subgraph NS["namespace: mern"]
                FE["frontend Deployment ×2<br/>nginx:1.27-alpine · 8080"]
                BE["backend Deployment ×2<br/>node:20-alpine · 5050<br/>HPA 2→6"]
                DB[("mongodb StatefulSet ×1<br/>mongo:7.0 · 27017<br/>PVC gp3 10Gi")]
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
    PROM -.-> AM -->|webhook| SLACK[Slack]
    GRAF -.-> PROM
    GRAF -.-> LOKI
```

### İstek akışı

```
Tarayıcı → https://<id>.cloudfront.net/           → CF → ALB → frontend:8080 → nginx → React SPA
Tarayıcı → https://<id>.cloudfront.net/api/record → CF → ALB → frontend:8080 → nginx proxy_pass
                                                   → backend:5050/record → MongoDB
```

**Kritik nokta:** Backend cluster dışına **açılmaz**. Tek giriş noktası CloudFront→ALB→frontend'dir;
`/api` prefix'i nginx tarafından soyulup backend'e iletilir. Böylece tek origin, tek sertifika, CORS yok.

### CloudFront yapılandırması (dikkat gerektiren nokta)

CloudFront varsayılan olarak cache yapar ve bu API'yi **bozar**. İki ayrı behavior tanımlanır:

| Path pattern | Cache policy | Origin request policy | Allowed methods |
|---|---|---|---|
| `/api/*` | **`CachingDisabled`** | **`AllViewerExceptHostHeader`** | GET, HEAD, OPTIONS, PUT, POST, PATCH, DELETE |
| `*` (default) | `CachingOptimized` | `CORS-S3Origin` benzeri minimal | GET, HEAD |

`AllViewerExceptHostHeader` olmadan Host header'ı origin'e taşınır ve ALB yönlendirmesi şaşar;
`CachingDisabled` olmadan POST/PUT/DELETE ya reddedilir ya da bayat yanıt döner.
Bu madde `docs/KARSILASILAN_ZORLUKLAR.md`'ye yazılır.

**ALB Security Group:** yalnızca AWS yönetimli
`com.amazonaws.global.cloudfront.origin-facing` prefix list'inden 80/tcp kabul eder.
ALB DNS adına doğrudan erişim böylece kapalıdır — TLS atlatılamaz.

---

## 3. Bileşen Tasarımı

### 3.1 Frontend (`client`)

| | |
|---|---|
| Image | `mern-client` — stage1 `node:20-alpine` build → stage2 `nginx:1.27-alpine`, ikisi de **digest pinli** · 63 MB · Trivy 0 bulgu |
| Port | 8080 (non-root nginx; 80 root gerektirir) |
| Replica | 2 (HPA kapsam dışı) |
| Resources | req `50m/64Mi` · limit `200m/128Mi` |
| Probe | liveness+readiness → `GET /` :8080 |

**nginx yapılandırması** — tek dosya, hem compose hem Kubernetes için:
`docker/nginx/default.conf.template` ([Aşama 2'de yazıldı ve doğrulandı](docs/KARSILASILAN_ZORLUKLAR.md))

```nginx
server {
  listen 8080;
  server_tokens off;
  gzip on;

  # Resolver adresi SABİT YAZILMAZ: imajın 15-local-resolvers.envsh scripti
  # /etc/resolv.conf'tan okuyup bu değişkeni doldurur. Böylece aynı template
  # compose'da 127.0.0.11, Kubernetes'te kube-dns ClusterIP ile render olur.
  resolver ${NGINX_LOCAL_RESOLVERS} valid=10s;

  # Değişkenli proxy_pass: nginx upstream'i istek anında çözer.
  # Sabit yazılırsa backend Service gelmeden nginx başlamaz ve CrashLoop'a girer.
  set $backend_upstream http://${BACKEND_UPSTREAM};

  location /api/ {
    # DİKKAT: değişkenli proxy_pass'te "sondaki slash öneki soyar" kuralı
    # GEÇERSİZDİR — nginx yazılan URI'yi isteğinkiyle birleştirmez, yerine koyar.
    # Önek bu yüzden rewrite ile soyulur, proxy_pass URI'siz bırakılır.
    rewrite ^/api/(.*)$ /$1 break;
    proxy_pass $backend_upstream;
  }

  location /     { try_files $uri $uri/ /index.html; }  # SPA fallback
}
```

**`readOnlyRootFilesystem` için zorunlu `emptyDir` mount'ları — dört adet:**
`/var/cache/nginx`, `/run`, `/tmp` ve **`/etc/nginx/conf.d`**.
Sonuncusu kolayca gözden kaçar: envsubst template'i oraya render eder; yazamazsa
script hata verip sessizce çıkar ve nginx varsayılan sayfayı servis eder.
Ayrıca `securityContext.fsGroup: 101` gerekir, aksi halde emptyDir'ler root sahipli gelir.

**Yapılan kod değişikliği (Aşama 1):** `create.js`, `edit.js`, `recordList.js`, `healthcheck.js`
içindeki 6 adet `http://localhost:5050/...` → `${API_URL}/...` (`src/api.js`, göreli `/api`).
Dev ortamda aynı rewrite'ı `src/setupProxy.js` sağlar.

### 3.2 Backend (`server`)

| | |
|---|---|
| Image | `mern-server` — `node:20-alpine` digest pinli, `npm ci --omit=dev`, `USER node`, tini PID1, **runtime'dan npm kaldırıldı** (18 CVE) · 153 MB · Trivy 0 bulgu |
| Port | 5050 |
| Replica | 2 · HPA 2→6 (CPU %70) |
| Resources | req `100m/128Mi` · limit `500m/256Mi` |
| Liveness | `GET /healthcheck` — sadece process canlılığı |
| Readiness | `GET /healthcheck/ready` — Mongo `ping` içerir; hata durumunda 503 |

**Env:**
| Değişken | Kaynak |
|---|---|
| `ATLAS_URI` | Secret `mongo-credentials` → `mongodb://$user:$pass@mongodb-0.mongodb:27017/sample_training?authSource=admin` |
| `MONGO_DB` | ConfigMap (`sample_training`) |
| `PORT` / `HOST` | ConfigMap (5050 / `0.0.0.0`) |
| `NODE_ENV` | `production` |
| `CORS_ORIGINS` | ConfigMap — varsayılan boş (same-origin) |

**Yapılan kod değişikliği (Aşama 1):** `db/conn.mjs` bağlantı hatasında `conn` undefined kalıp
`conn.db()`'de çöküyordu → üstel backoff'lu retry + tükenirse `process.exit(1)`
(restart'ı K8s üstlenir). `server.mjs` `0.0.0.0`'a bind + `PORT`/`HOST` env desteği +
`SIGTERM` graceful shutdown (tini PID 1 üzerinden doğrulandı). Loglar `pino` ile JSON.

> Metrik toplama uygulama kodundan değil, kube-state-metrics ve ALB/CloudFront metriklerinden
> yapılır (`prom-client` kapsam dışı) — uygulama koduna müdahale minimumda tutulur.

### 3.3 MongoDB

| | |
|---|---|
| Workload | StatefulSet, replica 1, `serviceName: mongodb` (Headless) |
| Image | `mongo:7.0` |
| Storage | `volumeClaimTemplates` → StorageClass **`gp3`**, 10Gi |
| Service | ClusterIP — **cluster dışına asla açılmaz** |
| Auth | `MONGO_INITDB_ROOT_*` Secret'tan (Terraform `random_password`); DB `sample_training`, koleksiyon `records` |
| Probe | `mongosh --eval "db.adminCommand('ping')"` |
| Resources | req `250m/512Mi` · limit `1000m/1Gi` |

> **Ön koşul:** `aws-ebs-csi-driver` addon'u + IRSA rolü + `gp3` StorageClass tanımı.
> EKS 1.23+ sürümünde bunlar olmadan PVC kalıcı olarak `Pending`'de kalır ve StatefulSet açılmaz.
> EKS varsayılan StorageClass'ı `gp2`'dir; `gp3` elle tanımlanır.

> Tek replica bilinçli bir tercihtir: case bir demo dağıtımıdır ve 3 node'lu ReplicaSet +
> init container'lı seçim mekanizması kapsamı gereksiz büyütür. Prod'a geçişte yol
> `mongodb-community-operator`'dür — bu README'de not edilir.

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

Image `etl` — **`python:3.12-alpine`** digest pinli (slim'de 36 düzeltilebilir CVE vardı, alpine'da 0), `requirements.txt` (`requests` pinli), non-root uid 10001 · 52 MB.
`HEALTHCHECK` yok: tek seferlik batch iş, sağlığı çıkış koduyla ölçülür.

**`ETL.py`'nin içeriği değiştirilmez** (case gereği). JSON log gereksinimi ayrı bir
`python-project/runner.py` sarmalayıcısı ile karşılanır: `ETL.py`'yi çalıştırır,
stdout'unu yapılandırılmış JSON log satırlarına çevirir, çıkış kodunu aynen döndürür.
Container entrypoint `runner.py`'dir. Loglar Grafana Alloy ile toplanır.

---

## 4. Ağ ve Güvenlik

### NetworkPolicy (default deny)
```
mern namespace: varsayılan tüm ingress/egress kapalı, üstüne:
  ALB (node CIDR) → frontend:8080
  frontend        → backend:5050
  backend         → mongodb:27017
  etl             → 0.0.0.0/0:443 (api.github.com)
  tümü            → kube-dns:53
  monitoring      → tüm pod'ların metrik portu
```

### Katman katman güvenlik

| Katman | Önlem |
|---|---|
| Kenar | CloudFront'ta TLS (`redirect-to-https`); **ALB SG yalnız CloudFront prefix list'ine açık** → ALB'ye doğrudan HTTP erişimi yok |
| Ağ | Node'lar private subnet; MongoDB ClusterIP; default-deny NetworkPolicy |
| Pod | `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation:false`, `capabilities.drop:[ALL]`, `seccompProfile: RuntimeDefault` |
| Kimlik | IRSA — pod bazlı IAM; node role'ünde geniş yetki yok |
| Secret | Terraform `random_password` → K8s Secret; `*.tfstate` ve `*.tfvars` git dışı. Git'te düz secret yok |
| Image | ECR scan-on-push + CI'da Trivy (`HIGH,CRITICAL` + `--ignore-unfixed` → fail). Base image'lar **SHA256 digest** ile pinli, üstüne `apk upgrade` katmanı. Aşama 2 sonunda üç imaj da **0 HIGH/CRITICAL**. |
| CI | GitHub OIDC → AWS role; uzun ömürlü access key yok |
| Hesap | Root'ta MFA, billing alarmı (40 USD) |

---

## 5. Repo Yapısı

```
.
├── mern-project/{client,server}/       # uygulama kaynağı (+ Aşama 1 düzeltmeleri)
├── python-project/
│   ├── ETL.py                          # dokunulmaz
│   ├── runner.py                       # JSON log sarmalayıcı
│   └── requirements.txt
├── docker/
│   ├── Dockerfile.client · Dockerfile.server · Dockerfile.etl
│   ├── nginx.conf
│   └── docker-compose.yml              # mongo + be + fe + cypress/included:4.12.1
├── k8s/
│   ├── base/                           # configmap, sts+svc (mongo), deployment+svc
│   │                                   # +hpa+pdb (be/fe), ingress, cronjob, netpol
│   │                                   # (namespace ve secret'lar Terraform'da — ADR 10)
│   └── overlays/prod/                  # kustomization (ns, images) + ingress-patch
├── terraform/
│   ├── bootstrap/                      # S3 state bucket (ayrı state)
│   ├── modules/{ecr,github-oidc,edge}/ # yalnızca upstream'de karşılığı olmayanlar;
│   │                                   # vpc/eks/irsa için terraform-aws-modules (ADR 12)
│   ├── envs/prod/                      # backend.tf (S3 native lock), VPC+EKS+ECR+IAM
│   └── envs/edge/                      # CloudFront — Aşama 4'ten SONRA apply
├── monitoring/                         # 3 chart values + alerts/mern-rules.yaml
│                                       # + dashboards/*.json (Terraform okur)
├── .github/workflows/{mern.yml,etl.yml}
├── docs/
│   ├── KARSILASILAN_ZORLUKLAR.md
│   └── screenshots/
├── MIMARI.md · PROJE_PLANI.md · README.md
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
    B --> T["Trivy scan<br/>HIGH,CRITICAL<br/>--ignore-unfixed → fail"]
    T --> P[ECR push]
    P --> K[kustomize set image<br/>kubectl apply -k overlays/prod]
    K --> RS[rollout status<br/>başarısız → rollout undo]
    RS --> S["smoke: /healthcheck 200<br/>/api/record 200"]
```

- Image tag = **git commit SHA** (mutable `latest` deploy'a girmez → her deploy izlenebilir ve geri alınabilir).
- `main` korumalı; PR + yeşil CI zorunlu.
- `etl.yml` ayrı pipeline: `ruff` → build → Trivy → push → CronJob image güncelle.
- **OIDC federated role Terraform `iam` modülünde Gün 2'de kurulur** — trust policy hatası
  ayıklamak Gün 3 sabahında yapılacak iş değildir.

---

## 7. Gözlemlenebilirlik

**Loglar:** uygulama stdout → Grafana Alloy → Loki → Grafana. Retention 14 gün.
Backend `pino` ile JSON log; ETL `runner.py` ile JSON log.

> **Sapma:** Alloy **DaemonSet değil, tek replica Deployment** olarak çalışır.
> `loki.source.kubernetes` logları hostPath'ten değil Kubernetes API'sinden okur;
> DaemonSet'te her node'daki instance tüm eşleşen pod'ları toplar ve **aynı satır
> node sayısı kadar yazılır**. Çözüm ya Alloy clustering ya tek instance'tır.

**Metrikler:** kube-prometheus-stack (node-exporter, kube-state-metrics).
Üçü de EKS'te scrape edilemediği için `kubeControllerManager`, `kubeScheduler`,
`kubeEtcd`, `kubeProxy` job'ları kapatılır (aksi halde kalıcı "down" hedef gürültüsü).

> **Sapma:** ALB `HTTPCode_Target_5XX_Count` **Prometheus'a alınmadı**. Metriğin
> Prometheus'a girmesi `yet-another-cloudwatch-exporter` + ayrı IRSA rolü gerektirir;
> oran alarmı ayrıca doğru **target group** boyutunu ve metric-math'i ister. Aynı
> arıza sinyali `BackendNotReady` + `PodCrashLooping` ile zaten alınıyor.

**Alert kuralları** (`monitoring/alerts/mern-rules.yaml` → Alertmanager):

| Alert | Koşul | Severity |
|---|---|---|
| `PodCrashLooping` | restart artışı > 0, 5 dk | critical |
| `BackendNotReady` | hazır backend pod'u yok (`sum(...) < 1 or absent(...)`), 2 dk | critical |
| `FrontendNotReady` | hazır frontend pod'u yok, 2 dk | critical |
| `MongoDiskFilling` | PVC doluluk > %80, 10 dk | warning |
| **`ETLJobMissing`** | **65 dk'dır başarılı job yok — ya da hiç olmamış (`absent`)** | critical |
| `ETLJobFailed` | son 1 saatte başarısız Job | warning |
| `NodeNotReady` | node NotReady > 5 dk | critical |
| `NodeMemoryPressure` / `NodeDiskPressure` | node baskı altında > 5 dk | warning |

> `absent(...)` iki kuralda **zorunlu**: tüm pod'lar yok olduğunda ya da CronJob hiç
> çalışmadığında zaman serisi kaybolur ve `== 0` / `> 3900` biçimindeki ifade hiç
> değerlendirilmez — alarm sessizce ateşlenmez. Sessiz alarm, alarm olmamasından kötüdür.

**Bildirim:** Slack webhook'u bu teslimde **yok**; tüm alert'ler `null` receiver'a düşer
ve kanıt Alertmanager UI'daki firing listesidir. `TF_VAR_slack_webhook_url` verilirse
Terraform `slack-notifications` receiver'ını üretir (`Watchdog` hariç tutulur).

**Erişim:** Grafana dışarı **açılmaz** — ALB Security Group yalnız CloudFront prefix
list'ine açık, ikinci bir public giriş §güvenlik listesini bozar.
`kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`.

> `ETLJobMissing` mimarinin en kritik alert'idir: bir web servisi çökerse kullanıcı fark eder,
> bir CronJob sessizce çalışmayı bırakırsa **kimse fark etmez**. README'deki "saatte 1 çalışmalı"
> kriterinin tek gerçek doğrulaması budur. Zaman daralsa bile bu alert kesilmez.

---

## 8. Ölçeklenebilirlik ve Dayanıklılık

| Senaryo | Yanıt |
|---|---|
| Trafik artışı | Backend HPA 2→6. **Node sayısı sabit (3 × `t3.medium`)** — Cluster Autoscaler kapsam dışı, sınır README'de yazılı |
| Pod ölümü | Deployment yeniden yaratır; readiness hazır olmadan trafik gitmez |
| Node kaybı | 2 AZ + 3 node + PDB (`minAvailable: 1`) + `topologySpreadConstraints` (`maxSkew: 1`, **`ScheduleAnyway`** — katı kural HPA'nın 6'ya ölçeklemesini kilitlerdi). Drain testinde ölçüldü: pod'lar taşındı, **110/110 istek 200**. Kesintisizlik `preStop` hook'una bağlıdır (madde 53) |
| Bellek baskısı | Monitoring'e **~8.4 GiB** kalır (3 node, ölçülen 3.37 GiB/node üzerinden). Tahmini yük ~5 GiB → rahat. Tampon kuralı yine de geçerli |
| Kötü deploy | `maxUnavailable: 0` rolling update; rollout fail → otomatik `rollout undo` |
| DB verisi | EBS gp3 PVC kalıcı; StatefulSet yeniden planlanınca aynı volume bağlanır — **ancak yalnızca aynı AZ içinde**. AZ kaybı tek replica'lı MongoDB için kurtarılamaz (madde 55) |
| Statik içerik yükü | CloudFront edge cache (`/api/*` hariç) |

### Bilinen sınırlar (README'de açıkça belirtilir)

| Sınır | Prod'a geçiş yolu |
|---|---|
| MongoDB tek replica → yeniden planlanmada kısa kesinti | `mongodb-community-operator` ile 3 node ReplicaSet |
| Tek NAT Gateway → o AZ düşerse private egress kesilir | AZ başına NAT |
| Node sayısı sabit (3), `t3` burst kredisiyle sınırlı CPU | Cluster Autoscaler / Karpenter + `m` serisi (burstable olmayan) node'lar |
| Secret'lar Terraform state'inde | External Secrets Operator + AWS Secrets Manager |
| Domain yok, `*.cloudfront.net` adı | Route53 + ACM + ExternalDNS (Terraform kodu hazır, yorum satırında) |
| Tek ortam (`prod`) | `overlays/dev` eklenmesi |
