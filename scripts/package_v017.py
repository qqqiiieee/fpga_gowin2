"""发布两音色V017：要求实际编译/时序/回归通过，仅打包，不连接板卡。"""
from pathlib import Path
import hashlib
import importlib.util
import json
import re
import shutil
from datetime import datetime, timezone, timedelta
from summarize_build import summarize

ROOT=Path(__file__).resolve().parents[1]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def copy_record_tree(source, destination):
    # 只保留可审计结果/日志，不带巨型仿真可执行文件和输入副本。
    for path in source.rglob('*'):
        if path.is_file() and path.suffix in ['.json','.log','.txt'] and not any(
                part in ['snapshot','src','tests','inputs','before'] for part in path.relative_to(source).parts):
            target=destination/path.relative_to(source)
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(path,target)

def main():
    acceptance=json.loads((ROOT/'validation/acceptance_v017.json').read_text(encoding='utf-8'))
    assert acceptance['status']=='PASS'
    for name,digest in acceptance['production_input_hashes'].items():
        assert sha(ROOT/name)==digest, name
    current=summarize(ROOT)
    assert current['timing_violations']=={'Setup':0,'Hold':0}
    base=json.loads((ROOT/'validation/baseline_v016/build_summary.json').read_text(encoding='utf-8'))
    store_path=Path('C:/Users/31989/ai-relay/version_store.py')
    spec=importlib.util.spec_from_file_location('version_store_local',store_path)
    store=importlib.util.module_from_spec(spec);spec.loader.exec_module(store)
    release=store.release_dir('双音色精简_长笛拨弦_保留32声部_20261024')
    assert re.search(r'_V017_',release.name),'Unexpected version; inspect catalog before packaging'
    project=release/'工程';project.mkdir(exist_ok=False)
    for name in ['src','assets','tests','scripts']:
        shutil.copytree(ROOT/name,project/name,ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copytree(ROOT/'tools',project/'tools',ignore=shutil.ignore_patterns(
        '__pycache__','*_setup.exe','*.zip','extract_probe','innoextract-1.9','runner_selfcheck'))
    for name in ['instrument_handoff.gprj','build.tcl','device_config.json']:
        shutil.copy2(ROOT/name,project/name)
    (project/'validation/baseline_v016').mkdir(parents=True)
    shutil.copy2(ROOT/'validation/baseline_v016/build_summary.json',project/'validation/baseline_v016/build_summary.json')
    for name in ['build_input_hashes.json','build_summary.json','gowin_build.log','acceptance_v017.json']:
        shutil.copy2(ROOT/'validation'/name,project/'validation'/name)
    validation=release/'验证';validation.mkdir()
    for name in ['build_input_hashes.json','build_summary.json','gowin_build.log','acceptance_v017.json',
                 'build_origin.json','dual_packing_report.json','dual_asset_tests.json','dual_asset_tests.log',
                 'timbre2_ui_agent.json','dual_timbre_review.json','review_resolution.json']:
        if (ROOT/'validation'/name).is_file():
            shutil.copy2(ROOT/'validation'/name,validation/name)
    for item in acceptance['result_directories']:
        source=ROOT/item
        copy_record_tree(source,validation/source.name)
    shutil.copy2(ROOT/'validation/dual_timbre_agent/baseline_optional_check.json',
                 validation/'baseline_optional_check.json')
    shutil.copy2(ROOT/'validation/dual_timbre_agent/frozen_reference_manifest.json',
                 validation/'frozen_reference_manifest.json')
    (validation/'阅读说明.txt').write_text(
        '最终结论以acceptance_v017.json为准：37项RTL、9项资产测试通过，3项负对照正确拒绝。\n'
        '首次回归曾发现旧16音色兼容路径在Icarus加载失败；修复后，所有涉及instrument_audio的6项用例已重新运行通过。\n'
        '旧失败日志保留供追溯，acceptance明确列出superseded_core_tests与最终记录位置。\n'
        '未涉及该模块的UI及独立算法测试复用相同展开源码；elaborated_files.txt保存仿真器实际文件表。\n'
        'dual_timbre_review.json中的Python优化模式提示已按review_resolution.json修复，并加入负保护测试。\n'
        '全部验证为离线数字模型，没有进行板卡烧录、模拟录音或HDMI实测。\n',encoding='utf-8-sig')
    gowin=validation/'Gowin';gowin.mkdir()
    for name in ['instrument_handoff.rpt.txt','instrument_handoff.tr','instrument_handoff.pin.html']:
        shutil.copy2(ROOT/'impl/pnr'/name,gowin/name)
    shutil.copy2(ROOT/'impl/gwsynthesis/instrument_handoff_syn_rsc.xml',gowin/'instrument_handoff_syn_rsc.xml')
    firmware=release/'instrument_v017.fs'
    shutil.copy2(ROOT/'impl/pnr/instrument_handoff.fs',firmware)
    assert sha(firmware)==current['firmware_sha256']
    docs=release/'docs';docs.mkdir()
    for name in ['V017_项目架构与模块说明.txt','AI快速上手_V017.txt']:
        shutil.copy2(ROOT/'docs'/name,docs/name)
    now=datetime.now(timezone(timedelta(hours=8)))
    meta={'version':'V017','created_at':now.isoformat(timespec='seconds'),'date':now.date().isoformat(),
          'title':'两音色精简：柔和长笛与拨弦，保留32声部',
          'status':'构建、时序和离线回归通过；未烧录，实机待验',
          'firmware_name':firmware.name,'usercode':current['usercode'],'sha256':current['firmware_sha256'],
          'development_project':str(ROOT),'resources':current['resources'],'baseline_version':'V016',
          'baseline_resources':base['resources'],'timing_violations':current['timing_violations'],
          'fmax_mhz':current['fmax_mhz'],'melodic_timbres':2,'voices':32,'pressure_drums':2,
          'audio_output':'onboard PT8211 / 3.5mm','pin_constraints_changed':False,
          'hardware_programmed':False,'tests':acceptance['counts'],
          'source_bank_mapping':{'0':'V016 ID1 柔和长笛','1':'V016 ID7 拨弦'},
          'contest_source':'https://www.gowinsemi.com.cn/university/match2026',
          'scope':'Meets >=2 timbre count only; pending MIDI/MCP3208/ESP32/effects/standard I2S and physical acceptance are not claimed complete.'}
    (release/'版本信息.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    changes='\n'.join(f'{name}：{base["resources"][name]:g} → {current["resources"][name]:g}' for name in ['Logic','Register','CLS','BSRAM','DSP'])
    description=f'版本：V017\n日期：{now:%Y-%m-%d}（北京时间）\n固件：instrument_v017.fs\nUserCode：{current["usercode"]}\nSHA256：{current["firmware_sha256"]}\n\n改动：旋律16音色减为2种：00柔和长笛（旧1）/01拨弦（旧7）；保留原波形和起音。音色波表半表16KiB降至2KiB；allocator与帧快照音色字段4位降至1位；S13/S14在两音色循环，中文名称与帮助同步更新。保留32独立声部、双压力鼓、双滑杆、四页中文、曲库、UART虚拟输入及32路验证。\n\n布局布线后资源：\n{changes}\n\n验证：Setup/Hold违例均0。受影响模块回归、双音色对照与资产保护测试通过，详见验证目录。\n未执行烧录和实机录音；接线/时钟约束不变。音色数满足赛题该项最低要求，不代表全部赛项已完成。\n\n烧录：Gowin Programmer选择本目录instrument_v017.fs；先以SRAM下载验证，再按既有Flash流程操作。工程为工程/instrument_handoff.gprj。\n'
    (release/'版本说明.txt').write_text(description,encoding='utf-8-sig')
    (release/'烧录记录.txt').write_text('未执行SRAM/Flash下载；板上当前固件版本未知。未录制实机音频或HDMI。构建、时序及数字仿真通过不等于实机验收。\n',encoding='utf-8-sig')
    rows=[]
    for name in ['Logic','Register','CLS','BSRAM','DSP']:
        old=base['resources'][name];new=current['resources'][name];cap=current['capacities'][name]
        rows.append(f'<tr><td>{name}</td><td>{old:g}</td><td>{new:g}</td><td>{old-new:g}</td><td>{new/cap*100:.2f}%</td></tr>')
    html='<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>V017 两音色精简结果</title><style>body{font:17px/1.8 Microsoft YaHei,sans-serif;margin:32px auto;max-width:1050px;padding:0 24px;color:#183044}table{border-collapse:collapse;width:100%}th,td{border:1px solid #c8d7e3;padding:12px;text-align:left}th{background:#eaf3fa}.ok{background:#e9f8ee;padding:16px;border-radius:8px}a{color:#065fac}p{margin:18px 0}</style><h1>V017：两音色精简，保留32声部</h1><p>日期：'+now.strftime('%Y-%m-%d')+'｜与V016比较</p><p class="ok">00 柔和长笛 + 01 拨弦，S13/S14切换。32独立相位/包络保留，双压力鼓、两滑杆、中文四页、曲库及验证模式保留。</p><table><tr><th>资源</th><th>V016</th><th>V017</th><th>释放</th><th>本版占用</th></tr>'+''.join(rows)+'</table>'
    html+='<p>生产音色半表由16×512×16bit减为2×512×16bit，即16KiB → 2KiB，减少87.5%。内部声部音色字段4bit → 1bit。原16音色文件只作生成与历史回归基准，不在生产硬件分支实例化。</p><p>长笛/拨弦的波形分别与V016旧ID1/7逐点相同，起音速度和调度时序保留。旧声部锁存原音色，切换影响随后音符。</p>'
    html+='<p>Setup/Hold违例均0。clk27路径Fmax '+str(current['fmax_mhz']['clk27'])+'MHz（工作27MHz），像素路径Fmax '+str(current['fmax_mhz']['pixel25_2'])+'MHz（工作25.2MHz）。引脚与时钟约束不变。</p>'
    counts=acceptance['counts']
    html+=f'<p>离线验证：{counts["rtl_pass"]}项RTL测试、{counts["asset_unit_tests"]}项波表资产测试通过，{counts["expected_negative_rejected"]}项故意破坏测试均被正确拒绝。完整结果及源hash见下方记录。未烧录、未实机监听；音色数量满足<a href="https://www.gowinsemi.com.cn/university/match2026">官方赛题</a>的至少两种要求，MIDI、MCP3208、ESP32、标准I2S、效果器和其他赛题验收仍需后续工作。</p>'
    html+='<p>固件：<a href="instrument_v017.fs">instrument_v017.fs</a>｜UserCode：'+current['usercode']+'</p><p><a href="docs/V017_项目架构与模块说明.txt">项目架构与模块说明</a> · <a href="docs/AI快速上手_V017.txt">AI快速上手</a> · <a href="验证/build_summary.json">真实资源与时序</a> · <a href="验证/acceptance_v017.json">本版验收记录</a></p></html>'
    (release/'资源对比.html').write_text(html,encoding='utf-8')
    for directory in ['src','assets','tests','scripts']:
        for source in (ROOT/directory).rglob('*'):
            if source.is_file() and '__pycache__' not in source.parts:
                assert sha(source)==sha(project/source.relative_to(ROOT)),str(source)
    for name,digest in acceptance['production_input_hashes'].items():
        assert sha(project/name)==digest, name
    manifest={p.relative_to(release).as_posix():sha(p) for p in sorted(release.rglob('*')) if p.is_file()}
    (release/'文件校验.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    assert all(sha(release/name)==digest for name,digest in manifest.items())
    catalog=json.loads(store.CATALOG.read_text(encoding='utf-8'))
    entry=next(x for x in catalog['versions'] if x['folder']==release.name)
    entry.update(title=meta['title'],status=meta['status'],firmware_names=[firmware.name],firmware=str(firmware),usercode=current['usercode'],sha256=current['firmware_sha256'],resource_summary=current['resources'],hardware_programmed=False)
    store.CATALOG.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    (store.ROOT/'最新版本.txt').write_text(f'V017 | {now:%Y-%m-%d} | {meta["title"]}\n文件夹：{release.name}\n固件：{firmware}\nUserCode：{current["usercode"]}\n{meta["status"]}\n资源对比：{release / "资源对比.html"}\n',encoding='utf-8-sig')
    (store.ROOT/'版本总览.txt').write_text('\n\n'.join(f'V{x["number"]:03d} | {x.get("date","")} | {x.get("title","")}\n文件夹：{x["folder"]}\n状态：{x.get("status","未知")}' for x in catalog['versions'])+'\n',encoding='utf-8-sig')
    result={'release':str(release),'firmware':str(firmware),'resources':current['resources'],'usercode':current['usercode'],'verified_files':len(manifest)}
    (ROOT/'validation/release_result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(result,ensure_ascii=True))

if __name__=='__main__':
    main()
