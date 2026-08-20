# DevOps Case — Uygulama Planı, Kurallar ve Kabul Kriterleri

Bu doküman, case metnindeki gereklilikleri somut aşamalara ve uyulacak kurallara çevirir.
Case metni: `Case Tanıtım Metni_Tr.txt` · Kabul kriterleri: `README.md`

---

## 0. Kapsam ve Teknoloji Kararları

| Alan | Karar | Gerekçe |
|---|---|---|
| Bulut | **AWS** | EKS + ECR + IAM/IRSA olgun, case'te serbest bırakılmış |
| Orkestrasyon | **Kubernetes (EKS)** | Case'in açık gerekliliği |
| IaC | **Terraform** (remote state: S3 + DynamoDB lock) | Modüler, versiyonlanabilir |
| CI/CD | **GitHub Actions** | Repo GitHub'da teslim edilecek |
| Registry | **Amazon ECR** (alternatif: GHCR) | Cluster ile aynı hesapta, IRSA ile pull |
| Manifest yönetimi | **Kustomize** (base + overlays: dev/prod) | Helm'e göre daha az soyutlama, review'da okunur |
| Gözlemlenebilirlik | **kube-prometheus-stack** + **Loki + Grafana Alloy** | Metrik + log tek Grafana'da |
| Alerting | **Alertmanager → Slack/e-posta** | Case'teki "kritik olaylar için uyarı" maddesi |
| Secret | K8s Secret + **External Secrets Operator → AWS Secrets Manager** | Git'te düz secret yok |

> Bu tablo tek doğruluk kaynağıdır. Bir teknoloji değişirse önce burası güncellenir.

### Servis envanteri (koddan çıkarıldı)

| Bileşen | Kaynak | Port | Notlar |
|---|---|---|---|
| Frontend | `mern-project/client` (CRA 5 + React 18) | 3000 (dev) / 8080 (nginx) | Cypress e2e mevcut |
| Backend | `mern-project/server` (Express, ESM) | 5050 | `/record` CRUD, `/healthcheck` |
| Veritabanı | MongoDB | 27017 | DB `sample_training`, koleksiyon `records` |
| ETL | `python-project/ETL.py` | — | Saatte 1 çalışacak (CronJob) |

---

## Aşama 1 — Kod Hazırlığı (deploy'dan önce çözülmesi zorunlu)

Bu maddeler yapılmadan uygulama cluster'da **çalışmaz**. Uygulama mantığına dokunulmaz, yalnızca dağıtılabilirlik düzeltilir.

1. **Frontend'deki hard-coded API adresi.**
   `client/src/components/{recordList,create,edit,healthcheck}.js` içinde 6 yerde `http://localhost:5050` sabit yazılı.
   Çözüm: tüm çağrılar `/api/...` göreli yoluna alınır; nginx `/api` → backend Service'e reverse-proxy yapar.
   (Alternatif `REACT_APP_API_URL` build-arg'dır; ancak CRA env'i build-time gömdüğü için aynı image ortamlar arası taşınamaz → **göreli yol tercih edilir**.)
2. **Backend Mongo bağlantısı.** `server/db/conn.mjs` bağlantı hatasında `conn` `undefined` kalır ve `conn.db()` ile süreç patlar.
   Çözüm: retry/backoff + hata durumunda `process.exit(1)` (K8s restart etsin). Bağlantı stringi `ATLAS_URI` env'inden gelir, `config.env` dosyasına bağımlılık kalkar.
3. **Readiness ayrımı.** `/healthcheck` yalnızca process canlılığını döner, Mongo'yu kontrol etmez.
   Çözüm: `livenessProbe` → `/healthcheck`, `readinessProbe` → Mongo ping içeren `/healthcheck/ready`.
