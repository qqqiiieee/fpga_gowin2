"""仅在V021验收满足后发布；复制新固件和源码，绝不重命名旧fs冒充新产物。"""
from pathlib import Path
from datetime import datetime,timezone,timedelta
import hashlib,html,json,shutil

ROOT=Path(__file__).resolve().parents[1]
STORE=ROOT.parent/'乐器版本'
ALIAS='MIDI主奏_电容屏控_无手机_20261030'

def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))
def write(p,d):p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    catalog=read(STORE/'版本目录.json')
    entry=next(x for x in catalog['versions'] if ALIAS in x.get('aliases',[]))
    assert entry['number']==21
    dest=STORE/entry['folder'];dest.mkdir(exist_ok=True)
    build=read(ROOT/'validation/build_summary.json')
    assert build['input_hashes_verified'] and all(v==0 for v in build['timing_violations'].values())
    assert build['fmax_mhz']['clk27']>=27 and build['fmax_mhz']['serial126']>=126 and build['fmax_mhz']['pixel25_2']>=25.2
    tests=read(ROOT/'validation/v021/summary.json')
    assert not tests['compile_only'] and len(tests['cases'])==9 and all(x['pass'] for x in tests['cases'])
    for name,digest in tests['source_hashes'].items():assert sha(ROOT/name)==digest,(name,'regression input changed')
    for name in ('live_adsr','touch_display'):
        a=read(ROOT/'validation/agents'/name/'results.json')
        assert a['status'].lower()=='pass',(name,a['status'])
    effect_dir=ROOT/'validation/agents/effects'
    effects=read(effect_dir/'report.json') if (effect_dir/'report.json').is_file() else read(effect_dir/'partial_report.json')
    completed={x['case'] for x in effects['tests'] if x['status'].lower()=='pass'}
    assert set(range(8))==completed
    assert all(x['status'].lower()=='pass' for x in effects['tests'])
    if effects['status'].lower()!='pass':
        reconciled=read(effect_dir/'consolidated_report.json')
        assert reconciled['status']=='pass' and reconciled['full_suite']
        assert reconciled['raw_rtl_bytes_match'] and reconciled['numerical_and_boundary_coverage_unchanged']
    # 最终FX数值用例来自不可变原始快照；其后只有bench调度/进度上报优化。
    # 验证原快照逐文件哈希、生产RTL字节一致，不能拿旧bench哈希硬比新bench。
    for name,digest in effects['sources_sha256'].items():
        assert sha(effect_dir/'original_snapshot'/name)==digest,(name,'FX snapshot mismatch')
    assert sha(ROOT/'src/audio_effects.v')==effects['sources_sha256']['src/audio_effects.v']
    midi=read(ROOT/'validation/agents/midi_controls.json');assert midi['source_hashes_match_now']
    abort=read(ROOT/'validation/agents/test_abort/combined_results.json')
    assert abort['status']=='PASS' and abort['counts']=={'PASS':13,'FAIL':0}
    assert abort['full_directed_suite'] and abort['snapshot_hashes_verified'] and abort['live_hashes_verified_at_merge']
    for name,digest in abort['source_hashes'].items():assert sha(ROOT/name)==digest
    hub=read(ROOT/'validation/agents/hub_safety.json')
    assert hub['status'].lower()=='pass'
    assert sha(ROOT/'src/performance_input_hub.v')=='b5b0f2801553dbb514695afd92e40cacdcb7dc3e3328a92ac64161b00c066644'
    for a in [read(ROOT/'validation/agents/live_adsr/results.json'),read(ROOT/'validation/agents/touch_display/results.json')]:
        for name,digest in a.get('source_hashes',a.get('sources_sha256',{})).items():assert sha(ROOT/name)==digest,(name,'agent evidence mismatch')
    for name,digest in midi['source_sha256'].items():assert sha(ROOT/name)==digest
    firmware=ROOT/'impl/pnr/instrument_handoff.fs'
    assert sha(firmware)==build['firmware_sha256']
    assert firmware.stat().st_mtime>=datetime(2026,10,30,tzinfo=timezone(timedelta(hours=8))).timestamp()
    target=dest/'instrument_v021.fs';shutil.copy2(firmware,target)
    source=dest/'source';source.mkdir(exist_ok=True)
    skip=shutil.ignore_patterns('__pycache__','*.pyc','*.vvp','*.tmp','.git','pcm5102a.pdf','PCM5102A_PLL_Table11.png')
    for name in ('src','assets','scripts','tests','tools','docs'):
        shutil.copytree(ROOT/name,source/name,dirs_exist_ok=True,ignore=skip)
    for name in ('instrument_handoff.gprj','build.tcl','device_config.json'):
        shutil.copy2(ROOT/name,source/name)
    shutil.copytree(ROOT/'validation',dest/'验证',dirs_exist_ok=True,ignore=skip)
    shutil.copytree(ROOT/'docs/V021_接线图',dest/'接线图',dirs_exist_ok=True,ignore=skip)
    for name in ('V021_使用与架构说明.html','V021_架构与AI交接.txt'):
        shutil.copy2(ROOT/'docs'/name,dest/name)
    # 根目录使用说明中的相对链接指向根接线图与本版验证记录。
    p=dest/'V021_使用与架构说明.html';s=p.read_text(encoding='utf-8').replace('V021_接线图/完整接线图.html','接线图/完整接线图.html').replace('../validation/build_summary.json','验证/build_summary.json');p.write_text(s,encoding='utf-8')
    changed=['撤除八线矩阵和其CST，电容键盘经MCP CH0专职HDMI菜单',
        'MIDI主奏32复音；四旋钮三页软接管、四Pad实时鼓组、实时ADSR',
        'KEY/STRUM互斥发声，双光束调用MIDI所选和弦',
        'FSR1明亮度、FSR2拨弦阻尼；仅保留A2实体主音量滑杆',
        '共享Delay/Chorus/Reverb，保留尾音和Panic清除；双DAC并行',
        '中文紧凑四页HDMI、单键验证入口、节拍辅助及校准误触保护',
        '手机/ESP32、屏幕USB触控、灯带本版不实现']
    now=datetime.now(timezone(timedelta(hours=8))).isoformat()
    info={'version':'V021','released_beijing':now,'changes':changed,
        'development_project':str(ROOT),'firmware':target.name,'usercode':build['usercode'],
        'sha256':sha(target),'resources':build['resources'],'utilization_percent':build['utilization_percent'],
        'fmax_mhz':build['fmax_mhz'],'timing_violations':build['timing_violations'],
        'compile':'PASS','simulation':'PASS selected integration and required independent suites',
        'effects_full_8s_tail':'PASS',
        'hardware_programmed':False,'hardware_validation':'未烧录、未实机标定、未听音/物理HDMI验收',
        'known_limits':['长生产MIDI active-sense扩展用例两次超时，未计为通过；其他UART/故障/27MHz单元回归通过',
            '触摸中心是估算，首次必须逐键实测标定；运行时表掉电不保存',
            'PCM5102A为线输出，VIN及背面焊桥以实际模块为准',
            '曲库仅三首固定练习，不是任意乐谱导入或完整节奏评分'],
        'wiring':'接线图/完整接线图.html','test_report':'验证/v021/summary.json'}
    write(dest/'版本信息.json',info)
    text='版本：V021\n日期：'+now+'（北京时间）\n\n改动：\n'+'\n'.join('· '+x for x in changed)
    text+='\n\n固件：instrument_v021.fs\nUserCode：'+info['usercode']+'\nSHA256：'+info['sha256']
    text+='\n\n综合/布局布线：PASS；约束时钟达标，Setup/Hold违例0。\n选定集成与独立单元仿真：PASS，详见验证目录；超时长用例单独记录。\n完整8秒尾音：'+info['effects_full_8s_tail']+'\n实际烧录：未进行。实机接线、标定、MIDI映射、HDMI/声音均待用户验证。\n资源：'+json.dumps(build['resources'],ensure_ascii=False)
    (dest/'版本说明.txt').write_text(text+'\n',encoding='utf-8-sig')
    (dest/'验证/烧录记录.txt').write_text('V021：本轮只构建和离线验证，未连接Programmer执行烧录。\n首次建议SRAM Program测试，不依赖先前曾失败的外部Flash桥接烧录。\n烧录目标GW2A-18C，文件为本目录instrument_v021.fs；不得选择旧V020。\n',encoding='utf-8-sig')
    entry.update(status='编译与选定回归通过；未烧录，待实机标定/验收',firmware_names=[target.name],firmware=str(target),usercode=info['usercode'],sha256=info['sha256'],resource_summary=info['resources'],hardware_programmed=False)
    write(STORE/'版本目录.json',catalog)
    (STORE/'版本总览.txt').write_text('乐器固件版本总览（各版独立保存，状态以各版记录为准）\n\n'+'\n\n'.join(f"V{x['number']:03d} | {x.get('date','')} | {x.get('title','')}\n目录：{x['folder']}\n状态：{x.get('status','未记录')}" for x in catalog['versions'])+'\n',encoding='utf-8-sig')
    (STORE/'最新版本.txt').write_text('V021 | MIDI主奏、电容屏控、无手机\n文件夹：'+entry['folder']+'\n固件：'+str(target)+'\nUserCode：'+info['usercode']+'\nSHA256：'+info['sha256']+'\n编译与选定离线回归通过；未烧录，首次须触摸标定。\n入口：'+str(dest/'版本入口.html')+'\n',encoding='utf-8-sig')
    page='<meta charset="utf-8"><title>V021 版本入口</title><style>body{font:20px/2 Microsoft YaHei;margin:50px;max-width:1100px}a{color:#07658d}</style><h1>V021｜MIDI主奏与电容屏控</h1><p>编译与选定回归通过；未烧录，实际硬件待标定和验收。</p>'
    for label,link in [('完整接线图（8页）','接线图/完整接线图.html'),('可打印PDF接线图','接线图/V021_完整接线图.pdf'),('本版固件','instrument_v021.fs'),('使用与架构说明','V021_使用与架构说明.html'),('AI/交接者模块说明','V021_架构与AI交接.txt'),('真实资源与时序记录','验证/build_summary.json'),('版本信息','版本信息.json')]:page+='<p><a href="'+html.escape(link)+'">'+label+'</a></p>'
    (dest/'版本入口.html').write_text(page,encoding='utf-8')
    # 按历史习惯同步接线图入口，不修改任何旧接线图。
    wire=ROOT.parent/'接线图/2026-10-30_V021_电容屏控完整接线';shutil.copytree(dest/'接线图',wire,dirs_exist_ok=True)
    manifest={str(p.relative_to(dest)):sha(p) for p in dest.rglob('*') if p.is_file() and p.name!='文件校验.json'}
    write(dest/'文件校验.json',manifest)
    assert sha(target)==build['firmware_sha256']
    print('V021_RELEASE_PASS',dest)

if __name__=='__main__':main()
