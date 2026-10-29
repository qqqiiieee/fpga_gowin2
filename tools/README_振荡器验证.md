# 32 振荡器主机验证工具

本目录保留 V009 的工具、support 和原有 73 项单元测试，新增 `oscillator_test.py`、`analyze_oscillators.py`、`launch_oscillator_test.py` 及三个 `test_*.py`。测试文件仅用于开发；打包运行工具时排除根目录 `test_*.py` 和 `__pycache__`，保留 `support`。V009 原测试内容与行为不变，`test_capture_pipeline.py` 仍以 `audio_devices` 模块名模拟输入枚举。

此次实现与单元测试没有连接真实串口、启动真实录音、读回真实 FPGA 或烧录。后续只有实际采集和检查接线后，才能说明硬件验证结果。

## 先查看计划

下面的设备 ID、名称、COM 口是示例，实际运行必须替换。计划模式不检查设备是否存在、不读取 manifest、不创建目录、不执行 JTAG、串口或音频操作，可用标准库 Python 3.11 运行。

```powershell
py -3.11 -B .\oscillator_test.py --port COM8 --device-id 2 --device-name "麦克风 (USB-Audio)" --manifest "C:\已打包版本\版本信息.json" --output-dir "C:\已有测量目录" --plan-only --independence
```

打包的 ASCII、CRLF `.cmd` 可以改用 `launch_oscillator_test.py`，把设备配置和 manifest 路径显式传入，避免在 `.cmd` 正文写中文设备名称或文件名。例如从 `tools` 目录查看计划：

```powershell
py -3.11 -B .\launch_oscillator_test.py --config "..\device_config.json" --manifest "..\manifest.json" --output-dir "..\measurements" --plan-only --independence
```

`device_config.json` 使用 UTF-8（也接受 UTF-8 BOM），格式示例：

```json
{"port":"COM8","device_id":0,"device_name":"麦克风 (USB-Audio)"}
```

示例值必须替换成明确选择的当前设备。配置只允许这三个字段；缺失、重复、多余字段、错误类型、无效 COM 口、默认设备编号或非 USB-Audio 名称都会拒绝。设备名称逐字保留，不去除空格。启动器不枚举、不自动选择设备、不回退到其他设备，只把配置转成主工具的显式参数，并转发两个可选开关及退出码。计划模式只读取指定配置，不读取 manifest 或写出文件。`manifest.json` 的镜像内容与 `版本信息.json` 一致由打包流程保证，启动器不会复制或修改它们。

正式运行应使用已带 numpy、Pillow 的 Python；不需要安装依赖。此机器已有：

```powershell
$oscPython = 'C:\Users\31989\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
```

## 后续真实运行的准备

1. 先由用户按项目流程准备匹配的新固件与 manifest。工具不含烧录命令。manifest 必须提供 `firmware_name`、64 位小写十六进制 `sha256` 和形如 `0x12345678` 的真实 `usercode`；不要使用示例 UserCode。
2. 把仪器的音频输出接入 USB-Audio 录音输入，选择正确输入模式和增益。检查 AGC/音效设置，避免自动改变增益；主机工具不代替输入标定或接线检查。
3. `remote_control.py list` 只枚举串口；`list_audio_inputs.py` 只枚举 WinMM 输入。明确选择当前 FTDI `COMn`、当前 WinMM 数字 ID 和当前完整 USB-Audio 名称。ID 不是 sounddevice ID。相同 ID 名称变化、单声道端点或非 FTDI 端口会拒绝运行，不使用默认设备。
4. 指定已经存在的输出目录。程序按 Asia/Shanghai（UTC+08:00）的当前时间创建新的时间戳子目录，不依赖 Windows 的本地时区设置，文件独占创建，不覆盖旧记录。控制事件仍保留 UTC 和单调时钟时间。

以后在用户允许真实测试时运行：

```powershell
& $oscPython -B .\oscillator_test.py --port COM8 --device-id 2 --device-name "麦克风 (USB-Audio)" --manifest "C:\已打包版本\版本信息.json" --output-dir "C:\已有测量目录"
# 可选：在主测试后再进行一次独立性扫描
& $oscPython -B .\oscillator_test.py --port COM8 --device-id 2 --device-name "麦克风 (USB-Audio)" --manifest "C:\已打包版本\版本信息.json" --output-dir "C:\已有测量目录" --independence
```

