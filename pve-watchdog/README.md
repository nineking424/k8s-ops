# pve-watchdog — pve 외부 하드웨어 워치독 (맥 Docker)

## 무엇을 / 왜

pve(192.168.1.3, HUANANZHI X99 보드)는 **자체 하드웨어 워치독으로 자가복구가 불가능**하다:

- `iTCO_wdt`는 로드·무장까지는 되지만(Wellsburg TCO v2, heartbeat 30s) **BIOS NO_REBOOT 봉인으로 실제 리셋을 못 함**. 2026-05-29 `echo c > /proc/sysrq-trigger` 강제패닉 실검증 → boot 로그 23:26~00:25 **~59분 공백**(수동 Tapo power cycle로 복구)으로 확정.
- `softdog`는 커널 하드행 시 타이머도 같이 멈춰 무력.

2026-05-24 전신 프리즈가 **~5.75일 방치**된 근본 이유가 이것이다. 따라서 **pve 외부에서 전원을 끊는 것**만이 완전한 자가복구 수단이다.

이 컴포넌트는 **상시 가동 맥의 Docker 컨테이너**에서 돌며 pve를 헬스체크하고, 장시간 무응답이면 **Tapo P110 스마트플러그("Main Rack", 192.168.150.226)** 로 power cycle 한다. 감시자를 **Proxmox 클러스터와 독립적인** 맥에 두어, pve뿐 아니라 Proxmox 노드(pve-main 등)가 같이 죽어도 복구가 가능하다.

> Docker Desktop(맥) 컨테이너는 기본 bridge 네트워크에서 NAT로 LAN에 도달한다. `pve:8006`, `pve:22`, `Tapo:80` 모두 컨테이너에서 OPEN 확인됨(2026-05-30). `network_mode: host`는 맥에선 의미가 다르므로 쓰지 않는다.

## 동작

컨테이너 내부에서 `watchdog.py`가 **무한 루프로 `CHECK_INTERVAL`(기본 120초)마다** 점검:

1. **TCP 헬스체크** — pve의 `:8006`(pveproxy) → `:22`(sshd) 순으로 connect 시도. 하나라도 열리면 alive. ICMP(ping)는 컨테이너에서 불안정해 쓰지 않는다.
2. **오판 방지(sanity)** — pve 무응답이어도, 그 직전에 **Tapo(:80) 도달 가능**할 때만 down으로 카운트. 둘 다 안 닿으면 "컨테이너/LAN 네트워크 장애"로 보고 카운트하지 않음(멀쩡한 pve를 죽이지 않음).
3. **연속 실패 누적** — `/data/state.json`에 `fail_count` 기록(컨테이너 재시작에도 유지).
4. **임계 도달 시 power cycle** — `fail_count >= FAIL_THRESHOLD`(기본 10 → 120초×10 = **20분 무응답**)이면 Tapo off → `OFF_WAIT_SEC`(**60초**) → on → (`WOL_WAIT_SEC` 후) **WoL 매직패킷**.
5. **안전장치**:
   - **쿨다운** `COOLDOWN_SEC`(**1800초=30분**) — power cycle 후 재발동 최소 간격. **콜드부팅(~7.3분)보다 반드시 길어야 함** (짧으면 부팅 중 재차단해 영영 못 올라옴 — 2026-05-30 실측으로 확인).
   - **일일 최대** `MAX_PER_DAY`(기본 3) — 하드웨어 완전 고장 시 무한 껐다켜기 방지. 초과 시 로그만 남기고 멈춤(사람 개입 필요).
   - **WoL 안전망** `WOL_MAC` — Tapo on 후에도 보드가 standby로 멈출 때(자동 전원 On 실패) 깨우는 보조 수단. directed unicast(`PVE_HOST`) + 제한 브로드캐스트를 함께 전송.

> **OFF_WAIT 60초인 이유(실측)**: 10초 off는 PSU standby 캐패시터가 안 빠져 보드가 AC 손실을 인식 못 함 → "AC 복귀 시 자동 전원 On"이 안 걸려 **standby로 멈춤**(콘센트엔 전기 와도 메인보드 OFF). **60초** off면 standby가 완전히 빠져 자동 전원 On 성공. 전제: BIOS "Restore on AC Power Loss = Power On".

