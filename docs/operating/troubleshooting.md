# 트러블슈팅

증상 → 원인 → 진단 → 조치 → 확인 매트릭스. 각 항목에 진단용 한 줄이 들어 있고, 깊은 절차는 [런북 §1–§10](runbook.md)으로 점프한다.

## kubectl이 먹통 — VIP fail-over 중

**원인.** cp VIP 보유자가 죽거나 reboot 중이라 다른 cp가 VIP를 이어받는 사이 `192.168.2.100:6443` 응답이 잠깐 끊긴다. 보통 수 초 안에 복구.

**진단.**

```bash
curl -sk --max-time 3 https://192.168.2.100:6443/livez && echo OK || echo DOWN
```

`OK`이면 정상 — 클라이언트 측 문제(인증서/네트워크). `DOWN`이 30초 이상 지속되면 VIP fail-over로 설명되지 않는 상황.

**조치.** 수 초 안에 자연 복구되면 무시. 30초 이상 끊기면 cp 도달성과 etcd 멤버 상태를 [런북 §1](runbook.md#1-etcd-쿼럼-손실-진단)으로 확인.

**확인.** `kubectl get nodes`가 응답하고 모든 cp가 `Ready`. VIP 보유자가 한 cp에 박혀 있음(VIP 식별 명령은 [런북 §2](runbook.md#2-cp-vip-fail-over-검증)).

## PVC가 Pending에서 안 넘어감

**원인.** NFS provisioner가 PV를 만들지 못하고 있다 — provisioner pod 다운, NFS NAS 도달 실패, NAS export 권한 누락 중 하나.

**진단.**

```bash
kubectl describe pvc -n <ns> <pvc> | tail -20
```

`Events:` 마지막 줄이 진단의 yes/no 신호 — `Provisioning failed: ...` 메시지에서 원인이 잡힌다. provisioner pod 자체가 죽어 있다면 `kubectl get pods -n nfs-subdir-external-provisioner`도 같이 본다.

**조치.** Events 메시지가 NAS 권한/도달 문제면 [런북 §7 NFS 마운트 장애](runbook.md#7-nfs-마운트-장애)로. provisioner pod이 죽어 있으면 `kubectl rollout restart deploy -n nfs-subdir-external-provisioner ...`로 재시작.

**확인.** `kubectl get pvc -n <ns> <pvc>`가 `Bound`로 전이.

## LoadBalancer Service의 EXTERNAL-IP가 `<pending>`

**원인.** MetalLB가 IP를 할당하지 못하고 있다 — IPAddressPool 부재/IP 풀 소진, controller 다운, L2Advertisement 누락 중 하나.

**진단.**

```bash
kubectl describe svc <svc> -n <ns> | grep -A 5 Events
```

Events에 `no available IPs in pool ...` 또는 `controller not running`이 보이면 원인이 갈린다. controller 상태도 같이 확인하려면:

```bash
kubectl get pods -n metallb-system
```

**조치.** IPAddressPool/L2Advertisement이 살아 있는지 확인 — `kubectl get ipaddresspool,l2advertisement -n metallb-system`. 풀 소진이면 안 쓰는 LB Service를 정리하거나 `home-pool`을 더 큰 대역으로 확장. controller가 죽어 있으면 `kubectl rollout restart deploy -n metallb-system metallb-controller`.

**확인.** `kubectl get svc <svc> -n <ns>`의 `EXTERNAL-IP`가 `192.168.3.x`로 채워짐. `kubectl get events -n <ns> --sort-by=.lastTimestamp | tail`에 `assigned IP "192.168.3.x"` 표시.

## EXTERNAL-IP는 할당됐는데 외부에서 접속 안 됨

**원인.** L2 announce가 들리지 않거나(speaker 문제), 라우터/스위치가 ARP probe를 막거나, `externalTrafficPolicy=Local`인데 announce된 노드에 backend pod이 없는 경우.

**진단.**

```bash
ssh pve "arping -c 3 -I vmbr0 <EXTERNAL_IP>"
```

응답이 오면 L2까지는 정상 — backend pod 라우팅 문제. 응답이 없으면 speaker/L2 문제.

**조치.** speaker 로그 확인:
```bash
kubectl logs -n metallb-system -l app.kubernetes.io/component=speaker --tail=50
```
ingress-nginx의 경우 `replicas=2 + anti-affinity`로 wk-01/wk-02에 분산되어 있어 한 worker 죽어도 정상 — 두 대 모두 죽었으면 [트러블슈팅 — Ingress 502](#ingress가-503-혹은-default-backend-404를-반환)로.

**확인.** `curl -sI http://<EXTERNAL_IP>/`가 응답.

## Ingress가 503 혹은 default backend 404를 반환

**원인.** Ingress 리소스가 잘못 만들어졌거나, host가 안 맞거나, backend Service가 죽었거나 셋 중 하나.

**진단.**

```bash
kubectl get ingress -A -o wide | grep <hostname>
```

Ingress가 보여야 정상. 안 보이면 만들어지지 않은 것 — 매니페스트 재적용. 보이지만 `ADDRESS`가 비어 있으면 admission webhook reject — controller 로그 확인.

**조치.**

- Ingress가 reject됐으면:
  ```bash
  kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=50
  ```
  잘못된 annotation이나 중복 host가 흔한 원인.
- backend Service가 죽었으면 `kubectl get pods -n <ns> -l <selector>`로 확인.
- host가 안 맞으면(NPM이 박는 `Host` 헤더 vs Ingress의 `host:` 다름) Ingress의 host를 NPM 매핑과 일치시킨다.

**확인.** `curl -sI -H 'Host: <hostname>' http://192.168.3.10/<path>`가 `200`.

## Grafana 외부 접속이 안 되거나 redirect가 깨짐

**원인.** 두 갈래 — (1) NPM 측 와일드카드 host가 죽었거나, (2) Grafana `root_url`이 `http://`로 박혀 NPM 뒤 HTTPS와 어긋나 redirect가 깨진 경우.

**진단.**

```bash
# 클러스터 측 (NPM 우회)
curl -sI -H 'Host: grafana.k8s.stjeong.com' http://192.168.3.10/login
```

`200 OK`이면 클러스터 정상 → NPM 측 문제. 클러스터에서도 안 되면 ingress 또는 Grafana pod 문제.

**조치.**

- 클러스터 측이 정상이면 [런북 §8 외부 NPM 다운](runbook.md#8-외부-npm-다운)으로.
- redirect가 `http://`로 떨어지면 `root_url` 확인:
  ```bash
  kubectl -n monitoring exec deploy/kube-prometheus-stack-grafana -c grafana -- \
    cat /etc/grafana/grafana.ini | grep root_url
  ```
  `https://grafana.k8s.stjeong.com`로 박혀 있어야 한다. 미설정이면 `kube-prometheus-stack/values.yaml`의 `grafana.grafana.ini.server.root_url`을 추가하고 `helm upgrade -f values.yaml`.

**확인.** `curl -sI https://grafana.k8s.stjeong.com/login`이 `200` + 정상 cert chain. 로그인 후 redirect 경로가 모두 `https://`.

## etcd member가 NotReady / unstarted

**원인.** cp 노드 한 대의 etcd가 raft에 다시 join하지 못하고 있다 — 디스크 IO 지연, 시간 동기화 어긋남, 멤버 ID 불일치 중 하나.

**진단.**

```bash
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
  --nodes <ANY_LIVE_CP_IP> etcd members"
```

각 멤버의 `STATE` 확인. `LEARNER`나 `STARTED`가 정상, `STARTED`가 아닌 멤버가 문제 노드.

**조치.** 노드의 talosctl 로그:
```bash
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
  --nodes <PROBLEM_CP_IP> logs etcd"
```
시간 동기화는 `talosctl --nodes <IP> get timesync` — 어긋났으면 NTP 서버 도달성 점검. 멤버가 영구히 깨진 경우 [런북 §3 노드 추가/제거](runbook.md#3-노드-추가--제거)로 제거 후 재추가.

**확인.** `etcd members`에서 모든 cp가 `STARTED`. `talosctl --nodes <IP> health`가 `etcd: HEALTHY`.

## NFS PVC가 mount 실패 / 읽기·쓰기 IOhang

**원인.** NAS 측 장애, 노드와 NAS 간 네트워크 단절, NFS 옵션 호환성(v3 vs v4) 중 하나.

**진단.**

```bash
ssh pve "ping -c 3 192.168.1.4"
```

도달 안 되면 네트워크 문제. 도달은 되는데 mount가 안 되면 NAS export 권한 / NFS 데몬 상태.

**조치.**

- 네트워크 문제면 라우터/스위치 점검 (본 프로젝트 외부).
- NAS 권한 문제면 NAS 관리도구에서 `*` 또는 `192.168.0.0/16` 허용 확인.
- v4 호환 문제면 `nfs-subdir-external-provisioner/values.yaml`의 `nfs.mountOptions`를 `nfsvers=4.1,nolock`로 바꾸고 `helm upgrade -f values.yaml` (NAS에서 v4가 활성화돼 있어야 함).
- 자세한 절차는 [런북 §7 NFS 마운트 장애](runbook.md#7-nfs-마운트-장애).

**확인.** 시험 PVC가 30초 안에 Bound:
```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: nfs-test, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
YAML
kubectl get pvc nfs-test -w
kubectl delete pvc nfs-test
```

## Prometheus가 disk full

**원인.** Prometheus 시계열이 PV(20Gi) 용량을 채웠다. `retention`(현재 7d)이나 `retentionSize`(현재 18GB cap)에 도달하면 자동으로 오래된 블록이 삭제되어야 하지만, 카디널리티 폭증이나 chunk 손상으로 정리가 늦어질 수 있다.

**진단.**

```bash
kubectl exec -n monitoring statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  df -h /prometheus
```

`Use%`가 95% 이상이면 거의 가득 찬 상태. carduality 폭증은:
```bash
kubectl exec -n monitoring statefulset/prometheus-kube-prometheus-stack-prometheus -- \
  promtool tsdb analyze /prometheus 2>/dev/null | head -30
```

**조치.** 즉시 압박 해소: `retention`을 임시로 줄이고 helm upgrade — `kube-prometheus-stack/values.yaml`의 `prometheus.prometheusSpec.retention`을 예 `3d`로 → `helm upgrade -f values.yaml`. 카디널리티 원인을 찾아 ServiceMonitor의 `metricRelabelings`로 라벨을 정리. 디스크 자체를 키우려면 PVC `resources.requests.storage` 변경 후 PV expand(SC가 `allowVolumeExpansion=true`).

**확인.** `df -h /prometheus`의 `Use%`가 80% 이하로 내려옴. `up{job=...}` 메트릭이 시간이 지나도 지속 수집됨.

## node-exporter pod이 일부 노드에서 안 뜸

**원인.** 노드 자체 문제(NotReady / cordon)거나, namespace PSA 라벨 누락이거나, taint 호환성 문제.

**진단.**

```bash
kubectl describe ds -n monitoring kube-prometheus-stack-prometheus-node-exporter | tail -30
```

`Events`에서 `FailedCreate: pods ... is forbidden: violates PodSecurity` 같은 메시지가 보이면 PSA 문제. 노드 자체가 NotReady면 `kubectl get nodes`에서 잡힌다.

**조치.** PSA 누락이면:
```bash
kubectl label ns monitoring \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged --overwrite
```
혹은 `kube-prometheus-stack/install.sh` 재실행 — install.sh가 라벨을 자동으로 박는다. 노드 NotReady면 [트러블슈팅 — node가 NotReady](#node가-notready로-떨어짐)로.

**확인.** `kubectl get pods -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter -o wide`가 노드 수만큼(현재 5) Running.

## node가 NotReady로 떨어짐

**원인.** 노드 자체 다운 / kubelet 멈춤 / 네트워크 단절 / Talos 서비스 멈춤 중 하나.

**진단.**

```bash
ssh pve "talosctl --talosconfig ~/talos-cluster/_out/talosconfig \
  --nodes <NODE_IP> services" 2>&1 | head -20
```

응답이 오면 talos apid가 살아 있다 — kubelet/CNI 문제. 응답이 없으면 노드 자체 다운.

**조치.**

- 노드 자체 다운(ping도 안 됨): Proxmox에서 VM 상태 확인 — `ssh pve "qm status <VMID>"`. 죽었으면 `qm start`.
- talos는 살았는데 kubelet 문제: `talosctl --nodes <NODE_IP> logs kubelet`로 로그 확인.
- 회복이 안 되면 노드를 통째로 재부팅: `talosctl --nodes <NODE_IP> reboot`.
- 그래도 안 되면 [런북 §3 노드 추가/제거](runbook.md#3-노드-추가--제거)로 교체.

**확인.** `kubectl get nodes`에서 해당 노드가 `Ready`. 노드 위 워크로드의 pod이 모두 Running으로 돌아옴.

## 알려진 한계

- **클러스터가 read-only로 떨어진 경우**(etcd 쿼럼 손실)에는 본 페이지의 진단 한 줄이 응답하지 않을 수 있다 — 대부분 명령이 kube-apiserver를 거치기 때문. 그 시점부터는 [런북 §1](runbook.md#1-etcd-쿼럼-손실-진단)의 talosctl 직접 명령만 동작한다.
- **외부 NPM 측 장애**는 본 페이지로 진단할 수 없다 — 클러스터 안에서 보면 모든 게 정상으로 보이고 외부 진입만 끊긴다. NPM 호스트의 운영은 본 프로젝트 범위 밖.
