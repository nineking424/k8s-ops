# MetalLB

홈랩 클러스터(`talos-homelab`)에서 `Service type=LoadBalancer`에 외부 IP를 할당해 주는 컴포넌트. 클라우드 LB가 없는 환경의 표준 해결책.

## 무엇 / 왜

- L2 모드(Layer-2 advertisement): MetalLB speaker가 노드에서 ARP/NDP로 LoadBalancer IP를 announce. 단일 호스트(같은 L2 broadcast domain)인 홈랩에 가장 단순한 모드.
- 의존성: 노드 NIC가 같은 L2(192.168.0.0/16)에 있어야 함. Proxmox vmbr0 + 모든 Talos 노드 eth0이 같은 bridge에 물려 있어 충족.
- Ingress controller(다음 단계 #5)가 `Service type=LoadBalancer`를 받으려면 본 컴포넌트가 전제.

## 설치

```bash
./install.sh
```

내부적으로:
1. `helm upgrade --install metallb metallb/metallb -n metallb-system -f values.yaml`
2. `metallb-controller` rollout 대기
3. `ipaddresspool.yaml`, `l2advertisement.yaml` apply

차트 버전: `0.15.3` (app `v0.15.3`). 변경 시 `install.sh` 상단의 `CHART_VERSION` 변수만 수정.

## 핵심 설정

| 항목 | 값 | 메모 |
|---|---|---|
| 모드 | L2 | BGP는 라우터 BGP peering 필요 — 홈랩은 L2가 단순 |
| `IPAddressPool` 이름 | `home-pool` | |
| IP 풀 | `192.168.3.0/24` | 노드 대역(`192.168.2.x`) / cp VIP(`192.168.2.100`) / DHCP(`192.168.1.x` 라우터 분배) 모두와 분리 |
| `L2Advertisement` 이름 | `home-l2` | `home-pool`만 advertise |
| Speaker DaemonSet | 모든 노드(cp + worker) | 차트 기본 toleration이 cp NoSchedule 포함 |
| FRR 모드 | disabled | BGP 전용 컴포넌트 — L2만 쓰므로 OFF |

> **라우터 DHCP 풀과의 분리:** 라우터가 `192.168.3.x`를 DHCP로 분배하면 IP 충돌이 발생함. 라우터 측에서 DHCP 풀을 `192.168.1.x`나 다른 대역으로 한정해 두어야 함.

> **PodSecurity:** speaker는 `hostNetwork=true`, `NET_RAW`, hostPort 7472/7946을 요구해 클러스터 기본값 `baseline:latest`에선 차단됨. `install.sh`가 `metallb-system` 네임스페이스에 `pod-security.kubernetes.io/{enforce,audit,warn}=privileged` 라벨을 자동으로 박는다. 차트가 만든 ns를 그대로 쓰면 차단되므로 install.sh 흐름을 우회하지 말 것.

## 한계 / 의도적으로 하지 않은 것

- **L2 only** — BGP 모드 미사용. 라우터/스위치와 BGP peering이 가능해지면 풀 IP 전체 광고 + ECMP 가능하지만, 홈랩 환경의 단순성을 우선.
- **단일 IPAddressPool** — `home-pool` 하나. 서비스별 풀 분리(예: 내부/외부, 환경별) 미운영. 필요해지면 추가 IPAddressPool + label selector로 분리.
- **FRR 모드 비활성** — BGP 전용 컴포넌트라 OFF. L2만 쓰는 한 의미 없음.
- **스피커 leader election은 등시(equal cost)** — 어느 노드가 announce할지를 사용자가 핀하지 않음. `Service` 단위로 announce 노드가 갈리고, 노드 장애 시 다른 speaker가 인계.

## 연결된 런북 / 트러블슈팅

- [트러블슈팅 — LoadBalancer Service의 EXTERNAL-IP가 `<pending>`](../docs/operating/troubleshooting.md#loadbalancer-service의-external-ip가-pending)
- [트러블슈팅 — EXTERNAL-IP는 할당됐는데 외부에서 접속 안 됨](../docs/operating/troubleshooting.md#external-ip는-할당됐는데-외부에서-접속-안-됨)
- [개념 — 네트워크 토폴로지](../docs/concepts/network-topology.md) — IP 풀 분리 근거.

## 검증 체크리스트

- [ ] `kubectl get pods -n metallb-system` — `metallb-controller`(Deployment, 1/1) + `metallb-speaker-*`(DaemonSet, 5/5 — cp 3 + wk 2) Running
- [ ] `kubectl get ipaddresspool -n metallb-system home-pool` — 보임
- [ ] `kubectl get l2advertisement -n metallb-system home-l2` — 보임
- [ ] 시험 LoadBalancer Service:
  ```bash
  kubectl create deploy lb-test --image=nginx:1.27-alpine
  kubectl expose deploy lb-test --port=80 --type=LoadBalancer
  kubectl get svc lb-test -w   # EXTERNAL-IP에 192.168.3.x 할당
  curl -sI http://<EXTERNAL_IP>   # 200 OK
  kubectl delete deploy lb-test && kubectl delete svc lb-test
  ```
- [ ] `kubectl get events -n metallb-system --sort-by=.lastTimestamp | tail` — `assigned IP "192.168.3.x"`, `announcing from node "talos-..."` 메시지

## 트러블슈팅

- **EXTERNAL-IP가 `<pending>`에 멈춤**: IPAddressPool/L2Advertisement이 빠졌거나 IP 풀이 모두 소진. `kubectl describe svc <name>` 의 events 확인.
- **EXTERNAL-IP는 할당됐는데 외부에서 접속 안 됨**:
  - speaker pod 로그: `kubectl logs -n metallb-system -l app.kubernetes.io/component=speaker --tail=50`
  - 노드 ARP 응답 확인: 같은 L2의 다른 호스트에서 `arping -c 3 <EXTERNAL_IP>`로 응답이 와야 함.
  - 라우터/스위치가 ARP probe를 막고 있는지 확인 (보통 홈 라우터는 OK).
- **두 노드가 동시에 같은 IP를 announce**: speaker는 leader election으로 한 노드만 announce — 둘이 동시면 leader election 실패. 노드 간 통신이 끊어졌는지 확인.

## 제거

```bash
kubectl delete -f l2advertisement.yaml -f ipaddresspool.yaml
helm uninstall metallb -n metallb-system
kubectl delete ns metallb-system
```

> **CRD는 helm uninstall 시 삭제되지 않을 수 있음.** 의존하는 LoadBalancer Service가 남아 있으면 EXTERNAL-IP가 재할당되지 않으므로, 본 컴포넌트를 제거하기 전에 LoadBalancer Service 의존 목록을 확인:
> ```bash
> kubectl get svc -A --field-selector spec.type=LoadBalancer
> ```
