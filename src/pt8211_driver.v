// ============================================================
// pt8211_driver.v
// PT8211 音频 DAC 串行输出驱动（类 I2S，LSBJ 格式）
// 27MHz 输入，位时钟 = 27MHz/16 = 1.6875MHz，采样率 ≈ 52.7kHz
// 一帧 32 bit（左 16 + 右 16），左右声道输出同一采样（单声道）
// ============================================================
module pt8211_driver(
    input         clk,       // H11, 27MHz
    input         rst_n,     // 复位（低有效）
    input  [15:0] sample,    // 有符号 16bit 音频采样
    output        bck,       // N15 位时钟
    output        ws,        // P16 声道切换
    output        din,       // P15 串行数据
    output        fs_tick    // 采样率脉冲（每帧一次，cnt==0）
);
    reg [8:0] cnt;           // 0..511
    reg [15:0] sr;           // 移位寄存器

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= 9'd0;
            sr  <= 16'd0;
        end else begin
            if (cnt == 9'd511)
                cnt <= 9'd0;
            else
                cnt <= cnt + 9'd1;

            if (cnt == 9'd0 || cnt == 9'd256)
                sr <= sample;                        // 每个声道开头装载
            else if (cnt[3:0] == 4'd0)
                sr <= {sr[14:0], 1'b0};              // 每个 bit 开头左移
        end
    end

    assign fs_tick = (cnt == 9'd0);
    assign bck = cnt[3];
    assign ws  = cnt[4];
    assign din = sr[15];
endmodule
