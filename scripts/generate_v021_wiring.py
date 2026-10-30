"""V021专职电容屏控接线图：同一绘图指令生成矢量SVG与可打印PDF。"""
from pathlib import Path
import html,json,re
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.colors import HexColor
from reportlab.lib.pagesizes import A4,landscape

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'docs/V021_接线图'
OUT.mkdir(parents=True,exist_ok=True)
W,H=1600,1130
PAGE_COUNT=9
DOC_REVISION='2026-10-30 R3：实测确认BMV51M001中间实物TX脚接T8；MIDI接收通过'
# 同本次用户照片：RGB LCD在上、Sipeed标志在下，板背面朝向观察者。
# J6编号采用官方原理图的Conn_02x06_Odd_Even，不能当作转接板1~8。
# 原理图+3709官方PCB焊盘位置交叉核对；照片右下3V3为方形1号焊盘。
PMOD2_BACK=[
 [('E15',12,'ADS SDA'),('A15',10,'I2S LRCK'),('A14',8,'空闲'),('C12',6,'空闲'),('GND',4,'公共地'),('3V3',2,'3.3V')],
 [('D14',11,'ADS SCL'),('B14',9,'I2S BCK'),('B13',7,'I2S DIN'),('B12',5,'空闲'),('GND',3,'公共地'),('3V3',1,'3.3V')],
]
PMOD2_SOURCE='https://dl.sipeed.com/fileList/TANG/Primer_20K/02_Schematic/Tang_Primer_20K_Dock-3713_Schematics.pdf'
PMOD2_PCB_SOURCE='https://dl.sipeed.com/fileList/TANG/Primer_20K/03_Bit_number_map/Dock/Tang_Primer_20K_Dock_3709_ibom.html'
FONT='WiringChinese'
pdfmetrics.registerFont(TTFont(FONT,r'C:\Windows\Fonts\simhei.ttf'))
C={'ink':'#17364b','muted':'#526675','line':'#b8ccd7','bg':'#f3f7fa',
   'power':'#c43943','gnd':'#465664','digital':'#126d96','analog':'#8b42a4','warn':'#9b6108'}
