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
| A | [ ] | **EBS CSI Driver** | EKS 1.23+ sürümünde `aws-ebs-csi-driver` addon'u ve IRSA rolü olmadan MongoDB'nin `volumeClaimTemplates` PVC'si kalıcı olarak `Pending`'de kalır; StatefulSet hiç açılmaz | Terraform `addons` modülünde **ilk sırada** kurulur; ayrıca `gp3` StorageClass elle tanımlanır (EKS varsayılanı `gp2`) |
| B | [x] | **nginx upstream DNS** | `proxy_pass` sabit yazılırsa nginx başlangıçta DNS çözümler; backend Service henüz yokken pod CrashLoop'a girer | Değişkenli `proxy_pass` + resolver. **Resolver adresi sabit yazılmıyor:** imajın `15-local-resolvers.envsh` scripti `/etc/resolv.conf`'tan okuyup `$NGINX_LOCAL_RESOLVERS`'a yazıyor → aynı template compose'da (`127.0.0.11`) ve K8s'te (kube-dns) çalışıyor. Compose'da doğrulandı. |
| C | [x] | **nginx + `readOnlyRootFilesystem`** | nginx `/var/cache/nginx`, `/run`, `/tmp` dizinlerine yazamadığı için açılmaz | Dockerfile'da bu yollar `chown nginx:nginx` yapıldı. **Dördüncü yol keşfedildi: `/etc/nginx/conf.d`** — envsubst template'i oraya render ediyor, yazamazsa script sessizce çıkıyor ve nginx varsayılan sayfayı servis ediyor. K8s'te dört `emptyDir` + `fsGroup: 101` gerekecek. |
| D | [ ] | **CloudFront cache API'yi bozuyor** | Varsayılan behavior GET dışını reddeder / bayat yanıt döner; Host header origin'e taşınırsa ALB yönlendirmesi şaşar | `/api/*` için ayrı behavior: `CachingDisabled` + `AllViewerExceptHostHeader` + tüm HTTP metodları |
| E | [x] | **Trivy pipeline'ı kilitliyor** | Düzeltmesi olmayan CVE'ler `main`'i kalıcı kırmızıya çevirir | `--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1`. Aşama 2'de lokal olarak çalıştırıldı; **düzeltilebilir 95 bulgu çıktı ve üçü de 0'a indirildi** (aşağıya bakınız). CI eşiği artık gerçekçi. |
| F | [x] | **Cypress sürüm uyumu** | Repo `cypress ^4.2.0` + `cypress.json` + `integration/` düzenini kullanıyor; Cypress 10+ imajları bu testleri bulamaz. Ayrıca Cypress 4.x **host makinede hiç başlamıyor** (Ubuntu 24.04 kütüphane uyumsuzluğu) | `cypress/included:4.12.1` imajı pinlendi ve Aşama 1 doğrulamasında fiilen kullanıldı — 3/3 geçti |
| G | [ ] | **Domain yok** | Kayıtlı domain olmadığı için Route53 + ACM ile TLS kurulamaz; ancak case public URL ve HTTPS bekliyor | ALB önüne CloudFront: ücretsiz ve geçerli `*.cloudfront.net` sertifikası, `redirect-to-https`. ALB Security Group yalnız `com.amazonaws.global.cloudfront.origin-facing` prefix list'ine açılır → ALB'ye doğrudan erişim kapalı |
| H | [ ] | **Yeni AWS hesabı** | Hesap aktivasyonu saatler sürebilir; yeni hesaplarda EC2 vCPU kotası düşük gelebilir ve artırma talebi 24–48 saat alır | Hesap açma + kota kontrolü Gün 0'a alındı; Aşama 1–2 AWS gerektirmediği için beklerken yürütülür |

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
