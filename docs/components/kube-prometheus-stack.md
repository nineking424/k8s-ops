# kube-prometheus-stack

메트릭 수집 + 시각화 + 알림 스택. Prometheus Operator가 모든 컴포넌트를 관리.

## 역할

| 서브컴포넌트 | 형태 | 책임 |
|---|---|---|
| Prometheus | StatefulSet (PVC 20Gi, retention 7d / 18GB cap) | 시계열 수집·저장 |
| Grafana | Deployment (PVC 5Gi) | 대시보드. 외부 노출은 Grafana만 |
| Alertmanager | StatefulSet (PVC 2Gi) | 알람 라우팅 |
| node-exporter | DaemonSet (5/5) | 노드 OS 메트릭. PSA `privileged` |
| kube-state-metrics | Deployment | k8s 객체 상태 메트릭 |
| Prometheus Operator | Deployment | CRD 기반 컴포넌트 reconcile |

## 위치 / 차트

- 폴더: [`kube-prometheus-stack/`](https://github.com/nineking424/k8s-ops/tree/main/kube-prometheus-stack/) — 권위 있는 install/검증 사본은 그 폴더의 `README.md`.
- 차트: `prometheus-community/kube-prometheus-stack` v84.5.0 (prometheus-operator app v0.90.1)
- Namespace: `monitoring` (자체, **PSA `privileged`** 필수 — node-exporter용)

## 외부 노출

| 서비스 | 접근 |
|---|---|
| Grafana | `https://grafana.k8s.stjeong.com` (NPM HTTPS → ingress-nginx HTTP) |
| Prometheus | ClusterIP — port-forward로 접근 |
| Alertmanager | ClusterIP — port-forward로 접근 |

Grafana `root_url`은 `https://grafana.k8s.stjeong.com`로 박혀 있어 NPM 뒤에서 redirect/링크가 HTTPS로 생성된다.

## 의존

- **NFS SC** (`nfs-client`, default) — Prometheus / Grafana / Alertmanager PVC 모두.
- **MetalLB** — Grafana Ingress가 ingress-nginx LB(`192.168.3.10`)를 통해서 노출.
- **ingress-nginx** — Grafana host 라우팅.
- **외부 NPM** — `grafana.k8s.stjeong.com` 와일드카드 + edge TLS.

## 한계 / 의도적으로 하지 않은 것

- **Loki/Promtail 없음 — 메트릭 전용** — 로깅은 별도 컴포넌트로 분리해 도입 예정.
- **cp 4개 컴포넌트 ServiceMonitor 비활성** — controller-manager / scheduler / proxy / etcd. Talos 기본값에서 메트릭 미공개. 활성화하려면 머신 컨피그 패치 필요. 자세한 분기는 [모니터링 — 활성/비활성 ServiceMonitor](../operating/monitoring.md#활성--비활성-servicemonitor).
- **Prometheus replicas=1** — HA Prometheus는 차트 + Thanos 도입이 필요. 본 단계에서는 단일.
- **Alertmanager → 외부 알림 미연결** — Slack/Discord/메일 receiver 미설정. 알람을 외부로 흘리려면 `values.yaml`의 `alertmanager.config.receivers`에 추가.
- **Default rules / dashboards 그대로** — 차트가 제공하는 알람 규칙과 대시보드를 그대로 쓴다. 클러스터 고유 알람은 별도 PrometheusRule로 추가.

## 연결된 런북 / 트러블슈팅

- [모니터링](../operating/monitoring.md) — 진입점/대시보드/알람 카탈로그.
- [트러블슈팅 — Prometheus가 disk full](../operating/troubleshooting.md#prometheus가-disk-full)
- [트러블슈팅 — Grafana 외부 접속이 안 되거나 redirect가 깨짐](../operating/troubleshooting.md#grafana-외부-접속이-안-되거나-redirect가-깨짐)
- [트러블슈팅 — node-exporter pod이 일부 노드에서 안 뜸](../operating/troubleshooting.md#node-exporter-pod이-일부-노드에서-안-뜸)
- [업그레이드와 롤백 — Helm 차트 업그레이드](../operating/upgrades-and-rollback.md#helm-차트-업그레이드) (CRD 갱신 절차 포함)
- 검증 절차는 [`kube-prometheus-stack/README.md` § 검증 체크리스트](https://github.com/nineking424/k8s-ops/blob/main/kube-prometheus-stack/README.md).
