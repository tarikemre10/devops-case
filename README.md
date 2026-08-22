# DevOps Case — AWS EKS Üzerinde MERN ve Python ETL

Bu proje; basit bir React, Express, MongoDB ve Python uygulamasını DevOps pratikleriyle
uçtan uca dockerize eder, orkestre eder ve güvenli biçimde sunar.
Kubernetes altyapısı AWS EKS üzerinde çalışır.
AWS kaynakları Terraform ile kurulur.
CI/CD pipeline'ı GitHub Actions ile yönetilir.
Monitoring tarafında Prometheus, Loki ve Grafana kullanılır.

**Canlı uygulama:** https://d3istqpjzc491u.cloudfront.net

**GitHub:** https://github.com/tarikemre10/devops-case

![Mimari](docs/mimari.svg)

| Alan | Kullanılan teknoloji |
|---|---|
| Bulut | AWS, `eu-central-1` |
| Kubernetes | EKS 1.34, 3 × `t3.medium` |
| IaC | Terraform 1.15, S3 remote state |
| CI/CD | GitHub Actions + AWS OIDC |
| Public erişim | CloudFront → ALB → nginx |
| Monitoring | Prometheus, Loki, Grafana Alloy, Alertmanager |

## Gereklilikler

| Gereklilik | Uygulama | Doğrulama |
|---|---|---|
| Konteynerleştirme | Frontend, backend ve ETL için üç Dockerfile; MongoDB resmi imajı | Docker Compose + Cypress |
| Orkestrasyon | Deployment, StatefulSet, CronJob, Service, Ingress, HPA ve PDB | EKS üzerinde çalışan pod'lar |
| CI/CD | MERN ve ETL için ayrı GitHub Actions workflow'ları | Başarılı pipeline koşusu |
| Günlük kaydı ve uyarılar | JSON log → Alloy/Loki; metrik → Prometheus; 9 alarm | Grafana ve Alertmanager |
| Dockerfile'lar | [docker/](docker/) | Compose build |
| Kubernetes yapılandırmaları | [k8s/](k8s/) | `kubectl kustomize k8s/overlays/prod` |
| Pipeline yapılandırmaları | [.github/workflows/](.github/workflows/) | Canlı koşu |
| IaC betikleri | VPC, EKS, ECR, IAM ve CloudFront Terraform ile yönetiliyor | `terraform validate` |
| Dokümantasyon | [MIMARI.md](MIMARI.md), [Karşılaşılan Zorluklar](docs/KARSILASILAN_ZORLUKLAR.md), [terraform/README.md](terraform/README.md) | — |
| Çalışan sistem ekran görüntüleri | [Ekran görüntüleri](#ekran-görüntüleri) | 13 görsel |

Readiness kontrolü:

```bash
curl https://d3istqpjzc491u.cloudfront.net/api/healthcheck/ready
# {"status":"ready","mongo":"up",...}
```

## Mimari

Genel görünüm için başlıktaki diyagrama bakınız.

Backend ve MongoDB cluster dışına açılmaz. nginx hem React dosyalarını sunar hem de
`/api` isteklerini backend'e iletir. ALB yalnız CloudFront'un eklediği doğrulama
header'ını kabul eder; doğrudan ALB erişimi `403` döner.

Ayrıntılı tasarım: [MIMARI.md](MIMARI.md)

## Lokal çalıştırma

Gereken tek araç Docker'dır:

```bash
docker compose up --build -d
docker compose --profile test run --rm cypress
```

Uygulama http://localhost:8080 adresinde açılır. Testler production nginx imajına karşı
çalışır ve frontend, API proxy ve kayıt oluşturma akışını kontrol eder.

ETL tek seferlik çalıştırılır:

```bash
docker compose --profile etl run --rm etl
docker compose down
```

## AWS kurulumu

Ön koşullar: Terraform 1.10+ (test edilen 1.15.9), AWS CLI, kubectl 1.34, Helm 3 ve Docker. AWS kimliği
önceden yapılandırılmış olmalıdır (`aws sts get-caller-identity` ile doğrulanır) ve
kurulum VPC, EKS, ECR, IAM ve CloudFront kaynakları yaratabilecek yetki gerektirir.

Başka bir AWS hesabına kurulum yapılacaksa adım adım sıra, ilk imajların üretilmesi ve
doğrulama komutları için [terraform/README.md](terraform/README.md) izlenmelidir; buradaki
özet mevcut ortamı anlatır.

### 1. Remote state

```bash
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply
```

Bootstrap çıktısındaki bucket adı hem `terraform/envs/prod/backend.tf` hem de
`terraform/envs/edge/main.tf` içine yazılır.

### 2. Ana altyapı

```bash
terraform -chdir=terraform/envs/prod init
terraform -chdir=terraform/envs/prod apply

aws eks update-kubeconfig \
  --name "$(terraform -chdir=terraform/envs/prod output -raw cluster_name)" \
  --region eu-central-1
```

Bu adım VPC, EKS, ECR, IAM/OIDC, cluster eklentileri ve monitoring kaynaklarını kurar.

### 3. Uygulama manifestleri

İlk imajlar ECR'ye push edildikten sonra prod overlay uygulanır. Origin doğrulama değeri
Git'te tutulmaz; Terraform output'undan manifest içine verilir:

```bash
kubectl kustomize k8s/overlays/prod \
  | sed "s/__ORIGIN_VERIFY__/$(terraform -chdir=terraform/envs/prod output -raw origin_verify_secret)/" \
  | kubectl apply -f -

kubectl -n mern rollout status deploy/backend deploy/frontend
```

### 4. CloudFront

Ingress ALB'yi oluşturduktan sonra edge stack uygulanır:

```bash
terraform -chdir=terraform/envs/edge init
terraform -chdir=terraform/envs/edge apply
terraform -chdir=terraform/envs/edge output app_url
```

Kurulum sırası ve destroy adımları: [terraform/README.md](terraform/README.md)

## Python ETL projesi

[python-project/](python-project/) ikinci teslim kalemidir. `ETL.py` dış bir API'den veri
çeker; `runner.py` bu betiği sarmalar, çıktısını JSON loga çevirir ve çıkış kodunu
CronJob'a iletir — böylece başarısız koşu Kubernetes tarafında görünür olur.

| Alan | Uygulama |
|---|---|
| İmaj | [docker/Dockerfile.etl](docker/Dockerfile.etl), digest pinli Python Alpine, non-root |
| Çalışma | CronJob `0 * * * *` (UTC), `restartPolicy: OnFailure` |
| CI/CD | [etl.yml](.github/workflows/etl.yml): ruff → build → Trivy → ECR → CronJob patch → doğrulama Job'ı |
| Log | stdout'a JSON → Alloy → Loki |
| Alarm | `ETLJobFailed`, `ETLJobMissing` (65 dk başarılı koşu yoksa) |
| Lokal | `docker compose --profile etl run --rm etl` |

## CI/CD

`.github/workflows/` altında iki pipeline bulunur:

- **MERN:** React build ve test → Docker Compose/Cypress → Docker build → Trivy →
  ECR push → EKS rollout → smoke test. Deploy başarısızsa Deployment geri alınır.
- **ETL:** Ruff ve Python kontrolü → Docker build → Trivy → ECR push → CronJob imaj
  güncellemesi → geçici doğrulama Job'ı. Hata olursa önceki imaja dönülür.

İmajlar commit SHA ile etiketlenir ve tarama geçmeden ECR'ye gönderilmez. AWS erişimi
OIDC ile yapılır; GitHub'da kalıcı AWS anahtarı tutulmaz.

Test kapsamı: MERN davranışı production nginx imajına karşı Cypress e2e testiyle (3 senaryo)
doğrulanır; ayrı bir backend unit test paketi yoktur. ETL tarafında lint ve derleme kontrolü
yapılır, çalışma doğrulaması deploy sonrası geçici Job ile yapılır.

Gerekli GitHub variables:

- `AWS_ROLE_ARN`
- `ECR_REGISTRY`
- `EKS_CLUSTER_NAME`
- `PUBLIC_URL`

## Monitoring ve loglar

Backend ve ETL logları JSON olarak stdout'a yazılır. Alloy logları Loki'ye gönderir;
Prometheus Kubernetes metriklerini toplar. Grafana iki dashboard içerir.

Alarmlar Alertmanager üzerinden Slack'e gider; webhook verilmediyse `null` receiver'a
düşer. Dokuz kuralın kapsamı ve ilk müdahalesi:

| Alarm | Anlamı | İlk bakılacak |
|---|---|---|
| `PodCrashLooping` | Pod sürekli yeniden başlıyor | `kubectl -n mern logs <pod> --previous` |
| `BackendNotReady` / `FrontendNotReady` | Servisin hazır replica'sı yok | `kubectl -n mern get pods,endpoints` |
| `ETLJobFailed` / `ETLJobMissing` | Saatlik ETL hata verdi ya da 65 dk koşmadı | `kubectl -n mern get jobs`, Job logları |
| `MongoDiskFilling` | PVC %80 üzeri dolu | PVC boyutu artırılır |
| `NodeNotReady` / `NodeMemoryPressure` / `NodeDiskPressure` | Node sorunu | `kubectl describe node` |

Grafana public değildir:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
terraform -chdir=terraform/envs/prod output -raw grafana_admin_password
```

## Güvenlik

- Container'lar non-root, read-only filesystem ve `drop: ALL` ile çalışır.
- Default-deny NetworkPolicy uygulanır.
- MongoDB authentication açıktır ve yalnız cluster içinden erişilir.
- Parolalar Terraform tarafından üretilir; Git'te secret veya state tutulmaz.
- ECR tag'leri immutable'dır ve imajlar Trivy ile taranır.
- GitHub Actions AWS'ye OIDC ile bağlanır; rol bu repository kimliğiyle sınırlıdır.
- Backend loglarında authorization ve cookie header'ları maskelenir.

## Ekran görüntüleri

| Kanıt | Görseller |
|---|---|
| Frontend | [Ana sayfa](docs/screenshots/01-frontend-anasayfa.png) · [Kayıt listesi](docs/screenshots/02-frontend-kayit-listesi.png) · [Kayıt oluşturma](docs/screenshots/03-frontend-kayit-olusturma.png) |
| API | [`/api/record`](docs/screenshots/04-api-record-json.png) · [Readiness](docs/screenshots/05-api-healthcheck-ready.png) |
| Kubernetes | [Pod'lar](docs/screenshots/06-kubectl-get-pods.png) · [ETL Job geçmişi](docs/screenshots/07-cronjob-job-gecmisi.png) |
| Monitoring | [MERN dashboard](docs/screenshots/08-grafana-mern-servis-durumu.png) · [ETL dashboard](docs/screenshots/09-grafana-etl-cronjob.png) · [Alarm](docs/screenshots/10-alertmanager-firing-alert.png) |
| CI/CD | [GitHub Actions](docs/screenshots/11-github-actions-pipeline.png) · [ECR depoları](docs/screenshots/12-ecr-imajlar.png) · [İmaj etiketleri](docs/screenshots/13-ecr-imaj-etiketleri.png) |

## Repo yapısı

```text
docker/                  Dockerfile'lar ve nginx yapılandırması
k8s/                     Base manifestler ve prod overlay
terraform/               AWS altyapısı ve remote state kurulumu
monitoring/              Helm values, alarmlar ve dashboard'lar
.github/workflows/       MERN ve ETL pipeline'ları
mern-project/            React frontend ve Express backend
python-project/          ETL kodu ve log sarmalayıcısı
docs/                    Zorluklar ve ekran görüntüleri
```

## Bilinen sınırlar

Bu çözüm kısa süreli bir değerlendirme ortamı için hazırlandı. MongoDB tek replica,
node grubu sabit ve monitoring diskleri AZ'ye bağlıdır. Production ortamında MongoDB
ReplicaSet/DocumentDB, Secrets Manager + External Secrets, Karpenter ve özel domain +
ACM tercih edilmelidir.

Pod silme ve node drain testleri kesintisiz tamamlandı. Testlerde bulunan ilk ALB 502
sorunu `preStop` ve deregistration ayarlarıyla giderildi. Ayrıntılar
[Karşılaşılan Zorluklar](docs/KARSILASILAN_ZORLUKLAR.md) dokümanındadır.
