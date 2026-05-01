# Talos OS를 Proxmox에 cloud-init으로 배포하기

이 문서는 Proxmox VE에서 cloud-init(`nocloud`) 방식으로 Talos Linux 클러스터를 구성하는 표준 절차를 정리한 가이드입니다. ISO 부팅 후 `talosctl apply-config`로 적용하는 일반 방식 대신, **VM이 부팅하자마자 머신 컨피그가 자동 적용**되는 워크플로우입니다.

## 적용 환경

이 가이드는 다음 환경을 전제로 작성되었습니다.

- **Proxmox VE** 8.x 이상, 단일 호스트 (`pve-main`)
- **스토리지**: `local` (디렉토리 기반, qcow2)
- **네트워크**: 홈 라우터가 `192.168.0.0/16` 단일 서브넷으로 운영
  - 게이트웨이: `192.168.1.1`
  - 노드 IP 할당 대역: `192.168.2.x`
  - 마스크는 `/16`
- **Talos 버전**: v1.13.0
- **OS 익스텐션**: `siderolabs/qemu-guest-agent` 포함

다른 환경에서 사용할 때는 세 스크립트 상단의 변수를 환경에 맞게 조정하세요.

- `01-gen-talos-config.sh`: `CLUSTER_NAME`, `CLUSTER_VIP`(control plane VIP, cluster endpoint), `TALOS_VERSION`. 절대 재실행 금지.
- `02-place-base-snippets.sh`: `STORAGE`, snippets 디렉토리 경로. 멱등 — `_out/`이 갱신되면 다시 돌려도 안전.
- `03-create-talos-vm.sh`: `SCHEMATIC_ID`(Image Factory에서 발급), `NODE_CIDR`, `GATEWAY`, `DNS_SERVERS`, `SEARCH_DOMAIN`, `CP_VIP`(cp 역할일 때 자동 삽입할 VIP), 역할별 리소스(`MEMORY` / `CORES` / `DISK_SIZE`) — 리소스는 기본값이고 호출 시 `--cpu` / `--memory` / `--disk` 옵션으로 노드별 덮어쓸 수 있습니다. cluster endpoint도 `--endpoint`로 노드별 덮어쓸 수 있습니다(VIP/외부 LB용).

## 설계 결정 요약

| 항목 | 선택 | 이유 |
|---|---|---|
| 부팅 방식 | cloud-init (nocloud) | VM 시작 즉시 머신 컨피그 자동 적용, 템플릿화/대량 배포 용이 |
| Talos 이미지 | `nocloud-amd64.raw` | nocloud platform용 디스크 이미지 (ISO 아님) |
| BIOS | OVMF (UEFI) + EFI Disk (`pre-enrolled-keys=0`) | nocloud 이미지가 Secure Boot 미서명이라 키 enroll 비활성 |
| Machine | q35 | PCIe 지원, 권장 머신 타입 |
| SCSI Controller | virtio-scsi-single | 디스크별 컨트롤러 분리로 I/O 성능 향상 |
| CPU | host | 호스트 CPU 기능 그대로 노출 |
| 디스크 | qcow2, ssd=1, discard=on | thin provisioning + TRIM 지원 |
| 메모리 | balloon=0 | Kubernetes 환경에서 ballooning 비활성 권장 |
| Image Factory 옵션 | `qemu-guest-agent` 익스텐션 | Proxmox Guest Agent 통합 |

## 사전 준비

01/02 스크립트가 다음을 자동으로 처리합니다 — 직접 실행할 필요 없음.

- `talosctl` 설치 (01, 없을 때만)
- `local` 스토리지의 snippets content type 활성화 (02, `pvesm set local --content ...`)
- `/var/lib/vz/snippets/` 디렉토리 생성 (02)

수동 작업으로 한 번만 해두어야 하는 건 아래 한 가지입니다.

### Image Factory에서 Schematic 생성

