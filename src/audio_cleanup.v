// 作用：可旁路的一阶低通，保留 Q8 滤波历史，输出 16 位二补码 PCM。
// sample_in/sample_out 是有符号 PCM 位图；0 为静音，数值范围为 -32768..32767。
// clk 是工程 27 MHz 主时钟；tick 是其域内采样使能，不是另一个时钟。
// 工程每 288 个主时钟形成一个 93.75 kHz 音频帧；本实例 tick 接 frame_done，
// 与帧完成时刻同步；无 tick 且无 quiet/复位时保持滤波状态和输出。
// 与上游 dc_blocker 同沿 tick 时，此处读到其更新前的 sample_out，这是寄存器级的采样延迟。
// rst_n 低有效异步清零；quiet 是每个主时钟检查的同步清零，优先级高于 tick。
// LOWPASS_ENABLE 默认1，按布尔参数使用（0旁路、非0允许）；enable 是运行时开关。
// 二者都为真才输出滤波结果；没有输出 valid，采样结果在 tick 更新后保持。
// 下面按实际系数、Q8 量化与有符号除法说明；保留小数可减少整数递推的舍入误差，
// 但不是无限精度。精确截止频率需分析离散响应，此处不推断实际听感或截止 Hz。
module audio_cleanup #(parameter LOWPASS_ENABLE=1)(
 input clk,input rst_n,input tick,input quiet,input enable,input [15:0] sample_in,
 output reg [15:0] sample_out);
 // state_q 为 Q8 状态：PCM 整数乘 256 后进入同一尺度，保留 8 个小数位。
 // 32 位有符号 target_q/difference 为缩放和正负输入间的差值提供运算空间。
 reg signed [31:0] state_q;
 wire signed [31:0] target_q=$signed(sample_in)*32'sd256;
 wire signed [31:0] difference=target_q-state_q;
 // 理想递推为 state += (target-state)/2，即每次向输入走剩余差值的一半。
 // 有符号 /2 截去小数并向零取整，例如 -3/2=-1；>>>1 则会得到 -2。
 // 因而这里不能把除法直接替换为算术移位并声称负数行为完全相同。
 wire signed [31:0] half_difference=difference/32'sd2;
 // 当 Q8 差值仅剩 +1 或 -1 时，/2 会变零；强制步进同符号的 1，最终到达目标。
 // 这消除残差停滞，但仍是离散定点递推，不能据此宣称无任何量化误差。
 wire signed [31:0] step=(half_difference==0 && difference!=0)?
    (difference[31]?-32'sd1:32'sd1):half_difference;
 wire signed [31:0] next_state=state_q+step;
 // 名称 rounded_sample 的实际运算是 /256 向零截断，不是四舍五入。
 // 保留 Q8 后再截断可让小幅正负结果都趋向 0；与 >>>8 的负数向下取整不同。
 wire signed [31:0] rounded_sample=next_state/32'sd256;
 // quiet 即使没有 tick 也清空历史和输出，用于结束尾音后建立确定的数字零。
 // 旁路只选择 sample_in 作为输出：每个 tick 仍更新 state_q，重新启用时有持续历史。
 // 滤波路径取 rounded_sample[15:0]，本模块没有额外的饱和比较器。
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin state_q<=0;sample_out<=0;end
   else if(quiet) begin state_q<=0;sample_out<=0;end
   else if(tick) begin
     state_q<=next_state;
     sample_out<=(LOWPASS_ENABLE && enable)?rounded_sample[15:0]:sample_in;
   end
 end
endmodule
