// 模块职责：仅把 A2 变成总音量、A3 变成旋律音高控制量，分别平滑并跟踪新鲜度。
// A0/A1 属于压力模块，本模块忽略；音高应用到哪些声部由下游决定，这里不合成声音。
// 端口：clk 为系统时钟，rst_n 异步低有效；adc_valid 为完整ADC样本单拍，
// adc_channel 为0..3通道号，adc_data 为ADS1115的16位原始码。
// 按 ±4.096V 量程解释，125uV/码；3.3V实际最大约26400码。负码在此置0，
// 正值不先限幅，映射后的 position 在255限幅。
// volume 是0..255的无符号音量控制量；pitch 是9位有符号控制量，数值范围
// -128..127，中心附近为0，不能直接当半音数。下游 wavetable_synth 使用
// inc变化=floor(inc/2048)*pitch，因此频率倍率约为1+pitch/2048。
// ready 仅表示A2和A3都曾收到且仍在新鲜期内；过期不清最后的volume/pitch。
// STALE_CYCLES 单位为clk周期，默认27MHz时6750000周期=250ms，逐通道独立计时。
// 该参数须为正且不大于2^24，年龄需能保存饱和值；代码不自动钳位。
// adc_valid 是控制更新使能，年龄仍每 clk 运行；无另一个输出 valid 事件。
// 复位给默认 volume=160、pitch=0、ready=0；首个/过期后的首个通道样本直接
// 初始化滤波，其后约每样本1/4距离跟随。此处没有独立状态机，按样本与年龄更新。
// A2 controls master volume; A3 controls melody bend. Drums keep their pitch.
// Freeze the last complete controls across transient I2C faults; defaults work
// without ADC. Per-channel expiry prevents an old validity mask masking faults.
module slider_controls #(parameter STALE_CYCLES=6750000)(
 input clk,input rst_n,input adc_valid,input [1:0] adc_channel,input [15:0] adc_data,
 output reg [7:0] volume,output reg signed [8:0] pitch,output ready);
 reg [15:0] filtered[0:1];reg [1:0] seen;
 reg [23:0] age[0:1];integer k;
  // idx=通道最低位：A2(2)=0、A3(3)=1；只在 adc_channel>=2 时使用更新。
 wire idx=adc_channel[0];
 wire [15:0] raw=adc_data[15]?16'd0:adc_data;
 wire [15:0] difference=(raw>=filtered[idx])?raw-filtered[idx]:filtered[idx]-raw;
  // 距离>=4码时走floor(距离/4)的一阶跟随；不足4码直接补齐，避免残差卡住。
 wire [15:0] change=(difference<4)?difference:(difference>>2);
  // seen 为0时不使用旧 filtered，直接接收 raw，适用于上电及失效后恢复。
 wire [15:0] next_filtered=!seen[idx]?raw:
    ((raw>=filtered[idx])?filtered[idx]+change:filtered[idx]-change);
  // scaled=5*next_filtered，19位足以保存5*65535；不用把ADC满量程32768
  // 当成3.3V滑条满量程。position=min(255,floor(5*next_filtered/512))。
  // 130560=255*512，对应26112码(3.264V)即到顶；3.3V约26400码也输出255。
 wire [18:0] scaled={next_filtered,2'b00}+next_filtered;
 wire [7:0] position=(scaled>=19'd130560)?8'd255:scaled[16:9];
  // 两通道 seen 与归约；只有一条滑条在更新不会掩盖另一条的超时。
 assign ready=(&seen);
  // 年龄按每个系统clk递增而非ADC样本计数，达到上限后饱和，防止回绕误有效。
  // 一个样本分支只刷新对应通道，因此A2/A3的滤波和失效计时互不混用。
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     seen<=0;volume<=160;pitch<=0;
     for(k=0;k<2;k=k+1) begin filtered[k]<=0;age[k]<=STALE_CYCLES;end
   end else begin
     for(k=0;k<2;k=k+1) begin
       if(age[k]<STALE_CYCLES) age[k]<=age[k]+1'b1;
       if(age[k]==STALE_CYCLES-1) seen[k]<=0;
     end
     if(adc_valid && adc_channel>=2) begin
        // 此处对seen/age的赋值在过期检测之后：若同拍到新样本，刷新结果优先。
        // 不直接检测I2C fault；是否过期只取决于本通道多久没有完整有效样本。
       filtered[idx]<=next_filtered;seen[idx]<=1;age[idx]<=0;
       if(!idx) volume<=position;
        // A3 position=124..132（含端点）设置中心死区，抑制中心抖动。
        // 其余将0..255先补0扩为正的9位有符号数，再减128，避免8位符号误解；
        // 死区之外靠近中心的非零输出从-5或+5开始，两端为-128与+127。
       else pitch<=(position>=124 && position<=132)?9'sd0:
                    $signed({1'b0,position})-9'sd128;
     end
   end
 end
endmodule
