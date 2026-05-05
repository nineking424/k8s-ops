# nfs-subdir-external-provisioner

NAS의 단일 NFS export를 백엔드로 동적 PV(`StorageClass nfs-client`)를 제공.

## 역할

- 클러스터 PVC가 들어오면 provisioner가 NFS export 하위에 `<namespace>-<pvc-name>-<pv-name>/` 디렉토리를 만들어 PV로 노출.
- 클러스터의 default StorageClass — PVC가 SC 미지정 시 자동으로 nfs-client를 쓴다.

## 위치 / 차트

- 폴더: [`nfs-subdir-external-provisioner/`](https://github.com/nineking424/k8s-ops/tree/main/nfs-subdir-external-provisioner/) — 권위 있는 install/검증 사본은 그 폴더의 `README.md`.
- 차트: `nfs-subdir-external-provisioner/nfs-subdir-external-provisioner` v4.0.18 (app v4.0.2)
- Namespace: `nfs-subdir-external-provisioner` (자체)

## 백엔드

| 항목 | 값 |
|---|---|
| NFS server | `192.168.1.4` (NAS `nknas`) |
| Export path | `/volume1/nfsvolume` |
| Mount options | `nfsvers=3,nolock` |
| StorageClass name | `nfs-client` (cluster default) |
| reclaimPolicy | `Delete` |
| archiveOnDelete | `false` |
| allowVolumeExpansion | `true` |
| accessModes | `ReadWriteOnce` (RWX 요청도 동작 — NFS 자체가 RWX 지원) |

> **단일 export 가정** — PVC가 늘어나도 같은 NFS export 하위 디렉토리로 분리될 뿐 export는 하나. 컴포넌트별로 SC를 분리할 의도 없음.

## 의존

없음 (NAS는 클러스터 외부 자원). 클러스터 측에서는 노드와 NAS 간 L2 도달성 + NAS export 권한만 갖추면 됨.

## 한계

- **NAS가 SPOF** — NAS 다운 시 모든 PVC 워크로드가 IO 블록. 분산 블록 스토리지(Longhorn/Rook-Ceph)는 미도입 — 필요해지면 그때.
- **단일 provisioner replica** — provisioner는 PV 생성 시점에만 호출. 일시 다운돼도 기존 PV는 영향 없음.
- **archiveOnDelete=false** — PVC 삭제 시 데이터가 즉시 사라진다. 보존이 필요하면 `true`로 바꾸거나 NAS 레벨 백업.
- **단일 NFS 버전** — `nfsvers=3,nolock`로 박혀 있음. NFSv4가 필요하면 values 변경 + NAS에서 v4 활성화.

## 연결된 런북 / 트러블슈팅

- [§7 NFS 마운트 장애](../operating/runbook.md#7-nfs-마운트-장애)
- [트러블슈팅 — PVC가 Pending에서 안 넘어감](../operating/troubleshooting.md#pvc가-pending에서-안-넘어감)
- [트러블슈팅 — NFS PVC가 mount 실패](../operating/troubleshooting.md#nfs-pvc가-mount-실패--읽기쓰기-iohang)
- 검증 절차는 [`nfs-subdir-external-provisioner/README.md` § 검증 체크리스트](https://github.com/nineking424/k8s-ops/blob/main/nfs-subdir-external-provisioner/README.md).
