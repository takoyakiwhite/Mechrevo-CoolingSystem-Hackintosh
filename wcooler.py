#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
wcooler.py —— 在 macOS 上通过蓝牙控制机械革命「水冷魔盒」

协议来源：逆向 open-revo（Tauri/Rust）+ 其运行日志 open-revo.log 中 BLE_TX 记录。
机械革命水冷魔盒是一个 BLE 外设，走 Nordic UART Service(NUS) 串口透传：

    service  6E400001-B5A3-F393-E0A9-E50E24DCCA9E
    write    6E400002-B5A3-F393-E0A9-E50E24DCCA9E   (主机 -> 魔盒)
    notify   6E400003-B5A3-F393-E0A9-E50E24DCCA9E   (魔盒 -> 主机)

帧格式： FE <cmd> <b1> <b2> <b3> <b4> <b5> EF   (8 字节)
    0x1C 水泵    b1=使能 b2=电压(V) b3=占空比(%) 
    0x1B 风扇    b1=使能 b2=占空比(%)
    0x1E 灯效    b1=开关 b2..b4=RGB b5=模式
    0x33 灯效    payload 与 0x1E 相同（open-revo 会成对发送）
    0x32 查询    每 ~3 秒一次（保活/流量查询）
握手帧不是 FE..EF 包裹，而是 2 字节 ASCII "sw" = 73 77。

用法：
    pip3 install bleak
    python3 wcooler.py scan
    python3 wcooler.py run  --pump 7 --duty 45 --fan 55 --led 0,128,0,2
    python3 wcooler.py run  --name "..." --curve      # 按 CPU 温度曲线跑
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

HANDSHAKE = bytes([0x73, 0x77])          # "sw"
QUERY = bytes([0xFE, 0x32, 0, 0, 0, 0, 0, 0xEF])


def frame(cmd: int, payload) -> bytes:
    body = list(payload)[:5]
    body += [0] * (5 - len(body))
    return bytes([0xFE, cmd] + body + [0xEF])


def pump_frame(enabled: bool, volt: int, duty: int) -> bytes:
    v = int(volt) if enabled else 0
    d = int(duty) if enabled else 0
    return frame(0x1C, [1 if enabled else 0, v, d, 0, 0])


def fan_frame(enabled: bool, duty: int) -> bytes:
    return frame(0x1B, [1 if enabled else 0, int(duty) if enabled else 0, 0, 0, 0])


def led_frames(on: bool, r: int, g: int, b: int, mode: int):
    p = [1 if on else 0, r if on else 0, g if on else 0, b if on else 0, mode if on else 0]
    return [frame(0x1E, p), frame(0x33, p)]   # open-revo 会两个 cmd 各发一次


def hexs(data: bytes) -> str:
    return " ".join(f"{x:02X}" for x in data)


class Cooler:
    def __init__(self, client: BleakClient):
        self.client = client
        self.last_notify = 0.0

    async def send(self, data: bytes, tag: str = ""):
        await self.client.write_gatt_char(NUS_WRITE, data, response=True)
        print(f"  -> {hexs(data):<26} {tag}")

    async def start_notify(self):
        def handler(_sender, data: bytearray):
            self.last_notify = time.time()
            print(f"  <- {hexs(bytes(data))}")

        try:
            await self.client.start_notify(NUS_NOTIFY, handler)
        except Exception as e:  # 有的固件不主动 notify，不影响控制
            print(f"  (notify 订阅失败，忽略: {e})")

    async def shutdown_frames(self):
        """open-revo 退出/睡眠时发的收尾帧：先停泵，再停风扇、关灯。"""
        for data in (pump_frame(False, 0, 0), fan_frame(False, 0)):
            try:
                await self.send(data, "shutdown")
                await asyncio.sleep(0.07)
            except Exception:
                pass
        for data in led_frames(False, 0, 0, 0, 0):
            try:
                await self.send(data, "shutdown")
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
        mark = " <-- 疑似水冷魔盒" if (dev.name and any(
            k in dev.name for k in ("Cooler", "cooler", "MECHREVO", "Mechrevo", "WATER", "水冷"))) else ""
        print(f"{str(dev.address):<40} rssi={adv.rssi:<5} name={dev.name!r} services=[{uuids}]{mark}")


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

    # 没指定时：优先找广播了 NUS 服务或名字像水冷的
    for dev, adv in found.values():
        if NUS_SERVICE in [str(u).lower() for u in (adv.service_uuids or [])]:
            return dev
    for dev, _ in found.values():
        if dev.name and any(k in dev.name for k in ("Cooler", "cooler", "MECh", "Mech", "WATER", "水冷")):
            return dev
    raise SystemExit("没找到疑似水冷魔盒，先用 scan 看看，再用 --name / --address 指定")


