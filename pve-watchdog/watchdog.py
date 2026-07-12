#!/usr/bin/env python3
"""
pve 외부 하드웨어 워치독 (상시 가동 맥의 Docker 컨테이너에서 실행).

pve(192.168.1.3)를 TCP 헬스체크하여, 장시간 무응답이면 Tapo P110
스마트플러그("Main Rack", 192.168.150.226)로 power cycle 한다.

배경: pve(HUANANZHI X99) 보드는 iTCO 하드웨어 워치독이 BIOS NO_REBOOT
봉인으로 실제 리셋을 못 하고(2026-05-29 sysrq 실검증으로 확정), softdog는
커널 하드행에 무력. 2026-05-24 전신 프리즈가 ~5.75일 방치된 이유. 따라서
pve '외부'에서 전원을 끊는 것만이 완전 자가복구 수단. 감시자는 Proxmox
클러스터와 독립적인 상시 가동 맥에 둔다.

컨테이너 친화적으로 ICMP 대신 TCP로 헬스체크하고, 오판(멀쩡한 pve를 죽임)을
막기 위해 'pve 무응답 + Tapo 도달'일 때만 down으로 센다. 설정은 환경변수.
"""
import asyncio
import json
import os
import socket
import time
from datetime import datetime, timezone

PVE_HOST = os.environ.get("PVE_HOST", "192.168.1.3")
TAPO_HOST = os.environ.get("TAPO_HOST", "192.168.150.226")
TAPO_EMAIL = os.environ.get("TAPO_EMAIL", "")
TAPO_PASSWORD = os.environ.get("TAPO_PASSWORD", "")
STATE_FILE = os.environ.get("STATE_FILE", "/data/state.json")
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", "120"))
FAIL_THRESHOLD = int(os.environ.get("FAIL_THRESHOLD", "10"))
COOLDOWN_SEC = int(os.environ.get("COOLDOWN_SEC", "1800"))
MAX_PER_DAY = int(os.environ.get("MAX_PER_DAY", "3"))
OFF_WAIT_SEC = int(os.environ.get("OFF_WAIT_SEC", "60"))
WOL_MAC = os.environ.get("WOL_MAC", "")                    # 안전망: on 후 standby 멈춤 대비 WoL
WOL_WAIT_SEC = int(os.environ.get("WOL_WAIT_SEC", "8"))    # Tapo on → standby 안정화 대기 후 WoL
DRY_RUN = os.environ.get("DRY_RUN", "") not in ("", "0", "false", "False")

# pve가 살아있으면 열려 있는 포트: pveproxy(웹), sshd
PVE_PORTS = [8006, 22]


def log(msg):
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    print(f"{ts} {msg}", flush=True)


def tcp_ok(host, port, timeout=4):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def pve_alive():
    """pve의 포트 중 하나라도 열려 있으면 alive."""
    for p in PVE_PORTS:
        if tcp_ok(PVE_HOST, p):
            return True, f"tcp:{p}"
    return False, f"tcp {'+'.join(map(str, PVE_PORTS))} unreachable"


def lan_ok():
    """컨테이너/LAN 자체가 살아있는지 — Tapo 도달로 확인(전원제어에도 필요)."""
    return tcp_ok(TAPO_HOST, 80)


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {"fail_count": 0, "last_pc": 0, "day": "", "day_count": 0}


def save_state(s):
    tmp = STATE_FILE + ".tmp"
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(tmp, "w") as f:
        json.dump(s, f)
    os.replace(tmp, STATE_FILE)


def send_wol():
    """WoL 매직패킷 전송 — power on 후 보드가 standby로 멈출 때 깨우는 안전망.
    컨테이너가 NAT 뒤라 L2 브로드캐스트가 LAN에 못 닿을 수 있어, directed unicast
    (PVE_HOST, 맥 ARP 캐시 활용)와 제한 브로드캐스트를 모두 시도한다."""
    if not WOL_MAC:
        return []
    import socket
    mac = bytes.fromhex(WOL_MAC.replace(":", "").replace("-", ""))
    packet = b"\xff" * 6 + mac * 16
    targets = [(PVE_HOST, 9), (PVE_HOST, 7), ("255.255.255.255", 9), ("255.255.255.255", 7)]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sent = []
    for host, port in targets:
        try:
            s.sendto(packet, (host, port))
            sent.append(f"{host}:{port}")
        except OSError:
            pass
    s.close()
    return sent


async def power_cycle():
    from tapo import ApiClient
    client = ApiClient(TAPO_EMAIL, TAPO_PASSWORD)
    dev = await client.p110(TAPO_HOST)
    await dev.off()
    await asyncio.sleep(OFF_WAIT_SEC)
    await dev.on()
    if WOL_MAC:
        await asyncio.sleep(WOL_WAIT_SEC)
        sent = send_wol()
        log(f"WoL magic packet -> {WOL_MAC} via {sent}")


def check_once(s):
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    if s["day"] != today:
        s["day"] = today
        s["day_count"] = 0

    alive, how = pve_alive()
    if alive:
        if s["fail_count"] > 0:
            log(f"pve RECOVERED via {how} (was fail_count={s['fail_count']})")
        s["fail_count"] = 0
        save_state(s)
        return

    # pve 무응답 — 단, 컨테이너 자신의 LAN이 죽은 거면 오판이므로 세지 않음
    if not lan_ok():
        log(f"pve unreachable BUT Tapo({TAPO_HOST}:80) also unreachable — "
            f"container/LAN network down, NOT counting (fail_count={s['fail_count']})")
        save_state(s)
        return

    s["fail_count"] += 1
    log(f"pve DOWN ({how}) fail_count={s['fail_count']}/{FAIL_THRESHOLD}")
    now = time.time()

    if s["fail_count"] >= FAIL_THRESHOLD:
        since_pc = now - s["last_pc"]
        if since_pc < COOLDOWN_SEC:
            log(f"threshold reached but in cooldown "
                f"({int(since_pc)}s < {COOLDOWN_SEC}s) — skip")
        elif s["day_count"] >= MAX_PER_DAY:
            log(f"threshold reached but DAILY LIMIT hit "
                f"({s['day_count']}/{MAX_PER_DAY}) — likely HARDWARE FAULT, "
                f"manual intervention needed")
        elif DRY_RUN:
            log("[DRY-RUN] would POWER CYCLE pve now")
            s["last_pc"] = now
            s["day_count"] += 1
            s["fail_count"] = 0
        else:
            log(f"POWER CYCLING pve via Tapo (off -> {OFF_WAIT_SEC}s -> on)")
            try:
                asyncio.run(power_cycle())
                log("power cycle command sent OK")
                s["last_pc"] = now
                s["day_count"] += 1
                s["fail_count"] = 0
            except Exception as e:
                log(f"power cycle FAILED: {e!r}")

    save_state(s)


def main():
    span_min = CHECK_INTERVAL * FAIL_THRESHOLD // 60
    log(f"pve-watchdog started (target={PVE_HOST}{PVE_PORTS}, tapo={TAPO_HOST}, "
        f"interval={CHECK_INTERVAL}s, threshold={FAIL_THRESHOLD} = {span_min}min, "
        f"cooldown={COOLDOWN_SEC}s, max/day={MAX_PER_DAY}, dry_run={DRY_RUN})")
    if not TAPO_EMAIL or not TAPO_PASSWORD:
        log("WARNING: TAPO_EMAIL/TAPO_PASSWORD not set — power cycle will fail")
    s = load_state()
    while True:
        try:
            check_once(s)
        except Exception as e:
            log(f"iteration error: {e!r}")
        time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    main()
