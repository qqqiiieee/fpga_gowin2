# V047 · ESP32 手机控制与扩展桥

适用classic ESP32-WROOM32 / esp32:esp32:esp32，Arduino ESP32 core2.0.17。与V047 FPGA配套，已编译、烧入并校验。ESP负责网页、可靠UART控制、曲谱/映射文件、数字PCM录音存储与下载；FPGA负责实际音频合成，不通过手机播放替代FPGA声音。

GPIO17 TX→FPGA PMOD3 L9，GPIO16 RX←N8，GND共地，3.3V UART、1Mbps。手机连接Tang20K-Music / fpga2026，主页 http://192.168.4.1/ ，扩展 /extensions 。完整操作见根README与docs中的V046基础/V047补充教程。

- bridge_core/web_ui：参数、预设、ACK和实际回读。HTTP202仅入队。
- v041_core/json/runtime/ui：曲谱、128音符映射、Pad/CC映射、调度、HTTP页面。
- recording_uart：FPGA数字流接收与顺序文件写入；wav_view：虚拟WAV头。
- /api/state：链路和遥测；/extensions：曲谱、映射、录音。能力同步与实际激活成功后才显示已应用。

录音为FPGA最终数字PCM降采样后的15625Hz/PCM16/mono，最长30秒。内部/last.wav的前44字节保持占位；HTTP/USB下载统一走readWavRange，绝不能恢复seek(0)回写大文件头。

曲谱支持tang20k.score/1及/2；/2每组最多4音，音高41–72、四分之一拍网格、最多63组、组间不重叠，固定示范力度192。示例文件需手机手动上传，固件不预载；当前仅一个自定义槽。映射作用于音频音符，HDMI高亮/练习仍按物理键。

Windows源码构建：`python bootstrap_toolchain.py`，之后`powershell -File build.ps1`；或`-ToolchainRoot`指定已安装的隔离工具链。构建不访问串口、不上传。firmware/esp32的四镜像和烧录映射用于实际部署；不整片擦除已有数据分区。

V047真实WiFi曲谱往返和30秒非静音录音已验证；本机手机触屏完整流程、实际映射琴键和模拟输出延迟须另外确认。不要自动运行旧hardware脚本给演示设备预载测试谱。
