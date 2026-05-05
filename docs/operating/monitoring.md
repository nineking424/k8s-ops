# 모니터링

`kube-prometheus-stack`이 무엇을 수집하고, 어디서 보고, 무엇에 알람을 거는지. 외부 노출은 Grafana만 — Prometheus / Alertmanager는 ClusterIP라 port-forward로 접근.

## 진입점

| UI | 접근 방법 | 인증 |
|---|---|---|
| Grafana | `https://grafana.k8s.stjeong.com` (NPM 경유 HTTPS) | `admin` + Secret `kube-prometheus-stack-grafana`의 `admin-password` |
| Prometheus | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090` → `http://localhost:9090` | 없음 (port-forward) |
| Alertmanager | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093` → `http://localhost:9093` | 없음 (port-forward) |

Grafana 비밀번호 출력:

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## 활성 / 비활성 ServiceMonitor

Talos는 일부 cp 컴포넌트의 메트릭을 기본값에서 노출하지 않으므로 차트의 기본 ServiceMonitor 중 일부는 비활성화되어 있다.

| 대상 | ServiceMonitor | 메모 |
|---|---|---|
| kube-apiserver | ✅ 활성 | 그대로 노출됨 |
| kubelet | ✅ 활성 | Talos kubelet이 metrics endpoint 노출 |
| coredns | ✅ 활성 | |
| prometheus-operator / grafana / alertmanager | ✅ 활성 | self-monitoring |
| node-exporter | ✅ 활성 (DaemonSet) | hostNetwork + hostPID, PSA `privileged` ns |
| kube-state-metrics | ✅ 활성 | k8s 객체 상태 메트릭 |
| kube-controller-manager | ❌ 비활성 | Talos 기본값 — 127.0.0.1 바인딩 |
| kube-scheduler | ❌ 비활성 | Talos 기본값 — 127.0.0.1 바인딩 |
| kube-proxy | ❌ 비활성 | Talos는 Flannel + 자체 처리 — kube-proxy ServiceMonitor 안 씀 |
| etcd | ❌ 비활성 | Talos가 etcd metrics를 외부 노출하지 않음 |

활성화하려면 Talos 머신 컨피그를 패치해 해당 컴포넌트의 metrics endpoint를 노출한 뒤, `kube-prometheus-stack/values.yaml`에서 ServiceMonitor를 enable. 본 클러스터에서는 비활성으로 운영(노이즈 회피).

요점: 운영 중 Prometheus targets에 cp 컴포넌트가 `down`으로 보이면 그건 의도된 비활성화 — 실제 다운이 아니라 ServiceMonitor가 잘못 enable된 상태. `kube-prometheus-stack/values.yaml`에서 disable로 되돌린다.

## Prometheus targets 검증

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | map(.health) | unique'
# → ["up"] 만 나와야 정상
```

`down`이 섞여 있으면 `curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health=="down") | .labels.job'`로 어느 job이 죽었는지 본다.

## 기본 대시보드

차트가 자동 등록한 Grafana 대시보드 중 일상에서 자주 보는 것:

| 대시보드 | 용도 |
|---|---|
| Kubernetes / Compute Resources / Cluster | 클러스터 전체 CPU/Memory 추세, namespace 별 사용량 |
| Kubernetes / Compute Resources / Namespace (Pods) | 특정 namespace의 pod별 리소스 |
| Kubernetes / Compute Resources / Node (Pods) | 특정 노드의 pod별 리소스 |
| Node Exporter / Nodes | OS 레벨 (디스크 IO, 네트워크, file descriptor) |
| Kubernetes / API server | apiserver latency / error rate |
| Prometheus / Overview | Prometheus 자체 상태(scrape duration, TSDB 크기) |

새 대시보드는 Grafana → Dashboards → New → Import에서 grafana.com ID로 추가, 또는 ConfigMap에 라벨 박아 자동 sidecar 로드.

## 권장 알람

차트 기본 알람 규칙(`defaultRules.create=true`)이 enable되어 있어 일반적인 알람은 자동. 본 클러스터에서 추가로 의미 있는 알람:

| PromQL (요지) | 임계값 | 의미 → 후속 |
|---|---|---|
| `up{job="kubelet"} == 0` | 5분 지속 | 노드 NotReady → [트러블슈팅 — node가 NotReady](troubleshooting.md#node가-notready로-떨어짐) |
| `kube_persistentvolumeclaim_resource_requests_storage_bytes / kubelet_volume_stats_capacity_bytes > 0.9` | 5분 지속 | PV 90% 초과 사용 → 디스크 압박 → [트러블슈팅 — Prometheus disk full](troubleshooting.md#prometheus가-disk-full)이 같은 패턴 |
| `etcd_server_has_leader == 0` | 1분 지속 | etcd leader 없음 → [런북 §1](runbook.md#1-etcd-쿼럼-손실-진단) |
| `prometheus_tsdb_storage_blocks_loaded == 0` | 5분 지속 | Prometheus 자체 비정상 |
| `histogram_quantile(0.95, rate(nginx_ingress_controller_request_duration_seconds_bucket[5m])) > 1` | 5분 지속 | Ingress 95p latency > 1초 → [트러블슈팅 — Ingress 503](troubleshooting.md#ingress가-503-혹은-default-backend-404를-반환) |

> **위 임계값은 홈랩 운영의 출발점이지 SLO가 아니다.** 실제 트래픽 패턴을 보고 false positive가 잦은 알람은 임계값을 낮추거나 평가 기간을 길게 한다. SLO를 정한 뒤에는 그 문서가 임계값의 권위 있는 사본이 된다.

## 로그 — 별도 컴포넌트로 분리

본 컴포넌트는 메트릭 전용. Loki/Promtail 같은 로깅 스택은 별도 컴포넌트로 분리해 도입할 예정이다. 그때까지는 노드/Pod 로그는 `kubectl logs`와 `talosctl logs`로 직접 본다.

## 알려진 한계

- **cp 컴포넌트 4개 메트릭 부재** — controller-manager / scheduler / proxy / etcd는 Talos 기본값에서 메트릭 미공개. 그쪽이 죽으면 `kube_state_metrics`나 `kubelet`/`apiserver` 쪽 신호로 간접 탐지해야 한다.
- **카디널리티 압박** — 7일 retention + 18GB cap이 홈랩 규모에선 충분하지만, 새 컴포넌트가 라벨 폭증을 유발하면 [트러블슈팅 — Prometheus disk full](troubleshooting.md#prometheus가-disk-full)이 발생한다. ServiceMonitor 추가 시 라벨 카디널리티를 먼저 본다.
- **Alertmanager → 외부 알림 미연결** — 본 클러스터의 Alertmanager는 Slack/Discord/메일 등 외부로 알림을 보내는 receiver가 설정돼 있지 않다. `kube-prometheus-stack/values.yaml`의 `alertmanager.config.receivers`에서 추가.
