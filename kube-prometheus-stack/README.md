# kube-prometheus-stack

홈랩 클러스터(`talos-homelab`)의 메트릭 수집 + 시각화 + 알림 스택. Prometheus Operator가 모든 컴포넌트를 관리.

## 무엇 / 왜

- **포함**: Prometheus(시계열 DB + 스크레이퍼), Grafana(대시보드), Alertmanager(알림 라우팅), node-exporter(DaemonSet, 노드 OS 메트릭), kube-state-metrics(Deployment, k8s 객체 상태 메트릭), Prometheus Operator(CRD 기반 컴포넌트 관리), 기본 알림 규칙 + 기본 대시보드.
- **외부 노출**: Grafana만 Ingress(`grafana.k8s.stjeong.com`, HTTP). 외부 nginx proxy manager(NPM)가 `*.k8s.stjeong.com → 192.168.3.10:80`을 사전 forward + TLS 종단하므로 클러스터 측은 HTTP Ingress만으로 충분. Prometheus/Alertmanager는 ClusterIP — 보안 단순화 + 일상 사용은 Grafana에서.
- **의존성(클러스터 내)**: `nfs-client` SC(default), MetalLB(LB IP), ingress-nginx(IngressClass `nginx`). 모두 본 플랜의 사전 단계로 도입 완료.
- **의존성(외부)**: NPM 와일드카드 host (`*.k8s.stjeong.com`) 사전 구성. 본 컴포넌트 측에서 NPM 추가 설정 불필요.
- **로깅(Loki/Promtail)은 별도 컴포넌트**로 분리해 도입 예정 — 본 디렉터리는 메트릭 전용.

## 설치

```bash
./install.sh
```

내부적으로:
1. `monitoring` ns 생성 + `pod-security.kubernetes.io/{enforce,audit,warn}=privileged` 라벨
2. `helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n monitoring -f values.yaml --version 84.5.0 --wait --timeout 10m`
3. `kube-prometheus-stack-operator`, `kube-prometheus-stack-grafana` rollout 대기

차트 버전: `84.5.0` (app prometheus-operator `v0.90.1`). 변경 시 `install.sh` 상단의 `CHART_VERSION` 수정 + 본 README의 차트/앱 버전 갱신.

## 핵심 설정

| 항목 | 값 | 메모 |
|---|---|---|
| Namespace | `monitoring` | PSA: `privileged` (node-exporter용) |
| StorageClass | `nfs-client` (default) | nknas(192.168.1.4) NFS export |
| Prometheus retention | 7d / 18GB cap (PVC 20Gi) | 홈랩 규모에 충분 |
| Alertmanager PVC | 2Gi | |
| Grafana PVC | 5Gi | dashboards/JSON 보존 |
| Grafana Ingress | host `grafana.k8s.stjeong.com`, HTTP | 외부는 NPM 경유 `https://grafana.k8s.stjeong.com` |
| Grafana `root_url` | `https://grafana.k8s.stjeong.com` | NPM 뒤 redirect/링크가 HTTPS로 생성되도록 |
| Grafana admin user | `admin` | password는 차트 자동 생성 → Secret |
| 비활성 ServiceMonitor | kube-controller-manager / kube-scheduler / kube-proxy / etcd | Talos 기본값에서 메트릭 미공개. 활성화하려면 Talos machine config 패치 필요 |
| 활성 ServiceMonitor | kube-apiserver / kubelet / coredns | Talos에서 그대로 노출됨 |
| node-exporter | DaemonSet, 5/5 (cp 3 + wk 2) | hostNetwork + hostPID |
| Default rules | enabled | 차트 제공 알림 규칙 set |
| Default dashboards | enabled | Grafana에 자동 등록 |

> **PodSecurity:** node-exporter는 `hostNetwork=true`, `hostPID=true`, hostPath 마운트를 요구해 클러스터 기본값 `baseline:latest`에선 차단됨. `install.sh`가 `monitoring` 네임스페이스에 `pod-security.kubernetes.io/{enforce,audit,warn}=privileged` 라벨을 자동으로 박는다. 차트가 만든 ns를 그대로 쓰면 차단되므로 install.sh 흐름을 우회하지 말 것.

