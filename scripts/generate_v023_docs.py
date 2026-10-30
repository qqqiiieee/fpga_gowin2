"""生成本轮实验版说明和可核对的接线表；不触及历史版本或硬件。"""
from pathlib import Path
import html,json
ROOT=Path(__file__).resolve().parents[1]

def main():
 docs=ROOT/'docs';docs.mkdir(exist_ok=True)
 rows=[
 ('MIDI输入','键盘 MIDI OUT → Type-A TRS/DIN线 → BMV51M001 MIDI IN','BMV实物中间 TX → PMOD0 T8；VDD→3V3；GND→GND；RX、NC留空','实际模块丝印与旧说明方向不同；TX接T8这条已在V021实测收到琴键。键盘USB单独供电。'),
 ('电容菜单键盘','G/V/S板 V→3V3，G→GND；S→10k→MCP CH0；CH0再经10k→GND','MCP CLK→T6，DIN→P6，OUT→R8，CS→T7；模块3.3V→3V3，G→GND','MCP1525提供2.5V参考；触摸中心仍为估算，先用V021测试工具实测校准；不是8线矩阵扫描。'),
 ('压力与滑杆','ADS1115 VDD→3V3，GND/ADDR→GND，ALRT留空','SCL→PMOD2 D14；SDA→PMOD2 E15；A0/A1→两FSR分压节点，A2→滑杆OTA，A3→GND','各FSR一端3V3、另一端接ADC并经10k到GND；滑杆只接一组VCC/GND/OTA，OTB组留空。FSR1明亮度、FSR2拨弦阻尼。'),
 ('双光束','每对TX和RX都供3.3V；红→3V3，黑→GND，共两对四端','A接收端白OUT→PMOD0 P8；B白OUT→P9；每路OUT各10k上拉到3V3','先对准、两束保持通光再开机，稳定200ms学习空闲。后补发射端电源需整板重启。KEY模式不由光束发音，STRUM需先按住MIDI和弦。'),
 ('PCM5102A I2S','BCK→PMOD2 B14；LRCK→A15；DIN→B13；GND→公共地','SCK→GND，FMT→GND，XSMT→3V3；本次沿用已测A3V3=+3.3V的供电方案','这条实物仍待排查，不因新固件就宣称正常。LINE OUT用于线输入/耳放，普通耳机不能作为唯一验收负载；板载3.5mm仍并行输出。'),
 ('手机通信（新增）','ESP32 GPIO17/TX2 → FPGA PMOD1 T11 / phone_uart_rx','FPGA PMOD1 P11 / phone_uart_tx → ESP32 GPIO16/RX2；双方GND相连','ESP32使用自身USB供电，不连接两个稳压器的3V3输出。115200 8N1，3.3V逻辑，绝不并接FTDI T13。仅适用图中经典ESP32-WROOM32 30Pin；其它芯片需改配置。'),
 ('显示/调试/音频','HDMI屏仍接板载HDMI；屏供电不承载触摸控制','JTAG&UART USB→电脑；板载3.5mm→耳机','原引脚完全保留，PMOD1仅增加T11/P11。MAX98357和扬声器本轮不接入，手机不使用屏幕USB触控。')]
 table=''.join('<tr>'+''.join('<td>'+html.escape(c)+'</td>' for c in row)+'</tr>' for row in rows)
 page='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>V023 实验版与接线</title><style>
