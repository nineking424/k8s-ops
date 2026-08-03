#!/usr/bin/env bash
set -euo pipefail

# kube-prometheus-stack 설치/업그레이드 진입점
# 차트: https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack
#
# 절차: ns 생성 + PSA privileged 라벨링 → helm upgrade --install → operator/Grafana rollout 대기.
# node-exporter(DaemonSet)가 hostNetwork+hostPID+hostPath를 쓰므로 PSA baseline 차단됨 → privileged 라벨 필요.
# 외부 노출: Grafana는 grafana.k8s.stjeong.com (HTTP) 으로 Ingress. 외부 NPM이 TLS + 와일드카드 forward.

CHART_VERSION="84.5.0"
RELEASE_NAME="kube-prometheus-stack"
NAMESPACE="monitoring"
REPO_NAME="prometheus-community"
REPO_URL="https://prometheus-community.github.io/helm-charts"

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

# node-exporter(DaemonSet)가 hostNetwork=true / hostPID=true / hostPath를 쓰므로
# PodSecurity baseline에선 차단됨. ns가 없으면 만들어 두고 privileged로 라벨링.
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
kubectl label ns "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite >/dev/null

helm upgrade --install "${RELEASE_NAME}" "${REPO_NAME}/kube-prometheus-stack" \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  -f values.yaml \
  --wait \
  --timeout 10m

echo "Waiting for prometheus-operator deployment..."
kubectl -n "${NAMESPACE}" rollout status "deploy/${RELEASE_NAME}-operator" --timeout=3m
echo "Waiting for grafana deployment..."
kubectl -n "${NAMESPACE}" rollout status "deploy/${RELEASE_NAME}-grafana" --timeout=3m

echo
echo "설치 완료. 검증:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get pvc -n ${NAMESPACE}"
echo "  kubectl get ingress -n ${NAMESPACE}"
echo "  # Grafana admin password 확인:"
echo "  kubectl get secret -n ${NAMESPACE} ${RELEASE_NAME}-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo"
echo "  # Grafana 접속(외부 NPM 경유 HTTPS): https://grafana.k8s.stjeong.com"
echo "  # Prometheus port-forward: kubectl -n ${NAMESPACE} port-forward svc/${RELEASE_NAME}-prometheus 9090:9090"
