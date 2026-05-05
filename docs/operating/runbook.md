# 런북

사고 대응 절차 모음. 번호 매겨진 §1–§10이 [트러블슈팅](troubleshooting.md)에서 점프하는 anchor 역할을 한다. 각 시나리오는 Steps + Verification 두 절을 모두 가진다.

## 1. etcd 쿼럼 손실 진단

cp 2대 이상이 죽거나 unreachable 상태이거나, kubectl이 30초 넘게 끊기고 VIP fail-over로도 복구되지 않을 때.

### Steps

1. cp 3대의 도달성 확인:
   ```bash
   for ip in 192.168.2.106 192.168.2.107 192.168.2.108; do
     ping -c 1 -W 1 $ip >/dev/null && echo "$ip up" || echo "$ip DOWN"
   done
   ```
2. 살아 있는 cp에서 etcd 멤버 상태 확인:
   ```bash
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes <SURVIVING_CP_IP> etcd members"
   ```
3. 1대만 죽은 경우(쿼럼 유지): 죽은 노드를 reboot 시도 — Proxmox에서 `qm start <VMID>`. 자동 복구되지 않으면 §3으로 노드 교체.
4. 2대 이상 죽은 경우(쿼럼 깨짐): etcd 단일 노드 복구가 필요. 살아 있는 cp 한 대에서:
   ```bash
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes <SURVIVING_CP_IP> etcd recover --from <BACKUP_PATH>"
   ```
   `<BACKUP_PATH>`는 `~/talos-backups/etcd-*.db`에서 가장 최근 스냅샷.
5. recover 후 다른 cp들은 폐기 → §3 절차로 새 cp로 다시 join.

### Verification

- `kubectl get nodes`가 정상 응답하고 모든 노드가 `Ready`.
- `talosctl --nodes <CP_IP> etcd members`가 cp 3대를 모두 보여줌(`STATE: STARTED`).
- `talosctl health`가 `etcd: HEALTHY`.