NETS=[
 ['FPGA','T6 / touch_sclk','MCP3208 CLK','SPI时钟，3.3V'],
 ['FPGA','P6 / touch_mosi','MCP3208 DIN','SPI主机输出'],
 ['FPGA','R8 / touch_miso','MCP3208 OUT','SPI主机输入'],
 ['FPGA','T7 / touch_cs_n','MCP3208 CS','低有效片选'],
 ['公共电源','3V3','MCP3208 3.3V','仅用用户指定的3.3V供电口'],
 ['公共地','GND','MCP3208 G','不接板上5V-18V端子'],
 ['触摸板','V / G','3V3 / GND','G/V/S三线模拟编码，不是8线矩阵'],
 ['触摸板','S','10k串联后节点 -> MCP CH0','该节点另接10k到GND；首次逐键标定'],
 ['FPGA','T8 / midi_rx','BMV51M001 中间脚 TX（实物丝印）','31250bps接收实测通过；见第9页'],
 ['公共电源','3V3 / GND','BMV实物 VDD / GND','NC、RX留空；不套用资料针脚名称'],
 ['MIDI键盘','MIDI OUT','Type A TRS3.5 -> DIN5公 -> BMV MIDI IN','Tip->DIN5、Ring->DIN4、Sleeve->DIN2'],
 ['MIDI键盘','USB','独立USB 5V电源','此线供电，不依赖FPGA USB Host'],
 ['SP-2','6.35mm插头','键盘 SUSTAIN','松开脚踏后上电，测试CC64方向'],
 ['FPGA','P8 / optical_beams[0]','光束A接收端白OUT','独立10k上拉到3V3'],
 ['FPGA','P9 / optical_beams[1]','光束B接收端白OUT','另一个10k上拉到3V3'],
 ['两对光束','四个端头红线 / 黑线','3V3 / GND','每对1发射+1接收；白OUT只在接收端'],
 ['FPGA','D14 / adc_scl','ADS1115 SCL','I2C上拉仅到3V3'],
 ['FPGA','E15 / adc_sda','ADS1115 SDA','I2C上拉仅到3V3'],
 ['ADS1115','VDD / GND / ADDR','3V3 / GND / GND','地址0x48，ALRT留空'],
 ['FSR602 #1','一端 / 另一端','3V3 / ADS A0节点','A0节点另接10k到GND；明亮度'],
 ['FSR602 #2','一端 / 另一端','3V3 / ADS A1节点','A1节点另接10k到GND；拨弦阻尼'],
 ['滑杆 #1','VCC / GND / OTA','3V3 / GND / ADS A2','仅使用一组三针；另一组全留空'],
 ['ADS1115','A3','GND','音高滑杆停用，不参与弯音仲裁'],
 ['FPGA','B14 / amp_bck','PCM5102A BCK','标准I2S位时钟，3MHz'],
 ['FPGA','A15 / amp_lrc','PCM5102A LCK / LRCK','采样率93.75kHz，32fs/16位双声道'],
 ['FPGA','B13 / amp_din','PCM5102A DIN','串行音频数据'],
 ['公共地','GND','PCM5102A GND','与FPGA共地'],
 ['PCM供电','核对模块额定输入后供电','PCM5102A VIN','确认支持5V输入才接5V；不从GPIO供电'],
 ['PCM配置','SCK / FMT','GND / GND','内部PLL / 标准I2S；核对背面焊桥'],
 ['PCM配置','XSMT','3.3V','解除静音；不是接VIN的5V'],
 ['PCM配置','DEMP / FLT','GND / GND','关闭去加重、普通延迟滤波'],
 ['PCM配置','A3V3','留空','不与VIN同时接两路电源，不接5V'],
 ['PCM模拟输出','LINE OUT 3.5mm','有源音箱/耳放 LINE IN','普通耳机仍可用Dock耳机孔'],
 ['Dock','板载3.5mm','耳机','PT8211通路与外接I2S并行保留'],
 ['Dock','HDMI','屏幕HDMI IN','显示屏USB单独供电，不启用触控'],
 ['USB调试','板载JTAG/UART USB','电脑','下载/触摸标定；本版不接ESP32'],
 ['已撤除','八线矩阵全部八根线','不连接','PMOD1八个信号空闲；第二滑杆不接'],
]
KEYS=[('1','S1','上一项'),('2','S2','下一项'),('3','S3','确认'),('A','S4','返回'),
 ('4','S5','前一屏'),('5','S6','后一屏'),('6','S7','播放/暂停'),('B','S8','重启曲目'),
 ('7','S9','长笛'),('8','S10','拨弦'),('9','S11','键盘/扫弦'),('C','S12','切换FX'),
 ('*','S13','紧急静音'),('0','S14','滤波/零PCM'),('#','S15','长按32测试'),('D','S16','退出/返回')]

