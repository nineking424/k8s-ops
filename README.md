# k8s-ops

Proxmox + Talos로 구성한 홈랩 Kubernetes 클러스터 `talos-homelab`의 운영·관리 저장소. 노드 프로비저닝 스크립트(`node-management/`), 클러스터 컴포넌트별 설치 진입점(`<component>/install.sh` + values), Proxmox 호스트 외부 워치독(`pve-watchdog/`)을 담는다.

**운영 문서는 [GitHub Wiki](https://github.com/nineking424/k8s-ops/wiki)에 있다** — 일상 접근 패턴, 런북, 트러블슈팅, 컴포넌트별 가이드, 아키텍처.

## 레이아웃

| 경로 | 내용 |
|---|---|
| `node-management/` | Talos 노드 프로비저닝 스크립트(`01`/`02`/`03`)와 종합 가이드 |
| `<component>/` | 클러스터 컴포넌트별 폴더 — `install.sh` 한 번으로 설치, `README.md`에 검증 절차 |
| `pve-watchdog/` | Proxmox 호스트(pve) 외부 워치독 — 상시 가동 맥 Docker에서 구동 |

## 빠른 확인

```bash
kubectl get nodes -o wide        # 클러스터 상태 (context: admin@talos-homelab)
ssh pve "qm list"                # VM 상태 (talos-cp-01만 ssh pve-main)
```

나머지는 전부 [위키](https://github.com/nineking424/k8s-ops/wiki)에서 찾는다.
