# Karşılaşılan Zorluklar ve Kaynak Kodu Değişiklikleri

Uygulama mantığına dokunulmaz; yalnızca uygulamanın konteyner/Kubernetes ortamında
**çalışabilir** hâle gelmesi için gereken düzeltmeler yapılır.
Aşama 8'de bu bölüm teslim `README.md`'sine taşınacaktır.

**Durum sütunu:** `[ ]` planlandı · `[x]` uygulandı ve doğrulandı.

---

## Aşama 1 — Kod Hazırlığı ✅ **tamamlandı ve doğrulandı**

Doğrulama: `mongo:7.0` container + `node server.mjs` + CRA dev server ile uçtan uca
çalıştırıldı; Cypress e2e **3/3 geçti** (`cypress/included:4.12.1` Docker imajıyla).

| # | Durum | Dosya | Sorun | Yapılan değişiklik |
|---|---|---|---|---|
| 1 | [x] | `client/src/components/{recordList,create,edit,healthcheck}.js` | API adresi 6 yerde `http://localhost:5050` olarak sabit yazılı; cluster içinde çalışmaz | Tüm çağrılar `/api/...` göreli yoluna alındı. nginx `/api` → backend Service reverse-proxy yapacak. CRA env değişkeni build-time gömüldüğü için `REACT_APP_API_URL` tercih edilmedi — aynı image tüm ortamlarda taşınabilir kalsın diye. |
| 2 | [x] | `server/db/conn.mjs` | Bağlantı hatasında `catch` hatayı yutuyor, `conn` `undefined` kalıyor, `conn.db()` anlamsız hata veriyor | Üstel backoff'lu retry (varsayılan 10 deneme) eklendi; tükenirse `process.exit(1)` → Kubernetes pod'u yeniden başlatır. DB adı `MONGO_DB` env'inden geliyor. |
| 3 | [x] | `server/routes/healthcheck.mjs` | `/healthcheck` yalnızca process canlılığını dönüyor, Mongo'yu kontrol etmiyor | `/healthcheck` liveness olarak korundu; Mongo `ping` yapan `/healthcheck/ready` (200/503) readiness probe için eklendi. |
| 4 | [x] | `server/server.mjs` | Port sabit `5050`, bind adresi varsayılan, graceful shutdown yok | `PORT`/`HOST` env ile override edilebilir, `0.0.0.0`'a bind ediliyor, `SIGTERM`/`SIGINT`'te `server.close()` + `client.close()` ile 10sn'lik graceful shutdown yapılıyor. |
| 5 | [x] | `server/server.mjs` | `cors()` her origin'e açık | nginx proxy ile same-origin olunacağından varsayılan kapalı (middleware hiç eklenmiyor); istisnalar `CORS_ORIGINS` env'i ile veriliyor. |
| 6 | [x] | `server/loadEnvironment.mjs` | `config.env` dosyası zorunlu gibi davranıyor | Dosya opsiyonel hâle geldi (`fs.existsSync` kontrolü); yolu `ENV_FILE` ile değiştirilebilir. Konteynerde konfigürasyon env'den gelir. |
| 7 | [x] | `server/.env-example` | Yalnızca boş `ATLAS_URI` var | Tüm env değişkenleri açıklamalarıyla örneklendi. |
| 8 | [x] | `client/cypress/integration/endToEnd.spec.js` | Test, kayıt ekledikten sonra `/` adresinde `Employee1` arıyor; ancak `/` rotası `HealthStatus` bileşenini render ediyor (liste `/records`'ta) → **test hiçbir zaman geçemez** | Uygulama rotalarına dokunulmadı, **test düzeltildi**: liste doğrulaması `/records` üzerinde yapılıyor, `after()` temizlik hook'u da önce `/records`'a gidiyor (Delete butonu yalnızca orada var). Ayrıca proxy yolunu doğrulayan `/api/healthcheck/` testi eklendi. |
| 9 | [x] | `client/cypress.json` | Boş (`{}`); adresler testte hard-coded | `baseUrl` (`http://localhost:3000`), `defaultCommandTimeout`, `video` tanımlandı; CI ve compose `CYPRESS_baseUrl` ile ezer. |
| 10 | [x] | `python-project/runner.py` *(yeni)* | ETL'in JSON log üretmesi gerekiyor ama `ETL.py` değiştirilemez | `ETL.py`'yi çağıran, stdout'unu yapılandırılmış JSON log'a çeviren ve çıkış kodunu aynen döndüren sarmalayıcı eklendi. Container entrypoint bu olacak. |
| 11 | [x] | `server/routes/record.mjs` | Beş route'un hepsinde `res.send(x).status(N)` yazılmış. Express'te `status()` `send()`'den **sonra** çağrılınca etkisizdir — yanıt zaten gönderilmiştir. Sonuç: kayıt bulunamadığında `404` yerine **`200 "Not found"`** dönüyordu | Altı yerde sıra `res.status(N).send(x)` olarak çevrildi. `204 No Content` gövde göndermeyi yasakladığı ve kod gövde gönderdiği için POST yanıtı `201 Created` yapıldı. **Gerekçe:** Aşama 5'teki smoke test ve Aşama 6'daki hata oranı alert'i doğru status kodlarına dayanır; 404'ler 200 görünürse izleme yalan söyler. İş mantığı değişmedi, yalnızca HTTP protokolü düzeltildi. |
| 12 | [x] | `server/logger.mjs` *(yeni)*, `server.mjs`, `db/conn.mjs` | `console.log` düz metin yazıyordu; Loki'de `level`, `service` gibi alanlara göre sorgulama yapılamazdı | `pino` ile yapılandırılmış JSON log. `LOG_LEVEL` env'i ile seviye ayarı, `service: "mern-server"` etiketi, ISO zaman damgası. Aşama 6'da Loki'ye bağlanırken backend koduna dönmek gerekmeyecek. |
| 13 | [x] | `client/src/setupProxy.js` *(yeni)* | Göreli `/api` yoluna geçince CRA dev server (`:3000`) isteği olduğu gibi iletiyor ve 404 alıyor; `package.json`'daki basit `proxy` alanı **path rewrite yapamaz** | `http-proxy-middleware` ile `^/api` → `` rewrite'ı. nginx'in prod davranışının birebir aynısı, böylece dev ve prod aynı kod yolunu kullanır. Paket zaten `react-scripts` bağımlılığı — **yeni npm paketi eklenmedi**. |
| 14 | [x] | `client/src/api.js` *(yeni)* | 6 çağrı adresi 4 dosyaya dağılmıştı | Tek `API_URL` sabiti; tüm bileşenler bunu import ediyor. Adres değişikliği tek yerden yapılır. |

### Doğrulama kanıtları

| Test | Sonuç |
|---|---|
| `GET /healthcheck` (liveness) | `200 {"uptime":…,"message":"OK",…}` |
| `GET /healthcheck/ready` (Mongo ayakta) | `200 {"status":"ready","mongo":"up"}` |
| **`GET /healthcheck/ready` (Mongo kapalı)** | **`503 {"status":"not-ready","mongo":"down"}` — liveness aynı anda `200` kaldı** |
| Mongo geri geldiğinde | Sürücü kendiliğinden yeniden bağlandı, readiness restart olmadan `200`'e döndü |
| `GET /record/<olmayan-id>` | `404` (önceden `200`) |
| `POST /record` | `201` (önceden `200`) |
| Mongo kapalıyken fresh start | 3 retry log'u → `mongo.giving_up` → **`exit 1`** |
| `SIGTERM` | `server.shutdown_started` → `server.shutdown_complete` → `exit 0` |
| Dev proxy | `localhost:3000/api/record/` → backend `/record/` → `200` |
| **Cypress e2e** | **3/3 geçti** (önceden hiç geçemiyordu) |
| `runner.py` başarılı çalışma | JSON log + `exit 0` |
| `runner.py` hata senaryosu | `etl.failed` + traceback + **`exit 1`** |

### Beklenmedik bulgu: Cypress lokalde çalışmıyor

`npx cypress run` Ubuntu 24.04'te başlamıyor — Cypress 4.12.1 (2020) Electron sürümü
modern sistem kütüphaneleriyle uyumsuz (`bad option: --no-sandbox`).

**Çözüm:** testler `cypress/included:4.12.1` Docker imajı içinde çalıştırılıyor:
```bash
docker run --rm --network host -v "$PWD":/e2e -w /e2e cypress/included:4.12.1
```
Bu, F maddesindeki sürüm pinleme kararını doğrular ve Aşama 5'te CI'ın da aynı imajı
kullanacağı anlamına gelir — "benim makinemde çalışıyor" sınıfı bir fark kalmaz.

> Not: imaj `root` olarak çalıştığı için ürettiği `cypress/videos` ve `cypress/screenshots`
> dizinleri root sahipli olur. Her ikisi de `.gitignore`'a eklendi.

### Açık not
`ETL.py` içeriğine **dokunulmadı** (case gereği). Log gereksinimi 10. madde ile sarmalayıcı
üzerinden karşılandı; çıktı stdout'tan Grafana Alloy ile toplanacak.

---

## Aşama 2–4 — Altyapı Tuzakları (deploy'u durduran, önceden tespit edilmiş maddeler)

Bunlar kaynak kodu değişikliği değildir; ancak ilk denemede sistemi çalışmaz hâle getiren
ve bu yüzden önceden planlanmış yapılandırma kararlarıdır.

| # | Durum | Konu | Sorun | Çözüm |
|---|---|---|---|---|
| A | [x] | **EBS CSI Driver** | EKS 1.23+ sürümünde `aws-ebs-csi-driver` addon'u ve IRSA rolü olmadan MongoDB'nin `volumeClaimTemplates` PVC'si kalıcı olarak `Pending`'de kalır; StatefulSet hiç açılmaz | Terraform `addons` modülünde **ilk sırada** kurulur; ayrıca `gp3` StorageClass elle tanımlanır (EKS varsayılanı `gp2`) |
| B | [x] | **nginx upstream DNS** | `proxy_pass` sabit yazılırsa nginx başlangıçta DNS çözümler; backend Service henüz yokken pod CrashLoop'a girer | Değişkenli `proxy_pass` + resolver. **Resolver adresi sabit yazılmıyor:** imajın `15-local-resolvers.envsh` scripti `/etc/resolv.conf`'tan okuyup `$NGINX_LOCAL_RESOLVERS`'a yazıyor → aynı template compose'da (`127.0.0.11`) ve K8s'te (kube-dns) çalışıyor. Compose'da doğrulandı. |
| C | [x] | **nginx + `readOnlyRootFilesystem`** | nginx `/var/cache/nginx`, `/run`, `/tmp` dizinlerine yazamadığı için açılmaz | Dockerfile'da bu yollar `chown nginx:nginx` yapıldı. **Dördüncü yol keşfedildi: `/etc/nginx/conf.d`** — envsubst template'i oraya render ediyor, yazamazsa script sessizce çıkıyor ve nginx varsayılan sayfayı servis ediyor. K8s'te dört `emptyDir` + `fsGroup: 101` gerekecek. |
| D | [x] | **CloudFront cache API'yi bozuyor** | Varsayılan behavior GET dışını reddeder / bayat yanıt döner; Host header origin'e taşınırsa ALB yönlendirmesi şaşar | `/api/*` için ayrı behavior: `CachingDisabled` + `AllViewerExceptHostHeader` + tüm HTTP metodları. **Doğrulandı:** CloudFront üzerinden `POST /api/record` → 201 ve hemen ardından `GET` yeni kaydı döndü (bayat yanıt yok) |
| E | [x] | **Trivy pipeline'ı kilitliyor** | Düzeltmesi olmayan CVE'ler `main`'i kalıcı kırmızıya çevirir | `--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1`. Aşama 2'de lokal olarak çalıştırıldı; **düzeltilebilir 95 bulgu çıktı ve üçü de 0'a indirildi** (aşağıya bakınız). CI eşiği artık gerçekçi. |
| F | [x] | **Cypress sürüm uyumu** | Repo `cypress ^4.2.0` + `cypress.json` + `integration/` düzenini kullanıyor; Cypress 10+ imajları bu testleri bulamaz. Ayrıca Cypress 4.x **host makinede hiç başlamıyor** (Ubuntu 24.04 kütüphane uyumsuzluğu) | `cypress/included:4.12.1` imajı pinlendi ve Aşama 1 doğrulamasında fiilen kullanıldı — 3/3 geçti |
| G | [x] | **Domain yok** | Kayıtlı domain olmadığı için Route53 + ACM ile TLS kurulamaz; ancak case public URL ve HTTPS bekliyor | ALB önüne CloudFront: ücretsiz ve geçerli `*.cloudfront.net` sertifikası, `redirect-to-https` (HTTP → **301** doğrulandı). **Sapma:** ALB'ye doğrudan erişim, planlanan Security Group prefix list'i yerine **paylaşılan `X-Origin-Verify` header'ı** ile kapatıldı — ALB listener kuralı header'sız isteğe fixed-response 403 döner. Sebep: prefix list SG kuralını ALB Controller'ın yönettiği SG'ye Terraform'dan eklemek, controller'ın kuralı geri almasıyla çakışıyor; header yöntemi Ingress annotation'ı olduğu için aynı sahibin elinde kalıyor. **Doğrulandı:** header'sız `curl` → 403 "Direct access denied", header'lı → 200 |
| H | [x] | **Yeni AWS hesabı** | Hesap aktivasyonu saatler sürebilir; yeni hesaplarda EC2 vCPU kotası düşük gelebilir ve artırma talebi 24–48 saat alır | Hesap açma + kota kontrolü Gün 0'a alındı. **Risk gerçekleşti:** kota 5 vCPU çıktı ve planlanan 3×t3.medium (6 vCPU) hiç açılmayacaktı — Aşama 3'te yakalandı, topoloji 2×t3.medium'a çekildi (madde 18) |

---

## Aşama 2 — Konteynerleştirme ✅ **tamamlandı ve doğrulandı**

Üç imaj (`docker/Dockerfile.{server,client,etl}`) + tek `nginx` template'i +
kökte `docker-compose.yml`. Doğrulama: tüm yığın ayağa kalktı, Cypress
**3/3 geçti** — bu kez CRA dev server'a değil **üretim artefaktına** (nginx +
build edilmiş SPA) karşı.