class Sheet:
 def __init__(self,pdf,title,page):
  self.pdf=pdf;self.svg=[];self.title=title
  self.rect(0,0,W,H,fill=C['bg'],stroke=None)
  self.rect(0,0,W,115,fill=C['ink'],stroke=None)
  self.text(40,60,title,34,fill='#ffffff')
  self.text(40,98,'V021 | MIDI主奏 / 电容键盘专职屏控 | 北京时间2026-10-30',21,fill='#ffffff')
  self.text(40,H-26,'部分链路已实测；整机电气/声学验收未完成，详见版本记录。',18,fill=C['muted'])
  self.text(W-160,H-26,f'{page} / {PAGE_COUNT}',18,fill=C['muted'])
 def rect(self,x,y,w,h,fill='#ffffff',stroke=C['line'],radius=10):
  self.svg.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill or "none"}" stroke="{stroke or "none"}" stroke-width="2"/>')
  p=self.pdf;p.setFillColor(HexColor(fill or '#ffffff'));p.setStrokeColor(HexColor(stroke or fill or '#ffffff'))
  p.roundRect(x,H-y-h,w,h,radius,fill=int(fill is not None),stroke=int(stroke is not None))
 def text(self,x,y,text,size=24,fill=C['ink']):
  for i,line in enumerate(text.split('\n')):
   yy=y+i*(size+10)
   self.svg.append(f'<text x="{x}" y="{yy}" font-family="Microsoft YaHei,Noto Sans CJK SC,sans-serif" font-size="{size}" fill="{fill}">{html.escape(line)}</text>')
   self.pdf.setFont(FONT,size);self.pdf.setFillColor(HexColor(fill));self.pdf.drawString(x,H-yy,line)
 def line(self,x1,y1,x2,y2,color=C['digital'],width=4):
  self.svg.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{width}"/>')
  self.pdf.setLineWidth(width);self.pdf.setStrokeColor(HexColor(color));self.pdf.line(x1,H-y1,x2,H-y2)
 def dot(self,x,y,color=C['digital']):
  self.svg.append(f'<circle cx="{x}" cy="{y}" r="6" fill="{color}"/>')
  self.pdf.setFillColor(HexColor(color));self.pdf.circle(x,H-y,6,fill=1,stroke=0)
 def box(self,x,y,w,h,title,lines):
  self.rect(x,y,w,h);self.text(x+20,y+38,title,27)
  self.text(x+20,y+78,lines,22,fill=C['muted'])
 def resistor(self,x,y,label,color=C['analog']):
  self.rect(x-27,y,54,80,fill='#ffffff',stroke=color,radius=0);self.text(x+42,y+49,label,24,fill=color)
 def ground(self,x,y):
  self.line(x,y-20,x,y,C['gnd']);
  for d,half in [(0,24),(10,16),(20,8)]:self.line(x-half,y+d,x+half,y+d,C['gnd'],3)
 def save_svg(self,name):
  value=f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">'+''.join(self.svg)+'</svg>'
  (OUT/name).write_text(value,encoding='utf-8');return value

pdfpath=OUT/'V021_完整接线图.pdf'
p=canvas.Canvas(str(pdfpath),pagesize=landscape(A4));p.setTitle('V021 MIDI主奏与电容屏控完整接线图')
svgs=[]
def begin(title,n):p.saveState();p.scale(landscape(A4)[0]/W,landscape(A4)[1]/H);return Sheet(p,title,n)
def end(s,name):svgs.append((s.title,s.save_svg(name)));p.restoreState();p.showPage()

s=begin('01  完整系统总览',1)
for y,title,lines in [(160,'MIDI键盘 + SP-2','琴键/力度/摇杆/四旋钮/四Pad\nTRS MIDI OUT -> 隔离接收板'),
 (350,'G/V/S电容触摸键盘','S经10k+10k分压 -> MCP3208 CH0\n只控制屏幕，不发送音符'),
 (540,'双FSR602 + ADS1115','A0明亮度 / A1拨弦阻尼\n独立10k分压下拉'),
 (730,'一条音量滑杆','OTA -> ADS1115 A2\n另一音高滑杆停用'),
 (920,'两对SEN0503','两接收端OUT -> P8 / P9\n方向、速度及扫弦触发')]:
 s.box(40,y,480,150,title,lines);s.line(520,y+75,610,y+75)
