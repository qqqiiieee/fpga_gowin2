> V030接线更新：手机RX/TX已移动到L9/N8；A11/B11/N6/D11属于四个菜单键。下文桥接源码与协议继承V023，FPGA已同步V030。

# ESP32-WROOM32 手机参数通信桥

这是 V023 的实验性独立手机控制桥，严格使用 `../docs/phone_protocol.txt` 的 12 字节 UART 契约。网页完整内嵌在 `web_ui.h` 的 PROGMEM 中，不需要互联网、文件系统分区、CDN 或 ArduinoJson。声音仍由 FPGA 音频链输出；这里没有音频采集、录音、回放或音频传输。

本次只进行源码编辑、软件模拟与编译，不访问电脑串口、不打开板卡、不烧录，也不进行物理测试。编译结果见 `build/compile.log`、`build/build-result.json`；是否实际完成编译以这两份记录为准。上述ESP32构建记录继承V023；当前FPGA版本及PMOD3接线以本页表格为准。

## 接线与供电（部署时参考）

适用于 **classic ESP32-WROOM32 / ESP32 Dev Module**，不是 ESP32-C3/S3。UART2 固定 115200 baud、8N1、3.3V TTL。

| ESP32 侧 | FPGA Tang Primer 20K 侧 | 方向 / 用途 |
|---|---|---|
| GPIO17 / TX2 | L9 / phone_uart_rx | ESP32 → FPGA |
| GPIO16 / RX2 | N8 / phone_uart_tx | FPGA → ESP32，ACK / readback |
| GND | GND | 必须共地 |
| 自己的 USB | 不连接 FPGA 电源输出 | ESP32 自 USB 供电 |
| 3V3 输出 | **不连接 FPGA 3V3 输出** | 不并联两路稳压输出 |

TX 接对端 RX，不是 TX 对 TX。两端为 3.3V 逻辑，不能接 RS232 电平或 5V TTL。ESP32 的 USB 在本方案中用于独立供电；源码不启动 USB 调试串口。FPGA 原 FTDI T13/M11 调试串口保持独立，不能把它当本协议端口。

## 手机连接（桥固件已部署后）

1. 手机打开 Wi-Fi，连接 **Tang20K-Music**。
2. 输入密码 **fpga2026**。若系统提示此 Wi-Fi 无互联网，选择继续连接 / 保持使用。
3. 手机浏览器手动输入 **http://192.168.4.1/**。这是 HTTP，地址不是 HTTPS，也不依赖自动弹出认证页面。
4. 等待绿色“FPGA 已连接 · 实际值持续回读”。ESP32 网页可访问不代表 FPGA UART 已通；完整回读完成前参数控件保持禁用。
5. 调整参数后先显示“请求已入队 / 等待 ACK”，只有 FPGA 正常 ACK 且实际值达到目标才显示确认。看每项下方的“FPGA 实际值”。
6. UART 断链或手机无法读取 ESP32 状态时，面板明确标记“过期”并禁用写入。恢复后自动完整回读，旧的待发写入不会补发。确需修改的参数应在恢复后重新操作。

AP 名称和密码可在 `esp32_phone.ino` 顶部 `AP_SSID` / `AP_PASSWORD` 自行修改后重新构建；WPA 密码用 8–63 字节。默认 AP 地址固定为 192.168.4.1。没有 STA 上网、自动配网或门户重定向。

## 参数与演奏约定

所有数值都是 FPGA 原始整数，范围含两端。ADSR / FX 的 0–255 刻度不虚构成毫秒、赫兹或百分比。

