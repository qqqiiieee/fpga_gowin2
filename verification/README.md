# V047 验证材料与当前边界

本目录保留本版已完成的构建/仿真/实机报告，部分报告创建于烧录前，字段hardware_programmed=false是其历史时刻，不覆盖后来的Flash/ESP实测结果。当前整体状态以根manifest和V047_publication_state.json为准。

- build_summary、布局资源报告、时序报告：当前资源、Fmax与Setup/Hold0。
- FPGA编译输入哈希、ESP编译结果：原构建源码身份；发布verify_release核对这些身份和二进制。
- 鼓垫增益测试、和弦RTL测试、JSON跨语言编码测试、附加回归：V047生产改动覆盖，包括MIDI位图等价差分和负向对照。
- Flash固化结果、ESP32上传结果：真实写入与独立校验。
- V047_HTTP结果、V047实机结果：真实WiFi曲谱往返、三模式状态、30秒数字录音；源报告可能含本机路径，路径不是运行依赖。
- V047_publication_state：测试谱已清空，固件不变，不预载上传演示曲谱。

默认离线入口：

```sh
python scripts/verify_release.py
python scripts/run_release_checks.py
```

前者验证固件/生产输入/ESP源码/构建选项/发布校验表与工程文件存在；后者再重跑V047三个和弦RTL用例及手机JSON编码用例。需要Icarus（IVERILOG_BIN或PATH）、Node.js。不连接板、不录音、不上传曲谱。它是发布便携性检查，不宣称重跑所有历史bench；既有其他回归结果可在本目录检查。

当前尚无模拟输出端到端延迟实测、32频率实际谱峰图、完整32秒逐路录音、真实和弦逐音按键验收或物理冷启动记录。光电单束后备150ms是已知边界。30秒WAV是自动演奏测试，不是32峰验证音源；数字PCM录音也不证明DAC模拟输出。

Logic20381、Register9540、CLS10353、BSRAM41、DSP16.25。CLS余15，clk27 Fmax27.03MHz；新RTL须重新完整PnR。录音成功数据：468750样本/937544字节/CRC a5efac56，非静音且未报告掉样。原始录音与Flash个人数据备份不随代码提交。
