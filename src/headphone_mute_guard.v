// 模块职责：识别诊断双键持续长按，给出有最大时长限制的纯零参考请求，
// 供下游静音/噪声对比；本模块只输出逻辑标志，不直接操作音频数据或板上PA_EN。
// 端口：clk 为系统时钟，rst_n 异步低有效；key_state 是已消抖的16位按键状态，
// 每位取1表示按下，bit14/15对应逻辑S15/S16；ghost 为键盘矩形歧义状态。
// mute_active 为持续有效的静音请求，不是单拍事件；复位后为0并允许首次触发。
// HOLD_CYCLES/MAX_CYCLES 单位均为clk周期，默认按27MHz计：双键稳定保持
// 13500000周期=0.5s才进入静音，进入后最多81000000周期=3s；两段分别计时。
// 无采样 clock enable，长按与窗口按每个 clk 计时；两参数须在1..2^27内，
// 使27位 timer 能计到门槛-1；本模块不会修正0/负数/超宽参数。
// 隐式状态：armed下等待长按 -> mute_active限时窗口 -> 未armed等待双键全松开。
// 结束窗口后不能因键卡住立即重触发，必须bit14/15同时松开才能重新武装。
// Pure-zero reference requires a deliberate hold, and cannot latch permanent
// silence if a matrix combination sticks. Wait for all shortcut keys released
// before allowing a second reference interval. Does not disable board PA_EN.
module headphone_mute_guard #(parameter HOLD_CYCLES=13500000,parameter MAX_CYCLES=81000000)(
 input clk,input rst_n,input [15:0] key_state,input ghost,output reg mute_active);
 reg [26:0] timer;reg armed;
  // 必须整个键盘恰好只有S15/S16按下，且无ghost；额外任何键都会破坏chord。
 wire chord=(key_state==16'hc000) && !ghost;
  // 同一计数器在长按成立时清0，重新计静音窗口，MAX不包含前面的HOLD时间。
  // 任意chord中断或窗口超时立即撤销请求，armed保持0直到快捷键全部释放。
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin timer<=0;armed<=1;mute_active<=0;end
   else if(mute_active) begin
     if(!chord || timer>=MAX_CYCLES-1) begin mute_active<=0;timer<=0;end
     else timer<=timer+1'b1;
    // 重新武装只检查两枚快捷键全松开，允许其他普通键仍按着；
    // 但真正开始下一次长按仍须满足上方完整chord条件。
   end else if((key_state & 16'hc000)==0) begin armed<=1;timer<=0;end
   else if(armed && chord) begin
      // 使用>=门槛，持续chord到HOLD个周期后启动；启动同时撤销armed，
      // 所以即使MAX超时而两键还在按，也不会立刻再进入一个静音窗口。
     if(timer>=HOLD_CYCLES-1) begin mute_active<=1;armed<=0;timer<=0;end
     else timer<=timer+1'b1;
    // 未凑齐chord、出现ghost或仍未重新武装时，不累计部分长按时间。
   end else timer<=0;
 end
endmodule