| JSON 键 | 参数 ID | 范围 / 含义 |
|---|---:|---|
| volume | 0 | 0–255，主音量，与实体滑杆 / CC7 共享仲裁 |
| timbre | 1 | 0 长笛 / 1 拨弦 |
| input_mode | 2 | 0 KEY / 1 STRUM |
| fx_mode | 3 | 0 OFF / 1 Delay / 2 Chorus / 3 Reverb |
| fx_wet | 4 | 0–255，湿度 |
| fx_time | 5 | 0–255，时间 |
| fx_feedback | 6 | 0–255，反馈；实际稳定系数仍由 FPGA 音频模块限制 |
| fx_modulation | 7 | 0–255，调制 |
| attack / decay / sustain / release | 8 / 9 / 10 / 11 | 各 0–255 |
| hdmi_page | 12 | 0–3；不假定各页画面名称 |
| filter | 13 | 0 关闭 / 1 开启 |
| digital_zero | 14 | SET 为手机 UI 静音请求，GET / ACK 为实际音频静音状态 |
| status_flags | 15 | 只读，禁止放入导入预设 |

四个实体 MIDI 旋钮在所有 UI 页固定为 **CC93=时间、CC91=反馈、CC71=调制、CC74=湿度**。手机改值后的软接管由 FPGA 对端执行，转到当前值附近再接管。手机不重新映射实体旋钮。

Pad 继续为打击乐通道 10，音符 **36 / 37 / 38 / 39** 和既有 GM 别名。网页只说明这些约定，不增加音符触发或 Pad 重新分配接口。

Flags：bit0 MIDI seen/held；bit1 ADS 故障；bit2 触摸故障；bit3 光学就绪；bit4 STRUM；bit5 MIDI overflow；bit6 **实际** digital zero；bit7 保留零。

### 实际值与控制冲突

ACK 的 EFFECTIVE 和 FLAGS 来自 FPGA 实际状态，绝不把请求值直接当成功结果。FTDI zero 尚未撤销时，手机 `digital_zero=0` 可能仍得到实际 1；test32 / zero / 实体滑杆等仲裁也可能使 `volume` 的实际值不同于目标。

即使 FPGA RESULT=0，只要 SET 的 EFFECTIVE 不等于目标，本桥仍报告 **“未达到目标 / 控制冲突，目标 X，实际 Y”**，保留实际值并停止该请求，不自动循环争抢控制权。实体滑杆在已确认后再次改变音量时，后续 ACK 摘要和轮询会刷新显示。

Panic 取消尚未发送的参数请求，等待当前在途请求结束后优先发送 CMD2。只有 Panic 的正常 ACK 才显示确认。Panic 不等同于永久静音开关，不替用户撤销 FTDI 的静音状态。

## JSON 预设的校验和执行边界

`preset.example.json` 是合法格式示例，并非适合所有演奏场景的推荐参数。导出生成含 15 个可写键的平面 JSON；只允许页面已回读到的整数值，不混入状态、版本号、音频或任意元数据。

导入接受上表可写键的任意非空子集。整份文件最多 **1024 字节**。固件先解析到临时结构，全部字段通过校验、队列容量足够且链路完成同步后才一次性入队。任何未知键、只读键、重复键、超范围值、字符串、布尔值、null、数组、嵌套对象、负数、小数、指数写法、转义键、非法前导零或尾随内容都会整份拒绝，**不会先应用合法前半部分**。本地 JS 校验只是辅助，固件校验是最终入口；例如 `1.0` 或重复 JSON 键即使能被浏览器 JSON.parse 接受，也会被固件整体拒绝。

校验通过后的多个 SET 是依次执行的，**不是 FPGA 的多参数原子提交**。中途 FPGA 拒绝、控制冲突或断链时，之前已确认的值可能已改变；错误会保留，后续成功 ACK 不会把整次混合结果改显示为成功。断链会停止剩余队列并自动回读；不承诺回滚，也不自动重放预设。

## 通信可靠性