> **외부 노출 / TLS:** 외부 NPM이 `*.k8s.stjeong.com` 와일드카드를 받아 ingress-nginx LB(`192.168.3.10:80`)로 HTTP forward + edge TLS 종단. 클러스터 Ingress는 HTTP만 정의(`tls:` 섹션 없음). 새 호스트(`<svc>.k8s.stjeong.com`)는 NPM 추가 설정 없이 즉시 사용 가능. cert-manager는 본 컴포넌트에 불필요.

## 한계 / 의도적으로 하지 않은 것

- **Loki / Promtail 없음 — 메트릭 전용** — 로깅 스택은 별도 컴포넌트로 분리 도입 예정.
- **cp 4개 ServiceMonitor 비활성** — controller-manager / scheduler / proxy / etcd. Talos 기본값에서 메트릭 미공개. 활성화하려면 머신 컨피그 패치 필요.
- **Prometheus replicas=1** — HA Prometheus는 차트 + Thanos 도입이 별도 필요. 본 단계에서는 단일 인스턴스.
- **Alertmanager → 외부 알림 미연결** — Slack/Discord/메일 receiver 미설정. 알람을 외부로 흘리려면 `values.yaml`의 `alertmanager.config.receivers`에 추가.
- **Default rules / dashboards 그대로** — 차트 제공 알림 규칙과 대시보드를 그대로 사용. 클러스터 고유 알람은 별도 PrometheusRule로 추가.
- **Grafana DB는 SQLite (PVC 5Gi)** — 외부 RDB(MySQL/Postgres) 연결 안 함. 단일 운영자 환경에서는 충분.

## 연결된 런북 / 트러블슈팅