s.box(610,170,410,845,'Tang Primer 20K','MIDI / 参数映射 / 模式\n\n触摸屏控 / 单键诊断\n\n32独立声部 + 可调ADSR\n\n旋律 + 四种打击乐混音\n\n压力表情 / 光束扫弦\n\nDelay / Chorus / Reverb\n\n标准I2S + 板载耳机\n\nHDMI波形与节奏教学')
s.box(1110,190,450,245,'PCM5102A','B14 -> BCK / A15 -> LCK\nB13 -> DIN / GND共地\nLINE OUT -> 有源音箱/耳放\nVIN和焊桥按第4页核对')
s.box(1110,510,450,180,'板载3.5mm','PT8211耳机通路保留\n不需要外接MAX98357')
s.box(1110,755,450,180,'HDMI显示屏','HDMI线 -> 屏幕HDMI IN\nUSB只供电，屏幕触控不启用')
for y in (310,590,840):s.line(1020,y,1110,y)
s.text(1090,1005,'ESP32 / 手机：本版不连接',23,fill=C['warn'])
end(s,'01_完整系统.svg')

s=begin('02  PMOD0：MIDI、触摸ADC与双光束',2)
s.text(50,155,'下表为按球号整理的功能表，不代表实物针脚方向；PMOD2实物定位见第8页。',22)
rows=[('T6','P6','MCP CLK','MCP DIN'),('R8','T7','MCP OUT','MCP CS'),
 ('T8','P8','MIDI RX','光束A OUT'),('P9','T9','光束B OUT','空闲'),('GND','GND','公共地','公共地'),('3V3','3V3','3.3V','3.3V')]
s.rect(50,190,530,690)
for i,(a,b,an,bn) in enumerate(rows):
 y=225+i*106
 for x,ball,label in [(85,a,an),(335,b,bn)]:
  s.rect(x,y,205,88,fill='#edf4f8');s.text(x+12,y+34,ball,27);s.text(x+12,y+68,label,21)
s.box(650,190,890,230,'MCP3208模块的数字侧','CLK <- T6    DIN <- P6    OUT -> R8    CS <- T7\n3.3V <- 板3V3；G <- 公共GND\n不用板上5V-18V端子；本版只采CH0触摸，不采FSR')
s.box(650,455,890,390,'G/V/S触摸板模拟侧','V -> 3V3；G -> GND；S按下图分压\n无二极管的8线矩阵和G/V/S不是同一种接法')
s.text(690,625,'触摸 S',26);s.line(810,616,900,616,C['analog']);s.rect(900,590,110,52,stroke=C['analog'],radius=0);s.text(922,625,'10k',24,fill=C['analog']);s.line(1010,616,1190,616,C['analog']);s.dot(1135,616,C['analog']);s.text(1200,625,'MCP CH0',26,fill=C['analog']);s.line(1135,616,1135,675,C['analog']);s.resistor(1135,675,'10k');s.line(1135,755,1135,785,C['gnd']);s.ground(1135,785)
s.text(650,915,'SPI：500kHz / 24位；触摸采样5k次/s；实际16键需逐键标定。',22)
s.text(650,960,'MCP CH1~CH7不接本版外设，可按模块要求固定未用模拟输入。',21,fill=C['muted'])
s.text(50,1035,'PMOD1原矩阵八根线全部移除：T11/P11、T12/R11、M14/M15、J14/J16均空闲。',22,fill=C['warn'])
end(s,'02_PMOD0与电容触摸.svg')

s=begin('03  ADS1115：双压力表情 + 一条总音量滑杆',3)
for x,title,ch,role in [(45,'FSR602 #1','A0','明亮度'),(555,'FSR602 #2','A1','拨弦阻尼 / 闷音')]:
 s.box(x,165,480,690,title,role+'；FSR两端无极性')
 xx=x+150;s.text(xx-40,305,'3V3',27,fill=C['power']);s.line(xx,325,xx,370,C['power']);s.resistor(xx,370,'FSR602')
 s.line(xx,450,xx,500,C['analog']);s.dot(xx,500,C['analog']);s.line(xx,500,x+390,500,C['analog']);s.text(x+330,475,'ADS '+ch,25,fill=C['analog']);s.line(xx,500,xx,560,C['analog']);s.resistor(xx,560,'10k');s.line(xx,640,xx,710,C['gnd']);s.ground(xx,710)
 s.text(x+25,800,'按压改变ADC电压；不是直接输入kg。',20,fill=C['muted'])