执行串口控制之前，工具先核对 manifest 对应固件 SHA256，再调用保留的 `verify_firmware.py` 独立执行 Gowin `--run 73` UserCode 只读回读，检查回读 JSON 内容与退出码。`verify_firmware.py` 的 Programmer 路径沿用 V009；打包时应检查路径适合目标机器。UART 协议版本 08 的握手不能代替这项版本验证。

## 控制顺序与时间

所有虚拟输入都使用 V009 `remote_control.Controller`、`WindowsSerial`、`verified_ftdi`，沿用协议 08 及原有字段，没有新增 UART 标志。活动请求严格匹配 ACK 的序号、flags、keys 和 ADC。连续两次 ACK 丢失/不匹配即停止，整个采集等待期间每 100 ms 继续发送当前状态。日志保留整个有限会话的控制事件，包括序号回绕、UTC 时间和单调时钟时间。

ACK 状态高位含义为：bit7=`synth_overrun`、bit6=`ghost`、bit5=`ready`、bit4=`stale`、bit3=实体 ADC fault。振荡器控制器在活动控制期间观察到任意有效 ACK 的 bit7，就锁存首次事件、停止测试并返回 `fail`，日志和终端摘要明确写出 `synth_overrun` 原因；仍执行 S16 和 DISABLED 的最终释放流程。有效但迟到/不匹配的活动 ACK 也不能掩盖 overrun，后续 bit7 清零不会消除已锁存的失败。单独的 bit3 不判振荡器测试失败，测试模式下实体 ADC 可能未连接。固件控制器波形的验收要求是 `overrun_tb=0`，该波形须由固件仿真流程确认，本次主机离线测试不声称检查了真实固件波形。

录音通过原生 WinMM `waveIn` 进行。输入名称在 worker 中再次核对；成功 `waveInStart` 后还必须观察 `waveInGetPosition(TIME_BYTES)` 的实际采集进度，再发就绪通知。主机等到这个通知后才发送进入测试模式的按键。无法报告进度、通知过迟或时间无效会中止。

主测试采用一次 11 秒有限原始采集：

1. 采集就绪后，精确发送 S13+S15，`keys=0x5000`，保持 2.2 秒。固件在进入模式时先进行约 21.8 ms 正常模式淡出，再进行约 21.8 ms 测试模式淡入。
2. 发 `keys=0`，等待 0.1 秒，默认 32 声部。主机继续保持零键活动输入。
3. 从该时刻在原始 WAV 中截取完整 8 秒，保存 `bank32.wav`；保留 `bank_native.wav` 以便核查前导、时间位置及录音完整性。若原始采集不足以容纳完整 8 秒，拒绝完成。

可选独立性测试采用另外一次 32.6 秒采集。等待其真实采集就绪后，S6 `keys=0x0020` 脉冲保持 0.08 秒后归零。固件自主从声部索引 0 的 OFF 开始，依次执行 OFF 0.5 秒、ON 0.5 秒，共 32 秒。主机在整个扫描及录音完成等待期间保持 100 ms 零键 keepalive，不用主机逐个模拟声部开关。0.6 秒包含扫描前后余量；若起始太迟，拒绝完成。

固件模式按键：

| 按键 | 声部数/动作 | mask |
|---|---:|---:|
| S1 | 1 | `0x0001` |
| S2 | 4 | `0x0002` |
| S3 | 8 | `0x0004` |
| S4 | 16 | `0x0008` |
| S5 | 32 | `0x0010` |
| S6 | 自主 32 声部 OFF/ON 扫描 | `0x0020` |
| S16 | 退出测试模式 | `0x8000` |

成功或异常结束时，主机都尝试 S16 保持 0.08 秒，再发 DISABLED 并检查释放 ACK。若握手未成功，协议禁止发送活动按键，只能尝试 DISABLED。S16 的 ACK 只是按键回显，DISABLED 的 ACK 只证明远程输入释放；不存在“测试状态 ACK”，主机不会声称通过它验证固件内部状态。释放或 S16 回显未确认，则采集不算成功。DISABLED 让 `remote_active` 源下降，固件应淡出/退出；1 秒远程 watchdog 也应触发退出，但本工具不把未观察的 watchdog 当作成功。实体进入模式后 60 秒无操作自动退出由固件实现，本工具不验证实体按键或该计时器。

