#!/usr/bin/env bash
set -euo pipefail

# metrics-server 설치/업그레이드 진입점
# 차트: https://github.com/kubernetes-sigs/metrics-server/tree/master/charts/metrics-server

CHART_VERSION="3.13.0"
RELEASE_NAME="metrics-server"
NAMESPACE="kube-system"
REPO_NAME="metrics-server"
REPO_URL="https://kubernetes-sigs.github.io/metrics-server/"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "${SCRIPT_DIR}"

# values 파일 점검
if [[ ! -f values.yaml ]]; then
  echo "ERROR: values.yaml 없음. 저장소에서 누락되었는지 확인하세요." >&2
  exit 1
fi

# helm repo 등록 (이미 있으면 update)
if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "${REPO_NAME}"; then
  helm repo add "${REPO_NAME}" "${REPO_URL}"
fi
helm repo update "${REPO_NAME}"

# install / upgrade
helm upgrade --install "${RELEASE_NAME}" "${REPO_NAME}/metrics-server" \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  -f values.yaml \
  --wait \
  --timeout 5m

echo
echo "설치 완료. 검증:"
echo "  kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=${RELEASE_NAME}"
echo "  kubectl get apiservice v1beta1.metrics.k8s.io"
echo "  kubectl top nodes"