[factory.talos.dev](https://factory.talos.dev/)에서 다음 옵션으로 schematic을 만들고 ID를 받습니다.

- Hardware Type: **Cloud Server** → Platform: **nocloud**
- Architecture: **amd64**
- System Extensions: **siderolabs/qemu-guest-agent**

발급받은 schematic ID(예: `ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515`)는 `03-create-talos-vm.sh`의 `SCHEMATIC_ID` 변수에 넣습니다.

수동으로 미리 환경을 정비하고 싶다면 다음 명령들을 참고하세요(전부 01/02가 알아서 합니다).

```bash
# Snippets content type 활성화 + 디렉토리
pvesm set local --content iso,vztmpl,backup,snippets
mkdir -p /var/lib/vz/snippets

# talosctl 설치
TALOS_VERSION="v1.13.0"
curl -Lo /usr/local/bin/talosctl \
  "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64"
chmod +x /usr/local/bin/talosctl
```

## 배포 워크플로우

전체 작업은 다섯 단계로 나뉩니다.

```
[01-gen-talos-config.sh]      → 클러스터 시크릿/머신컨피그 생성 (1회, 절대 재실행 금지)
            ↓
[02-place-base-snippets.sh]   → snippets/에 역할별 base 템플릿 배치 (멱등, _out 갱신 시 재실행)
            ↓
[03-create-talos-vm.sh]       → 노드별 스닙셋 자동 생성(cp는 VIP 자동 삽입) + VM 생성/부팅 (노드마다 반복)
            ↓
[talosctl bootstrap]          → 첫 CP에서 한 번만
            ↓
[kubectl get nodes]           → 클러스터 확인
```

### 1단계: 클러스터 시크릿/머신컨피그 생성 (01)

`01-gen-talos-config.sh`에서 클러스터 이름과 cluster endpoint(VIP)를 정의합니다. 노드 목록을 미리 등록할 필요는 없습니다.

```bash
CLUSTER_NAME="talos-homelab"
CLUSTER_VIP="192.168.2.100"   # control plane VIP (cp 머신 컨피그의 vip.ip와 동일)
```

실행:

```bash
bash 01-gen-talos-config.sh
```

이 단계가 끝나면 `~/talos-cluster/_out/`에 다음 파일들이 생성됩니다. base 템플릿을 snippets로 복사하는 일은 02가 따로 처리합니다(스크립트 분리: 01은 시크릿 발급이라 위험하고 02는 멱등이라 안전).

```
~/talos-cluster/_out/
├── controlplane.yaml   # 02가 → snippets/_talos-cp-base.yaml 로 복사
├── worker.yaml         # 02가 → snippets/_talos-wk-base.yaml 로 복사
└── talosconfig         # talosctl 클라이언트 인증 (반드시 안전하게 보관)
```

`talosconfig`는 클러스터 관리 전체 권한을 가진 인증 파일이라 분실/유출되면 클러스터 접근을 잃거나 탈취될 수 있습니다. Git에 커밋하지 말고 별도 보관소(1Password, Vault, 백업 디스크 등)에 두세요.

### 2단계: snippets에 base 배치 (02)

`02-place-base-snippets.sh`는 `_out/{controlplane,worker}.yaml`을 snippets 디렉토리에 `_talos-{cp,wk}-base.yaml` 이름으로 복사하고, 필요 시 storage의 snippets content type도 활성화합니다.

```bash
bash 02-place-base-snippets.sh
```

멱등 — `_out`을 갱신했을 때(예: endpoint 바꿔서 01을 다시 돌렸을 때) 다시 호출하면 base가 새로 박힙니다. 이미 만든 노드별 `<VM_NAME>-user.yaml`에는 영향이 없습니다(03이 base에서 한 번 복사한 뒤 독립 운용).

### 3단계: VM 생성 (03)

`03-create-talos-vm.sh`는 인자 기반으로 동작합니다.

```bash
Usage: 03-create-talos-vm.sh [OPTIONS] <VMID> <VM_NAME> <NODE_IP> [ROLE]

Options:
  --cpu N           CPU 코어 수 (역할별 기본값을 덮어씀)
  --memory N        메모리 크기 (MiB)
  --disk SIZE       디스크 크기 (예: 32G, 64G)
  --endpoint URL    cluster.controlPlane.endpoint (예: https://10.0.0.10:6443)
```

CP 3대 + Worker 2대를 만드는 예시:

```bash
# Control Plane (cp 역할 → 03이 자동으로 vip.ip 블록을 user.yaml에 삽입)
bash 03-create-talos-vm.sh 106 talos-cp-01 192.168.2.106 cp
bash 03-create-talos-vm.sh 107 talos-cp-02 192.168.2.107 cp
bash 03-create-talos-vm.sh 108 talos-cp-03 192.168.2.108 cp

# Worker
bash 03-create-talos-vm.sh 111 talos-wk-01 192.168.2.111 worker
bash 03-create-talos-vm.sh 112 talos-wk-02 192.168.2.112 worker
```

`ROLE`에 따라 리소스 사양이 다르게 적용됩니다.

| Role | Memory | Cores | Disk |
|---|---|---|---|
| cp | 4096 MiB | 2 | 32 GB |
| worker | 4096 MiB | 4 | 64 GB |

운영 환경에 맞게 스크립트의 역할별 분기 로직을 조정하거나, 호출 시 옵션으로 덮어쓸 수 있습니다.

```bash
# CP에 코어/메모리/디스크를 더 크게 할당
bash 03-create-talos-vm.sh --cpu 4 --memory 8192 --disk 64G \
  106 talos-cp-01 192.168.2.106 cp
```

cluster endpoint를 다른 VIP나 외부 LB로 두고 싶다면 `--endpoint`를 사용하세요. 옵션은 해당 노드의 `<VM_NAME>-user.yaml`에 박힌 `cluster.controlPlane.endpoint`만 치환하므로, **모든 노드에 같은 값으로 호출해야** 클러스터가 일관되게 동작합니다(기본은 01의 `CLUSTER_VIP`).

```bash
# 예: 외부 LB 192.168.2.200을 CP endpoint로 쓰는 경우
for i in 1 2 3; do
  bash 03-create-talos-vm.sh --endpoint https://192.168.2.200:6443 \
    10$((i+5)) talos-cp-0${i} 192.168.2.10$((i+5)) cp
done
```

`base` 템플릿 자체의 endpoint를 영구히 바꾸고 싶다면 `01-gen-talos-config.sh`의 `CLUSTER_VIP`를 바꾸고 01→02를 다시 돌리는 게 더 깔끔합니다(부트스트랩 전 한정).

`03-create-talos-vm.sh`는 호출 시 다음과 같이 동작합니다.

- `<VM_NAME>-user.yaml` 스닙셋이 이미 있으면 그대로 사용 (수동으로 패치한 컨피그가 보존됩니다).
- 없으면 `ROLE`에 맞는 base 템플릿(`_talos-cp-base.yaml` 또는 `_talos-wk-base.yaml`)을 복사해 새로 생성.
  - cp 역할이면 새 user.yaml에 `machine.network.interfaces[]` 블록(자기 IP `/16` + 게이트웨이 + `vip.ip: ${CP_VIP}`)을 자동으로 박습니다 — VIP는 03 상단의 `CP_VIP` 변수에서 가져오며, 다른 클러스터에 재사용할 때 그 값만 바꾸면 됩니다.
  - 모든 역할에 hostname을 노드 이름(`<VM_NAME>`)으로 박습니다.

따라서 새 노드를 추가할 때 01/02를 다시 돌릴 필요 없이 03만 호출하면 됩니다. 노드별로 컨피그를 다르게 가져가고 싶다면, 03 실행 후 생성된 `<VM_NAME>-user.yaml`을 직접 수정한 뒤 `talosctl apply-config`로 반영하세요.

### 4단계: etcd 부트스트랩

VM이 모두 부팅된 후 (약 1~2분), 첫 번째 CP 노드에서 **한 번만** etcd를 부트스트랩합니다.

```bash
# 관리 호스트 (Proxmox 호스트나 로컬 머신)
export TALOSCONFIG=~/talos-cluster/_out/talosconfig

talosctl config endpoint 192.168.2.106 192.168.2.107 192.168.2.108
talosctl config node 192.168.2.106

talosctl bootstrap
```

**중요**: `bootstrap`은 절대 두 번 이상 실행하지 마세요. etcd 데이터가 깨지고 클러스터를 복구하기 매우 어려워집니다.

### 5단계: kubeconfig 추출 및 검증

먼저 클러스터/노드 상태를 talosctl로 확인합니다.

```bash
talosctl health
```

`KUBELET`, `ETCD`, `CONTAINER RUNTIME`이 모두 정상이면 kubeconfig을 받아 kubectl로 검증합니다.

```bash
talosctl kubeconfig .
export KUBECONFIG=$(pwd)/kubeconfig

kubectl get nodes -o wide
kubectl get pods -A
```

모든 노드가 `Ready`이고 시스템 파드가 `Running`이면 클러스터가 정상 동작 중입니다. CNI 부트스트랩에 1~2분 더 걸릴 수 있습니다.

## 트러블슈팅

### `volume 'local:snippets/...' does not exist`

snippets 파일이 없거나 content type이 활성화되지 않은 경우. 다음을 확인:

```bash
# 1. content 활성화 확인
grep -A 5 "^dir: local$" /etc/pve/storage.cfg | grep snippets

# 2. 파일 존재 확인
ls -la /var/lib/vz/snippets/

# 3. Proxmox가 인식하는지 확인
pvesm list local --content snippets
```

### VM 부팅 직후 PXE Boot로 빠짐

이전 시도의 잔재로 ISO가 마운트되어 있거나, 디스크 import가 실패해 부팅 디스크가 없는 상태입니다.

```bash
# VM 설정 확인
qm config <VMID>
```

`scsi0`에 import된 디스크가 attach되어 있고 `boot: order=scsi0`인지 확인하세요. nocloud 이미지는 ISO가 아닌 `.raw`/`.qcow2` 디스크로 import되어야 합니다.

### `BdsDxe: failed to load Boot0001 ... Access Denied` / `Security Violation`

EFI Disk가 Secure Boot용 키(Microsoft 등)를 미리 enroll한 상태(`pre-enrolled-keys=1`)에서 만들어졌는데 Talos `nocloud-amd64.raw`에는 secure boot 서명이 없어 펌웨어가 부팅을 거부할 때 나타납니다. `No bootable option or device was found`로 끝나고 부트 매니저 메뉴로 떨어집니다.

`03-create-talos-vm.sh`는 EFI Disk를 `pre-enrolled-keys=0`으로 만들어 이 문제를 피합니다. 직접 만든 VM에서 이 에러가 보이면 EFI Disk를 다시 만드세요.

```bash
qm stop <VMID> --skiplock 1
qm set <VMID> --delete efidisk0
qm set <VMID> --efidisk0 local:0,efitype=4m,pre-enrolled-keys=0,format=qcow2
qm start <VMID>
```

### 외부 통신 안 됨 (이미지 pull 실패 등)

게이트웨이 서브넷 불일치가 가장 흔한 원인입니다.

```bash
# 노드 IP 대역과 게이트웨이가 같은 L2에 있어야 함
# 라우터 DHCP 풀이 192.168.0.0/16이라면 노드도 /16 마스크 사용

qm config <VMID> | grep ipconfig0
# → ipconfig0: ip=192.168.2.106/16,gw=192.168.1.1  ← /24가 아닌 /16
```

라우터의 DHCP 풀과 LAN 인터페이스 마스크를 확인해 동일한 마스크로 맞추세요.

### 머신 컨피그 endpoint와 노드 IP 불일치

`talosctl gen config` 시점에 박힌 `cluster.controlPlane.endpoint`가 실제 노드 IP와 다르면 부트스트랩 후 클러스터 endpoint 접근이 꼬입니다.

```bash
# base 템플릿 endpoint 확인
grep -A 1 "endpoint:" /var/lib/vz/snippets/_talos-cp-base.yaml | head -3
```

대응은 부트스트랩 여부에 따라 다릅니다.

**부트스트랩 전(아직 `talosctl bootstrap` 안 했음)**: 01을 다시 돌려 시크릿/머신컨피그를 재생성해도 안전합니다. 인증서/시크릿이 새로 나오지만 어차피 운영 중인 클러스터가 없습니다. 기존 노드별 user.yaml은 새 base와 어긋나므로 삭제하고 02→03을 다시 호출하세요.

```bash
bash 01-gen-talos-config.sh
bash 02-place-base-snippets.sh
rm /var/lib/vz/snippets/talos-cp-*-user.yaml /var/lib/vz/snippets/talos-wk-*-user.yaml
# 그 후 03을 노드별로 다시 호출
```

**부트스트랩 후(클러스터 운영 중)**: `01-gen-talos-config.sh`를 다시 돌리면 인증서/시크릿이 통째로 새로 발급되어 **기존 클러스터를 망가뜨립니다**. 절대 하지 마세요. endpoint를 옮기려면 talosctl로 직접 컨피그를 수정합니다.

```bash
# 현재 컨피그 추출 → endpoint 수정 → 적용
talosctl --nodes 192.168.2.106 get machineconfig -o yaml > /tmp/cp.yaml
# /tmp/cp.yaml의 cluster.controlPlane.endpoint를 새 값으로 편집
talosctl apply-config --nodes 192.168.2.106 --file /tmp/cp.yaml
```

### `qm destroy` 실패

VM이 실행 중이거나 락이 걸려 있을 때. 스크립트는 `--skiplock 1`로 처리하지만 수동으로 강제 정리하려면:

```bash
qm stop <VMID> --skiplock 1
qm unlock <VMID>
qm destroy <VMID> --purge 1 --skiplock 1
```

### 디스크 import는 성공했는데 unused0가 안 보임

`qm config`의 출력 파싱 문제일 수 있습니다. 직접 확인:

```bash
qm config <VMID> | grep -i unused
```

EFI Disk가 `disk-0`을 차지하므로 import된 Talos 디스크는 보통 `vm-XXX-disk-1.qcow2`로 잡힙니다.

## 일상 운영

### 노드 재시작 / 종료

```bash
talosctl --nodes 192.168.2.106 reboot
talosctl --nodes 192.168.2.106 shutdown
```

### 머신 컨피그 변경

cloud-init은 **최초 부팅 때만** 동작합니다. 운영 중 노드의 컨피그를 바꾸려면 talosctl로 직접 적용해야 합니다.

snippets 디렉토리에는 두 종류의 파일이 있고, 의미가 다릅니다.

- `_talos-cp-base.yaml` / `_talos-wk-base.yaml`: 향후 새로 만들 노드의 base. 여기를 고치면 다음에 02로 새 노드를 만들 때 반영됩니다(이미 만든 노드에는 영향 없음).
- `<VM_NAME>-user.yaml`: 특정 노드의 컨피그. 이 노드를 다시 만들 때(같은 이름으로 02 재호출) 사용됩니다.

운영 중 노드를 바꾸려면 노드별 user.yaml을 수정하고 `apply-config`로 반영하세요.

```bash
vim /var/lib/vz/snippets/talos-cp-01-user.yaml

talosctl apply-config \
  --nodes 192.168.2.106 \
  --file /var/lib/vz/snippets/talos-cp-01-user.yaml
```

변경 항목에 따라 자동 재부팅이 일어날 수 있습니다.

> **hostname:** snippet의 `HostnameConfig` 문서에서 `auto: stable`(random 생성) 대신 `hostname: <노드명>`을 박아야 의도한 이름(예: `talos-cp-01`)으로 부팅됩니다. 03 스크립트는 새 snippet을 만들 때 자동으로 `hostname: <VM_NAME>`을 박지만, 기존 snippet을 재사용하는 노드는 거기에 박힌 hostname이 그대로 적용됩니다(수동 패치 보존).

### Control Plane VIP 운영

cp 3대는 `machine.network.interfaces[].vip.ip = 192.168.2.100`을 머신 컨피그에 박아두었고, Talos가 etcd 기반 leader election으로 한 cp에만 VIP를 attach합니다. 다른 cp는 대기 상태이고, VIP 보유자가 죽으면 즉시 자동 fail-over됩니다 — 별도 컴포넌트(kube-vip 등) 없이 Talos 내장 기능만으로 처리.

VIP 보유 cp 식별:

```bash
for ip in 192.168.2.106 192.168.2.107 192.168.2.108; do
  echo "-- $ip --"
  talosctl --endpoints $ip --nodes $ip get addresses 2>/dev/null \
    | grep '192.168.2.100/' || echo '(not holder)'
done
```

fail-over 검증 (VIP 보유자 reboot → 다른 cp로 즉시 이전, kubectl 무단절):

```bash
talosctl --nodes <VIP_HOLDER_IP> reboot
# 몇 초 안에 다른 cp가 VIP를 보유. kubectl get nodes는 끊기지 않아야 함.
```

새 cp 추가 시: 03 스크립트가 cp 역할이면 `machine.network.interfaces` 블록(자기 IP `/16` + 게이트웨이 + `vip.ip: ${CP_VIP}`)을 새 user.yaml에 자동으로 박아 줍니다 — 별도 수작업 불필요. 다른 클러스터에 재사용할 때는 03 상단의 `CP_VIP`만 그 클러스터의 VIP로 바꾸면 됩니다(01의 `CLUSTER_VIP`와 동일하게 두는 것을 전제).

base 템플릿(`_talos-cp-base.yaml`)에는 노드별 IP 자리 때문에 `machine.network.interfaces`를 박지 않고, 03이 노드별 user.yaml을 만들 때 노드 IP를 채워 넣어 박습니다. cluster endpoint(`cluster.controlPlane.endpoint`)는 base/user 모두 `https://${CLUSTER_VIP}:6443`로 통일됩니다(01이 base에 박고, 03이 user.yaml에 그대로 복사 또는 `--endpoint`로 치환).

운영 중인 cp의 user.yaml을 사후에 수정해 `apply-config`로 반영할 때는, addresses와 cloud-init이 박는 IP가 어긋나면 인터페이스가 잠시 down될 수 있으니 patch yaml의 `addresses` 항목을 반드시 해당 노드의 정적 IP와 일치시킵니다.

### Talos 업그레이드

```bash
talosctl upgrade \
  --nodes 192.168.2.111 \
  --image ghcr.io/siderolabs/installer:v1.13.1
```

Control plane은 한 번에 한 대씩 순차 업그레이드해 etcd 쿼럼을 유지하세요.

### Kubernetes 업그레이드

```bash
talosctl upgrade-k8s --nodes 192.168.2.106 --to 1.31.0
```

### etcd 백업

```bash
mkdir -p ~/talos-backups
talosctl etcd snapshot ~/talos-backups/etcd-$(date +%Y%m%d-%H%M%S).db \
  --nodes 192.168.2.106
```

## 추가 작업 아이디어

이 환경 위에 얹기 좋은 것들입니다.

- **Cilium CNI**: kube-proxy 대체, eBPF 기반 네트워킹/관측성. 머신 컨피그에 `cluster.network.cni: { name: none }` 설정 후 Helm으로 설치.
- **Longhorn / Rook-Ceph**: 분산 블록 스토리지. 워커 노드에 별도 디스크를 추가해 사용.
- **kube-vip**: control plane HA. CP 노드들이 공유하는 VIP를 머신 컨피그로 선언.
- **Flux / ArgoCD**: GitOps. 머신 컨피그와 클러스터 manifest를 모두 Git으로 관리.
- **OpenTelemetry Collector + Elasticsearch**: 노드/k8s 메트릭과 로그 수집. 기존 관측성 스택과 연동.

## 파일 구조 요약

```
프로젝트 루트/
├── 01-gen-talos-config.sh      # 시크릿/머신컨피그 생성 (1회, 절대 재실행 금지)
├── 02-place-base-snippets.sh   # _out → snippets/에 base 배치 (멱등)
├── 03-create-talos-vm.sh       # VM 생성 (인자 기반, 노드마다 실행, cp는 VIP 자동 삽입)
└── README.md                   # 이 문서

~/talos-cluster/                # 1단계 결과물
└── _out/
    ├── controlplane.yaml
    ├── worker.yaml
    └── talosconfig             # 안전하게 보관 필수

/var/lib/vz/snippets/           # cloud-init user-data
├── _talos-cp-base.yaml         # 02가 배치하는 controlplane base 템플릿
├── _talos-wk-base.yaml         # 02가 배치하는 worker base 템플릿
├── talos-cp-01-user.yaml       # 03이 base에서 생성 (노드별, cp는 VIP 블록 포함)
├── talos-cp-02-user.yaml
├── talos-cp-03-user.yaml
├── talos-wk-01-user.yaml
└── talos-wk-02-user.yaml

/var/lib/vz/template/iso/
└── nocloud-amd64.raw           # Talos 디스크 이미지
```

## 참고 자료

- [Talos Linux 공식 문서](https://www.talos.dev/latest/)
- [Image Factory](https://factory.talos.dev/)
- [talosctl CLI 레퍼런스](https://www.talos.dev/latest/reference/cli/)
- [Proxmox VE Cloud-Init 문서](https://pve.proxmox.com/wiki/Cloud-Init_Support)