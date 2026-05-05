# metrics-server

`kubectl top` / HPA가 사용하는 리소스 메트릭(`v1beta1.metrics.k8s.io` API)을 제공.

## 역할

- 노드/Pod의 CPU·Memory 사용량을 kubelet의 Summary API에서 수집해 in-memory로 보관, Aggregated API로 노출.
- HPA, VPA, `kubectl top` 등 클러스터 기본 도구가 의존.

## 위치 / 차트

- 폴더: [`metrics-server/`](../../metrics-server/) — 권위 있는 install/검증 사본은 그 폴더의 `README.md`.
- 차트: `metrics-server/metrics-server` v3.13.0 (app v0.8.0)
- Namespace: `kube-system`

## 의존

없음. PV/LB/Ingress 모두 불필요 — `talos-homelab`에서 가장 가벼운 시작점.

## Talos 특이사항

Talos kubelet은 self-signed serving 인증서를 사용해 metrics-server가 기본 설정으론 `x509: certificate signed by unknown authority`로 실패. values에서 다음 args로 우회:

- `--kubelet-insecure-tls` — kubelet 인증서 검증 스킵
- `--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP`

장기적으로는 kubelet serving cert를 cluster CA로 서명하도록 Talos 머신 컨피그를 패치(`--rotate-server-certificates`)할 수 있으나 본 단계에서는 insecure-tls가 표준.

## 한계

- **단일 replica** — 차트 기본값. 잠깐 끊겨도 `kubectl top`/HPA만 영향 — 운영에 큰 부담 없음. HA가 필요해지면 replicaCount를 2 + leader election 활성화.
- **15초 단위 in-memory 보관** — Prometheus 같은 시계열 저장이 아니다. 추세 분석은 [kube-prometheus-stack](kube-prometheus-stack.md).

## 연결된 런북 / 트러블슈팅

- [모니터링 — Prometheus targets 검증](../operating/monitoring.md#prometheus-targets-검증) — metrics-server 자체 알람보다 Prometheus를 통한 추적이 일반적.
- 검증 절차는 [`metrics-server/README.md` § 검증 체크리스트](../../metrics-server/README.md).
