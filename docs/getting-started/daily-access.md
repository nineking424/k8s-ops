# 일상 접근 패턴

`talos-homelab`을 다루는 세 가지 진입점 — 로컬 macOS의 `kubectl`, Proxmox 호스트의 `talosctl`, Proxmox VE 측 명령(`qm`/`pvesm`). 어디서 무엇을 하는지가 정해져 있다.

## 진입점 분리

| 도구 | 어디서 실행 | 무엇에 접근 | 인증 |
|---|---|---|---|
| `kubectl` | 로컬 macOS | Kubernetes API (cp VIP `192.168.2.100:6443`) | `~/.kube/config`, context `admin@talos-homelab` |
| `talosctl` | Proxmox 호스트 (`ssh pve`) | Talos 머신 API (각 노드) | `pve:~/talos-cluster/_out/talosconfig` (Git에 절대 커밋 금지) |
| `qm` / `pvesm` | Proxmox 호스트 (`ssh pve`, root) | VM 라이프사이클, snippets, 스토리지 | Proxmox root 셸 |

요점: kubectl은 로컬, talosctl/qm은 PVE — 로컬에서 talosctl을 쓰고 싶으면 `scp pve:~/talos-cluster/_out/talosconfig ~/.talos/config` 후 `--talosconfig` 생략 가능.

## 클러스터 상태 확인

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl top nodes              # metrics-server 도입됨
```

`Ready` 노드 수가 5(cp 3 + wk 2)인지가 1차 확인선. 그 외 시스템 파드(`kube-system`, `metallb-system`, `ingress-nginx`, `monitoring`, `nfs-subdir-external-provisioner`)가 모두 Running이어야 정상.

## Proxmox 측 검증

```bash
ssh pve "qm list"                                 # VM 5대 (106-108, 111, 112)
ssh pve "ls /var/lib/vz/snippets/"                # base 2 + node-user 5 yaml
ssh pve "qm config <VMID>"                        # 특정 VM의 cloud-init / 디스크 / 네트워크
ssh pve "pvesm status"                            # 스토리지 상태 (local 디렉토리)
```

## Talos 노드 작업

```bash
# VIP 보유 cp 식별
ssh pve "for ip in 192.168.2.106 192.168.2.107 192.168.2.108; do
  echo \"-- \$ip --\"
  talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
    --endpoints \$ip --nodes \$ip get addresses 2>/dev/null \
    | grep '192.168.2.100/' || echo '(not holder)'
done"

# 노드 dashboard
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes <IP> dashboard"

# 노드 reboot (cp는 한 번에 한 대씩, etcd 쿼럼 유지)
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes <IP> reboot"

# etcd 백업
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes 192.168.2.100 \
  etcd snapshot ~/talos-backups/etcd-\$(date +%Y%m%d-%H%M%S).db"
```

자주 쓰는 절차의 권위 있는 사본은 [노드 관리 가이드](https://github.com/nineking424/k8s-ops/blob/main/node-management/node-management-guide.md). cluster endpoint(`192.168.2.100`)로 명령을 보내면 VIP 보유 cp가 받는다 — 보유자가 바뀌어도 명령이 유지됨.

## 외부 노출 호스트 매핑

`*.k8s.stjeong.com` 와일드카드는 외부 NPM이 받아 `192.168.3.10:80` (ingress-nginx LB)로 forward + edge TLS 종단. 클러스터 측만 빠르게 확인하려면 `Host:` 헤더를 박는다.

```bash
# 외부 경유 (NPM HTTPS)
curl -sI https://grafana.k8s.stjeong.com/login

# 클러스터 측만 (NPM 우회)
curl -sI -H 'Host: grafana.k8s.stjeong.com' http://192.168.3.10/login
```

두 응답 모두 `HTTP/.. 200 OK`이면 외부 → NPM → ingress-nginx → Grafana 경로가 모두 살아있는 상태. 자세한 책임 분리는 [외부 노출 모델](../concepts/external-exposure.md).

## 새 노드 추가

본 프로젝트의 스크립트를 PVE 사본으로 동기화 → PVE에서 03 호출.

```bash
# 1. 본 프로젝트에서 스크립트를 수정했다면 PVE로 동기화
scp node-management/*.sh node-management/*.md pve:k8s-ops/node-management/

# 2. PVE에서 새 노드 생성 (예: worker 추가)
ssh pve "cd ~/k8s-ops/node-management && bash 03-create-talos-vm.sh <VMID> <VM_NAME> <NODE_IP> worker"

# 3. 노드 ready 확인
kubectl get nodes -w
```

cp 추가 시는 03이 머신 컨피그에 VIP 블록(`vip.ip: 192.168.2.100`)을 자동 삽입한다 — 별도 수작업 불필요. 자세한 절차는 [노드 관리 가이드 § 배포 워크플로우](https://github.com/nineking424/k8s-ops/blob/main/node-management/node-management-guide.md#배포-워크플로우).

## 가드레일 (반복하지만 한 번 더)

- **`talosctl bootstrap`은 절대 다시 돌리지 말 것** — etcd가 깨진다.
- **`01-gen-talos-config.sh`도 절대 다시 돌리지 말 것** — 시크릿/CA가 통째로 새로 발급되어 운영 중 클러스터를 망가뜨림. endpoint 변경은 [런북 § cluster endpoint 변경](../operating/runbook.md#9-cluster-endpoint--vip-변경)으로.
- **`talosconfig`는 클러스터 전체 권한을 가진 인증 파일** — Git 커밋 금지, 1Password / Vault / 백업 디스크 등에 별도 보관.
- **`03-create-talos-vm.sh`는 동일 VMID가 있으면 자동 destroy** — 인자를 잘못 주면 운영 중 VM이 삭제된다. 호출 직전에 `qm list`로 확인.
