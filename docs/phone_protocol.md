# V034 手机 UART 协议 v1

适用 classic ESP32-WROOM32，UART2 115200bps、8N1、3.3V TTL。D17/TX→FPGA PMOD3 L9/RX，N8/TX→D16/RX；公共 GND。ESP32 USB 供电，3V3输出不与FPGA稳压输出相连。FTDI T13/M11 和 MIDI T8 是独立接口。

源代码：[FPGA协议](../src/phone_control_link.v)、[顶层实际回读](../src/top.v)、[ESP桥核心](../esp32_phone/bridge_core.h)、[HTTP服务](../esp32_phone/esp32_phone.ino)。

## 帧

```text
请求  A5 5A 01 SEQ CMD PARAM VALUE 00 00 00 00 XOR
响应  5A A5 01 SEQ RESULT PARAM EFFECTIVE FLAGS TIMBRE FX_MODE VOLUME XOR
```

每帧12字节；XOR为字节2至10异或。SEQ按8位回绕，同一时刻一笔在途请求。CMD=0 GET（VALUE必须0）、1 SET绝对值、2 Panic（PARAM/VALUE均0）。保留字节必须0。

RESULT：0成功、1不支持命令、2参数不存在/只读、3超范围、4版本/保留字段错误。坏XOR或半帧不执行、不响应；字节间20ms超时重新接收。仅完整合法SET产生单周期提交；FPGA等待后级稳定后读取实际状态回复，不回显请求值。桥在250ms重试同SEQ；绝对值SET不重复翻转。

## 参数

| ID | JSON键 | 范围/语义 |
|---|---|---|
| 0 | volume | 0–255 实际主音量，K4/CC7/手机仲裁；实体滑杆停用 |
| 1 | timbre | 0长笛 / 1拨弦 |
| 2 | input_mode | 0KEY / 1STRUM / 2HYBRID |
| 3 | fx_mode | 0OFF / 1Delay / 2Chorus / 3Reverb |
| 4 | fx_wet | 0–255 当前/最近效果强度；更新对应效果保存强度 |
| 5 | fx_time | 0–255 效果时间控制码，不标定成毫秒 |
| 6 | fx_feedback | 0–255 反馈控制码，稳定系数由引擎限制 |
| 7 | fx_modulation | 0–255 调制控制码 |
| 8–11 | attack/decay/sustain/release | 各0–255包络控制码，不直接等于毫秒 |
| 12 | hdmi_page | 0演奏 / 1曲库 / 2帮助 / 3诊断 |
| 13 | filter | 0/1 低通允许开关 |
| 14 | digital_zero | 0/1，回读有效静音状态，包括FTDI零参考影响 |
| 15 | status_flags | 只读0–127，SET拒绝 |

FLAGS：bit0 MIDI seen/held；bit1 ADC故障（top flags[3]）；bit2键盘ghost兼容状态（flags[6]）；bit3光电ready；bit4允许扫弦（STRUM或HYBRID）；bit5 MIDI溢出；bit6实际数字零；bit7保留0。模式准确值看GET2，不根据bit4区分STRUM和HYBRID。

K1/CC93、K2/CC91、K3/CC71分别调整各效果的**强度**，K4/CC74音量。它们不是手机参数5/6/7的别名。切效果只启用一种，共享同一效果器与历史RAM。

## HTTP 与确认

- `GET /api/state`：包含boot_id、linked/synced/stale、ack_age_ms、队列/在途/重试/拒绝计数和每项真实回读/请求/生效/失败状态。
- `POST /api/apply`：Content-Type为application/json，最多1024字节；只允许已知可写键、范围内整数，重复或非法字段整批拒绝。HTTP 202仅表示入队，不能当作FPGA已生效。
- `POST /api/panic`：请求体严格为`{}`；只在可通信时接受。
- `rx`计数是通过协议校验的响应，不是原始电平变化计数；rx=0不直接等于示波器上没有数据。

连接中断后旧值过期、写控件禁用，待发写入不会在恢复后补发；恢复时先完整GET同步。手机改参数、面板长按与MIDI PC最终都以FPGA状态为准。Panic清声音及待发控制，不代表永久静音；数字零是独立持续状态。

**配套升级要求**：旧桥限制模式0/1，不能正确接受V034模式2回读。更新任一端范围必须同时更新FPGA校验、ESP限值、网页/预设和回归。当前内嵌网页帮助仍有旧T11/P11文字，部署接线以本文和CST的L9/N8为准；改网页需重新编译并更新ESP bin身份。
