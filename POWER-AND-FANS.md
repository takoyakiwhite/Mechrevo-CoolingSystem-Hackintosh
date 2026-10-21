# 机身功耗墙 / 风扇曲线 / 性能模式 —— macOS 可行性方案

先说结论：**能，但不是用户态的事**。这台机器上「性能模式 / 功耗墙 / 风扇表」全部落在
EC（嵌入式控制器）里，Windows 侧要么走 ACPI-WMI 邮箱，要么直接用端口 I/O 刷 EC RAM。
macOS 没有 WMI 驱动、也没有用户态端口 I/O，所以要么靠 kext，要么靠「先在 Windows 设好、
让 EC 自己记住」。

---

## 0. 你这台机器的事实（已核实）

| 项 | 值 | 来源 |
| --- | --- | --- |
| 机型 / 主板 | MECHREVO Yaoshi16Super Series **GM6IX9B** | `Win32_ComputerSystem` / `Win32_BaseBoard` |
| CPU | Intel Core **i9-14900HX** | `Win32_Processor` |
| OpenRevo 机型 ID | `GM6IX9B`，project_id **25**，BIOS project `IDB` | `%APPDATA%\OpenRevo\models.json`（`"mine": true`） |
| 出厂三档 PL1/PL2/PL4 | 办公 45/45/125W，平衡 75/75/125W，狂暴 205/205/200W | 同上 `factory_specs` |
| OpenRevo 狂暴预设 | PL1 205W / PL2 205W / **PL4 230W**，TccOffset 5 | 同上 `presets.turbo` |
| 风扇表（狂暴，10 级） | CPU 起转 55°C→duty 60，58°C→70，61°C→80，65°C→100，69°C→110，72°C→120，75°C→130，78°C→150，81°C→160，84°C→**180**（raw 0–255） | 同上 `fan_tables.turbo` |
| 支持水冷 | `has_water_cooler: true`，base_tgp 225W | 同上 |
| Windows 侧控制通道 | `root\wmi` 里**没有** `OemWMIMethod` 类，只有 `AcpiTest_*`（GUID `{ABBC0F6a-8EA1-11d1-00A0-C90629100000}` 这套微软 ACPI 测试 GUID）→ 功能挂在 `AcpiTest_WMI`（PNP0C14）设备上，方法 `OemWMIfun`，in 64B / out 256B | 本机 WMI 查询 + open-revo 内嵌 model-driver |
| EC 侧 | open-revo 的 `ec-config` 插件用 `inpoutx64.dll` 直接做端口 I/O 刷 ECRAM（`EC Service RPL APP for Tongfang`） | `plugins/ec-config/` |

WMI 调用长这样（来自内嵌 driver，Intel 机型通用）：

```json
"set_cpu_spl":  { "channel": "wmi_mailbox", "input": [0, 251, 0, 23, 2, "{val}"] },
"set_cpu_sppt": { "channel": "wmi_mailbox", "input": [0, 251, 0, 23, 3, "{val}"] },
"set_cpu_temp_wall": { "channel": "wmi_mailbox", "input": [0, 251, 0, 23, 4, "{val}"] }
```

即 `OemWMIfun(0x00, 0xFB, 0x00, 0x17, <2=Spl/3=Sppt/4=TjMax>, <W>)`，读风扇转速是 `input: [2, 1]`，
返回 u16_le 的 CPU/GPU RPM。**这就是要在 macOS 上复刻的东西。**

---

## 1. 四条路，按性价比排序

| # | 方案 | 能做什么 | 工作量 | 风险 |
| - | ---- | -------- | ------ | ---- |
| A | Windows 里设好，让 EC 记住 | 性能模式、PL1/PL2/PL4、风扇表（静态档位） | 10 分钟 | 无（可逆） |
| B | MSR 直写 PL1/PL2（VoltageShift，Intel 专用） | 只有功耗上限，无风扇曲线/无 PL4 | 10 分钟 | 低 |
| C | 自写 Lilu 插件 + ACPI 方法调用（等价 WMI） | 全套：三档、PL1/2/4、TccOffset、风扇表、GPU TGP | 几天，要懂 kext | 中（ACPI 方法调错会写坏 EC） |
| D | 自写 kext 直接 EC 端口 I/O | 最强，连 OEM 没开放的字段也能动 | 几周，要逆向 EC 表 | 高（写错可能风扇失控/黑屏） |

macOS 侧不论哪条路，**动态风扇曲线都得自己写**：hackintosh 上 VirtualSMC 不模拟风扇控制，
没有 `F0Ac` 这类 SMC 键可写，温度只能从 `SMCProcessor` 的 `TC0P/TC0D` 读。

---

## 2. 先做 A（今天就能验证，成本最低）

EC 的设置是**跨系统持久**的（EC 有独立供电，BIOS 重置/掉电才会丢），所以：

1. Windows 进 open-revo → 选「高能狂暴」、把风扇曲线拉到你要的档、关掉「智能」策略
   （智能 RAMP 是 Windows 侧软件每秒算的，重启就没）。
2. 记下 HWiNFO 里 `PL1/PL2` 和双烤时的封装功耗、风扇 RPM。
3. 重启进 macOS，跑 `pmset -g therm`、`powermetrics --samplers smc -i 1000`，
   再跑个 `yes > /dev/null &` 满载，看是否还能吃到同样功耗、风扇是否按 EC 表升速。

- 如果功耗和转速都继承了 → **你已经拥有 90% 的「性能模式」**，剩下的只是显示/切换 UI。
- 如果被拉回办公室档 → EC 每次上电会复位，必须走 B/C/D。

