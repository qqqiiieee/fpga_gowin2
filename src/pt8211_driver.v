// 作用：把单声道 16 位二补码 PCM 复制到 PT8211 的两个通道并串行发送。
// sample 是已经准备好的 PCM 位图，0 为静音；串行器按位发送，不重新解释/缩放符号。
// clk 为 27 MHz 主时钟，rst_n 为低有效异步复位；复位清零计数、帧缓存、移位器
// 和 BCLK。这里不创建供内部 always 使用的新时钟，所有寄存器均由 clk 驱动。
// 每 9 个主时钟发送 1 bit，BCLK = 27 MHz/9 = 3 MHz；每个立体声帧 32 bit，
// Fs = 3 MHz/32 = 93.75 kHz。fs_tick 是每 288 个主时钟一次的域内采样使能。
// PT8211 使用 16 bit 右对齐格式：MSB 先发、LSB 位于当前 WS 半帧末尾。
// 当前每半帧恰好 16 bit，WS 翻转后即准备下一字的 MSB，不插入 I2S 的一位延迟。
// 因此不能将本模块当作 MAX98357 的标准 I2S 驱动；PT8211 接口只需 BCLK、WS、DIN，
// 无需额外 MCLK。本模块也没有 MCLK 输出。
// 无模块参数；分频和16位半帧固定。无额外 valid，整帧装载事件就是 fs_tick。
module pt8211_driver(input clk, input rst_n, input [15:0] sample,
    output bck, output ws, output din, output fs_tick);
    // div_count 在 0..8 间循环，bit_index 为 0..31 的整帧位序号。
    // frame_sample 保存当前帧 PCM；sr 为 MSB 先出的 16 位移位寄存器。
    // WS=bit_index[4]：低、高两个半帧各 16 bit；此处只说明电平，不假定外部声道路由。
    reg [4:0] div_count, bit_index;
    reg [15:0] frame_sample, sr;
    wire boundary = (div_count == 8);
    reg bck_r;
    assign bck = bck_r;
    assign ws = bit_index[4];
    assign din = sr[15];
    // 组合使能在 div_count=8 且 bit_index=31 时为高，供接下来的 clk 上升沿采样。
    // 它不是独立采样时钟，也不是每通道一次的脉冲；每整帧只出现一次。
    assign fs_tick = boundary && (bit_index == 31);
    // 分频计数为 3 的 clk 沿拉高 BCLK，计数为 8 的沿拉低 BCLK 并换数据。
    // 因为除以奇数 9，正常 BCLK 高电平占 5 个 clk 周期、低电平占 4 个 clk 周期。
    // DIN/WS 在 BCLK 下降边界更新，在下一个 BCLK 上升沿前已经稳定。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_count<=0; bit_index<=0; frame_sample<=0; sr<=0; bck_r<=0;
        end else if (boundary) begin
            div_count<=0; bit_index<=bit_index+1'b1; bck_r<=0;
            // 旧位序号 31：结束整帧，锁存 sample，同时装载下一帧第一个通道。
            // 旧位序号 15：结束第一个半帧，再装载同一 frame_sample 给第二个通道。
            // 其余下降边界左移 1 bit，下一次上升沿发送新的 sr[15]，总计各发送 16 bit。
            // 同沿更新的其他模块寄存器按非阻塞赋值规则不会成为此处立即可见的新 sample。
            // 启动时缓存为零，首次整帧边界以前发送复位后的零数据。
            if (bit_index==31) begin frame_sample<=sample; sr<=sample; end
            else if (bit_index==15) sr<=frame_sample;
            else sr<={sr[14:0],1'b0};
        end else begin
            div_count<=div_count+1'b1;
            if (div_count==3) bck_r<=1;
        end
    end
endmodule
