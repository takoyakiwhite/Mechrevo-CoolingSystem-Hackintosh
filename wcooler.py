#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wcooler.py —— macOS 上控制机械革命 / XMG OASIS / TUXEDO Aquaris 水冷魔盒

协议依据：Uniwill GCUService.exe（.NET IL，402k 行）逆向文档
  设备名：CoolingSystem LCT21001 (Mk1) / CoolingSystem LCT22002 (Mk2)
  service  6E400001-B5A3-F393-E0A9-E50E24DCCA9E   (NUS)
  write    6E400002-B5A3-F393-E0A9-E50E24DCCA9E   (主机 -> 魔盒)
  notify   6E400003-B5A3-F393-E0A9-E50E24DCCA9E   (魔盒 -> 主机)

帧格式（固定 8 字节）：[0]=0xFE [1]=CMD [2]=on/off [3..6]=参数 [7]=0xEF
  0x19 系统模式   00 01=睡眠 / 01 04=开始注水([4]=0x50) / 00 04=停止注水
  0x1A 系统使能   [2]=1|0（固件命令，Windows 主机不发，这里默认发一次）
  0x1B 风扇       [2]=on [3]=duty(0-100)
  0x1C 水泵       [2]=on [3]=duty(0-100) [4]=电压码
  0x1E 冷头灯效   [2]=on [3]=R [4]=G [5]=B [6]=模式
  0x32 查询水表   （设备也会主动推 0x31）
  0x33 风扇灯效   同 0x1E 布局（仅 LCT22002）
  0x38 断线       （断开连接时发，不是睡眠）

电压码：11V=0  12V=1（本机不用）  7V=2  8V=3；**本机上限 11V**，12V 已禁用
灯效模式：0=常亮 1=呼吸 2=炫彩 3=呼吸变色

【曾写错、现已修正的两点】
  1) 占空比是 **0-100 的百分数**，不是 raw 0-255；
  2) 水泵帧里 **duty 在前、电压码在后**（byte[3]=duty, byte[4]=volt_code）。

握手：写 73 77（ASCII "sw"，无 FE/EF），设备须回一段 ≥18 字符的固件版本串
      （如 "CoolingSystem FW V1.00.00"）。**收到这串才算连接建立**。

用法：
    pip3 install bleak
    python3 wcooler.py scan
    python3 wcooler.py run --volt 8 --duty 100 --fan 50
    python3 wcooler.py frames          # 离线打印将发的帧，不连蓝牙
    python3 wcooler.py prime           # 注水/排气（约 68 秒）
    python3 wcooler.py probe           # 扫占空比，找起转点
    python3 wcooler.py raw --hex "FE 1C 01 64 03 00 00 EF"
    python3 wcooler.py off
