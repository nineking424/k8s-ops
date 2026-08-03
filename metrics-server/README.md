# metrics-server

`kubectl top` 및 HPA가 사용하는 리소스 메트릭(`v1beta1.metrics.k8s.io` API)을 제공.

## 무엇 / 왜

- 노드/Pod의 CPU·Memory 사용량을 kubelet의 Summary API에서 수집해 in-memory로 보관, Aggregated API로 노출.
- HPA, VPA, `kubectl top` 등 클러스터 기본 도구가 의존.
- 의존성: 없음 (PV/LB/Ingress 불필요). `talos-homelab`에서 제일 먼저 도입 가능한 컴포넌트.

## 설치

```bash
./install.sh
```

내부적으로 `helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system -f values.yaml` 호출.

차트 버전: `3.13.0` (app `v0.8.0`). 변경 시 `install.sh` 상단의 `CHART_VERSION` 변수만 수정.

## Talos 특이사항

Talos kubelet은 self-signed serving 인증서를 사용하므로 metrics-server가 기본 설정으론 `x509: certificate signed by unknown authority`로 실패. 본 values는 다음 args로 우회:

- `--kubelet-insecure-tls` — kubelet 인증서 검증 스킵
- `--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP` — Talos 노드의 InternalIP 우선

장기적으론 kubelet serving cert를 cluster CA로 서명하도록 Talos machine config를 패치하는 방법이 있으나(`--rotate-server-certificates`) 부트스트랩 클러스터에선 일단 insecure-tls가 표준.

## 한계 / 의도적으로 하지 않은 것

- **CPU/Memory만** — disk·network·custom 메트릭 없음. 정밀한 시계열은 `kube-prometheus-stack`이 담당.
- **In-memory 보관** — 1~2분 히스토리만. 과거 추이는 Prometheus에서 본다.
- **kubelet 인증서 검증 OFF** — `--kubelet-insecure-tls`. 동일 L2 클러스터라 위험은 낮지만, 외부 네트워크에 kubelet이 노출되면 재검토.
- **HA replica 미설정** — 차트 기본값(replicas=1). 단일 인스턴스가 죽어도 HPA가 30초~1분 후 다음 메트릭으로 복구되므로 홈랩 단계에서는 충분.

## 연결된 런북 / 트러블슈팅

- [트러블슈팅 — node가 NotReady로 떨어짐](https://github.com/nineking424/k8s-ops/wiki/Operating-Troubleshooting#node가-notready로-떨어짐) — `kubectl top`이 비어 있거나 일부 노드만 안 보일 때 1차 확인.
- [모니터링 — 활성 ServiceMonitor 카탈로그](https://github.com/nineking424/k8s-ops/wiki/Operating-Monitoring#활성--비활성-servicemonitor) — kubelet 메트릭은 Prometheus가 별도로 다시 받아간다.

## 검증 체크리스트

- [ ] `kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server` — Running, READY 1/1
- [ ] `kubectl get apiservice v1beta1.metrics.k8s.io` — `AVAILABLE=True`
- [ ] `kubectl top nodes` — 5개 노드의 CPU/MEM 출력 (수치가 보이기까지 30~60초 소요)
- [ ] `kubectl top pods -A` — 모든 네임스페이스의 Pod 메트릭 출력

## 제거

```bash
helm uninstall metrics-server -n kube-system
```

CRD 없음. 클러스터 스코프 자원(APIService, ClusterRole/Binding)은 helm uninstall이 정리.