单次原生采集最多 40 秒，默认 8 秒；超过 8 秒必须显式传 `--seconds`。worker 内有采集超时，父进程另外以“请求时长 + 8 秒”为监督期限；异常时终止自己创建的 worker，回收等待最多 3 秒。不会为一次录音进行 70 秒阻塞等待。实际控制循环采用短等待，同时处理 ACK 和 keepalive。

## 报告和离线判定

运行目录包括绝对路径的 WAV、采集就绪 JSON、`firmware_readback.json`、完整 `controller_events.json`、`oscillators.json`、32 行频率 `oscillators.csv` 和 `oscillators.png` FFT 图。日志记录原始采集起点、8 秒截取起点与控制 request/ACK 时间。图上的大 5 kHz 峰可以显示，但不会替代指定频率的声部证据。

目标频率为 `400 + 97*i`，`i=0..31`。DDS 实际频率为：

```text
round(f * 2^24 / 93750) * 93750 / 2^24
```

判定只接受 48000 Hz、双声道、PCM16，合并两通道频谱功率，避免反相立体声抵消。逐个搜索指定 DDS 频率附近的峰，要求误差不超过 `max(3 Hz, DDS频率*0.2%)`、局部突出度至少 12 dB、峰值至少 -72 dBFS，并且所有样本都没有出现 `32767` 或 `-32768` 满量程值。强度门槛是主机测量充分性规则，不是硬件性能指标。

已有至少 24 个可靠指定声部时，缺失峰可判失败；全静音、过低输入、纯噪声、孤立 5 kHz 声音无法证明指定声部银行，返回 `inconclusive`，不会假通过。明显偏频或满量程削波可判失败。谐波、全局最大峰不能替代 32 个指定峰。

独立性扫描在每个 OFF/ON 半秒区间两侧留出 150 ms，比较各 200 ms 稳态窗。在对应 DDS 频率做窗函数复数投影，目标声部下降至少 15 dB，其余 31 峰变化不超过约 3 dB。若 OFF 已到噪声底，采用保守衰减下界；噪声无法支持 15 dB 证明则 `inconclusive`。缺少时序、request/ACK 区间超过 80 ms、标注不确定性超过 100 ms、真实采集进度未确认或 32 秒扫描不完整，均不通过独立性检查。

**FFT 的时间标定是近似的。** 以 WAV 首样本与 `waveInStart`、串口发送/回显时间对齐，没有硬件时间戳、固件内部状态标志或驱动延迟标定。若可观察的声部 0 OFF→ON 边界与主机预计时间相差超过 100 ms，返回 `inconclusive`，不会自动挪动时间窗求通过。切窗保护边界不等于精确校准。判断不确定时保留文件，核查时间、增益、噪声和接线再重测。

完全离线重分析，不会调用采集或串口：

```powershell
& $oscPython -B .\analyze_oscillators.py --wav "C:\测量结果\bank32.wav" --output-dir "C:\新的离线报告目录"
& $oscPython -B .\analyze_oscillators.py --wav "C:\测量结果\bank32.wav" --independence-wav "C:\测量结果\independence32.wav" --run-json "C:\测量结果\controller_events.json" --output-dir "C:\新的离线报告目录"
```

输出目录需已存在且报告文件未存在。退出码：`0=pass`、`1=fail`、`2=inconclusive`。采集成功只表示取得了完整音频及确认的控制回显；声部指标是否通过由离线分析另行决定。

## 开发测试

```powershell
& $oscPython -B -m unittest discover -s . -p 'test_*.py'
```

原有 73 项 V009 测试继续使用原内容。新测试覆盖 32 正弦波、单声部缺失/偏频、频率容差、谐波、强/孤立 5 kHz、反相立体声、正负满量程、静音/噪声、完整自主扫描、未消失声部、其他声部误变、时序不充分、离线报告，以及假 FTDI/ACK、就绪顺序、100 ms keepalive、两次 ACK 丢失、worker 超时和异常释放。启动器测试覆盖 Unicode/BOM、严格配置校验、显式参数和退出码转发、只读计划，以及上海时区的跨午夜目录日期。所有新测试放在根目录 `test_*.py`，运行代码不导入测试模块。
