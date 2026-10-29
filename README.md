# Tang Primer 20K 多音色乐器 · V020 云端工程

本分支 `codex/cloud-v020-20261029` 从当前 V020 工程导入，供 Codex Cloud
修改 RTL、补注释、运行数字仿真和整理文档。原本地工程不变。历史 main 仍是
V015，请在云端确认当前分支及 `src/pressure_expression.v`，避免改到旧版。

## 开始使用

1. 在 Codex 中选择 **Work in → Cloud → Create environment**。
2. 选择 `qqqiiieee/fpga_gowin2`，使用本分支；如果界面未提供分支选择，
   在环境准备会话中明确要求检出 `codex/cloud-v020-20261029`，再运行 setup。
3. 环境准备要求：Python 3.11+、Git、Icarus Verilog / vvp；使用 Ubuntu/Debian
   软件源安装工具，运行 `bash cloud/setup.sh`。本脚本用于云端，不要在本地
   游戏期间安装工具或编译。NumPy / Pillow 供既有离线分析工具使用。
4. 运行 `.venv/bin/python cloud/run_checks.py --suite full`。核对实际报告后
   发布环境。后续新任务选择该环境，直接提出工程修改要求。
5. 先检查 `verification/cloud_import.json` 的 V020 身份与 README；不得把
   环境创建成功当成测试通过。实际配置、发布和云端仿真状态以网页/报告为准。

## 目录与模块

| 路径 | 内容 |
| --- | --- |
| `src/top.v` | 系统入口，音频、遥测、中文 HDMI 交互连接 |
| `src/instrument_audio_top.v` | 输入到声音的生产链，板载音频串行输出 |
| `src/instrument_inputs.v` | ADS、滑杆、FSR、矩阵和远程输入仲裁 |
| `src/performance_input_hub.v` | MIDI / 光弦事件及全局表情处理 |
| `src/midi_*.v` | 31250bps MIDI，音符、力度、延音、控制、清音 |
| `src/optical_strum.v`, `strum_player.v` | 双光束方向/速度检测与扫弦序列 |
| `src/pressure_expression.v` | 双 FSR 基线、死区、连续明亮度/揉弦 |
| `src/voice_allocator.v`, `wavetable_synth.v` | 32 声部分配及共享合成 |
| `src/hdmi_*.v` | 中文四页界面与视频输出 |
| `assets/`, `src/*.hex` | 音色、字体、触摸中心和查找表 |
| `tests/`, `scripts/` | 断言、差分参考、回归和构建工具 |
| `tools/` | 标定、输入监视、串口控制、音频分析工具；物理输入需本地运行 |
| `cloud/` | Linux 环境安装、静态核对和离线回归入口 |
| `docs/wiring_20261029/` | 新完整接线图和逐根线表 |
| `verification/v020_original/` | 原版本软件验证记录，不是新云端测量 |

## 当前硬件行为

板载 3.5mm 输出和 HDMI 显示保留；2 音色、32 声部。MIDI 主键盘为 CH1，
CH10 Note35/36 底鼓、38/40 军鼓。FSR A0 明亮度、A1 揉弦；滑杆 A2 音量、
A3 基础音高。GVS 为三线模拟触摸，经 MCP3208 CH0，首次需逐键标定。
原八线矩阵可作菜单/组合键，R2=M14、R3=T12。双 SEN0503 为 P8/P9。
MAX98357 功放和 ESP32 生产通信尚未启用，屏幕触控与外接灯带不启用。

## 验证边界与返回本地

`cloud/run_checks.py --static` 只检查工程文件、Python 语法、引脚及参考固件。
`--suite smoke` 运行 MIDI UART 和光电测试；`--suite full` 覆盖全部 MIDI、
光电、触摸、压力单元和 FSR/真实 PCM 数字链集成。它不表示每个历史回归、
HDMI 原语或完整资源/时序验证都通过。结果写 `validation/cloud/`，不进 Git。

仓库没有厂商编译器或许可证。云端修改后，提交到任务分支；本地拉取并用
Gowin 构建、检查 setup/hold、烧录和实测耳机、MIDI、光电与压力传感器。
日后如取得可用的 Gowin Linux 安装及授权，再单独配置云端布局布线。

参考固件：`instrument_v020.fs`，UserCode `0x000052D9`，SHA256
`5c8be9899de5b1898337a84fbed230f842eb335a7f9e622e8009a0290019f01f`。
该文件是既有 V020，不是本次新编译结果。

先读 `docs/V020_架构与AI交接.txt` 与根目录 `AGENTS.md`，然后按任务修改。
