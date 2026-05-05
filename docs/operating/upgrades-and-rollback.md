# 업그레이드와 롤백

세 종류의 업그레이드가 있다 — Talos OS, Kubernetes, helm 차트. 각자 다른 절차, 다른 롤백 가능성.

## Talos OS 업그레이드

cp는 한 번에 한 대씩, etcd 쿼럼을 유지하며 순차 진행. 자세한 절차는 [런북 §4](runbook.md#4-talos-os-업그레이드).

### 흐름

1. [런북 §6](runbook.md#6-etcd-백업--복구)으로 백업.
2. worker부터 한 대씩 — 다 끝나면 노드 `Ready` 확인 후 다음.
3. cp는 VIP 미보유자부터 한 대씩 — 마지막에 VIP 보유자.

### 롤백 가능성

- **이미지 단계의 단순 롤백 가능** — 같은 노드에 이전 버전 이미지로 다시 `talosctl upgrade`를 보내면 된다. Talos는 A/B 파티션을 유지해 이전 시스템 이미지를 보존한다.
- **새 머신 컨피그가 박힌 변경은 비대칭** — 업그레이드와 함께 머신 컨피그를 바꿨다면 롤백 시 그 변경도 같이 되돌려야 한다.

명령:
```bash
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
  --nodes <NODE_IP> upgrade --image ghcr.io/siderolabs/installer:<OLD_VERSION>"
```

`<OLD_VERSION>`은 업그레이드 전 버전(예: `v1.13.0`). 03 스크립트의 `SCHEMATIC_ID`와 매칭되는 이미지여야 OS 익스텐션(qemu-guest-agent)이 살아 있다.

## Kubernetes 업그레이드

Talos가 K8s 컴포넌트를 묶어서 다룬다. cp 한 대에 명령을 보내면 전체 노드 순차 업그레이드. 자세한 절차는 [런북 §5](runbook.md#5-kubernetes-업그레이드).

### 흐름

1. dry-run으로 가능한 경로 확인:
   ```bash
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes 192.168.2.106 upgrade-k8s --to <NEW_VERSION> --dry-run"
   ```
2. 적용:
   ```bash
   ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
     --nodes 192.168.2.106 upgrade-k8s --to <NEW_VERSION>"
   ```

### 롤백 가능성

- **단순 롤백 어려움** — `upgrade-k8s`는 in-place로 컴포넌트를 교체하고 etcd 스키마 마이그레이션을 동반할 수 있다. 같은 명령으로 이전 버전을 지정해도 데이터 호환성이 깨질 수 있음.
- **롤백이 필요하면 etcd 스냅샷에서 복구** — [런북 §6](runbook.md#6-etcd-백업--복구). 업그레이드 직전 스냅샷이 있어야 한다.
- 운영 환경에서는 K8s 마이너 버전을 한 단계씩만 올리고, 한 단계마다 충분히 검증한다.

## Helm 차트 업그레이드

본 프로젝트의 6개 컴포넌트(metrics-server / nfs-subdir-external-provisioner / metallb / ingress-nginx / kube-prometheus-stack / + node-management 외)는 모두 Helm으로 관리. 업그레이드 흐름은 동일.

### 표준 흐름

1. `<component>/install.sh` 상단의 `CHART_VERSION` 변수를 새 버전으로 수정.
2. CHANGELOG / Upgrade notes 확인 — 차트 저장소(예: prometheus-community/helm-charts)의 README 또는 GitHub Release.
3. helm diff (선택, 차트 메이저 변경 시 강력 권장):
   ```bash
   helm plugin install https://github.com/databus23/helm-diff   # 최초 1회
   helm diff upgrade <release> <chart> -n <ns> --version <NEW> -f values.yaml
   ```
4. 적용:
   ```bash
   ./install.sh
   ```
5. 검증 — 해당 컴포넌트 README의 "검증 체크리스트".

### 롤백 가능성

- **helm rollback으로 즉시 복귀 가능** — `helm rollback <release> <REVISION> -n <ns>`. `helm history <release> -n <ns>`로 revision 확인.
- **CRD가 따라오는 차트는 주의** — kube-prometheus-stack은 helm install 시 CRD를 박지만 `helm upgrade`는 기본적으로 CRD를 갱신하지 않는다. 차트 메이저를 올릴 때는 차트 저장소의 [Upgrading Chart 절차](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack#upgrading-chart)를 따라 CRD를 먼저 수동 적용:
  ```bash
  for f in alertmanagerconfigs alertmanagers podmonitors probes prometheusagents prometheuses prometheusrules scrapeconfigs servicemonitors thanosrulers; do
    kubectl apply --server-side -f \
      https://raw.githubusercontent.com/prometheus-community/helm-charts/kube-prometheus-stack-<NEW>/charts/kube-prometheus-stack/charts/crds/crds/crd-${f}.yaml
  done
  ```
  그 다음 `./install.sh`.

## 컴포넌트별 메모

### metrics-server

상태 없음 — 마음대로 업그레이드/롤백. 차트 마이너 변경은 거의 무관.

### nfs-subdir-external-provisioner

상태 없음(provisioner는 PV 생성 시점에만 호출, 기존 PV에는 영향 없음). 다만 SC의 `provisioner` 필드가 차트 메이저에서 바뀌면 새 PVC만 새 provisioner를 쓰고, 기존 PV는 옛 SC reference를 유지하므로 SC를 함부로 지우지 말 것.

### MetalLB

CRD가 따라오는 차트 — `IPAddressPool`, `L2Advertisement`. 차트 메이저 업그레이드 시 차트 저장소 CHANGELOG를 먼저 본다. 본 클러스터의 두 CR(`home-pool`, `home-l2`)을 helm uninstall로 통째로 잃지 않도록 주의.

### ingress-nginx

`AdmissionWebhook`이 enabled — 업그레이드 중 webhook이 잠시 끊기면 새 Ingress 생성이 reject될 수 있다. 차트가 자동으로 cert를 patch하지만 수 초간의 회색 지대가 존재. 새 Ingress 생성 작업은 업그레이드 직후에만 잠시 보류.

### kube-prometheus-stack

CRD 갱신 절차가 가장 복잡한 차트. 위 § "CRD가 따라오는 차트는 주의" 절차를 따른다. 마이너 업그레이드라도 prometheus-operator의 reconcile이 잠시 멈출 수 있어 알람이 일시 침묵하는 시점이 있음 — 업그레이드 시각을 기록하고 알람 검증을 직후 한 번 돌린다.

## 롤백 마지막 수단 — etcd 복구

helm rollback / talosctl upgrade 롤백으로 풀리지 않는 상황(예: K8s 업그레이드 후 etcd 스키마가 깨짐)에서는 [런북 §6](runbook.md#6-etcd-백업--복구)의 백업으로 복구. 이 방법은 백업 시점 이후의 모든 변경을 잃는다 — 업그레이드 직전 백업이 필수.
