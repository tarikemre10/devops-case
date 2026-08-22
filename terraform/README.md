# Terraform Altyapısı

Terraform; remote state, VPC, EKS, ECR, IAM/OIDC, monitoring ve CloudFront
kaynaklarını yönetir.

## Uygulama sırası

| Sıra | Bileşen | İçerik |
|---|---|---|
| 1 | `bootstrap` | S3 remote state bucket'ı |
| 2 | `envs/prod` | VPC, EKS, ECR, IAM ve monitoring |
| 3 | Kubernetes | Uygulama manifestleri, Ingress ve ALB |
| 4 | `envs/edge` | CloudFront |

`edge`, Ingress ALB'yi oluşturduktan sonra uygulanmalıdır.

## Ön koşullar

Terraform 1.10+, AWS CLI, kubectl 1.34 ve Helm 3 gerekir. İlk imajlar yerelde
üretilecekse Docker da gereklidir.

```bash
aws sts get-caller-identity
```

AWS kimliği gerekli altyapı ve IAM kaynaklarını oluşturabilmelidir. Terraform
state secret değerleri içerdiği için hassas kabul edilmelidir.

## Kurulum

```bash
# Remote state
terraform -chdir=terraform/bootstrap init
terraform -chdir=terraform/bootstrap apply
terraform -chdir=terraform/bootstrap output
```

Çıktıdaki bucket adını şu üç yere yazın:

- `terraform/envs/prod/backend.tf`: S3 backend
- `terraform/envs/edge/main.tf`: S3 backend ve `terraform_remote_state`

```bash
# Değişkenler
cp terraform/envs/prod/terraform.tfvars.example terraform/envs/prod/terraform.tfvars

# Ana altyapı
terraform -chdir=terraform/envs/prod init
terraform -chdir=terraform/envs/prod apply

# Cluster erişimi
aws eks update-kubeconfig \
  --name "$(terraform -chdir=terraform/envs/prod output -raw cluster_name)" \
  --region eu-central-1
kubectl get nodes
```

`terraform.tfvars`, state ve plan dosyaları Git'e eklenmemelidir.

## İlk dağıtım

Manifestler uygulanmadan önce ilk imajların ECR'de bulunması gerekir.

```bash
REG=$(terraform -chdir=terraform/envs/prod output -raw ecr_registry_url)
TAG=$(git rev-parse --short HEAD)

aws ecr get-login-password --region eu-central-1 \
  | docker login --username AWS --password-stdin "$REG"

docker build -f docker/Dockerfile.server \
  -t "$REG/mern-devops-case/mern-server:$TAG" mern-project/server
docker build -f docker/Dockerfile.client \
  --build-context nginxconf=docker/nginx \
  -t "$REG/mern-devops-case/mern-client:$TAG" mern-project/client
docker build -f docker/Dockerfile.etl \
  -t "$REG/mern-devops-case/mern-etl:$TAG" python-project

docker push "$REG/mern-devops-case/mern-server:$TAG"
docker push "$REG/mern-devops-case/mern-client:$TAG"
docker push "$REG/mern-devops-case/mern-etl:$TAG"
```

`k8s/overlays/prod/kustomization.yaml` içindeki üç `newTag` değerini `$TAG` yapın.
Başka bir AWS hesabında `newName` değerlerini de `$REG/mern-devops-case/<repo>`
biçiminde güncelleyin.

```bash
kubectl kustomize k8s/overlays/prod \
  | sed "s/__ORIGIN_VERIFY__/$(terraform -chdir=terraform/envs/prod output -raw origin_verify_secret)/" \
  | kubectl apply -f -

kubectl -n mern rollout status deploy/backend --timeout=5m
kubectl -n mern rollout status deploy/frontend --timeout=5m
kubectl -n mern get ingress mern-ingress -w
```

Ingress `ADDRESS` alanı dolduktan sonra:

```bash
terraform -chdir=terraform/envs/edge init
terraform -chdir=terraform/envs/edge apply
terraform -chdir=terraform/envs/edge output app_url
```

### Doğrulama

```bash
kubectl -n mern get pods,ingress
kubectl -n monitoring get pods

APP=$(terraform -chdir=terraform/envs/edge output -raw app_url)
curl -s "$APP/api/healthcheck/ready"
```

GitHub Actions değişkenleri için [ana README'nin CI/CD bölümüne](../README.md#cicd)
bakın.

## Kapatma

Sıra: `edge` → uygulama ve PVC'ler → monitoring ve PVC'ler → `prod`.

```bash
# CloudFront
terraform -chdir=terraform/envs/edge destroy

# Uygulama, Ingress/ALB ve MongoDB PVC
ALB_DNS=$(kubectl -n mern get ingress mern-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
ALB_ARN=$(aws elbv2 describe-load-balancers --region eu-central-1 \
  --query "LoadBalancers[?DNSName=='$ALB_DNS'].LoadBalancerArn | [0]" --output text)
kubectl delete -k k8s/overlays/prod
aws elbv2 wait load-balancers-deleted --region eu-central-1 \
  --load-balancer-arns "$ALB_ARN"
kubectl -n mern wait --for=delete pod --all --timeout=5m
kubectl -n mern delete pvc --all

# Monitoring ve PVC'ler
terraform -chdir=terraform/envs/prod destroy \
  -target=helm_release.kube_prometheus_stack \
  -target=helm_release.loki \
  -target=helm_release.alloy
kubectl -n monitoring wait --for=delete pod --all --timeout=5m
kubectl -n monitoring delete pvc --all

# Kalan altyapı
terraform -chdir=terraform/envs/prod destroy
```

`bootstrap` normalde korunur. Tamamen silinecekse S3 bucket içindeki tüm obje
sürümlerini ve delete marker'ları temizleyip
`terraform -chdir=terraform/bootstrap destroy` çalıştırın.

Mimari ve sınırlar için [MIMARI.md](../MIMARI.md), kararların gerekçeleri için
[KARSILASILAN_ZORLUKLAR.md](../docs/KARSILASILAN_ZORLUKLAR.md) dosyasına bakın.
