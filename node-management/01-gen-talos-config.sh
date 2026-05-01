#!/bin/bash
#
# Talos 클러스터 시크릿/머신 컨피그 생성 스크립트 (한 번만 실행)
#
# 동작:
#   - talosctl이 없으면 자동 설치
#   - talosctl gen config로 controlplane.yaml / worker.yaml / talosconfig 생성
#   - cluster.controlPlane.endpoint를 CLUSTER_VIP로 박음
#
# 절대 재실행 금지 — 인증서/시크릿이 통째로 새로 발급되어 운영 중인 클러스터를 망가뜨립니다.
# 다음 단계(snippets 배치)는 02-place-base-snippets.sh, VM 생성은 03-create-talos-vm.sh.
#
# 사용법: bash 01-gen-talos-config.sh
#

set -e

# ==== 변수 ====
CLUSTER_NAME="talos-homelab"
# Cluster endpoint는 control plane VIP. cp의 machine.network.interfaces[].vip.ip와 동일해야
# 함. 03-create-talos-vm.sh가 cp 노드에 VIP 블록을 박을 때도 같은 IP를 사용한다.
CLUSTER_VIP="192.168.2.100"
TALOS_VERSION="v1.13.0"
WORK_DIR="${HOME}/talos-cluster"

# ==== 0. 사전 체크 & 준비 ====

# talosctl 설치 확인
if ! command -v talosctl &>/dev/null; then
  echo "Installing talosctl ${TALOS_VERSION}..."
  curl -Lo /usr/local/bin/talosctl \
    "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64"
  chmod +x /usr/local/bin/talosctl
fi
echo "talosctl: $(talosctl version --client --short 2>/dev/null || talosctl version --client)"

# ==== 1. 클러스터 컨피그 생성 ====

mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# 기존 컨피그가 있으면 백업 — 재실행 자체는 위험하지만, 백업은 보존해 둠
if [ -d "_out" ]; then
  BACKUP_DIR="_out.backup.$(date +%Y%m%d_%H%M%S)"
  echo "Existing _out/ found, backing up to ${BACKUP_DIR}"
  echo "  (재실행은 운영 클러스터를 망가뜨립니다 — 의도한 작업인지 다시 확인하세요)"
  mv _out "$BACKUP_DIR"
fi

echo "Generating cluster config: ${CLUSTER_NAME} → https://${CLUSTER_VIP}:6443"
talosctl gen config "$CLUSTER_NAME" "https://${CLUSTER_VIP}:6443" \
  --output-dir ./_out

ls -la _out/

# ==== 2. 안내 ====

cat <<EOF

==========================================================
✓ Talos cluster config generated.

Files:
  Cluster configs:    ${WORK_DIR}/_out/
  talosconfig:        ${WORK_DIR}/_out/talosconfig

Endpoint baked into base: https://${CLUSTER_VIP}:6443

Save talosconfig path:
  export TALOSCONFIG=${WORK_DIR}/_out/talosconfig

  # Optional: persist to shell profile
  echo 'export TALOSCONFIG=${WORK_DIR}/_out/talosconfig' >> ~/.bashrc

Next steps:
  1) bash 02-place-base-snippets.sh   # _out → snippets/ 로 base 배치
  2) bash 03-create-talos-vm.sh ...   # 노드별 VM 생성

==========================================================
EOF
