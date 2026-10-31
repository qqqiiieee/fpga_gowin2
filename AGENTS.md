# 当前工程工作约定 · V047

- 先读manifest.json、README、docs/AI快速上手.md、docs/项目架构与模块说明.md、docs/V034到V047更新说明.md。入口instrument_handoff.gprj / src/top.v。
- 当前V047两端已固化并校验；WiFi上传与30秒数字录音实测通过；模拟延迟、32峰频谱、冷启动等尚未全部验收。保持事实边界。
- 32独立相位/包络状态、2音色、4鼓、KEY/STRUM/HYBRID、FSR明亮度/阻尼、单条互斥FX。旧矩阵/电容菜单/滑杆/MCP停用。
- CST为准：MIDI T8；光电P8/P9；ADS N9/N7；I2S B12/C12/B13；四键A11/B11/N6/D11；手机L9/N8、1Mbps。受损前两组T6/P6/R8/T7、T11/P11/T12/R11、D14/E15/B14/A15停用。
- use_sspi_as_gpio=1不可丢；生产源、生成资产、构建选项、FPGA/ESP二进制必须与manifest同源。
- 音频改动保护NoteOff/来源/Panic、phase/envelope RAM流水和288clk预算；显示保护整包CDC、双bank、帧边界与消隐/像素对齐。
- score/2、能力字、ACK两端配套；教学来源3先Off后On。原始物理held与映射音符分离；手机202不等于已应用。
- 不自动把示例JSON预载到设备，用户要手机现场上传。录音虚拟头readWavRange不可改回seek(0)写头。
- 默认离线scripts/verify_release.py与scripts/run_release_checks.py不访问硬件。其他历史测试先核对适用参数，不能全部当本版入口。
- 不提交工具链/缓存/安装包、账户/许可、对话、个人录音或Flash数据备份。主分支只维护当前一版，旧版由Git历史追溯。
- 本地新固件放D:/Gowin_project/乐器版本/YYYY-MM-DD_HHMMSS_Vnnn_改动摘要（北京时间），带源码、固件、版本说明/JSON、验证与烧录记录；不覆盖旧版，不散放桌面。同一固件的文档和记录可同目录更新。
- CLS余15，任何RTL改动必须完整PnR与时序检查。不能把0时序违例等价于端到端低延迟合格。
