# Tang Primer 20K 多音色乐器 V015

当前仓库提供 V015 的生产工程、匹配固件、回归材料及两份最新架构交接文档。

- 16 音色、32 个独立相位与包络状态，共享波表和运算流水。
- 两路压力分别触发底鼓和军鼓；两路滑杆控制总音量与旋律弯音。
- 四页中文界面、三首跟弹曲库，以及 32 个不同频率的验证模式。
- 主时钟 27MHz，音频采样率 93750Hz；当前输出为板载 PT8211 的 16 位右对齐链路。

## 交接文档

- [项目架构与模块说明](docs/项目架构与模块说明.docx)：37 个生产模块的职责、数据流及维护重点。
- [AI 快速上手](docs/AI快速上手.txt)：代码阅读顺序、接口契约及修改定位。

## 工程结构

| 路径 | 内容 |
| --- | --- |
| `instrument_handoff.gprj` | 当前 Gowin 工程，顶层 `top` |
| `src/` | 生产 RTL、约束、波表和字模 |
| `assets/` | 界面文字、字模映射及独立布局期望 |
| `scripts/` | 文本生成、构建和分组回归 |
| `tests/` | 本版测试 bench、必要对照夹具和主机模拟测试 |
| `tools/` | 电脑侧虚拟输入、采集及离线分析 |
| `instrument_handoff.fs` | 已构建的 V015 固件 |
| `manifest.json` | 固件身份、源码及交接文档哈希 |
| `verification/software_summary.json` | 当前软件验证范围与结果 |

## 构建与回归

使用 Python 3.11、Gowin 1.9.12.04 和 Vivado 2023.2 的 XSim；UI 与频谱脚本需要 `requirements.txt` 中的依赖。
通过 `GOWIN_HOME`、`XILINX_VIVADO` 指定本机安装根，或者使用脚本的对应命令行参数。脚本从自身路径定位工程。

```powershell
python -B scripts/generate_ui_text.py --check
python -B scripts/build.py
python -B scripts/run_tests.py --group all
```

`tests/` 中的少量 reference/legacy 文件是本版等价性回归的必要输入，不是额外的可运行旧版本。
本机设备配置与生成日志不纳入仓库。

## 当前状态

V015 构建、时序及软件回归通过；本固件实机验证尚未确认。外接 MAX 音频端口固定为 0，USB 触控主机未实现。
具体软件验证范围见 `verification/software_summary.json`。像素时钟仅约 0.44MHz 时序余量，扩展显示逻辑需重新检查。

固件 UserCode：`0x00006DA0`。
固件 SHA256：`20dbffca8677a5ce6091a6189f30489d0d019914f64e61ed178776ebde29d30c`。
