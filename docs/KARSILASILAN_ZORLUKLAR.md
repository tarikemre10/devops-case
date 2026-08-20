# Karşılaşılan Zorluklar ve Kaynak Kodu Değişiklikleri

Uygulama mantığına dokunulmadı; yalnızca uygulamanın konteyner/Kubernetes
ortamında **çalışabilir** hâle gelmesi için gereken düzeltmeler yapıldı.
Aşama 8'de bu bölüm teslim `README.md`'sine taşınacaktır.

## Aşama 1 — Kod Hazırlığı

| # | Dosya | Sorun | Yapılan değişiklik |
|---|---|---|---|
| 1 | `client/src/components/{recordList,create,edit,healthcheck}.js` | API adresi 6 yerde `http://localhost:5050` olarak sabit yazılıydı; cluster içinde çalışmaz | Tüm çağrılar `/api/...` göreli yoluna alındı. nginx `/api` → backend Service reverse-proxy yapacak. CRA env değişkeni build-time gömüldüğü için `REACT_APP_API_URL` tercih edilmedi — aynı image dev/prod'da taşınabilir kalsın diye. |
| 2 | `server/db/conn.mjs` | Bağlantı hatasında `conn` `undefined` kalıyor, `conn.db()` ile süreç anlamsız hata veriyordu | Üstel backoff'lu retry (varsayılan 10 deneme) eklendi; tükenirse `process.exit(1)` → Kubernetes pod'u yeniden başlatır. DB adı `MONGO_DB` env'inden. |
| 3 | `server/routes/healthcheck.mjs` | `/healthcheck` yalnızca process canlılığını dönüyordu, Mongo'yu kontrol etmiyordu | `/healthcheck` liveness olarak korundu; Mongo `ping` yapan `/healthcheck/ready` (503/200) readiness probe için eklendi. |
| 4 | `server/server.mjs` | Port sabit `5050`, bind adresi varsayılan, graceful shutdown yok | `PORT`/`HOST` env ile override edilebilir, `0.0.0.0`'a bind, `SIGTERM`/`SIGINT`'te `server.close()` ile bağlantı boşaltma. |
| 5 | `server/server.mjs` | `cors()` her origin'e açıktı | nginx proxy ile same-origin olunacağından varsayılan `false`; istisnalar `CORS_ORIGINS` env'i ile verilir. |
| 6 | `server/loadEnvironment.mjs` | `config.env` dosyası zorunlu gibi davranıyordu | Dosya opsiyonel; yolu `ENV_FILE` ile değiştirilebilir. Konteynerde konfigürasyon env'den gelir. |
| 7 | `server/.env-example` | Yalnızca boş `ATLAS_URI` vardı | Tüm env değişkenleri örneklendi. |
| 8 | `client/cypress/integration/endToEnd.spec.js` | Test, kayıt ekledikten sonra `/` adresinde `Employee1` arıyordu; ancak `/` rotası `HealthStatus` bileşenini render ediyor (liste `/records`'ta) → test hiçbir zaman geçemezdi | Uygulama rotalarına dokunulmadı, **test düzeltildi**: liste doğrulaması `/records` üzerinde yapılıyor. Ayrıca proxy üzerinden `/api/healthcheck` doğrulaması eklendi. |
| 9 | `client/cypress.json` | Boş; adresler testte hard-coded'dı | `baseUrl` tanımlandı; CI'da `CYPRESS_baseUrl` env'i ile canlı ortama yönlendirilebilir. |

### Açık not
`ETL.py` içeriğine dokunulmadı (case gereği). `print()` çıktısı stdout'tan
Grafana Alloy ile toplanacak.
