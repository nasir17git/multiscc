#!/bin/bash
set -euo pipefail
trap 'echo "❌ 오류 발생: 라인 $LINENO, 명령어: $BASH_COMMAND"' ERR

# /path/to/.../k8s
BASE_DIR="$(cd "$(dirname "$0")" && pwd)/k8s"
CONFIG_DIR="$BASE_DIR/config"
APP_DIR="$BASE_DIR/app"
PLATFORM_DIR="$BASE_DIR/platform"
CLUSTER_CONFIG_FILE="$PLATFORM_DIR/kind-cluster.yaml"
source "$CONFIG_DIR/cluster.env"
source "$CONFIG_DIR/logging.sh"

MISSING_TOOLS=()

for tool in kind kubectl helm docker; do
  if ! command -v $tool &> /dev/null; then
    log_error "$tool 명령어를 찾을 수 없습니다."
    MISSING_TOOLS+=("$tool")
  fi
done

if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
  echo
  log_error "누락된 도구: ${MISSING_TOOLS[*]}"
  echo "👉 다음 명령어로 설치 및 업데이트 해주세요:"
  echo "   brew install kind kubernetes-cli helm docker"
  exit 1
fi

log_success "필수 도구가 모두 설치되어 있습니다."

# ------------------------------------------------------------
# 기존 클러스터 확인
if kind get clusters | grep -q "^$CLUSTER_NAME$"; then
  echo "⚠️  Kind 클러스터 '$CLUSTER_NAME' 가 이미 존재합니다."
  read -p "👉 삭제 후 재생성할까요? [y/N]: " answer
  case "$answer" in
    [yY]|[yY][eE][sS])
      log_info "기존 클러스터 $CLUSTER_NAME 삭제 중..."
      kind delete cluster --name "$CLUSTER_NAME"
      ;;
    *)
      log_info "기존 클러스터 $CLUSTER_NAME 유지. 스크립트를 종료합니다."
      exit 0
      ;;
  esac
fi

log_info "Kind 클러스터 $CLUSTER_NAME 생성 중..."
kind create cluster --name "$CLUSTER_NAME" --config "$CLUSTER_CONFIG_FILE"
log_success "Kind 클러스터 $CLUSTER_NAME 생성 완료."

# ------------------------------------------------------------
# Preload Images
log_info "플랫폼 이미지 preload 중..."
for img in "${IMAGES[@]}"; do
  echo "📦 이미지 preload: $img"
  docker pull "$img" || log_error "$img pull 실패"
  kind load docker-image "$img" --name "$CLUSTER_NAME" || log_error "$img kind load 실패"
done
log_success "플랫폼 이미지 preload 완료."

log_info "Helm 저장소 추가/업데이트 중..."
helm repo add bitnami https://charts.bitnami.com/bitnami || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add strimzi https://strimzi.io/charts/ || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

log_info "플랫폼 서비스 배포 중 (Database, Observability)..."


# ArgoCD
helm upgrade argocd argo/argo-cd --version 9.3.7 -n argocd --install

# Monitoring (Loki + Tempo + Grafana + Prometheus)

kubectl create ns monitoring || true
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 77.10.0 -n monitoring -f "$PLATFORM_DIR/kube-prometheus-stack.yaml" --install
helm upgrade loki grafana/loki --version 6.41.0 -n monitoring -f "$PLATFORM_DIR/loki.yaml" --install
helm upgrade tempo grafana/tempo-distributed --version 1.46.2 -n monitoring -f "$PLATFORM_DIR/tempo.yaml" --install

# OpenTelemetry (Operator + Collector)
helm upgrade otel-operator open-telemetry/opentelemetry-operator --version 0.95.1 -n monitoring -f "$PLATFORM_DIR/otel-operator.yaml" --install --wait
helm upgrade otel-collector open-telemetry/opentelemetry-collector --version 0.134.1 -n monitoring -f "$PLATFORM_DIR/otel-collector.yaml" --install

# MySQL
kubectl create ns database || true
helm upgrade mysql bitnami/mysql --version 14.0.3 -n database -f "$PLATFORM_DIR/mysql.yaml" --install --wait

log_success "플랫폼 서비스 배포 완료."

log_info "애플리케이션 배포 중..."
kubectl apply -f "$PLATFORM_DIR/instrumentation.yaml"
kubectl apply -f "$APP_DIR"

# pet-clinic 서버 준비 대기
log_info "환경 구성 완료 후 $APP_NAME 시작 대기..."
kubectl rollout status deployment/custom-$APP_NAME -n default

# ------------------------------------------------------------
log_info "애플리케이션 헬스체크 시작..."

check_ok=false

# $APP_NAME 헬스체크
for i in {1..10}; do
  if curl -fsS "http://localhost:30001/actuator/health" | grep -q '"status":"UP"'; then
    log_success "애플리케이션 $APP_NAME 정상 동작 중."
    check_ok=true
    break
  fi
  printf "\r⏳ $APP_NAME 헬스체크 대기 중 (%d/10)" "$i"
  sleep 5
done
echo

if [ "$check_ok" = false ]; then
  log_error "❌ $APP_NAME (포트 30001) 가 정상 상태가 아닙니다."
  exit 1
fi

# ------------------------------------------------------------
# 배포 요약
echo
echo "------------------------------------------------------------"
echo "🚀 배포 요약"
echo "------------------------------------------------------------"
echo "🌐 애플리케이션 엔드포인트"
echo "   ▸ $APP_NAME            http://localhost:30001"
echo
echo "🎛️ ArgoCD                 http://localhost:30002"
echo "   ▸ (로그인: admin / 비밀번호: admin1!)"
echo "📊 모니터링"
echo "   ▸ Grafana               http://localhost:30004"
echo "      (로그인: admin / 비밀번호: admin)"
echo "   ▸ Prometheus            http://localhost:30009"
echo "   ▸ Otel Collector        http://localhost:30010"
echo
echo "------------------------------------------------------------"
