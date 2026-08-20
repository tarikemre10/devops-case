# DevOps Case — Uygulama Planı, Kurallar ve Kabul Kriterleri

Bu doküman, case metnindeki gereklilikleri somut aşamalara ve uyulacak kurallara çevirir.
Case metni: `Case Tanıtım Metni_Tr.txt` · Kabul kriterleri: `README.md` · Hedef mimari: `MIMARI.md`

> **Durum:** **Aşama 1 ve 2 tamamlandı ve doğrulandı.** `docker compose up` ile sistem
> uçtan uca çalışıyor, Cypress e2e üretim artefaktına karşı 3/3 geçiyor, üç imaj da
> non-root ve Trivy'de **0 HIGH/CRITICAL** bulgu veriyor.
> Aşama 0 sürüyor (AWS hesabı), Aşama 3 ve sonrası planlanmış durumda.
> Ayrıntılar ve doğrulama kanıtları: `docs/KARSILASILAN_ZORLUKLAR.md`

---

## 0. Kapsam ve Teknoloji Kararları

| Alan | Karar | Gerekçe |
|---|---|---|
| Bulut | **AWS** (`eu-central-1`) | EKS + ECR + IAM/IRSA olgun, case'te serbest bırakılmış; Frankfurt en düşük gecikme |
| Orkestrasyon | **Kubernetes (EKS)**, managed node group **3 × `t3.medium`** | Case'in açık gerekliliği; boyutlandırma gerekçesi aşağıda |
| IaC | **Terraform** (remote state: S3 + DynamoDB lock) | Modüler, versiyonlanabilir |
| CI/CD | **GitHub Actions** + OIDC federated role | Repo GitHub'da teslim edilecek, uzun ömürlü anahtar yok |
| Registry | **Amazon ECR** | Cluster ile aynı hesapta, scan-on-push |
| Manifest yönetimi | **Kustomize**, tek `overlays/prod` | Helm'e göre daha az soyutlama, review'da okunur |
| TLS / giriş noktası | **CloudFront → ALB** | **Kayıtlı domain yok**; CloudFront ücretsiz geçerli sertifika (`*.cloudfront.net`) verir |
| Gözlemlenebilirlik | **kube-prometheus-stack** + **Loki + Grafana Alloy** | Metrik + log tek Grafana'da |
| Alerting | **Alertmanager → Slack** | Case'teki "kritik olaylar için uyarı" maddesi |
| Secret | Terraform ile üretilen **K8s Secret** (`random_password`) | Git'te düz secret yok; ESO prod yolu olarak README'de not edilir |

> Bu tablo tek doğruluk kaynağıdır. Bir teknoloji değişirse önce burası güncellenir.

### Kapsam dışı bırakılanlar (bilinçli kesimler)

3 günlük süre ve tek kişilik ekip gerçeğiyle aşağıdakiler **kapsam dışıdır**; her biri
teslim `README.md`'sinde "prod'a geçiş yolu" olarak not edilir:

