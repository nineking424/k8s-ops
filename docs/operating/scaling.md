# 스케일링

용량을 늘리고 줄이는 두 축은 **노드 추가**(Talos VM)와 **워크로드 replicaCount** 다. 어느 쪽을 어떻게 움직일지 결정하는 기준을 정리한다.

## 기본: worker 1대 추가

가장 흔한 시나리오. PVE 호스트에 여유가 있고 클러스터 전체 CPU/Memory가 부족할 때.

```bash
# 본 프로젝트의 03 스크립트를 PVE 사본과 동기화
scp node-management/*.sh node-management/*.md pve:k8s-ops/node-management/

# 새 worker 생성 (예: VMID 113, IP 192.168.2.113)
ssh pve "cd ~/k8s-ops/node-management && bash 03-create-talos-vm.sh \
  113 talos-wk-03 192.168.2.113 worker"
```

확인 절차:

1. `kubectl get nodes -w` — 새 노드가 `NotReady` → `Ready`로 전이(약 1~2분).
2. `kubectl top nodes` — 새 노드의 메트릭이 보이기까지 추가 30~60초.
3. ingress-nginx의 anti-affinity는 wk-01/wk-02에 박혀 있어 wk-03이 자동 합류하지 않는다 — 워크로드별로 토폴로지를 본다.

자세한 절차 / cp 추가는 [런북 §3](runbook.md#3-노드-추가--제거).

## 노드 추가 vs replicaCount 트레이드오프

같은 처리량 N을 만드는 두 방법.

| 방식 | 예시 | 장점 | 단점 |
|---|---|---|---|
| **노드 추가** | 4번째 worker(`talos-wk-03`) | 새 CPU/Memory를 클러스터에 통째로 추가, 단일 노드 OOM 위험 분산 | Proxmox 호스트 물리 자원 한계, 노드 OS 부하 증가 |
| **replicaCount 늘림** | `kube-prometheus-stack` Grafana replicas=3 | 즉시 적용, 기존 노드 자원 활용 | 한 노드에 다 몰리면 anti-affinity 없을 때 단일 장애로 다 죽음 |

권장 출발점:

- **워크로드의 단일 인스턴스 latency가 충분한 경우(수평 확장 가능)**: replicaCount를 먼저 — 이미 ingress-nginx가 2이고 PV가 RWX 가능한 NFS이므로 추가 replica를 NFS PVC에 묶을 수 있음.
- **클러스터 전체 자원이 부족한 경우(`kubectl top nodes`에서 80%+ 사용 중)**: 노드 추가 — replicaCount만 늘리면 같은 자원을 더 잘게 쪼갤 뿐.
- **단일 인스턴스 latency가 문제(예: Prometheus 단일 query가 느림)**: replicaCount로 못 풀고 노드 추가 + 리소스 request/limit 상향이 답.

## 컴포넌트별 스케일 한계

| 컴포넌트 | 현재 | 한계 | 비고 |
|---|---|---|---|
| ingress-nginx | replicas=2 (anti-affinity wk-01/wk-02) | wk 노드 수 | wk가 3+이면 replicas=3으로 anti-affinity 유지 가능. `replicas > wk 노드 수`면 같은 노드에 둘 이상 몰림 |
| kube-prometheus-stack Prometheus | StatefulSet replicas=1 | 차트 단일 본 단계 | HA Prometheus는 차트의 `prometheusSpec.replicas` + Thanos 도입이 필요 — 본 단계에서는 수평 확장 안 함 |
| kube-prometheus-stack Grafana | Deployment replicas=1 | NFS PVC RWO | RWX로 PVC를 만들면 replicas 증가 가능, 현재는 default `ReadWriteOnce` |
| metallb-controller | Deployment replicas=1 | 차트 기본값 | controller는 leader election + state 없음 — 죽어도 speaker는 계속 announce |
| metallb-speaker | DaemonSet (모든 노드) | 노드 수에 자동 추적 | 새 노드 추가 시 자동 합류 |
| nfs-subdir-external-provisioner | Deployment replicas=1 | 차트 기본값 | provisioner는 PV 생성 시점에만 호출 — 일시 다운돼도 기존 PV는 영향 없음 |
| metrics-server | replicas=1 | 차트 기본값 | 잠깐 끊겨도 `kubectl top` / HPA만 영향 — 운영에 큰 부담 없음 |

## 노드 리소스 한계

각 노드의 기본 리소스(`03-create-talos-vm.sh`의 역할별 분기):

| Role | Memory | Cores | Disk |
|---|---|---|---|
| cp | 4096 MiB | 2 | 32 GB |
| worker | 4096 MiB | 4 | 64 GB |

호출 시 옵션으로 덮어쓸 수 있다 (`--cpu`, `--memory`, `--disk`). PVE 호스트의 물리 자원 안에서만 변경.

```bash
# 예: worker에 더 큰 자원 할당
bash 03-create-talos-vm.sh --cpu 8 --memory 16384 --disk 128G \
  113 talos-wk-03 192.168.2.113 worker
```

기존 노드의 리소스를 늘리려면 PVE에서 `qm set <VMID> --cores N --memory N`으로 변경 후 노드 reboot. Talos는 자원 변경에 특별한 절차 없음.

## 스케일 다운

worker 제거: [런북 §3 노드 추가/제거](runbook.md#3-노드-추가--제거)의 제거 절차. cp 제거는 etcd 쿼럼 유지 가능 여부를 먼저 확인 — 3대에서 1대 빼면 2대(쿼럼 유지), 1대에서 더 빼면 안 됨.

워크로드 replicaCount 줄이기: helm `values.yaml`에서 `replicas`를 줄이고 `helm upgrade -f values.yaml`. 차트가 graceful shutdown을 처리한다.

## 알려진 한계

- **HPA 미설정** — metrics-server는 도입했지만 자동 스케일을 거는 워크로드는 없다. 트래픽 패턴이 안정적이라 수동으로 충분 — 변동이 커지면 HPA 추가.
- **단일 PVE 호스트** — 모든 VM이 `pve` 한 대에서 동작. 호스트 장애 시 클러스터 전체 손실. 다중 PVE 또는 외부 백업이 필요한 시점에 별도 검토.
- **노드 토폴로지 라벨 미부착** — 현재 모든 노드가 같은 `pve` 호스트에 있어 zone/region 분리가 의미 없음. 토폴로지 인식 스케줄링이 필요해지면 노드 라벨부터.
