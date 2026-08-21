# Terraform — Altyapı

AWS `eu-central-1` üzerinde EKS cluster'ı, ağı, imaj kayıt defteri ve CI için
IAM rolü kurar.

## Stack'ler ve uygulama sırası

Sıra **zorunludur** — her stack bir öncekinin çıktısına dayanır.

| # | Stack | Ne yapar | Ne zaman |
|---|---|---|---|
| 1 | `bootstrap/` | Remote state için S3 bucket'ı | Bir kez, en başta |
| 2 | `envs/prod/` | VPC, EKS, ECR, IAM, ALB Controller | Aşama 3 |
| 3 | `envs/edge/` | CloudFront (HTTPS giriş noktası) | **Aşama 4'ten sonra** |

`envs/edge` neden sonra: ALB'yi Terraform yaratmaz — Kubernetes Ingress'ine
bakarak AWS Load Balancer Controller yaratır. Ingress uygulanmadan ALB yoktur,
CloudFront da origin bulamaz. Erken çalıştırılırsa plan hata verir (kasıtlı).

## Kurulum

```bash
# 1. State bucket'ı (yerel state ile, bir kez)
cd bootstrap
terraform init && terraform apply
terraform output backend_config     # çıktıyı envs/prod/backend.tf'e yazın

# 2. Ana altyapı
cd ../envs/prod
cp terraform.tfvars.example terraform.tfvars   # değerleri gözden geçirin
terraform init
terraform plan -out=tfplan
terraform apply tfplan                          # EKS ~15 dk

# 3. Cluster erişimi
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region eu-central-1
kubectl get nodes

# ... Aşama 4 manifestleri uygulanır, Ingress ALB'yi yaratır ...

# 4. CloudFront
cd ../edge
terraform init && terraform apply
terraform output app_url            # ekran görüntülerinde görünecek HTTPS adresi
```

## Maliyet ve gün sonu kapatma

Cluster ayaktayken yaklaşık **7.2 $/gün** (Aşama 6 monitoring dahil):

| Kalem | Günlük |
|---|---|
| EKS control plane (0.10 $/saat) | 2.40 $ |
| 3 × `t3.medium` | 3.11 $ |
| NAT Gateway ×1 | 1.25 $ |
| EBS — node diskleri (3 × 30 GB gp3) | 0.29 $ |
| EBS — PVC'ler (Prometheus 20Gi + Loki 10Gi + Mongo 10Gi) | 0.13 $ |
| ALB | ~0.60 $ |

Çalışılmayan saatlerde **`envs/prod` destroy edilir**. Node'ları 0'a çekmek
yetmez: control plane + NAT çalışmaya devam eder ve maliyetin yalnızca %38'i
kurtulur.

```bash
# Gün sonu
# ÖNCE monitoring PVC'leri: EBS volume'ları asılı kalırsa VPC destroy'u tıkanır
kubectl -n monitoring delete pvc --all
cd envs/prod && terraform destroy      # ~5 dk, ~0 $/gün'e iner

# Ertesi gün
cd envs/prod && terraform apply        # ~20 dk, aynı yapı geri gelir
aws eks update-kubeconfig --name $(terraform output -raw cluster_name) --region eu-central-1
```

`bootstrap` stack'i (state bucket'ı) **silinmez** — aylık maliyeti birkaç senttir
ve state'in yaşadığı yerdir. Silinirse tüm geçmiş kaybolur.

> Bu döngü aynı zamanda altyapının gerçekten sıfırdan kurulabildiğinin kanıtıdır;
> IaC'nin asıl vaadi budur.

## Kararlar ve tuzaklar

**State kilidi DynamoDB'siz.** Terraform 1.10+ ile gelen S3 native lockfile
(`use_lockfile = true`) kullanılıyor. Klasik DynamoDB tablosuna gerek yok —
bir kaynak, bir maliyet kalemi, bir hata yüzeyi eksik.

**Kubernetes sürümü bir maliyet kararıdır.** Standart destekten çıkmış bir
sürüm seçilirse control plane 0.10 $/saat yerine **0.60 $/saat** (6×) olur ve
extended support yeni cluster'larda **varsayılan olarak açıktır**. 1.34
seçilmesinin sebebi budur; 1.33 bu case yazılırken standart destekten çıkmıştı.
Değiştirmeden önce:

```bash
aws eks describe-cluster-versions --region eu-central-1 \
  --query "clusterVersions[?clusterVersion=='<sürüm>'].status"   # STANDARD_SUPPORT olmalı
```

**EBS CSI Driver olmadan hiçbir PVC bağlanmaz.** Addon + IRSA rolü
`envs/prod/main.tf` içinde birlikte tanımlı. Eksik olursa MongoDB StatefulSet'i
kalıcı `Pending`'de kalır ve Aşama 4 tamamen durur.

**Subnet tag'leri ALB Controller için zorunludur.** `kubernetes.io/role/elb`
(public) ve `kubernetes.io/role/internal-elb` (private) olmadan Ingress
sessizce `ADDRESS`'siz kalır — hata da vermez.

**Node disk boyutu launch template'ten gelir.** Modül özel launch template
kullandığı için node group'taki `disk_size` alanı yok sayılır;
`block_device_mappings` kullanılmalıdır. Varsayılan 20 GiB, monitoring
imajlarıyla DiskPressure'a girer.

**AWS provider sürümleri stack'ler arasında ayrışır.** `bootstrap` 6.x,
`envs/prod` 5.x kullanır: `terraform-aws-modules/eks` v20 henüz provider 6'yı
desteklemiyor (`< 6.0.0`). Ayrı state'ler olduğu için sorun değil; EKS modülü
v21'e geçildiğinde hizalanır.

## Bilinen sınırlar

| Sınır | Sebep | Prod'a geçiş yolu |
|---|---|---|
| Tek NAT Gateway | Maliyet (~1.2 $/gün tasarruf) | AZ başına bir NAT |
| 3 node, sabit (t3.medium, 6 vCPU) | Otomatik ölçekleme kapsam dışı; kota 5'ten 16 vCPU'ya çıkarıldı | Cluster Autoscaler / Karpenter |
| Mongo parolası state'te düz metin | `random_password` → K8s Secret (ADR 10); state S3'te şifreli ve sürümlü | External Secrets Operator + Secrets Manager |
| API endpoint `0.0.0.0/0`'a açık | CI runner IP'leri sabit değil | Sabit IP / VPN arkasından CIDR daraltma |
| Tek ortam (`prod`) | 3 günlük kapsam | `envs/dev` eklenmesi |

## Temizlik

Ekran görüntüleri alındıktan **sonra**:

```bash
cd envs/edge && terraform destroy
# Aşama 4 manifestleri silinir (Ingress silinmezse ALB kalır ve VPC destroy takılır)
kubectl delete -k ../../../k8s/overlays/prod
cd ../prod && terraform destroy
# bootstrap: force_destroy = true yapıp apply, sonra destroy
```
