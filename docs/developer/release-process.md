# 릴리스 / 업그레이드 절차

helm 차트 / Talos OS / Kubernetes 버전을 올릴 때의 표준 작업 흐름. 운영자 시점의 절차는 [업그레이드와 롤백](../operating/upgrades-and-rollback.md)에 있고, 본 페이지는 변경을 사람 손으로 만드는 사람의 시점.

## 변경의 단위

본 프로젝트는 GitOps가 아니라 수동 `helm`/`kubectl` 흐름. 한 번의 "릴리스"는 다음 셋 중 하나.

| 종류 | 예시 | 영향 |
|---|---|---|
| Helm 차트 minor/patch | metrics-server 3.13.0 → 3.13.1 | 컴포넌트 1개 |
| Helm 차트 major | kube-prometheus-stack 84.5.0 → 85.0.0 | 컴포넌트 1개 + CRD 변경 가능성 |
| Talos OS / K8s | v1.13.0 → v1.13.1, K8s v1.36.0 → v1.36.1 | 클러스터 전체 |

## Helm 차트 변경 흐름

### minor / patch

1. `<component>/install.sh` 상단의 `CHART_VERSION` 한 줄 수정.
2. CHANGELOG 또는 차트 GitHub Release 한 번 훑어 breaking change가 없는지 확인.
3. helm diff (선택, 안전한 minor라도 첫 도입 시 권장):
   ```bash
   helm plugin install https://github.com/databus23/helm-diff   # 최초 1회
   helm diff upgrade <release> <chart> -n <ns> --version <NEW> -f values.yaml
   ```
4. 적용 — `./install.sh`.
5. 검증 — 그 컴포넌트 `README.md`의 "검증 체크리스트".
6. 본 README에 차트 버전을 적은 라인이 있으면 같이 갱신 (현재 6개 컴포넌트 README가 모두 차트 버전을 명시).

### major

1. CHANGELOG / Upgrade notes 정독 — breaking change, CRD 변경, values schema 변경 모두 기록.
2. CRD가 있는 차트라면 차트 저장소의 "Upgrading Chart" 절차를 따른다 — kube-prometheus-stack의 경우 [업그레이드와 롤백 — Helm 차트 업그레이드](../operating/upgrades-and-rollback.md#helm-차트-업그레이드)에 정리.
3. values.yaml schema 변경이 있으면 본 클러스터의 values를 먼저 새 schema로 다시 적는다.
4. helm diff 필수 — 큰 차이가 있을 텐데, 의도치 않은 변경이 섞여 있는지 확인.
5. 적용 후 검증 + 의존하는 다른 컴포넌트(예: ServiceMonitor를 만드는 다른 컴포넌트)가 깨지지 않았는지 함께 확인.

### 롤백

`helm rollback <release> <REVISION> -n <ns>`. revision 번호는 `helm history <release> -n <ns>`. CRD 변경을 동반한 major 업그레이드는 롤백 불가능할 수 있음 — 그 경우 [등록된 백업으로 etcd 복구](../operating/runbook.md#6-etcd-백업--복구)가 마지막 수단.

## Talos OS 업그레이드 흐름

운영자 시점 절차는 [런북 §4](../operating/runbook.md#4-talos-os-업그레이드). 변경의 사람 측면:

- `node-management/01-gen-talos-config.sh`의 `TALOS_VERSION`은 부트스트랩 시점에 박혔으므로 운영 중 변경 의미가 없다 — 새 부트스트랩에만 영향.
- `03-create-talos-vm.sh`의 `SCHEMATIC_ID`는 현재 시점의 익스텐션 묶음. 새 익스텐션이 필요하면 [factory.talos.dev](https://factory.talos.dev/)에서 새 schematic을 발급받고 `SCHEMATIC_ID`를 갱신 — 새 노드가 새 이미지로 부팅된다(기존 노드는 영향 없음).
- 업그레이드 자체는 `talosctl upgrade --image ghcr.io/siderolabs/installer:<version>`로 별도 명령. 03 스크립트와 무관.

## Kubernetes 업그레이드 흐름

운영자 시점 절차는 [런북 §5](../operating/runbook.md#5-kubernetes-업그레이드). 변경의 사람 측면:

- `talosctl upgrade-k8s --to <version>` 한 번에 전체 노드 순차 업그레이드. dry-run 먼저.
- 업그레이드 직전 [백업](../operating/runbook.md#6-etcd-백업--복구) 필수 — 롤백이 어려운 작업.
- K8s minor 버전(`1.36 → 1.37`)을 한 번에 두 단계 이상 건너뛰지 않는다.

## 컴포넌트 추가 / 제거 변경

운영자/통합자 시점은 [컴포넌트 추가 컨벤션](contributing.md). 변경의 사람 측면:

- 추가: 새 폴더 + `install.sh` + README + `docs/components/<name>.md` + `mkdocs.yml` nav 갱신 + `CLAUDE.md` 도입 순서 표 갱신.
- 제거: helm uninstall + namespace 삭제 + `mkdocs.yml` nav에서 페이지 제거(또는 페이지를 archive 폴더로 이동) + `CLAUDE.md`에서 제거. CRD가 따라오는 차트라면 의존 CR을 먼저 점검.

## 변경 추적

본 프로젝트는 별도의 CHANGELOG 파일을 두지 않는다 — git 커밋 메시지가 그 역할. 컴포넌트 추가/업그레이드 시 커밋 메시지에 다음을 박는다:

```
<component>: <verb> <release/version> <subject>

  - 차트: <chart> <old> → <new>
  - 의도: <왜>
  - 영향: <어디까지>
```

기존 커밋(예: `kube-prometheus-stack: introduce metrics + dashboards + alerts`)이 그 패턴.

## 변경 직전 점검 한 줄

- `helm history <release> -n <ns>` — 현재 revision 확인.
- `kubectl get pods -n <ns>` — 변경 직전 상태 baseline.
- `helm diff upgrade ...` — 의도치 않은 변경이 섞여 있지 않은지.
- 변경 직후 검증은 컴포넌트 README의 체크리스트.
