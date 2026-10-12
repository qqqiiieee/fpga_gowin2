// 职责：以 Q8 状态平滑音量/弯音目标，按平滑增益缩放16位二补码 PCM。
// clk=27MHz，rst_n 异步低有效；fs_tick 是同域93750Hz控制更新使能。
// gain_q/pitch_q 仅在 fs_tick 更新，sample_out 则每个 clk 寄存；没有输出 valid。
// sample_in/out 位图范围[-32768,32767]，0为静音；volume 为无单位0..255。
// pitch_in/pitch_smooth 为9位有符号弯音码，端口范围[-256,255]，不是Hz/半音。
// volume 目标先乘255，取 Q8 高位作增益后再除256，不是直接输出百分数。
// 无模块参数；复位增益状态为45900个 Q8 单位，弯音与PCM输出为0。
// 平滑减少控制目标直接阶跃；此处只说明数字递推，不保证模拟输出无噪声。
module audio_controls(input clk,input rst_n,input fs_tick,input [15:0] sample_in,
    input [7:0] volume,input signed [8:0] pitch_in,
    output signed [8:0] pitch_smooth,output reg [15:0] sample_out);
    reg signed [17:0] gain_q;
    reg signed [18:0] pitch_q;
    // 原 expression=255，所以 volume*255 精确等于 (volume<<8)-volume。
    // 不能替换成 volume<<8，否则会改变所有音量的实际增益。
    wire [15:0] gain_product={volume,8'b0}-{8'd0,volume};
    wire signed [17:0] gain_target=$signed({2'b00,gain_product});
    wire signed [18:0] pitch_target=$signed(pitch_in)<<<8;
    wire signed [18:0] gain_distance=$signed(gain_target)-$signed(gain_q);
    wire signed [19:0] pitch_distance=$signed(pitch_target)-$signed(pitch_q);
    wire signed [18:0] gain_step=gain_distance>>>8;
    wire signed [19:0] pitch_step=pitch_distance>>>8;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin gain_q<=18'sd45900;pitch_q<=0;end
        else if(fs_tick) begin
            // 正的小差值右移可能为 0，补 +1 避免停在目标之前。
            // 负数仍算术右移，保持原来的取整方向与收敛行为。
            gain_q<=gain_q+((gain_step==0 && gain_distance!=0)?19'sd1:gain_step);
            pitch_q<=pitch_q+((pitch_step==0 && pitch_distance!=0)?20'sd1:pitch_step);
        end
    end
    assign pitch_smooth=pitch_q>>>8;
    // sample_in 按二补码解释，增益前补 0 以免大音量被当成负数。
    // 乘积算术右移 8 位等于除以 256，并保留原输出寄存器时序。
    wire signed [32:0] scaled=$signed(sample_in)*$signed({1'b0,gain_q[15:8]});
    always @(posedge clk or negedge rst_n)
        if(!rst_n) sample_out<=0;else sample_out<=scaled>>>8;
endmodule
