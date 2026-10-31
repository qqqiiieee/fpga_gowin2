# V038 手机只读遥测：隔离实验与 FPGA 对接合同

本实验位于 `D:/Gowin_project/phone_extension_v038_20261031`。
来源：`D:/Gowin_project/instrument_piano_f32_20261030`，复制清单和原始哈希见
`validation/source_capture.json`。未复制 build、vendor、.toolchain、node_modules、
.build_work 或缓存。原工程、FPGA、CST/SDC 均未修改；未连接硬件或烧录。
这里只实现 ESP32 手机桥，FPGA 对端由父任务在后续 V038 实现。没有 I2S、录音、
曲谱上传、键位映射或新的可写参数。旧版 FPGA 返回 RESULT=2 时仍可使用参数控制。

## 传输与权限

沿用 UART2 115200/8N1，ESP TX GPIO17→FPGA L9，FPGA N8→ESP RX GPIO16。
原 v1 固定 12 字节帧、SEQ、XOR 和公共状态字段不变；**校验为 XOR，不是 CRC**。

```
请求 A5 5A 01 SEQ CMD PARAM VALUE 00 00 00 00 XOR
应答 5A A5 01 SEQ RESULT PARAM EFFECTIVE FLAGS TIMBRE FX_MODE VOLUME XOR
XOR = bytes[2] ^ ... ^ bytes[10]
```

原 0..15 参数合同不变，15 个可写参数不变。新增槽位 16..31 **仅 CMD=0 GET、
VALUE=0**；SET PARAM>=16 必须 RESULT=2，无副作用。CMD=2 Panic 仍仅允许原 PARAM=0。
所有应答公共 FLAGS（byte7）的 bit7 仍保留为0；槽位22中的 snapshotvalid 是
**EFFECTIVE（byte6）** 的 bit7，不能与公共 FLAGS 混淆。

## 能力与原子快照

GET31：EFFECTIVE=0xA7，不触发或改变快照。旧 FPGA 的 RESULT=2 表示不支持。
桥在每次连接完成原参数同步后先探测一次；重连/重新同步后重新探测。探测超时或瞬态错误
仅将遥测标为 UNAVAILABLE，不阻止原参数控制；该状态从 lastCapabilityProbe 起满1000ms
后允许重新 GET31，每次发出均更新该时间戳。SET/Panic 队列及已到期的普通参数轮询优先，
重探测不抢占在途请求。错误 XOR 不能刷新 lastAck 或快照时间，也不会触发无间隔探测。
UNSUPPORTED（RESULT=2 或能力魔数不符）则保持到重连，不持续探测旧板。
Core 默认 telemetryEnabled=false；sketch 明确启用。

**GET16 在 FPGA 中触发一次128位原子快照，ACK16 必须返回本次新快照的 A0lo**。
GET17..30 返回同一个缓存；普通 GET/SET/Panic、显示或 ADC 更新不得重新捕获。
按低地址在低字节排列：槽位 N 对应 snapshot[(N-16)*8 +: 8]（N=16..30）。
这15个槽位传输120位；snapshot[127:120] 为未传输保留字节，建议置0。31始终是能力字节。
无效请求、错误校验或 SET 不得触发 GET16 的捕获副作用。
父任务 FPGA 对相邻、相同 SEQ 的有效 GET16 重试做幂等处理，不重新捕获；其他有效命令
清除该去重标记。本 ESP 桥仍不重试遥测槽位，不依赖该去重行为；末尾 GET22 验证保持不变。

| 槽位 | EFFECTIVE 内容 |
|---|---|
|16|FSR0 / ADS A0 RAW bits7:0，GET触发捕获|
|17|A0 RAW bits15:8|
|18|FSR1 / ADS A1 RAW bits7:0|
|19|A1 RAW bits15:8|
|20|FSR0 LVL，0..255|
|21|FSR1 LVL，0..255|
|22|bit0 cal0、1 cal1、2 ADCfault、3 ADCstale、4 opticalready、5 MIDIframeerror、6 MIDIoverflow、7 snapshotvalid|
|23|bit0 electricalA、1 electricalB、2 blockedA、3 blockedB、4 opticalenabled、5 strumbusy、6 testmode、7 testowned|
|24|最近MIDI力度 VEL，0..127|
|25|BEND bits7:0|
|26|bit0=BEND bit8，bits7:1=0；9位二补码，-256..255|
|27|MOD / CC1，0..127|
|28|活动声部数，0..32|
|29|测试请求声部数，0..32|
|30|bit0 testactive、1 sweep、2 overrun、bits7:3 sweep index 0..31|
|31|能力魔数0xA7，不属于快照|