| Kesilen | Yerine | Gerekçe |
|---|---|---|
| External Secrets Operator + Secrets Manager | Terraform üretimli K8s Secret | Ayrı IRSA + CRD + debug maliyeti; güvenlik hedefi (git'te düz secret yok) zaten karşılanıyor |
| Route53 + ACM + ExternalDNS | CloudFront varsayılan sertifikası | Kayıtlı domain yok |
| `dev` / `prod` overlay ayrımı | Tek `base` + `overlays/prod` | Kustomize hata yüzeyini yarıya indirir |
| Cluster Autoscaler | Sabit 3 node + HPA | Ölçekleme yeteneği HPA ile zaten kanıtlanır |
| Frontend HPA | Yalnız backend HPA | Aynı yetenek, yarı yapılandırma |
| Backend `prom-client` `/metrics` | kube-state-metrics + ALB/CloudFront metrikleri | Uygulama koduna daha az müdahale |
| MongoDB ReplicaSet (3 node) | Tek replica StatefulSet | Demo dağıtımı; sınır README'de açıkça yazılır |

### Servis envanteri (koddan çıkarıldı)

| Bileşen | Kaynak | Port | Notlar |
|---|---|---|---|
| Frontend | `mern-project/client` (CRA 5 + React 18) | 3000 (dev) / 8080 (nginx) | Cypress 4.x e2e mevcut |
| Backend | `mern-project/server` (Express, ESM) | 5050 | `/record` CRUD, `/healthcheck` |
| Veritabanı | MongoDB | 27017 | DB `sample_training`, koleksiyon `records` |
| ETL | `python-project/ETL.py` | — | Saatte 1 çalışacak (CronJob) |

---

## Aşama 0 — AWS Hesabı ve Ön Koşullar (kritik yol)

**Bu aşama her şeyden önce başlatılır.** Yeni AWS hesabının aktivasyonu saatler sürebilir;
Gün 2'yi tek başına kilitleyebilecek risk budur.

1. AWS hesabı aç, kart doğrulamasını tamamla, **aktivasyon e-postasını bekle**.
2. Root hesaba MFA; günlük iş için admin yetkili IAM kullanıcısı; `aws configure`.
3. **Billing Budget: 40 USD** eşiğinde e-posta uyarısı.
4. **Service Quotas kontrolü** — yeni hesaplarda `Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances`
   kotası düşük gelebilir. `eu-central-1`'de en az 6 vCPU (3 × `t3.medium`) olduğunu doğrula.
   Artırma talebi 24–48 saat sürer; bunu Gün 2 sabahı öğrenmek kabul edilemez.
5. Bölge sabiti: **`eu-central-1`**.

**Çıktı:** `aws sts get-caller-identity` çalışıyor, bütçe alarmı kurulu, kota yeterli.

> Aşama 1 ve 2 AWS gerektirmez; hesap beklenirken bunlar yürütülür.

### Maliyet tahmini (3 gün)

| Kalem | Yaklaşık |
|---|---|
| EKS control plane (0.10 $/saat) | ~7 $ |
| 3 × `t3.medium` node | ~9.3 $ |
| NAT Gateway (**tek AZ'de 1 adet**) | ~3.5 $ |
| ALB + CloudFront + EBS + ECR | ~3 $ |
| **Toplam** | **~23 $** |

Teslim ekran görüntüleri alındıktan **sonra** `terraform destroy` çalıştırılır.

### Node boyutlandırma gerekçesi

`t3.medium` (2 vCPU / 4 GB) × 3 seçildi. Karşılaştırma:

| | 2 × `t3.large` | **3 × `t3.medium`** | 2 × `t3.medium` |
|---|---|---|---|
| Allocatable bellek | ~13.5 GB | **~10 GB** | ~6.6 GB |
| Sistem + addon'lar | ~1.5 GB | ~2 GB | ~1.5 GB |
| Uygulama (fe+be+mongo) | ~1 GB | ~1 GB | ~1 GB |
| Monitoring'e kalan | ~11 GB | **~7 GB** | ~4 GB |
| 3 günlük maliyet | ~12.4 $ | **~9.3 $** | ~6.2 $ |
| Değerlendirme | Gereğinden büyük | **Seçilen** | Sınırda — Gün 3'te Prometheus `Pending` riski |

- kube-prometheus-stack + Loki + Alloy gerçekte ~4–5 GB ister. 2 × `t3.medium`'da bu marj
  yok; sorun tam da Gün 3 akşamı, en kötü anda çıkar.
- 3 node, 2 node'dan **hem daha ucuz hem teslimde daha güçlü**: PDB, pod anti-affinity,
  HPA 2→6 dağılımı ve node kaybı senaryosu gerçekten gösterilebilir hâle gelir.
- **`t3.small` ve altı kullanılamaz:** allocatable ~1.4 GB'ı DaemonSet'ler tek başına yer;
  ayrıca VPC CNI `max-pods` limiti `t3.small`'da **11**, `t3.medium`'da **17**'dir.
- `credit_specification = "standard"` bırakılır (unlimited değil) — 3 günlük demo yükünde
  burst kredisi yetiyor, beklenmedik fatura riski doğmuyor.
- Bellek yine de sıkışırsa çözüm node büyütmek değil, **Aşama 6 tampon kuralıdır**:
  Loki + Alloy kesilir, Prometheus + Alertmanager + `ETLJobMissing` kalır (~1.5 GB).

---

## Aşama 1 — Kod Hazırlığı ✅ **TAMAMLANDI**

Bu maddeler yapılmadan uygulama cluster'da **çalışmaz**. Uygulama mantığına dokunulmadı,
yalnızca dağıtılabilirlik düzeltildi. 14 maddenin tamamı uygulandı ve doğrulandı;
kanıtlar `docs/KARSILASILAN_ZORLUKLAR.md`'de.

İnceleme sırasında plana **4 madde eklendi**: `record.mjs` HTTP status kodları (11),
`pino` JSON log (12), `setupProxy.js` dev proxy (13), `api.js` tek sabit (14).

1. **Frontend'deki hard-coded API adresi.**
   `client/src/components/{recordList,create,edit,healthcheck}.js` içinde 6 yerde `http://localhost:5050` sabit yazılı.
   Çözüm: tüm çağrılar `/api/...` göreli yoluna alınır; nginx `/api` → backend Service'e reverse-proxy yapar.
   (Alternatif `REACT_APP_API_URL` build-arg'dır; ancak CRA env'i build-time gömdüğü için aynı image ortamlar arası taşınamaz → **göreli yol tercih edilir**.)
2. **Backend Mongo bağlantısı.** `server/db/conn.mjs` bağlantı hatasında `conn` `undefined` kalır ve `conn.db()` ile süreç patlar.
   Çözüm: retry/backoff + hata durumunda `process.exit(1)` (K8s restart etsin). Bağlantı stringi `ATLAS_URI` env'inden gelir, `config.env` dosyasına bağımlılık kalkar.
3. **Readiness ayrımı.** `/healthcheck` yalnızca process canlılığını döner, Mongo'yu kontrol etmez.
   Çözüm: `livenessProbe` → `/healthcheck`, `readinessProbe` → Mongo ping içeren `/healthcheck/ready`.
4. **Port ve host.** Backend `0.0.0.0`'a bind etmeli; `PORT` env ile override edilebilmeli; `SIGTERM`'de graceful shutdown.
5. **CORS.** nginx proxy ile same-origin olunacağı için `cors()` kısıtlanır (varsayılan kapalı, `CORS_ORIGINS` ile açılır).
6. **`loadEnvironment.mjs`.** `config.env` opsiyonel hâle gelir; konteynerde konfigürasyon env'den gelir.
7. **Cypress testi.** `endToEnd.spec.js` kayıt ekledikten sonra `/` adresinde `Employee1` arıyor; ancak `/` rotası
   `HealthStatus` render ediyor (liste `/records`'ta) → test hiçbir zaman geçemez.
   **Uygulama rotalarına dokunulmaz, test düzeltilir.** `cypress.json`'a `baseUrl` eklenir.
8. **ETL log sarmalayıcı.** `ETL.py` **değiştirilmez**; JSON log gereksinimi `python-project/runner.py`
   sarmalayıcısı ile karşılanır (ETL'i çağırır, stdout'u yapılandırılmış log'a çevirir).

**Çıktı:** uygulama `docker compose up` ile lokalde uçtan uca çalışır, Cypress testi yeşildir.

---

## Aşama 2 — Konteynerleştirme ✅ **TAMAMLANDI**

- **Backend** — `node:20-alpine`, multi-stage, `npm ci --omit=dev`, non-root `USER node`, `tini` ile PID 1.
- **Frontend** — stage 1 `node:20-alpine` (`npm ci && npm run build`), stage 2 `nginx:1.27-alpine`; nginx conf'ta `/api` proxy, SPA fallback (`try_files ... /index.html`), gzip. Non-root nginx (port 8080).
- **ETL** — **`python:3.12-alpine`** (slim'de 36 düzeltilebilir CVE vardı), `requirements.txt` (`requests` pinlenmiş), non-root uid 10001, entrypoint `runner.py`.
- **MongoDB** — resmi `mongo:7.0` imajı; **yeniden derlenmez**, StatefulSet ile çalıştırılır.

**Kurallar**
- Base image'lar **SHA256 digest** ile pinlenir (`latest` ve mutable tag yasak); üstüne
  `apk upgrade` katmanı eklenir — digest tekrarlanabilirliği, upgrade güncelliği sağlar.
- Her image'da `.dockerignore` (node_modules, .git, cypress videoları).
- Katman sırası: önce bağımlılık dosyaları, sonra kaynak kod (cache verimliliği).
- Image'lar `HEALTHCHECK` içerir ve **root olmayan** kullanıcıyla çalışır.

**nginx'te iki zorunlu ayrıntı** (yoksa pod açılmaz):
1. **Değişkenli `proxy_pass` + resolver.** Sabit upstream adı yazılırsa nginx başlangıçta DNS
   çözümlemeye çalışır ve backend Service henüz yokken CrashLoop'a girer:
   ```nginx
   resolver kube-dns.kube-system.svc.cluster.local valid=10s;
   set $backend_upstream http://backend.mern.svc.cluster.local:5050;
   location /api/ { proxy_pass $backend_upstream/; }
   ```
2. **`readOnlyRootFilesystem` ile `emptyDir` mount'ları:** `/var/cache/nginx`, `/var/run`, `/tmp`.

**Lokal doğrulama:** `docker-compose.yml` — mongo + backend + frontend + **`cypress/included:4.12.1`**
servisi. Repo `cypress ^4.2.0` + `cypress.json` + `integration/` düzenini kullanıyor; Cypress 10+
imajları bu testleri bulamaz, sürüm bu yüzden pinlenir.

**Çıktı:** `docker/Dockerfile.{server,client,etl}`, `docker/nginx/default.conf.template`,
kökte `docker-compose.yml`, üç `.dockerignore`.

**Sonuç:** frontend 63 MB · etl 52 MB · backend 153 MB; üçü de non-root ve
Trivy'de 0 HIGH/CRITICAL (ilk taramada 95 düzeltilebilir bulgu vardı, hepsi kapatıldı).

---

## Aşama 3 — Altyapı (Terraform)

Modüller: `network`, `eks`, `ecr`, `iam`, `addons`, `edge`.

| Modül | İçerik |
|---|---|
| `network` | VPC 10.0.0.0/16, 2 AZ, public/private subnet, **tek NAT Gateway** (maliyet) |
| `eks` | Managed node group 3 × `t3.medium`, OIDC provider, private node'lar |
| `ecr` | 3 repo (client/server/etl) + lifecycle policy + scan-on-push |
| `iam` | IRSA rolleri + **GitHub Actions OIDC federated role** |
| `addons` | **1. `aws-ebs-csi-driver` (+IRSA)**, 2. `gp3` StorageClass, 3. AWS Load Balancer Controller, 4. metrics-server |
| `edge` | CloudFront distribution + ALB Security Group kısıtı |

> **`aws-ebs-csi-driver` listenin ilk maddesidir.** EKS 1.23+ sürümünde bu addon ve IRSA rolü
> olmadan MongoDB'nin `volumeClaimTemplates` PVC'si kalıcı olarak `Pending`'de kalır.
> `gp3` StorageClass'ı da elle tanımlanır — EKS varsayılanı `gp2`'dir.

**Kurallar**
- State **remote** (S3 + DynamoDB kilit); `terraform.tfstate` asla commit'lenmez.
- Provider ve modül sürümleri pinlenir; `terraform fmt` + `validate` + `tflint` CI'da zorunlu.
- Node'lar private subnet'te; cluster endpoint public ama CIDR kısıtlı.
- Hiçbir secret tfvars'a düz yazılmaz → `random_password` + K8s Secret.
- **OIDC role Gün 2'de kurulur**, Gün 3'e bırakılmaz (trust policy debug'ı tipik olarak 1–2 saat yer).

**Çıktı:** `terraform/` — `terraform apply` ile sıfırdan çalışan EKS.

---

## Aşama 4 — Kubernetes Manifestleri

```
k8s/
  base/       namespace, backend, frontend, mongodb (StatefulSet+PVC),
              etl-cronjob, services, ingress, configmap, secret,
              hpa, pdb, networkpolicy
  overlays/prod/
```

- **Backend**: Deployment, replica 2, `resources.requests/limits`, liveness+readiness, HPA (CPU %70, 2→6).
- **Frontend**: Deployment, replica 2, nginx, HPA yok (kapsam dışı).
- **MongoDB**: StatefulSet + `volumeClaimTemplates` (gp3 10Gi), Headless Service, kimlik bilgileri Secret'tan.
- **ETL**: `CronJob` — `schedule: "0 * * * *"`, `concurrencyPolicy: Forbid`, `successfulJobsHistoryLimit: 3`, `backoffLimit: 2`, `restartPolicy: OnFailure`. **README kabul kriteri budur.**
- **Ingress**: AWS Load Balancer Controller → ALB; TLS CloudFront katmanında sonlanır.

**Kurallar**
- Her pod: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `drop: ALL`, `seccompProfile: RuntimeDefault`.
- Her workload'da requests/limits **zorunlu**.
- Varsayılan `deny-all` NetworkPolicy; yalnız gerekli yollar açılır (frontend→backend, backend→mongo).
- Image tag = **commit SHA** → `imagePullPolicy: IfNotPresent` güvenli.
- Deployment'larda `RollingUpdate` + `maxUnavailable: 0`.
- PDB `minAvailable: 1` (frontend/backend).

**Uygulama sırası (bağımlılık zinciri):** mongodb → backend → frontend → ingress → cronjob.

---

## Aşama 5 — CI/CD (GitHub Actions)

**Pipeline A — `mern.yml`** (tetik: `mern-project/**` değişikliği)
1. Lint & unit test (client)
2. `docker compose up` → **Cypress e2e** (`endToEnd.spec.js`) → artifact olarak video/screenshot
3. Image build (buildx + cache) → **Trivy taraması** → ECR push, tag = `git sha`
4. `kustomize edit set image` → EKS'e deploy → `kubectl rollout status` (başarısızsa otomatik `rollout undo`)
5. Deploy sonrası smoke test: `/healthcheck` ve `/api/record` 200 dönmeli

**Pipeline B — `etl.yml`** (tetik: `python-project/**`): lint (`ruff`) → build → Trivy → push → CronJob image güncelle.

**Kurallar**
- AWS erişimi **OIDC ile federated role**; uzun ömürlü `AWS_ACCESS_KEY` secret'ı yok.
- `main`'e doğrudan push kapalı; PR + yeşil CI zorunlu.
- Test aşaması atlanamaz; deploy yalnızca testler geçerse çalışır.
- **Trivy ayarı:** `--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1`.
  `--ignore-unfixed` olmadan düzeltmesi olmayan CVE'ler `main`'i kalıcı kırmızıya çevirir.
  Bu eşik Aşama 2'de lokal olarak kalibre edildi; imajlar hâlihazırda temiz geçiyor.

---

## Aşama 6 — Logging, Monitoring, Alerting

- **Loglar**: uygulamalar stdout'a **JSON** yazar — backend `pino` ve ETL `runner.py`
  **Aşama 1'de eklendi**, bu aşamada kod değişikliği gerekmiyor. Grafana Alloy toplar → Loki → Grafana. Retention 14 gün.
- **Metrikler**: kube-prometheus-stack (node/pod/kube-state-metrics) + CloudWatch üzerinden ALB 5xx.
- **Dashboard'lar**: Cluster sağlığı, MERN servis durumu, MongoDB, ETL job başarı geçmişi.
- **Alert kuralları (kritik olaylar)**:
  - `PodCrashLooping` (5 dk)
  - ALB target 5xx oranı > %5 (5 dk)
  - Backend readiness başarısız > 2 dk
  - MongoDB PVC doluluk > %80
  - **ETL CronJob son 1 saatte başarıyla tamamlanmadı** (kabul kriterinin doğrulaması)
  - Node NotReady / bellek baskısı
- Alertmanager → Slack webhook (webhook URL git'e girmez).

> **Tampon kuralı:** Gün 3 saat 14:00'te bu aşama bitmediyse **Loki + Alloy kesilir**;
> Prometheus + Alertmanager + `ETLJobMissing` bırakılır. Dokümantasyon ve ekran görüntüleri
> her zaman monitoring derinliğinden önce gelir.

---

## Aşama 7 — Güvenlik Kontrol Listesi

- [ ] Git'te düz secret yok; `.gitignore`'a `config.env`, `*.tfvars`, `kubeconfig`, `*.tfstate` eklendi
- [ ] Tüm container'lar non-root, read-only rootfs, `drop: ALL`
- [ ] NetworkPolicy default-deny
- [ ] Image'larda Trivy taraması CI'da bloklayıcı (`--ignore-unfixed`)
- [ ] MongoDB dışarıya açık değil (ClusterIP), auth açık, parola `random_password` ile üretilmiş
- [ ] **CloudFront'ta TLS zorunlu (`redirect-to-https`); ALB Security Group yalnız
      `com.amazonaws.global.cloudfront.origin-facing` prefix list'ine açık** → ALB'ye doğrudan erişim kapalı
- [ ] IRSA ile pod bazlı en az yetki; node role'ünde geniş izin yok
- [ ] ECR image scan on push açık
- [ ] GitHub Actions OIDC; uzun ömürlü AWS anahtarı yok
- [ ] Root hesapta MFA, billing alarmı kurulu
- [ ] Dependabot açık

---

## Aşama 8 — Teslim Paketi

Case metnindeki 6 madde ile birebir eşleşme:

| Case maddesi | Karşılığı |
|---|---|
| 1. Dockerfile'lar | `docker/Dockerfile.{client,server,etl}` + `nginx.conf` |
| 2. K8s yapılandırmaları | `k8s/base`, `k8s/overlays/prod` |
| 3. Her iki proje için CI/CD | `.github/workflows/mern.yml`, `etl.yml` |
| 4. IaC | `terraform/` (modüller + `envs/prod`) |
| 5. Belgeler | `README.md` (mimari + adım adım deploy), `MIMARI.md`, `PROJE_PLANI.md`, `docs/KARSILASILAN_ZORLUKLAR.md` |
| 6. Ekran görüntüleri | `docs/screenshots/` — canlı URL'de frontend listesi, kayıt oluşturma, `/healthcheck` JSON, `kubectl get pods`, CronJob job geçmişi, Grafana dashboard, yeşil pipeline |

**Ekran görüntüsü kuralı:** hepsinde tarayıcının adres çubuğundaki **public HTTPS URL'i**
(`https://<id>.cloudfront.net`) görünür olmalı; `localhost` görüntüsü kabul edilmez.

**Ekran görüntüleri Gün 2 akşamı alınır**, Gün 3'e bırakılmaz. En sık yapılan teslim hatası budur.

---

## Çalışma Kuralları

1. **Sıra bozulmaz.** Aşama 1 bitmeden Aşama 2'ye geçilmez — çalışmayan uygulama konteynerleştirilmez.
   (Tek istisna: Aşama 0 arka planda beklerken Aşama 1–2 yürür.)
2. **Her aşama kendi başına doğrulanır** (lokal compose → EKS).
3. Commit'ler **Conventional Commits** (`feat:`, `fix:`, `ci:`, `docs:`), küçük ve atomik.
4. Branch: `main` korumalı, iş `feat/<konu>` dallarında, PR ile birleşir.
5. Uygulama kaynak koduna yapılan **her** değişiklik, gerekçesiyle `docs/KARSILASILAN_ZORLUKLAR.md`'ye yazılır.
6. Pipeline kurulduktan sonra manuel `kubectl apply` ile müdahale yok — tek dağıtım yolu pipeline'dır.
   (Gün 2'de pipeline henüz yokken elle apply serbesttir.)
7. Bilinmeyen bir karar çıkarsa varsayım yazılır, dokümante edilir, ilerlenir.

---

## Zaman Planı

| Gün | İş |
|---|---|
| **0 (bugün)** | Aşama 0: AWS hesabı + MFA + billing alarm + kota kontrolü (~30 dk, sonra bekleme). Ardından Aşama 1'e başla — AWS beklemez. |
| **1** | Aşama 1 + 2: kod düzeltmeleri (8 madde), Dockerfile'lar, compose ile uçtan uca çalışan sistem, **Cypress yeşil**. Bitiş kriteri budur. |
| **2** | Aşama 3 + 4: Terraform (EBS CSI ilk sırada) + OIDC role + CloudFront, manifestler sırayla apply, canlı HTTPS URL, **ekran görüntüleri**. |
| **3** | Aşama 5 + 6 + 7 + 8: pipeline'lar, monitoring/alerting, güvenlik listesi, README, son görüntüler, `terraform destroy`. |

**Öncelik sırası:** README'deki 4 kabul kriteri (Mongo bağlı · endpoint'ler çalışıyor · sayfalar
çalışıyor · ETL saatte 1) her şeyden önce gelir. Zaman daralırsa sırasıyla monitoring derinliği,
sonra Loki, sonra HPA/PDB kısılır; bu dört madde asla kısılmaz.