> 另一个免费技巧：BIOS 里若有「性能模式/风扇模式」项，设成固定值同样会被 EC 记住，
> 比任何软件方案都稳。

## 3. 方案 B：MSR 直写（你是 i9-14900HX，可用）

```bash
# VoltageShift（需关闭 SIP 的一部分并加载其 kext）
sudo ./voltageshift power 205 205      # PL1/PL2 单位 W，写 MSR 0x610
sudo ./voltageshift read 0x610         # 回读确认
```

能立刻把 CPU 长/短时功耗上限顶上去，但**不碰风扇、不碰 PL4/TccOffset/GPU TGP**，
而且 OEM 的 EC 有可能周期性把 0x610 重新写回（表现为「过几秒又掉功耗」），
这时只能走 C/D。

## 4. 方案 C：kext + ACPI 方法（等价 WMI，推荐的正路）

思路：Windows 的 WMI 最终也是调 ACPI 里的 `OemWMIfun`，那就在 macOS 的 kext 里
用 `IOACPIPlatformExpert::evaluateObject` 调同一个方法 —— 完全绕开「macOS 不支持 WMI」。

1. **SSDT 包装**（把 OEM 方法暴露成一个固定入口，方便 kext 调，也方便加保护）：

```asl
DefinitionBlock ("", "SSDT", 2, "ORV", "WMIFN", 0x00000001) {
    External (_SB.PC00.LPCB.EC0.OemWMIfun, MethodObj)   // 用 ioreg/ACPI dump 确认路径

    Method (WMFN, 2, Serialized) {                       // Arg0 = 输入 Buffer(64)，Arg1 = 输出 Buffer(256)
        Local0 = \_SB.PC00.LPCB.EC0.OemWMIfun (Arg0, Arg1)
        Return (Local0)
    }
}
```

2. **kext 侧调用**（Lilu 插件，或直接 IOService）：

```cpp
IOACPIPlatformDevice *dev = /* 从 IORegistry 找 PNP0C14 / AcpiTest_WMI 设备 */;
OSObject *argv[2] = { inBuf, outBuf };   // OSData，64B / 256B
OSObject *ret = nullptr;
dev->evaluateObject("WMFN", &ret, argv, 2);
```

3. **用户态接口**：kext 注册 `IOUserClient`，`wcooler` 这类 CLI/App 用 `IOConnectCallStructMethod`
   发 `[0,251,0,23,2,205]` 这种 6 字节命令，拿回 256B 结果。

4. 有了这条通道，三档预设、PL1/2/4、TccOffset、风扇表（`cpu_upt/cpu_downt/cpu_duty` 三段数组）
   就能 1:1 复刻 open-revo；风扇曲线的「温度→duty」映射在国际化上其实只是一张 10 级表，
   直接把 `models.json` 里 `fan_tables.turbo` 抄进去即可。

**先试现成的**：`YogaWMI`（zhen-zen/YogaSMC 里的子项目）就是「在 macOS 上解析 ACPI-WMI 设备
并调用其方法」的实现，理论上把你机器的 `AcpiTest_WMI` 设备喂给它就能直接调 `OemWMIfun`。
它主要面向 Lenovo，设备名/类名要按需改；成本低，值得先花半天试。

## 5. 方案 D：kext 直接写 EC（最强也最险）

open-revo 自己就是这么干的（`inpoutx64.dll` → 端口 0x62/0x66），kext 里等价代码：

```c
static inline void ec_wait(void) { for (int i = 0; i < 100000 && (inb(0x66) & 0x02); i++); }

UInt8 ec_read(UInt8 addr) {
    ec_wait(); outb(0x66, 0x80); ec_wait(); outb(0x62, addr);
    for (int i = 0; i < 100000 && !(inb(0x66) & 0x01); i++);
    return inb(0x62);
}

void ec_write(UInt8 addr, UInt8 val) {
    ec_wait(); outb(0x66, 0x81); ec_wait(); outb(0x62, addr);
    ec_wait(); outb(0x62, val);
}
```

前提是先把 EC 全表 dump 出来、和「改前/改后」做 diff 找出 PL/风扇表的偏移
（在 Windows 上用 `ec-config` 插件或 RWEverything dump 一份，边改 open-revo 边看哪些字节变）。
注意：Apple 的 `AppleACPIEC` 可能已经占了这对端口，得先确认 `IORegistry` 里 EC 设备的归属。

## 6. 风险与回滚

- 任何 EC 写入前：**先 dump 全表并存盘**，并准备一个 Windows PE/安装 U 盘。
- 风扇表写成非法值时，有的模具会锁在最低转速（过热降频）或全速（吵但安全）；
  遇到异常先长按电源 15 秒放静电（EC 复位），必要时拔电池排线。
- PL4/TccOffset 比 PL1/PL2 危险得多（直接改温度墙），一次只动一个字节。
- kext 崩溃会五国；用 `-liludbg` / `keepsyms=1` 引导排错，配置保持一份可用 EFI 备份。

---

## 7. 建议顺序

1. 今天：走 **A**，确认 EC 是否记住了狂暴档（这决定后面要不要写 kext）。
2. 想动态调功耗：**B**（VoltageShift，10 分钟）。
3. 想完整复刻 open-revo：先花半天试 **YogaWMI**，不行再写 **C** 的 SSDT + kext。
4. 只有 C 也满足不了（比如要改 OEM 未开放的字段）才考虑 **D**。
