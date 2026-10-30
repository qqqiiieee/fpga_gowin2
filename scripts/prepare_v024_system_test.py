"""从V023完整音频/通信回归派生，追加V024黑键位图和时间轴的端到端断言。"""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    p=(ROOT/'tests/tb_v023_system.v').read_text(encoding='utf-8')
    p=p.replace('tb_v023_system','tb_v024_system').replace('V023','V024')
    p=p.replace('defparam dut.u_audio.input_hub.touch_input.reader.SCLK_DIV=1;',
        'defparam dut.GUIDE_BEAT_SAMPLES=67;\n defparam dut.u_audio.input_hub.touch_input.reader.SCLK_DIV=1;')
    p=p.replace('integer i,oldnotes,oldpcm;','integer i,oldnotes,oldpcm;reg[11:0]frozen_tick;')
    anchor='  // Knob near current target catches it, then all pages preserve fixed FX mapping.'
    p=p.replace(anchor,'''  // 独立音高事件和屏幕位图均保留半音，不经自然音级摘要压缩。
  midi(8'h90,60,100);midi(8'h90,61,100);
  if(dut.piano_keys!==32'h00003000 || dut.piano_outside)$fatal(1,"C4/C#4 physical display lost sharp");
  midi(8'h80,60,0);if(dut.piano_keys!==32'h00002000)$fatal(1,"white release cleared black key");
  midi(8'h80,61,0);if(dut.piano_keys!==0)$fatal(1,"black release left key lit");
  midi(8'h90,35,100);if(!dut.piano_outside || dut.piano_keys!==0)$fatal(1,"out of visible range not indicated");
  midi(8'h80,35,0);if(dut.piano_outside)$fatal(1,"out of range release stuck");
  touch(7); // B/S8: restart autonomous visual timeline; production rate is only accelerated here.
  if(dut.roll_tick==0 || dut.guide_done)$fatal(1,"timeline restart did not advance");
  phone(1,12,1,1);frozen_tick=dut.roll_tick;clocks(1200);
  if(dut.roll_tick!==frozen_tick)$fatal(1,"non-LIVE page failed to freeze timeline");
  phone(1,12,0,0);clocks(1200);
  if(dut.roll_tick<=frozen_tick)$fatal(1,"LIVE resume did not advance timeline");
  oldnotes=note_ons;
'''+anchor)
    p=p.replace('phone_uart=1 fixed_knobs=1','piano_sharp_bitmap=1 roll_page_pause=1 phone_uart=1 fixed_knobs=1')
    (ROOT/'tests/tb_v024_system.v').write_text(p,encoding='utf-8')
    print('V024_SYSTEM_TEST_GENERATED')
if __name__=='__main__':main()