"""

import argparse
import asyncio
import signal
import sys
import time

try:
    from bleak import BleakClient, BleakScanner
except ImportError:  # pragma: no cover
    sys.exit("缺少依赖：pip3 install bleak")

NUS_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
NUS_WRITE = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
NUS_NOTIFY = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

CMD_SYSTEM_MODE = 0x19
CMD_SYSTEM_ENABLE = 0x1A
CMD_FAN = 0x1B
CMD_PUMP = 0x1C
CMD_HEAD_LED = 0x1E
CMD_QUERY_METER = 0x32
CMD_FAN_LED = 0x33
CMD_LINE_OFF = 0x38

HANDSHAKE = bytes([0x73, 0x77])  # "sw"

# 电压码（IL 证据：11 -> 0，12 -> 1，7 -> 2，default -> 3 即 8V）
VOLT_CODES = {11: 0, 12: 1, 7: 2, 8: 3}
CODE_VOLTS = {0: "11V", 1: "12V", 2: "7V", 3: "8V"}

LED_MODES = {0: "常亮", 1: "呼吸", 2: "炫彩", 3: "呼吸变色"}


def volt_code(v: int) -> int:
    return VOLT_CODES.get(int(v), 3)


def frame(cmd: int, payload) -> bytes:
    body = list(payload)[:5]
    body += [0] * (5 - len(body))
    return bytes([0xFE, cmd] + body + [0xEF])


def clamp(v, lo=0, hi=255):
    return max(lo, min(hi, int(v)))


def pump_frame(on: bool, duty: int, volt: int) -> bytes:
    """FE 1C <on> <duty 0-100> <volt_code> 00 00 EF"""
    d = clamp(duty, 0, 100) if on else 0
    return frame(CMD_PUMP, [1 if on else 0, d, volt_code(volt) if on else 0, 0, 0])


def fan_frame(on: bool, duty: int) -> bytes:
    """FE 1B <on> <duty 0-100> 00 00 00 EF"""
    d = clamp(duty, 0, 100) if on else 0
    return frame(CMD_FAN, [1 if on else 0, d, 0, 0, 0])


def head_led_frame(on: bool, r: int, g: int, b: int, mode: int) -> bytes:
    return frame(CMD_HEAD_LED, [1 if on else 0] +
                 [clamp(x) if on else 0 for x in (r, g, b)] + [clamp(mode) if on else 0])


def fan_led_frame(on: bool, r: int, g: int, b: int, mode: int) -> bytes:
    return frame(CMD_FAN_LED, [1 if on else 0] +
                 [clamp(x) if on else 0 for x in (r, g, b)] + [clamp(mode) if on else 0])


def system_enable_frame(on: bool) -> bytes:
    return frame(CMD_SYSTEM_ENABLE, [1 if on else 0, 0, 0, 0, 0])


QUERY_METER = frame(CMD_QUERY_METER, [])
LINE_OFF = frame(CMD_LINE_OFF, [])
SLEEP = frame(CMD_SYSTEM_MODE, [0, 1, 0, 0, 0])
PRIME_START = frame(CMD_SYSTEM_MODE, [1, 4, 0x50, 0, 0])
PRIME_STOP = frame(CMD_SYSTEM_MODE, [0, 4, 0, 0, 0])


def hexs(data: bytes) -> str:
    return " ".join(f"{x:02X}" for x in data)


# MARK: - 智能控制（无 UI 时的守护进程模式也用它）

SMART_PRESETS = {
    "silent": {
        "pump": [(0, 40), (50, 55), (100, 80)],
        "fan": [(0, 0), (40, 25), (70, 45), (100, 70)],
    },
    "balanced": {
        "pump": [(0, 50), (50, 70), (100, 100)],
        "fan": [(0, 20), (40, 40), (70, 65), (100, 100)],
    },
    "performance": {
        "pump": [(0, 80), (40, 100), (100, 100)],
        "fan": [(0, 50), (40, 80), (100, 100)],
    },
}


def interp(points, x: float) -> float:
    """折线插值，x 超出范围取端点"""
    pts = sorted(points)
    if x <= pts[0][0]:
        return pts[0][1]
    if x >= pts[-1][0]:
        return pts[-1][1]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if x0 <= x <= x1:
            return y0 + (y1 - y0) * (x - x0) / max(1e-6, x1 - x0)
    return pts[-1][1]


def cpu_percent() -> float:
    """优先用 psutil；没有就退回 1 分钟平均负载换算"""
    try:
        import psutil  # type: ignore
        return float(psutil.cpu_percent(interval=0.3))
    except Exception:
        import os
        return min(100.0, os.getloadavg()[0] / (os.cpu_count() or 8) * 100.0)


def read_temp(cmd: str) -> float | None:
    """执行外部命令（如 osx-cpu-temp -c），取输出里第一个数字作为摄氏度"""
    import re
    import subprocess
    cmd = cmd.strip()
    if not cmd:
        return None
    try:
        out = subprocess.run(["/bin/sh", "-c", cmd], capture_output=True,
                             text=True, timeout=3).stdout
        m = re.search(r"-?\d+(?:\.\d+)?", out)
        return float(m.group()) if m else None
    except Exception:
        return None


def smart_targets(args):
    """返回 (pump_duty, fan_duty, 输入说明)"""
    curve = SMART_PRESETS.get(getattr(args, "smart_preset", "balanced"),
                              SMART_PRESETS["balanced"])
    if getattr(args, "temp_cmd", ""):
        t = read_temp(args.temp_cmd)
        if t is not None:
            span = max(1.0, args.temp_max - args.temp_min)
            x = (t - args.temp_min) / span * 100.0
            desc = f"温度 {t:.0f}℃"
        else:
            x = cpu_percent()
            desc = f"CPU {x:.0f}%（温度命令取不到，回退）"
    else:
        x = cpu_percent()
        desc = f"CPU {x:.0f}%"
    x = max(0.0, min(100.0, x))
    pump = max(getattr(args, "pump_min", 50), int(round(interp(curve["pump"], x))))
    fan = max(getattr(args, "fan_min", 0), int(round(interp(curve["fan"], x))))
    return pump, fan, desc


def parse_hex(s: str) -> bytes:
    cleaned = "".join(ch for ch in s if ch.isalnum())
    if not cleaned or len(cleaned) % 2:
        raise ValueError("hex 长度不对")
    return bytes.fromhex(cleaned)


def parse_response(data: bytes) -> str:
    """按 GCUService 的 FormatValueByPresentation 解析回包"""
    if len(data) >= 4 and data[0] == 0xFE:
        if data[1] in (0x31, 0x32):
            state = data[3]
            ok = "流量正常" if state == 2 else "异常/告警"
            kind = "设备主动推送" if data[1] == 0x31 else "查询应答"
            return f"水表状态 {state} = {ok}（{kind}）"
        return f"未知回包 {hexs(data)}"
    full = data.decode("utf-8", errors="replace")
    # 建链瞬间偶尔会先冒出一个不完整的短包（解出来是乱码），忽略它，别当成版本串
    if len(full) < 4 or "�" in full:
        return f"（忽略非文本短包 {hexs(data)}）"
    short = full[17:] if len(full) >= 18 else full
    return f'固件版本 "{full}" (版本段 = "{short}")'


async def resolve_chars(client):
    """挑出写/通知特征。没有 NUS 的固件批次会自动枚举并回退。"""
    svcs = client.services
    nus = svcs.get_service(NUS_SERVICE)
    if nus:
        w = nus.get_characteristic(NUS_WRITE)
        n = nus.get_characteristic(NUS_NOTIFY)
        if w:
            print(f"使用 NUS：写 {w.uuid} / 通知 {n.uuid if n else '(无)'}")
            return w.uuid, (n.uuid if n else None), NUS_SERVICE

    print("  没有 NUS 服务。枚举到的全部服务/特征：")
    for s in svcs:
        print(f"     服务 {s.uuid}")
        for c in s.characteristics:
            print(f"        {c.uuid}  {c.properties}")

    best = None
    for s in svcs:
        w = next((c for c in s.characteristics
                  if "write" in c.properties or "write-without-response" in c.properties), None)
        n = next((c for c in s.characteristics
                  if "notify" in c.properties or "indicate" in c.properties), None)
        if w and n:
            return w.uuid, n.uuid, str(s.uuid)
        if w and best is None:
            best = (w.uuid, None, str(s.uuid))
    if not best:
        raise SystemExit("这个设备没有任何可写特征，控制不了。上面是它全部的 GATT 结构。")
    print(f"  >> NUS 不存在，回退使用服务 {best[2]}，写特征 {best[0]}")
    return best


class Cooler:
    def __init__(self, client: BleakClient, write_uuid=NUS_WRITE, notify_uuid=NUS_NOTIFY):
        self.client = client
        self.last_notify = 0.0
        self.prefer_response = True
        self.write_uuid = write_uuid
        self.notify_uuid = notify_uuid
        self.firmware = None
        self.meter_state = None
        self.got_handshake_reply = False

    @property
    def connected(self) -> bool:
        return bool(getattr(self.client, "is_connected", False))

    async def send(self, data: bytes, tag: str = ""):
        try:
            ok = await self.client.write_gatt_char(self.write_uuid, data,
                                                   response=self.prefer_response)
        except Exception as e:
            # 连接已断 / 服务发现已失效：不要再盲目降级重试，直接抛给上层重连
            if not self.connected:
                raise ConnectionError(f"写 {tag} 时连接已断开") from e
            if self.prefer_response:
                self.prefer_response = False
                print(f"  (带响应写失败：{e}，改用无响应写)")
                try:
                    ok = await self.client.write_gatt_char(self.write_uuid, data, response=False)
                except Exception as e2:
                    raise ConnectionError(f"写 {tag} 失败：{e2}") from e2
            else:
                raise ConnectionError(f"写 {tag} 失败：{e}") from e
        print(f"  -> {hexs(data):<26} {tag}")
        return ok

    async def start_notify(self):
        def handler(_sender, data: bytearray):
            self.last_notify = time.time()
            b = bytes(data)
            text = parse_response(b)
            if len(b) >= 4 and b[0] == 0xFE:
                if b[1] in (0x31, 0x32) and self.meter_state != b[3]:
                    self.meter_state = b[3]
                    print(f"  <- {text}")
            else:
                s = b.decode("utf-8", errors="replace")
                if len(s) < 4 or "�" in s:
                    print(f"  <- {text}")      # 非文本短包，不当成握手应答
                    return
                self.got_handshake_reply = True
                self.firmware = s[17:] if len(s) >= 18 else s
                print(f"  <- 握手应答：{text}")

        if not self.notify_uuid:
            print("  (该服务没有 notify 特征，收不到回包属正常)")
            return False
        try:
            await self.client.start_notify(self.notify_uuid, handler)
            return True
        except Exception as e:
            print(f"  (notify 订阅失败: {e})")
            return False

    async def handshake(self):
        """
        官方文档的连接顺序（顺序不能反）：
          1) 找到 TX(6e400002) 存起来
          2) 在 RX(6e400003) 上**打开通知**
          3) 向 TX 写 "sw"
          4) 在 RX 上收到固件版本串 -> 连接才算建立
        """
        await self.start_notify()
        print("握手：写 \"sw\" (73 77)，等待固件版本串…")
        await self.send(HANDSHAKE, "handshake 'sw'")
        for _ in range(50):                      # 最多等 5 秒
            await asyncio.sleep(0.1)
            if self.got_handshake_reply:
                break
        if not self.got_handshake_reply:
            print("!! 没收到固件版本串。按 GCUService 逻辑，收不到就**不算连上**，"
                  "后续控制帧大概率无效。")
            return False
        print(f"连接已建立，固件版本 {self.firmware!r}")
        return True

    async def apply_state(self, args, tag="restore"):
        duty = clamp(args.duty, 0, 100)
        fan_duty = clamp(max(args.fan, args.fan_min), 0, 100)
        vc = volt_code(args.volt)
        await self.send(pump_frame(True, duty, args.volt),
                        f"{tag} pump {duty}% @ {CODE_VOLTS[vc]}")
        await asyncio.sleep(0.12)
        await self.send(fan_frame(True, fan_duty), f"{tag} fan {fan_duty}%")
        await asyncio.sleep(0.12)
        if args.no_led:
            await self.send(head_led_frame(False, 0, 0, 0, 0), f"{tag} head led off")
            await self.send(fan_led_frame(False, 0, 0, 0, 0), f"{tag} fan led off")
        else:
            r, g, b, m = args.led
            await self.send(head_led_frame(True, r, g, b, m),
                            f"{tag} head led ({r},{g},{b}) mode={m}"
                            f"({LED_MODES.get(m, m)})")
            if getattr(args, "fan_led", None):
                fr, fg, fb, fm = args.fan_led
                await self.send(fan_led_frame(True, fr, fg, fb, fm),
                                f"{tag} fan led ({fr},{fg},{fb}) mode={fm}")

    async def shutdown_frames(self):
        for data, tag in ((pump_frame(False, 0, 0), "stop pump"),
                          (fan_frame(False, 0), "stop fan"),
                          (head_led_frame(False, 0, 0, 0, 0), "stop head led"),
                          (fan_led_frame(False, 0, 0, 0, 0), "stop fan led"),
                          (LINE_OFF, "line-off (0x38)")):
            try:
                await self.send(data, tag)
                await asyncio.sleep(0.07)
            except Exception:
                pass


async def cmd_scan(args):
    print("扫描 BLE 设备（看 name / address / rssi）…")
    found = await BleakScanner.discover(timeout=args.timeout, return_adv=True)
    if not found:
        print("没扫到任何设备。检查蓝牙是否开启、是否已在别的机器上配对占用。")
        return
    for dev, adv in found.values():
        uuids = ",".join(str(u) for u in (adv.service_uuids or []))
        mark = ""
        if dev.name and any(k in dev.name.lower()
                            for k in ("coolingsystem", "cooler", "lct", "mech", "water")):
            mark = " <-- 疑似水冷魔盒"
        print(f"{str(dev.address):<40} rssi={adv.rssi:<5} name={dev.name!r} "
              f"services=[{uuids}]{mark}")


async def pick_device(args):
    print("扫描中…")
    found = await BleakScanner.discover(timeout=args.timeout, return_adv=True)
    if not found:
        raise SystemExit("没扫到设备")

    if args.address:
        for dev, _ in found.values():
            if dev.address.lower() == args.address.lower():
                return dev
        raise SystemExit(f"没找到 address={args.address} 的设备")

    if args.name:
        for dev, _ in found.values():
            if dev.name and args.name.lower() in dev.name.lower():
                return dev
        raise SystemExit(f"没找到名字包含 {args.name!r} 的设备")

    for dev, adv in found.values():
        if NUS_SERVICE in [str(u).lower() for u in (adv.service_uuids or [])]:
            return dev
    for dev, _ in found.values():
        if dev.name and any(k in dev.name.lower()
                            for k in ("coolingsystem", "cooler", "lct", "mech", "water")):
            return dev
    raise SystemExit("没找到疑似水冷魔盒，先用 scan 看看，再用 --name / --address 指定")


async def connect_client(dev, timeout=12.0, attempts=3, **kw):
    """连接并带超时/重试。CoreBluetooth/bleak 的 connect 也可能一直不返回。"""
    last = None
    for i in range(1, attempts + 1):
        c = BleakClient(dev, timeout=timeout, **kw)
        try:
            print(f"连接中（第 {i}/{attempts} 次，超时 {timeout:g}s）…")
            await asyncio.wait_for(c.connect(), timeout=timeout + 2)
            return c
        except Exception as e:
            last = e
            print(f"  连接失败/超时: {e}")
            try:
                await c.disconnect()
            except Exception:
                pass
            await asyncio.sleep(1.5)
    raise SystemExit(
        f"连不上设备（最后错误：{last}）。请依次确认：\n"
        "  1) 水冷魔盒通电正常；\n"
        "  2) 没被别的主机/进程占着（Windows 侧 Control Center / open-revo 必须完全退出）；\n"
        "  3) 没有残留 wcooler 进程握着连接：pgrep -x wcooler；\n"
        "  4) 系统设置 → 蓝牙 里若能看到它，先「忽略此设备」再重连。")


async def open_session(args):
    """
    完整建链：扫描 -> 连接 -> 解析特征 -> 订阅 RX -> 写 "sw" -> 收版本串。
    中途任何一步掉线就整体重来 —— CoreBluetooth 很容易「刚连上就断」，
    单次建链成功率不高，必须重试。
    """
    attempts = getattr(args, "session_attempts", 5)
    last = None
    for i in range(1, attempts + 1):
        client = None
        try:
            dev = await pick_device(args)
            client = await connect_client(dev, timeout=args.connect_timeout,
                                          disconnected_callback=lambda _c: print("!! 连接断开"))
            w, n, _svc = await resolve_chars(client)
            cooler = Cooler(client, w, n)
            if await cooler.handshake():
                return client, cooler
            last = RuntimeError("握手没收到固件版本串")
            print(f"  第 {i}/{attempts} 次握手未完成，重连再试…")
        except Exception as e:
            last = e
            print(f"  第 {i}/{attempts} 次建链失败：{type(e).__name__}: {e}")
        if client is not None:
            try:
                await client.disconnect()
            except Exception:
                pass
        await asyncio.sleep(2.0)
    raise SystemExit(
        f"\n建链始终没成功（最后错误：{last}）。\n"
        "若日志显示「刚连上就断开」，按下面顺序试：\n"
        "  1) 给魔盒断电重启一次（拔供电等 10 秒再插），清掉它那侧的僵尸连接；\n"
        "  2) 关掉蓝牙等 10 秒再打开；\n"
        "  3) 确认没被别的主机（手机 App / Windows 控制中心）占着；\n"
        "  4) 用 --session-attempts 20 加大重试次数。")


async def cmd_run(args):
    client, cooler = await open_session(args)
    try:
        if args.system_enable:
            await cooler.send(system_enable_frame(True), "system enable (0x1A)")
            await asyncio.sleep(0.1)

        await cooler.apply_state(args, "restore")

        stop = asyncio.Event()

        def _sig(*_a):
            stop.set()

        loop = asyncio.get_running_loop()
        for s in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(s, _sig)
            except NotImplementedError:
                pass

        last_pump, last_fan = -999, -999
        if getattr(args, "smart", False):
            pump, fan, desc = smart_targets(args)
            last_pump, last_fan = pump, fan
            print(f"  智能首帧：{desc} -> 泵 {pump}% / 扇 {fan}%")
            await cooler.send(pump_frame(True, pump, args.volt), f"smart pump {pump}%")
            await cooler.send(fan_frame(True, fan), f"smart fan {fan}%")

        print(f"\n运行中，Ctrl+C 退出（先停泵停扇再断开）。"
              f"每 {args.refresh:g}s 采样一次"
              f"{'（智能模式）' if getattr(args, 'smart', False) else '并重推状态帧'}。\n")

        while not stop.is_set():
            try:
                await asyncio.wait_for(stop.wait(), timeout=max(1.0, args.refresh))
            except asyncio.TimeoutError:
                pass
            if stop.is_set():
                break
            try:
                if not cooler.connected:
                    print("!! 连接已断开，重建中…")
                    try:
                        await client.disconnect()
                    except Exception:
                        pass
                    client, cooler = await open_session(args)
                    await cooler.apply_state(args, "restore")
                    continue

                if getattr(args, "smart", False):
                    pump, fan, desc = await asyncio.to_thread(smart_targets, args)
                    if abs(pump - last_pump) >= args.hysteresis or \
                       abs(fan - last_fan) >= args.hysteresis:
                        last_pump, last_fan = pump, fan
                        print(f"  智能：{desc} -> 泵 {pump}% / 扇 {fan}%")
                        await cooler.send(pump_frame(True, pump, args.volt),
                                          f"smart pump {pump}%")
                        await cooler.send(fan_frame(True, fan), f"smart fan {fan}%")
                else:
                    await cooler.apply_state(args, "keepalive")
            except Exception as e:
                print(f"保活写入失败：{e}，2 秒后重试…")
                await asyncio.sleep(2.0)

        print("退出：发送停止帧…")
        try:
            await cooler.shutdown_frames()
        except Exception:
            pass
        await asyncio.sleep(0.2)
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


async def cmd_prime(args):
    """注水/排气：官方时序，8 个循环，约 68 秒"""
    client, cooler = await open_session(args)
    try:
        print("\n=== 注水/排气序列开始（约 68 秒，8 个循环）===")
        await cooler.send(PRIME_START, "prime start (0x19 01 04 50)")
        await cooler.send(fan_frame(True, 50), "fan 50%")
        await asyncio.sleep(1.0)
        for i in range(8):
            await cooler.send(pump_frame(False, 0, 0), "prime pump off")
            await asyncio.sleep(0.5)
            print(f"  循环 {i + 1}/8：泵 100% @ 8V，5.5s")
            await cooler.send(pump_frame(True, 100, 8), "prime pump 100% @ 8V")
            await asyncio.sleep(5.5)
            await cooler.send(pump_frame(False, 0, 0), "prime pump off")
            await asyncio.sleep(2.5)
        await cooler.send(PRIME_STOP, "prime stop (0x19 00 04)")
        print("=== 注水/排气完成 ===")
        await asyncio.sleep(0.5)
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


async def cmd_probe(args):
    """扫占空比：确认起转阈值（duty 是 0-100 百分数）"""
    steps = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
    client, cooler = await open_session(args)
    try:
        print("\n=== probe：逐级扫占空比（0-100 百分数），每级 6 秒 ===")
        print("盯住风扇/水泵，记下起转的那一级。\n")
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        try:
            loop.add_signal_handler(signal.SIGINT, stop.set)
        except NotImplementedError:
            pass
        for phase, title in ((0, "风扇"), (1, f"水泵({CODE_VOLTS[volt_code(args.volt)]})")):
            print(f"\n--- {title} ---\n")
            for d in steps:
                if stop.is_set():
                    break
                f = fan_frame(True, d) if phase == 0 else pump_frame(True, d, args.volt)
                print(f"{title} duty={d}%  <- 看有没有转")
                await cooler.send(f, "probe")
                try:
                    await asyncio.wait_for(stop.wait(), timeout=6.0)
                except asyncio.TimeoutError:
                    pass
        print("\n=== probe 结束。用 --fan / --duty 填起转的百分数 ===")
        await cooler.shutdown_frames()
        await asyncio.sleep(0.3)
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


async def cmd_raw(args):
    data = parse_hex(args.hex)
    client, cooler = await open_session(args)
    try:
        await cooler.send(data, "raw")
        await asyncio.sleep(1.0)
        await cooler.send(LINE_OFF, "line-off (0x38)")
        await asyncio.sleep(0.3)
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


async def cmd_off(args):
    client, cooler = await open_session(args)
    try:
        await cooler.shutdown_frames()
        await asyncio.sleep(0.3)
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


async def cmd_sleep(args):
    client, cooler = await open_session(args)
    try:
        await cooler.send(SLEEP, "sleep (0x19 00 01)")
        await asyncio.sleep(0.5)
    finally:
        try:
            await client.disconnect()
        except Exception:
            pass


def cmd_frames(args):
    """离线打印将要发送的帧，不连蓝牙，用于核对编码"""
    vc = volt_code(args.volt)
    lc = args.led
    fl = getattr(args, "fan_led", None)
    print(f"将要发送的帧（volt={args.volt} -> 电压码 {vc}，duty 为 0-100 百分数）:\n")
    rows = [
        ("握手", HANDSHAKE),
        ("系统使能 0x1A", system_enable_frame(True)),
        ("水泵     0x1C", pump_frame(True, args.duty, args.volt)),
        ("风扇     0x1B", fan_frame(True, max(args.fan, args.fan_min))),
        ("冷头灯   0x1E", head_led_frame(True, *lc)),
        ("风扇灯   0x33", fan_led_frame(fl is not None,
                                        *(fl if fl else (0, 0, 0, 0)))),
        ("查询     0x32", QUERY_METER),
        ("睡眠     0x19", SLEEP),
        ("注水开始 0x19", PRIME_START),
        ("注水停止 0x19", PRIME_STOP),
        ("断线     0x38", LINE_OFF),
    ]
    for name, data in rows:
        print(f"  {name}   {hexs(data)}")
    print("\n对照官方文档：")
    print("  FE 1C 01 DD VV 00 00 EF   泵开，DD=duty(0-100)，VV=电压码(11V=0 12V=1 7V=2 8V=3)")
    print("  FE 1B 01 DD 00 00 00 EF   扇开，DD=duty(0-100)")
    print("  FE 1E 01 RR GG BB MM EF   冷头灯，MM=0常亮 1呼吸 2炫彩 3呼吸变色")
    print("  73 77                     握手（ASCII \"sw\"，无 FE/EF）")


def rgb_arg(s):
    parts = tuple(int(x) for x in s.split(","))
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("需要 r,g,b,mode 四个整数")
    return parts


def common_args(p):
    p.add_argument("--timeout", type=float, default=8.0)
    p.add_argument("--connect-timeout", type=float, default=12.0, dest="connect_timeout",
                   help="单次连接的超时秒数（默认 12，超时会自动重试 3 次）")
    p.add_argument("--session-attempts", type=int, default=8, dest="session_attempts",
                   help="整体建链（连+订阅+握手）的重试次数，默认 8。"
                        "刚连上就断开时调大这个值，比如 20")
    p.add_argument("--name", help="按设备名匹配（不区分大小写，子串）")
    p.add_argument("--address", help="按地址/UUID 精确匹配（macOS 上是一串 UUID）")


def run_args(p):
    p.add_argument("--volt", type=int, default=8, choices=[7, 8, 11],
                   help="水泵电压：7|8|11|12 -> 电压码 2|3|0|1（默认 8）")
    p.add_argument("--pump", type=int, default=8, choices=[7, 8, 11],
                   help="--volt 的别名")
    p.add_argument("--duty", type=int, default=100, help="水泵占空比 0-100（默认 100）")
    p.add_argument("--fan", type=int, default=50, help="风扇占空比 0-100（默认 50）")
    p.add_argument("--fan-min", type=int, default=0, dest="fan_min",
                   help="风扇下限占空比 0-100（默认不干预）")
    p.add_argument("--refresh", type=float, default=5.0,
                   help="重推状态帧的间隔秒数（默认 5）")
    p.add_argument("--led", type=rgb_arg, default=(0, 255, 0, 0),
                   help="冷头灯 r,g,b,mode，默认 0,255,0,0（绿色常亮）")
    p.add_argument("--fan-led", type=rgb_arg, default=None, dest="fan_led",
                   help="风扇灯 r,g,b,mode（Mk1 不支持，默认不发）")
    p.add_argument("--no-led", action="store_true", help="关灯")
    p.add_argument("--no-sysenable", action="store_false", dest="system_enable",
                   help="握手后不发 FE 1A 系统使能（与官方主机行为一致）")
    p.set_defaults(system_enable=True)
    # 智能控制
    p.add_argument("--smart", action="store_true",
                   help="智能模式：按 CPU 负载（或温度）自动调节泵/扇占空比")
    p.add_argument("--smart-preset", choices=list(SMART_PRESETS), default="balanced",
                   dest="smart_preset", help="智能预设：silent/balanced/performance")
    p.add_argument("--temp-cmd", default="", dest="temp_cmd",
                   help='温度命令，输出里的第一个数字当摄氏度，如 "osx-cpu-temp -c"')
    p.add_argument("--temp-min", type=float, default=40.0, dest="temp_min")
    p.add_argument("--temp-max", type=float, default=95.0, dest="temp_max")
    p.add_argument("--pump-min", type=int, default=50, dest="pump_min",
                   help="智能模式下水泵占空比硬下限，避免停转（默认 50）")
    p.add_argument("--hysteresis", type=int, default=3,
                   help="滞回阈值：占空比变化小于该值就不下发（默认 3）")
    common_args(p)


def main():
    ap = argparse.ArgumentParser(
        description="macOS 水冷魔盒控制（依据 Uniwill GCUService 逆向协议）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="扫描附近 BLE 设备")
    s.add_argument("--timeout", type=float, default=8.0)
    s.set_defaults(func=cmd_scan)

    p = sub.add_parser("frames", help="离线打印将发送的帧（不连蓝牙）")
    run_args(p)
    p.set_defaults(func=cmd_frames)

    p = sub.add_parser("run", help="连接并持续控制")
    run_args(p)
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("prime", help="注水/排气（约 68 秒）")
    common_args(p)
    p.set_defaults(func=cmd_prime)

    p = sub.add_parser("probe", help="扫占空比，找出起转点")
    p.add_argument("--volt", type=int, default=8, choices=[7, 8, 11])
    common_args(p)
    p.set_defaults(func=cmd_probe)

    p = sub.add_parser("raw", help="直接下发一帧十六进制")
    p.add_argument("--hex", required=True, help='如 "FE 1C 01 64 03 00 00 EF"')
    common_args(p)
    p.set_defaults(func=cmd_raw)

    p = sub.add_parser("off", help="连接后停泵停扇并断线")
    common_args(p)
    p.set_defaults(func=cmd_off)

    p = sub.add_parser("sleep", help="让魔盒进入睡眠（FE 19 00 01）")
    common_args(p)
    p.set_defaults(func=cmd_sleep)

    args = ap.parse_args()
    if args.cmd == "frames":
        cmd_frames(args)
        return
    try:
        asyncio.run(args.func(args))
    except KeyboardInterrupt:
        print("\n已中断。")
    except SystemExit:
        raise
    except Exception as e:
        sys.exit(f"\n出错：{type(e).__name__}: {e}\n"
                 "（若是刚连上就断开，用 --session-attempts 20 多试几次，"
                 "并给魔盒断电重启一次。）")


if __name__ == "__main__":
    main()
