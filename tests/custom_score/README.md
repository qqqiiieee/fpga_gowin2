# 自定义曲谱显示交接与验证

仅在 `D:/Gowin_project/instrument_phone_extensions_20261031` 开发。原工程
`instrument_piano_f32_20261030` 的 src 与 gprj 使用逐文件 SHA-256 核查。
本任务修改四个获授权模块，新增 `src/custom_score_ram.v` 和本测试目录；
不负责 top、控制器、音频、ESP、工程文件、引脚与时序约束，也不生成/烧录固件。
隔离工程中其他模块有父流程并行修改，报告中会列出观察到的变化，不能把这些变化
归因于本任务。

## 父流程连接

1. guide、hdmi_live_display 生产实例均设置 `CUSTOM_SCORE_ENABLE=1`，默认0保留旧行为。
   hdmi_live_display 将参数向 compact dashboard、renderer 逐级传递。
2. 五个公共输入原样广播到 guide 和 hdmi_live_display：`custom_write_clk`、
   `custom_write_en`、`custom_write_addr[8:0]`、`custom_write_data[31:0]`、
   `custom_config[31:0]`。write_clk 与 guide.clk、live.clk27 必须为同一个27MHz时钟。
3. `custom_bank_ack` 的输出路径为 renderer → compact dashboard → live display。
   它是 **pixel 域电平**。控制器必须两级同步后，只有 ack==config[31] 才能接受下一次 BEGIN。
   本模块不代替控制器执行该拒绝规则。renderer 对被隐藏页面也继续处理提交和 ack。
4. 每次 BEGIN 写 inactive bank。所有256个条目先写完（预备、休止与尾部填0条目也要写），
   再以 config.bank 翻转提交。掉电、复位都不清空 BRAM；valid 之前不可读取未写条目。
5. guide 在 custom 被选中时检测**整个** config 变化，位置和分数相位清零。
   保留用户暂停状态；同拍 toggle 仍有效。start/restart 优先并主动运行，外部 pause 仍冻结位置。
   父控制器 commit 选曲并通过 key_pause 保持暂停，op20 再启动，这与现有接口兼容。
6. `ui_song=3` 的选中标题复用现有 SONG 行，数字为4；曲库增加第四行 `SONG 4`，
   开始提示下移一行。既有字体没有“目”，所以没有新增中文字形。页码仍为0/1/2/3。
   CUSTOM_SCORE_ENABLE=0 的曲库行、字形、字段宽度不变。

## 数据与边界

两份逻辑512×32 SDP RAM，一份 guide 源域读，一份 renderer 像素域读；
每份两 bank、每 bank256条。地址 `{bank,quarter_index[7:0]}`。
word：note[6:0]、step[12:7]、valid[13]、onset[14]、longnote[15]、
next_note[22:16]、next_valid[23]、velocity[31:24]。velocity 仅存储，综合允许删除未用位。
不产生 NoteOn、PCM、音量或合成器控制。

config：bank[31]、valid[30]、total_steps[29:24]、total_beats[23:18]、
samples_per_beat[17:0]。total_steps/total_beats 非零且拍长在23437..187500才视为有效。
total_beats 含两拍预备，向上取整；末尾不足一拍的填充可保持静音。
tick 单位1/64拍，前128tick/8quarter强制不显示当前音符。
source 地址为 roll_tick[11:4]，pixel 为 future_tick[11:4]。
自定义 onset 分隔采用低4bit<2；内置曲仍采用低6bit<2。
next_note/next_valid 来自预计算表，避免为了查下一音新增 RAM 或分布式表。
配置无效时 song3 安全结束，不回退小星星。内置0/1/2不使用自定义配置。

guide 的动态拍长使用 phase+=64、比较和减法，保留余数，
精确满足 tick=floor(有效采样数×64/samples_per_beat)，无运行时除法/取模。
旧 BEAT_SAMPLES 参数的小于64测试仍支持一次推进多个tick。
自定义 word 没有精确音符时长字段，因此旧 HUD 的 beat_progress 显示当前 quarter 相位
0..240，longnote 只提供粗略1/2拍提示；下落条形、同音分隔和整体时长均按 quarter 表精确显示。

## 同步读和 CDC

RAM 无异步读取、无复位清零循环。地址 tag 随同步输出一起登记。
guide 每次换 quarter 或 bank 有一个27MHz周期的提示无效窗口，旧地址绝不会冒充新音符。
生产每个采样有288个源时钟，窗口在下一个有效采样之前已经收敛。

renderer 的未来地址与 x 无关，一行内保持稳定。行开始 x=0..33 预取，
到 x34边框/x35键盘面板时 RAM 已就绪；不增加第三像素级。
不连续地跳转 raster 时，tag 不一致也会屏蔽旧词，不显示旧行音符。
renderer 两级、live wrapper 四级，RGB、covered、DE/HS/VS 对齐规则不变。

