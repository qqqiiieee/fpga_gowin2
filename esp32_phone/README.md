# V034 · ESP32 手机控制桥

适用 **classic ESP32-WROOM32 / ESP32 Dev Module**，Arduino ESP32 core **2.0.17**，FQBN `esp32:esp32:esp32`。不是C3/S3固件。网页内嵌在 `web_ui.h`，不需要CDN、文件系统分区或ArduinoJson。FPGA负责声音；本桥不录音、不播放、不传输音频。

V034配套源码与二进制已编译并记录SHA256，但**尚未上传本版到实物**。当前FPGA和ESP32需要一起升级；旧ESP桥只允许模式0/1，会拒绝HYBRID=2的回读。固件在 [`firmware/esp32/`](../firmware/esp32/)，身份见 [`manifest.json`](../manifest.json)。

## 内部三线与手机连接

| ESP32 | Tang Primer 20K PMOD3 | 方向 |
|---|---|---|
| D17 / GPIO17 / UART2 TX | L9 / phone_uart_rx | ESP→FPGA |
| D16 / GPIO16 / UART2 RX | N8 / phone_uart_tx | FPGA→ESP |
| GND | GND | 公共地 |

ESP32 Type-C烧录后可只接USB电源，不需要一直连电脑；手机不接数据线。三根UART线固定在作品内部即可。两块板各自正常供电，3V3稳压输出不相连；接口不是5V TTL或RS232。FTDI与MIDI端口保持独立。

1. 先部署匹配固件并接好内部UART三线，给两块板上电。
2. 手机连接Wi-Fi **Tang20K-Music**，密码 **fpga2026**；提示无互联网时保持连接。
3. 浏览器打开 **http://192.168.4.1/**，等待“FPGA已连接”及参数同步完成。
4. 选音色或KEY/STRUM/HYBRID。参数先显示请求入队，只有FPGA ACK/实际读回吻合才确认。
5. 手机离线后面板和乐器仍可演奏；FPGA重启恢复默认值，不自动保存整套参数。

**已知帮助文字问题**：当前 `web_ui.h` 内嵌帮助仍写旧T11/P11，实际代码与CST为上述 **L9/N8**。本发布保持已编译源码与bin一致，没有只改文字后冒充旧bin；修复需要重新编译并更新哈希。

## 构建与上传

Windows可在本目录运行：

```powershell
.\build.ps1
# 已有完整兼容工具链时，可避免重新下载：
.\build.ps1 -ToolchainRoot '你的已有工具链目录'
```

`bootstrap_toolchain.py` 只下载隔离的Arduino/Espressif构建依赖。`build.ps1`将三份正式源码暂存至`.build_work/sketch/esp32_phone`，输出到`build/`，记录编译状态及源码/bin哈希。工具链、缓存、编译输出不提交。此构建脚本为Windows路径；其它平台可用Arduino CLI安装core2.0.17后按同一FQBN构建。

上传是独立步骤，先确认当前连接的CH340/CP210x串口，**不能沿用另一台机器的COM号**。在本目录使用已配置的Arduino CLI，例如：

```powershell
$cli = '.\.toolchain\cli\arduino-cli.exe'
& $cli upload --config-file '.\.build_work\arduino-cli.yaml' `
  --fqbn 'esp32:esp32:esp32' --port 'COMx' `
  --upload-property 'upload.speed=115200' --input-dir '.\build' `
  '.\.build_work\sketch\esp32_phone'
```

若复用外部工具链，`$cli`应改为其CLI实际路径。上传已经发布的配套bin时，把`--input-dir`设为仓库 `firmware/esp32`，其余仍用同一core/FQBN；上传不会替你编译。不要把单个应用bin盲写到Flash起始地址。编译/上传/校验/复位分别记状态，最终还需手机与FPGA实际联调。

## 控制契约与排查

完整表见 [phone_protocol.md](../docs/phone_protocol.md)。输入模式参数2允许0/1/2，音色参数1只允许0/1。K1–K3是效果强度、K4是音量；手机参数5/6/7另为time/feedback/mod，不能混淆。

网页读不到FPGA时看 `/api/state` 的 `linked`、`synced`、`stale`、tx/rx/retries/ignored。rx只统计有效响应，不是逻辑电平计数。tx增长但rx=0，先核对D17→L9、N8→D16、公共地、供电、FPGA固件和115200串口。绿色只代表协议链路，不证明外接音频、光电手势或FSR已通过。

桥断链会丢弃待发写入，恢复后完整回读，禁止重放过期写入。HTTP 202仅为入队。Panic与持续digital zero分开；网页、旋钮和面板以FPGA回读的实际值为准。

离线测试在仓库根目录执行 `python tests/phone_bridge/run_native.py` 和 `npm run test:phone-web`，或当前统一检查入口。它们使用模拟UART/HTTP状态，不访问实物。
