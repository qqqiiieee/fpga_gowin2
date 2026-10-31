# V045 手机演奏接入与离线验证

实现仅修改 `esp32_phone/v041_runtime.h`、`esp32_phone/v041_ui.h`，以及 `esp32_phone.ino` 的 `FIRMWARE_VERSION="V045"`。新增文件全部位于本目录。教程、RTL、ROM、菜单与版本发布目录由父任务处理。

## 手机与协议

- 三模式：0 固定BPM检验、1 自动演奏、2 逐音练习。
- 四曲目：0 小星星 / 120 BPM、1 灯阶练习曲 / 112 BPM、2 溪桥练习曲 / 100 BPM、3 自定义 / 上传BPM。
- `POST /api/guide/control`：`{"song":0,"action":1}`，op20 payload `(1<<16)|(song<<8)|action`。
- `POST /api/guide/mode`：`{"mode":2}`，op21 payload `mode`。
- action 0 选择并暂停、1 开始、2 暂停/继续切换、3 重播。
- 旧 `POST /api/scores/control`：`{"action":0..3}`，仍发送 op20 旧 payload 0..3，作用于自定义曲谱。
- op0 能力值仍严格接受 `0x10007`。op22 不支持、NACK、超时或返回保留位非零均不会伪装为新功能生效。

## 状态与队列语义

`GET /api/guide/state` 只读取缓存，不产生串口请求。`POST /api/guide/state`，正文 `{}`，请求现有 Job 队列刷新；使用 `/api/extensions/job` 跟踪返回的 `id`。

设置作业执行能力检查、op20/op21、op22。设置 ACK 后只置 `request_accepted=true`，仍处于 running；有效 op22 后才置 `state_verified=true`。模式/已选曲目与请求不一致时作业失败（error 12），但缓存仍保存、展示实际回读值。格式错误使用 error 13。动作可能已经推进或受到外部暂停影响，因此 `ok/target_match` 不声称动作瞬间的 active/step；应查看实际状态。

缓存字段：

| 字段 | 语义 |
| --- | --- |
| `verified` | 最近的有效 op22 读回尚未被设置、读回失败或断线失效；不表示请求值已生效 |
| `fresh` | verified 且连接已同步，`age_ms <= 3000` |
| `stale` | `!fresh` |
| `age_ms`, `ttl_ms` | 距读回的毫秒数、有效期 3000ms；尚未读回时 age 为 null |
| `raw` | op22 原始实际状态；只接受高8位全0、mode 0..2 |
| `mode`, `roll_song` | bits 1:0、3:2 |
| `active`, `done`, `practice_hold`, `external_suspend` | bits 4、5、6、7，布尔值 |
| `step`, `expected_note`, `expected_valid`, `selected_song` | bits 13:8、20:14、21、23:22 |
| `pending`, `job_id`, `refresh_allowed`, `error` | 当前导奏作业、可否申请刷新及失效原因 |

首次读回前实际字段均为 null；失败后可保留历史数值，但 fresh/verified 为 false。仅年龄过期时 verified 可以为 true、fresh 为 false。页面下拉框与实际状态独立，不用请求值更新实际状态。页面每1500ms查询缓存，按需申请刷新；另有500ms本地过期检查，网络请求卡住也不会无限显示“新鲜”。

刷新请求最小间隔1000ms；HTTP不会发送串口帧。导奏请求在录音、EOF排空、停止待处理、其他作业或RPC占用时返回409；未同步503，过频429，参数非法422，正文类型/大小不合要求413。全部串口事务仍由原 UART task 调度与互斥管理，无后台自主UART轮询，不在录音中插入导奏刷新。

## 测试

从项目根目录运行：

```powershell
python tests/phone_guide_v045/run_tests.py
```

结果为本目录 `results.json`、`native.log`、`ui.log`、`legacy_ui.log`。生成的 `.inc` 是从实际实现逐字提取的测试输入，不能手动修改。所有 host C++ 编译、临时文件与结果均保留在本目录。

- native：实际 scheduler、consumeAck、guideAck、RPC编解码、缓存/JSON、HTTP handler；三模式、四曲目×四动作、旧payload、所有状态位单独置位、ACK与读回分离、目标不一致、非法位、重试、超时、错误序号/op/checksum、初始未知、失效、断线及32位时钟回绕；录音、停止/CRC队列优先级和互斥；GET无串口副作用。
- HTTP：实际字段整数校验与白名单、实际 handler/bodyLimit，使用 AST fixture 隔离未修改的 cJSON 文本解析器；覆盖缺失、越界、非数、非整数、未知字段、非法正文及409/422/429/503。此部分不是 cJSON 文本解析器测试。
- UI：执行完整内嵌JavaScript及真实handler，模拟DOM/fetch；覆盖模式、曲目、状态位、请求与读回分离、过期/网络错误、刷新合并与录音忙。不是实际浏览器截图或手机联机验证。
- 回归：原 `tests/v041_esp_native.cpp` 录音流/CRC/EOF/全30秒测试及 `tests/v041_esp_ui.cjs`。
- 保持性：记录开始前哈希，核对 IRAM `recording_uart.h`、bridge/core/JSON、UART task、录音/文件处理函数及原录音ACK/调度片段；ino 除版本字符串外相同。共享目录的父任务文件若发生并行修改，仅记录在报告，不覆盖。

未执行 ESP32/FPGA 固件编译、烧录、串口访问或硬件验证。FPGA协议与实际模式效果仍需父任务集成后联调。