## 调度与新鲜度

仅一个 Parser、一个共享 UART 调度器、一个在途请求。先完成原参数回读，再探测能力。
能力有效时目标每200ms启动一轮 GET16..30，再额外读取一次 GET22 做发布前验证；
请求/应答全部串行，共16次请求，下限约33.33ms/轮。
原参数轮询仍保留；已入队 SET/Panic 在报文之间优先，不能截断发送中的报文。
长期持续控制写入可以延迟遥测，界面会据实显示过期。

遥测使用独立 staging 与 committed 缓冲；全部15个槽位完成后仍不发布，须再做
**一次额外 GET22**：其 bit7 必须为1，且**整个字节必须等于本轮已保存的槽位22**，
才一次发布。这防止 FPGA 在原槽位22读出之后复位、后续槽位返回清零缓存时拼出混合数据。
验证失败丢弃 staging、清除有效显示，保留原计数/时间戳不刷新，并从新 GET16 开始，
不等待下一个200ms周期。只有最终验证成功才递增 snapshot_id，普通 ACK 计数不代表
完整遥测发布。SET/Panic 在最终检查前也可优先插队；整个流程仍受原500ms总期限限制。
低/高字节不能来自不同轮，部分应答不刷新已发布值或年龄。没有新增或更改协议槽位。
GET16 有捕获副作用，因此**遥测槽位均不重试**；任何一轮从 GET16 发出起满500ms即
丢弃 staging，后续从新序号 GET16 开始，晚到应答不续接旧轮。普通控制的原250ms重试不变。

age_ms 从 GET16 请求开始发送计时，不从最后应答计时；相对 FPGA 收到整包后实际捕获
略保守（约一个请求串行传输时间）。满1000ms标为 stale。坏 XOR、错 SEQ/PARAM、非法
值或未完成轮次不能刷新快照时间。snapshotvalid=0 不发布有效数据。
断链立即清除遥测有效位、缓存及所有诊断标志；重连先重新读原参数再探测能力。

## /api/state 与中文页面

原 params 对象保留原16个键；新数据单独位于 telemetry，不参与预设。

- enabled、status（probing/supported/unsupported/unavailable/disabled）、supported
- valid、stale、age_ms（无有效快照时null）、snapshot_id、snapshot_valid、aborted_bursts
- fsr[0/1]：raw（16位原码，页面显示HEX）、level、calibrated
- adc：fault、stale
- midi：velocity、bend、modulation、frame_error、overflow
- beams：electrical_a/b、blocked_a/b、enabled、ready、busy
- voices；test：mode、owned、requested、active、sweep、overrun、index

页面分别显示两路 RAW/LVL/CAL 与0..255进度条、VEL/BEND/MOD、光电电平/遮挡/就绪/忙、
ADC故障/采样过期、声部及测试状态。ADC stale 与通信快照 stale 分开表达。
遥测不支持、读取失败、等待有效快照、过期或断链均明确显示；失效时清空显示值与进度条。
即使 HTTP 没有新应答，页面也根据年龄继续计时，到1秒清空遥测。
RAW/LVL 不是 kg 或电压；VEL 是最近力度，BEND 是归一化码，不是 Hz。

## 本地验证与构建

```
python -B scripts/run_stage1_tests.py
powershell -File esp32_phone/build.ps1 -ToolchainRoot D:/Gowin_project/instrument_phone_test_20261030/esp32_phone/.toolchain
```

测试：原 native_core 和 web_ui 回归保持不变；新增 native_telemetry 检查能力、组帧、
符号、超时、XOR、旧 FPGA、恢复、抢占及权限；native_api 用离线 Arduino stub 执行
真实 sketch 序列化和 apply 逻辑。仅为避开MSVC字符串长度限制，host fixture替换网页
字面量为""，其余 sketch 函数原样保留；真实网页另由无硬件、全HTTP mock的 Edge 测试。
测试及构建只输出隔离目录。构建复用已安装 Arduino-ESP32 2.0.17 工具链，不下载依赖，
不复制工具链，不访问串口。编译成功不等于 FPGA 对接或实机验证通过。
