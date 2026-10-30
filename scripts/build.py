"""构建当前目录工程，不使用旧版本路径。不进行板卡下载。"""
from pathlib import Path
import argparse, os, subprocess, hashlib, json, time
ROOT=Path(__file__).resolve().parents[1]
def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--gowin-home',type=Path,default=Path(os.environ.get('GOWIN_HOME','D:/Gowin_V1.9.12.04_x64_win/Gowin/Gowin_V1.9.12.04_x64')))
    ap.add_argument('--timeout',type=int,default=1800,help='本脚本Gowin子进程的主机超时秒数')
    a=ap.parse_args();exe=a.gowin_home/'IDE/bin/gw_sh.exe'
    if not exe.exists():ap.error('找不到 gw_sh.exe；使用 --gowin-home 或 GOWIN_HOME 指定安装根目录')
    subprocess.run([os.sys.executable,str(ROOT/'scripts/generate_ui_text.py'),'--check'],check=True,cwd=ROOT)
    # V016以短文本ID译码。两份生成资产必须与同一份中文文案一致。
    subprocess.run([os.sys.executable,str(ROOT/'scripts/generate_ui_lookup.py'),'--check'],check=True,cwd=ROOT)
    # 半表资产必须逐样本可逆；不允许音色更新后悄悄使用旧压缩表。
    subprocess.run([os.sys.executable,str(ROOT/'scripts/generate_odd_half_rom.py'),'--check'],check=True,cwd=ROOT)
    # V017仅综合长笛/拨弦两组；资产挑选与奇对称折叠都要可追溯到冻结原表。
    subprocess.run([os.sys.executable,str(ROOT/'scripts/generate_dual_timbres.py'),'--check'],check=True,cwd=ROOT)
    subprocess.run([os.sys.executable,str(ROOT/'scripts/generate_touch_centers.py'),'--check'],check=True,cwd=ROOT)
    # 音符号直接对应十二平均律；扩展音域也必须按最近整数舍入，不能变成等Hz间隔。
    subprocess.run([os.sys.executable,str(ROOT/'scripts/check_midi_note_table.py')],check=True,cwd=ROOT)
    val=ROOT/'validation';val.mkdir(exist_ok=True)
    inputs=[p for p in (ROOT/'src').glob('*') if p.is_file()]+[ROOT/'instrument_handoff.gprj',ROOT/'build.tcl']
    def hashes():return {str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
    before=hashes();(val/'build_input_hashes.json').write_text(json.dumps(before,indent=2),encoding='utf-8')
    started_ns=time.time_ns()
    with (val/'gowin_build.log').open('wb') as out:
        proc=subprocess.Popen([str(exe),str(ROOT/'build.tcl')],cwd=ROOT,stdout=out,stderr=subprocess.STDOUT)
        try:code=proc.wait(timeout=a.timeout)
        except subprocess.TimeoutExpired:proc.kill();proc.wait();raise SystemExit('构建超时，已停止本脚本创建的子进程')
    assert before==hashes(),'构建期间源码变化'
    log=(val/'gowin_build.log').read_text(encoding='utf-8',errors='replace');print(log[-4000:])
    fs=ROOT/'impl/pnr/instrument_handoff.fs'
    if code or not fs.exists() or 'ERROR' in log:raise SystemExit(code or 1)
    # impl内可能还留着上一版.fs。只有本轮实际更新的产物才算新构建，绝不改名旧固件交付。
    if fs.stat().st_mtime_ns < started_ns-1_000_000_000:raise SystemExit('本轮未生成新的.fs，拒绝使用旧产物')
    print('BUILD_PASS',fs)
if __name__=='__main__':main()
