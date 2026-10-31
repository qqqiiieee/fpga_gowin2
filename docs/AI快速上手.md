# V047 · AI 快速上手

这是当前代码与设备状态交接，不是对话摘要。先读根README、manifest、架构说明、V034到V047更新说明，再看当前CST与相关模块。生产入口src/top.v；两端V047已固化，但all_requirements_verified=false。

- FPGA SHA见manifest；UserCode不是唯一版本号。任何生产RTL/.h/.ino改动都必须重新构建并更新对应固件/身份，不以改文件名代表编译。
- 32独立状态、2旋律音色、4鼓、三效果互斥；KEY0/STRUM1/HYBRID2。FSR0明亮度、FSR1拨弦阻尼，旧变量pressure_vibrato不能据名推断生产作用。
- 面板A11/B11/N6/D11；MIDI T8；光电P8/P9；ADS N9/N7；I2S B12/C12/B13；手机L9←D17、N8→D16，1Mbps；FTDI T13/M11仍115200。
- 禁用受损脚：T6/P6/R8/T7，T11/P11/T12/R11，D14/E15/B14/A15。N9复用脚必须use_sspi_as_gpio=1。
- 默认离线入口verify_release.py与run_release_checks.py不打开硬件。仓库保留一些旧runner作参考，不保证所有旧bench对当前参数有效。
- 修改MIDI必须保护完整音域、NoteOff、来源标签、排队/ready、延音和Panic；位图优化差分证据已存verification。教学来源3先Off后On，练习需新按下并同时held所有目标。
- 映射作用于合成音符；HDMI/练习按物理raw键。手机HTTP202只是入队；实际激活与ACK必须由FPGA确认。
- score/2最多63组、每组1–4升序唯一音高41–72、1/4拍网格、组间不重叠、组内同起止；velocity不改变固定示范力度192。不能承诺任意MIDI导入或三连音精确还原。
- 示例曲谱必须供用户用手机现场上传；不要预载到固件或硬件。验证后自定义槽已经清空；不要运行历史hardware_*脚本自动再上传。
- WAV实际15625Hz/PCM16/mono，最长30秒；内部文件头占位，统一wav_view::readWavRange叠加文件头，不回写LittleFS大文件头。HTTP/USB下载路径要一致。
- FFT与XY是数字只读支路；XY取两个独立声部，不是左右DAC。32路谱峰尚未实际采集；模拟延迟未测。光电单束fallback150ms是已知超标路径，不能用MIDI局部仿真掩盖它。
- 当前资源Logic98.288%、CLS99.855%(剩15)，27MHz Fmax27.03MHz；新RTL须完整PnR。显示改动守住整包CDC、帧边界双bank、同步/消隐/像素管线。
- 当前实机证据：真实Wi-Fi JSON上传往返、三模式状态、30秒非静音数字PCM468750样本/CRC a5efac56；不代表真人和弦练习、模拟底噪、冷启动或32谱峰验收。

修改入口：音频→voice_allocator/wavetable_synth/instrument_audio；FX→midi_control_bank/audio_effects；交互→four_button_display_control/top；光电→optical_strum/strum_player；教学→guide_* / piano_roll_*；手机→phone_extension_state与ESP v041_*；录音→recording_uart/wav_view。

本地新固件按AGENTS约定另存日期编号目录，Git主分支只维护当前版。不要提交工具链、账号/许可、对话、Flash数据备份或用户录音。发布只推代码与材料，不额外改变设备。
