#!/bin/bash
#
# 클러스터 머신 컨피그 base를 PVE snippets 디렉토리에 배치
#
# 동작:
#   - _out/controlplane.yaml → snippets/_talos-cp-base.yaml
#   - _out/worker.yaml       → snippets/_talos-wk-base.yaml
#   - snippets content type이 storage에 활성화되어 있는지 확인 (없으면 활성화)
#
# 멱등 — 재실행해도 안전. _out/이 갱신되었을 때 다시 돌리면 base가 새로 박힌다.
# 이미 만든 노드별 <VM_NAME>-user.yaml에는 영향 없음(03이 base에서 한 번만 복사).
#
# 사전 요구사항:
#   - 01-gen-talos-config.sh 가 먼저 실행되어 ${HOME}/talos-cluster/_out/ 가 존재
#   - Proxmox 호스트에서 root로 실행
#
# 사용법: bash 02-place-base-snippets.sh
#

set -e

# ==== 변수 ====
WORK_DIR="${HOME}/talos-cluster"
SNIPPETS_DIR="/var/lib/vz/snippets"
STORAGE="local"

# 역할별 base 스닙셋 파일명. 03-create-talos-vm.sh가 ROLE에 맞춰 이 파일을
# <VM_NAME>-user.yaml로 복사해 사용한다. VM-named 스닙셋과 충돌하지 않도록
# '_' prefix로 네임스페이스를 분리한다.
CP_BASE_SNIPPET="_talos-cp-base.yaml"
WK_BASE_SNIPPET="_talos-wk-base.yaml"

# ==== 0. 사전 체크 ====

if [ ! -d "${WORK_DIR}/_out" ]; then
  echo "ERROR: ${WORK_DIR}/_out 가 없습니다. 먼저 01-gen-talos-config.sh를 실행하세요."
  exit 1
fi

if [ ! -f "${WORK_DIR}/_out/controlplane.yaml" ] || [ ! -f "${WORK_DIR}/_out/worker.yaml" ]; then
  echo "ERROR: ${WORK_DIR}/_out 안에 controlplane.yaml 또는 worker.yaml 이 없습니다."
  exit 1
fi

# Snippets 디렉토리 보장
mkdir -p "$SNIPPETS_DIR"

# Snippets content type 활성화 확인
if ! grep -A 5 "^dir: ${STORAGE}$" /etc/pve/storage.cfg | grep -q snippets; then
  echo "Enabling 'snippets' content type on storage '${STORAGE}'..."
  pvesm set "$STORAGE" --content iso,vztmpl,backup,snippets
fi

# ==== 1. base 배치 ====

echo "Placing base templates in ${SNIPPETS_DIR}..."

cp "${WORK_DIR}/_out/controlplane.yaml" "${SNIPPETS_DIR}/${CP_BASE_SNIPPET}"
echo "  ✓ ${SNIPPETS_DIR}/${CP_BASE_SNIPPET} (controlplane base)"

cp "${WORK_DIR}/_out/worker.yaml" "${SNIPPETS_DIR}/${WK_BASE_SNIPPET}"
echo "  ✓ ${SNIPPETS_DIR}/${WK_BASE_SNIPPET} (worker base)"

# ==== 2. 검증 ====

echo ""
echo "Verifying snippets..."
pvesm list "$STORAGE" --content snippets | grep -E "_talos-(cp|wk)-base" || true

echo ""
echo "Endpoint configured in cp base:"
grep -nE 'endpoint:[[:space:]]+https?://' "${SNIPPETS_DIR}/${CP_BASE_SNIPPET}" | head -3

# ==== 3. 안내 ====

cat <<EOF

==========================================================
✓ Base templates placed.

Next: 노드별 VM 생성
  bash 03-create-talos-vm.sh <VMID> <VM_NAME> <NODE_IP> [cp|worker]

==========================================================
EOF
