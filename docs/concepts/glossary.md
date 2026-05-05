# 용어집

본 문서가 영어 그대로 쓰는 용어와 그 정의. 코드/대시보드에서 grep할 때 한국어로 번역하지 않은 채 그대로 등장한다.

## 클러스터 / 노드

**Talos** — Linux 배포판이 아니라 Kubernetes 전용으로 만들어진 minimal OS. 컨테이너 외에는 SSH도, shell도 없고 모든 관리는 `talosctl`로 한다. 본 클러스터는 `v1.13.0`.

**talosconfig** — `talosctl`이 노드 API에 접근할 때 쓰는 클라이언트 인증 파일. 클러스터 전체 권한이 박혀 있어 Git 커밋 절대 금지. 권위 있는 사본은 `pve:~/talos-cluster/_out/talosconfig`.

**machine config** — Talos 노드의 모든 설정(네트워크, 인증서, kubelet args 등)을 담는 단일 YAML. cloud-init은 최초 부팅에만 적용되고, 운영 중 변경은 `talosctl apply-config`로 반영.

**cp** — control plane 노드의 약어. 본 클러스터엔 3대(`talos-cp-01/02/03`).

**wk** — worker 노드의 약어. 본 클러스터엔 2대(`talos-wk-01/02`).

**cluster endpoint** — `kubectl`/`talosctl`이 도달하는 cp의 단일 진입 IP. 본 클러스터에선 cp VIP `192.168.2.100:6443`.

**VIP (Virtual IP)** — 본 문서에서는 Talos native VIP를 가리킨다. cp 3대가 같은 IP를 머신 컨피그에 박아두고 etcd leader election으로 한 대만 보유. fail-over는 자동.

**etcd quorum** — cp 3대 중 2대 이상이 살아 있을 때만 etcd write가 가능. 1대 손실까지는 안전, 2대 손실 시 read-only.

## Proxmox / VM

**Proxmox VE** — 가상화 호스트 OS. `pve`(192.168.1.3)에 모든 Talos VM이 떠 있다.

**snippet** — Proxmox가 cloud-init user-data로 사용하는 YAML 파일. `pve:/var/lib/vz/snippets/`에 두고 VM 생성 시 `qm set --cicustom user=local:snippets/<file>.yaml`로 attach.

**nocloud** — cloud-init의 datasource 형식 중 하나. ISO 부팅이 아니라 이미 박혀 있는 user-data를 읽는 방식. Talos `nocloud-amd64.raw` 디스크 이미지가 이 방식.

**Image Factory** — Talos가 운영하는 [factory.talos.dev](https://factory.talos.dev/) 서비스. 시스템 익스텐션(`siderolabs/qemu-guest-agent` 등)을 포함한 커스텀 이미지를 만들고 schematic ID를 발급. 본 클러스터의 ID는 `03-create-talos-vm.sh`의 `SCHEMATIC_ID` 변수에 박혀 있다.

## 네트워크

**IPAddressPool** — MetalLB가 LB IP를 분배할 풀. 본 클러스터는 `home-pool` = `192.168.3.0/24`.

**L2Advertisement** — IPAddressPool을 L2(ARP/NDP) 모드로 announce하라는 MetalLB CRD. 본 클러스터는 `home-l2`가 `home-pool`만 advertise.

**externalTrafficPolicy=Local** — Service의 트래픽을 받는 노드를 announce된 노드로 한정. 클라이언트 source IP 보존이 가능하지만 announce 노드에 backend pod이 없으면 트래픽이 끊긴다.

**IngressClass** — 어떤 Ingress controller가 이 Ingress를 처리할지 결정하는 식별자. 본 클러스터는 `nginx`가 default — `ingressClassName` 미지정 Ingress도 자동으로 nginx가 처리.

**NPM (nginx proxy manager)** — 클러스터 바깥의 reverse proxy. `*.k8s.stjeong.com` 와일드카드 host로 들어오는 HTTPS를 받아 TLS 종단 후 `192.168.3.10:80`으로 HTTP forward.

## 스토리지

**StorageClass / SC** — 동적 PV 프로비저닝의 정책 묶음(어떤 provisioner / 어떤 reclaim 정책 / 어떤 mount 옵션). 본 클러스터의 default는 `nfs-client`.

**reclaimPolicy** — PVC가 삭제됐을 때 PV를 어떻게 처리할지. 본 클러스터의 `nfs-client`는 `Delete` — NFS 디렉토리도 같이 사라짐.

**archiveOnDelete** — `nfs-subdir-external-provisioner` 고유 옵션. `false`면 PVC 삭제 시 NFS 디렉토리를 정말 지우고, `true`면 `archived-<...>`로 이름만 바꿔 남긴다.

## 관측성

**ServiceMonitor** — Prometheus Operator가 어떤 Service를 scrape할지 결정하는 CRD. 본 클러스터에선 controller-manager / scheduler / proxy / etcd ServiceMonitor가 비활성(Talos가 메트릭 미공개).

**PodMonitor / PrometheusRule** — ServiceMonitor의 Pod 버전 / 알람 규칙 CRD. helm uninstall 시 CRD가 남을 수 있어 다른 컴포넌트가 만든 CR을 깨뜨릴 수 있다.

**PSA (Pod Security Admission)** — namespace 단위 Pod 보안 정책. 본 클러스터의 기본값은 `baseline:latest`. node-exporter / metallb-speaker는 hostNetwork 등을 요구해 `privileged`로 라벨이 박힌 namespace에서만 동작 — `metallb-system`, `monitoring`이 그 대상.

## 컨벤션 / 스크립트

**01 / 02 / 03** — `node-management/0{1,2,3}-*.sh` 세 부트스트랩 스크립트의 약어. 01은 시크릿 발급(절대 재실행 금지), 02는 base snippets 배치(멱등), 03은 노드별 VM 생성.

**values.template.yaml** — Helm `values.yaml`의 시크릿 placeholder 버전. Git 추적 대상. 실제 시크릿이 박힌 `values.yaml`은 `.gitignore`. 자세한 정책은 [시크릿 처리](../developer/secrets.md).
