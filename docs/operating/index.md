# 운영

런북, 트러블슈팅, 모니터링, 스케일링, 업그레이드. 운영자가 한 사이클을 도는 동안 필요한 모든 페이지가 여기 있다.

- [런북](runbook.md) — 사고 대응 절차 모음. 번호 매겨진 §1–§10으로 [트러블슈팅](troubleshooting.md)에서 점프.
- [트러블슈팅](troubleshooting.md) — 증상 → 원인 → 진단 한 줄 → 조치 → 확인 매트릭스.
- [모니터링](monitoring.md) — Prometheus 활성/비활성 ServiceMonitor, Grafana 기본 대시보드, 권장 알람.
- [스케일링](scaling.md) — 노드 추가 vs replicaCount, 컴포넌트별 한계.
- [업그레이드와 롤백](upgrades-and-rollback.md) — Talos OS / Kubernetes / helm 차트 업그레이드 흐름과 롤백 가능성.

깊은 부트스트랩 절차는 [`node-management/node-management-guide.md`](https://github.com/nineking424/k8s-ops/blob/main/node-management/node-management-guide.md)에 그대로 둔다 — 본 섹션은 부트스트랩 이후 운영을 다룬다.
