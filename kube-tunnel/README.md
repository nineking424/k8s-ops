# kube-tunnel — kubectl 용 localhost 포워더 (맥 Docker)

## 무엇을 / 왜

`nkmini`(이 맥)의 `localhost:16443` → 클러스터 VIP `192.168.2.100:6443` TCP 포워더. kubectl context `talos-tunnel`(기본)이 여기로 붙는다.

macOS 15 "로컬 네트워크" 보호는 **kubectl 을 실행한 앱**의 권한으로 LAN 접속을 판정한다(Apple TN3179 — Terminal/SSH 에서 직접 돌린 CLI 는 면제, GUI 앱이나 launchd **agent** 가 띄운 프로세스는 그 앱/agent 권한을 따름). 권한 없는 앱에서 돌면 VIP 직접 접속(`admin@talos-homelab`)이 막힌다. LAN 구간을 Docker Desktop 에 맡기면 kubectl 은 localhost 에만 붙으므로 어느 앱에서 돌든 동작한다.

- 이전 방식인 `ssh -fN -L 16443:192.168.2.100:6443 nineking@192.168.1.7` 은 상시 기동 장치가 없어 조용히 끊겼다(2026-11-19 발견). launchd agent 는 위 면제 대상이 아니라 대안에서 제외했다.
- TLS 는 종단하지 않는다 — socat 은 바이트만 전달하고, 인증서 검증은 kubeconfig 의 `tls-server-name: 192.168.2.100` 으로 kubectl 이 한다. 시크릿 없음.

범주: **클러스터 외 운영도구** (`pve-watchdog/` 과 같음 — `kubectl` 에 안 보이고, Docker Desktop 이 죽으면 같이 죽는다).

## 기동 / 운영

```bash
docker compose up -d          # 기동
docker compose ps             # 상태 (healthy 여야 함)
docker compose logs kube-tunnel
docker compose down           # 중지/제거
```

Docker Desktop 이 멈췄을 때의 비상 경로(수동, 비영속):

```bash
ssh -fN -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L 16443:192.168.2.100:6443 nineking@192.168.1.7
```

## 검증 체크리스트

- [ ] `docker ps --filter name=kube-tunnel` — `Up ... (healthy)`
- [ ] `lsof -nP -iTCP:16443 -sTCP:LISTEN` — `127.0.0.1:16443` 만 (LAN 바인딩 없음)
- [ ] `kubectl config current-context` = `talos-tunnel`, `kubectl get nodes` — 6/6 Ready
