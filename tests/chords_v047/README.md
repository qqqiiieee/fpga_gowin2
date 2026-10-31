# V047 和弦独立 RTL 验证

运行：`python tests/chords_v047/run_tests.py`。
仅新增本目录测试/说明/结果；不修改任何生产文件，不构建全工程，不访问硬件或烧录。
使用已有工具 `D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin`。

本次全部通过：`results/20261031T112954_398424Z/report.json`，当前副本为 `latest_report.json`。
快照记录实际测试的源码/测试 SHA256、工具哈希、命令与原始输出；运行期间输入未变。

| 测试 | 结果 | 覆盖 |
|---|---|---|
| `tb_modes.v` | 35项通过 | 四个目标全部有fresh NoteOn且同时held才通过；错音、预按、缺第四音、依次单点不可通过；共同音重复和弦需全部重新触发；松键再保持但无新事件不可通过；RAM bubble保留部分进度；暂停清掉未完成尝试；旧单音、休止、示范bubble不重复触发、重复step/暂停恢复重触发、退出 |
| `tb_events.v` | 145项通过；24 On/20 Off | 真实32声部 `voice_allocator`，SOURCE_TAG_ENABLE=1、source3；48/52/55/60→52/55/60/64共同音槽重排时全部Off先于新On，最终每音恰一声部；同音source1 live声部始终保留；同和弦重触发恰4 Off+4 On；快速连点收敛无卡音；blocked期间不发事件、只接受最新desired；退出释放全部source3；全局clear同时清分配器 |
| `tb_score_pixels.v` | 103项通过；10个非法word被拒；11次真实RAM bubble | `phone_extension_state(CHORD_SCORE_ENABLE=1,GUIDE_MODES_ENABLE=1)` 经真实写总线上传并提交，CAP=0x1000f；真实guide读取、同步RAM气泡和step；真实renderer读取和弦word，对全部32键中心验证只有四条CYAN，四目标键AMBER/按住GREEN；黑键42、最低41、最高72；panel/x/y/de边界、onset两像素空隙、旧bank抑制、done/越界时间抑制；旧mono next-note元数据不当作和弦delta |

非法word包括：flag31置1但仅根音、delta空洞、重复、下降顺序、最后delta下降、最高音73、根音40/73、step越界、valid13为0。
合法上传涵盖二/三/四音和弦、最大delta31、最高root+delta=72。旧mono保持flag31=0，读出offsets=0。

验证边界：这是独立模块和局部真实连接的RTL仿真，未声称整机UART/音频、异步像素时钟CDC、时序或CLS映射通过。
renderer测试由真实score写口填RAM并经配置握手生效，按稳定像素坐标逐点检查；不是截图或stub。
声部分配器测试不实例化合成器包络，voice_busy置0，检查的是gate/source/note生命周期。
父代理负责ESP及Gowin整合构建。本次未发现生产RTL错误，因此没有生产修复。
