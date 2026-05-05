# 컴포넌트

본 클러스터에 도입된 컴포넌트와 그 의존 순서. 각 페이지는 "역할 / 의존 / 한계 / 연결된 런북" 골격으로 짧게 정리하고, 설치·검증의 권위 있는 사본은 컴포넌트 폴더의 `README.md`다.

| # | 컴포넌트 | 역할 | 의존 (선행) |
|---|---|---|---|
| 0 | [node-management](node-management.md) | Talos 머신 컨피그 발급 + Proxmox에 VM 생성. 클러스터의 토대. | 없음 |
| 1 | [metrics-server](metrics-server.md) | `kubectl top`, HPA가 쓰는 리소스 메트릭 API. | 없음 |
| 2 | (CP HA / VIP) | Talos native VIP `192.168.2.100`. 별도 컴포넌트 없이 머신 컨피그로 처리 — [노드 관리 가이드 §VIP 운영](https://github.com/nineking424/k8s-ops/blob/main/node-management/node-management-guide.md#control-plane-vip-운영). | 없음 |
| 3 | [nfs-subdir-external-provisioner](nfs-subdir-external-provisioner.md) | StorageClass `nfs-client` (default). NAS `nknas`(192.168.1.4) 백엔드. | 없음 |
| 4 | [MetalLB](metallb.md) | L2 모드 LoadBalancer. IP 풀 `192.168.3.0/24`. | 없음 |
| 5 | [ingress-nginx](ingress-nginx.md) | HTTP 외부 진입점. LB IP `192.168.3.10` pin. | MetalLB |
| 6 | [kube-prometheus-stack](kube-prometheus-stack.md) | Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics. | NFS SC, MetalLB, ingress-nginx |

새 컴포넌트를 추가하는 절차는 [새 컴포넌트 도입](../getting-started/adding-a-component.md), 깊은 컨벤션은 [컴포넌트 추가 컨벤션](../developer/contributing.md) 참고.

> **README.md ↔ 본 페이지 분리.** 컴포넌트 폴더의 `README.md`는 `install.sh` 진입점 / 검증 체크리스트 / 트러블슈팅 — 그 컴포넌트만 다루는 운영자가 본다. 본 페이지는 클러스터 전체 그림에서 이 컴포넌트의 위치 / 의존 / 한계를 짧게 보여준다.