body{font:17px/1.7 "Microsoft YaHei",sans-serif;color:#173149;background:#f4f7fa;margin:0}main{max-width:1200px;margin:auto;padding:32px}h1,h2{color:#113d60}section{background:white;border-radius:14px;padding:24px;margin:20px 0}.note{background:#fff1cc;padding:18px;border-left:6px solid #d99a17}table{border-collapse:collapse;width:100%;font-size:15px}td,th{border:1px solid #c6d5df;padding:12px;text-align:left;vertical-align:top}th{background:#e7f3fa}code{background:#edf2f6;padding:2px 5px}a{color:#006b9a}img{width:100%;height:auto}@media print{section{break-inside:avoid}main{padding:0}body{background:white}td{font-size:11px}}</style><main>
<h1>V023｜手机通信、四旋钮FX、四Pad鼓组</h1><p>北京时间 2026-10-30 · 独立实验版 · 从V021分支 · <b>本轮未烧录FPGA或ESP32</b></p>
<div class="note">先保留板上已固化的V021，醒来先完成电容/光束测试，再决定何时试V023。旧版PCM5102A无声问题仍未完成实物定位，不能由数字仿真代替。</div>
<section><h2>先做哪一步</h2><ol><li>打开交付的“电容测试.cmd”，选择JTAG/UART对应串口，记录空闲、按4、释放、按5、释放。若码值变化却不能认键，再采集16键校准。</li><li>点“停止检测”，等待1秒，全部抬手，再短按电容面板4/5并释放，检查HDMI前后翻页。诊断轮询会有意暂停菜单，不能一边轮询一边判定切页失效。</li><li>两对光束的发射和接收端都供电，对准后保持通光重启FPGA，打开“光束测试.cmd”，按引导遮挡A/B并恢复。</li><li>外设问题基本清楚后再加载V023与ESP32程序，按下文手机步骤验证。此说明不自动触发烧录。</li></ol>
<p>本机测试入口：<a href="../tools/peripheral_testbench/">V021外设测试工具目录</a>；发行包内也附有tools/peripheral_testbench。</p></section>
<section><h2>功能变化与边界</h2><ul><li>32声部、两种音色、压力表情、滑杆主音量、双光束、4页HDMI、板载DAC与外接I2S沿用。矩阵输入不恢复，电容键盘仍专职菜单。</li><li>K1/CC93=时间，K2/CC91=反馈，K3/CC71=调制深度，K4/CC74=干湿；所有页面固定。默认FX为OFF，先点手机Delay/Chorus/Reverb或按面板C/S12，才能明显听见湿声。</li><li>旋钮有软接管：先转过屏幕显示的目标值才接管；手机改该值后会重新等待。K3在Delay模式可能不明显，Chorus更适合测试调制。</li><li>Pad只触发鼓：CH10 Bank A，36底鼓、37闭镲、38军鼓、39开镲；保留35/42/40/46等原GM兼容映射。若键盘改过CC或Pad映射，需先恢复该映射或重新采集实际消息。</li><li>手机可控制音量、两音色、KEY/STRUM、FX四参数、ADSR、HDMI页、滤波、数字静音及Panic；JSON预设可导入导出。ADSR不再占用四旋钮。实体主音量滑杆或CC7发生足够变化仍可取得音量控制。</li><li>手机本轮是参数通信，不包含WAV录音、手机音频传输或任意曲谱文件导入；网页确认须收到FPGA ACK，ESP32连上WiFi不等于FPGA连通。</li><li>光束诊断新增滤波后的真实0/1电平标志；V021只能看到相对开机基线的遮挡状态。测试工具会自动区分。</li></ul></section>
<section><h2>手机接入图</h2><img src="V023_手机UART接线.svg" alt="ESP32与Primer20K独立串口接线"><p>PMOD1焊盘标号按底板实物丝印查找：T11/P11是一组信号脚，不能把针排层数或杜邦线颜色当成引脚编号。原矩阵键盘已撤除，此处是释放后的空闲引脚。</p></section>
<section><h2>完整接线核对表</h2><div style="overflow:auto"><table><thead><tr><th>模块</th><th>接法</th><th>FPGA/其余端子</th><th>核对重点</th></tr></thead><tbody>'''+table+'''</tbody></table></div></section>
<section><h2>手机使用顺序（等准备测试新版时再做）</h2><ol><li>按新接线连接独立UART，FPGA加载本版instrument_v023_test.fs。ESP32用其目录build.ps1编译，之后由用户选择ESP32正确串口下载；此轮已经编译验证但没有自动下载。</li><li>手机连接WiFi <code>Tang20K-Music</code>，密码<code>fpga2026</code>，浏览器打开 <code>http://192.168.4.1/</code>。手机若提示无互联网，选择保留此WiFi连接。</li><li>等界面显示FPGA已连接并回读完成，再改参数；未连接/过期不能当作设置成功。测试先用板载3.5mm正常音频路径。</li><li>先KEY模式、音色长笛/拨弦，正常弹键；选择Chorus，干湿约80~140，再试四旋钮。随后敲四个Pad，验证独立鼓音；音量先低。</li><li>切STRUM后保持MIDI和弦，再先后挡A/B。完成后回KEY。Panic清声音与尾音，已按住的键须松开再按才能恢复。</li><li>参数是运行时值，FPGA掉电恢复默认；JSON预设保存到手机后可重新导入，不会在每次连接时擅自覆盖当前实体控制。</li></ol><p>桥接实现、实际编译记录、引脚和故障说明见 <a href="../esp32_phone/README.md">ESP32说明</a>。协议详见 <a href="phone_protocol.txt">phone_protocol.txt</a>。</p></section>
<section><h2>模块与验证</h2><p>FPGA：phone_control_link负责独立协议/ACK，midi_control_bank负责参数与软接管，touch_display_control负责手机和触摸的UI状态仲裁，原instrument_inputs/audio保留32声部与音频路径。ESP32只提供WiFi和参数桥，不替代FPGA合成。</p><p>可复跑：<code>python scripts/run_v023_tests.py</code>、<code>python scripts/build.py</code>、<code>python scripts/summarize_build.py</code>。仿真系统测试只在HDMI物理发送器边界使用桩；布局布线使用实际HDMI RTL和PLL。原硬件接线、听音、手机和实际光束/电容输入均需后续实测。</p><p>真实资源与时序：<a href="../validation/build_summary.json">构建记录</a>；<a href="../validation/v023/summary.json">回归记录</a>。新功能在本轮没有写入任何板卡。</p>
<p>接口依据：<a href="https://docs.espressif.com/projects/arduino-esp32/en/latest/api/wifi.html">Espressif WiFi</a>、<a href="https://docs.espressif.com/projects/arduino-esp32/en/latest/api/serial.html">Espressif UART</a>。</p></section></main></html>'''
 (docs/'V023_使用与完整接线.html').write_text(page,encoding='utf-8')
 svg='''<svg xmlns="http://www.w3.org/2000/svg" width="1150" height="610" viewBox="0 0 1150 610"><style>text{font-family:'Microsoft YaHei',sans-serif;fill:#173149;font-size:21px}.title{font-size:30px;font-weight:bold}.small{font-size:18px}.box{fill:#eef6fb;stroke:#5989a9;stroke-width:2}.wire{fill:none;stroke-width:5}</style><rect width="1150" height="610" fill="white"/><text x="35" y="50" class="title">V023 新增接线：手机 → ESP32 → FPGA</text><text x="35" y="87" class="small">经典 ESP32-WROOM32 / 30Pin · 115200 8N1 · 3.3V TTL · 本轮未烧录</text>
<rect class="box" x="35" y="125" width="255" height="350" rx="14"/><text x="60" y="170" class="title">ESP32</text><text x="60" y="211">自身 USB 单独供电</text><text x="60" y="285">GPIO17 / TX2</text><text x="60" y="355">GPIO16 / RX2</text><text x="60" y="425">GND</text>
<rect class="box" x="760" y="125" width="350" height="350" rx="14"/><text x="785" y="170" class="title">Tang Primer 20K</text><text x="785" y="211">Dock PMOD1</text><text x="785" y="285">T11 / phone_uart_rx</text><text x="785" y="355">P11 / phone_uart_tx</text><text x="785" y="425">GND</text>
<path class="wire" stroke="#c57424" d="M290 278H760"/><polygon fill="#c57424" points="746,268 760,278 746,288"/><text x="370" y="260">发送 → 接收</text>
<path class="wire" stroke="#167ba8" d="M290 348H760"/><polygon fill="#167ba8" points="304,338 290,348 304,358"/><text x="370" y="331">接收 ← 发送（ACK）</text>
<path class="wire" stroke="#35434c" d="M290 418H760"/><text x="375" y="406">公共地</text><text x="35" y="520">不连接两板的 3V3 输出；不接入 FTDI 调试口 T13/M11。</text><text x="35" y="561">手机连接 Tang20K-Music → 密码 fpga2026 → 浏览器 192.168.4.1</text></svg>'''
 (docs/'V023_手机UART接线.svg').write_text(svg,encoding='utf-8')
 (ROOT/'README.txt').write_text('V023 独立实验版：先看 docs/V023_使用与完整接线.html。\n本轮只开发、离线验证和编译，没有烧录FPGA/ESP32。板上仍为V021。\n外设测试工具 tools/peripheral_testbench 可直接配合已烧录V021，醒来先测电容再测双光束。\n源码结构沿用V021；手机协议见docs/phone_protocol.txt，ESP32桥见esp32_phone。\n',encoding='utf-8-sig')
 print('V023_DOCS_GENERATED')

if __name__=='__main__':main()
