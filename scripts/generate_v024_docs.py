"""V024说明：在已交付V023的接线/手机说明上追加真实钢琴与下落提示契约。"""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
    docs=ROOT/'docs'
    text=(docs/'V023_使用与完整接线.html').read_text(encoding='utf-8')
    text=text.replace('V023','V024').replace('从V021分支','从V023实验版分支')
    text=text.replace('手机通信、四旋钮FX、四Pad鼓组','钢琴黑白键、下落演奏提示、手机与FX')
    text=text.replace('V024_手机UART接线.svg','V023_手机UART接线.svg')
    text=text.replace('run_v023_tests.py','run_v024_tests.py').replace('../validation/v023/summary.json','../validation/v024/summary.json')
    text=text.replace('此轮已经编译验证但没有自动下载','沿用V023已编译且核对源码/二进制哈希的ESP32程序；本轮未重新编译或下载')
    extra='''<section><h2>本版新增：真正的黑白琴键与下落提示</h2>
<p>发声仍按标准MIDI音符号和十二平均律：A4（MIDI 69）=440Hz，相邻半音频率比为2^(1/12)。白键C D E F G A B，黑键C# D# F# G# A#；E-F、B-C之间本来没有黑键。原发声查表已经遵循这个关系，本版没有把黑键改成鼓或另一个音色。</p>
<p>屏幕展示MIDI 48..79（C3..G5）的32个半音，19个白键、13个黑键，黑键画在相邻白键之间，较短、较窄。当前按键亮起，多键同时亮；超出显示范围另有标记。发声仍接受MIDI 0..127，屏幕范围不是声音范围。八度命名采用C4=MIDI60。</p>
<p>演奏页改为下落式谱面：向下移动的音条对应琴键；条的前端落到判定线时按下，后端到线时松开，连续长条代表较长时值。固定120BPM，一拍0.5秒，开始/重启预留两拍；曲谱按时间继续，不会等按对才推进。</p>
<p>三首内置练习仍是简化的一/两拍单声部编排，不承诺原曲所有节奏细节。现在是节拍和键位提示，没有自动伴奏、完整音游评分、命中率统计或任意MIDI曲谱导入。</p>
<p>电容面板6/S7播放暂停，B/S8重启；4/S5、5/S6翻页；曲库用1/S1、2/S2选择、3/S3确认。菜单按键松开确认。离开演奏页、菜单手势和32路验证时冻结谱面，不冻结正常声音；恢复后从冻结位置继续。板上V021的电容诊断轮询须先停止，等1秒并全松，才测试切页。</p>
<p>普通演奏页以琴键与音条为主；诊断页/32路测试仍保留PCM波形，便于继续排查音频。手机、四旋钮FX、四Pad鼓、两音色、压力表情、双光束及所有外设引脚沿用V023，不新增接线。</p>
<p><a href="../validation/piano_roll/">RTL像素截图与谱面测试记录</a>；<a href="../validation/piano_pitch/results.json">MIDI全音域音高核对</a>。</p></section>'''
    text=text.replace('<section><h2>先做哪一步</h2>',extra+'<section><h2>先做哪一步</h2>',1)
    (docs/'V024_使用与完整接线.html').write_text(text,encoding='utf-8')
    (ROOT/'README.txt').write_text('V024 独立实验测试版：先看 docs/V024_使用与完整接线.html。\n黑白琴键、32音显示和下落式三曲练习；继承V023手机/四旋钮FX/四Pad鼓。\n本轮未烧录FPGA/ESP32；现有V021不变，先使用电容和光束PC工具排查当前问题。\n新谱面仅视觉引导，非自动发声；不是完整音游评分。\n',encoding='utf-8-sig')
    print('V024_DOCS_GENERATED')

if __name__=='__main__':main()
