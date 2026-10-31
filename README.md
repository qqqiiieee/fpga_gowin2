# Tang Primer 20K 多音色乐器 · V047

当前发布为 **V047 配套 FPGA/ESP32 源码、固件、验证材料与操作/架构交接文档**。相对仓库上一版 V034（`d6295e3`），主要增加手机曲谱上传、键位映射、数字录音、三种教学模式、和弦指引及 FFT/李萨如显示；鼓垫组增益提高约 6dB，修正受损引脚避让。中间固件版本由 Git 历史以外的本地归档保存。

**V047 两端已烧录并独立校验，真实 Wi-Fi 上传往返和 30 秒非静音数字 PCM 录音已通过。** 完整模拟输出延迟、32 路实际频谱峰值和物理断电冷启动尚未完成验证；不能据此声称赛题全部验收通过。本次发布不改变板上程序或预载示例曲谱。

| 内容 | 入口 |
|---|---|
| 相比仓库上一版增删与维护重点 | [V034 → V047 更新说明](docs/V034到V047更新说明.md) |
| 给交接者的模块与架构说明 | [项目架构与模块说明](docs/项目架构与模块说明.md) |
| 给交接者的 AI | [AI 快速上手](docs/AI快速上手.md)、[AGENTS.md](AGENTS.md) |
| 手机与四页屏幕操作 | [V046 基础操作指南](docs/V046_手机控制与显示屏指南.html)、[V047 和弦上传补充](docs/V047_更新与曲谱上传指南.html) |
| 当前接线与配套烧录 | [接线与部署](docs/V047_接线与部署.md) |
| 键位重定向与演示拍摄 | [映射教程](docs/V047_键位重定向详细教程.html)、[拍摄参考](docs/V047_演示视频拍摄参考.html) |
| 评分、频谱与延迟边界 | [32 路频谱指南](docs/32路评分与频谱展示/32路评分与频谱展示指南.html)、[资源与延迟](docs/V047_资源与延迟展示指南.html)、[逐项核查](docs/V047_赛题逐项达标核查.html) |
| 固件身份与验证记录 | [manifest.json](manifest.json)、[验证说明](verification/README.md) |

当前功能：32 个独立相位/包络声部，2 种旋律音色，4 种 MIDI 打击乐；KEY/STRUM/HYBRID；MIDI 力度、弯音、延音、CC1；双 FSR 调明亮度和拨弦阻尼。K1/CC93=Delay、K2/CC91=Chorus、K3/CC71=Reverb、K4/CC74=音量，三效果共享引擎、一次启用一种。滑杆、MCP3208、旧矩阵及电容菜单不参与当前生产路径。

HDMI 显示 F2–C5（MIDI 41–72，19 白键/13 黑键）。四页为演奏引导、曲库、FFT/李萨如、诊断。曲库保留小星星、灯阶练习曲、溪桥练习曲；手机可上传一个自定义槽。自动演奏发声、逐音正确才推进、固定 BPM 三模式均已实现；自定义和弦每组最多 4 音。

手机连接 `Tang20K-Music`（密码 `fpga2026`），打开 `http://192.168.4.1/` 调参数，`/extensions` 上传曲谱、提交映射、录音并下载 WAV。需等真实 ACK 和激活状态，HTTP 202 仅表示入队。示例 JSON 在 [examples/V047](examples/V047/)，须在手机选择文件并“保存并上传 FPGA”；固件不内置这些上传演示文件。

| 文件/目录 | 用途 |
|---|---|
| `instrument_handoff.gprj`、`build.tcl`、`src/`、`assets/` | Gowin 工程、RTL、CST/SDC、ROM/字模资产 |
| `instrument_handoff.fs` | V047 FPGA 固件，UserCode `0x00003608` |
| `firmware/esp32/`、`esp32_phone/` | classic ESP32 配套镜像、网页/桥接源码及构建工具 |
| `tests/`、`scripts/` | 回归夹具、可迁移的发布核验入口；历史 bench 不代表全适用当前配置 |
| `verification/` | 本版编译/时序与仿真/实机证据；原报告中的旧时间表示当时状态 |
| `manifest.json`、`checksums.json` | 源码、构建输入、固件及发布文件身份 |

主时钟 27MHz，实际设计输出采样率 **93750Hz**，外接标准 I2S BCK=3MHz，板载 PT8211 并行输出。录音是 FPGA 最终数字 PCM 降采样后的 **15625Hz / PCM16 / mono / 最长30秒**，不是 DAC 模拟回采；设计吞吐 32×93750=300万声部采样/秒，仍需现场频谱证明同时活跃可听。

当前资源：Logic 20381/20736，Register 9540/16173，CLS 10353/10368，BSRAM 41/46，DSP 16.25/24；Setup/Hold 违例均 0。**CLS 只余 15，27MHz 域报告 Fmax 27.03MHz**，任何 RTL 增改均须完整布局布线，不可只看仿真通过。

离线校验（Python 3.11+；RTL 用 Icarus，JSON 用 Node.js）：

```sh
python scripts/verify_release.py
python scripts/run_release_checks.py
```

`IVERILOG_BIN` 可指定同时包含 iverilog/vvp 的目录，否则使用 PATH。这两个入口不烧录、不打开串口、不预载曲谱。默认回归覆盖见 [verification/README.md](verification/README.md)，不冒充全部历史测试的重跑。FPGA 构建优先在已授权 Gowin 1.9.12.04 中执行 `source {完整路径/scripts/rebuild_gui_v047.tcl}`；必须保留 `use_sspi_as_gpio=1` 以启用 N9 上的 ADS SCL。

FPGA SHA256：`d7fa4bbe937d33c69dd5b025d68b557c9088ab918d9c4c70d41f276862fc303f`。
ESP32 应用 SHA256：`7cda05925a9ebe70ebea5322cda401434bd00a0bb958ac381c39fbedf1ea97c7`。
