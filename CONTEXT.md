# talos-homelab

Proxmox 위에 Talos 로 올린 홈랩 Kubernetes 클러스터와, 그것을 떠받치는 홈랩 인프라 전체를 다루는 컨텍스트다. `k8s-ops` 저장소는 이 인프라의 일부(코어 컴포넌트와 노드 프로비저닝)를 형상관리한다.

이 문서는 **용어집이다.** 절차·명령·런북은 [GitHub Wiki](https://github.com/nineking424/k8s-ops/wiki), 저장소를 만질 때의 규칙은 `CLAUDE.md` 에 있다. 여기에는 **정의만** 둔다 — 혼동이 실제 사고로 이어진 적이 있는 축을 못 박는 것이 목적이다.

## 호스트 층

**pve**:
Proxmox 주 호스트(`192.168.1.3`). Talos VM 5대(cp-02, cp-03, wk-01/02/03)가 여기서 돈다. 자체 하드웨어 워치독으로 자가복구가 불가능한 보드다.
_Avoid_: "Proxmox 호스트"(호스트가 둘이라 어느 쪽인지 지칭이 안 된다)

**pve-main**:
Proxmox 호스트(`192.168.1.6`). `talos-cp-01`(VMID 106) **한 대만** 여기서 돈다. 2026-05-24 pve 전신 프리즈 사고 이후 control plane 을 두 호스트에 분산한 결과이며, pve 가 통째로 죽어도 etcd 멤버 하나는 살아남게 하는 것이 목적이다.

**pve-mini**:
Proxmox 호스트(`192.168.1.5`). **이 클러스터와 무관하다.** 이름이 비슷해 pve/pve-main 과 혼동되므로 여기 적어 둔다.

**nknas**:
NAS(`192.168.1.4`), export `/volume1/nfsvolume`. 클러스터의 **모든 PersistentVolume 의 실제 저장소**다.

**NPM**:
클러스터 **밖**에서 도는 nginx proxy manager. `*.k8s.stjeong.com` 와일드카드를 받아 `192.168.3.10:80` 으로 평문 forward 하고 **TLS 를 종단**한다. 클러스터 안에는 인증서가 존재하지 않으며, 그래서 cert-manager 가 없다.
_Avoid_: "리버스 프록시"(클러스터 안의 ingress-nginx 도 리버스 프록시라 겹친다)

**Tapo**:
스마트플러그 P110(`192.168.150.226`, 레이블 "Main Rack"). pve 의 **전원 그 자체**다. 클러스터 외 운영도구가 이것을 끊어 pve 를 강제 재부팅한다.

**nkmini**:
맥(`192.168.1.7`, `nkmini.local`). Proxmox 가 아니라 **클러스터 밖의 상시 가동 맥**이며, 여기를 경유하는 상시 SSH 터널이 kubectl 의 `talos-tunnel` context 를 떠받친다. `~/.ssh/config` 에 별칭이 없어 IP 로만 등장한다.
_Avoid_: pve-mini(`192.168.1.5`)와 혼동. 전혀 다른 장비다.

## 노드 층

**talos-homelab**:
클러스터 이름. kubectl context 는 **둘**이며 둘 다 같은 클러스터를 가리킨다 — `admin@talos-homelab` 은 VIP 로 직접(`https://192.168.2.100:6443`), `talos-tunnel` 은 nkmini 를 경유하는 상시 SSH 터널로(`https://localhost:16443`) 붙는다. **현재 활성은 `talos-tunnel`** 이다. LAN 안에서는 둘 다 동작하므로, 어느 쪽이 활성인지 모른 채 명령이 성공하면 경로를 착각하기 쉽다.

**cp / wk**:
노드 역할. cp 는 control plane(`talos-cp-01..03`, `192.168.2.106..108`), wk 는 worker(`talos-wk-01..03`, `192.168.2.111..113`). `03-create-talos-vm.sh` 의 4번째 인자가 이 역할이며, cp 일 때만 VIP 블록이 자동 삽입된다.

**VIP**:
`192.168.2.100`. Talos native VIP 로, cp 한 대가 etcd leader election 으로 보유하고 장애 시 자동 fail-over 한다. 클러스터 API 의 **단일 주소**이며, 개별 cp 노드 IP 로 붙지 않는다(`talos-tunnel` context 도 결국 이 주소로 포워딩된다).
_Avoid_: 스크립트마다 이름이 다르지만 `CLUSTER_VIP`(01), `CP_VIP`(03), 머신컨피그의 `vip.ip`, 문서의 "cluster endpoint" 는 **전부 이 하나**를 가리킨다. 서로 다른 것으로 읽지 말 것.

**노드 대역 / LB 풀**:
노드 대역은 `192.168.2.x`(노드 IP 와 VIP), MetalLB 풀은 `192.168.3.0/24`(서비스에 할당되는 LoadBalancer IP, ingress 는 `192.168.3.10`). 겹치면 ARP 가 충돌하므로 분리한 것이며, 둘 다 `192.168.0.0/16` 단일 서브넷 안에 있다. 노드 마스크가 `/24` 가 아니라 **`/16`** 인 이유가 이것이다.

**snippets**:
`pve:/var/lib/vz/snippets/` 의 cloud-init user-data. 두 종류가 있다 — `_talos-{cp,wk}-base.yaml` 은 `02` 가 배치하는 역할별 **base**, `<VM_NAME>-user.yaml` 은 `03` 이 base 에서 만드는 **노드별 인스턴스**다. cloud-init 은 최초 부팅에만 동작하므로, 운영 중 노드의 설정을 바꾸려면 user.yaml 을 고친 뒤 `talosctl apply-config` 로 따로 반영해야 한다. **파일을 고쳤다고 노드에 반영되지 않는다.**

**factory installer**:
`factory.talos.dev/installer/<SCHEMATIC_ID>:<version>` 형태의 설치 이미지. 이 클러스터의 schematic(`ce4c9805...7515`)은 `siderolabs/qemu-guest-agent` 익스텐션을 포함한다. 업그레이드 시 vanilla `ghcr.io/siderolabs/installer` 를 쓰면 **익스텐션이 소실**되므로 반드시 factory 쪽을 쓴다.
_Avoid_: 그냥 "installer"(둘 중 어느 쪽인지가 사고의 갈림길이다)

## 클러스터 층

**컴포넌트**:
클러스터 **안**에서 도는 Helm 배포물. 현재 5종(metrics-server, nfs-subdir-external-provisioner, metallb, ingress-nginx, kube-prometheus-stack). `<name>/{README.md, install.sh, values.yaml}` 폴더 컨벤션이 적용되는 **유일한 범주**이며, `kubectl get pods -n <ns>` 로 검증한다.
_Avoid_: 저장소의 모든 폴더를 컴포넌트라 부르는 것. 아래 둘은 컴포넌트가 아니다.

**노드 프로비저닝**:
`node-management/` 의 bash 3종(`01`/`02`/`03`). **PVE 호스트에서 root 로** 실행되며 로컬 macOS 에서는 돌지 않는다. `qm` 과 `talosctl` 로 검증한다.

**클러스터 외 운영도구**:
`pve-watchdog/`. **상시 가동 맥의 Docker** 에서 도는 compose 서비스로, pve 를 헬스체크하다 20분 무응답이면 Tapo 로 전원을 끊는다. 쿠버네티스 자원이 아니므로 **`kubectl` 에 전혀 보이지 않는다** — 죽어 있어도 클러스터 쪽에서는 알 수 없고, `docker logs` 로만 확인된다.

**워크로드**:
클러스터에서 도는, **k8s-ops 가 관리하지 않는** 모든 것. 각자의 앱 저장소(`~/workspace/app/*`)가 매니페스트를 갖고 있으며, 이 저장소는 목록도 유지하지 않는다. 어떤 네임스페이스를 다루기 전에 그 출처를 **먼저 확인해야 한다** — 2026-08-01 에 `ftp` 의 100Gi 데이터가 출처(`~/workspace/app/k8s-ftp`)를 확인하지 않은 채 삭제됐다.

**nfs-client**:
기본 StorageClass. `reclaimPolicy=Delete` + `archiveOnDelete=false` 이므로, **PVC 를 지우면 nknas 의 해당 디렉토리가 아카이브 없이 즉시 삭제된다.** 네임스페이스 삭제도 같은 결과를 낳는다. 되돌릴 방법은 없다.

## 형상관리 층

**권위 있는 사본 / 실행 사본**:
같은 파일이 두 곳에 있을 때, **git 이 추적하는 쪽이 권위 있는 사본**이고 실제로 실행·배포되는 쪽이 실행 사본이다. 편집은 언제나 권위 있는 사본에서 시작하고, 실행 사본으로 내보낸다. 현재 유일한 쌍은 `node-management/`(저장소) → `pve:~/k8s-ops/node-management/`(실행)이며, **동기화는 수동 `scp` 이고 어긋남을 자동으로 감지하지 못한다.**
_Avoid_: `values.yaml` 을 이 관계로 읽는 것. 그건 사본 쌍이 아니라 파일 하나이며, git 이 추적하는 그 파일을 helm 이 그대로 먹는다.

**문서 표면**:
사실이 사는 곳은 넷이고 역할이 다르다 — **CONTEXT.md**(용어 정의), **CLAUDE.md**(이 저장소를 만질 때의 규칙과 빠른 참조, 세션마다 자동 로드됨), **Wiki**(사람이 읽는 런북·트러블슈팅·아키텍처, 별도 git 저장소라 push 즉시 라이브), **auto-memory**(세션 간에 넘기는 사고 이력). 새 사실이 생기면 넷 중 어디에 속하는지 정하고 **한 곳에만** 쓴다.
