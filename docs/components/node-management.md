# node-management

Talos 머신 컨피그 발급 + Proxmox VM 생성 스크립트. 클러스터의 토대 — 다른 모든 컴포넌트는 이 위에서 동작한다.

## 역할

- `01-gen-talos-config.sh` — 클러스터 시크릿/CA + 머신컨피그 발급. **절대 재실행 금지.**
- `02-place-base-snippets.sh` — `_out/`의 base 컨피그를 PVE snippets에 배치. 멱등.
- `03-create-talos-vm.sh` — 노드별 user.yaml + Proxmox VM 생성. cp 역할이면 VIP 블록을 자동 삽입. 노드마다 호출.
- `node-management-guide.md` — 부트스트랩 / 노드 추가 / 업그레이드 / etcd 백업 / VIP 운영 / 트러블슈팅 종합 가이드.

스크립트는 **PVE 호스트에서 root로 실행**되는 것을 전제. 본 프로젝트의 사본은 작업/리뷰용이고, 실제 실행은 `pve:~/k8s-ops/node-management/`의 사본을 호출한다.

## 위치

- **작업 사본 (권위 있는)**: `node-management/` (본 프로젝트 디렉토리)
- **실행 사본**: `pve:~/k8s-ops/node-management/` — 본 사본 변경 후 동기화 필수.
  ```bash
  scp node-management/*.sh node-management/*.md pve:k8s-ops/node-management/
  ```

부트스트랩 결과물:
- `pve:~/talos-cluster/_out/` — `controlplane.yaml`, `worker.yaml`, **`talosconfig`**(절대 Git 커밋 금지).
- `pve:/var/lib/vz/snippets/` — base 2개(`_talos-cp-base.yaml`, `_talos-wk-base.yaml`) + 노드별 5개(`talos-cp-0{1,2,3}-user.yaml`, `talos-wk-0{1,2}-user.yaml`).

## 의존

없음 — 클러스터의 시작점.

## 한계 / 의도적으로 하지 않은 것

- **PVE 단일 호스트 가정** — 멀티 PVE에 분산하려면 03 스크립트의 `STORAGE`와 snippets 경로 / VM 배치 로직을 손봐야 한다.
- **스크립트는 Talos cluster 한 개만 다룬다** — 두 번째 클러스터를 만들려면 01의 `CLUSTER_NAME` / `CLUSTER_VIP`를 별도로 박은 사본이 필요. 같은 호스트에서 두 클러스터를 운영할 의도는 없음.
- **schematic ID 변경 자동화 없음** — 새 OS 익스텐션을 추가하려면 [factory.talos.dev](https://factory.talos.dev/)에서 새 schematic을 발급받고 03 스크립트의 `SCHEMATIC_ID`를 수동으로 갱신.
- **동기화는 수동** — 본 프로젝트와 PVE 사본의 동기화는 `scp` 한 줄. 자동 동기화(예: cron rsync)는 도입하지 않음 — 동기화 시점이 명시적이어야 안전.

## 연결된 런북

- [§3 노드 추가/제거](../operating/runbook.md#3-노드-추가--제거)
- [§4 Talos OS 업그레이드](../operating/runbook.md#4-talos-os-업그레이드)
- [§9 cluster endpoint / VIP 변경](../operating/runbook.md#9-cluster-endpoint--vip-변경)

## 권위 있는 사본

세부 절차의 단일 진실은 [`node-management/node-management-guide.md`](../../node-management/node-management-guide.md). 본 페이지는 그 가이드의 진입점이다.
