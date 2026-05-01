# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 저장소 개요

`k8s-ops`는 Proxmox + Talos로 구성된 홈랩 Kubernetes 클러스터(`talos-homelab`)의 **운영 및 관리**를 위한 작업 디렉토리입니다. 클러스터 매니페스트, 노드 프로비저닝 스크립트, 운영 가이드를 이곳에 모읍니다. 현재는 클러스터 부트스트랩이 막 끝난 상태(CRD/StorageClass 미설치)입니다 — 새 자원을 추가할 때 이 문서를 갱신하세요.

이 디렉토리는 git 루트가 아닙니다. **git 루트는 상위 디렉토리 `/Users/nineking/workspace/k8s/`** 이고, 그곳에 과거에 다른 클러스터용으로 작업했던 컴포넌트별 디렉토리(`prometheus/`, `cert-manager/`, `ingress-nginx/`, `metallb/`, `minio/`, `elastic/`, `nifi/` 등)와 배포 가이드(`talos-dist/`, `elastic-dist/` 등)가 함께 들어 있습니다. 이들은 현재 클러스터에 적용된 상태가 아니므로, 재사용할 때는 매니페스트/values를 현재 클러스터 기준으로 검증한 뒤 적용해야 합니다.

## 디렉토리 구조

본 프로젝트는 **노드 관리**(`node-management/`)와 **클러스터 컴포넌트**(`<component>/`)를 평면적으로 나란히 두는 구조입니다. 새로 도입하는 컴포넌트는 각자 폴더를 가지며, 폴더 안 컨벤션은 [클러스터 컴포넌트 추가](#클러스터-컴포넌트-추가) 섹션 참조.

- **`node-management/`** — Talos 노드 프로비저닝/관리 스크립트와 가이드. `01-gen-talos-config.sh`(클러스터 시크릿/CA + 머신컨피그 발급, 절대 재실행 금지), `02-place-base-snippets.sh`(`_out/` → snippets/에 base 배치, 멱등), `03-create-talos-vm.sh`(노드별 VM 생성, cp는 VIP 자동 삽입), `node-management-guide.md`(부트스트랩·노드 추가·업그레이드·etcd 백업·트러블슈팅 종합 가이드). 자세한 내용은 [노드 관리](#노드-관리-node-management) 섹션 참고.
- **`<component>/` (예정)** — 클러스터 레벨 컴포넌트별 폴더. 도입 우선순위는 [권장 도입 순서](#권장-도입-순서) 섹션 참조 (StorageClass / LoadBalancer / Ingress / cert-manager / metric-server / 관측성 등).

## 인프라 토폴로지

- **Proxmox 호스트**: `ssh pve` (192.168.1.3, root) — 단일 호스트, 모든 Talos VM이 여기서 동작
  - `pve-mini` (192.168.1.5), `pve-main` (192.168.1.6)도 ssh config에 있으나 현재 클러스터와 무관
- **Talos 클러스터**: `talos-homelab` (Talos v1.13.0 / Kubernetes v1.36.0 / containerd 2.2.3 / Flannel CNI)
  - Control plane: `talos-cp-01` (192.168.2.106, VMID 106), `talos-cp-02` (192.168.2.107, VMID 107), `talos-cp-03` (192.168.2.108, VMID 108)
  - **Cluster endpoint (VIP): `192.168.2.100`** — Talos native VIP (`machine.network.interfaces[].vip`), cp 한 대가 etcd leader election으로 보유, 장애 시 자동 fail-over. kubectl/talosctl 모두 이 IP로 접근.
  - Worker: `talos-wk-01` (192.168.2.111, VMID 111), `talos-wk-02` (192.168.2.112, VMID 112)
  - 네트워크: `192.168.0.0/16` 단일 서브넷, GW `192.168.1.1`, 노드는 `/16` 마스크 (`/24` 아님 — 라우터 DHCP 풀과 일치)
- **kubectl context**: `admin@talos-homelab` (현재 활성)
- **TALOSCONFIG**: 부트스트랩을 수행한 호스트(`pve`)의 `~/talos-cluster/_out/talosconfig`. 로컬에서 `talosctl`을 쓰려면 그곳에서 가져와 `export TALOSCONFIG=...` 후 사용. 같은 디렉토리에 `controlplane.yaml`, `worker.yaml`(machine config 시드)도 함께 존재.
- **Snippets 디렉토리**: `pve:/var/lib/vz/snippets/`
  - `_talos-cp-base.yaml`, `_talos-wk-base.yaml` — 02가 배치한 역할별 base 템플릿
  - `talos-cp-0{1,2,3}-user.yaml`, `talos-wk-0{1,2}-user.yaml` — 03이 base에서 만든 노드별 cloud-init user-data (cp는 VIP 블록 포함)
  - cloud-init은 최초 부팅에만 동작하므로, 운영 중 노드의 컨피그를 바꾸려면 해당 user.yaml을 수정 → `talosctl apply-config`로 직접 반영

## 노드 관리 (`node-management/`)

이 클러스터는 `node-management/`의 세 스크립트(`01` → `02` → `03`)로 부트스트랩되었습니다. 자세한 절차·트러블슈팅은 `node-management/node-management-guide.md`에 정리되어 있고, 운영 시 **먼저 그쪽을 읽고** 여기 CLAUDE.md는 빠른 참조용으로 활용.

스크립트는 **Proxmox 호스트에서 `root`로 실행**되는 것을 전제로 작성되어 있어, 로컬 macOS에서는 직접 돌릴 수 없습니다. 본 사본은 작업/검토용이고, 실제 실행은 PVE에 같은 파일을 둔 채 거기서 호출합니다.

부트스트랩 시점에 박힌 핵심 변수(현재 클러스터를 그대로 다루는 한 변경 금지):

- `01-gen-talos-config.sh`: `CLUSTER_NAME=talos-homelab`, `CLUSTER_VIP=192.168.2.100` (cluster endpoint, cp의 `vip.ip`와 동일), `TALOS_VERSION=v1.13.0`. **재실행은 절대 금지** — 인증서/시크릿이 통째로 새로 발급됨.
- `02-place-base-snippets.sh`: `STORAGE=local`, `SNIPPETS_DIR=/var/lib/vz/snippets`. 멱등 — `_out/`이 갱신되면 재호출 안전.
- `03-create-talos-vm.sh`: `SCHEMATIC_ID=ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515` (Image Factory, `siderolabs/qemu-guest-agent` 포함), `NODE_CIDR=16`, `GATEWAY=192.168.1.1`, `CP_VIP=192.168.2.100` (cp 역할 노드의 user.yaml에 자동 삽입할 VIP — 01의 `CLUSTER_VIP`와 동일하게 유지).

### 사본 위치 / 동기화

- **`node-management/` (본 프로젝트)** — 작업/리뷰의 권위 있는 사본. 변경은 여기서 시작.
- **`pve:~/k8s-ops/node-management/`** — PVE에서 실제로 실행되는 사본. 본 프로젝트의 스크립트를 수정한 뒤에는 반드시 동기화:
  ```bash
  scp node-management/*.sh node-management/*.md pve:k8s-ops/node-management/
  ```
  스크립트가 rename된 직후에는 옛 파일이 PVE에 남아 있으므로 `ssh pve "rm -f k8s-ops/node-management/<old>.sh"`로 먼저 정리하세요.

> 부트스트랩에 사용했던 별도 저장소(`nineking424/talos-dist`)는 본 프로젝트로 흡수 후 GitHub 측 archive 처리 + 로컬/PVE 사본 모두 삭제 완료. 이제 노드 관련 권위 있는 코드는 위 두 사본뿐입니다.

## 클러스터 컴포넌트 추가

클러스터 레벨 워크로드(Ingress, LoadBalancer, StorageClass, metric-server, NFS provisioner, cert-manager 등)는 본 프로젝트에 **컴포넌트별 폴더**로 추가합니다. 일관된 구조를 유지해야 미래의 자기 자신이 다른 컴포넌트를 다룰 때도 빠르게 컨텍스트 복원이 됩니다.

### 폴더 컨벤션

```
<component>/
├── README.md           # 무엇을 / 왜 / 의존성 / 적용 후 검증 방법
├── install.sh          # helm upgrade --install 또는 kubectl apply 한 번으로 끝나는 진입점
├── values.template.yaml # (Helm) 시크릿 placeholder만 있는 Git 추적 템플릿
├── values.yaml         # (Helm) 실제 값. 시크릿이 들어가면 .gitignore
└── *.yaml              # 추가 매니페스트 (Issuer, IPAddressPool, StorageClass 등)
```

폴더 이름은 **Helm chart 이름 또는 일반 통용 명**을 따릅니다(`ingress-nginx`, `metallb`, `cert-manager`, `metrics-server`, `nfs-subdir-external-provisioner`, `kube-vip`). 상위 워크스페이스의 동명 디렉토리(`../prometheus/`, `../ingress-nginx/` 등)와 이름이 겹쳐도 본 프로젝트 안이라 충돌은 없지만, **상위 사본은 과거 클러스터용**이므로 그대로 복사하지 말고 현재 클러스터 기준으로 검증한 뒤 옮기세요.

### Helm vs raw manifest

- **Helm 사용**(권장): `install.sh` 안에서 `helm repo add ...` → `helm upgrade --install <release> <chart> -n <ns> --create-namespace -f values.yaml`. 업그레이드/롤백/diff가 표준화됨. 차트 버전은 `install.sh` 상단에 변수로 박아두기.
- **Raw manifest**: 컴포넌트가 작거나 차트가 없을 때만. `kubectl apply -f` 진입점을 `install.sh`에 두기. CRD가 있으면 적용 순서를 명시.

### 시크릿 처리

기본 원칙: `values.yaml`은 시크릿(토큰/비번/인증서)이 포함되면 **로컬 전용**으로 두고 Git에 안 올림. 대신 `values.template.yaml`을 placeholder(`<DOCKERHUB_TOKEN>`, `<CLOUDFLARE_API_TOKEN>` 등)로 채워 커밋. `install.sh` 상단에서 두 파일이 어긋날 때 경고.

더 정교한 흐름이 필요해지면(여러 사람이 만지거나 GitOps 도입) **sealed-secrets / external-secrets / SOPS** 중 하나로 일원화. 현재는 단일 운영자 환경이라 template/values 분리만으로 충분.

### 설치 후 체크리스트

`<component>/README.md`의 끝부분에 항상 적어둘 것:

- [ ] `kubectl get pods -n <ns>` — 모두 Running
- [ ] 컴포넌트 고유 검증 (예: ingress면 test ingress 배포 후 curl, metric-server면 `kubectl top nodes`)
- [ ] 의존하는 다른 컴포넌트가 정상 동작하는지 (예: ingress 추가 후 cert-manager가 새 Certificate를 issue하는지)

### CRD / 네임스페이스 / 충돌

- CRD가 있는 차트(cert-manager, prometheus-operator 등)는 **언인스톨 시 CRD가 자동 삭제되지 않을 수 있음**. 의도치 않게 다른 컴포넌트의 CR이 사라지지 않도록 `helm uninstall` 전에 의존 CR 목록을 확인.
- 같은 namespace를 여러 컴포넌트가 공유하지 않도록 컴포넌트당 자체 namespace를 권장(`ingress-nginx`, `cert-manager`, `metallb-system`, `kube-system`은 코어용).
- ClusterRole/ClusterRoleBinding/Webhook 같은 클러스터 스코프 자원은 이름이 겹치면 다른 컴포넌트가 깨질 수 있으니, 차트 기본값을 그대로 쓰고 임의 변경 자제.

### GitOps 도입 (현재 안 함)

지금은 수동 `helm/kubectl` 흐름이고, 변경은 git 커밋으로 추적. 컴포넌트가 5~6개 넘어가면 **ArgoCD** 또는 **Flux** 도입을 고려 — 그 시점에 폴더 구조가 그대로 `Application` / `Kustomization` 매니페스트로 매핑되도록 위 컨벤션을 잡아두었습니다.

## 일상 접근 패턴

```bash
# 클러스터 상태 (로컬 macOS에서)
kubectl get nodes -o wide
kubectl get pods -A

# Proxmox 측 검증 (VM 상태, 스닙셋 등)
ssh pve "qm list"
ssh pve "ls /var/lib/vz/snippets/"
ssh pve "qm config <VMID>"

# Talos 노드 작업 (Proxmox 호스트에서, TALOSCONFIG가 ~/talos-cluster/_out/talosconfig에 있음)
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes <IP> dashboard"
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes <IP> reboot"

# 새 노드 추가 (예: worker 추가)
# 스크립트를 본 프로젝트에서 수정했다면 먼저 PVE로 동기화: scp node-management/*.sh pve:k8s-ops/node-management/
ssh pve "cd ~/k8s-ops/node-management && bash 03-create-talos-vm.sh <VMID> <VM_NAME> <NODE_IP> worker"
# 그 후 노드 ready 확인: kubectl get nodes -w

# Talos OS 업그레이드 (CP는 한 번에 한 대씩, etcd 쿼럼 유지)
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig upgrade --nodes <IP> --image ghcr.io/siderolabs/installer:<version>"

# Kubernetes 업그레이드
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig upgrade-k8s --nodes <CP_IP> --to <k8s-version>"

# etcd 백업 (정기적으로)
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes 192.168.2.100 etcd snapshot ~/talos-backups/etcd-\$(date +%Y%m%d-%H%M%S).db"
```

스크립트 실행이나 snippets 검증이 필요할 때는 `ssh pve "<command>"` 형태로 원격 호출. 파일 전송은 `scp` 또는 `rsync`. 로컬에서 `talosctl`을 직접 쓰려면 `scp pve:~/talos-cluster/_out/talosconfig ~/.talos/config` 후 `--talosconfig` 생략 가능.

## 관련 디렉토리 (상위 git 루트)

- **`../prometheus/`, `../grafana/`, `../cert-manager/`, `../ingress-nginx/`, `../metallb/`, `../minio/`, `../nfs-provisioner/`, ...** — 과거 클러스터에서 사용한 매니페스트/values. **현재 클러스터에는 미적용**이고, 챠트/CRD 버전이 달라졌을 가능성이 높습니다. 본 프로젝트로 옮길 때는 그대로 복사하지 말고 [클러스터 컴포넌트 추가](#클러스터-컴포넌트-추가) 컨벤션으로 재구성하면서 values를 다시 검증.
- **`../*-dist/`** (`elastic-dist`, `kafka-dist`, `nifi-dist`, `oracle-12c-ee-dist`, `zookeeper-dist`) — 컴포넌트별 배포 가이드/스크립트 모음. 워크로드(애플리케이션) 성격이라 본 프로젝트(클러스터 운영)와 분리해 둠 — 옮기지 않음.

## 위험한 작업 / 가드레일

- **`talosctl bootstrap`은 이미 완료**된 상태입니다. 절대 다시 실행하지 마세요. etcd가 깨지고 복구가 매우 어렵습니다.
- **`talosconfig`는 클러스터 전체 권한**을 가진 인증 파일입니다. Git에 커밋 금지, 1Password / Vault / 백업 디스크 등에 별도 보관.
- **머신 컨피그 변경**: cloud-init은 최초 부팅 때만 동작합니다. 운영 중 노드의 컨피그를 바꾸려면 snippets의 `<VM_NAME>-user.yaml`을 수정한 뒤 `talosctl apply-config --nodes <IP> --file <path>`로 직접 반영. 자세한 절차는 `node-management/node-management-guide.md` 참고.
- **`01-gen-talos-config.sh`를 다시 돌리지 말 것**: 인증서/시크릿이 통째로 새로 발급되어 운영 중인 클러스터를 망가뜨립니다. endpoint 변경 등은 `talosctl get/apply-config`로 처리.
- **`03-create-talos-vm.sh`는 동일 VMID가 있으면 자동 destroy**합니다. 인자를 잘못 주면 운영 중 VM이 삭제됩니다.
- **Control plane 업그레이드**는 한 번에 한 대씩, etcd 쿼럼을 유지하면서 순차 진행.

## 권장 도입 순서

부트스트랩 직후 상태(CRD/StorageClass 미설치)라 클러스터 레벨 자원이 모두 비어 있습니다. 운영자 결정에 따라 아래 순서로 도입합니다.

| 순서 | 컴포넌트 | 구현 / 핵심 설정 | 의존 / 근거 |
|---|---|---|---|
| 1 ✓ | **metrics-server** | `metrics-server` chart. Talos는 kubelet serving cert를 자체 발급하므로 `--kubelet-insecure-tls` 또는 kubelet 인증서 신뢰 설정 필요 — 도입 시 확인. | 가장 가벼운 시작점(PV / LB / Ingress 의존 없음). `kubectl top`, HPA의 전제. **(✓ 도입 완료 — `metrics-server/`)** |
| 2 ✓ | **Control Plane HA (VIP)** | **Talos native VIP** (`machine.network.interfaces[].vip`, **VIP `192.168.2.100`**). 추가 컴포넌트 없이 etcd 기반 leader election 내장 — cp 한 대가 VIP를 보유, 장애 시 자동 fail-over. cp 3대의 머신 컨피그에 patch 적용 + 모든 노드의 cluster endpoint를 `192.168.2.106` → `192.168.2.100`로 컷오버 완료. | 첫 CP(106)가 죽으면 kubectl/talosctl 모두 끊기는 SPOF 해소. **(✓ 도입 완료 — VIP 운영 메모는 `node-management/node-management-guide.md`)** |
| 3 | **StorageClass / NFS** | `nfs-subdir-external-provisioner` chart. 백엔드는 NAS `nknas` (192.168.1.4). NFS export 경로는 NAS에서 미리 생성/허용 IP 설정. | 이후 단계(특히 관측성)와 stateful 워크로드의 전제. |
| 4 | **LoadBalancer** | `MetalLB` (L2 모드). IP 풀: **`192.168.3.0/24` 전체**. 노드 대역 `192.168.2.x` 및 VIP `192.168.2.100`과 분리됨. 라우터 DHCP 풀이 `192.168.3.x`를 분배하지 않는지 사전 확인. | 홈랩이라 클라우드 LB 없음. Ingress controller가 `Service type=LoadBalancer`를 받으려면 필요. |
| 5 | **Ingress** | `ingress-nginx`. Service type=LoadBalancer로 MetalLB가 IP 할당. | 외부 진입점. HTTP만 우선 운영하다가 필요 시 cert-manager를 추가해 HTTPS로. |
| 6 | **관측성 스택** | `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager), Loki/Promtail | PV 필요(3번), 외부 노출 시 Ingress(5번). 가장 무거운 단계 — 리소스 여유 확보 후. |

각 컴포넌트는 본 프로젝트에 `<component>/` 폴더로 추가 — [클러스터 컴포넌트 추가](#클러스터-컴포넌트-추가) 컨벤션을 따릅니다. 도입할 때 이 표의 해당 행을 그 폴더의 `README.md`에 옮기고 본 표는 "✓ 도입 완료" 표시로 갱신.

### 향후 도입 고려 항목 (필수 아님)

지금 단계에서 필수는 아니지만 클러스터 사용 패턴이 늘어나면 자연스럽게 도입되는 항목들:

- **cert-manager** — TLS 자동화 (Let's Encrypt 등 ACME). HTTPS로 외부에 노출할 서비스가 생기면 도입. ACME HTTP-01은 Ingress(5번) 의존, DNS-01은 DNS 프로바이더 API 토큰 필요. 도입 전엔 자체 서명 인증서나 HTTP만으로 운영.
- **GitOps (ArgoCD / Flux)** — 컴포넌트 5~6개 넘어가서 수동 `helm/kubectl` 흐름이 부담스러워지면. [클러스터 컴포넌트 추가](#클러스터-컴포넌트-추가) 컨벤션이 그대로 매핑되도록 폴더 구조를 잡아두었음.
- **백업 (Velero)** — etcd 외에 PV 데이터까지 백업이 필요해지면. 현재는 NAS의 NFS export 자체를 NAS 레벨에서 백업하는 것으로 갈음 가능.
- **Sealed-Secrets / External-Secrets / SOPS** — 시크릿 관리가 `values.yaml` 로컬 분리 수준을 넘어서거나 GitOps 도입과 함께.
