# FAQ

설계 / 운영 / 마이그레이션 관련 자주 묻는 질문. 답이 5문장을 넘으면 별도 페이지로 빼고 링크한다.

## 설계

### 왜 cert-manager가 없나

외부 NPM(`*.k8s.stjeong.com`)이 edge에서 TLS를 종단하므로 클러스터 안에서 인증서를 발급할 필요가 없다. 클러스터 Ingress는 HTTP만 정의한다. 자세한 모델은 [외부 노출 모델](concepts/external-exposure.md). 향후 mTLS / 내부 서비스 간 TLS가 필요해지면 도입.

### 왜 kube-vip가 아니라 Talos native VIP인가

Talos가 `machine.network.interfaces[].vip`로 etcd 기반 leader election을 내장 — 추가 컴포넌트 없이 cp 한 대가 VIP를 보유하고, 죽으면 즉시 fail-over. kube-vip를 띄우는 것보다 단순하고, 머신 컨피그에 박혀 있어 노드 추가 시 자동 적용된다. 자세한 동작은 [`node-management/node-management-guide.md` § Control Plane VIP 운영](https://github.com/nineking424/k8s-ops/blob/main/node-management/node-management-guide.md#control-plane-vip-운영).

### 왜 GitOps(ArgoCD/Flux)를 안 쓰나

운영자 1명, 컴포넌트 6개 환경에서 수동 `helm upgrade --install` / `kubectl apply` + git 커밋이 더 간단하고 변경 추적도 충분하다. 컴포넌트가 늘거나 여러 명이 만지게 되면 도입을 검토 — `<component>/` 폴더 컨벤션이 그대로 ArgoCD `Application` / Flux `Kustomization`에 매핑되도록 [컴포넌트 추가 컨벤션](developer/contributing.md)을 잡아두었다.

### 왜 `nfs-client` 하나가 default인가

홈랩 단일 NAS(`nknas`)에 export 하나(`/volume1/nfsvolume`)뿐이라 SC를 여러 개로 나눌 이점이 없다. 모든 PVC가 같은 NFS export 하위 디렉토리로 분리된다. 분산 블록 스토리지(Longhorn / Rook-Ceph)가 필요해지면 그때 두 번째 SC를 도입.

## 운영

### kubectl이 갑자기 끊겼다

[트러블슈팅 — kubectl이 먹통](operating/troubleshooting.md#kubectl이-먹통--vip-fail-over-중) 참고. cp VIP fail-over는 보통 수 초 안에 끝나므로 즉시 재시도해본다. 30초 이상 끊기면 [런북 §1](operating/runbook.md#1-etcd-쿼럼-손실-진단)으로.

### NFS 디렉토리에 직접 접근하고 싶다

NAS `nknas`(192.168.1.4)의 `/volume1/nfsvolume` 아래에 `<namespace>-<pvc-name>-<pv-name>/` 디렉토리가 PVC마다 만들어진다. NAS 측 쉘이나 SMB 공유로 직접 접근 가능. `archiveOnDelete=false`이므로 PVC를 삭제하면 디렉토리도 함께 사라진다 — 백업이 필요하면 NAS 레벨에서.

### Grafana 비밀번호를 잊어버렸다

```bash
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

차트가 자동 생성한 비밀번호가 Secret에 박혀 있다.

## 마이그레이션 / 변경

### Talos를 v1.13.x → v1.14.x로 올리려면

[운영 — 업그레이드와 롤백 § Talos OS](operating/upgrades-and-rollback.md#talos-os-업그레이드)와 [런북 §4](operating/runbook.md#4-talos-os-업그레이드)를 따른다. cp는 한 번에 한 대씩, etcd 쿼럼 유지하며 순차 진행. 업그레이드 후 `kubectl get nodes`에서 `Ready` 확인.

### 컴포넌트를 통째로 제거하면 데이터는?

`reclaimPolicy=Delete`이므로 PVC 삭제 시 NFS 디렉토리도 함께 사라진다. 데이터 보존이 필요하면 (1) `helm uninstall` 전에 PVC를 다른 SC로 옮기거나, (2) NAS에서 디렉토리를 따로 백업하거나, (3) PV를 `Retain`으로 패치한다. CRD가 있는 차트(kube-prometheus-stack)는 helm uninstall 시 CRD가 남아 있을 수 있어 의존 CR을 먼저 점검.

### 외부 도메인을 `*.k8s.stjeong.com`이 아닌 다른 와일드카드로 바꾸려면

NPM 측 와일드카드 host 매핑과 클러스터 측 Ingress의 host를 같이 바꿔야 한다. `kube-prometheus-stack/values.yaml`의 `grafana.ingress.hosts[0]`와 `grafana.grafana.ini.server.root_url`을 수정 → `helm upgrade -f values.yaml`. 신규 도메인이 동작하면 NPM에서 옛 매핑 해제.

### NPM 없이 클러스터가 직접 TLS를 종단하려면

cert-manager + ClusterIssuer(Let's Encrypt 등) 도입 후 각 Ingress에 `tls:` 섹션과 인증서 어노테이션을 추가, NPM의 와일드카드 host를 해제한다. ACME HTTP-01은 ingress-nginx로 처리 가능하지만 TLS 종단점이 NPM에서 ingress-nginx로 이동하므로 외부 라우팅 검증이 필요. 단일 운영자 환경에서는 NPM이 더 단순.
