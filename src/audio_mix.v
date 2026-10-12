// 作用：把键盘旋律、底鼓、军鼓三个单声道 PCM 相加，再限制到 16 位输出范围。
// melody/kick/snare/sample 虽声明为无符号总线，位图均按 16 位二补码 PCM 解释；
// 0 是静音，正满幅为 32767，负满幅为 -32768。
// 本模块是纯组合逻辑，没有 clk、采样 tick、复位或内部状态；输入变化即影响输出。
// 工程上游运行在 27 MHz 主时钟，音频帧率为 93.75 kHz（每帧 288 个主时钟周期）；
// 这里不产生时钟或使能，下游按自己的采样使能读取组合结果。
// 不做平均、音量缩放或柔性压缩；鼓输入都为零时，旋律 PCM 位图原样通过。
module audio_mix(input [15:0] melody,input [15:0] kick,input [15:0] snare,
                 output [15:0] sample);
 // 先复制符号位扩展到 18 位，再进行有符号加法，不能先做 16 位加法再扩展。
 // 三个 16 位数之和落在 -98304..98301 内，18 位有符号总线可以完整容纳。
 // $signed 明确比较/运算的符号属性，拼接本身并不自动成为有符号数。
 wire signed [17:0] melody_w=$signed({{2{melody[15]}},melody});
 wire signed [17:0] kick_w=$signed({{2{kick[15]}},kick});
 wire signed [17:0] snare_w=$signed({{2{snare[15]}},snare});
 wire signed [17:0] total=melody_w+kick_w+snare_w;
 // 越界时分别钳位到 0x7fff / 0x8000；范围内才取低 16 位。
 // 这种饱和限制避免越界总和截断后回绕到相反极性；临界值本身直接通过。
 assign sample=(total>18'sd32767)?16'h7fff:
               (total< -18'sd32768)?16'h8000:total[15:0];
endmodule
