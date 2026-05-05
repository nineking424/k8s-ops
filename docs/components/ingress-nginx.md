# ingress-nginx

홈랩 클러스터의 HTTP 외부 진입점. cluster-internal Service들에 host/path 기반 라우팅을 제공.

## 역할

- `Service type=LoadBalancer`로 노출 — MetalLB가 `home-pool`에서 IP 할당, **`192.168.3.10`로 핀**.
- IngressClass `nginx`가 클러스터 default — `ingressClassName` 미지정 Ingress도 자동으로 nginx가 처리.
- 외부 NPM이 `*.k8s.stjeong.com → 192.168.3.10:80` HTTP forward + edge TLS 종단. 클러스터 측 Ingress는 HTTP만 정의 (`tls:` 섹션 없음).

## 위치 / 차트

- 폴더: [`ingress-nginx/`](https://github.com/nineking424/k8s-ops/tree/main/ingress-nginx/) — 권위 있는 install/검증 사본은 그 폴더의 `README.md`.
- 차트: `ingress-nginx/ingress-nginx` v4.15.1 (app v1.15.1)
- Namespace: `ingress-nginx` (자체)

## 핵심 설정

| 항목 | 값 |
|---|---|
| IngressClass | `nginx` (cluster default) |
| Service 타입 | LoadBalancer |
| LB IP (pin) | `192.168.3.10` (어노테이션 `metallb.universe.tf/loadBalancerIPs`) |
| externalTrafficPolicy | `Local` (클라이언트 source IP 보존) |
| Replicas | 2 (anti-affinity로 wk-01/wk-02 분산) |
| AdmissionWebhook | enabled, `failurePolicy=Fail` |
| Metrics | disabled (별도 ServiceMonitor 필요 시 활성화) |

## 의존

- **MetalLB** — LoadBalancer IP 할당의 전제.
- **외부 NPM** — `*.k8s.stjeong.com` 와일드카드를 받아 HTTP forward. 본 컴포넌트가 NPM을 관리하지 않음.

## 한계 / 의도적으로 하지 않은 것

- **HTTP only** — Ingress 리소스에 `tls:` 섹션을 두지 않는다. NPM이 edge에서 TLS 종단. cert-manager 미도입 — 클러스터 안에서 인증서를 발급할 일이 없음.
- **Metrics 비활성** — 차트의 metrics endpoint를 끔. 활성화하면 ServiceMonitor를 추가하고 알람을 [모니터링](../operating/monitoring.md)에 반영.
- **`externalTrafficPolicy=Local`로 인한 트래픽 단절 위험** — 두 worker가 모두 죽으면 외부 진입이 끊긴다. cp에서는 controller pod이 안 뜨도록 anti-affinity 박혀 있음(cp 자원 절약).
- **단일 controller class** — 두 번째 IngressClass(예: 다른 controller)를 동시에 운영할 의도 없음.
- **AdmissionWebhook은 단일 명세 검증만** — 차트가 자동으로 cert를 patch. cert가 깨지면 새 Ingress 생성이 reject되는 짧은 회색 지대가 helm 업그레이드 중에 존재.

## 연결된 런북 / 트러블슈팅

- [트러블슈팅 — Ingress가 503 혹은 default backend 404를 반환](../operating/troubleshooting.md#ingress가-503-혹은-default-backend-404를-반환)
- [트러블슈팅 — Grafana 외부 접속이 안 되거나 redirect가 깨짐](../operating/troubleshooting.md#grafana-외부-접속이-안-되거나-redirect가-깨짐) (외부 NPM 쪽 진단 분기 포함)
- [외부 노출 모델](../concepts/external-exposure.md)
- 검증 절차는 [`ingress-nginx/README.md` § 검증 체크리스트](https://github.com/nineking424/k8s-ops/blob/main/ingress-nginx/README.md).
