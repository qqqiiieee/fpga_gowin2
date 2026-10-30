# V034 验证范围

`manifest.json` 是固件与构建输入的身份入口；`checksums.json` 是当前发布文件校验清单。

| 证据 | 范围 |
|---|---|
| [build_summary.json](build_summary.json) | 实际 Gowin 综合/布局布线后的资源、时序、Fmax、UserCode 和固件 SHA256 |
| [place_route_report.txt](place_route_report.txt)、[timing_report.txt](timing_report.txt) | 构建报告摘存；仅规范化开发机目录字符串，未改写数值 |
| [software_summary.json](software_summary.json) | 离线检查结果与实机边界，含发布工作目录重跑结果 |
| [source_delta_v015_v034.json](source_delta_v015_v034.json) | 相对远端 V015 的源码增加/修改/保留清单；不是运行功能数量 |
| [mode_headers.png](mode_headers.png)、[hybrid_piano.png](hybrid_piano.png) | 实际 RTL RGB 捕获，非界面设计稿、非物理 HDMI 证据 |

原开发目录验证包含：长短按/多键取消/上电按住与所有权保护，真实 UART GET/SET 与非法模式拒绝，三模式与真实合成器同音来源隔离，六种 CDC 包宽兼容及字模像素检查，ESP32 native/offline web 回归。

发布目录的便携脚本另行重跑并记录，避免仅复制一份旧的“PASS”。与生产固件有关的 `src/`、波表/字模、工程 XML 和 Tcl 均与编译时 SHA256 逐项一致；便携性调整限定在主机脚本和说明。

V034 两板均未烧录。本仓库不宣称已完成物理冷启动、模拟耳机/PCM5102A 输出、真实光束/压力动作、32 路模拟 FFT 或正式赛题验收。此前 V033 板载 MIDI 发声与手机 UART 恢复已有用户反馈，但不能代替 V034 实测。32 路引擎的离线测试通过也不能补足当前顶层缺少启动入口的问题。