- 请求：`A5 5A 01 SEQ CMD PARAM VALUE 00 00 00 00 XOR`。
- 响应：`5A A5 01 SEQ RESULT PARAM EFFECTIVE FLAGS TIMBRE FX_MODE VOLUME XOR`。
- XOR 覆盖字节 2–10（含两端）；GET 的 VALUE 恒为 0；Panic PARAM/VALUE 恒为 0；保留字节恒为 0。
- SEQ 为 8 位自然回卷；始终只允许一个请求在途。响应须匹配在途 SEQ / PARAM，版本、XOR、RESULT 和实际值范围也要合法。
- 接收解析器在 **20ms** 字节间隔后丢弃半包，支持噪声重同步；损坏、旧序号和重复 ACK 不会形成成功或刷新心跳。
- 等待 **250ms** 后以完全相同 SEQ / 帧重发，最多三次发送（初次 + 两次重试）。SET 使用绝对值，因此重复是幂等操作；重试期间仍可能被实体控制源重新接管，以 ACK 实际值为准。
- 正常轮询约每 120ms 产生一个 GET；主音量有约 500ms 的优先回读，并且**每个** ACK 都包含实际音量、音色、FX 和 flags。正常无写入时，全部参数约数秒内巡回一次；连续写入时这些额外 GET 可以延后。
- 轮询不进入写队列；已有单个在途 GET 完成后，排队写入优先。不会取消一半 UART 帧去插入写请求。
- 写队列最多 16 项，按参数合并尚未发送的绝对 SET，保留最新目标；在途项不修改。网页自身也仅保留一个正在提交的 HTTP 请求和每参数一个最新草稿。
- 750ms 无有效 ACK 会耗尽重试；1500ms 是额外心跳失联上限。断链将所有缓存标为 stale，取消在途/待发写入并记录失败。
- 断链后约每 1000ms 发 GET15 探测。恢复后回读所有未验证参数，只有完整 snapshot 有效才恢复写入。没有积压参数突发补发。
- 手机约每 350ms 查询 `/api/state`；HTTP 请求有超时，手机侧独立检查状态心跳。ESP32 启动 ID 变化会让旧请求确认失效。

### 本地 HTTP 接口

| 方法 / 路径 | 请求 / 返回 |
|---|---|
| GET `/` | PROGMEM 内嵌中文网页 |
| GET `/api/state` | 链路、stale、ACK 年龄、队列计数、实际参数、各参数请求/确认/失败 revision |
| POST `/api/apply` | `Content-Type: application/json`，平面预设对象；202 仅代表 accepted / revision，**不是成功 ACK** |
| POST `/api/panic` | 相同 JSON 类型，body 精确为 `{}`；同样返回 202 待确认 |

校验失败返回 400；类型错误 415；正文过大/缺失 413；链路未就绪 503；容量不足 429。任何这些错误都不显示成功。API 中 `error=1..4` 是 FPGA RESULT；`10` 是链路超时，`11` 是被 Panic 取消，`12` 是正常 ACK 但实际值未达到目标，这三个是桥接层本地错误码，不修改 UART RESULT 定义。

## 隔离工具链与可复现编译

仅需 Windows PowerShell 和 Python 3.11+；不调用全机 Arduino 配置，也不修改 PATH / 注册表。固定 Arduino CLI **1.2.2**、Espressif Arduino-ESP32 **2.0.17**，FQBN **esp32:esp32:esp32**。本桥只使用内置 WiFi / WebServer / HardwareSerial。

在本目录运行：

```powershell
python .\bootstrap_toolchain.py
.\build.ps1
```

`build.ps1` 缺少工具链清单时也会自动执行 bootstrap。所有下载、配置、工具、SDK、临时文件、暂存草图和缓存都在本目录 `.toolchain/`；产物和编译日志在 `build/`。构建命令只使用 `compile`，没有 upload / monitor / board list / 串口设备路径。

下载只使用 Arduino / Espressif 官方发布源，CLI、编译器、core、esptool 和 ctags 都校验官方 SHA256。为了满足只使用官方源的约束，脚本只安装 classic WROOM32 编译实际用到的 Espressif 编译器与 elf2image 工具，省略其他芯片编译器、调试器及第三方文件系统镜像工具；这不是全系列完整 Boards Manager 安装，但无需 SPIFFS/LittleFS 的本草图可正常构建。Arduino CLI 首次初始化可能自动下载其官方 builtin discovery/monitor 工具；只安装依赖，构建不调用这些设备功能。

构建脚本将三个源码文件复制到暂存草图目录，防止 CLI 扫描 `.toolchain`；还创建本目录内的 SDK / GCC junction 以避开 Windows 命令行长度和旧 GCC 260 字符头文件路径限制。它们都指向本目录工具链，不创建盘符、不搬动工程、不改官方 headers、不写全局配置。

