"""打包独立实验版：核对本轮输入/产物和离线证据；绝不调用Programmer或ESP下载。"""
from pathlib import Path
from datetime import datetime,timezone,timedelta
import hashlib,html,json,shutil

ROOT=Path(__file__).resolve().parents[1]
STORE=ROOT.parent/'乐器版本'
OLD=ROOT.parent/'instrument_expression_20261024'
V021_SHA='c59627066feab3eddb85006bd4764232e00062b8eaa0fc3736806ffd53cefc53'
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def write(p,v):p.parent.mkdir(parents=True,exist_ok=True);p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def verify(base,items):
 for name,digest in items.items():assert sha(base/name).lower()==digest.lower(),('input changed',str(base/name))

def main():
 target=read(ROOT/'validation/release_destination.json');dest=Path(target['directory'])
 assert dest.parent.resolve()==STORE.resolve() and target['version']=='V023'
 catalog=read(STORE/'版本目录.json');entry=next(x for x in catalog['versions'] if x['folder']==dest.name)
 assert entry['number']==23 and target['alias'] in entry['aliases']
 # 生产V021源码和固件都须保持本轮开始时的字节，实验绝不覆盖旧版。
 baseline=read(ROOT/'validation/baseline_v021.json');verify(OLD,baseline['source_hashes'])
 prod=next(x for x in catalog['versions'] if x['number']==21)
 prod_fs=STORE/prod['folder']/'instrument_v021.fs';assert sha(prod_fs)==V021_SHA
 build=read(ROOT/'validation/build_summary.json')
 assert build['input_hashes_verified'] and not any(build['timing_violations'].values())
 assert build['fmax_mhz']['clk27']>=27 and build['fmax_mhz']['serial126']>=126 and build['fmax_mhz']['pixel25_2']>=25.2
 verify(ROOT,read(ROOT/'validation/build_input_hashes.json'))
 regression=read(ROOT/'validation/v023/summary.json')
 assert len(regression['cases'])==14 and all(x['passed'] for x in regression['cases']) and regression['source_hashes_match']
 verify(ROOT,regression['source_hashes'])
 review=read(ROOT/'validation/phone_review/results.json');assert not review['remaining_confirmed_fpga_blockers']
 bridge=read(ROOT/'esp32_phone/build/validation-result.json')
 assert bridge['native_tests_passed'] and bridge['web_tests_passed'] and bridge['compile']['compile_passed']
 verify(ROOT/'esp32_phone',bridge['compile']['source_sha256'])
 verify(ROOT/'esp32_phone/build',bridge['compile']['binary_sha256'])
 standalone=ROOT.parent/'调试工具/2026-10-30_V021_电容与光束测试'
 toolruns=list((standalone/'验证记录/交付包回归').glob('*/验证结果.json'))
 assert toolruns,'standalone peripheral validation report missing'
 # 校验工具报告和manifest另存；模拟/工具PASS始终不升级为物理PASS。
 toolreport=read(sorted(toolruns)[-1]);assert toolreport['all_passed'] and not toolreport['serial_opened'] and not toolreport['firmware_programmed']
 verify(standalone,{x['path']:x['sha256'] for x in read(standalone/'文件清单.json')['files']})
 fs=ROOT/'impl/pnr/instrument_handoff.fs';assert sha(fs)==build['firmware_sha256']
 firmware=dest/'instrument_v023_test.fs'
 if firmware.exists():assert sha(firmware)==sha(fs),'同版本固件不同，须新版本编号'
 shutil.copy2(fs,firmware)
 skip=shutil.ignore_patterns('__pycache__','*.pyc','*.vvp','*.tmp','*.obj','.git','.toolchain',
     'browser-profile','browser-temp','temp','_test_tmp')
 source=dest/'source';source.mkdir(exist_ok=True)
 for name in ('src','assets','scripts','tests','tools','docs','esp32_phone'):
  shutil.copytree(ROOT/name,source/name,dirs_exist_ok=True,ignore=skip)
 for name in ('instrument_handoff.gprj','build.tcl','device_config.json','README.txt'):
  shutil.copy2(ROOT/name,source/name)
 shutil.copytree(ROOT/'validation',dest/'验证',dirs_exist_ok=True,ignore=skip)
 # 源码中的说明页面保留可用的相对报告链接。
 write(source/'validation/build_summary.json',build)
 write(source/'validation/v023/summary.json',regression)
 shutil.copy2(standalone/'交付运行报告.md',dest/'验证/外设测试工具交付报告.md')
 shutil.copytree(standalone/'验证记录',dest/'验证/外设测试工具',dirs_exist_ok=True,ignore=skip)
 shutil.copy2(standalone/'先读我_使用说明.md',dest/'外设测试说明.md')
 # 根目录入口只启动PC只读工具，不下载固件。CMD先切换UTF8再读取中文路径。
 for label in ('电容','光束'):
  (dest/(label+'测试.cmd')).write_text('@echo off\nchcp 65001 >nul\ncall "%~dp0source\\tools\\peripheral_testbench\\'+label+'测试.cmd"\n',encoding='utf-8')
 now=datetime.now(timezone(timedelta(hours=8))).isoformat()
 changes=['独立ESP32 UART手机参数通信，支持实际状态ACK、JSON预设导入导出与Panic',
  '四旋钮跨全部页面固定为时间/反馈/调制/干湿，手机改值后重新软接管',
  '四Pad专职底鼓/闭镲/军鼓/开镲；保留两音色、32声部、FSR表情和双光束',
  '电容和光束PC测试工具兼容V021，逐步采集、校准与JSON/CSV报告',
  '光束诊断新增滤波电平能力位；手机静音回读包含FTDI zero',
  '手机重复绝对音量SET可重新取得控制权，保留CC7微抖/重复值及安全取消语义']
 limits=['本版未烧录FPGA或ESP32，实际手机/WiFi/UART/触摸/光束/听音待用户测试',
  '触摸中心仍为估算，须实测；运行时校准不持久保存到Flash',
  'PCM5102A实物无声问题未解决；数字I2S仿真通过不等于模拟输出已通过',
  '手机只做参数通信与JSON预设，不含音频录音/传输、任意曲谱导入',
  'test32/zero可屏蔽音量或音色SET；手机显示实际值和冲突，解除后需重发',
  'PC工具和手机网页截图使用软件模拟，不能计作硬件验收']
 info={'version':'V023','kind':'experimental_not_programmed','released_beijing':now,
  'development_project':str(ROOT),'baseline':'V021','changes':changes,'known_limits':limits,
  'firmware':firmware.name,'usercode':build['usercode'],'sha256':sha(firmware),
  'compile':'PASS','simulation':'PASS 14 selected RTL cases plus independent review and PC tests',
  'resources':build['resources'],'utilization_percent':build['utilization_percent'],
  'timing_violations':build['timing_violations'],'fmax_mhz':build['fmax_mhz'],
  'esp32_compile':'PASS','esp32_uploaded':False,'hardware_programmed':False,'physical_validation':False,
  'production_v021_unchanged':True,'baseline_source_hashes_verified':True,'on_board_firmware_from_prior_record':'V021',
  'external_tests_path':str(standalone),'phone_wiring':{'FPGA_RX_T11':'ESP32_TX_GPIO17','FPGA_TX_P11':'ESP32_RX_GPIO16','GND':'common','power':'separate USB; do not join 3V3 outputs'}}
 write(dest/'版本信息.json',info)
 notes='版本：V023（独立实验测试版）\n日期：'+now+'（北京时间）\n\n改动：\n'+'\n'.join('· '+x for x in changes)
 notes+='\n\n固件：'+firmware.name+'\nUserCode：'+info['usercode']+'\nSHA256：'+info['sha256']
 notes+='\nFPGA：本轮综合、布局布线和14项RTL回归通过；Setup/Hold违例0。\nESP32：已实际编译，原生协议/手机网页模拟测试通过。\n实际烧录：未执行；现有V021源码/固件字节已核对保持不变。\n资源：'+json.dumps(info['resources'],ensure_ascii=False)
 notes+='\n\n限制与待测：\n'+'\n'.join('· '+x for x in limits)+'\n\n先打开电容测试.cmd，随后光束测试.cmd，最后再考虑新版固件。\n'
 (dest/'版本说明.txt').write_text(notes,encoding='utf-8-sig')
 (dest/'验证/烧录记录.txt').write_text('V023：用户要求新版本暂不烧录。本轮未调用Programmer、未连接真实串口、未上传ESP32；所有新增输入/网页验收均为离线软件测试。\nV021先前已固化在SPI Flash，本轮没有覆盖或擦除。\n',encoding='utf-8-sig')
 page='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>V023 测试版入口</title><style>body{font:19px/1.8 'Microsoft YaHei',sans-serif;max-width:1080px;margin:40px auto;padding:20px;background:#f4f7fa;color:#173149}a{color:#006b9a}article{padding:25px;background:white;border-radius:15px;margin:20px 0}b{color:#9a4b05}</style><h1>V023｜独立实验测试版</h1><p><b>没有烧录FPGA或ESP32。先测试板上的V021，再决定何时试新版。</b></p><article><h2>醒来先做这两项</h2><ol><li><a href="电容测试.cmd">启动电容键盘测试</a>：空闲→按4→释放→按5→释放，必要时再做16键校准。</li><li><a href="光束测试.cmd">启动双光束测试</a>：两对TX/RX都供电，开机通光，再按引导遮挡A/B和恢复。</li></ol><p>诊断轮询会暂停触摸菜单。停止轮询后等1秒，全松再按4/5并抬手切页。</p><p><a href="外设测试说明.md">外设测试详细说明</a></p></article><article><h2>新版内容</h2><p>手机参数通信、四旋钮固定效果、四Pad鼓音，保留MIDI32声部和压力/双光束。</p><p><a href="source/docs/V023_使用与完整接线.html">新版使用说明与完整接线表</a></p><p><a href="source/esp32_phone/README.md">ESP32 / 手机部署说明</a></p><p><a href="instrument_v023_test.fs">V023测试固件（此轮未烧录）</a></p><p><a href="版本信息.json">版本信息</a> · <a href="验证/build_summary.json">实际资源及时序</a> · <a href="验证/v023/summary.json">RTL回归</a> · <a href="source/esp32_phone/build/validation-result.json">ESP32编译与测试</a></p></article></html>'''
 (dest/'版本入口.html').write_text(page,encoding='utf-8')
 # 更新目录，不更改任何历史条目的固件/验证状态。
 entry.update(status='实验版：编译/离线验证通过；未烧录，先测V021外设',firmware_names=[firmware.name],firmware=str(firmware),
  usercode=info['usercode'],sha256=info['sha256'],hardware_programmed=False,kind=info['kind'],resource_summary=info['resources'])
 write(STORE/'版本目录.json',catalog)
 (STORE/'版本总览.txt').write_text('乐器固件版本总览（状态以各版记录为准）\n\n'+'\n\n'.join(f"V{x['number']:03d} | {x.get('date','')} | {x.get('title','')}\n目录：{x['folder']}\n状态：{x.get('status','未记录')}" for x in catalog['versions'])+'\n',encoding='utf-8-sig')
 (STORE/'最新版本.txt').write_text('最新交付：V023（实验测试版，未烧录）\n目录：'+str(dest)+'\n入口：'+str(dest/'版本入口.html')+'\n固件：'+str(firmware)+'\nUserCode：'+info['usercode']+'\n板上仍保留此前固化的V021；醒来先测试电容与双光束，再测试V023。\n当前板载版本记录：'+str(STORE/'当前板载版本.txt')+'\n',encoding='utf-8-sig')
 (STORE/'当前板载版本.txt').write_text('此前实测固化版本：V021\n固件：'+str(prod_fs)+'\nSHA256：'+V021_SHA+'\nUserCode：0x0000976F\n先前Flash写入/校验及Flash重载已通过。本轮V023开发未连接串口、未烧录，不改变该版本。\n本记录沿用此前验证，当前不进行实时硬件检测。\n',encoding='utf-8-sig')
 manifest={str(p.relative_to(dest)):sha(p) for p in dest.rglob('*') if p.is_file() and p.name!='文件校验.json'}
 write(dest/'文件校验.json',manifest)
 assert sha(prod_fs)==V021_SHA
 print('V023_RELEASE_PASS',dest)

if __name__=='__main__':main()
