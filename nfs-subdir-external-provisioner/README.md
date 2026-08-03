# nfs-subdir-external-provisioner

NAS의 단일 NFS export를 백엔드로 동적 PV(`StorageClass nfs-client`)를 제공.

## 무엇 / 왜

- 클러스터 PVC가 들어오면 provisioner가 NFS export 하위에 디렉토리(`<namespace>-<pvc-name>-<pv-name>`)를 만들어 PV로 노출.
- `talos-homelab`은 부트스트랩 직후라 StorageClass가 비어 있어서 stateful 워크로드(관측성 스택, DB 등)를 띄우지 못함. 본 컴포넌트가 그 전제를 채움.
- 백엔드: NAS `nknas` (192.168.1.4), 단일 export `/volume1/nfsvolume`. PVC가 늘어나도 export는 하나로 유지(컴포넌트별 분리 아님).

## 설치

```bash
./install.sh
```

내부적으로 `helm upgrade --install nfs-subdir-external-provisioner nfs-subdir-external-provisioner/nfs-subdir-external-provisioner -n nfs-subdir-external-provisioner -f values.yaml` 호출. 자체 namespace를 생성/사용.

차트 버전: `4.0.18` (app `v4.0.2`). 변경 시 `install.sh` 상단의 `CHART_VERSION` 변수만 수정.

## 핵심 설정

| 항목 | 값 | 메모 |
|---|---|---|
| `nfs.server` | `192.168.1.4` | NAS `nknas` |
| `nfs.path` | `/volume1/nfsvolume` | 단일 export. NAS 측에서 `*` 허용. |
| `nfs.mountOptions` | `nfsvers=3,nolock` | Synology 기본 호환. v4 이슈 시 조정. |
| `storageClass.name` | `nfs-client` | 관용적 명칭 |
| `storageClass.defaultClass` | `true` | 클러스터 기본 SC. PVC가 SC 미지정 시 자동 사용. |
| `storageClass.reclaimPolicy` | `Delete` | PVC 삭제 시 NFS 디렉토리도 제거 |
| `storageClass.archiveOnDelete` | `false` | 보존 안 함. 필요 시 `true`로. |
| `storageClass.allowVolumeExpansion` | `true` | PVC 용량 증가 허용 |
| `storageClass.accessModes` | `ReadWriteOnce` | NFS는 `ReadWriteMany`도 가능 — PVC에서 RWX 요청해도 동작. |

> 이 provisioner는 PVC 단계에서 `accessMode`를 검증하지 않으므로 PVC가 `ReadWriteMany`를 요청해도 PV가 정상 생성됨. NFS export 자체가 RWX를 지원하기 때문.

## 한계 / 의도적으로 하지 않은 것

- **단일 NFS export** — 컴포넌트별 export 분리 안 함. NAS export 자체가 망가지면 본 클러스터의 모든 PV가 동시에 영향.
- **Snapshot / Volume Cloning 미지원** — 차트가 CSI VolumeSnapshot을 제공하지 않음. 백업은 NAS 레벨(Synology 스냅샷 / rsync)에서.
- **reclaimPolicy=Delete + archiveOnDelete=false** — PVC 삭제 시 NFS 디렉토리도 즉시 삭제. 우발적 PVC 삭제는 데이터 분실로 이어진다 — 중요한 워크로드는 PVC에 finalizer/operator 보호 또는 NAS 측 스냅샷에 의존.
- **Talos kubelet은 NFS 클라이언트를 자체 포함** — 별도 시스템 패키지 설치 불필요. 다만 NFSv4 강제 시 `nolock` 옵션과 충돌하는 케이스가 있어 기본은 v3.
- **권한 분리 없음** — 모든 PVC가 같은 export 아래에 평면 디렉토리로 생성. namespace 단위 격리는 NAS 권한이 아니라 k8s API(RBAC)에서.

## 연결된 런북 / 트러블슈팅

- [런북 §7 — NFS 마운트 장애](https://github.com/nineking424/k8s-ops/wiki/Operating-Runbook#7-nfs-마운트-장애)
- [트러블슈팅 — PVC가 Pending에서 안 넘어감](https://github.com/nineking424/k8s-ops/wiki/Operating-Troubleshooting#pvc가-pending에서-안-넘어감)
- [트러블슈팅 — NFS PVC가 mount 실패 / 읽기·쓰기 IOhang](https://github.com/nineking424/k8s-ops/wiki/Operating-Troubleshooting#nfs-pvc가-mount-실패--읽기쓰기-iohang)

## 검증 체크리스트

- [ ] `kubectl get pods -n nfs-subdir-external-provisioner` — provisioner pod이 Running, READY 1/1
- [ ] `kubectl get sc` — `nfs-client (default)` 보임
- [ ] 시험 PVC 동적 프로비저닝:
  ```bash
  kubectl apply -f - <<'YAML'
  apiVersion: v1
  kind: PersistentVolumeClaim
  metadata: { name: nfs-test, namespace: default }
  spec:
    accessModes: [ReadWriteOnce]
    resources: { requests: { storage: 1Gi } }
  YAML
  kubectl get pvc nfs-test -w   # Bound 까지 수십 초
  ```
- [ ] PV가 Bound되고 NAS의 `/volume1/nfsvolume/default-nfs-test-<pv>` 디렉토리가 실제로 생성되었는지 확인
- [ ] 시험 PVC 정리:
  ```bash
  kubectl delete pvc nfs-test
  ```
  → reclaimPolicy=Delete이므로 NFS 디렉토리도 함께 사라짐.

## 트러블슈팅

- **`mount.nfs: access denied by server`**: NAS export의 허용 IP에 노드 대역(192.168.2.0/24)이 빠져 있음. NAS 관리도구에서 export 권한 확인.
- **PV는 Pending인 채 멈춤**: provisioner pod 로그 확인 — `kubectl logs -n nfs-subdir-external-provisioner -l app=nfs-subdir-external-provisioner --tail=50`. NFS 도달성/권한 이슈가 대부분.
- **NFSv4로 강제하고 싶으면**: `values.yaml`의 `nfs.mountOptions`를 `nfsvers=4.1,...` 로 바꿔 `helm upgrade -f values.yaml`. NAS 측에서 NFSv4가 활성화되어 있어야 함.

## 제거

```bash
helm uninstall nfs-subdir-external-provisioner -n nfs-subdir-external-provisioner
kubectl delete ns nfs-subdir-external-provisioner
```

CRD 없음. 단, **기존 PVC가 본 SC를 쓰고 있으면 PV가 고아가 되어 데이터 분리/이전 절차가 필요**하므로 제거 전에 의존 PVC 목록을 반드시 확인:

```bash
kubectl get pvc -A -o jsonpath='{range .items[?(@.spec.storageClassName=="nfs-client")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}'
```
