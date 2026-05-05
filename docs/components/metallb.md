# MetalLB

홈랩 클러스터에서 `Service type=LoadBalancer`에 외부 IP를 할당. 클라우드 LB가 없는 환경의 표준 해결책.

## 역할

- L2 모드(Layer-2 advertisement) — speaker가 노드에서 ARP/NDP로 LB IP를 announce.
- IPAddressPool `home-pool` (`192.168.3.0/24`)에서 IP를 분배.
- ingress-nginx가 LB IP를 받기 위한 전제.

## 위치 / 차트

- 폴더: [`metallb/`](../../metallb/) — 권위 있는 install/검증 사본은 그 폴더의 `README.md`.
- 차트: `metallb/metallb` v0.15.3 (app v0.15.3)
- Namespace: `metallb-system` (자체, **PSA `privileged`** 필수)

## 핵심 설정

| 항목 | 값 |
|---|---|
| 모드 | L2 (BGP 미사용) |
| `IPAddressPool` 이름 | `home-pool` |
| IP 풀 | `192.168.3.0/24` |
| `L2Advertisement` 이름 | `home-l2` |
| Speaker | DaemonSet, 모든 노드 (cp 3 + wk 2) |
| FRR | disabled |

## 의존

- 노드 NIC가 같은 L2 broadcast domain에 있어야 함. 본 클러스터는 모두 Proxmox `vmbr0` 단일 bridge — 충족.
- speaker가 `hostNetwork=true` + `NET_RAW` + hostPort 7472/7946을 요구해 클러스터 기본 PSA `baseline:latest`에선 차단. `metallb-system` 네임스페이스에 `pod-security.kubernetes.io/{enforce,audit,warn}=privileged` 라벨이 박혀 있어야 한다 — `install.sh`가 자동으로 처리.

## 한계 / 의도적으로 하지 않은 것

- **L2 모드만 운영 — BGP 안 씀** — 라우터 BGP peering이 없는 홈랩에서는 BGP가 과한 복잡도. 노드가 다른 L2 세그먼트로 분산되면 그때 BGP 검토.
- **단일 IP 풀** — 환경 분리(예: dev/prod)는 단일 운영자 환경에서 의미 없음. 필요해지면 IPAddressPool 추가.
- **라우터 DHCP 풀과의 분리는 라우터 측 책임** — 라우터가 `192.168.3.x`를 DHCP로 분배하면 충돌. 본 컴포넌트가 자동 회피하지 않는다 — 라우터에서 DHCP 풀을 `192.168.1.x`로 한정해 두어야 함.
- **speaker가 hostNetwork** — 보안상 namespace를 격리하기 어렵다. 같은 ns에 다른 컴포넌트를 함께 두지 않는다.

## 연결된 런북 / 트러블슈팅

- [트러블슈팅 — LoadBalancer Service의 EXTERNAL-IP가 `<pending>`](../operating/troubleshooting.md#loadbalancer-service의-external-ip가-pending)
- [트러블슈팅 — EXTERNAL-IP는 할당됐는데 외부에서 접속 안 됨](../operating/troubleshooting.md#external-ip는-할당됐는데-외부에서-접속-안-됨)
- [네트워크 토폴로지 — MetalLB L2 announce](../concepts/network-topology.md#metallb-l2-announce)
- 검증 절차는 [`metallb/README.md` § 검증 체크리스트](../../metallb/README.md).