s.box(1065,165,490,690,'HW-233 滑杆 #1','只使用OTA这一组三针')
for y,pin,target,color in [(340,'OTA','ADS A2',C['analog']),(425,'VCC','3V3',C['power']),(510,'GND','GND',C['gnd'])]:
 s.text(1095,y,pin,29);s.line(1190,y-8,1310,y-8,color);s.text(1330,y,target,27,fill=color)
s.text(1100,620,'OTB / VCC / GND',25,fill=C['muted']);s.text(1100,665,'另一组三针全部留空',24,fill=C['warn']);s.text(1100,725,'滑杆 #2停用，不再控制音高',23,fill=C['warn'])
s.box(45,895,1510,145,'ADS1115公共连接','VDD -> 3V3；GND / ADDR -> GND；SCL -> D14；SDA -> E15\nALRT留空；A3接GND。本版FSR仍接ADS，未迁移到MCP。I2C上拉仅到3V3。')
end(s,'03_FSR与音量滑杆.svg')

s=begin('04  标准I2S直连PCM5102A，板载耳机并行保留',4)
s.box(55,170,485,390,'FPGA / PMOD2 信号','B14 / amp_bck\n\nA15 / amp_lrc\n\nB13 / amp_din')
s.box(805,170,740,390,'PCM5102A模块（按丝印接）','BCK\n\nLCK / LRCK\n\nDIN')
for y,label in [(248,'BCK = 3MHz'),(312,'LRCK = 93.75kHz'),(376,'DIN = 16bit I2S')]:
 s.line(540,y,795,y);s.text(565,y-17,label,21)
s.text(80,530,'所有数字信号为3.3V逻辑；图中为逻辑连接，不表示排针的实际间距。',21)
s.box(55,605,700,300,'供电与配置','GND -> 公共GND；XSMT -> 3.3V\nSCK / FMT -> GND（内部PLL / 标准I2S）\nDEMP / FLT -> GND；A3V3留空\nVIN：仅在确认模块支持后接额定电源\n不要把XSMT接到VIN的5V')
s.box(805,605,740,300,'模拟输出和可选外放','PCM LINE OUT -> 有源音箱或耳放LINE IN\n普通耳机可继续接Dock板载3.5mm\nMAX98357是可选I2S接收端，可与DAC并联输入\n它不串联在FPGA和PCM之间；OUT+/-只接喇叭\nMAX的VIN/SD与扬声器规格需按模块单独核对')
s.text(65,975,'I2S模式需核对背面FMT焊桥；不能把仍焊到高电平的同一引脚直接强接GND。',23,fill=C['warn'])
s.text(65,1025,'本版新.fs包含标准I2S；旧instrument_v020.fs不包含。耳机模拟地噪声仍需实测。',22,fill=C['muted'])
s.text(65,590,'定位见第8页：B14在照片丝印第2行、第2列，位于A15下方。',23,fill=C['warn'])
end(s,'04_I2S与耳机.svg')

