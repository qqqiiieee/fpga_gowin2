# V045 集成边界测试

本目录只包含新增测试、运行器、被测输入快照和验证结果。没有修改生产 RTL、旧测试或工程配置，没有安装工具，没有运行 Gowin、综合、布局布线或烧录。

## 运行

在 `D:/Gowin_project/instrument_phone_extensions_20261031` 执行：

```powershell
python -B tests/guide_integration_v045/run_tests.py
```

已有 Icarus 路径：`D:/Gowin_project/instrument_expression_20261024/tools/vendor/iverilog-v12/app/bin`。可用 `--tool-dir` 指定其他**已有**目录。复用原 `tests/tb_midi_support.v` 的串行驱动、FIFO 背压稳定性检查和事件记分板；旧 helper 不作修改。

只运行部分用例：

```powershell
python -B tests/guide_integration_v045/run_tests.py --only 'demo|audio_chain'
python -B tests/guide_integration_v045/run_tests.py --only 'phone|menu|guide_stop'
```

每次输出保存到本目录 `results/<UTC时间>/`，包含 `snapshot/`、编译日志、仿真日志、`.vvp`、`report.json`。`latest_report.json` 指向最近一次运行内容；使用 `--only` 时它仅代表所选用例。运行失败返回非零退出码；只有编译成功、仿真成功、出现预期 PASS 标记且没有 ERROR/FATAL 才算通过。默认 2 workers、每条命令超时 180 秒，可用 `--workers`、`--timeout` 调整。`--reuse-report` 只复用生产源码/数据、对应 bench/helper、参数哈希一致的已通过记录，并明确保留原日志路径和 `reused_from`。

## 覆盖

| 用例 | 覆盖的生产边界 |
| --- | --- |
| `receipt_1000000`、`receipt_27000000` | 真正 31250 baud UART 字节；分别 32/864 clocks/bit。receipt 在 UART data-valid 同一采样沿出现；ready=0 和 FIFO 填满期间不延迟；排空不重复。running status、实时字节插入、同音、原始 0/127 音域；velocity0、NoteOff、鼓、其他通道、控制消息、SysEx、system common、半包、坏停止位、错误后孤立数据、FF 取消、suppress、松键重新武装、FIFO 溢出取消。 |
| `hub_receipt_backpressure` | 真实 `performance_input_hub` 的 local 事件优先级让 MIDI FIFO 等待；4 个 receipt 均先于音频交付。STRUM 模式仍报告实体音符；allow_performance、remote、digital_zero、manual_panic 抑制。 |
| `demo_real_allocator` | 真实 `guide_demo_events` 接真实 32 路 `voice_allocator`，source3 对 source1。80 次同音每次严格 Off→下一拍 On；无尾音及 busy 全 1 两种状态下 gate 最大为 1。blocked 重触发、多个目标只交付最新、阻塞中取消、Off/On 间取消、live 优先、clear 清 pending、同音来源隔离及全部释放。 |
| `audio_chain_real_rtl` | 完整真实 `instrument_audio_top → instrument_inputs → performance_input_hub → midi_keyboard`，真实映射写入/commit ACK；MIDI60→音频72 而 receipt=60。audio_top 的 demo mux/source3、16 次同音、真实 MIDI 同拍争用、取消、velocity0、鼓、digital zero、panic 清音。包含真实声音层、声部分配器和波表初始化，无替身模块。 |
| `menu_db1`、`menu_db4` | GUIDE_MODES_ENABLE=1；长4只 mode_cycle+restart、不选曲、保持等待/播放状态；短4选曲及内置/自定义环回；owned 长4忽略、短4测试全声部；所有权边沿清手势；同一消抖释放沿 phone song/mode/page 优先；手机模式清除持键手势；多键取消。 |
| `phone_enable0`、`phone_enable1` | 真实 executor 接真实 menu。通过 BEGIN/WRITE/COMMIT 生成有效自定义槽后检查 legacy0..3；新显式 4 songs × 4 actions；无自定义时内置仍可用；逐位检查所有保留位和无 bit16 却给 songbits；owned BUSY；OP21 mode0..2 ACK及单次 restart、非法模式及高位；OP22 逐位 24-bit 状态零扩展回读、非法40位 payload、只读无副作用；参数0兼容、未知op。 |
| `guide_stop_enable0`、`guide_stop_enable1` | stop 后 started 清零且 key_pause 持续；mode/长4不会自行开始；手机及短2显式 start 可恢复；stop 与 phone start 同拍最高优先；清除未完成长4；跨 owned 交接仍停止；旧参数0忽略 stop。其余新增面板实例均显式 tie guide_stop=0。 |
| `legacy_panel_v035`、`legacy_fourphone` | 原有面板测试原样执行，验证默认参数兼容。 |
| `score_modes_m0_gap4`、`score_modes_m1_gap1/gap4`、`score_modes_m2_gap1/gap4` | 真实 `piano_roll_guide(SONG_LIBRARY_ENABLE=1, BEAT_SAMPLES=64) → guide_play_modes → guide_demo_events → voice_allocator`。分别每1/4个源时钟发一次 sample_tick，刺激真实同步ROM气泡；从原始 `source.json` 的音高/时长生成独立 oracle，不引用 DUT HEX/查谱函数作为预期。三首完整演奏、两拍预备、错音不走、正确音只释放本step、连续同音重新按、长音跨气泡保留接受状态、真实休止、暂停期间按键丢弃、已接受音暂停恢复、自动音暂停释放及恢复重发、自然结束/重复toggle不能复活。自动发声数量按有音高事件统计，休止不发声。 |

