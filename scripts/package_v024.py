"""校验当前构建、回归和旧版本不变后交付V024；不访问任何板卡。"""
from pathlib import Path
from datetime import datetime,timezone,timedelta
import hashlib,html,json,shutil
ROOT=Path(__file__).resolve().parents[1]
STORE=ROOT.parent/'乐器版本'
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(json.dumps(v,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def verify(base,items):
    for name,digest in items.items():assert sha(base/name).lower()==digest.lower(),str(base/name)

def main():
    plan=read(ROOT/'validation/release_destination.json');dest=Path(plan['directory'])
    assert plan['version']=='V024' and dest.parent.resolve()==STORE.resolve()
    catalog=read(STORE/'版本目录.json');entry=next(x for x in catalog['versions'] if x['folder']==dest.name)
    assert entry['number']==24 and plan['alias'] in entry['aliases']
    verify(ROOT.parent/'instrument_phone_test_20261030',read(ROOT/'validation/baseline_v023_source_hashes.json'))
    baseline=read(ROOT/'validation/baseline_v021.json')
    verify(ROOT.parent/'instrument_expression_20261024',baseline['source_hashes'])
    old=next(x for x in catalog['versions'] if x['number']==21)
    old_fs=STORE/old['folder']/'instrument_v021.fs'
    assert sha(old_fs)=='c59627066feab3eddb85006bd4764232e00062b8eaa0fc3736806ffd53cefc53'
    b=read(ROOT/'validation/build_summary.json');verify(ROOT,read(ROOT/'validation/build_input_hashes.json'))
    assert b['input_hashes_verified'] and not any(b['timing_violations'].values())
    assert b['fmax_mhz']['clk27']>=27 and b['fmax_mhz']['pixel25_2']>=25.2 and b['fmax_mhz']['serial126']>=126
    assert all(b['resources'][k]<=b['capacities'][k] for k in b['resources'])
    r=read(ROOT/'validation/v024/summary.json');assert r['all_passed'] and r['source_hashes_match'] and r['full_suite']
    verify(ROOT,r['source_hashes'])
    guide=read(ROOT/'validation/piano_roll_source/summary.json');assert guide['passed']
    verify(ROOT,guide['frozen_product_sources_sha256'])
    pixels=read(ROOT/'validation/piano_roll/summary.json')
    assert pixels['source_hashes_match'] and all(x['passed'] for x in pixels['cases'])
    verify(ROOT,pixels['source_hashes'])
    pitch=read(ROOT/'validation/piano_pitch/results.json');assert pitch['passed']
    review=read(ROOT/'validation/v024_review.json');assert review['passed'] and not review['remaining_blockers']
    verify(ROOT,review['inspected_source_hashes'])
    bridge=read(ROOT/'esp32_phone/build/validation-result.json')
    assert bridge['native_tests_passed'] and bridge['web_tests_passed'] and bridge['compile']['compile_passed']
    verify(ROOT/'esp32_phone',bridge['compile']['source_sha256'])
    verify(ROOT/'esp32_phone/build',bridge['compile']['binary_sha256'])
    standalone=ROOT.parent/'调试工具/2026-10-30_V021_电容与光束测试'
    verify(standalone,{x['path']:x['sha256'] for x in read(standalone/'文件清单.json')['files']})
    fw=ROOT/'impl/pnr/instrument_handoff.fs';assert sha(fw)==b['firmware_sha256']
    dst_fw=dest/'instrument_v024_test.fs'
    if dst_fw.exists():assert sha(dst_fw)==sha(fw),'不能用不同固件覆盖同一版本'
    shutil.copy2(fw,dst_fw)
    ignore=shutil.ignore_patterns('__pycache__','*.pyc','*.vvp','*.tmp','*.obj','.git','.toolchain',
        'browser-profile','browser-temp','temp','_test_tmp','*.ppm')
    source=dest/'source';source.mkdir(exist_ok=True)
    for name in ('src','assets','scripts','tests','tools','docs','esp32_phone'):
        shutil.copytree(ROOT/name,source/name,dirs_exist_ok=True,ignore=ignore)
    for name in ('instrument_handoff.gprj','build.tcl','device_config.json','README.txt'):
        shutil.copy2(ROOT/name,source/name)
    shutil.copytree(ROOT/'validation',dest/'验证',dirs_exist_ok=True,ignore=ignore)
    shutil.copytree(ROOT/'validation',source/'validation',dirs_exist_ok=True,ignore=ignore)
    # 开发版来源记录不作为最终路径；发行包说明明确当前真实目录。
    for label in ('电容','光束'):
        (dest/(label+'测试.cmd')).write_text('@echo off\nchcp 65001 >nul\ncall "%~dp0source\\tools\\peripheral_testbench\\'+label+'测试.cmd"\n',encoding='utf-8')
    shutil.copy2(standalone/'先读我_使用说明.md',dest/'外设测试说明.md')
    now=datetime.now(timezone(timedelta(hours=8))).isoformat()
    changes=[
        '演奏页以真实黑白键几何展示MIDI48..79的32个半音，实体按键多键同时点亮，显示区外另提示',
        '保持原MIDI0..127十二平均律音高，黑键不改为打击乐或另一个音色；修正扩展音域15项1LSB取整误差，21..108不变',
        '三首简化练习曲改为120BPM时间驱动下落音条，含两拍准备、长音、暂停和重启；不等待正确按键推进',
        '手机通信、四旋钮FX、四Pad打击乐及FSR/滑杆/双光束继承V023，ESP32程序和引脚不变',
        '电容与光束测试仍可先配合板上V021使用；新版未烧录']
    limits=[
        '没有烧录FPGA或ESP32；真实HDMI显示、琴键同步、手机和外设等待用户后续实测',
        '内置曲目是简化一/两拍编排，不含完整音游计分、任意曲谱导入或自动伴奏',
        '可视范围为MIDI48..79，声音仍支持0..127；区外提示不是丢音，C4命名为MIDI60',
        '菜单/测试/非演奏页会冻结谱面；现有声音不随谱面自动暂停；音条不负责生成声音',
        'PCM5102A原实物无声原因仍未定位；本次不宣称修复',
        'ESP32沿用V023已实际编译的相同源码及二进制，本轮核对哈希，不重复上传或编译']
    info={'version':'V024','kind':'experimental_not_programmed','released_beijing':now,
        'development_project':str(ROOT),'baseline':'V023','changes':changes,'known_limits':limits,
        'firmware':dst_fw.name,'usercode':b['usercode'],'sha256':sha(dst_fw),
        'compile':'PASS','simulation':'PASS','resources':b['resources'],
        'utilization_percent':b['utilization_percent'],'timing_violations':b['timing_violations'],
        'fmax_mhz':b['fmax_mhz'],'hardware_programmed':False,'esp32_uploaded':False,
        'physical_validation':False,'prior_on_board_firmware':'V021','historical_versions_unchanged':True,
        'esp32_compile':'V023 binary reused; source and binary hashes verified',
        'piano_visible_range':[48,79],'audio_midi_range':[0,127],'falling_bpm':120,
        'external_tests_path':str(standalone)}
    write(dest/'版本信息.json',info)
    notes='版本：V024（独立实验测试版）\n日期：'+now+'（北京时间）\n基于：V023\n\n改动：\n'+'\n'.join('· '+x for x in changes)
    notes+='\n\n固件：'+dst_fw.name+'\nUserCode：'+b['usercode']+'\nSHA256：'+sha(dst_fw)
    notes+='\nFPGA编译/布局布线/离线回归：通过；Setup/Hold违例0。\n烧录状态：未执行。板上仍为此前V021记录。\n资源：'+json.dumps(b['resources'],ensure_ascii=False)
    notes+='\n\n限制：\n'+'\n'.join('· '+x for x in limits)+'\n'
    (dest/'版本说明.txt').write_text(notes,encoding='utf-8-sig')
    (dest/'验证/烧录记录.txt').write_text('本轮没有调用Programmer、打开真实串口或上传ESP32。\nV024仅编译/仿真/打包；板上此前V021不变。\nV021外设测试工具先于新版固件使用，等待用户醒来操作硬件。\n',encoding='utf-8-sig')
    screenshots=[dest/'验证/piano_roll'/name for name in ('live_play.png','live_16ticks_later.png','paused_held_outside.png')]
    assert all(p.is_file() for p in screenshots)
    imgs=''.join('<img style="max-width:100%;image-rendering:pixelated" src="'+html.escape(str(p.relative_to(dest)).replace('\\','/'))+'" alt="RTL模拟像素截图">' for p in screenshots[:3])
    page='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>V024 测试版入口</title><style>body{font:18px/1.8 'Microsoft YaHei',sans-serif;max-width:1100px;margin:40px auto;padding:20px;background:#f4f7fa;color:#173149}article{padding:24px;background:white;border-radius:14px;margin:20px 0}a{color:#006b9a}b{color:#914b00}</style><h1>V024｜黑白琴键与下落式演奏指示</h1><p><b>实验版未烧录。先测当前V021的电容和光束，再考虑加载新版。</b></p><article><h2>先排查现有外设</h2><p><a href="电容测试.cmd">电容键盘测试</a> · <a href="光束测试.cmd">双光束测试</a> · <a href="外设测试说明.md">测试说明</a></p><p>诊断完成点停止轮询，等1秒并全部松开，再按4/5抬手切页。</p></article><article><h2>新版功能与接线</h2><p>保持钢琴半音关系，黑白键按下显示；三曲谱面按120BPM下落，音条到线按键，条尾到线松开。6暂停，B重启，曲库1/2选择、3确认。</p><p><a href="source/docs/V024_使用与完整接线.html">使用说明与完整接线</a> · <a href="source/esp32_phone/README.md">手机端部署</a> · <a href="instrument_v024_test.fs">V024测试固件（未烧录）</a></p><p><a href="版本信息.json">版本信息</a> · <a href="验证/build_summary.json">资源及时序</a> · <a href="验证/v024/summary.json">回归记录</a></p></article><article><h2>实际RTL仿真像素预览</h2><p>以下来自RTL仿真，未连接真实显示器。</p>'''+imgs+'</article></html>'
    (dest/'版本入口.html').write_text(page,encoding='utf-8')
    entry.update(title='钢琴黑白键与下落式演奏提示，继承手机/FX/四Pad',status='实验版：编译/离线验证通过，未烧录',
        firmware_names=[dst_fw.name],firmware=str(dst_fw),usercode=b['usercode'],sha256=sha(dst_fw),
        hardware_programmed=False,kind=info['kind'],resource_summary=b['resources'])
    write(STORE/'版本目录.json',catalog)
    (STORE/'版本总览.txt').write_text('乐器版本总览\n\n'+'\n\n'.join(f"V{x['number']:03d} | {x.get('date','')} | {x.get('title','')}\n目录：{x['folder']}\n状态：{x.get('status','未记录')}" for x in catalog['versions'])+'\n',encoding='utf-8-sig')
    (STORE/'最新版本.txt').write_text('最新交付：V024（实验测试版，未烧录）\n目录：'+str(dest)+'\n入口：'+str(dest/'版本入口.html')+'\n固件：'+str(dst_fw)+'\nUserCode：'+b['usercode']+'\n仍按先电容、再光束、最后新版的顺序测试；此前板载V021保持不变。\n',encoding='utf-8-sig')
    write(dest/'文件校验.json',{str(p.relative_to(dest)):sha(p) for p in dest.rglob('*') if p.is_file() and p.name!='文件校验.json'})
    print('V024_RELEASE_PASS',dest)

if __name__=='__main__':main()