s=begin('05  电容键盘专职屏控：每个键的功能',5)
s.text(55,165,'逻辑S1~S16按1,2,3,A / 4,5,6,B / 7,8,9,C / *,0,#,D排列；先逐键标定。',23)
for i,(printed,logic,role) in enumerate(KEYS):
 x=55+(i%4)*380;y=205+(i//4)*165
 s.rect(x,y,350,145,fill='#ffffff');s.text(x+18,y+42,printed+'  /  '+logic,28);s.text(x+18,y+93,role,26)
s.box(55,900,725,145,'普通屏幕操作','S1/S2选项目，S3确认；S5/S6切四个HDMI页\n主界面可选MAIN / ADSR / FX旋钮控制页')
s.box(815,900,730,145,'诊断与安全操作','S15单键长按2s入测试；S16退出；S13始终Panic\n测试中S1~S6 = 1/4/8/16/32/逐路OFF-ON')
s.text(65,875,'S14短按切滤波；长按约1.2s切数字零。所有触摸键均不产生旋律或鼓音符。',22,fill=C['warn'])
end(s,'05_触摸屏控键位.svg')

for n,chunk in enumerate([NETS[:21],NETS[21:]],6):
 s=begin('06  逐根线表（前半）' if n==6 else '07  逐根线表（后半）与上电顺序',n)
 x=[40,220,560,1120];width=[180,340,560,440]
 for i,h in enumerate(['设备','源端','连接到','说明']):
  s.rect(x[i],150,width[i],44,fill='#e3edf3',radius=0);s.text(x[i]+10,181,h,23)
 for row,entry in enumerate(chunk):
  y=198+row*38
  if row%2==0:s.rect(40,y,1520,37,fill='#ffffff',stroke=None,radius=0)
  for i,cell in enumerate(entry):
   # 表格按列自动缩字号到最小14，避免汉字越界；图页上保留较大字号。
   size=19
   while pdfmetrics.stringWidth(cell,FONT,size)>width[i]-16 and size>14:size-=1
   if pdfmetrics.stringWidth(cell,FONT,size)>width[i]-16:
    # 长说明分两行，表格行高不变时两行用14号；不截断任何接线内容。
    mid=max(1,int(len(cell)*(width[i]-20)/max(1,pdfmetrics.stringWidth(cell,FONT,14))))
    s.text(x[i]+8,y+14,cell[:mid],14);s.text(x[i]+8,y+30,cell[mid:],14)
   else:s.text(x[i]+8,y+26,cell,size)
 if n==7:
  s.box(45,895,1510,145,'首次验证顺序','断电改线 -> 烧录配套V021 -> USB触摸标定 -> 16键菜单无误发声 -> MIDI/压力/扫弦 -> 32频模式\nPCM VIN/背面焊桥确认后再上电；键盘和屏幕各自USB供电，模块只共信号地，不并联不同稳压器输出。')
 end(s,'06_逐线表.svg' if n==6 else '07_逐线表与验证.svg')

s=begin('08  PMOD2实物定位：B14在A15下方',8)
s.text(55,160,'背面焊点视图：和本次照片同方向。RGB LCD文字在上，Sipeed标志在下。',24)
s.text(55,203,'左侧邻居为PMOD1 / DVP；右侧邻居为PMOD3 / RGB LCD。共6列，每列上下2针。',22)
for col in range(6):
 s.text(100+col*247,250,f'第{col+1}列',22,fill=C['muted'])
for row,cells in enumerate(PMOD2_BACK):
 for col,(ball,pad,role) in enumerate(cells):
  x=55+col*247;y=280+row*150
  color=C['warn'] if ball=='B14' else C['gnd'] if ball=='GND' else C['power'] if ball=='3V3' else C['digital']
  s.rect(x,y,225,130,fill='#fff0d8' if ball=='B14' else '#ffffff',stroke=color)
  # 方形标记是PCB本体J6.1，不把转接头的印字当作板上球号。
  if pad==1:s.rect(x+15,y+16,16,16,fill=color,stroke=None,radius=0)
  else:s.dot(x+23,y+24,color)
  s.text(x+45,y+42,ball,31,fill=color)
  s.text(x+15,y+82,role,23,fill=color)
  s.text(x+15,y+112,f'J6.{pad} 焊盘',19,fill=C['muted'])
s.text(55,600,'注意：原照片把两行球号集中印在焊点下方；上图已把球号放回对应焊点位置。',22)
s.text(55,643,'B14 = 第2列下针；A15 = 第2列上针；B13 = 第3列下针。（仅限本页背面方向）',23,fill=C['warn'])
s.box(55,690,725,250,'PCM5102A逐线连接','B14 / J6.9 -> BCK\nA15 / J6.10 -> LCK / LRCK\nB13 / J6.7 -> DIN\nGND -> GND；VIN按第4页核对额定输入')
s.box(815,690,730,250,'正面与PMOD转接头','本页不是正面插线视图；翻板后需重新定位。\n转接板1~8标签不等于B14/A15等FPGA球号。\n先按断电通断测试确认转接板对应关系。\n当前固件球号不变，无需为这次文档修订重烧。')
s.text(55,980,'核对依据：用户本次照片 + Sipeed官方3713原理图第1、4页 + 官方3709 PCB焊盘位置。',20,fill=C['muted'])
s.text(55,1022,'J6.x是原理图连接器焊盘号，与商品PMOD接口1~12或1~8标号不可直接混用。',21,fill=C['muted'])
end(s,'08_PMOD2背面定位.svg')

s=begin('09  MIDI实物勘误：RX/TX与官方资料相反',9)
s.text(55,165,'型号已由用户照片确认：BEST MODULES BMV51M001，PCB V1.0。',25)
s.text(55,210,'以下顺序只按背面照片：型号文字在下方，五针位于右侧，从NC端开始数。',22)
for i,(label,role) in enumerate([
 ('NC','留空'),('RX','留空；本项目不向模块发送MIDI'),
 ('TX','中间脚 -> FPGA T8；已收到有效MIDI'),
 ('VDD','3.3V'),('GND','公共GND')]):
 y=270+i*92
 color=C['warn'] if label=='TX' else C['power'] if label=='VDD' else C['gnd'] if label=='GND' else C['digital']
 s.rect(65,y,145,68,stroke=color)
 s.text(90,y+44,label,30,fill=color)
 s.text(245,y+44,role,26,fill=color)
s.box(55,760,725,255,'实物和资料差异：已做接收验证','照片丝印：NC、RX、TX、VDD、GND。\n官方表格：NC、TX、RX、VDD、GND。\n先前接实物RX：连续弹键45秒，T8无字节/跳变。\n改接实物TX：45秒收到3459字节，帧错误0。\nNote On 41次、Note Off 40次，末次快照仍有按键。')
s.box(815,760,730,255,'现行接法与验证边界','键盘MIDI OUT -> 模块MIDI IN（照片已插IN）。\n断电改线；中间实物TX接T8，VDD接3.3V、GND共地。\nNC、另一根RX留空；不要按杜邦线颜色辨认电源。\nV022诊断结束已恢复V021，UserCode 0x0000976F。\n已确认输入链路；声音、PCM与旋钮映射仍需分别验收。')
s.text(55,1055,'依据：用户2026-10-30两张实物照片；厂家使用手册/原理图。旧“第3脚RX”不适用于本实物丝印。',19,fill=C['warn'])
end(s,'09_MIDI实物RX_TX勘误.svg')
assert len(svgs)==PAGE_COUNT
p.save()

cst=(ROOT/'src/multi_tone.cst').read_text(encoding='utf-8-sig')
expected={'touch_sclk':'T6','touch_mosi':'P6','touch_miso':'R8','touch_cs_n':'T7','midi_rx':'T8',
 'optical_beams[0]':'P8','optical_beams[1]':'P9','adc_scl':'D14','adc_sda':'E15',
 'amp_bck':'B14','amp_lrc':'A15','amp_din':'B13'}
actual=dict(re.findall(r'IO_LOC\s+"([^\"]+)"\s+([A-Z]\d+)\s*;',cst))
assert all(actual.get(k)==v for k,v in expected.items()),'接线与CST不一致'
assert not any(k.startswith('matrix_') for k in actual),'仍存在矩阵约束'
payload={'version':'V021','date_beijing':'2026-10-30','nets':NETS,'touch_keys':KEYS,
 'pin_contract':expected,'matrix_removed':True,'phone_connected':False,'second_slider_connected':False,
 'power_boundary':'PCM VIN/背面焊桥须按实物确认；没有电气实测结论',
 'document_revision':DOC_REVISION,'firmware_pin_change':False,
 'pmod2_back_photo_view':PMOD2_BACK,'pmod2_orientation':'RGB LCD文字在上、Sipeed标志在下，背面朝向观察者',
 'pmod2_sources':[PMOD2_SOURCE,PMOD2_PCB_SOURCE]}
(OUT/'接线表.json').write_text(json.dumps(payload,ensure_ascii=False,indent=2),encoding='utf-8')
sections=''.join(f'<section id="p{i}"><h2>{html.escape(title)}</h2>{svg}</section>' for i,(title,svg) in enumerate(svgs,1))
nav=''.join(f'<a href="#p{i}">{i}. {html.escape(title[4:])}</a>' for i,(title,_) in enumerate(svgs,1))
document='''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>V021 完整接线图</title><style>body{margin:0;background:#eef3f7;color:#17364b;font:16px/1.7 "Microsoft YaHei",sans-serif}header,main{max-width:1400px;margin:auto;padding:20px}nav{display:flex;flex-wrap:wrap;gap:10px}a{color:#126d96}nav a{background:white;padding:5px 10px;border-radius:6px}section{background:white;margin:24px 0;padding:12px;border-radius:10px}h2{margin:5px 12px}svg{width:100%;height:auto;display:block}header p{margin:8px 0}@media print{header{display:none}main{padding:0}section{page-break-after:always;margin:0;padding:0}h2{display:none}}</style></head><body><header><h1>V021 完整接线图</h1><p>MIDI主奏，G/V/S电容键盘只控制HDMI；FSR明亮度/阻尼，保留一条音量滑杆，双光束扫弦。八线矩阵、第二滑杆、ESP32不连接。</p><p><a href="V021_完整接线图.pdf">可打印PDF</a> · <a href="接线表.json">逐根线数据</a></p><nav>'''+nav+'</nav></header><main>'+sections+'</main></body></html>'
notice='<p style="background:#fff0d8;padding:12px;border-radius:8px"><strong>'+DOC_REVISION+'</strong><br>MIDI：实物背面从NC端起为NC、RX、TX、VDD、GND，与官方表格名称相反。中间实物TX接T8，VDD接3.3V、GND共地，NC/RX留空。45秒实测收到3459字节、41次Note On、40次Note Off、0帧错误，已恢复V021。<a href="#p9">查看MIDI实物勘误与实测</a>。<br>B14确实存在，在PMOD2第二列下针、A15下方。<a href="#p8">查看PMOD2背面定位</a>。正面/转接头须重新定位。</p>'
refs='<details><summary>PMOD2核对依据</summary><p>用户2026-10-30实物照片；<a href="'+PMOD2_SOURCE+'">Sipeed官方3713原理图</a>（PDF第1页球号、第4页J6）；<a href="'+PMOD2_PCB_SOURCE+'">官方3709 PCB</a>（J6方形1号焊盘）。PCB为较早版本，只用于交叉核对与照片一致的孔位方向，不据此判断用户整板版本。</p></details>'
document=document.replace('<nav>',notice+refs+'<nav>',1)
(OUT/'完整接线图.html').write_text(document,encoding='utf-8')
(OUT/'接线核查.json').write_text(json.dumps({'pages':len(svgs),'fpga_pins_checked':len(expected),'matrix_constraints':False,'pdf':str(pdfpath),'physical_tested':False,'document_revision':DOC_REVISION,'firmware_pin_change':False,'pmod2_back_photo_view':PMOD2_BACK},ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps({'pdf':str(pdfpath),'pages':len(svgs),'nets':len(NETS),'pins_checked':len(expected)},ensure_ascii=True))