- [모니터링](../docs/operating/monitoring.md) — 진입점/대시보드/알람 카탈로그.
- [트러블슈팅 — Prometheus가 disk full](../docs/operating/troubleshooting.md#prometheus가-disk-full)
- [트러블슈팅 — Grafana 외부 접속이 안 되거나 redirect가 깨짐](../docs/operating/troubleshooting.md#grafana-외부-접속이-안-되거나-redirect가-깨짐)
- [트러블슈팅 — node-exporter pod이 일부 노드에서 안 뜸](../docs/operating/troubleshooting.md#node-exporter-pod이-일부-노드에서-안-뜸)
- [업그레이드와 롤백 — Helm 차트 업그레이드](../docs/operating/upgrades-and-rollback.md#helm-차트-업그레이드) — CRD 갱신 절차 포함.

## Grafana 접속

```bash
# admin 비밀번호 확인
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo

# 브라우저 (외부 NPM 경유 HTTPS)
open https://grafana.k8s.stjeong.com
# user: admin / password: 위에서 출력된 값

# 클러스터 측만 빠르게 확인하려면 Host 헤더 박아 직접 호출:
curl -sI -H 'Host: grafana.k8s.stjeong.com' http://192.168.3.10/login
```

## Prometheus / Alertmanager 접속 (port-forward)

```bash
# Prometheus UI
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090

# Alertmanager UI
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093
# → http://localhost:9093
```

## 검증 체크리스트

- [ ] `kubectl get pods -n monitoring` — 모두 Running
  - prometheus-kube-prometheus-stack-prometheus-0 (2/2)
  - alertmanager-kube-prometheus-stack-alertmanager-0 (2/2)
  - kube-prometheus-stack-operator-* (1/1)
  - kube-prometheus-stack-grafana-* (3/3)
  - kube-prometheus-stack-kube-state-metrics-* (1/1)
  - kube-prometheus-stack-prometheus-node-exporter-* (1/1, 노드 수만큼 = 5)
- [ ] `kubectl get pvc -n monitoring` — 3개(Prometheus 20Gi, Alertmanager 2Gi, Grafana 5Gi) 전부 Bound
- [ ] `kubectl get ingress -n monitoring` — `kube-prometheus-stack-grafana` HOSTS=`grafana.k8s.stjeong.com`, ADDRESS=`192.168.3.10`
- [ ] `curl -sI -H 'Host: grafana.k8s.stjeong.com' http://192.168.3.10/login` — `HTTP/1.1 200 OK` (클러스터 측)
- [ ] `curl -sI https://grafana.k8s.stjeong.com/login` — `HTTP/2 200` + Grafana cookie + 정상 cert chain (외부 NPM 경유)
- [ ] Prometheus targets: port-forward 후 `curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | map(.health) | unique'` → `["up"]`만 있어야(있을 수 있는 다른 값: 비활성화한 cp 컴포넌트가 잘못 enable됐거나 RBAC 누락 시 `down`)
- [ ] `kubectl get servicemonitor -n monitoring` — 활성화한 SM(api-server, kubelet, coredns, prometheus-operator, grafana, alertmanager 등) 보임
- [ ] Grafana 로그인 후 Dashboards → Browse → "Kubernetes / Compute Resources / Cluster" 등 기본 대시보드에 데이터 표시

## 트러블슈팅

- **Pod이 PSA로 거부됨 (`violates PodSecurity baseline`)**: `monitoring` ns 라벨 확인 — `kubectl get ns monitoring -o yaml | grep pod-security`. 누락이면 `install.sh` 재실행 또는 수동 `kubectl label ns monitoring pod-security.kubernetes.io/enforce=privileged --overwrite`.
- **PVC가 Pending**: `kubectl describe pvc -n monitoring <name>` — provisioner 에러 확인. NFS provisioner 상태: `kubectl get pods -n nfs-system`(혹은 도입 시 사용한 ns).
- **Grafana ingress가 404 (nginx default backend)**: `kubectl get ingress -n monitoring kube-prometheus-stack-grafana -o yaml`에서 host가 `grafana.k8s.stjeong.com`로 정확한지, IngressClass가 `nginx`인지 확인. host가 다르면 `Host:` 헤더와 일치해야 함.
- **외부에서 https://grafana.k8s.stjeong.com 접속이 안 됨**: NPM 측 와일드카드 host 동작 점검. `curl -v https://probe.k8s.stjeong.com/`로 NPM → ingress-nginx 경로가 살아있는지 먼저 확인. 클러스터 측만 정상이면 NPM 설정 점검을 사용자에게 요청.
- **Grafana 로그인 후 redirect가 http://로 떨어짐**: `grafana.ini.server.root_url`이 `https://grafana.k8s.stjeong.com`로 박혀있는지 — `kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- cat /etc/grafana/grafana.ini | grep root_url`. 미설정이면 values.yaml에서 추가.
- **Prometheus targets에서 cp 컴포넌트가 down**: 의도. Talos 기본값에서 controller-manager/scheduler/etcd metrics는 127.0.0.1 바인딩. values.yaml에서 disable되어 있어야 함.
- **Helm upgrade 후 CRD가 갱신 안 됨**: kube-prometheus-stack은 helm install 시 CRD를 박지만, `helm upgrade`는 기본적으로 CRD를 갱신하지 않음. 차트 버전을 메이저 단위로 올릴 때는 차트 저장소의 [Upgrading Chart 절차](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack#upgrading-chart)를 따라 CRD를 먼저 수동 적용한 뒤 helm upgrade. 직접 적용 시에는 `https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack/charts/crds/crds`에서 각 CRD 파일을 개별 URL로 `kubectl apply --server-side -f <url>` 방식으로.
- **node-exporter pod이 일부 노드에서 안 뜸**: `kubectl describe ds -n monitoring kube-prometheus-stack-prometheus-node-exporter`로 toleration 확인. 차트 기본값이 모든 taint를 tolerate하므로 보통 cp/worker 모두 뜸. 안 뜨면 노드 상태나 PSA 라벨 점검.

## 제거

```bash
helm uninstall kube-prometheus-stack -n monitoring

# CRD는 남아 있을 수 있음. 다른 컴포넌트가 ServiceMonitor/PrometheusRule을 만들어 두지 않았다면 삭제 가능:
kubectl get crd | grep monitoring.coreos.com
# kubectl delete crd <목록>      # 필요 시

# PVC는 namespace 삭제 시 함께 사라짐(NFS subdir provisioner는 reclaim=Delete + archiveOnDelete=false)
kubectl delete ns monitoring
```

> **CRD 삭제 주의:** 의존하는 다른 컴포넌트(예: cert-manager, ingress-nginx 자체 metrics용 ServiceMonitor 등)가 CRD를 사용 중이면 그들의 CR이 통째로 사라질 수 있다. 제거 전 `kubectl get servicemonitor,podmonitor,prometheusrule -A` 로 의존성 확인.
