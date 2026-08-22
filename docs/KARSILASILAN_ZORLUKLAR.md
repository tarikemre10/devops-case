# Karşılaşılan Zorluklar

Bu doküman geliştirme sırasında karşılaşılan önemli sorunları ve alınan kararları
özetler. Ayrıntılı kurulum komutları [README.md](../README.md) ve
[terraform/README.md](../terraform/README.md) içindedir.

## Uygulama

### Frontend API adresleri

Frontend kodunda `localhost:5050` sabit kullanılıyordu. Bu adres container ve
Kubernetes ortamında çalışmadığı için tüm çağrılar `/api` yoluna taşındı. nginx bu
istekleri backend Service'e proxy'liyor. Aynı imaj böylece ortamdan bağımsız kaldı.

### MongoDB bağlantısı ve healthcheck

İlk kod bağlantı başarısız olduğunda belirsiz bir hatayla kapanıyordu. Bağlantıya
retry/backoff eklendi ve liveness ile readiness ayrıldı:

- Liveness yalnız Node.js sürecini kontrol ediyor.
- Readiness MongoDB'ye ping atıyor ve bağlantı yoksa pod'u trafikten çıkarıyor.

Geçersiz MongoDB ID'leri ve geçici bağlantı kesintileri de kontrollü HTTP yanıtına
dönüştürüldü; artık süreci düşürmüyor. Bu sorun teslim öncesi dayanıklılık testinde
ortaya çıktı ve ölçümleriyle birlikte
[aşağıda](#mongodb-kesintisi-backend-sürecini-düşürüyordu) anlatılıyor.

### Cypress testi

Mevcut test, kayıt ekledikten sonra yanlış sayfada sonucu arıyordu. Uygulama rotasını
değiştirmek yerine test `/records` sayfasını kontrol edecek şekilde düzeltildi. Testler
CRA development server'a değil, production nginx imajına karşı çalıştırılıyor.

## Konteynerler

İlk Trivy taramasında base image ve paketlerden gelen çok sayıda düzeltilebilir bulgu
vardı. Image sürümleri digest ile sabitlendi, Alpine paketleri güncellendi ve gereksiz
araçlar runtime katmanından çıkarıldı. Son kontrolde üç uygulama imajında düzeltilebilir
HIGH/CRITICAL bulgu kalmadı.

nginx read-only filesystem ile çalışırken cache ve PID dizinlerine yazamadı. Gerekli
dizinler `emptyDir` olarak mount edildi. Ayrıca backend Service henüz oluşmadan nginx'in
CrashLoop'a girmemesi için Kubernetes DNS çözümü çalışma zamanına bırakıldı.

## AWS ve Terraform

### Node kotası ve kapasite

Yeni AWS hesabının EC2 kotası üç `t3.medium` node için yeterli değildi. Cluster önce iki
node ile doğrulandı, kota artırıldıktan sonra üç node'a çıkarıldı. Üçüncü node yalnız
yedek kapasite için değil, monitoring pod'ları ve HPA'nın birlikte çalışabilmesi için
gerekliydi.

### EKS sürümü

Planlanan eski EKS sürümü extended support ücretine girmişti. Kontrol edilmeden
kullanılsaydı control plane maliyeti altı katına çıkacaktı. Standart destekteki 1.34
seçildi ve `kubectl` aynı minor sürüme sabitlendi.

### Kaynakların uygulama sırası

ALB, Terraform tarafından doğrudan değil Kubernetes Ingress'i izleyen AWS Load Balancer
Controller tarafından oluşturuluyor. Bu nedenle kurulum sırası şöyledir:

1. `bootstrap`: remote state bucket
2. `prod`: VPC, EKS, ECR, IAM ve monitoring
3. Kubernetes manifestleri: Ingress ve ALB
4. `edge`: ALB'yi origin olarak kullanan CloudFront

CloudFront daha erken uygulanırsa origin henüz bulunamadığı için kurulum tamamlanamaz.

## CI/CD

ECR tag'leri immutable olduğu için aynı commit yeniden çalıştırıldığında push hata
veriyordu. Workflow önce tag'in varlığını kontrol ediyor; varsa build ve push'u atlayıp
deploy'a devam ediyor.

İmaj taraması ECR push'tan önce yapılıyor. Buildx imajı yerel Docker daemon'una yüklüyor,
Trivy başarılı olursa push ediliyor. Böylece başarısız taramadan geçen bir imaj registry'ye
ulaşmıyor.

MERN ve ETL deploy'ları ayrıldı. MERN pipeline'ı yalnız frontend/backend Deployment'larını,
ETL pipeline'ı yalnız CronJob'ı güncelliyor. ETL doğrulaması saat başını beklemeden geçici
bir Job oluşturarak yapılıyor.

İlk OIDC denemesi başarısız oldu: GitHub `sub` claim'ini artık immutable biçimde
(`OWNER@<owner_id>/REPO@<repo_id>`) üretiyor, klasik `OWNER/REPO` kalıbıyla yazılmış trust
policy sessizce eşleşmiyor. Doğru değer CloudTrail'deki başarısız
`AssumeRoleWithWebIdentity` kaydından okundu ve trust policy'ye eklendi. Rol bu repository
kimliğiyle sınırlıdır; repo'nun tüm dalları rolü üstlenebilir, daraltma
(`allowed_subjects`) sonraki bir sertleştirme adımıdır.

## Monitoring ve alarmlar

İlk `FrontendNotReady` alarmında container adı manifestteki adla eşleşmiyordu. Sorgu
veri bulamadığı için alarm sessiz kalıyordu. Container adı düzeltildi ve servis/ETL
kurallarına `absent(...)` kontrolü eklendi. Böylece pod veya zaman serisi tamamen
kaybolduğunda da alarm tetikleniyor.

Alloy ilk yapılandırmada aynı log satırlarını birden fazla kez topladı. Kubernetes API
discovery ve relabel kuralları sadeleştirilerek tekrarlar kaldırıldı. Loglar JSON olarak
stdout'a yazılıyor; authorization ve cookie header'ları backend logger'da maskeleniyor.

Grafana'yı public açmak ikinci bir internet giriş noktası oluşturacağı için tercih
edilmedi. Yönetim erişimi port-forward ile sağlanıyor.

İlk Grafana oturumunda port-forward bağlantısı koptu ve pod'un `OOMKilled` olduğu görüldü.
Loglarda uygulama hatası yoktu; `256Mi` bellek limiti, boşta yaklaşık `200Mi` kullanan
Grafana 13'ün oturum açılışındaki artışını karşılamıyordu. Limit `512Mi` yapıldıktan sonra
pod kararlı kaldı ve kullanım `244Mi` olarak ölçüldü. Bu sorun pod boşta sağlıklı göründüğü
için ancak arayüz ilk kez kullanıldığında ortaya çıktı.

## Kesinti testleri

Bir backend pod'u silindiğinde 80 isteğin tamamı başarılı oldu. İlk node drain testinde
ALB hedef kaydı silinmeden pod kapandığı için sekiz istek hata verdi. Frontend ve backend'e
`preStop` gecikmesi, Ingress'e daha kısa deregistration süresi eklendi. Tekrarlanan testte
110 isteğin tamamı `200` döndü.

Bu test, manifestlerin yalnızca geçerli olmasının yeterli olmadığını gösterdi; kapanış
sırasının gerçek trafik altında ölçülmesi gerekiyordu.

### MongoDB kesintisi backend sürecini düşürüyordu

MongoDB pod'u silindiğinde üç backend pod'u işlenmeyen async hatalar nedeniyle yeniden
başladı ve kesinti 26 saniye sürdü. Async handler'lar merkezi hata middleware'ine bağlandı;
MongoDB hataları `503`, geçersiz ID ve alanlar `400` yanıtına dönüştürüldü. MongoDB
kaynaklı process-level hatalar için de koruma eklendi.

Düzeltmeden sonra aynı test tekrarlandı:

| Ölçüm | Düzeltme öncesi | Düzeltme sonrası |
|---|---|---|
| Backend pod restart | 3 pod, `exitCode 1` | **0** |
| Kesinti süresi | 26 sn | **20 sn** |
| Hata yanıtı | 4 × `502` + 1 timeout | 4 × `503`, timeout yok |
| Toplam istek | — | 1215 × `200`, 4 × `503` |
| Veri | korundu | korundu |
| Toparlanma | startup probe döngüsü | MongoDB hazır olur olmaz `200` |

Kalan 20 saniye tek replica MongoDB pod'unun ve EBS volume'ünün yeniden hazırlanmasından
kaynaklandı. Uygulama toparlanmayı artık geciktirmiyor.

### Rolling update ve yük altında ölçümler

Aynı doğrulama turunda iki ölçüm daha yapıldı. Her ikisinde de istekler public CloudFront
adresine gönderildi, yani ölçülen yol gerçek kullanıcının kullandığı yoldur.

| Test | Sonuç |
|---|---|
| Backend + frontend `rollout restart`, 5 dk kesintisiz istek | 1684/1684 `200`, sıfır `502` |
| Yük testi (`hey`, 150 eşzamanlı, 5 dk) | 219.718 istek, **0 hata**, p50 118 ms, p99 1.19 sn |
| HPA davranışı | CPU %5 → %429, **2 → 6 pod (~30 sn)**, yük bitince kademeli iniş |

Yük testi `hey -c 150 -z 5m "$APP/api/record"`, kesinti testleri ise 0.2 sn aralıklı
`curl -o /dev/null -w '%{http_code}'` döngüsüyle yapıldı; HPA `kubectl -n mern get hpa -w`
ile izlendi.

Yük testi cluster **dışından** yapılmak zorunda kaldı: küme içinde çalıştırılan yük üretici
pod'u NetworkPolicy hem backend'e hem frontend'e sokmadı. Beklenen davranış budur ve
default-deny kuralının gerçekten uygulandığının yan kanıtıdır.

## Bilinen sınırlar

- MongoDB tek replica olduğu için AZ kaybında otomatik kurtarma yoktur.
- Cluster Autoscaler/Karpenter kurulmadı; node grubu 3'te sabit tutulur (max 4, elle).
- Secret'lar Git'te değildir ancak Kubernetes Secret ve Terraform state içinde tutulur.
- Slack webhook verilmezse Alertmanager bildirimleri `null` receiver'a yollar.
- Uygulama seviyesinde özel Prometheus metriği yerine Kubernetes metrikleri kullanılır.