### Karşılaşılan sorunlar

| # | Durum | Konu | Sorun | Çözüm |
|---|---|---|---|---|
| 15 | [x] | **Değişkenli `proxy_pass` URI semantiğini değiştiriyor** | `location /api/ { proxy_pass $upstream/; }` yazıldığında backend'e giden her istek `/` oluyordu (`Cannot GET /`, 404). nginx dokümantasyonundaki "sondaki slash öneki soyar" kuralı **yalnızca sabit `proxy_pass` için geçerli**; direktif değişken içerdiğinde yazılan URI, isteğin URI'siyle birleştirilmez, onun **yerine konur**. | `rewrite ^/api/(.*)$ /$1 break;` + URI'siz `proxy_pass $backend_upstream;`. Bu, DNS gecikmeli çözümleme avantajını korurken önek soymayı doğru yapar. |
| 16 | [x] | **Host portu 8080 dolu** | Makinede çalışan başka bir projenin container'ı 8080'i tutuyordu; `docker compose up` "port is already allocated" ile düşüyordu | Host portları `${FRONTEND_PORT:-8080}` / `${BACKEND_PORT:-5050}` ile yapılandırılabilir yapıldı. Temiz makinede varsayılan 8080, çakışma varsa `FRONTEND_PORT=8081 docker compose up -d`. |
| 17 | [x] | **nginx template context dışında** | Template `docker/nginx/` altında duruyor (Aşama 4'te K8s ConfigMap'ine de kaynak olacak), ama client build context'i `mern-project/client` | Uygulama context'ini kirletmek yerine **named build context** kullanıldı: compose'da `additional_contexts: nginxconf: ./docker/nginx`, Dockerfile'da `COPY --from=nginxconf`. Tek doğruluk kaynağı korunur. |

