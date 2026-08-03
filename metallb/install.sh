#!/usr/bin/env bash
set -euo pipefail

# MetalLB 설치/업그레이드 진입점
# 차트: https://github.com/metallb/metallb/tree/main/charts/metallb
#
# 절차: helm upgrade --install → controller/webhook ready 대기 → IPAddressPool/L2Advertisement apply.
# IPAddressPool/L2Advertisement는 CRD에 의존하므로 webhook이 ready되기 전에 apply하면 admission이 실패.

CHART_VERSION="0.15.3"
RELEASE_NAME="metallb"
NAMESPACE="metallb-system"
REPO_NAME="metallb"
REPO_URL="https://metallb.github.io/metallb"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "${SCRIPT_DIR}"

if [[ ! -f values.yaml ]]; then
  echo "ERROR: values.yaml 없음. 저장소에서 누락되었는지 확인하세요." >&2
  exit 1
fi

if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "${REPO_NAME}"; then
  helm repo add "${REPO_NAME}" "${REPO_URL}"
fi
helm repo update "${REPO_NAME}"

# speaker DaemonSet은 hostNetwork=true / NET_RAW / hostPort를 쓰므로
# PodSecurity baseline에선 차단됨. 네임스페이스가 없으면 만들어 두고 privileged로 라벨링.
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
kubectl label ns "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite >/dev/null

helm upgrade --install "${RELEASE_NAME}" "${REPO_NAME}/metallb" \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  -f values.yaml \
  --wait \
  --timeout 5m

# Webhook이 ready될 때까지 짧게 대기 — helm --wait는 deployment ready만 보지만
# webhook endpoint가 traffic을 받기까지 1~2초 추가 여유 필요한 경우가 있음.
echo "Waiting for metallb webhook to be ready..."
kubectl -n "${NAMESPACE}" rollout status deploy/metallb-controller --timeout=2m

# IPAddressPool / L2Advertisement 적용
kubectl apply -f ipaddresspool.yaml
kubectl apply -f l2advertisement.yaml

echo
echo "설치 완료. 검증:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get ipaddresspool -n ${NAMESPACE}"
echo "  kubectl get l2advertisement -n ${NAMESPACE}"
echo "  # 시험 LoadBalancer Service:"
echo "  kubectl create deploy lb-test --image=nginx:1.27-alpine"
echo "  kubectl expose deploy lb-test --port=80 --type=LoadBalancer"
echo "  kubectl get svc lb-test -w  # EXTERNAL-IP에 192.168.3.x 할당"