配置 CDC 采用 held_config+request_toggle。源域保持整个32bit配置，
直到像素域在帧边界实际应用、返回 applied_toggle 后才允许覆盖。
request 经三级像素寄存后捕获整个稳定总线，pending_config 仅在 frame_tick 原子替换 active_config。
bank_ack 与 active_config 同沿发布。
另有一位 bank 标记随原 hdmi_status_cdc 状态包握手传输，
防止新配置与旧播放 tick 混用。功能0不增加字段；生产 piano+hybrid+expression 从397增至398bit。
旧字段偏移完全保留。renderer 会暂时隐藏 tag 不匹配的新谱面，直到相应播放快照到达。
**没有修改 SDC**：这些新 CDC 端点的时序约束仍需父流程纳入正式工程的 CDC/STA 审查。

## 运行与报告

```
python tests/custom_score/run_tests.py --workers 4
python tests/custom_score/run_tests.py --synth-only
```

可选开源映射（实验性估算，不能代替 Gowin 综合/布局布线或整机 CLS 余量）：

```
python -m pip install --target tests/custom_score/tool_deps yowasp-yosys
python tests/custom_score/run_tests.py --synth-only --yosys
```

测试和综合都从冻结快照运行，只在本目录 artifacts 下产生报告和临时工程。
`latest_report.txt` 指向最近一次报告；多个独立运行的 summary.json 各自保留。
Gowin 本次报告若记录 `License verification failed / Server not responding`，
应按“未完成厂商综合”理解，不能据此声称已完成97%利用率下的布线收敛。

覆盖：原三曲完整逐采样回归、功能打开与冻结旧 guide 的逐拍 miter；四种动态拍长；
两拍预备、完整时长、尾部静音、同音 quarter 分隔、长音持续、下一音预告；
用户暂停/切页/重启、失效配置；27MHz/25.2MHz近似异步时钟四种初始相位；
完整800时钟 raster 行的 x35首像素与全部面板像素；13种提交到帧边界相位；
事务中复位；ack 逐级输出与外部两级同步模型；已有 FFT/XY 支路和菜单字形。

## 本次结果（2026-10-31）

总交接报告为 `validation_summary.json`，差异为 `changes.diff`。
23个完整仿真用例全通过，另将已开启自定义功能的内置 guide **和 renderer**
与冻结旧 RTL 作15009周期的逐拍对比，通过。原工程 src/gprj 的76个文件哈希一致。
四种异步初相0/3/11/19ns，各比较1468800个自定义像素和1836个完整 raster 行，
合计5875200像素、7344行；每相位15次提交，覆盖13种接近帧边界的提交相位。
菜单/包装链检查4100像素，包含选中 SONG4 和第四项高亮、四级 RGB/DE/HS/VS 对齐；
原像素回归47855项，FFT/XY renderer 241116项。

| samples/beat | 两拍预备采样数 | 测试曲含预备共五拍采样数 |
|---:|---:|---:|
| 23437 | 46874 | 117185 |
| 46875 | 93750 | 234375 |
| 93750 | 187500 | 468750 |
| 187500 | 375000 | 937500 |

每个有效采样核对 floor(samples*64/samples_per_beat)，没有累积 tick 漂移。
四组自定义源域断言次数分别为1412019、2824157、5648374、11296813。

开源 Yosys GW2A 实验映射（仅 guide+renderer 隔离核，不含 compact/live 状态包装）：

| 单元 | 功能0 | 功能1 | 增量 |
|---|---:|---:|---:|
| LUT1..4 | 495 | 771 | 276 |
| 触发器 | 105 | 265 | 160 |
| ALU单元 | 330 | 441 | 111 |
| BRAM | 1 | 3 | **2** |

新增两份曲谱 RAM 均为 `SDPX9B`（512×36物理端口容纳512×32逻辑字），
既有几何 ROM 为 `SPX9`，没有新增分布式大 RAM；运行时 div/mod 单元均为0。
为避免 Wasm 前端缓慢展开既有几何 initial 双重循环，先由 Icarus 从冻结原 RTL
导出全部1024个 geometry 字，再仅在综合快照中以 readmemh 读回相同内容。
完整工具命令、ROM SHA-256、原源哈希和映射网表保留在资源报告中。

Gowin 厂商综合两组均因本机 License 服务器无响应而失败，未完成生产工程综合、
PnR、板上显示或烧录。因此这些开源单元计数不能转换成已验证的 CLS 使用率，
也不能声称97%使用率下已经满足布线/时序。父流程仍须负责 top 接入、
工程加入 custom_score_ram、ACK 两级同步与 BEGIN 拒绝、CDC/STA 和正式资源收敛。
