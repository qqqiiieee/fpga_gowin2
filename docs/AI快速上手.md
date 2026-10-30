# V034 · AI 快速上手

这是项目代码交接，不是对话摘要。先读根目录 [README](../README.md)、[manifest.json](../manifest.json)、[架构模块说明](项目架构与模块说明.md)，再读 [V015→V034 变化](V015到V034更新说明.md)。

## 身份与验证事实

- 生产入口 `instrument_handoff.gprj` → `src/top.v`；Tang Primer 20K / GW2A-LV18PG256C8/I7。
- 发布 FPGA 为 V034，UserCode `0x000099D5`，SHA256 以 manifest 为准；ESP32 三个源文件和配套 bin 同样有哈希。
- 构建与离线回归通过，**本版两板未烧录**。此前 V033 有板载 MIDI 琴声、显示和手机连通反馈，不代表 V034 完成实测。
- 当前已知待办：生产没有 32 振荡器验证启动入口；内嵌手机帮助仍写旧 T11/P11；PCM5102A 模拟无声未闭环；实际光束/压力/混合听感待验收。
- 本仓库只包含一份当前工程。测试的 legacy/reference 文件用于对照，不是可以替代生产固件的历史版本。

## 生产参数和功能

`MIDI_ENABLE=1`、`OPTICAL_ENABLE=1`、`TOUCH_ENABLE=0`、`DISPLAY_TOUCH_ONLY=1`、`PRESSURE_EXPRESSION_ENABLE=1`、`PHASE_RAM=1`、`PIANO_ROLL_ENABLE=1`。历史参数名不能替代对 generate 分支的检查。

两音色：0 长笛、1 拨弦。32 独立相位/包络/音符槽共享流水线。KEY=0 直接弹奏；STRUM=1 琴键只选和弦；HYBRID=2 允许键盘加光电。SOURCE1 MIDI、SOURCE2 光电同音释放必须隔离。模式变化 Panic 清声音和扫弦队列，正常操作后需松键重按。

FSR A0 明亮度、A1 拨弦阻尼；滑杆/电容菜单/矩阵演奏停用。4 个 Pad 是打击输入。K1/CC93、K2/CC91、K3/CC71 为三效果强度，K4/CC74 总音量；三效果共用一条引擎，软接管后才调节。手机参数 5/6/7 仍是 time/feedback/mod，**不是 K1/K2/K3 强度的别名**。

显示 F2–C5 / MIDI41–72 / 19白13黑，音频接收完整 MIDI 音符。屏幕 highlighter 表示物理 held，不等于声音 gate/busy 或延音尾音。教学是固定三首曲子的视觉时间轴，不是完整评分音游或任意 MIDI 文件播放器。

## 修改入口

| 请求 | 优先读/改的位置 | 必须跟着检查 |
|---|---|---|
| 面板交互 | `four_button_display_control.v`、`top.v` | 松手触发、长短互斥、取消/重武装、手机同拍优先 |
| MIDI/Pad/延音 | `midi_keyboard.v`、`performance_input_hub.v` | 真实 UART、velocity=0、来源 gate/Note Off/Panic |
| 扫弦 | `optical_strum.v`、`strum_player.v`、hub | 极性学习、raw/blocked/ready、最多6音、快速重扫/背压清理 |
| 音色/声部/声音 | `voice_allocator.v`、`wavetable_synth.v`、`instrument_audio.v` | 来源标签、RAM读取延迟、符号位宽、288clk预算/overrun |
| FSR | `pressure_expression.v`、inputs、audio_top/audio | 无载基线和失联；A1传damping，不按旧变量名当vibrato |
| 效果/旋钮 | `midi_control_bank.v`、`audio_effects.v` | actual volume、软接管、独立强度记忆、共享引擎/历史RAM |
| 手机协议 | `phone_control_link.v`、`top.v`、`bridge_core.h`、`web_ui.h` | 范围、真实回读、SEQ/XOR/超时、旧桥兼容、两端构建 |
| 显示/教学 | `piano_layout.vh`、roll score/guide/renderer、compact dashboard | F2几何、原曲音高、帧边界快照、流水/消隐对齐 |
| 32路验证 | `oscillator_test_control.v`、`top.v` | 当前入口缺失；复用test_owned和声音清理，不绕过所有权 |
| 引脚 | `multi_tone.cst`、`matrix_clock.sdc` | PMOD1避让、冲突与IO电压；代码/文档/实际烧录一致 |

## 不可随意破坏的接口

- 27MHz / 93750Hz 采样使能；PCM 16位二补码。保持32份独立相位状态和包络，不能以预混音频冒充验证。
- `valid/ready` 必须保持至消费，Note Off 不能被高优先级事件覆盖后丢掉；同音不同来源不能互相关门。
- 生产 `hdmi_live_display` 通过一个整包握手跨域：339bit；HYBRID最高追加位不移动旧字段。兼容 242/252/289/338 等配置，不用逐位双触发器替代整包一致性。
- PT8211 右对齐与 PCM5102A 标准 I2S 不同，后者声道切换后MSB延迟一个BCK。两个输出都取同一音频帧，不另起异步重采样路径。
- 网页 HTTP 202 是请求入队，只有匹配 ACK/实际读回才确认；断链清待发队列并完整回读，不能重放过期写入。
- 源码/生成资产/固件身份要一致。不要改 RTL 或网页后仍用原二进制、原 UserCode/哈希声称更新完成。

## 检查命令

```sh
python scripts/verify_release.py
python scripts/run_release_checks.py
python scripts/run_release_checks.py --ui --web
```

依赖及 IVERILOG_BIN、Playwright 配置见 README。默认检查不访问硬件。编译 FPGA 用 `scripts/build.py`（GOWIN_HOME）或 Gowin GUI，之后 `scripts/summarize_build.py`；重新检查 Setup/Hold、CLS 与实际帧预算。便携脚本在 Windows 重跑通过，Linux 执行尚未验证。

不要承诺仓库里所有旧 bench 都适用于生产配置；使用当前入口并记录实际覆盖。核心集成对 HDMI 使用边界桩，显示由独立像素/CDC回归检查；离线像素捕获不能替代实屏照片或模拟音频测量。

## 固定接线事实

MIDI T8；光电 P8/P9；ADS D14/E15；I2S B14/A15/B13；面板 A11/B11/N6/D11；手机 L9 RX←ESP D17、N8 TX→D16、公共GND；FTDI T13/M11。两块板3V3输出不并联。冲突以 CST 为准，不能照网页旧帮助 T11/P11 接线。

改动按新编号独立保存本地版本，文档/记录可以在同版更新，不覆盖旧固件。用户未要求时不自动烧录、修改引脚或把对话/机器账号配置上传仓库。重点保持工程可读、可验证，诚实区分“编译/仿真通过”和“已烧录/实机通过”。