> **etcd recover는 마지막 수단** — 백업 시점 이후의 클러스터 변경은 모두 잃는다. 정기 백업이 없다면 recover 실행 전에 [§6 etcd 백업/복구](#6-etcd-백업복구)부터.

## 2. cp VIP fail-over 검증

VIP 보유 cp의 reboot/장애 시 다른 cp가 VIP를 즉시 이어받는지 확인. 새벽이 아니라 정기 점검 때 돌리는 절차다.

### Steps

1. 현재 VIP 보유 cp 식별:
   ```bash
   ssh pve "for ip in 192.168.2.106 192.168.2.107 192.168.2.108; do
     echo \"-- \$ip --\"
     talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
       --endpoints \$ip --nodes \$ip get addresses 2>/dev/null \
       | grep '192.168.2.100/' || echo '(not holder)'
   done"
   ```
2. 다른 터미널에서 `kubectl` watch 켜둠:
   ```bash
   kubectl get nodes -w
   ```
3. VIP 보유자 reboot:
   ```bash
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes <VIP_HOLDER_IP> reboot"
   ```
4. 몇 초 안에 다른 cp가 VIP를 보유. `kubectl get nodes -w`는 끊기지 않거나 한 번 깜빡인 뒤 복구되어야 한다.

### Verification

- 1번 명령을 다시 돌려 새로운 cp가 VIP 보유자임을 확인.
- `curl -sI -k https://192.168.2.100:6443/livez`가 `200`.
- reboot된 cp가 다시 올라온 후 `kubectl get nodes`에서 `Ready`로 돌아옴(약 1~2분).

## 3. 노드 추가 / 제거

worker 또는 cp를 추가/제거하는 표준 절차. 부트스트랩 후 클러스터 운영 중에 사용.

### Steps (추가)

1. 본 프로젝트의 03 스크립트를 PVE 사본과 동기화:
   ```bash
   scp node-management/*.sh node-management/*.md pve:k8s-ops/node-management/
   ```
2. PVE에서 03 호출 (worker 추가 예):
   ```bash
   ssh pve "cd ~/k8s-ops/node-management && bash 03-create-talos-vm.sh \
     <VMID> <VM_NAME> <NODE_IP> worker"
   ```
   cp 추가는 `worker` 자리를 `cp`로 — 03이 자동으로 VIP 블록을 user.yaml에 박는다.
3. 노드 ready 대기:
   ```bash
   kubectl get nodes -w
   ```

### Steps (제거)

1. 워크로드 drain:
   ```bash
   kubectl drain <NODE_NAME> --ignore-daemonsets --delete-emptydir-data
   ```
2. 클러스터에서 멤버 제거 (cp인 경우 etcd member 제거 먼저):
   ```bash
   # cp 제거 시
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes <ANOTHER_CP_IP> etcd remove-member <NODE_NAME>"
   kubectl delete node <NODE_NAME>
   ```
3. Proxmox VM 정리:
   ```bash
   ssh pve "qm stop <VMID> --skiplock 1 && qm destroy <VMID> --purge 1"
   ```
4. snippets 정리:
   ```bash
   ssh pve "rm /var/lib/vz/snippets/<VM_NAME>-user.yaml"
   ```

### Verification

- `kubectl get nodes`가 추가/제거 결과를 반영.
- cp 추가 시: `talosctl --nodes <NEW_CP_IP> etcd members`가 새 멤버를 `STARTED`로 보여줌.
- cp 제거 시: `etcd members` 목록에서 사라지고 `kubectl get nodes`에도 없음.

## 4. Talos OS 업그레이드

cp는 한 번에 한 대씩, etcd 쿼럼을 유지하며 순차 진행.

### Steps

1. 백업 먼저 — [§6 etcd 백업/복구](#6-etcd-백업복구).
2. worker부터 업그레이드:
   ```bash
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes 192.168.2.111 \
     upgrade --image ghcr.io/siderolabs/installer:<NEW_VERSION>"
   ```
3. 노드가 자동 재부팅되며 `Ready`로 돌아오는지 확인 후 다음 worker.
4. cp는 가장 마지막에, **VIP 미보유자부터** 한 대씩.
5. VIP 보유 cp는 마지막에 — fail-over 후 업그레이드.

### Verification

- 각 노드 업그레이드 후 `kubectl get nodes`에서 해당 노드가 `Ready`.
- `talosctl version --nodes <IP>`가 새 버전을 출력.
- `talosctl health`가 모든 노드에서 `HEALTHY`.

> 03 스크립트의 `SCHEMATIC_ID`가 박혀 있는 이미지와 일치하는지 확인. 업그레이드 이미지가 다른 schematic을 쓰면 OS 익스텐션(qemu-guest-agent 등)이 빠진다.

## 5. Kubernetes 업그레이드

Talos가 K8s 컴포넌트를 묶어서 다룬다. cp 한 대에서 명령을 보내면 전체 노드가 순차 업그레이드.

### Steps

1. 가능한 업그레이드 경로 확인:
   ```bash
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes 192.168.2.106 upgrade-k8s --to <NEW_VERSION> --dry-run"
   ```
2. 적용:
   ```bash
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes 192.168.2.106 upgrade-k8s --to <NEW_VERSION>"
   ```
3. 진행 상황은 `kubectl get nodes -o wide` watch — `VERSION` 컬럼이 노드별로 갱신됨.

### Verification

- 모든 노드의 `VERSION`이 `<NEW_VERSION>`.
- `kubectl get pods -n kube-system`에서 control plane pod이 모두 Running.
- `kubectl version --short`가 새 버전.

## 6. etcd 백업 / 복구

정기적으로 돌려야 하는 백업과, §1에서 호출되는 복구 절차.

### Steps (백업)

```bash
ssh pve "mkdir -p ~/talos-backups && \
  talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
    --nodes 192.168.2.100 \
    etcd snapshot ~/talos-backups/etcd-\$(date +%Y%m%d-%H%M%S).db"
```

cluster endpoint(`192.168.2.100`)로 보내면 VIP 보유자가 응답한다. 백업은 어느 cp에서 떠도 동일 — 모든 cp가 같은 etcd raft log를 가진다.

권장 주기: 일 1회. NAS의 별도 디렉토리로 함께 복제하면 호스트 장애 대비.

### Steps (복구)

복구는 etcd 쿼럼이 깨진 §1 시나리오에서만. 살아 있는 cp 한 대에 백업 파일을 올린 뒤:

```bash
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
  --nodes <SURVIVING_CP_IP> \
  etcd recover --from ~/talos-backups/<BACKUP_FILE>.db"
```

복구 후 그 cp 한 대로 클러스터를 일으킨 뒤, 다른 cp는 §3 절차로 새로 join.

### Verification

- 백업 파일이 정상 크기(보통 수 MB ~ 수십 MB)로 생성.
- 복구 후 `talosctl --nodes <CP_IP> etcd members`가 단일 멤버를 `STARTED`로 보여줌.
- `kubectl get nodes`가 응답.

## 7. NFS 마운트 장애

NAS 측 장애나 권한 문제로 PVC가 마운트 실패할 때.

### Steps

1. provisioner pod 로그 확인:
   ```bash
   kubectl logs -n nfs-subdir-external-provisioner \
     -l app=nfs-subdir-external-provisioner --tail=100
   ```
2. 노드에서 NAS 도달성:
   ```bash
   ssh pve "ping -c 3 192.168.1.4"
   ```
3. NAS export 권한 확인 — NAS 관리도구에서 `*` 또는 `192.168.0.0/16`이 허용되어 있는지.
4. 마운트 옵션 호환성 — `values.yaml`의 `nfs.mountOptions`가 NAS의 NFS 버전과 일치하는지(현재 `nfsvers=3,nolock`).

### Verification

- 시험 PVC가 30초 안에 Bound:
  ```bash
  kubectl apply -f - <<'YAML'
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata: { name: nfs-test, namespace: default }
  spec:
    accessModes: [ReadWriteOnce]
    resources: { requests: { storage: 1Gi } }
  YAML
  kubectl get pvc nfs-test -w
  kubectl delete pvc nfs-test
  ```
- NAS 측에서 `/volume1/nfsvolume/` 하위에 시험 디렉토리 생성/삭제 보임.

## 8. 외부 NPM 다운

`https://*.k8s.stjeong.com` 외부 진입이 안 되지만 클러스터 안 동작은 정상일 때.

### Steps

1. 클러스터 측 분리 검증 — NPM 우회로 ingress-nginx가 정상인지:
   ```bash
   curl -sI -H 'Host: grafana.k8s.stjeong.com' http://192.168.3.10/login
   ```
   `200 OK`이면 클러스터는 정상 — 끊김은 NPM 측.
2. NPM 호스트 접속 / 프로세스 상태 점검 (NPM 호스트는 본 프로젝트 외부).
3. NPM이 살아 있다면 와일드카드 host 매핑 (`*.k8s.stjeong.com → 192.168.3.10:80`)이 그대로인지 확인.
4. NPM이 죽었다면 NPM 호스트에서 직접 복구 — 본 프로젝트 범위 밖.

### Verification

- `curl -sI https://grafana.k8s.stjeong.com/login`이 `200` + 정상 cert chain.
- 다른 외부 호스트(`<svc>.k8s.stjeong.com`)도 정상 응답.

## 9. cluster endpoint / VIP 변경

cp VIP를 다른 IP로 옮기거나 외부 LB로 바꾸고 싶을 때. **부트스트랩 후 변경은 위험** — 절차를 정확히 따른다.

### Steps

1. **부트스트랩 전이라면**: `01-gen-talos-config.sh`의 `CLUSTER_VIP`를 새 값으로 바꾸고 01 → 02를 다시 돌리고, 기존 노드별 user.yaml 삭제 후 03 재호출. 자세한 흐름은 [노드 관리 가이드 § 머신 컨피그 endpoint와 노드 IP 불일치](../../node-management/node-management-guide.md#머신-컨피그-endpoint와-노드-ip-불일치).
2. **부트스트랩 후라면**: `01-gen-talos-config.sh` 절대 다시 돌리지 말 것. talosctl로 직접 머신 컨피그를 수정.
   ```bash
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes 192.168.2.106 get machineconfig -o yaml > /tmp/cp.yaml"
   # /tmp/cp.yaml의 cluster.controlPlane.endpoint를 새 값으로 편집
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes 192.168.2.106 apply-config --file /tmp/cp.yaml"
   ```
3. 모든 cp에 같은 변경 적용.
4. `talosctl` 클라이언트의 endpoint도 갱신:
   ```bash
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     config endpoint <NEW_VIP>"
   ```
5. `~/.kube/config`의 server URL도 새 endpoint로 갱신.

### Verification

- `talosctl --nodes <NEW_VIP> version`이 응답.
- `kubectl get nodes`가 정상.
- 노드 머신 컨피그에서 `cluster.controlPlane.endpoint`가 새 값.

## 10. kubectl / talosctl 명령 모음

자주 쓰는 진단/조작 명령을 한곳에 — 트러블슈팅에서 점프.

```bash
# 클러스터 전체
kubectl get nodes -o wide
kubectl get pods -A
kubectl top nodes
kubectl get events -A --sort-by=.lastTimestamp | tail -50

# 특정 namespace
kubectl get all -n <ns>
kubectl describe pod -n <ns> <pod>
kubectl logs -n <ns> -l <selector> --tail=100 -f

# Talos 노드
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes <IP> dashboard"
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes <IP> services"
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes <IP> logs <service>"
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes <IP> health"
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig --nodes <IP> reboot"

# Proxmox
ssh pve "qm list"
ssh pve "qm config <VMID>"
ssh pve "qm start <VMID>"
ssh pve "qm stop <VMID> --skiplock 1"

# Ingress / LB 검증
curl -sI -H 'Host: <svc>.k8s.stjeong.com' http://192.168.3.10/<path>
curl -sI https://<svc>.k8s.stjeong.com/<path>
```