4. **Port ve host.** Backend `0.0.0.0`'a bind etmeli; `PORT` env ile override edilebilmeli.
5. **CORS.** nginx proxy ile same-origin olunacağı için `cors()` kısıtlanır (prod'da sadece bilinen origin).

**Çıktı:** uygulama `docker compose up` ile lokalde uçtan uca çalışır, Cypress testi yeşildir.

---

## Aşama 2 — Konteynerleştirme

- **Backend** — `node:20-alpine`, multi-stage, `npm ci --omit=dev`, non-root `USER node`, `dumb-init`/`tini` ile PID 1.
- **Frontend** — stage 1 `node:20-alpine` (`npm ci && npm run build`), stage 2 `nginx:alpine`; nginx conf'ta `/api` proxy, SPA fallback (`try_files ... /index.html`), gzip. Non-root nginx (port 8080).
- **ETL** — `python:3.12-slim`, `requirements.txt` (`requests` pinlenmiş), non-root.
- **MongoDB** — resmi `mongo:7` imajı; **yeniden derlenmez**, StatefulSet ile çalıştırılır.

**Kurallar**
- Base image'lar **digest veya sabit minor tag** ile pinlenir; `latest` yasak.
- Her image'da `.dockerignore` (node_modules, .git, cypress videoları).
- Katman sırası: önce bağımlılık dosyaları, sonra kaynak kod (cache verimliliği).
- Image'lar `HEALTHCHECK` içerir ve **root olmayan** kullanıcıyla çalışır.
- Lokal geliştirme için `docker-compose.yml` (3 servis + mongo) — ama prod yolu K8s'tir.

**Çıktı:** `docker/` altında 3 Dockerfile, `nginx.conf`, `docker-compose.yml`.

---

## Aşama 3 — Altyapı (Terraform)

Modüller: `network` (VPC, 2 AZ, public/private subnet, NAT), `eks` (managed node group, OIDC provider), `ecr` (3 repo + lifecycle policy), `iam` (IRSA rolleri), `addons` (ALB Controller, ExternalDNS, metrics-server).

**Kurallar**
- State **remote** (S3 + DynamoDB kilit); `terraform.tfstate` asla commit'lenmez.
- `dev` / `prod` ayrımı workspace değil **ayrı `envs/` dizini + tfvars** ile yapılır.
- Provider ve modül sürümleri pinlenir; `terraform fmt` + `validate` + `tflint` CI'da zorunlu.
- Node'lar private subnet'te; cluster endpoint public ama CIDR kısıtlı.
- Hiçbir secret tfvars'a düz yazılmaz → AWS Secrets Manager.

**Çıktı:** `terraform/` — `terraform apply` ile sıfırdan çalışan EKS.

---

## Aşama 4 — Kubernetes Manifestleri

```
k8s/
  base/       namespace, backend, frontend, mongodb (StatefulSet+PVC),
              etl-cronjob, services, ingress, configmap, secret(ExternalSecret),
              hpa, pdb, networkpolicy
  overlays/dev, overlays/prod
```

- **Backend**: Deployment, replica 2, `resources.requests/limits`, liveness+readiness, HPA (CPU %70, 2→6).
- **Frontend**: Deployment, replica 2, nginx, HPA.
- **MongoDB**: StatefulSet + `volumeClaimTemplates` (gp3), Headless Service, kimlik bilgileri Secret'tan.
- **ETL**: `CronJob` — `schedule: "0 * * * *"`, `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`, `backoffLimit: 2`, `restartPolicy: OnFailure`. **README kabul kriteri budur.**
- **Ingress**: AWS ALB Controller, `/` → frontend, TLS (ACM sertifikası), HTTP→HTTPS yönlendirme.

**Kurallar**
- Her pod: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `drop: ALL`.
- Her workload'da requests/limits **zorunlu**.
- Varsayılan `deny-all` NetworkPolicy; yalnız gerekli yollar açılır (frontend→backend, backend→mongo).
- `imagePullPolicy` sabit tag ile değil, **commit SHA tag'i** ile kullanılır → `IfNotPresent` güvenli.
- Deployment'larda `RollingUpdate` + `maxUnavailable: 0`.

---

## Aşama 5 — CI/CD (GitHub Actions)

**Pipeline A — `mern.yml`** (tetik: `mern-project/**` değişikliği)
1. Lint & unit test (client)
2. `docker compose up` → **Cypress e2e** (`endToEnd.spec.js`) → artifact olarak video/screenshot
3. Image build (buildx + cache) → **Trivy taraması** (HIGH/CRITICAL'de fail) → ECR push, tag = `git sha` + `latest`
4. `kustomize edit set image` → EKS'e deploy → `kubectl rollout status` (başarısızsa otomatik `rollout undo`)
5. Deploy sonrası smoke test: `/healthcheck` ve `/record` 200 dönmeli

**Pipeline B — `etl.yml`** (tetik: `python-project/**`): lint (`ruff`) → build → Trivy → push → CronJob image güncelle.

**Kurallar**
- AWS erişimi **OIDC ile federated role**; uzun ömürlü `AWS_ACCESS_KEY` secret'ı yok.
- `main`'e doğrudan push kapalı; PR + yeşil CI zorunlu.
- `prod` ortamı GitHub Environments ile **manuel onaya** bağlı.
- Test aşaması atlanamaz; deploy yalnızca testler geçerse çalışır.

---

## Aşama 6 — Logging, Monitoring, Alerting

- **Loglar**: uygulamalar stdout'a **JSON** yazar (backend `pino`, ETL `logging` + JSON formatter). Grafana Alloy toplar → Loki → Grafana. Retention 14 gün.
- **Metrikler**: kube-prometheus-stack; node/pod metrikleri + backend `/metrics` (prom-client: istek sayısı, hata oranı, latency).
- **Dashboard'lar**: Cluster sağlığı, MERN servis latency/hata oranı, MongoDB, ETL job başarı geçmişi.
- **Alert kuralları (kritik olaylar)**:
  - `PodCrashLooping` (5 dk)
  - Backend 5xx oranı > %5 (5 dk)
  - `/healthcheck` readiness başarısız > 2 dk
  - MongoDB PVC doluluk > %80
  - **ETL CronJob son 1 saatte başarıyla tamamlanmadı** (kabul kriterinin doğrulaması)
  - Node NotReady / bellek baskısı
- Alertmanager → Slack webhook (+ severity=critical için e-posta).

---

## Aşama 7 — Güvenlik Kontrol Listesi

- [ ] Git'te düz secret yok; `.gitignore`'a `config.env`, `*.tfvars`, `kubeconfig` eklendi
- [ ] Tüm container'lar non-root, read-only rootfs
- [ ] NetworkPolicy default-deny
- [ ] Image'larda Trivy taraması CI'da bloklayıcı
- [ ] MongoDB dışarıya açık değil (ClusterIP), auth açık, güçlü parola Secrets Manager'da
- [ ] Ingress'te TLS zorunlu, HTTP→HTTPS
- [ ] IRSA ile pod bazlı en az yetki; node role'ünde geniş izin yok
- [ ] ECR image scan on push açık
- [ ] Dependabot açık

---

## Aşama 8 — Teslim Paketi

Case metnindeki 6 madde ile birebir eşleşme:

| Case maddesi | Karşılığı |
|---|---|
| 1. Dockerfile'lar | `docker/Dockerfile.{client,server,etl}` + `nginx.conf` |
| 2. K8s yapılandırmaları | `k8s/base`, `k8s/overlays/*` |
| 3. Her iki proje için CI/CD | `.github/workflows/mern.yml`, `etl.yml` |
| 4. IaC | `terraform/` (modüller + `envs/`) |
| 5. Belgeler | `README.md` (mimari + adım adım deploy + karşılaşılan zorluklar), `ARCHITECTURE.md`, bu dosya |
| 6. Ekran görüntüleri | `docs/screenshots/` — canlı URL'de frontend listesi, kayıt oluşturma, `/healthcheck` JSON, `kubectl get pods`, CronJob job geçmişi, Grafana dashboard, yeşil pipeline |

**Ekran görüntüsü kuralı:** hepsinde tarayıcının adres çubuğundaki **public URL** görünür olmalı; `localhost` görüntüsü kabul edilmez.

---

## Çalışma Kuralları

1. **Sıra bozulmaz.** Aşama 1 bitmeden Aşama 2'ye geçilmez — çalışmayan uygulama konteynerleştirilmez.
2. **Her aşama kendi başına doğrulanır** (lokal compose → tek node kind/minikube → EKS).
3. Commit'ler **Conventional Commits** (`feat:`, `fix:`, `ci:`, `docs:`), küçük ve atomik.
4. Branch: `main` korumalı, iş `feat/<konu>` dallarında, PR ile birleşir.
5. Uygulama kaynak koduna yapılan **her** değişiklik, gerekçesiyle `README.md`'nin "Karşılaşılan Zorluklar" bölümüne yazılır.
6. Manuel `kubectl apply` ile prod'a müdahale yok — tek dağıtım yolu pipeline'dır.
7. Bilinmeyen bir karar çıkarsa varsayım yazılır, dokümante edilir, ilerlenir.

---

## Zaman Planı (3 gün)

| Gün | İş |
|---|---|
| 1 | Aşama 1 + 2: kod düzeltmeleri, Dockerfile'lar, compose ile uçtan uca çalışan sistem, Cypress yeşil |
| 2 | Aşama 3 + 4: Terraform ile EKS, manifestler, ilk canlı deploy, Ingress + TLS |
| 3 | Aşama 5 + 6 + 8: pipeline'lar, monitoring/alerting, güvenlik listesi, dokümantasyon, ekran görüntüleri |

**Öncelik sırası:** README'deki 4 kabul kriteri (Mongo bağlı · endpoint'ler çalışıyor · sayfalar çalışıyor · ETL saatte 1) her şeyden önce gelir. Zaman daralırsa önce monitoring derinliği, sonra prod/dev overlay ayrımı kısılır; bu dört madde asla kısılmaz.
