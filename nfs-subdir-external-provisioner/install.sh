#!/usr/bin/env bash
set -euo pipefail

# nfs-subdir-external-provisioner 설치/업그레이드 진입점
# 차트: https://github.com/kubernetes-sigs/nfs-subdir-external-provisioner/tree/master/charts/nfs-subdir-external-provisioner

CHART_VERSION="4.0.18"
RELEASE_NAME="nfs-subdir-external-provisioner"
NAMESPACE="nfs-subdir-external-provisioner"
REPO_NAME="nfs-subdir-external-provisioner"
REPO_URL="https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "${SCRIPT_DIR}"

# values 파일 점검
if [[ ! -f values.yaml ]]; then
  echo "ERROR: values.yaml 없음. values.template.yaml을 복사해 만드세요." >&2
  exit 1
fi

# 시크릿 없는 컴포넌트지만 컨벤션 유지 — template과 values가 어긋나면 경고
if ! diff -q values.template.yaml values.yaml > /dev/null 2>&1; then
  echo "WARN: values.template.yaml 과 values.yaml 이 어긋남. 의도한 변경인지 확인하세요." >&2
fi

# helm repo 등록 (이미 있으면 update)
if ! helm repo list 2>/dev/null | awk '{print $1}' | grep -qx "${REPO_NAME}"; then
  helm repo add "${REPO_NAME}" "${REPO_URL}"
fi
helm repo update "${REPO_NAME}"

# install / upgrade
helm upgrade --install "${RELEASE_NAME}" "${REPO_NAME}/nfs-subdir-external-provisioner" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${CHART_VERSION}" \
  -f values.yaml \
  --wait \
  --timeout 5m

echo
echo "설치 완료. 검증:"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl get sc"
echo "  # 동적 PV 시험: kubectl apply -f - <<'YAML'"
echo "  # apiVersion: v1; kind: PersistentVolumeClaim; metadata: ..."