## 证据与边界

- 所有刺激都从端口进入；只读层次观察用于检查 receipt 时序、FIFO 数量、allocator 来源/gate。没有 `force`，没有注入 UART 解码字节，也没有直接改 DUT 内存或状态。
- 顶层链路的映射通过真实写入/commit 握手配置。命令测试的自定义曲谱通过真实上传命令生成。
- receipt 测试使用旧 helper 的时钟精度和 27MHz 参数/864 clocks-per-bit；没有声称验证实体 UART 电气质量或实测延迟。
- OP22 验证的是 executor 对输入 `guide_status` 的 24-bit 只读回传，未模拟 ESP/手机帧传输。手机命令从 executor 请求端口进入；完整 HDMI 顶层、跨域显示、真实手机、实体音频和板卡均不在此测试范围。
- audio_top 的 panic 用例同时取消 desired demo；停止后保持等待由真实 menu 的独立 `guide_stop` 用例验证。未把两项单独证据宣称为整机 phone_panic 端到端仿真。
- 每次快照记录 SHA-256，并检测运行期间输入变化。并发父任务若修改生产代码，旧结果只对保存的快照成立；查看 `inputs_changed_during_run`，需要时重新运行。
- Icarus `-Wall` 会记录生产文件 timescale 继承、组合数组敏感列表，以及旧 helper/default-param 实例新增端口悬空警告；这些旧实例关闭了相应功能。新增功能实例的输入均明确连接。
- `score_modes` 的预期文件 `song_events.hex`、`song_metadata.hex` 仅生成在本次快照的测试目录中；`song_oracle.json` 记录本次实际曲名、总步数、音符/休止数和拍数。当前 source.json 是小星星、Lantern Steps、River Bridges；没有名为 nocturne 的条目，因此不会把当前第三首冒称为 nocturne。若父任务更换曲谱，下一次运行自动从新来源生成预期并验证真实 ROM。
- 最早音频链独立运行通过（51.312秒）；一次联合运行在60秒的旧运行器上触发纯墙钟超时，该失败日志保留在 `results/20261031T102928_747574Z/`，没有通过放宽 RTL 断言消除失败。新默认180秒用于容纳多任务共享主机负载。

发现生产问题时只在本目录记录复现和日志，由父任务处理生产修复。
