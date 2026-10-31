# V045 集成边界测试结果

2026-10-31 18:34 北京时间开始的最终完整运行：**18/18 PASS，复用旧结果 0 项**。

- 机器可读报告：`results/20261031T103416_028013Z/report.json`；方便查找的副本：`latest_report.json`。
- 运行期间输入变化：无。最终复核 `src/` 全部 SHA-256 与被测快照一致。
- 生产代码修改：无。写入均在 `tests/guide_integration_v045/` 内。
- 工具：已有 Icarus Verilog/vvp。没有安装工具，没有运行 Gowin，没有烧录或实体测试。
- 本次覆盖内未发现功能 bug；父任务无需根据本次测试修改生产 RTL。

## 关键结果

| 边界 | 结果 |
| --- | --- |
| MIDI receipt | 1 MHz/27 MHz 参数串行驱动均通过；27 MHz 下 864 clocks/bit。背压及 FIFO 满前 receipt 与真实 UART data-valid 同一采样沿；排空无重复；零力度、鼓、错误、suppress、overflow 取消不触发。 |
| receipt 链路 | performance hub 本地优先造成真实 FIFO 背压；audio_top 全链路和真实 mapping 握手通过；音频映射 60→72，receipt 仍为原始60。 |
| Demo/source 隔离 | 独立 adapter 接真实32路 allocator，80次同音最大 source3 gate=1；每次旧Off→下一拍新On；source1同音不被关闭。真实 audio_top 再做16次同音。取消/清理后 gate 全释放。 |
| Menu/手机 | 长4不选曲、短4选曲、owned长4忽略、手机同释放沿优先、清除未完成手势通过。OP20所有新 song/action 组合及旧0..3通过；非法位、OP21 ACK、OP22 24位只读回读通过。 |
| guide_stop | 停止后 key_pause 持续；mode/长4不自动恢复；显式手机start/短2可恢复；stop优先于同拍start、清手势、跨owned仍保持停止；参数0兼容。 |
| 实际ROM联动 | `piano_roll_guide(SONG_LIBRARY_ENABLE=1, BEAT_SAMPLES=64)` + modes + adapter +真实allocator，5组新用例全部通过。sample每1/4个clk分别施压；每组整曲流程经历474次真实score_ready气泡。 |
| 练习模式 | 每组接受128个正确新按，10个实际休止、19处相邻同音；错音不走、每次只放行当前step、跨多quarter不重复要求按键、pause/resume、结束清理均通过，无卡死。 |
| 自动演奏 | 三首音符On/Off各为42/42、44/44、42/42，均对应非休止事件数；两拍预备静音，休止无声，暂停释放、恢复重发一次，完成后全释放。 |

## 当前实际曲谱

| ID | 当前 source.json 曲名 | 总step | 发声step | 休止 | 含预备总拍数 |
| --- | --- | ---: | ---: | ---: | ---: |
| 0 | Twinkle Twinkle Little Star | 42 | 42 | 0 | 50 |
| 1 | Lantern Steps | 48 | 44 | 4 | 34 |
| 2 | River Bridges | 48 | 42 | 6 | 34 |

当前工作区没有名为 nocturne 的条目。新测试按实际原始音高/时长生成独立预期，再验证真实ROM，不以曲名猜测内容；因此第三首的6个休止均已覆盖，但不能声称验证了另一份 nocturne 曲谱。

## 复现与历史记录

```powershell
cd D:/Gowin_project/instrument_phone_extensions_20261031
python -B tests/guide_integration_v045/run_tests.py --workers 2 --timeout 180
```

只重跑新联动：`python -B tests/guide_integration_v045/run_tests.py --only score_modes`。

早期 audio_top 独立通过，随后一次联合运行在旧60秒限制下超时，日志保留于 `results/20261031T102928_747574Z/`。没有改变RTL断言来跳过该项；最终完整运行中此项14.672秒、27MHz receipt项8.984秒，均通过。超时属于历史运行器墙钟限制，不计为生产功能失败。

测试只从真实端口驱动，没有force、内部状态注入或DUT内存直接修改。完整HDMI、ESP/手机帧传输、电气与实体音频不在本次仿真范围；详见README。
