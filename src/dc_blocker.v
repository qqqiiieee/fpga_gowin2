// 作用：用输入差分加带泄漏的反馈状态去除直流，输出为 16 位二补码 PCM。
// sample_in/sample_out 是承载有符号 PCM 位图的 16 位总线，0 表示静音。
// clk 为工程 27 MHz 主时钟；tick 是这个时钟域中的采样使能，不是独立时钟。
// 工程采样帧率为 93.75 kHz，每帧 288 个主时钟；本实例 tick 接 frame_done，
// 即合成帧完成脉冲，而非直接接 PT8211 的 fs_tick。无 tick 时寄存器保持。
// rst_n 为低有效异步复位，清零上一输入、反馈状态和输出；顶层还用 quiet 控制它。
// 固定系数由算术移位实现；下面说明代码系数、定点尺度和量化行为。
// 精确截止频率需由离散响应分析，不能只用连续时间近似推定；此处不作 Hz/听感承诺。
module dc_blocker(input clk,input rst_n,input tick,input [15:0] sample_in,
  output reg [15:0] sample_out);
    // previous 保存上一采样的整数 PCM；state 保存输出递推值的 Q8 表示。
    // Q8 在这里指保留 8 个小数位，即 256 个状态单位对应 1 个 PCM 整数单位。
    reg signed [15:0] previous;
    reg signed [31:0] state;
    // 17 位有符号差分覆盖两个 16 位 PCM 的最大差值，避免先在 16 位中回绕。
    wire signed [16:0] delta=$signed(sample_in)-$signed(previous);
    // 泄漏项为 state / 1024 的算术右移近似，理想反馈系数为 1 - 1/1024。
    // >>> 对有符号负数补符号位，丢弃低位时向负无穷取整；与有符号 / 的向零截断不同。
    // 当移位结果为零但 state 非零时，强制减去指向零的 1 个 Q8 单位，避免量化停滞。
    // 对负 state，>>>10 本来就可能得到 -1，所以下面的补偿分支并非对称舍入器。
    wire signed [31:0] decay=state>>>10;
    wire signed [31:0] decay_step=(decay==0 && state!=0)?(state[31]?-32'sd1:32'sd1):decay;
    // 递推：s[n] = 256*(x[n]-x[n-1]) + s[n-1] - decay_step。
    // 表达式在 32 位有符号上下文中计算；<<<8 对齐到 Q8，左移只改位权、不做舍入。
    // next_state>>>8 再转回整数 PCM，依然采用算术右移的负数舍入规则。
    wire signed [31:0] next_state=(delta<<<8)+state-decay_step;
    wire signed [31:0] wide=next_state>>>8;
    // 仅在 tick 更新差分历史和 Q8 反馈。输出饱和只作用于 PCM，state 不被钳位。
    // 无 tick 时 sample_out 保持上一采样值；复位优先于 tick。
    always @(posedge clk or negedge rst_n) begin
      if(!rst_n) begin previous<=0;state<=0;sample_out<=0;end
      else if(tick) begin
        previous<=sample_in;state<=next_state;
        // 比较宽有符号结果后钳位到 [-32768,32767]，范围内才取低 16 位。
        sample_out<=wide>32767?16'h7fff:(wide < -32768?16'h8000:wide[15:0]);
      end
    end
endmodule
