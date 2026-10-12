"""构建当前目录工程，不使用旧版本路径。不进行板卡下载。"""
from pathlib import Path
import argparse, os, subprocess, hashlib, json
ROOT=Path(__file__).resolve().parents[1]
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--gowin-home',type=Path,default=Path(os.environ.get('GOWIN_HOME','D:/Gowin_V1.9.12.04_x64_win/Gowin/Gowin_V1.9.12.04_x64')))
    a=ap.parse_args();exe=a.gowin_home/'IDE/bin/gw_sh.exe'
    if not exe.exists():ap.error('找不到 gw_sh.exe；使用 --gowin-home 或 GOWIN_HOME 指定安装根目录')
    subprocess.run([os.sys.executable,str(ROOT/'scripts/generate_ui_text.py'),'--check'],check=True,cwd=ROOT)
    val=ROOT/'validation';val.mkdir(exist_ok=True)
    inputs=[p for p in (ROOT/'src').glob('*') if p.is_file()]+[ROOT/'instrument_handoff.gprj',ROOT/'build.tcl']
    def hashes():return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    before=hashes();(val/'build_input_hashes.json').write_text(json.dumps(before,indent=2),encoding='utf-8')
    with (val/'gowin_build.log').open('wb') as out:
        proc=subprocess.Popen([str(exe),str(ROOT/'build.tcl')],cwd=ROOT,stdout=out,stderr=subprocess.STDOUT)
        try:code=proc.wait(timeout=900)
        except subprocess.TimeoutExpired:proc.kill();proc.wait();raise SystemExit('构建超时，已停止本脚本创建的子进程')
    assert before==hashes(),'构建期间源码变化'
    log=(val/'gowin_build.log').read_text(encoding='utf-8',errors='replace');print(log[-4000:])
    fs=ROOT/'impl/pnr/instrument_handoff.fs'
    if code or not fs.exists() or 'ERROR' in log:raise SystemExit(code or 1)
    print('BUILD_PASS',fs)
if __name__=='__main__':main()
