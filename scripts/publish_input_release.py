"""按验收记录发布输入扩展固件；不会烧录或推送代码。"""
from pathlib import Path
from datetime import datetime, timezone, timedelta
import hashlib,importlib.util,json,re,shutil
from summarize_build import summarize
ROOT=Path(__file__).resolve().parents[1]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def copy_file(src,dst):
 dst.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(src,dst)
def main():
 plan=json.loads((ROOT/'validation/release_plan.json').read_text(encoding='utf-8'))
 audit=json.loads((ROOT/'validation/acceptance.json').read_text(encoding='utf-8'))
 if audit['status']!='PASS':raise RuntimeError('acceptance must pass')
 current=summarize(ROOT)
 if current['timing_violations']!={'Setup':0,'Hold':0}:raise RuntimeError('timing failed')
 for n,h in audit['production_input_hashes'].items():
  if sha(ROOT/n)!=h:raise RuntimeError('source drift '+n)
 spec=importlib.util.spec_from_file_location('local_version_store','C:/Users/31989/ai-relay/version_store.py')
 store=importlib.util.module_from_spec(spec);spec.loader.exec_module(store)
 release=store.release_dir(plan['alias']);version=f"V{plan['number']:03d}"
 if f'_{version}_' not in release.name:raise RuntimeError('unexpected version catalog entry')
 project=release/'工程';project.mkdir()
 ignore=shutil.ignore_patterns('__pycache__','*_setup.exe','*.zip','extract_probe','innoextract-1.9','runner_selfcheck')
 for name in ['src','assets','scripts','tests','tools']:
  shutil.copytree(ROOT/name,project/name,ignore=ignore)
 for name in ['instrument_handoff.gprj','build.tcl','device_config.json']:
  copy_file(ROOT/name,project/name)
 for name in ['acceptance.json','build_summary.json','build_input_hashes.json','gowin_build.log','release_plan.json']:
  copy_file(ROOT/'validation'/name,project/'validation'/name)
 # 可重跑的优化证明只带冻结输入、脚本与报告，不复制大体积中间网表。
 for name in plan.get('reproduction_bundles',[]):
  source=ROOT/'validation'/name;target=project/'validation'/name
  for item in source.rglob('*'):
   parts=item.relative_to(source).parts
   if item.is_file() and not any(x in ['runs','synthesis','compatibility','negative_controls','__pycache__','impl'] for x in parts):
    copy_file(item,target/item.relative_to(source))
 for src in (ROOT/'validation'/plan['baseline_directory']).rglob('*'):
  if src.is_file():copy_file(src,project/'validation'/src.relative_to(ROOT/'validation'))
 docs=release/'docs';docs.mkdir()
 for name in plan['documents']:
  target=docs/Path(name).name
  copy_file(ROOT/name,target)
  if target.suffix=='.html':
   text=target.read_text(encoding='utf-8').replace('href="../src/','href="../工程/src/').replace('href="../assets/','href="../工程/assets/')
   text=re.sub(r'href="../validation/(baseline_[^/]+/)',r'href="../工程/validation/\1',text)
   text=text.replace('href="../validation/','href="../验证/')
   target.write_text(text,encoding='utf-8')
 for name in plan.get('preview_images',[]):copy_file(ROOT/name,docs/Path(name).name)
 validation=release/'验证';validation.mkdir()
 for name in ['acceptance.json','build_summary.json','build_input_hashes.json','gowin_build.log','build_origin.json',*plan['verification_records']]:
  source=ROOT/'validation'/name
  if source.is_file():copy_file(source,validation/name)
  elif source.is_dir():
   for item in source.rglob('*'):
    parts=item.relative_to(source).parts
    if item.is_file() and item.suffix in ['.json','.log','.txt'] and not any(x in ['src','assets','tests','snapshot','inputs'] for x in parts):
     copy_file(item,validation/name/item.relative_to(source))
  else:raise FileNotFoundError(source)
 for name in ['instrument_handoff.rpt.txt','instrument_handoff.tr','instrument_handoff.pin.html']:
  copy_file(ROOT/'impl/pnr'/name,validation/'Gowin'/name)
 copy_file(ROOT/'impl/gwsynthesis/instrument_handoff_syn_rsc.xml',validation/'Gowin/instrument_handoff_syn_rsc.xml')
 fw=release/f'instrument_{version.lower()}.fs';copy_file(ROOT/'impl/pnr/instrument_handoff.fs',fw)
 now=datetime.now(timezone(timedelta(hours=8)))
 meta={'version':version,'title':plan['title'],'date':now.date().isoformat(),'created_at':now.isoformat(timespec='seconds'),
 'status':'编译、时序与离线测试通过；未烧录，实机待验','firmware_name':fw.name,'usercode':current['usercode'],'sha256':sha(fw),
 'resources':current['resources'],'timing_violations':current['timing_violations'],'fmax_mhz':current['fmax_mhz'],
 'test_counts':audit['counts'],'hardware_programmed':False,'development_project':str(ROOT),'notes':plan['notes']}
 (release/'版本信息.json').write_text(json.dumps(meta,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 (release/'版本说明.txt').write_text(f'{version} | {now:%Y-%m-%d}（北京时间）\n{plan["title"]}\n固件：{fw.name}\nUserCode：{current["usercode"]}\nSHA256：{sha(fw)}\n\n'+plan['changes']+'\n\n验证：'+json.dumps(audit['counts'],ensure_ascii=False)+'\n编译、时序及离线测试通过，未执行下载或实机录音。\n',encoding='utf-8-sig')
 (release/'烧录记录.txt').write_text('未烧录；板上当前固件未知，未进行实机音频/HDMI/新增外设测试。\n',encoding='utf-8-sig')
 if plan.get('touch_launchers'):
  for name,mode in [('打开触摸监视.cmd','monitor'),('开始逐键标定.cmd','calibrate')]:
   import sys
   text='@echo off\nchcp 65001 >nul\ncd /d "%~dp0工程"\n"'+Path(sys.executable).as_posix()+'" tools/touch_launcher.py '+mode+'\npause\n'
   (release/name).write_text(text,encoding='utf-8')
 if plan.get('input_monitor_launcher'):
  import sys
  text='@echo off\nchcp 65001 >nul\ncd /d "%~dp0工程"\n"'+Path(sys.executable).as_posix()+'" tools/input_monitor.py\npause\n'
  (release/'打开全部输入监视.cmd').write_text(text,encoding='utf-8')
 rows=''.join(f'<tr><td>{n}</td><td>{v:g}/{current["capacities"][n]:g}</td><td>{current["utilization_percent"][n]:.2f}%</td></tr>' for n,v in current['resources'].items())
 doclinks=' · '.join(f'<a href="docs/{Path(n).name}">{Path(n).name}</a>' for n in plan['documents'])
 html='<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>'+version+' 输入扩展交付</title><style>body{font:17px/1.8 Microsoft YaHei,sans-serif;max-width:1100px;margin:36px auto;padding:0 24px;color:#19324a}table{border-collapse:collapse;width:100%}th,td{border:1px solid #c9dae8;padding:10px}th{background:#e9f3fa}a{color:#086ab5}.box{padding:16px;background:#eef6fd;border-radius:10px}</style><h1>'+version+' '+plan['title']+'</h1><p class="box">'+plan['overview_html']+'</p><p>固件：<a href="'+fw.name+'">'+fw.name+'</a>，UserCode '+current['usercode']+'</p><table><tr><th>资源</th><th>已用/总量</th><th>占用</th></tr>'+rows+'</table><p>Setup/Hold违例均0；未烧录、未实机验证。</p><p>'+doclinks+'</p><p>'+plan['notes']+'</p><p><a href="验证/acceptance.json">离线验收记录</a> · <a href="版本说明.txt">日期与改动</a></p></html>'
 (release/'版本入口.html').write_text(html,encoding='utf-8')
 for n,h in audit['production_input_hashes'].items():
  if sha(project/n)!=h:raise RuntimeError('copied source mismatch '+n)
 manifest={p.relative_to(release).as_posix():sha(p) for p in sorted(release.rglob('*')) if p.is_file()}
 (release/'文件校验.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 if not all(sha(release/n)==h for n,h in manifest.items()):raise RuntimeError('manifest failed')
 catalog=json.loads(store.CATALOG.read_text(encoding='utf-8'));entry=next(x for x in catalog['versions'] if x['folder']==release.name)
 entry.update(title=plan['title'],status=meta['status'],firmware_names=[fw.name],firmware=str(fw),usercode=current['usercode'],sha256=sha(fw),resource_summary=current['resources'],hardware_programmed=False)
 store.CATALOG.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 (store.ROOT/'最新版本.txt').write_text(f'{version} | {now:%Y-%m-%d} | {plan["title"]}\n文件夹：{release.name}\n固件：{fw}\nUserCode：{current["usercode"]}\n{meta["status"]}\n入口：{release / "版本入口.html"}\n',encoding='utf-8-sig')
 (store.ROOT/'版本总览.txt').write_text('\n\n'.join(f'V{x["number"]:03d} | {x.get("date","")} | {x.get("title","")}\n文件夹：{x["folder"]}\n状态：{x.get("status","")}' for x in catalog['versions'])+'\n',encoding='utf-8-sig')
 result={'release':str(release),'firmware':str(fw),'usercode':current['usercode'],'sha256':sha(fw),'verified_files':len(manifest),'version':version}
 (ROOT/'validation/release_result.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(result,ensure_ascii=True))
if __name__=='__main__':main()