### Güvenlik: Trivy bulguları 95 → 0

Trivy Aşama 5'e bırakılmayıp **burada** çalıştırıldı. İlk tarama düzeltilebilir
95 HIGH/CRITICAL bulgu verdi; hepsi kapatıldı:

| İmaj | Önce | Kaynak | Çözüm | Sonra |
|---|---|---|---|---|
| backend | 24 (1 CRITICAL) | **18'i base imajdaki npm'in kendi bağımlılıklarından** (`tar`, `minimatch`, `cross-spawn`, `sigstore` …), 4'ü express 4.18'den, 2'si alpine OS'tan | Çalışma zamanı imajından `npm` kaldırıldı (uygulama `node server.mjs` ile başlıyor, npm'e ihtiyaç yok) · express `4.18.2 → 4.22.2` · `apk upgrade` | **0** |
| frontend | 35 (2 CRITICAL) | Tamamı alpine OS paketleri (`libssl3`, `libxml2`, `libpng`, `musl`, `zlib` …) | `apk upgrade --no-cache` | **0** |
| etl | 36 | Tamamı Debian `util-linux`/`login`/`mount` ailesi — bir batch job'ın hiç kullanmadığı paketler | Base `python:3.12-slim` → **`python:3.12-alpine`** (tek bağımlılık `requests` saf Python, derleme gerekmiyor) | **0** |

> **Çıkarım:** "digest ile pinle" ve "güncel tut" birbiriyle çelişmez —
> digest tekrarlanabilirliği, `apk upgrade` katmanı güncelliği sağlar.
> Ayrıca *çalışma zamanında gerekmeyen her araç* (burada npm) saldırı yüzeyidir:
> tek bir `rm -rf` 18 CVE'yi birden kapattı.

### Doğrulama kanıtları

| Test | Sonuç |
|---|---|
| `docker compose up` sağlık zinciri | mongo healthy → backend healthy → frontend healthy |
| nginx proxy `/api/healthcheck/` · `/api/record/` | 200 · 200 |
| SPA fallback `/`, `/records`, `/create`, `/edit/abc` | dördü de 200 |
| Status kodları proxy üzerinden | olmayan kayıt **404**, POST **201** |
| Render edilmiş conf (resolver kanıtı) | `resolver 127.0.0.11 valid=10s;` — otomatik dolduruldu |
| Kullanıcı kimlikleri | backend `uid=1000(node)` · frontend `uid=101(nginx)` · etl `uid=10001(etl)` — **hiçbiri root değil** |
| PID 1 | `tini` |
| `docker compose stop backend` | `shutdown_started` → `shutdown_complete`, 10sn timeout'a düşmeden |
| ETL container | JSON log + `exit 0` |
| **Cypress (üretim artefaktına karşı)** | **3/3 geçti** |
| Trivy (üç imaj) | **0 HIGH / 0 CRITICAL** |
| İmaj boyutları | frontend 63 MB · etl 52 MB · backend 153 MB |

### Not: ETL imajında `HEALTHCHECK` yok

Bilinçli tercih. ETL sürekli çalışan bir servis değil, tek seferlik bir batch iş;
sürekli yoklanacak bir process yok. Sağlığı çıkış koduyla ölçülür — `runner.py`
hata durumunda `exit 1` döner, Kubernetes Job'ı `Failed` işaretler ve
`ETLJobMissing` alert'i tetiklenir.


---

## Aşama 3 — Altyapı (Terraform)

Stack'ler: `terraform/bootstrap` (S3 state), `terraform/envs/prod` (VPC, EKS, ECR, IAM),
`terraform/envs/edge` (CloudFront — Aşama 4'ten sonra apply edilir).

| # | Durum | Konu | Sorun | Çözüm |
|---|---|---|---|---|
| 18 | [x] | **vCPU kotası planı bozdu** | Hesabın `eu-central-1` kotası **5 vCPU**. Planlanan 3 × `t3.medium` = 6 vCPU → node group hiç açılmayacaktı. 8 vCPU talebi `CASE_OPENED` durumunda ve onay 24–48 saat sürebilir | Topoloji geçici olarak **2 × `t3.medium`** (4 vCPU) yapıldı ve cluster bu haliyle doğrulandı. **Kota 16'ya çıkarıldıktan sonra plandaki 3 node'a dönüldü** — karar tahmine değil, 2 node'lu cluster'da ölçülen değerlere dayandı: 20 boş pod slotu ve ~5.5 GiB bellek, HPA (2→6) ile tam monitoring'i aynı anda kaldıramazdı. 3 node'da ~34 slot / ~8.4 GiB olur. `node_instance_type` ve `node_desired_size` Terraform değişkeni |
| 19 | [x] | **EKS 1.33 extended support tuzağı** | Plan 1.33 öngörüyordu ("olgun sürüm"). Ama 1.33'ün standart desteği **29 Temmuz 2026**'da bitmiş; sürüm artık extended support'ta ve control plane **0.10 $/saat yerine 0.60 $/saat** (6×). Üstelik extended support yeni cluster'larda **varsayılan olarak açık** — fark edilmeseydi fatura sessizce ~7 $ yerine ~43 $ olurdu | **1.34** seçildi (standart destek 2 Aralık 2026'ya kadar). `variables.tf` içine doğrulama komutu yorum olarak eklendi; apply öncesi `describe-cluster-versions` ile `STANDARD_SUPPORT` teyit ediliyor |
| 20 | [x] | **Provider/modül sürüm çakışması** | `provider aws ~> 6.0` yazılmıştı ama `terraform-aws-modules/eks` v20 `< 6.0.0` istiyor → `terraform init` çöktü | Ana stack `~> 5.100`'e sabitlendi (EKS modülü v21 major rewrite, 3 günde riskli). `bootstrap` bilinçli olarak 6.x'te bırakıldı — ayrı state, yalnızca S3 kaynakları; 5.x'e düşürülünce mevcut state okunamadı ("created by a newer provider version") |
| 21 | [x] | **Node disk boyutu sessizce yok sayılıyor** | Node group'a `disk_size = 30` verilmişti ama planda `disk_size: None` göründü. Modül özel launch template kullandığında bu alan **yok sayılır**; node'lar varsayılan 20 GiB ile açılırdı. kube-prometheus-stack + Loki + uygulama imajları çekilince DiskPressure ve pod tahliyesi kaçınılmazdı | `block_device_mappings` ile 30 GiB gp3 (şifreli) tanımlandı. Planda doğrulandı |
| 22 | [x] | **Terraform state kilidi** | Klasik yaklaşım S3 + DynamoDB tablosu | Terraform 1.10+ ile gelen **S3 native lockfile** (`use_lockfile = true`) kullanıldı — DynamoDB tablosu hiç yaratılmadı |
| 24 | [x] | **metrics-server sessizce çalışmıyordu** | `terraform apply` temiz geçti, `kubectl -n kube-system get deploy metrics-server` **2/2 READY** gösterdi — ama `kubectl top nodes` "Metrics API not available" dedi. APIService `v1beta1.metrics.k8s.io` durumu `False (FailedDiscoveryCheck)`: control plane pod'a ulaşamıyordu. Sebep: EKS metrics-server addon'ı **10251** portunda dinliyor, modülün varsayılan node güvenlik grubu kuralları ise control plane'den yalnızca 443 ve 10250'ye (kubelet) izin veriyor | `node_security_group_additional_rules` ile 10251'e `source_cluster_security_group` ingress kuralı eklendi. **Neden önemli:** pod'lar sağlıklı göründüğü için sorun fark edilmez; HPA metrik bulamaz ve hiç ölçeklenmez — Aşama 4'teki HPA demosu sessizce çalışmazdı |
| 25 | [x] | **IAM açıklamasında Unicode uzun tire** | `apply` 90 kaynağın 87'sini yarattıktan sonra IAM rolünde patladı: `ValidationError: Value at 'description' failed to satisfy constraint: [\u0009\u000A\u000D\u0020-\u007E\u00A1-\u00FF]`. Açıklamadaki uzun tire (`—`, U+2014) bu aralığın dışında. Türkçe karakterler (`ü` = U+00FC) sorun değil, tire | Açıklamalar ASCII'ye çevrildi. Aynı tuzak CloudFront `comment` alanında da vardı, önden düzeltildi |
| 23 | [x] | **CloudFront sıra tuzağı** | ALB'yi Terraform yaratmıyor; Aşama 4'te Ingress'ten AWS Load Balancer Controller yaratıyor. CloudFront ana stack'te olsaydı origin'i bulunamayacaktı | `envs/edge` **ayrı stack** olarak yazıldı ve ALB'yi `elbv2.k8s.aws/cluster` tag'i üzerinden `data "aws_lb"` ile buluyor. **Aşama 4'ten sonra** apply edildi ve ALB'yi ilk denemede buldu — plan hata vermedi |

### Araç sürümleri

`terraform 1.15.9` · `kubectl 1.34.11` · `helm 3.21.4` — üçü de checksum doğrulamasıyla kuruldu.
kubectl bilinçli olarak cluster ile aynı minor sürümde: en yeni sürüm 1.36'ydı ama
kubectl ±1 minor skew destekler, 1.36 ↔ 1.34 iki minor uzaklıkta kalırdı.

### Aşama 3 doğrulama kanıtları

| Test | Sonuç |
|---|---|
| `terraform apply` | 91 kaynak, temiz |
| `kubectl get nodes` | 2 node **Ready**, `v1.34.9-eks`, private IP (10.0.x) |
| Sürüm destek durumu | `1.34 STANDARD_SUPPORT` — son tarih 2026-12-02 (extended support ücreti yok) |
| kube-system pod'ları | 14/14 Running (vpc-cni, coredns, kube-proxy, ebs-csi ×4, metrics-server ×2, alb-controller ×2) |
| StorageClass | `gp3 (default)`, `WaitForFirstConsumer`, expansion açık · gp2'nin default işareti kaldırıldı |
| **EBS CSI + IRSA** | Test PVC **8 saniyede Bound**; pod volume'a yazdı; AWS tarafında `gp3`, **şifreli**, `in-use` volume doğrulandı |
| `kubectl top nodes` | Çalışıyor (SG kuralı sonrası); APIService `True` |
| Node diski | 30 GiB (launch template'ten) |
| ECR | 3 repo, `IMMUTABLE`, scan-on-push açık |
| GitHub OIDC | Trust policy `repo:tarikemre10/devops-case:*` ile sınırlı, `aud=sts.amazonaws.com` |
| ALB Controller | 2/2 Available |

### Ölçülen kapasite — Aşama 4 ve 6 için kritik

| | Değer |
|---|---|
| Toplam pod kapasitesi | **34** (2 node × 17, VPC CNI `max-pods` limiti) |
| kube-system'in kullandığı | 14 |
| **Boştaki pod slotu** | **20** |
| Toplam allocatable bellek | ~6.7 GiB |
| Şu an kullanılan | ~1.2 GiB |
| **Boştaki bellek** | **~5.5 GiB** |

Tahmini tüketim: uygulama ~6 pod / ~1 GiB · kube-prometheus-stack ~7 pod / ~2.5–3 GiB ·
Loki + Alloy ~3 pod / ~1 GiB → **16 pod / ~5 GiB**. Sığıyor ama marj yok;
HPA backend'i 2→6 ölçeklerse 4 pod daha eklenir ve **20 slotun tamamı dolar**.

---

## Aşama 4 — Kubernetes Manifestleri

Manifestler: `k8s/base` (13 kaynak) + `k8s/overlays/prod`. Namespace ve Secret'lar
manifestlerde değil, `terraform/envs/prod`'da (ADR 10).

| # | Durum | Konu | Sorun | Çözüm |
|---|---|---|---|---|
| 26 | [x] | **NetworkPolicy sessizce etkisiz** | EKS'in VPC CNI'ı NetworkPolicy nesnelerini **varsayılan olarak uygulamaz**. `kubectl apply` başarılı olur, `kubectl get netpol` hepsini listeler, ama tek bir paket bile engellenmez. Default-deny yazıp güvende sanmak en tehlikeli hâli | `vpc-cni` addon'ına `configuration_values = jsonencode({ enableNetworkPolicy = "true" })` eklendi. Doğrulama tahmine bırakılmadı: frontend pod'undan mongodb:27017'ye erişim timeout ile reddediliyor mu diye test edildi |
| 27 | [x] | **Origin-verify yumurta-tavuk** | `X-Origin-Verify` değerini `envs/edge` üretiyordu, ama aynı değere **Aşama 4'teki Ingress annotation'ı** da ihtiyaç duyuyor — ve Ingress, edge'den ÖNCE apply ediliyor. Değer edge'de kalsaydı ALB kuralı henüz var olmayan bir sırra bağlanacaktı | `random_password.origin_verify` `envs/prod`'a taşındı ve `sensitive` output olarak verildi; edge onu `terraform_remote_state` ile okuyor. Overlay'de `__ORIGIN_VERIFY__` yer tutucusu var, apply öncesi `terraform output -raw origin_verify_secret` ile dolduruluyor (Aşama 5'te CI adımı olacak) — **git'e düz metin secret girmiyor** |
| 28 | [x] | **ALB kural sırası** | Ingress'te iki kural var: koşullu `frontend` ve yakalayıcı `deny-direct` (403). ALB listener kuralları manifestteki **sırayla** üretilir; deny önce gelseydi CloudFront dahil her istek 403 alırdı | Koşullu kural listede ilk sırada; `overlays/prod/ingress-patch.yaml` içine sıranın neden önemli olduğu yorum olarak yazıldı. Patch `rules` listesini tamamen değiştiriyor (liste merge key'i yok), bu yüzden base'deki tek kural ezildi — `kubectl kustomize` çıktısıyla doğrulandı |
| 29 | [x] | **StatefulSet'te readOnlyRootFilesystem** | mongod açılışta `/data/configdb` ve `/tmp`'ye yazmak istiyor; salt-okunur kökle "Permission denied" ile çıkıyor. Ayrıca PVC `fsGroup` olmadan root sahipli mount ediliyor ve veri dizini de yazılamıyor | İki `emptyDir` + `fsGroup: 999` (mongo imajının uid'si). Aynı kalıp frontend'de dört `emptyDir` + `fsGroup: 101` olarak zaten Aşama 2'de öğrenilmişti (madde C) |
| 30 | [x] | **Liveness probe'a Mongo koymamak** | Backend'in `/healthcheck/ready` ucu Mongo ping içeriyor. Bunu liveness'a bağlamak cazip ama yanlış: Mongo kısa süre düşerse **tüm backend pod'ları** aynı anda restart döngüsüne girer ve Mongo geri gelse bile CrashLoopBackOff'tan çıkamazlar | Liveness `/healthcheck` (sadece process), readiness `/healthcheck/ready` (Mongo ping → 503, pod Service'ten düşer ama öldürülmez). İlk açılış için ayrıca `startupProbe` (30 × 5 sn) — `conn.mjs`'in üstel backoff'una zaman tanır |

| 31 | [x] | **`sed` secret'ı repoya yazdı** | `__ORIGIN_VERIFY__` yer tutucusunu doldururken `sed` dosyadaki **yorum satırındaki** geçişi de değiştirdi; gizli değer apply'dan sonra iki yerde düz metin olarak dosyada kaldı | Apply biter bitmez ters `sed` ile yer tutucu geri konuldu ve dosyada değerin kalmadığı `grep` ile doğrulandı. **Aşama 5'te kalıcı çözüm:** dosyayı hiç değiştirmeyen bir akış — `kustomize build \| envsubst` ya da değeri yalnızca `kubectl patch` ile geçirmek. Repoda tutulan sürüm daima yer tutuculu olmalı |

### Aşama 4 doğrulama kanıtları

Statik: `kubectl kustomize k8s/overlays/prod` → 21 kaynak temiz render; dört pod şablonunun
dördünde de `readOnlyRootFilesystem: true` + `runAsNonRoot: true`. `terraform validate`
iki stack'te de başarılı, `terraform fmt -recursive -check` temiz.

Cluster üzerinde (`mern-devops-case-prod`, 3 node):

| Test | Sonuç |
|---|---|
| `terraform apply` (prod) | 5 eklendi, 1 değişti (vpc-cni netpol bayrağı), 0 silindi |
| Namespace + Secret'lar | `mern` Active; `mongo-credentials` (3 anahtar) ve `origin-verify` Terraform'dan geldi |
| ECR push | üç imaj da tag `2d9e9c04f433` (commit SHA) ile yüklendi |
| PVC | `data-mongodb-0` **Bound**, 10Gi, `gp3` |
| Rollout | mongodb 1/1, backend 2/2, frontend 2/2 — hepsi ilk denemede Running |
| **Kriter 1 — Mongo bağlı** | `/healthcheck/ready` → `{"status":"ready","mongo":"up"}` |
| **Kriter 2 — endpoint'ler** | ALB üzerinden POST **201**, GET 200, PATCH 200, DELETE 200 |
| **Kriter 3 — sayfalar** | `/` ve `/create` 200 (SPA fallback + `/api` rewrite çalışıyor) |
| **Kriter 4 — ETL saatte bir** | CronJob `0 * * * *`; elle tetiklenen Job **Complete**, JSON log, `etl.success` `duration_ms: 3342` |
| Origin doğrulaması | header'sız → **403** "Direct access denied" · header'lı → **200** |
| NetworkPolicy | frontend → mongodb:27017 **timeout** (engellendi) · frontend → backend:5050 **200** (izinli) · ETL → api.github.com **200** |
| HPA | `cpu: 1%/70%`, 2/6 replica — metrics-server metriği geliyor |
| PDB | backend ve frontend: `ALLOWED DISRUPTIONS 1` |
| CloudFront (edge) | `https://d3istqpjzc491u.cloudfront.net` — `/` 200, `/api/record` 200, POST 201, HTTP → **301** HTTPS |

---

## Aşama 5 — CI/CD (GitHub Actions)

İki pipeline: `.github/workflows/mern.yml` (backend + frontend) ve
`.github/workflows/etl.yml` (ETL). Erişim GitHub OIDC ile üstlenilen role dayanır;
repoda tek bir GitHub **secret'ı yok** — yalnızca gizli olmayan `vars` var.

### Temel tasarım kararı — CI tam `apply` yapmaz

CI'a `kubectl apply -k` yaptırmak namespace içindeki 9 kaynak tipine
`create/update/patch` yetkisi vermeyi ve `__ORIGIN_VERIFY__` sırrını pipeline'dan
geçirmeyi gerektirirdi. Oysa pipeline'ın her koşuda değiştirdiği tek şey **imaj
tag'i**. Bu yüzden CI yalnızca `kubectl set image` / `kubectl patch cronjob`
çalıştırır. Sonuçlar:

- RBAC beş kurala iner (aşağıda) — gerçek least-privilege.
- Origin-verify sırrı CI'a hiç girmez; **madde 31 kapanır**.
- **Sınır:** manifest *yapısı* değişirse (yeni kaynak, probe, resource değişikliği)
  dağıtım elle `kubectl apply -k` ile yapılır. Pipeline **imaj** dağıtımının tek
  yoludur. Bu, Çalışma Kuralı 6'ya bilinçli ve dar bir istisnadır.

| # | Durum | Konu | Sorun | Çözüm |
|---|---|---|---|---|
| 32 | [x] | **IAM izni ≠ Kubernetes yetkisi** | OIDC rolünün `eks:DescribeCluster` izni vardı, yani `aws eks update-kubeconfig` sorunsuz çalışıyordu — ama `module "eks"` bloğunda hiç `access_entries` yoktu. Her `kubectl` çağrısı `Unauthorized` dönerdi. Kubeconfig'in üretilmesi bağlantının kurulduğu izlenimini verdiği için yanıltıcı bir hata | `access_entries` eklendi, `user_name = "github-actions"` ile sabitlendi. `policy_associations` **bilerek boş**: hazır `AmazonEKSClusterAdminPolicy` cluster geneli admin verirdi. Yetki `mern` namespace'ine bağlı `ci-deployer` Role'ünden gelir: `deployments` get/list/patch, `replicasets` get/list (rollout undo bunları okur), `cronjobs` get/list/patch, `jobs` +create/delete, `pods,pods/log,events` get/list. Secret, Service, Ingress, StatefulSet ve cluster-scope her şey **yok** |
| 33 | [x] | **Terraform bağımlılık döngüsü** | `github_oidc` modülü `module.eks.cluster_arn`'i okuyor; access entry için `module.eks`'in `module.github_oidc.role_arn`'i okuması gerekti → `Cycle` hatası | Cluster ARN'i tamamen deterministik (bölge + hesap + ad). `locals.eks_cluster_arn` olarak elde kuruldu, bağımlılık tek yöne (`eks → github_oidc`) çevrildi |
| 34 | [x] | **İki pipeline'ın tag sahipliği** | İlk tasarımda `mern.yml` deploy adımı üç imajı birden `$GITHUB_SHA` ile güncelliyordu. Ama o workflow yalnız `mern-server` ve `mern-client` üretiyor — `mern-etl:$SHA` hiç var olmuyor. CronJob var olmayan bir imaja işaret edip her saat başı `ImagePullBackOff`'a girerdi ve hata bir sonraki saate kadar fark edilmezdi | Her imajın **tek sahibi** var: `mern.yml` yalnız iki Deployment'ı, `etl.yml` yalnız CronJob'ı günceller. Doğrulama: merge sonrası CronJob'ın imaj tag'inin **değişmemiş** olması |
| 35 | [x] | **Smoke testi sahte-yeşil** | Smoke `$PUBLIC_URL/healthcheck/ready` adresini deneyecekti. nginx yalnız `/api/` yolunu backend'e proxy'liyor; öneksiz yol SPA fallback'ine düşer ve **200 + HTML** döner. Yani backend tamamen ölü olsa bile smoke geçerdi | Doğru yol `/api/healthcheck/ready`. Ayrıca yalnız status koduna bakılmıyor: `Content-Type` doğrulanıyor ve gövde `jq -e '.mongo == "up"'` ile kontrol ediliyor |
| 36 | [x] | **Smoke ayrı job olamaz** | Smoke ve rollback ayrı bir job'a konulmuştu. GitHub job'ları izole makinelerde çalışır: ayrı job'ın ne OIDC oturumu, ne kubeconfig'i, ne de önceki job'ın çalışma dizini olur — yani başarısızlıkta `kubectl rollout undo` **çalışamazdı** | Deploy + rollout + smoke + `if: failure()` rollback tek job, tek shell oturumu |
| 37 | [x] | **ECR IMMUTABLE + workflow re-run** | Repolar `IMMUTABLE`. Bir workflow'u aynı commit için yeniden çalıştırmak (örn. geçici bir ağ hatası sonrası) push adımında `ImageTagAlreadyExistsException` ile patlar — düzeltilecek bir şey olmadığı hâlde pipeline kırmızı kalır | Push öncesi `aws ecr describe-images --image-ids imageTag=$SHA` kontrolü; imaj varsa build+push atlanır, deploy yine çalışır |
| 38 | [x] | **CronJob'ın rollout geçmişi yok** | `Deployment`'ta `rollout undo` var, `CronJob`'ta yok. ETL imajı bozuksa geri dönecek bir revizyon bulunmaz ve her saat başı bozuk Job tetiklenmeye devam eder | `etl.yml` patch'ten **önce** mevcut imajı okuyup step output'una yazıyor; doğrulama job'ı başarısız olursa CronJob o değere geri patch'leniyor |
| 39 | [x] | **`ruff` `runner.py`'de UP017** | Lint eklenince `datetime.now(timezone.utc)` `UP017` verdi. `ETL.py` **değiştirilemez** (Aşama 1 kuralı), ama `runner.py` bizim yazdığımız dosya | `runner.py` `datetime.UTC`'ye geçirildi (py3.12 imajı). `ETL.py` için `ruff.toml`'da `per-file-ignores` — stilistik kurallar kapalı, gerçek hata sınıfı `F` açık kalıyor |

| 40 | [x] | **OIDC `sub` claim'inin immutable-ID biçimi** | Trust policy `repo:tarikemre10/devops-case:*` kalıbıyla yazılmıştı ve her pipeline koşusu `Not authorized to perform sts:AssumeRoleWithWebIdentity` ile düşüyordu. Rol, provider, `aud`, repo adı, branch, `AWS_ROLE_ARN` variable'ı — hepsi tek tek doğrulandı, hepsi doğruydu. Hata mesajı hangi claim'in eşleşmediğini söylemediği için tahminle ilerlemek imkânsızdı | Cevap **CloudTrail**'de: reddedilen `AssumeRoleWithWebIdentity` olayının `userIdentity.userName` alanı gerçek `sub` değerini taşıyor — `repo:tarikemre10@102986030/devops-case@1341157652:ref:refs/heads/master`. GitHub artık sahip ve repo adlarına kalıcı sayısal kimliklerini ekliyor (**immutable ID biçimi**), klasik kalıp eşleşmiyor. Modül iki biçimi de kabul edecek şekilde güncellendi (`github_repository_immutable`). Bu bir gevşetme değil: her iki değer de aynı repoyu gösteriyor, immutable biçim repo yeniden adlandırılsa bile geçerli kaldığı için aslında daha güçlü |

### Aşama 5 doğrulama kanıtları

Statik (lokal): `actionlint` iki workflow'da da **0 bulgu** ·
`ruff check` + `ruff format --check` temiz · `terraform fmt -recursive` temiz ·
`terraform validate` (prod) başarılı.

Cluster üzerinde doğrulandı: access entry `username: github-actions` olarak eşlendi;
`kubectl --as=github-actions` ile `get/patch deploy`, `patch cronjobs`, `create/delete jobs`
**yes**; `get secrets`, `delete deploy`, `patch ingresses`, `patch statefulsets`,
`get nodes` ve başka namespace'te `patch deploy` **no**. Trust policy iki `sub` biçimini
de kabul ediyor (madde 40).

**Pipeline canlı koştu ve doğrulandı** (PR #19 merge'ü, commit `422111a`). Kanıtlar
cluster ve ECR üzerinden, GitHub Actions arayüzüne bakmadan okunabiliyor:

| Kanıt | Ölçüm |
|---|---|
| Build + Trivy + push çalıştı | ECR'de üç repoda da `422111a2d8bc...` tag'i var. Tarama push'tan **önce** yapıldığı için tag'in varlığı taramanın da geçtiğini gösterir |
| `kubectl set image` + rollout çalıştı | `backend`/`frontend` **revision 2**; eski ReplicaSet'ler `2d9e9c04f433` tag'iyle 0'a çekilmiş, yeni ReplicaSet'ler merge SHA'sıyla 2 replica'da |
| Otomatik rollback tetiklenmedi | Revizyon 3 yok, çalışan tag merge SHA'sı — yani `rollout status` ve smoke geçti, `rollout undo` hiç çalışmadı |
| `etl.yml` ayrı olarak koştu | CronJob'ın imajı da merge SHA'sına geçmiş; `etl-29788920` (18:00) eski tag'le, `etl-29788980` (19:00) ve `etl-29789040` (20:00) **yeni tag'le `succeeded: 1`** |
| ECR ayarları | Üç repo da `IMMUTABLE` + `scanOnPush: true` |

> **Not:** İlk koşuda pipeline OIDC `sub` biçimi yüzünden düştü (madde 40); trust
> policy düzeltildikten (`afc38c8`) sonraki koşu uçtan uca geçti. Yukarıdaki
> tag'ler o başarılı koşunun çıktısıdır.

Ayrıca doğrulanmış: `git grep ORIGIN_VERIFY` yalnızca placeholder döndürüyor —
origin-verify sırrı pipeline'a hiç girmiyor (Aşama 5'in tasarım kararı).

GitHub arayüzünden bakılırsa görülecekler (kayıt için): PR koşusunda `build` ve
`deploy` job'ları **skipped** (`if: github.event_name != 'pull_request'`),
master koşusunda smoke adımının `mongo:"up"` çıktısı.

---

## Aşama 6 — Logging, Monitoring, Alerting

Yığın `terraform/envs/prod/monitoring.tf` içinde üç `helm_release` ile kuruluyor:
kube-prometheus-stack `88.5.3` · loki `7.3.0` · alloy `1.11.1`. Sürümler **tam
pinli**; `~> 88.5` yazılsaydı apply günü farklı bir chart çekilir ve
tekrarlanabilirlik iddiası çökerdi.

| # | Durum | Sorun | Çözüm |
|---|---|---|---|
| 41 | [x] | **`ruleSelector` tuzağı — sessiz alarm** | kube-prometheus-stack varsayılanda `ruleSelectorNilUsesHelmValues: true` ile gelir; Prometheus YALNIZCA `release=<name>` label'lı kendi kaynaklarını toplar. Dışarıdan gelen `PrometheusRule` hata vermeden **sessizce yok sayılır** — `kubectl get prometheusrule` kaynağı listeler, alarm hiç çalışmaz | Dört bayrak da `false`: `ruleSelectorNilUsesHelmValues`, `serviceMonitorSelectorNilUsesHelmValues`, `podMonitorSelectorNilUsesHelmValues`, `probeSelectorNilUsesHelmValues`. Render'da doğrulandı: `ruleSelector: {}`. Cluster doğrulaması: `curl localhost:9090/api/v1/rules \| jq '.data.groups[].name'` → `mern-workloads`, `mern-etl`, `cluster-health` |
| 42 | [x] | **`absent()` olmadan alarm hiç ateşlenmez** | `kube_pod_container_status_ready{container="backend"} == 0` doğru görünür ama tüm backend pod'ları yok olduğunda (ImagePullBackOff, node kaybı) **zaman serisi tamamen kaybolur** ve ifade boş küme döner. Aynı sorun `kube_cronjob_status_last_successful_time` için de var: CronJob hiç çalışmadıysa metrik hiç doğmaz | `sum(...) < 1 or absent(...)` ve ETL'de `(time() - ... > 3900) or absent(...)`. Sessiz alarm, alarm olmamasından kötüdür |
| 43 | [x] | **Alloy DaemonSet olursa loglar çoğalır** | `loki.source.kubernetes` logları hostPath'ten değil **Kubernetes API'sinden** okur. DaemonSet olarak çalıştırılırsa her node'daki instance tüm eşleşen pod'ları toplar ve aynı satır node sayısı kadar Loki'ye yazılır (3 node → 3 kopya) | `controller.type: deployment`, `replicas: 1`. Alternatif Alloy clustering/sharding'di; bu ölçekte gereksiz karmaşıklık. Bedeli: pod restart'ında kısa log boşluğu. Yan fayda: 2 pod slotu tasarrufu |
| 44 | [x] | **Loki boş `schemaConfig` ile açılmaz** | Chart varsayılanı `schemaConfig: {}`; öylece bırakılırsa Loki CrashLoop'a girer. Ayrıca `replication_factor` varsayılanı 3'tür ve SingleBinary'de tutmaz | `schemaConfig` açıkça yazıldı (tsdb + v13 + filesystem), `replication_factor: 1`. Retention için `retention_period` **tek başına yetmez**: silme işini compactor yapar → `compactor.retention_enabled: true` + `delete_request_store: filesystem` |
| 45 | [x] | **`monitoring` namespace'ine PSA `restricted` konulamaz** | App namespace'i `pod-security.kubernetes.io/enforce=restricted` ile etiketli. Aynı etiket monitoring'e konursa node-exporter (hostPath + hostNetwork) admission tarafından reddedilir ve DaemonSet hiç açılmaz | Monitoring namespace'i `restricted` etiketi almıyor; gerekçe `monitoring.tf`'te yorumda. App namespace'i sıkı kalıyor |
| 46 | [x] | **CRD'li chart + `kubernetes_manifest` çakışması** | Alert kurallarını `kubernetes_manifest` ile apply etmek doğal yol gibi görünüyor, ama o kaynak **plan aşamasında** CRD şemasını API'den okumak zorunda — `PrometheusRule` CRD'si aynı apply'da kurulduğu için ilk plan patlar | Kurallar repoda YAML (`monitoring/alerts/mern-rules.yaml`), Terraform `yamldecode` ile okuyup chart'ın `additionalPrometheusRulesMap` değerine gömüyor. Kural okunabilir kalıyor, CRD sırası sorunu yok |
| 47 | [x] | **ALB 5xx alarmı kurulmadı (bilinçli sapma)** | `MIMARI.md §7` ALB `HTTPCode_Target_5XX_Count` oranını öngörüyordu. Prometheus'a almak `yet-another-cloudwatch-exporter` + ayrı IRSA rolü ister; CloudWatch tarafında kurmak ise yalnız `data.aws_lb` ile tamamlanmaz — doğru **target group** boyutunun bulunması ve `5XX/RequestCount` için **metric-math** alarmı gerekir. Üstüne SNS e-posta aboneliği kullanıcı onayı olmadan bildirim göndermez → teslimde doğrulanamayan bir dış bağımlılık | Kurulmadı. Aynı arıza sinyali `BackendNotReady` + `PodCrashLooping` ile alınıyor. Prod'a geçiş yolu olarak README'de not edilecek |
| 48 | [x] | **EKS'te scrape edilemeyen job'lar gürültü üretir** | `kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, `kubeProxy` chart'ta varsayılanda açık; EKS'te control plane AWS tarafında olduğu için hedefler kalıcı "down" görünür ve gerçek arıza gürültüde kaybolur | Dördü de `enabled: false` |
| 49 | [x] | **Grafana parolası ve Slack webhook'u git'e girmemeli** | Chart'ın `grafana.adminPassword` alanı values dosyasına düz metin ister | Parola `random_password` → `grafana-admin` Secret → `grafana.admin.existingSecret`. Slack: webhook **yok**, hepsi `null` receiver'a düşüyor; `TF_VAR_slack_webhook_url` verilirse ikinci bir values dokümanı `slack-notifications` receiver'ını üretiyor (`api_url_file` + secret mount karmaşıklığı kurulmadı). `Watchdog` her koşulda `null`'a gider — sürekli ateşleyen bir sinyaldir, kanalı kullanılamaz hale getirir |

| 50 | [x] | **`FrontendNotReady` yanlış pozitif verdi — container adı `frontend` değil `nginx`** | Kural `container="frontend"` ile yazılmıştı; frontend Deployment'ında container'ın adı `nginx` (`k8s/base/frontend-deployment.yaml`). Metrik hiç doğmadı, `absent()` dalı devreye girdi ve alarm cluster'da **FIRING** oldu — oysa iki frontend pod'u da 2/2 Running'di | `container="nginx"` olarak düzeltildi, dashboard paneli de aynı şekilde. **Asıl ders madde 42'nin doğrulanması:** `absent()` olmasaydı bu yazım hatası alarmı sessizce hiç ateşlemeyecek, kural "çalışıyor" sanılacaktı. Yanlış pozitif gürültülüdür ama görünür; sessiz alarm görünmez |
| 51 | [x] | **Backend HTTP isteklerini loglamıyor** | Loki'de backend'in yalnızca 4 satırı vardı: `mongo.connected` ve `server.listening`. `pino` Aşama 1'de eklenmişti ama yalnızca yaşam döngüsü olaylarını yazıyordu; 16 istek atıldıktan sonra bile yeni satır gelmedi — "loglama" panelleri pratikte boştu. Boşluk **Aşama 6 doğrulaması sırasında Loki'de görülerek** bulundu; metrikler bunu göstermez | `pino-http` middleware'i eklendi (`msg: http.request`). Üç ayrıntı: **(1)** `/healthcheck` `autoLogging.ignore` ile dışarıda — probe'lar saniyede birkaç kez gelir, gerçek trafiği boğar ve 14 günlük retention'ı doldurur; **(2)** `customLogLevel` 5xx→`error`, 4xx→`warn` — Grafana'da severity'ye göre filtrelenebiliyor; **(3)** `logger.mjs`'e `redact`: pino-http **tüm istek header'larını** yazar, bu uygulamada auth yok ama loglar Loki'de 14 gün duruyor — bir gün auth eklenirse token'lar sessizce log'a akardı. `authorization`, `cookie`, `set-cookie` maskeli. Aşama 1'in "uygulama mantığına dokunma" kuralı korundu: iş mantığı değil, yalnızca gözlemlenebilirlik eklendi |
| 52 | [x] | **Alloy açılışta silinmiş helm-hook pod'una takılıyor** | Kurulumdan hemen sonra Alloy `kube-prometheus-stack-admission-patch-*` pod'u için saniyede onlarca `tailer stopped; will retry ... pods not found` uyarısı bastı | Geçici: helm hook pod'u silinirken discovery listesi bir tur bayat kalıyor. Bir sonraki discovery yenilemesinde kendiliğinden geçti (son 60 saniyede **0** uyarı). Yapılandırma değişikliği gerekmedi |

### Grafana neden dışarı açılmadı

ALB Security Group yalnızca `com.amazonaws.global.cloudfront.origin-facing` prefix
list'ine açık (Aşama 7 maddesi). Grafana için ikinci bir Ingress açmak bu kısıtı
delerdi. Erişim port-forward ile:
`kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80`
Parola: `terraform -chdir=terraform/envs/prod output -raw grafana_admin_password`.

### Dashboard'lar neden grafana.com'dan indirilmiyor

Chart zaten cluster/node/namespace dashboard'larını kendi getiriyor
(`grafana.defaultDashboardsEnabled`). Ek olarak grafana.com ID'sinden çekmek
çalışma anında dış kaynağa ve değişen dashboard şemasına bağımlılık yaratırdı.
Elde yazılan iki dashboard repoda JSON olarak duruyor ve Terraform onları
`grafana_dashboard=1` label'lı ConfigMap'e yazıyor; sidecar otomatik yüklüyor.

### Aşama 6 doğrulama kanıtları

Statik (lokal, cluster'sız):
`terraform fmt -recursive` temiz · `terraform validate` (prod) başarılı ·
`helm template` üç chart için de hatasız (kps'de 31 PrometheusRule, Loki'de tek
StatefulSet `replicas: 1`, Alloy'da `kind: Deployment` — DaemonSet **yok**) ·
`promtool check rules` → **9 rules found, SUCCESS** ·
render edilen Alertmanager config'i base64'ten çözülüp iki yol da doğrulandı
(webhook boşken `receiver: "null"`, doluyken `slack-notifications` + Watchdog istisnası).

**Cluster üzerinde doğrulandı** (`terraform apply` → *8 added, 0 changed, 0 destroyed*):

| Doğrulama | Sonuç |
|---|---|
| `kubectl -n monitoring get pods` | **10/10 Running** (prometheus, alertmanager, grafana, operator, kube-state-metrics, 3 × node-exporter, loki, alloy) |
| PVC'ler | `prometheus-...-0` **20Gi Bound**, `storage-loki-0` **10Gi Bound**, ikisi de `gp3` |
| Kapasite | 51 slotun **35'i** dolu (16 boş — HPA 2→6 için yeterli); bellek %53/%32/%39 |
| **`ruleSelector` tuzağı (madde 41)** | `/api/v1/rules` üç grubu da listeliyor: `mern-workloads`, `mern-etl`, `cluster-health` → **9 kural yüklü** |
| Prometheus hedefleri | 23 target, **up olmayan 0** (kapatılan dört control-plane job'ı gürültü üretmiyor, madde 48) |
| Loki log akışı | `{namespace="mern"}` 4 stream; ETL'de `etl.success` JSON satırları `job_name` label'ıyla, backend'de `pino` JSON, mongodb 2000+ satır |
| **Alloy çoğaltma testi (madde 43)** | Üç sorguda da benzersiz satır = toplam satır → **tekrarlanan 0**. `container` label listesinde `alloy` ve `loki` **yok** (drop kuralı çalışıyor) |
| Grafana | 3 datasource (Prometheus, Loki, Alertmanager); iki dashboard "MERN DevOps Case" klasöründe; Loki sorgusu Grafana API'sinden **200** |
| **`absent()` dalı (madde 42)** | Var olmayan bir cronjob için `absent(...)` = **1** → güvenlik ağı gerçekten değerlendiriliyor |
| `ETLJobMissing` yanlış pozitif yok | Son başarılı koşudan bu yana **2197 sn** (eşik 3900) → sessiz |
| **Alarm zinciri uçtan uca** | `mern` namespace'ine bilerek CrashLoop'a giren test pod'u kondu → `PodCrashLooping` 5 dk sonra **FIRING** → Alertmanager'da `severity: critical`, `receiver: ["null"]`, `state: active`. Test pod'u silindi |
| Uygulama etkilenmedi | Test boyunca backend/frontend 2/2, `https://d3istqpjzc491u.cloudfront.net/` **200**, `/api/healthcheck/ready` → `{"mongo":"up"}` |

> **Alarm testi neden `scale=0` veya bozuk imajla yapılmadı:** `kubectl scale deploy/backend
> --replicas=0` HPA `minReplicas: 2` tarafından hemen geri alınır; bozuk imaj vermek ise
> `maxUnavailable: 0` rolling update yüzünden eski pod'ları ayakta bıraktığı için
> `BackendNotReady`'yi hiç tetiklemez — üstelik ikisi de canlı uygulamayı riske atar.
> Ayrı bir CrashLoop pod'u hem gerçek zinciri kanıtlar hem üretime dokunmaz.

Alınacak ekran görüntüleri (Aşama 8): Grafana "MERN — Servis Durumu" ve
"ETL — CronJob Sağlığı" dashboard'ları, Prometheus `/alerts` sayfası,
Alertmanager'da firing alert, `kubectl -n monitoring get pods`.

> **Destroy notu:** Prometheus ve Loki PVC'leri EBS volume tutar. `helm_release`'ler
> Terraform bağımlılık sırasıyla önce silinir, ama artakalan PVC/volume için
> `kubectl -n monitoring delete pvc --all` doğrulaması şart — aksi halde VPC destroy'u
> asılı kalır.

---

## Aşama 7 — Güvenlik Kontrol Listesi

Liste **ölçülerek** kapatıldı: her madde için çalışan sistemden bir çıktı alındı.
Kontrol listesinin kendisi `PROJE_PLANI.md` Aşama 7'de; burada ölçüm komutları ve
sonuçları var, böylece bağımsız olarak tekrarlanabilir.

| Madde | Komut | Ölçülen sonuç |
|---|---|---|
| Git'te düz secret | `git ls-files \| grep -E "\.tfstate\|\.tfvars$\|kubeconfig\|config\.env\|\.pem$\|\.key$"` | **boş** |
| Container sertliği | `kubectl -n mern get pods -o json` → securityContext | 5/5 pod `roFS=true`, `privEsc=false`, `drop=[ALL]`; pod seviyesinde `runAsNonRoot=true` |
| Gerçek kullanıcı | `kubectl -n mern exec deploy/backend -- id` | `uid=1000(node) gid=1000(node)` |
| NetworkPolicy **etkisi** | `mern`'e etiketsiz test pod'u + `nc -z -w4` | `mongodb-0.mongodb:27017` → **ENGELLENDİ**, `backend:5050` → **ENGELLENDİ** |
| NetworkPolicy ön koşulu | `kubectl -n kube-system get ds aws-node -o json` | `aws-eks-nodeagent --enable-network-policy=true` · `NETWORK_POLICY_ENFORCING_MODE=standard` |
| Trivy bloklayıcı | `.github/workflows/mern.yml` | `severity: HIGH,CRITICAL` · `ignore-unfixed: true` · **`exit-code: "1"`**; `load: true` → Trivy → `docker push` sırası |
| MongoDB kapalı | `kubectl -n mern get svc mongodb` | `ClusterIP`, `clusterIP: None` (headless), Ingress yok |
| MongoDB auth | pod içinden kimliksiz `listDatabases` | `MongoServerError: Command listDatabases requires authentication` |
| CloudFront TLS | `curl http://<id>.cloudfront.net/` | **301** |
| ALB doğrudan erişim | `curl http://k8s-mern-...elb.amazonaws.com/` | **403** |
| Node role yetkisi | `aws iam list-attached-role-policies` | Yalnız `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly` |
| IRSA rolleri | `aws iam list-roles` | `...-ebs-csi`, `...-alb-controller`, `...-github-actions` ayrı ayrı |
| ECR | `aws ecr describe-repositories` | 3 repo: `scanOnPush=True`, `IMMUTABLE` |
| OIDC | `aws iam get-role --role-name mern-devops-case-github-actions` | Principal `token.actions.githubusercontent.com`, Action `sts:AssumeRoleWithWebIdentity` |
| Uzun ömürlü anahtar | `grep -rn "secrets\." .github/workflows/` | **hiç eşleşme yok** — workflow'lar yalnız `vars.*` kullanıyor |
| Root MFA | `aws iam get-account-summary` | `AccountMFAEnabled = 1` |
| Billing alarmı | `aws budgets describe-budgets` | *My Monthly Cost Budget* — **40 USD** |
| Monitoring dışa kapalı | `kubectl -n monitoring get svc,ingress` | 12 Service'in tamamı `ClusterIP`, **Ingress yok** |

### `git grep` ile bulunan üç "secret benzeri" satır — üçü de gerçek sır değil

Tarama şu üçünü döndürüyor; bilerek bırakıldılar:

| Dosya | Neden sorun değil |
|---|---|
| `docker-compose.yml:41` | Yalnız **lokal geliştirme** varsayılanı (`${MONGO_PASSWORD:-devpassword}`); cluster'a hiç gitmiyor |
| `mern-project/server/.env-example` | Placeholder (`<user>:<pass>`), gerçek değer değil |
| `terraform/envs/prod/main.tf:374` | `format()` şablonu; parola `random_password.mongo_root.result` değişkeninden geliyor, dosyada düz metin yok |

### Bilinçli istisna: `node-exporter` hostNetwork + hostPath

"Tüm container'lar non-root/read-only" maddesi **uygulama namespace'i** için geçerlidir.
`node-exporter` node metriğini okumak için `hostNetwork` ve `/proc`, `/sys`, `/` hostPath
mount'larına ihtiyaç duyar — başka yolu yoktur. Bu yüzden `monitoring` namespace'ine PSA
`restricted` etiketi konmaz (madde 45), `mern` namespace'ine konur. Sınır net: sertlik
uygulama iş yüklerinde tavizsiz, gözlemlenebilirlik ajanında gerektiği kadar gevşek.
