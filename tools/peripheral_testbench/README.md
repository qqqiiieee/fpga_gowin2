# V021 电容与双光束测试台

两个工具均默认只读：115200、8N1、16字节09诊断、请求flag=0x80。不会自动选端口、扫描设备、接管演奏或烧录。16键校准使用随包复制的原校准器；只有明确选择“校准并应用 --apply”才允许0x81运行时写入。

## 醒来后怎么用

1. 双击根目录的 **电容测试.cmd** 或 **光束测试.cmd**。本机已检测到 Python 3.11、Tk 8.6。入口优先用 `py -3`，其次 `python`；需要 Python 3.10+ 含 Tkinter。pyserial 3.5 随包附带，无需安装。工具不会自行安装任何软件。
2. 连接USB串口线；点击“刷新端口”，手动选择端口，再点“连接并只读检测”。只打开串口不算连接成功，必须收到版本09、XOR正确、seq匹配的回复。08 ACK不算成功。
3. 每个阶段先做好画面提示动作，保持稳定，然后点击“动作已做好，采集本阶段”。默认每阶段8个新回复，约1秒。不会用点击前已排队的采样作为本阶段证据。某阶段未通过仍可完成后续动作，最终报告列出原因。
4. 电容依次：全部释放 → 仅按住实际位置4（第2行第1列）→ 释放 → 仅按住5（第2行第2列）→ 释放。光束依次：通光 → 仅A遮挡 → 恢复 → 仅B遮挡 → 恢复 → 双遮挡 → 恢复。
5. 完成全部阶段自动导出。断开/窗口关闭也保存已有证据；也可随时点“导出当前 JSON / CSV / 中文结论”。每次在 `tools\peripheral_testbench\reports\` 下创建时间戳新目录，含 `诊断报告.json`、`原始采样.csv`、`中文结论.txt`，不会覆盖旧报告。检测与校准分别出报告。

**菜单恢复很重要：**V021每次诊断查询都会暂停HDMI菜单约0.5秒，持续查询会让菜单持续暂停。点击独立的 **停止轮询（保留连接）**，等当前事务结束、界面确认不再发送周期诊断，再等1秒；此时串口仍打开，但没有后续诊断。画面会显示“1秒已到：请松开全部触摸键，再按4/5并抬手切页”。只有点“继续只读轮询”才恢复查询。也可点“停止检测 / 断开”，关闭串口后等1秒再按。采集途中暂停会中断整套阶段，需要重新开始。校准前必须断开普通检测。

## 接线和诊断边界

电容：G/V/S单路模拟键盘，S经10k/10k分压到MCP3208 CH0，共地，ADC参考2.5V。界面电压为 `raw × 2.5 / 4095` 的估算，不是电压表实测。固件中心是未实物标定的估算值。电容测试要求释放raw<4、键mask清零；4/5按下raw在8..4094，跨度≤8码，中心间隔≥12码且采样区间不重叠；4应为0x0010，5应为0x0020。fault必须为0，sample_seq每阶段必须有推进。报告分别列原始码响应与键解码，避免把“raw有变化”误当成“菜单键解码正常”。通过只覆盖所测4/5，不代表16键全部合格。

touch_valid是单周期脉冲，轮询时通常为0；**不能用它证明/否定连接**。连接依据是匹配seq的有效09事务。sample_seq推进只能说明数字采样过程在活动，即使MISO卡零/悬空也可能推进，**不能单凭它宣布ADC正常**。0/满量程、噪声、释放、两档独立性、mask与fault须一起判断。超时/拔线立即停止并清空实时旧值，保留未完成报告；不自动重连，请排障后显式重新连接。

光束：SEN0503两对TX（各2线）+RX（各3线），四端均供3.3V且共地。RX OUT A=P8、B=P9，各自10k上拉到3.3V。开机两束通光至少200ms学习基线；如果TX是后来才补上电，须整板重启并保持通光。ready所有阶段都须为1，A/B每阶段必须稳定符合预期、独立切换并恢复。

V021 diag2 bit4=A blocked，bit5=B blocked，bit7=ready，bit0=touch_valid，bit1=touch_fault；diag3=sample_seq。blocked是**相对开机学习基线**，不是原始0/1电平，也不能推断RX的高低有效极性。V021显示真实电平“不可用”，JSON为null、CSV为空。新版V023按能力位识别：**仅bit11 raw_available=1时**才显示bit9 rawA、bit10 rawB；未声明能力时即使bit9/10有值也忽略。工具不会按工程版本号猜能力。

光束测试观察的是逻辑输入；不屏蔽演奏、不会发模式接管请求，因此实机遮挡动作仍可能触发乐器原有声音。

## 16键校准

- 先“停止检测 / 断开”，选择实际串口；模拟模式禁用校准。
- **16键校准：仅采集保存**：逐个实际4×4位置，按提示释放、按住，用另一只手点“动作已做好 / 下一步”。调用原 `touch_calibrate calibrate`，不带 `--apply`，只保存JSON/候选hex，不改生产源、不写FPGA。
- **16键校准并应用 --apply…**：只有用户明确点击并确认才带 `--apply` 重新完整采16键。采集合格后还需“全松”确认；逐项写运行时中心并检查16个index/value ACK，再全松query确认。中断/丢ACK不会重试不确定写，不会报成功，可能部分更新，查看 `touch_calibration.json` 的 `apply.status/writes_confirmed`。
- 应用属于运行时设置，不烧录、不复制hex到工程，断电持久性未验证。随包原校准器收集流程沿用原判据（24样本、噪声、中心间距、逐键释放守卫），不把校准日志解释成整个模拟前端已获仪表实测。
- 校准任务目录另有 `任务记录.json`。采集未完成时原校准器不会生成完整中心表；取消仍会关闭串口。写入阶段取消后状态可能未知，以ACK报告为准。

## 无设备先演练

在交付根目录用 PowerShell：

```powershell
python -B .\tools\peripheral_testbench\run.py --tool touch --simulate
python -B .\tools\peripheral_testbench\run.py --tool beam --simulate
python -B .\tools\peripheral_testbench\run.py --tool beam --simulate --raw-capability
python -B .\tools\peripheral_testbench\run.py --tool touch --cli --simulate
python -B .\tools\peripheral_testbench\run.py --tool beam --cli --simulate
python -B .\tools\peripheral_testbench\run.py --self-test
python -B .\tools\peripheral_testbench\run.py --tool beam --cli --simulate --fault swapped
```

模拟明显标记，不枚举/打开真实串口、不写校准、**永远不计硬件通过**。故障可选timeout/disconnect/stuck/swapped/not-ready/noise/touch-fault/frozen-seq/bad-xor/wrong-seq。`--raw-capability`演示新版能力。命令行退出码：0=本流程判据通过；1=阶段判据失败；2=通信失败/中断/参数错误。模拟exit0仍不是硬件通过。

仅枚举：`python -B .\tools\peripheral_testbench\run.py --list-ports`，不会打开端口。实机CLI必须明确 `--cli --port COM实际编号`，每阶段交互确认后只读采样。

## 复核与来源

```powershell
python -B -m unittest discover -s tests -p test_peripheral_testbench.py -v
python -B .\tools\peripheral_testbench\run_validation.py
```

验证完全使用mock/严格字节流替身，不连接硬件。`验证记录/` 保存本次交付测试和界面截图；`文件清单.json` 保存包文件SHA256。测试覆盖协议黄金帧、错版本/XOR/seq、分片/短写、断连/超时恢复、阶段噪声/卡值/rails/混键/光束串扰与恢复、模拟标记、显式校准/丢ACK、GUI暂停无继续发送及恢复。

`vendor/touch_calibrate.py` 原样复制自兼容基线 `instrument_expression_20261024/tools/touch_calibrate.py`，SHA256 `c2bac656deec662c8d77a5e1fc2bae84dfa6990cc9887578f3cd71e91c8f951d`；运行不依赖基线或开发目录。pyserial 3.5复制自本机安装，随附BSD许可证。无需联网。不包含Python解释器；没有Python/Tk时会停在错误提示，不会假装已启动。

这次交付是PC测试工具，未创建固件版本、未更改V021源码/Flash、未进行任何真实串口连接或烧录；无设备，实际供电/波形/菜单动作/音频仍待用户醒来实测。
