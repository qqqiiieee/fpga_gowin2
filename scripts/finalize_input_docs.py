"""将并行文档草稿收敛到已验证的V019实现；不改RTL或固件。"""
from pathlib import Path
import hashlib,json,re

ROOT=Path(__file__).resolve().parents[1]

def write(name,text):
    (ROOT/name).write_text(text.strip()+'\n',encoding='utf-8')

def main():
    doc=ROOT/'docs/V019_MIDI与光电接线测试.html'
    text=doc.read_text(encoding='utf-8')
    text=text.replace('V019 正在并行开发；下文“应当”的行为是验收目标，不能据此认定整机已经 PASS。','V019 的离线仿真、Gowin布局布线与时序已通过；下文首次测试仍需真实硬件执行，不能据此认定整机实测 PASS。')
    text=text.replace('主 agent 最终交付的','本目录交付的')
    text=text.replace('CH10 Pad Note 36 / 38','CH10 Pad Note 35/36 / 38/40')
    text=text.replace('36 → 底鼓，38 → 军鼓，保留力度。','35/36 → 底鼓，38/40 → 军鼓，保留力度。建议配置为36和38。')
    text=text.replace('其他 pad / bank 保持自选但当前映射不处理。','35/36也可触发底鼓，38/40也可触发军鼓；其余Note当前不处理。')
    text=text.replace('CC120 / System Reset FF','CC120 / Stop FC / System Reset FF')
    text=text.replace('Clock / Start / Stop 等忽略其演奏动作。','Clock / Start / Continue 等忽略其演奏动作；Stop FC执行全局清音。')
    text=text.replace('开发快照：当前 optical_strum.v 的参数（尚待主 agent 集成验收）','已交付 optical_strum.v 的参数（离线验证通过，手势实测待做）')
    text=text.replace('上述阈值、同时触发策略及最终和弦选择 / 释放逻辑须与交付源码再次核对。','上述分档已由单元与整合仿真核对；两束同时变化按升序、力度180、间隔6ms处理，不推断真实方向。')
    start=text.index('<section id="verification">')
    end=text.index('<footer>',start)
    verified='''<section id="verification"><h2>8　软件验证与到货实测边界</h2>
<div class="note"><strong>最终实现已收敛：</strong>CH10的35/36为底鼓、38/40为军鼓；FC/FF及主旋律通道CC120执行全局清音。音量/音高只在数值变化时重新夺取控制；清音会取消旧光弦队列。进入数字零测试也清除所有来源，退出后要松键重按或重新扫动，避免旧按键恢复出声。</div>
<table><thead><tr><th>项目</th><th>交付状态及证据</th></tr></thead><tbody>
<tr><td>整版构建</td><td>UserCode 0x00005D02，Setup/Hold违例均0。Logic18141、Register7659、CLS9999、BSRAM9、DSP12.25；CLS约96.44%，后续扩展仍需控制规模。<a href="../validation/build_summary.json">实际构建记录</a></td></tr>
<tr><td>系统仿真</td><td>12项主回归通过，旧行映射负例按预期失败；另测全部输入启用时触摸、数字零退出、来源隔离。真实31250bit/s串行时序覆盖32音符、延音、光弦与测试模式隔离。<a href="../validation/acceptance.json">汇总验收与源哈希</a></td></tr>
<tr><td>独立审查</td><td>静音退出挂音及HDMI仍用本地键的问题均已复现、修复并复验。<a href="../validation/midi_optical_integration_review.json">审查记录</a></td></tr>
<tr><td>相位RAM</td><td>4种模式逐拍比对和3项故意破坏测试通过；保留32声部。冻结参考构建减少735个寄存器；最终整版资源以上行数据为准。</td></tr>
<tr><td>接线图与映射</td><td>SVG已渲染目检；官方资料、连线方向与最终映射已核对。<a href="../validation/docs_final_followup.json">文档最终跟进</a>；并行草稿记录保留供追溯，不代表最终未完成。</td></tr>
<tr><td>触摸基线</td><td>V018 UserCode 0x0000BDFC。默认中心是估算值，首次使用仍须逐键标定。<a href="V018_触摸键盘接线与测试.html">接线与标定步骤</a></td></tr>
<tr><td>实机</td><td>未烧录、未测供电/线材/极性/MIDI事件/耳机声音/端到端延迟。请执行第6节，记录实测结果。仿真通过不等同于实机通过。</td></tr>
</tbody></table>
<p>Gowin仍报告既有TMDS位宽截断及触摸中心表异步置位/复位提示；编译器未因此失败，运行时标定和复位后的实际表现仍应按首次测试核对。完整日志随版本保存。</p>
</section>
'''
    text=text[:start]+verified+text[end:]
    # 将末尾监视工具区移入主文档宽度，避免在宽屏上脱离正文。
    text=text.replace('</main><section><h2>只读输入监视','<section><h2>只读输入监视')
    text=text.replace('</section></body></html>','</section></main></body></html>')
    doc.write_text(text,encoding='utf-8')

    mapping=ROOT/'assets/midi_tiny_mapping.json'
    data=json.loads(mapping.read_text(encoding='utf-8'))
    data['status']='offline_validated_hardware_pending'
    data['control_arbitration'].pop('implementation_snapshot_caveat',None)
    data['control_arbitration']['validated_behavior']='首个MIDI值可接管；此后只有新数值变化接管，实体滑杆移动可夺回；重复相同MIDI值不夺回。'
    data['safety_and_release_contract']['global_panic_triggers']=['melody_channel_CC120','Stop_0xFC','SystemReset_0xFF','ActiveSense_armed_stream_timeout','UART_framing_error','FIFO_overflow','remote_takeover_rise','digital_zero_rise']
    data['safety_and_release_contract']['digital_zero']='清除所有来源/活动光弦，退出不重放旧按键，松键重按或新手势恢复。'
    data['implementation_snapshot_protocol_differences']=[]
    data['ignored_performance_messages_contract']=['非支持通道普通演奏消息','其他ControlChange与ProgramChange','CH10除35/36/38/40外的pad音符','Aftertouch','SysEx/MMC','MIDI Clock/Start/Continue等未映射实时消息；FC除外']
    data['verification_boundary']='最终RTL单元/系统仿真、源哈希、Gowin构建/时序及文档渲染通过；未烧录/测真实硬件。JSON是工程映射说明，不是键盘配置文件。'
    mapping.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')

    write('docs/V019_项目架构与模块说明.txt','''
V019 项目架构与模块说明 | 2026-10-24

1. 当前范围
Tang Primer20K/GW2A-18C，27MHz。2种主旋律音色（长笛、拨弦），共享32独立声部；底鼓/军鼓独立。
保留ADS1115双压力、双滑杆、旧矩阵、中文四页HDMI、3曲跟弹、32不同频率验证、远程诊断和板载PT8211耳机。
新增模拟电容触摸、MCP3208、TINY+32独立MIDI、SEN0503双光束。顶层默认TOUCH/MIDI/OPTICAL/PHASE_RAM均1。
本版只准备代码、固件、接线与离线验收；真实器件链和板上当前固件未确认。

2. 数据流
top：板级端口、时钟/复位、instrument_audio_top、HDMI与UI状态连接。
instrument_audio_top：连接输入与音频引擎，处理测试模式所有权/淡入淡出、输出时序与监视信号。
instrument_inputs：读取实体输入、原调试串口，保留本地按键菜单语义，再把演奏事件送performance_input_hub。
performance_input_hub：本地、MIDI、光电三来源仲裁；共用音色选择、音量/音高所有权、代表音符与状态诊断。
instrument_audio：voice_allocator -> wavetable_synth -> 混音/清理/静音 -> pt8211_driver。

3. 触摸与旧矩阵
mcp3208_reader：SPI mode0，500kHz，24bit帧，CH0启动到启动5kHz；数据在后12个上升沿采样。
analog_touch_keypad：单模拟量对应16档中心，34周期顺序搜索，3样本消抖；动态接收窗/歧义拒绝，100ms过期释放。
touch_centers.hex由assets/touch_calibration.json生成；默认中心是商家参考估算，必须实物标定。
matrix_keypad：触摸onehot和旧4x4扫描合并；前12键演奏，S13/S14选音色，S15/S16菜单/组合测试。
8线薄膜矩阵可保留一块作菜单/组合键备用；另一种同为R/C接点的矩阵可替换，不必同时占两套GPIO。
G/V/S触摸只有一条编码模拟线，按单键使用，不承诺任意多键和弦；和弦交给MIDI。

4. MIDI
midi_uart_rx：T8输入，31250、8N1，专用串口，独立于T13/M11的115200调试。
midi_keyboard：CH1主旋律，0..127音符，32路持键，运行状态、实时字节交错、FIFO背压。
NoteOn力度0作为NoteOff；CC64延音；PC0/1切长笛/拨弦；CC7音量；PitchBend音高；CC1约6Hz颤音。
CH10：35/36底鼓、38/40军鼓。键盘需在Control Center配置实际发送通道和CC，不假设出厂一致。
CC123仅释放MIDI；CH1的CC120、FC/FF、已启用FE后的350ms断流、帧错/溢出触发全局清音。
FE只在首次收到后启用；没有FE时长按不会因无后续消息而超时。
BMV51M001以3.3V供电，BMCOM 3脚RX为接收路径输出到T8，2脚TX只收时悬空。
键盘USB-C独立5V供电；Type A TRS MIDI OUT -> DIN5公 -> BMV MIDI IN；本方案不实现USB Host。

5. 光电
optical_strum：P8/P9两束，同步/约1ms滤波；启动无遮挡200ms学习空闲极性。
A->B升序，B->A降序；配对窗150ms，速度决定力度与2/4/6/10ms逐音间隔。
单束超时一次回退（150ms等待、力度160、间隔8ms）；长遮挡不重复，双束恢复后才重新允许。
strum_player：快照MIDI held图，最多6音；无和弦用60/64/67/72；固定拨弦音色。
valid/ready保证事件背压不丢松键；新手势先释放旧光弦，压制/清音取消旧队列，不在退出时重放。

6. 共享声部与表达
voice_allocator：SOURCE_TAG_ENABLE后按音符+来源释放，0本地/1MIDI/2光弦；相同C4可以分别持有。
总声部32，满载按既有窃音策略分配；不是每种输入独占32声部。
音量与音高：首个MIDI值可接管，以后最近数值变化来源拥有；移动实体滑杆可夺回，重复相同MIDI值不夺回。
CC1颤音加在当前音高控制上，CC1=0撤销；测试模式屏蔽外来演奏/表达，恢复需要新输入。
数字零上升沿清全来源音频状态，取消光弦；期间拒收，退出需松键重按或新扫动。

7. 音频与相位RAM
wavetable_synth：Fs=93750，32声部时分复用。双音色半波表和既有ADSR/混音仍在。
PHASE_RAM=1把32x24位相位放同步片内RAM；phase_valid掩码复位，RAM本体不异步清零。
fs_tick优先读voice0并阻止旧slot0写回；slot7预读下一个voice，解决同步RAM延迟与残留相位。
模块默认PHASE_RAM=0兼容旧测试/调用，根top显式选1。不要单改读写拍或把valid掩码去掉。
4种参数组合共9,206,880周期逐拍对照；3项故意破坏对照可检测关键错误。冻结参考PnR寄存器减少735。
最终资源：Logic18141/20736，Register7659/16173，CLS9999/10368，BSRAM9/46，DSP12.25/24。
Setup/Hold均0；clk27 Fmax29.381MHz，pixel25_2 Fmax26.476MHz。CLS占96.44%，后续功能仍应共享算术/顺序扫描。

8. 显示与诊断
instrument_telemetry：合并performance_keys，增加7bit外部代表音符；0..127均有音高表。
HDMI只保留原12键高亮范围，其外音符通过代表音符显示；四位频率最大显示9999，raw frequency_hz仍16bit。
remote_debug_link：旧08演奏控制协议保持，09为只读诊断/中心写入。09查询/标定不接管演奏，不刷新远程接管看门狗。
09 diag0触摸raw、diag1触摸keys、diag2状态、diag3采样序号；写中心ACK回显索引/值并带A100|index标记。
diag2 bit0触摸有效，1触摸fault，2MIDI见数据/持键，3帧错，4/5遮挡A/B，6溢出，7光弦就绪，8播放busy。
tools/input_monitor.py只查询；tools/touch_calibrate.py负责逐键采集、检查和运行时写入。
运行时标定复位即恢复hex；主机JSON/HEX只是文件保存，持久化须更新工程并重新编译新版本。

9. 构建与证据
从“工程”目录：python scripts/build.py。需要本机Gowin安装，tools/vendor为离线Icarus。
验证入口：scripts/run_midi_tests.py、run_optical_tests.py、run_touch_unit_tests.py、run_iverilog_tests.py。
Python协议/工具测试位于tests/Python。acceptance/build_summary/build_input_hashes记录固件与源码对应。
validation/phase_ram_candidate含冻结参考/证明脚本，原执行路径保留在历史报告中，不代表发布工程仍依赖该路径。
未执行任何板级下载；Gowin提示既有TMDS位宽及触摸中心异步置位/复位，日志留存，实物复位/标定须核对。
''')
    write('docs/AI快速上手_V019.txt','''
V019 AI快速上手 | 2026-10-24

先读V019_项目架构与模块说明.txt与V019_MIDI与光电接线测试.html。
项目根为版本目录的“工程”，顶层src/top.v；Gowin工程instrument_handoff.gprj，器件保持GW2A-18C。
固件UserCode 0x00005D02；构建/时序/离线测试已过，未烧录，硬件结果不能推断。
不改线序：MCP T6/P6/R8/T7；MIDI T8；光A P8/光B P9；矩阵/ADS/耳机均沿用。
GVS模拟触摸需S-10k-CH0-10k-GND，MCP模块3V3供电，5V–18V端悬空，默认中心必须逐键标定。

关键模块：
instrument_inputs.v连接旧本地、触摸与performance_input_hub.v；后者连接midi_keyboard.v与optical_strum.v/strum_player.v。
midi_uart_rx.v做31250串口；midi_keyboard含状态/延音/通道过滤/FIFO与panic。
voice_allocator.v以source+note释放；instrument_audio.v传来源；不能只按note释放。
wavetable_synth.v PHASE_RAM1为同步相位RAM，valid掩码复位，slot7预读，tick抢占旧写；根top启用，模块默认0兼容。
top.v HDMI/telemetry/跟弹用performance_keys；超出12键范围有external_note代表，Hz四位显示饱和9999。
remote_debug_link.v原08协议不变，09诊断不接管；CALIB_ENABLE由TOUCH_ENABLE控制，纯MIDI查询不能伪写标定。

必须保持：2种主旋律/32共享独立声部；压力双鼓、滑杆、PT8211右对齐3.5mm、四页中文HDMI、曲库与32频验证。
当前TINY+映射：CH1旋律、PC0/1、CC7音量、Bend音高、CC1颤音、CC64延音；CH10 35/36底鼓、38/40军鼓。
FC/FF与CH1 CC120全局清音，CC123仅MIDI；FE收到后才启用350ms断流监控。
实体滑杆与MIDI最近数值变化接管，重复同值不夺回；清音/零模式/接管必须取消旧光弦并清活动声部。
数字零退出不重放旧持键，需松开重按；测试所有权中输入与表达不得污染32频验证。
SEN0503两套：启动200ms无遮挡学习，1ms滤波，150ms配对/单束回退，方向/快慢驱动拨弦，held和弦最多6音。
GVS只有单模拟编码，不能承诺多键；旧8线矩阵保留菜单/组合，另一块膜键盘无需同时接。

复验建议按改动范围选，不必无变化反复跑：
python scripts/run_midi_tests.py
python scripts/run_optical_tests.py
python scripts/run_touch_unit_tests.py
python scripts/run_iverilog_tests.py --tests tb_midi_audio_integration tb_optical_audio_integration tb_touch_integration tb_midi_expression_controls tb_digital_zero_source_release tb_midi_telemetry_range tb_note_table_midi_range --jobs 4 --timeout 900 --output validation/recheck
python -m unittest discover -s tests/Python -p test_touch_calibrate.py
python -m unittest discover -s tests/Python -p test_input_monitor.py
python scripts/build.py
python scripts/summarize_build.py
相位RAM改动先进入validation/phase_ram_candidate复跑逐拍/负例，不能仅靠听感判断。

资料索引：assets/midi_tiny_mapping.json是工程合同，不是键盘配置文件。
验证汇总见发布目录“验证/acceptance.json”，源哈希和FS SHA需对应；旧并行草稿只作历史，最终docs_final_followup/审查PASS优先。
资源：CLS9999/10368（96.44%），仍拥挤；新增功能先估算，避免大组合表或多路重复算术。
标定工具只运行时写中心；保存的JSON/HEX不等于FPGA断电保留，要重新编译发布。
尚待用户接线后做供电/极性/原始MIDI字节/声音/HDMI/真实延迟测试，不编造板级完成状态。
''')
    report={'status':'PASS','scope':'final documentation and source-contract reconciliation; hardware not tested',
        'resolved':['CH10 35/36 kick and 38/40 snare documented','FC global panic documented','CC120 primary-channel trigger with global effect documented','same-value ownership tested','panic cancels old strum tested','digital-zero rise clears all voices and rejects stale replay tested','HDMI receives merged keys confirmed'],
        'visual_qa':{'svg_rendered_and_viewed':True,'preview':'midi_optical_wiring_preview.png','result':'readable labels, arrow directions, power rails and pin names verified'},
        'evidence':['midi_agent.json','optical_agent.json','midi_optical_integration_review.json','host_input_tests.json','build_summary.json'],
        'final_hashes':{n:hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in ['docs/V019_MIDI与光电接线测试.html','docs/MIDI与双光束接线.svg','assets/midi_tiny_mapping.json','docs/V019_项目架构与模块说明.txt','docs/AI快速上手_V019.txt']}}
    write('validation/docs_final_followup.json',json.dumps(report,ensure_ascii=False,indent=2))
    print('FINAL_DOCS_PASS')

if __name__=='__main__':main()
