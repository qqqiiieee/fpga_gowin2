"""生成V021使用、模块与接手说明；不修改固件或接线约束。"""
from pathlib import Path
import html

ROOT=Path(__file__).resolve().parents[1]
TEXT='''V021｜MIDI主奏 + 电容键盘专职屏控
日期：2026-10-30（北京时间）
状态：本文件描述实现方案；编译、仿真及实际烧录状态以版本信息.json和验证目录为准。

1. 本版方案
八线矩阵键盘从生产top和CST撤除；已有G/V/S模拟编码电容键盘接MCP3208 CH0，只负责HDMI菜单。不能用TTP229/I2C或数字多键触摸板直接替代此三线模拟编码板。
音符与力度：MIDI键盘。MIDI OUT经Type A TRS-DIN线、BMV51M001隔离接收器进入T8；不是把USB MIDI线插进FPGA当USB Host。
四旋钮：三页共用，软接管防止切页时参数跳变。打击垫：四种实时合成打击音。SP-2：键盘延音踏板。
摇杆X依实际MIDI Pitch Bend映射弯音，摇杆Y发送CC1时映射约6Hz颤音。若键盘发出其他CC，应先观察消息再修改映射。
双光束：扫弦方向/速度手势；MIDI按住的音符作为和弦。KEY模式正常键盘演奏并屏蔽光束，STRUM模式选和弦不直接发音，避免一次动作两次触发；无按住的音符时沿用默认C/E/G/C练习和弦。
FSR1：明亮度/滤波开合；FSR2：拨弦包络阻尼，重压更快止音，长笛不受此阻尼。两路不再触发鼓，也不重复音高或音量。FSR1需保持FILTER=1，基础明亮度不要先拧满，否则会因旁路或饱和而感觉不明显；FSR2须先选择拨弦音色并触发音符。
仅保留一只实体滑杆接ADS1115 A2控制主音量；第二滑杆和A3音高输入停用，A3接地。
HDMI屏幕：中文四页，演奏/曲库/帮助/诊断；保留波形及32路验证显示。屏幕USB只供电，不启用触控。不添加灯带。
手机/ESP32通信本版不实现，不预占串口。MAX98357不属于默认线输出路径。

2. 电容键盘操作（正面从左至右、从上至下S1..S16）
第一行：1/S1上一项，2/S2下一项，3/S3确认，A/S4返回。
第二行：4/S5前一屏，5/S6后一屏，6/S7播放/暂停，B/S8重启曲目。
第三行：7/S9长笛，8/S10拨弦，9/S11切KEY/STRUM，C/S12切FX。
第四行：*/S13紧急静音Panic，0/S14短按切滤波、长按1.2秒后松开切数字零，#/S15长按2秒进32振荡器验证，D/S16返回/退出验证。
普通菜单动作在单键干净松开后确认；Panic按下即发出且按住不连发。紧急清音时仍按住的MIDI琴键会被安全屏蔽，必须松开再按才恢复，避免清音后自动复响。多键、串键和歧义取消本次操作，需要全部松开后再试。
演奏页S1/S2选MAIN、ADSR、FX，S3确认旋钮页。曲库页S1/S2选三首练习，S3开始并回到演奏页。
32验证中S1/S2/S3/S4/S5/S6分别选择1/4/8/16/32路/扫描，S16退出；S13也可紧急静音退出。
验证无有效控制60秒后自动退出；长按和通信保活不续时。使用同一32路合成器逐路频率/相位/包络，不是播放预混音录音。请求数/活动包络数/实际频谱峰数不是同一指标，需声卡或示波器FFT做最后验收。

3. MIDI控制
旋律通道默认CH1（代码MIDI_CHANNEL=0），打击垫CH10（编号9）。音符支持0..127，最多32个独立旋律声部；超出32会执行原声部分配策略。
K1/K2/K3/K4固定识别CC93/91/71/74。MAIN：主音量/旋律-鼓组平衡/基础明亮度/FX干湿。ADSR：Attack/Decay/Sustain/Release。FX：时间/反馈/调制深度/干湿。
切换参数页后旋钮需转到屏幕当前值附近或跨过该值才接管；不是故障。主音量也接受CC7。实体滑杆位移至少4码才重新接管，轻微采样抖动不夺回旋钮音量。
打击垫常见Bank A音符36/37/38/39映射底鼓/闭镲/军鼓/开镲；另接受GM 35/42/40/46。仅当Pad实际发CH10时生效，应在首次实机测试确认。
CC64延音，CC1颤音，Pitch Bend弯音；PC0长笛/PC1拨弦，其余PC忽略。音色选择作用于之后的新声部。
FX循环顺序：OFF、Delay、Chorus、Reverb。三种共用一个效果器和延迟RAM，不是每声部复制三份。尾音保留，Panic/数字零/验证模式清除尾音；最长8秒无新输入后有界淡出。
旋律/四鼓混音先留数字峰值余量，因而同音量设置下可能比旧版更轻，应调主音量而不是删除限幅余量。

4. 首次接线与上电
先断电，照配套9页图的实际球位连接。PMOD编号、FPGA球位和转接板1..4编号不是同一编号；转接板两排朝向用已测通断结果确认，不凭“内外层”猜测。
MIDI接线R3勘误：用户实物BMV51M001 V1.0从NC端开始印着NC、RX、TX、VDD、GND，与官方表格RX/TX名称相反。现行接法：中间实物TX脚接T8，VDD接3.3V、GND共地，NC/RX留空。2026-10-30 15:20起45秒实测收到3459字节、41次Note On、40次Note Off、0帧错误，末次快照仍有按键按住；之前接实物RX时连续弹键却无字节/跳变。已恢复V021，UserCode 0x0000976F。该结果确认MIDI输入链路，不代表音频输出或全部旋钮映射均已验收。第9页已更新，FPGA球号及固件不变。
接线图R2第8页补充PMOD2背面焊点视图：保持用户2026-10-30照片方向，RGB LCD文字在上、Sipeed标志在下。B14是第2列下针（原理图J6.9）、A15是第2列上针（J6.10）、B13是第3列下针（J6.7）。B14确实存在，原固件球号不变；该方向不能直接套到正面或PMOD转接头。
矩阵八根线全部拔除，PMOD1空闲。所有ADC、触摸板及光束输出按3.3V域接线并共地；MCP用模块指定3.3V口，不用其5V-18V端子。
FSR：3V3 -> FSR -> A0/A1节点 -> 各自10k -> GND。上电让两片FSR完全无压力，等每路16次有效样本建立基线；采样过期会释放并重新标定。压力显示是归一化控制量，不是公斤。
滑杆只用一组三针VCC/GND/OTA到3V3/GND/ADS A2。另一组OTB/VCC/GND全不接；不是将两个模拟输出短接。
PCM5102A：B14 BCK、A15 LRCK、B13 DIN、共地。VIN额定电压和背面焊桥须按你的模块确认；XSMT用3.3V、FMT/SCK接地。详细配置见音频页。
PCM模块3.5mm是LINE OUT，推荐接有源音箱或耳放的LINE IN；普通耳机可继续插Dock板载PT8211孔。两个DAC并行，标准I2S不要求停用原耳机孔。严禁把MAX98357喇叭差分输出接耳机或电脑音频输入。
HDMI不传本项目音频，屏幕USB只供电。先低耳机音量上电再按MIDI键。

5. 触摸键盘标定
仓库默认touch_centers.hex及同源touch_centers_init.vh来自估算，不代表已对你的电容板实测。首次必须按面板真实位置逐键标定，不能按电压高低重新排序。
电脑连接Dock JTAG/UART USB，确认当前串口，开发目录执行：
python tools/touch_calibrate.py --list
python tools/touch_calibrate.py calibrate --port COM8 --output-dir "D:/Gowin_project/标定记录/V021_首次实测" --apply
COM8替换为实际端口；输出目录必须是尚不存在的新目录。电脑需要已有pyserial；工具只发诊断/校准协议，不烧录、不占MIDI口。
V021诊断轮询时暂停触摸菜单，避免长按#标定误进发声测试；若已有32测试，会先静音退出。标定完退出程序、松开全部键，等0.5秒后再操作菜单。诊断读取期间MIDI仍可演奏。
运行时--apply写的是RAM，重新烧录/掉电恢复固件默认中心。要持久化，把该次实测16个中心按row_major_keys写入assets/touch_calibration.json，运行scripts/generate_touch_centers.py，然后重新编译发布新版本。
中心必须8..4094且任意两键间距至少12码；如果失败先查模拟量分压/供电/接线，不强行合并键或用最近键掩盖错误。

6. 项目结构
top.v：只装配音频、遥测、触摸菜单、曲目练习、HDMI；生产固定DISPLAY_TOUCH_ONLY=1、COMPACT_UI=1、LIVE_ADSR_ENABLE=1、EFFECTS_ENABLE=1。
instrument_audio_top.v：上电复位、验证所有权交接、输入/声音/LED装配、PT8211与PCM5102A并行。滤波控制只选一路；Panic/校准能安全退出验证。
instrument_inputs.v：ADS、MCP触摸、调试、控制银行；触摸与虚拟UI键永不产生local NoteOn/NoteOff。A3停用不等待其采样。旧矩阵分支只保留兼容独立历史测试，生产不综合。
performance_input_hub.v：MIDI/光束事件仲裁、音量所有权、弯音与CC1、来源标签与Panic。STRUM模式保留held chord但不把键盘按下再送一遍旋律。
midi_keyboard.v / midi_uart_rx.v：31250bps协议、running status、延音、CC、Pad、故障清音。midi_control_bank.v：三页旋钮参数和软接管。
mcp3208_reader.v / analog_touch_keypad.v：24位SPI CH0、三样本稳定、中心距离/歧义检测与过期释放。remote_debug_link.v / tools/touch_calibrate.py：查询/运行时校准；诊断不启用远程演奏接管。
ads1115_reader.v / slider_controls.v / pressure_expression.v：I2C采集、A2主音量、两路FSR无负载基线、死区与平滑。保留pressure_vibrato旧接口名，但生产连接到拨弦damping，不是揉弦。
voice_allocator.v / wavetable_synth.v：32路独立状态，时分复用运算，8clk/声部，27MHz下每288clk一音频采样。PHASE_RAM=1，两种半表音色ROM。实时ADSR和拨弦阻尼只影响普通演奏，test_mode强制固定测试频率及独立验证包络。
drum_voice.v / snare_voice.v / hat_voice.v / performance_mixer.v：四鼓与旋律的有符号混音，平滑互补权重和饱和边界。
dc_blocker.v / audio_cleanup.v / audio_effects.v / audio_controls.v：去直流、明亮度/低通、共享全局FX、主音量与弯音平滑。FX固定tick+63clk发布，RAM不整块复位，读有效范围受元数据约束。
pt8211_driver.v / pcm5102a_i2s.v：两个不同音频串行协议读取同一最终16bit PCM。PCM5102A标准I2S BCK3MHz、LRCK93.75kHz、16bit双声道；不可把旧PT8211右对齐信号冒充标准I2S。
touch_display_control.v：单键菜单与长按诊断。oscillator_test_control.v：原32频测试的淡入淡出、持有和退出状态机。
song_guide.v：三首练习，MIDI键位提示、错键、按住约80%目标时值才推进、独立节拍辅助。它不是任意乐谱导入或完整节奏评分系统。
hdmi_live_display.v / hdmi_status_cdc.v / hdmi_compact_dashboard.v / wave_scope.v：289bit整包握手跨域、帧边界换状态、四拍画面管线、波形双缓冲。不得逐位同步多位总线，不得因为显示PLL失锁而复位音频。
assets/*.json + scripts/generate_*.py：中文字库/界面布局/半波表/触摸中心的可重复生成输入。触摸HEX和异步复位常量init.vh由同一JSON同时生成并核对，禁止仅改一份。生成资产检查必须通过；不要只手改生成vh或hex。
src/multi_tone.cst / src/matrix_clock.sdc：真实球位和三时钟约束。保留旧matrix_clock文件名不代表仍使用矩阵输入。

7. 维护与验证边界
python scripts/run_v021_tests.py：触摸16键无音符、MCP24位事务、MIDI32声部、UI与持有和弦隔离、光束不双触发、Panic、单键32验证、校准保护及保留协议用例。
python scripts/run_touch_display_tests.py：触摸菜单/紧急清音/289位CDC/四拍像素布局。
python scripts/run_control_bank_tests.py：CC/软接管/四Pad/镲音；其长生产用例超时不能记成通过。
python scripts/run_live_adsr_tests.py：包络、阻尼、RAM/寄存器两实现、正负满幅、旧默认兼容和32路验证隔离。
python scripts/run_effects_tests.py：Delay/Chorus/Reverb参考模型、边界/清除/切换/完整8秒尾音。长仿真保持生产采样比，耗时不等于板上运行慢。
python scripts/build.py：本机Gowin完整编译，拒绝源码变更或未更新的旧fs。
python scripts/summarize_build.py：从本轮PnR读取资源、时序、UserCode、SHA256；Logic和CLS分别报告。
数字仿真不验证耳机底噪、线材、光束阈值、触摸中心或真实MIDI设备映射。实际烧录和听音状态单独记录，不能把旧版测试/旧fs改名当新版。
下一版使用新的北京时间目录和编号，包含源码、固件、改动/验证/烧录记录；不覆盖V020/V021，也不散放桌面。
'''

def main():
    out=ROOT/'docs';out.mkdir(exist_ok=True)
    (out/'V021_架构与AI交接.txt').write_text(TEXT,encoding='utf-8-sig')
    body='\n'.join('<p>'+html.escape(p)+'</p>' for p in TEXT.split('\n') if p)
    page='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>V021 使用与架构说明</title><style>body{font:17px/1.8 "Microsoft YaHei",sans-serif;background:#f2f6fa;color:#16364b;margin:auto;max-width:1050px;padding:28px}p{background:white;padding:8px 20px;border-radius:8px;overflow-wrap:anywhere}nav{padding:20px;background:#dcecf5;border-radius:12px}a{color:#08648f}</style><nav><b>V021｜使用与架构说明</b>　<a href="V021_接线图/完整接线图.html">打开9页接线图</a>　<a href="../validation/build_summary.json">编译实测记录</a>　<a href="https://www.ti.com/lit/ds/symlink/pcm5102a.pdf">PCM5102A原厂资料</a></nav>'''+body+'</html>'
    (out/'V021_使用与架构说明.html').write_text(page,encoding='utf-8')
    print('V021_NOTES_GENERATED',out)

if __name__=='__main__':main()