`build/build-result.json` 记录实际退出码、北京时间、编译使用的三份源码 SHA256 和生成 `.bin` SHA256；`build/toolchain-manifest.json` 记录固定版本和官方资产 URL / 校验和。若编译失败，脚本以非零退出并标记失败，不以已有旧 `.bin` 充当本次成功证据。分区和 bootloader 产物是编译生成文件，不表示已部署。

若手动使用 Arduino IDE，应把 `esp32_phone.ino`、`bridge_core.h`、`web_ui.h` 三个文件复制到一个干净的 `esp32_phone` 草图目录，选择 ESP32 Dev Module。不要让 IDE 把存放工具链的整个交付目录当额外源码扫描。

## 离线测试与文件清单

测试目录为 `../tests/phone_bridge/`。在该目录运行：

```powershell
.\run_tests.ps1
```

原生测试使用已安装的 Visual Studio 2022 C++，`run_native.cmd` 只在当前子进程加载编译环境。网页测试使用本机 Node、已有 Playwright 和 headless Edge，所有 HTTP 请求被模拟拦截，浏览器临时数据保存在测试目录。没有连接真实 AP、设备或串口。若另一台电脑的 VS / Edge / Playwright 路径不同，需要调整测试脚本路径；ESP32 构建不依赖这些网页测试组件。

| 文件 | 用途 |
|---|---|
| `esp32_phone.ino` | SoftAP、WebServer、UART2、JSON API、实际状态输出 |
| `bridge_core.h` | 可在 PC 测试的协议 codec / parser、严格 JSON、单在途调度与恢复 |
| `web_ui.h` | PROGMEM 中文网页，零外部网络资源 |
| `preset.example.json` | 合法参数文件示例 |
| `bootstrap_toolchain.py` / `build.ps1` | 官方源隔离安装 / 实际编译与散列记录 |
| `build/compile.log` / `build/build-result.json` | 实际编译输出 / 机器可读结果 |
| `build/*.bin` / `build/*.elf` | 实际生成的 ESP32 二进制 / ELF |
| `build/toolchain-manifest.json` | 官方下载与固定版本证据 |
| `build/validation-result.json` | 本次编译与离线测试汇总、产物/测试日志散列 |
| `../tests/phone_bridge/native_core.cpp` | 帧、错误 ACK、冲突、队列、Panic、超时/恢复测试 |
| `../tests/phone_bridge/web_ui.test.cjs` | 手机网页、预设、错误保持、实际值、断链和 JSON 导出模拟 |
| `../tests/phone_bridge/run_tests.ps1` / `run_native.cmd` | 离线测试入口 / MSVC 子进程入口 |
| `../tests/phone_bridge/build/*test.log` | 离线测试日志 |
| `../tests/phone_bridge/build/phone-ui-mobile.png` | 390px 手机页面截图，使用模拟 FPGA 状态 |

测试验证的是软件行为和可编译性，不能代替实际 ESP32 AP、UART 电气、FPGA/FTDI 交互、声音、延迟或烧录验证。此交付无任何实际烧录或物理联调结论。

### 继承的ESP32编译和离线测试结果（北京时间 2026-10-30）

最终源码于 **18:07:36** 实际编译成功，退出码 0：Flash **777,017 / 1,310,720 字节（59%）**；全局 RAM **45,576 / 327,680 字节（13%）**。最终编译日志没有警告。生成 `.bin`、bootloader、partitions、ELF 和 map；三份实际编译源码与当前源文件 SHA256 一致，生成 `.bin` 的 SHA256 也已核对。

原生 C++ 测试和 headless Edge 手机网页测试全部通过，包含 26 个严格 JSON 向量、RESULT 1–4、RESULT=0 但 actual 不等于目标、FTDI 静音保留导致手机目标 0 / 实际 1、滑杆回读、保持焦点时控件仍恢复实际值、队列合并、同帧重试、断链清队列与恢复、Panic、HTTP 心跳丢失及 JSON 导出。测试日志和机器可读汇总见上表，所有测试均使用软件模拟。
