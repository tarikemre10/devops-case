# Ekran görüntüsü çekim listesi

Case teslim maddesi 6: *"çalışan sistemin web üzerinden erişilebilir olduğunu gösteren
ekran görüntüleri"*. Bu dosya ne çekileceğini, hangi adla kaydedileceğini ve her
görüntüde **ne görünmesi gerektiğini** tanımlar.

## Üç kural

1. **Tarayıcı görüntülerinde adres çubuğu görünür olmalı** ve `https://d3istqpjzc491u.cloudfront.net`
   yazmalı. `localhost` görüntüsü kabul edilmez — dağıtımın gerçekten yapıldığını kanıtlamaz.
2. **Terminal görüntülerinde komut da görünmeli**, yalnız çıktı değil.
3. Dosya adları aşağıdaki tabloyla **birebir** aynı olmalı — `README.md` bu adlara link veriyor.

## Liste

| # | Dosya adı | Ne çekilecek | Görünmesi şart olan |
|---|---|---|---|
| 1 | `01-frontend-anasayfa.png` | `https://d3istqpjzc491u.cloudfront.net/` | Adres çubuğu + kilit ikonu, sağlık durumu kartı |
| 2 | `02-frontend-kayit-listesi.png` | `/records` | En az bir kayıt satırı, tablo başlıkları |
| 3 | `03-frontend-kayit-olusturma.png` | `/create` — form doldurulmuş hâlde | Doldurulmuş alanlar (Name/Position/Level) |
| 4 | `04-api-record-json.png` | `/api/record` | Ham JSON dizisi, adres çubuğunda `/api/record` |
| 5 | `05-api-healthcheck-ready.png` | `/api/healthcheck/ready` | **`"mongo":"up"`** açıkça okunmalı — kriter 1'in kanıtı |
| 6 | `06-kubectl-get-pods.png` | `kubectl -n mern get pods` **ve** `kubectl -n monitoring get pods` | İki namespace'in tamamı `Running`, `READY` sütunu |
| 7 | `07-cronjob-job-gecmisi.png` | `kubectl -n mern get cronjob,jobs` | `SCHEDULE 0 * * * *` ve **ardışık saatlerde** `COMPLETIONS 1/1` — kriter 4'ün kanıtı |
| 8 | `08-grafana-mern-servis-durumu.png` | Grafana → *MERN — Servis Durumu* | Hazır pod sayıları, HPA paneli, CPU/bellek grafikleri |
| 9 | `09-grafana-etl-cronjob.png` | Grafana → *ETL — CronJob Sağlığı* | "Son başarılı koşudan bu yana" paneli + **Loki log panelinde `etl.success` satırları** |
| 10 | `10-alertmanager-firing-alert.png` | Alertmanager UI (`:9093`) | **FIRING** durumda bir alarm, `severity: critical` etiketi |
| 11 | `11-github-actions-pipeline.png` | GitHub → Actions → başarılı `mern` koşusu | Tüm job'lar yeşil: Lint & e2e, Build & push (×2), Deploy to EKS |
| 12 | `12-ecr-imajlar.png` | AWS Console → ECR → `mern-devops-case/mern-server` | Commit SHA tag'i, "Scan on push: Enabled", tag mutability **Immutable** |

## Çekim öncesi hazırlık

```bash
# Grafana (8, 9) ve Alertmanager (10) için port-forward
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80 &
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 &

# Grafana parolası (kullanıcı: admin)
terraform -chdir=terraform/envs/prod output -raw grafana_admin_password
```

**10 numara için alarm tetiklenmelidir.** Sistem sağlıklıyken firing alarm yoktur
(`Watchdog` hariç, o Prometheus'un kendi canlılık sinyalidir ve kanıt sayılmaz).
Üretime dokunmadan gerçek bir alarm üretmek için `mern` namespace'ine bilerek
CrashLoop'a giren bir test pod'u konur; ~5 dakika sonra `PodCrashLooping` ateşler,
görüntü alınır ve pod silinir.

> Backend'i `scale=0` yapmak ya da bozuk imaj vermek **işe yaramaz**: HPA
> `minReplicas: 2` ilkini geri açar, `maxUnavailable: 0` ise ikincisinde eski
> pod'ları ayakta tutar. Ayrıca ikisi de canlı uygulamayı riske atar.

Bu adım için hazır komutlar `docs/KARSILASILAN_ZORLUKLAR.md` → *Aşama 6 doğrulama
kanıtları* bölümünde.

## Çekim sonrası

Görüntüler alındıktan sonra cluster kapatılabilir:

```bash
kubectl -n monitoring delete pvc --all
cd terraform/envs/edge && terraform destroy
cd ../prod && terraform destroy
```
