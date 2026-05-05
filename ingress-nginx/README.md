# ingress-nginx

홈랩 클러스터(`talos-homelab`)의 HTTP(S) 외부 진입점. cluster-internal Service들에 대한 host/path 기반 라우팅을 제공.

## 무엇 / 왜

- ingress-nginx Controller가 `Service type=LoadBalancer`로 노출되고, MetalLB가 `home-pool`에서 IP를 할당.
- IngressClass `nginx`를 클러스터 default로 설정 — `ingressClassName` 미지정 Ingress도 자동으로 nginx가 처리.
- 의존성: MetalLB(권장 도입 #4)가 LoadBalancer IP를 할당. AdmissionWebhook은 차트가 알아서 cert patch.

## 설치

```bash
./install.sh
```

내부적으로:
1. `helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx -f values.yaml`
2. `ingress-nginx-controller` rollout 대기

차트 버전: `4.15.1` (app `v1.15.1`). 변경 시 `install.sh` 상단의 `CHART_VERSION` 변수만 수정.

## 핵심 설정

| 항목 | 값 | 메모 |
|---|---|---|
| Namespace | `ingress-nginx` | 전용 |
| IngressClass | `nginx` (default) | 단일 controller 환경 — ingressClassName 미지정 Ingress도 nginx가 처리 |
| Service 타입 | LoadBalancer | MetalLB가 IP 할당 |
| LoadBalancer IP | **`192.168.3.10`** (pin) | `metallb.universe.tf/loadBalancerIPs` 어노테이션으로 핀. DNS / `/etc/hosts` 안정 |
| externalTrafficPolicy | `Local` | 클라이언트 source IP 보존 |
| Replicas | 2 | wk-01/wk-02에 anti-affinity로 분산 |
| AdmissionWebhook | enabled, `failurePolicy=Fail` | Ingress 생성/수정 시 nginx config validate. 차트가 cert 자동 patch |
| Metrics | disabled | Prometheus 도입(#6) 시 활성화 |

> **PodSecurity:** controller pod은 `baseline:latest` 기본값에 호환 (runAsNonRoot, allowPrivilegeEscalation=false, seccompProfile=RuntimeDefault, NET_BIND_SERVICE만 추가). 별도 ns 라벨링 불필요.

## 한계 / 의도적으로 하지 않은 것

- **HTTP only** — Ingress 리소스에 `tls:` 섹션을 두지 않는다. 외부 NPM이 edge에서 TLS 종단. 클러스터 안에서는 평문 HTTP만 흐름.
- **cert-manager 미도입** — 클러스터 안에서 인증서를 발급할 일이 없음. 향후 mTLS / 내부 서비스간 TLS가 필요해지면 그 시점에 도입.
- **Metrics 비활성** — 차트의 metrics endpoint를 끔. 활성화하려면 ServiceMonitor 추가 + 알람 규칙 보강 필요.
- **`externalTrafficPolicy=Local`로 인한 트래픽 단절 위험** — 두 worker가 모두 죽으면 외부 진입이 끊긴다. cp에서는 controller pod이 안 뜨도록 anti-affinity로 막혀 있음(cp 자원 절약).
- **단일 controller class** — 두 번째 IngressClass(예: 다른 controller)를 동시에 운영할 의도 없음. 새로 추가하면 default 충돌.

## 연결된 런북 / 트러블슈팅

- [트러블슈팅 — Ingress가 503 혹은 default backend 404를 반환](../docs/operating/troubleshooting.md#ingress가-503-혹은-default-backend-404를-반환)
- [트러블슈팅 — Grafana 외부 접속이 안 되거나 redirect가 깨짐](../docs/operating/troubleshooting.md#grafana-외부-접속이-안-되거나-redirect가-깨짐) — 외부 NPM 쪽 진단 분기 포함.
- [개념 — 외부 노출 모델](../docs/concepts/external-exposure.md) — NPM ↔ ingress-nginx 책임 분리.

## 검증 체크리스트

- [ ] `kubectl get pods -n ingress-nginx` — `ingress-nginx-controller-*`(Deployment, 2/2) Running
- [ ] `kubectl get svc -n ingress-nginx ingress-nginx-controller` — `EXTERNAL-IP`가 `192.168.3.10`
- [ ] `kubectl get ingressclass` — `nginx`가 보이고 `IS-DEFAULT-CLASS=true`
- [ ] `kubectl get validatingwebhookconfiguration ingress-nginx-admission` — 보임
- [ ] 시험 Ingress:
  ```bash
  kubectl create deploy ing-test --image=nginx:1.27-alpine
  kubectl expose deploy ing-test --port=80
  kubectl create ingress ing-test --rule="ing-test.local/*=ing-test:80"
  curl -sI -H "Host: ing-test.local" http://192.168.3.10   # 200 OK
  kubectl delete ingress ing-test && kubectl delete svc ing-test && kubectl delete deploy ing-test
  ```

## 트러블슈팅

- **EXTERNAL-IP가 `<pending>`**: MetalLB controller/speaker 상태 확인. `home-pool` IP 풀이 소진됐는지 `kubectl describe svc -n ingress-nginx ingress-nginx-controller` events 확인.
- **Ingress 생성이 admission webhook에서 reject**: webhook pod 로그
  ```bash
  kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50
  ```
  잘못된 nginx config(예: 중복 host, 잘못된 annotation)이 가장 흔한 원인.
- **Webhook이 timeout으로 안 뜸 (cert가 깨짐)**: 차트가 자동 patch하는 cert가 만료/손상. 차트 재설치(`./install.sh`)로 cert job이 재실행됨.
- **`externalTrafficPolicy=Local`인데 일부 노드로 가면 응답 없음**: announce된 노드에 controller pod이 없으면 트래픽이 끊김. replica 2 + anti-affinity로 두 worker에 분산되어 있는지 `kubectl get pods -n ingress-nginx -o wide` 확인. wk 1대만 살아 있으면 정상이지만 둘 다 죽으면 끊김.

## 제거

```bash
helm uninstall ingress-nginx -n ingress-nginx
kubectl delete ns ingress-nginx
# IngressClass는 차트가 만든 거라 helm uninstall로 같이 삭제됨.
# Default IngressClass가 사라지면 ingressClassName 미지정 Ingress는 처리되지 않음 — 의존 Ingress 확인:
#   kubectl get ingress -A
```
