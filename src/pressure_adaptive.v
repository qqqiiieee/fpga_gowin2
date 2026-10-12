// 模块职责：仅处理 A0/A1 两路压力，学习静止负载基线，检测击打，
// 并在压力相对峰值充分释放后重新武装；持续按住仅触发一次。
// 端口：clk 为系统时钟，rst_n 为异步低有效复位；ready 为上层允许校准/检测。
// adc_valid 为样本脉冲，adc_channel=0/1 分别对应压力0/1；A2音量/A3音高被忽略。
// adc_data 为 ADC 原始16位码：按 ADS1115 ±4.096V、125uV/码解释，
// 3.3V 实际最大约26400码；符号位为1时本模块按0处理，不在此裁剪正值上限。
// 这里只比较原始码差，不输出 kg；实际力/质量需传感器与前端标定。
// hit0/hit1 为一个 clk 周期的击打脉冲，velocity0/1 为随上次击打保持的
// 8位力度控制量，不是电压/速度物理单位。calibrated/armed_status 的 bit0/1
// 分别对应A0/A1；校准完成与可接收下一击打是两个独立状态。
// 参数单位：CAL_SAMPLES、QUIET_SAMPLES、冷却计数均为各自通道的有效样本数；
// ON/STRONG_ON/OFF/RISE_COUNT 均为ADC码差，不是时钟周期或毫伏数。
// 默认门槛：192码=24mV、384码=48mV、96码=12mV、32码=4mV，均为增量。
// CAL_SAMPLES 默认16，6位计数要求1..64；QUIET_SAMPLES 默认8，
// 需在1..63内才能以6位 stable 保存饱和样本数，参数没有自动限幅。
// ON/STRONG_ON/OFF/RISE 默认192/384/96/32，按非负ADC增量门槛使用。
// adc_valid 是有效通道处理使能，ready 与 hit 清零仍每 clk 检查；
// 校准/冷却实际耗时取决于A0/A1各自采样间隔。
// 状态流程：ready低取消校准 -> 16个样本学习基线 -> armed -> hit锁止 ->
// 满足释放阈值且冷却接近结束后 armed。复位清所有历史；ready低仅清标志/计数。
// Calibrate the resting load instead of requiring raw ADC <48mV forever.
// A0/A1: capture light fast attacks, rearm on a substantial falling release,
// and retain one strike for a steady sustained load. Values at +/-4.096V.
module pressure_adaptive #(
 parameter CAL_SAMPLES=16,parameter ON_COUNT=192,parameter STRONG_ON_COUNT=384,
 parameter OFF_COUNT=96,parameter RISE_COUNT=32,parameter QUIET_SAMPLES=8
)(input clk,input rst_n,input ready,input adc_valid,input [1:0] adc_channel,
 input [15:0] adc_data,output reg hit0,output reg hit1,
 output reg [7:0] velocity0,output reg [7:0] velocity1,
 output [1:0] calibrated,output [1:0] armed_status);
 reg [1:0] cal_done,armed;
 reg [15:0] baseline[0:1],previous[0:1],peak[0:1];
 reg [5:0] calibration[0:1],stable[0:1];reg [1:0] cooldown[0:1];
  // idx 只在 adc_channel<2 的有效样本分支用于更新，A0=0、A1=1；
  // below-baseline 的差值截为0，防止无符号减法下溢变成一次巨大击打。
 wire idx=adc_channel[0];wire [15:0] raw=adc_data[15]?16'd0:adc_data;
 wire [15:0] delta=(raw>baseline[idx])?raw-baseline[idx]:16'd0;
  // rise 为本通道相邻有效样本的正向增量；change 为同两样本的绝对变化量。
  // previous 在本次边沿才写入，所以组合计算使用的是上一有效样本。
 wire [15:0] rise=(raw>previous[idx])?raw-previous[idx]:16'd0;
 wire [15:0] change=(raw>previous[idx])?raw-previous[idx]:previous[idx]-raw;
 wire [15:0] peak_delta=(peak[idx]>baseline[idx])?peak[idx]-baseline[idx]:16'd0;
  // release_delta=max(floor((峰值-基线)/4), OFF_COUNT)。判断的是释放后
  // 相对基线还剩多少增量，不是“本次下降了峰值的1/4”，也不要求 raw 接近0。
  // 未武装期间峰值可继续升高；同拍刷新 peak 时此式仍使用刷新前峰值。
 wire [15:0] release_delta=((peak_delta>>2)>OFF_COUNT)?(peak_delta>>2):OFF_COUNT;
  // 轻击须同时超过基线门槛且上升够快；强击只须超过更高的基线门槛，
  // 不要求 rise，适应已经较慢抬升到较强压力的输入。
 wire attack=(delta>=ON_COUNT && rise>=RISE_COUNT) || delta>=STRONG_ON_COUNT;
  // strength=min(255,floor(delta/16))；4080=255*16，是力度限幅点。
 wire [7:0] strength=(delta>=4080)?8'd255:delta[11:4];
  // 击打力度=96+floor(strength/2)+floor(strength/8)，理论范围96..254；
  // 两次右移各自截断，不等价于先乘5再除8，且此控制量不限定在MIDI的0..127。
 wire [7:0] hit_velocity=8'd96+(strength>>1)+(strength>>3);
 wire [15:0] base_distance=(raw>baseline[idx])?raw-baseline[idx]:baseline[idx]-raw;
  // 校准不是算术平均：首样本直接置基线，之后每次向 raw 移动距离的1/4；
  // 小于4码时直接补齐距离，避免整数右移截断后永远差最后几码。
 wire [15:0] cal_step=(base_distance<4)?base_distance:(base_distance>>2);
  // 武装时对小正增量缓慢跟随，步长约距离的1/32；小于32码时一步1码。
 wire [15:0] slow_step=(base_distance<32)?16'd1:(base_distance>>5);
 assign calibrated=cal_done;assign armed_status=armed;
 integer i;
  // 两通道共用此处理器但历史/校准/峰值/冷却完全独立，仅有效通道推进计数。
  // 每拍先清 hit，其他输出保持；ready 低时不接受样本或产生新击打。
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     cal_done<=0;armed<=0;hit0<=0;hit1<=0;velocity0<=96;velocity1<=96;
     for(i=0;i<2;i=i+1) begin baseline[i]<=0;previous[i]<=0;peak[i]<=0;calibration[i]<=0;stable[i]<=0;cooldown[i]<=0;end
   end else begin
     hit0<=0;hit1<=0;
     if(!ready) begin
        // 不清 baseline/previous/peak；重新 ready 后首个校准样本重置该通道基线。
       cal_done<=0;armed<=0;
       for(i=0;i<2;i=i+1) begin calibration[i]<=0;stable[i]<=0;cooldown[i]<=0;end
     end else if(adc_valid && adc_channel<2) begin
       previous[idx]<=raw;
       if(!cal_done[idx]) begin
          // calibration=0 的首样本也算一个，默认第16个有效样本置 cal_done/armed。
          // 完成校准的这一样本仍在校准分支，不会同拍成为击打。
         if(calibration[idx]==0) baseline[idx]<=raw;
         else baseline[idx]<=(raw>=baseline[idx])?baseline[idx]+cal_step:baseline[idx]-cal_step;
         if(calibration[idx]>=CAL_SAMPLES-1) begin cal_done[idx]<=1;armed[idx]<=1;end
         else calibration[idx]<=calibration[idx]+1'b1;
         peak[idx]<=raw;stable[idx]<=0;
       end else if(!armed[idx]) begin
          // 击打锁止期间只跟踪峰值和冷却，不向上跟随基线，防止长按自动重复。
         if(raw>peak[idx]) peak[idx]<=raw;
         if(cooldown[idx]!=0) cooldown[idx]<=cooldown[idx]-1'b1;
         // A single clearly released sample permits the next real strike.
         if(delta<=release_delta && cooldown[idx]<=1) begin
            // cooldown 默认由2开始，按本通道样本递减；条件读取旧值，旧值1
            // 时允许重新武装，同时减为0。只需一个满足释放条件的样本。
            // 本分支仅武装，不同拍再击打；下一样本才有机会进入 attack 分支。
           armed[idx]<=1;stable[idx]<=0;
           // The released level can still be above the old baseline. Make it
           // the new rest level so a residual plateau cannot fire a second hit.
           baseline[idx]<=raw;
         end
       end else if(attack && cooldown[idx]==0) begin
          // 触发时锁止通道、锁存峰值并启动两样本冷却，力度在此时一次性计算。
         armed[idx]<=0;peak[idx]<=raw;stable[idx]<=0;cooldown[idx]<=2;
         if(idx==0) begin hit0<=1;velocity0<=hit_velocity;end
         else begin hit1<=1;velocity1<=hit_velocity;end
       end else begin
         if(cooldown[idx]!=0) cooldown[idx]<=cooldown[idx]-1'b1;
         // Stable new resting loads are relearned ONLY while armed. Never
         // move the baseline up under a latched held press and auto-repeat.
         if(change<=RISE_COUNT) begin
            // 已武装且没有触发攻击时，连续稳定样本达 QUIET_SAMPLES 学习新负载；
            // 稳定指相邻样本变化不超过32码，允许缓慢变化，并非必须完全相等。
           if(stable[idx]<QUIET_SAMPLES) stable[idx]<=stable[idx]+1'b1;
           if(stable[idx]>=QUIET_SAMPLES-1) baseline[idx]<=raw;
         end else stable[idx]<=0;
          // 后两条基线赋值在源码中更靠后，条件满足时优先于上方稳定学习赋值：
          // 低于基线直接下调；0<delta<=OFF_COUNT 时采用 slow_step 缓慢上调。
          // 因此小正增量即使已稳定，也仍走慢跟随，不应描述成一律直接置 raw。
         if(raw<baseline[idx]) baseline[idx]<=raw;
         else if(delta!=0 && delta<=OFF_COUNT) baseline[idx]<=baseline[idx]+slow_step;
       end
     end
   end
 end
endmodule
