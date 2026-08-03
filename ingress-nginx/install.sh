#!/usr/bin/env bash
set -euo pipefail

# ingress-nginx 설치/업그레이드 진입점
# 차트: https://github.com/kubernetes/ingress-nginx/tree/main/charts/ingress-nginx
#
# 절차: helm upgrade --install --wait → controller rollout 확인.
# AdmissionWebhook은 차트가 자동으로 cert를 patch — 별도 작업 불필요.

CHART_VERSION="4.15.1"
RELEASE_NAME="ingress-nginx"
NAMESPACE="ingress-nginx"
REPO_NAME="ingress-nginx"
REPO_URL="https://kubernetes.github.io/ingress-nginx"

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

helm upgrade --install "${RELEASE_NAME}" "${REPO_NAME}/ingress-nginx" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CHART_VERSION}" \
  -f values.yaml \
  --wait \
  --timeout 5m

echo "Waiting for ingress-nginx controller rollout..."
kubectl -n "${NAMESPACE}" rollout status deploy/ingress-nginx-controller --timeout=2m

echo
echo "설치 완료. 검증:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get svc ingress-nginx-controller -n ${NAMESPACE}  # EXTERNAL-IP=192.168.3.10"
echo "  kubectl get ingressclass"