async def cmd_run(args):
    dev = await pick_device(args)
    print(f"连接 {dev.name!r} ({dev.address}) …")

    def on_disconnect(_client):
        print("!! 连接断开")

    async with BleakClient(dev, disconnected_callback=on_disconnect) as client:
        print("已连接，握手…")
        cooler = Cooler(client)
        await cooler.send(HANDSHAKE, "handshake")
        await asyncio.sleep(0.1)
        await cooler.start_notify()

        # 初始状态：先停泵，再按目标值设置（和 open-revo 的连接顺序一致）
        await cooler.send(pump_frame(False, 0, 0), "pump init")
        await asyncio.sleep(0.08)
        await cooler.send(fan_frame(True, args.fan), f"fan {args.fan}%")
        await asyncio.sleep(0.08)
        await cooler.send(pump_frame(True, args.pump, args.duty), f"pump {args.pump}V/{args.duty}%")
        await asyncio.sleep(0.08)
        if args.no_led:
            for f in led_frames(False, 0, 0, 0, 0):
                await cooler.send(f, "led off")
                await asyncio.sleep(0.08)
        else:
            r, g, b, m = args.led
            for f in led_frames(True, r, g, b, m):
                await cooler.send(f, f"led rgb({r},{g},{b}) mode={m}")
                await asyncio.sleep(0.08)
        await cooler.send(QUERY, "query")

        stop = asyncio.Event()

        def _sig(*_a):
            stop.set()

        loop = asyncio.get_running_loop()
        for s in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(s, _sig)
            except NotImplementedError:
                pass

        print("\n运行中，Ctrl+C 退出（会先停泵再断开）…\n")
        last = 0.0
        while not stop.is_set():
            try:
                await asyncio.wait_for(stop.wait(), timeout=3.0)
            except asyncio.TimeoutError:
                pass
            if stop.is_set():
                break
            # 每 ~3s 一次保活/流量查询
            if time.time() - last >= 3.0:
                try:
                    await cooler.send(QUERY, "query")
                except Exception as e:
                    print(f"查询失败：{e}")
                    break
                last = time.time()

        print("退出：发送停止帧…")
        await cooler.shutdown_frames()
        await asyncio.sleep(0.2)
        await client.disconnect()


async def cmd_off(args):
    dev = await pick_device(args)
    async with BleakClient(dev) as client:
        cooler = Cooler(client)
        await cooler.send(HANDSHAKE, "handshake")
        await asyncio.sleep(0.1)
        await cooler.shutdown_frames()
        await asyncio.sleep(0.2)


def main():
    ap = argparse.ArgumentParser(description="macOS 机械革命水冷魔盒控制（复刻 open-revo 的 BLE 协议）")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="扫描附近 BLE 设备")
    s.add_argument("--timeout", type=float, default=8.0)
    s.set_defaults(func=cmd_scan)

    for name, func, hlp in (("run", cmd_run, "连接并持续控制"), ("off", cmd_off, "连接后只发停止帧")):
        p = sub.add_parser(name, help=hlp)
        p.add_argument("--timeout", type=float, default=8.0)
        p.add_argument("--name", help="按设备名匹配（不区分大小写，子串）")
        p.add_argument("--address", help="按地址/UUID 精确匹配（macOS 上是一串 UUID）")
        p.add_argument("--pump", type=int, default=7, help="水泵电压 V（0-12，7=标准档）")
        p.add_argument("--duty", type=int, default=45, help="水泵占空比 %%（标准档 45）")
        p.add_argument("--fan", type=int, default=55, help="风扇占空比 %%")
        p.add_argument("--led", default="0,128,0,2", help="灯效 r,g,b,mode，默认 0,128,0,2")
        p.add_argument("--no-led", action="store_true", help="关灯")
        p.set_defaults(func=func)

    args = ap.parse_args()
    if getattr(args, "led", None):
        try:
            args.led = tuple(int(x) for x in args.led.split(","))
            assert len(args.led) == 4
        except Exception:
            ap.error("--led 需要 r,g,b,mode 四个 0-255 的整数")
    asyncio.run(args.func(args))


if __name__ == "__main__":
    main()