정상 콜드부팅이 ~7.3분(전원인가→네트워크 up) 걸리는 것을 실측했으므로 임계 20분 + 쿨다운 30분은 오판/부팅중재차단 여지가 거의 없다.

## 구성

| 파일 | 설명 |
|---|---|
| `watchdog.py` | 본체 (환경변수로 설정, stdout 로깅) |
| `Dockerfile` | `python:3.12-slim` + `tapo` 라이브러리 |
| `docker-compose.yml` | 서비스 정의. `restart: unless-stopped`, 설정 env, `./data` 볼륨 |
| `.env.template` | `TAPO_EMAIL`/`TAPO_PASSWORD` placeholder (git 추적) |
| `.env` | 실제 Tapo 계정 (**git 제외**) |
| `data/state.json` | 런타임 상태 fail_count/last_pc/day_count (**git 제외**) |

설정값은 모두 `docker-compose.yml`의 `environment` 또는 `.env`로 주입된다(`PVE_HOST`, `TAPO_HOST`, `CHECK_INTERVAL`, `FAIL_THRESHOLD`, `COOLDOWN_SEC`, `MAX_PER_DAY`, `OFF_WAIT_SEC`, `WOL_MAC`, `WOL_WAIT_SEC`, `DRY_RUN`).

> **전제**: Tapo 앱 > 나 > 타사 서비스(Third-Party Compatibility) **ON**. 꺼져 있으면 `get_device_info()`가 `FORBIDDEN`으로 막힌다.

## 설치 (맥에서, 최초 1회)

```bash
cd ~/workspace/k8s/k8s-ops/pve-watchdog
cp .env.template .env          # 편집해 실제 TAPO_EMAIL/TAPO_PASSWORD 입력
docker compose up -d --build    # 빌드 + 백그라운드 기동
```

Docker Desktop을 **로그인 시 자동 시작**으로 설정해 두면, 맥 재부팅 후에도 `restart: unless-stopped`로 컨테이너가 자동 복귀한다.

## 설치 후 체크리스트

- [x] 컨테이너 LAN 도달성: `pve:8006`/`pve:22`/`Tapo:80` OPEN (2026-05-30 확인)
- [x] Tapo 인증: 빌드 이미지에서 `get_device_info()` 성공 (`device_on=True`)
- [x] 헬스체크: 정상 pve를 `tcp:8006`로 alive 인식, `fail_count=0` 유지
- [x] dry-run: 가짜 down(`PVE_HOST=127.0.0.1`) + `DRY_RUN=1`로 임계 도달 → power cycle 경로 진입 확인
- [x] **실검증(2026-05-30)**: pve를 `echo c`(panic=0)로 강제 행 → 워치독이 **실제 Tapo 전원차단** 발동(로그 `POWER CYCLING`+`command sent OK`) → 60초 off로 보드 자동 전원 On → 콜드부팅 ~7.3분 → **k8s 5/5 Ready 자동 복구**. 이 과정에서 `OFF_WAIT 10→60초`·`COOLDOWN 600→1800초` 튜닝 도출, WoL 안전망 추가.

## 운영

```bash
cd ~/workspace/k8s/k8s-ops/pve-watchdog
docker compose logs -f pve-watchdog   # 동작 로그 (시작/down/복구/power cycle)
cat data/state.json                   # 현재 상태
docker compose restart pve-watchdog   # 재시작
docker compose down                   # 중지/제거

# 읽기전용 1회 점검(컨테이너 안에서 헬스체크 로직 한 번)
docker compose run --rm -e CHECK_INTERVAL=1 -e DRY_RUN=1 pve-watchdog \
  python -c "import watchdog as w; s=w.load_state(); w.check_once(s); print(s)"
```

## 향후

- **알림 연동** (현재 stdout 로그만) — power cycle 발동 시 Discord 등. `watchdog.py`의 `"POWER CYCLING ..."` 로그 지점에 훅 추가.
- **감시자 SPOF** — 맥(또는 Docker Desktop)이 죽으면 워치독도 멈춤. 상시 가동 맥이라 우선순위 낮음. 필요 시 pve-main에 보조 워치독을 두어 상호 감시.
- 관련 사고/하드웨어 맥락은 상위 `../CLAUDE.md` 및 메모리 `pve-hardware-and-freeze-incident` 참조.
