`timescale 1ns/1ps
// 实时噪声镲，无录音/ROM：23位LFSR + 一阶差分高通 + 单调衰减包络。
// OPEN=0闭镲，OPEN=1开镲；按本工程fs_tick=93750Hz，最长100/600ms。
// clk为主时钟，fs_tick为同域单clk采样使能；sample为16位二补码PCM位图。
// hit在任意clk可捕获，采样间保存最新力度；同沿hit优先于缓存。
// velocity=0只消费事件而不复触发；busy为活动或待消费事件，并非PCM非零。
// clear同步立即清静音、尾音和待触发事件，优先于hit和fs_tick；rst_n异步复位。
module hat_voice #(
    parameter integer OPEN = 0
)(
    input wire clk, rst_n, fs_tick, clear, hit,
    input wire [7:0] velocity,
    output reg [15:0] sample,
    output wire busy
);
    localparam [22:0] NOISE_SEED = 23'h5a31c7;
    localparam integer DECAY_SHIFT = OPEN ? 13 : 10;
    localparam [15:0] VOICE_TICKS = OPEN ? 16'd56250 : 16'd9375;
    reg pending, active;
    reg [7:0] pending_velocity;
    reg [22:0] noise_lfsr;
    reg signed [15:0] previous_noise;
    reg [23:0] envelope_q8;
    reg [15:0] remaining;
    assign busy = active || pending;
    wire [7:0] event_velocity = hit ? velocity : pending_velocity;
    wire start_voice = (hit || pending) && event_velocity!=0;
    // x^23+x^18+1；非零种子不会落入全零锁死状态，每次有效采样更新一次。
    wire [22:0] noise_next = {noise_lfsr[21:0], noise_lfsr[22]^noise_lfsr[17]};
    wire signed [15:0] raw_noise = $signed({noise_next[14], noise_next[14:0]});
    wire signed [16:0] high_noise =
        $signed({raw_noise[15],raw_noise}) - $signed({previous_noise[15],previous_noise});
    wire [16:0] magnitude = high_noise[16] ? $unsigned(-high_noise) : $unsigned(high_noise);
    // 24位Q8包络：峰值velocity*65536，取高16位后的增益为velocity/256。
    // 每tick衰减floor(env/2^SHIFT)+1，避免小包络右移为零后无限残留。
    wire [23:0] drop = (envelope_q8 >> DECAY_SHIFT) + 24'd1;
    wire [23:0] envelope_next = envelope_q8>drop ? envelope_q8-drop : 24'd0;
    // 差分范围[-32767,32767]；幅值*增益/4，最大8159，远离16位溢出。
    // 先用无符号幅值缩放，再恢复正负，避免负数算术截断留下-1的直流尾巴。
    wire [32:0] product = magnitude * envelope_next[23:8];
    wire [15:0] pcm_magnitude = {1'b0,product[32:18]};
    wire [15:0] pcm = high_noise[16] ? (~pcm_magnitude + 16'd1) : pcm_magnitude;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending<=0; pending_velocity<=0; active<=0;
            noise_lfsr<=NOISE_SEED; previous_noise<=0;
            envelope_q8<=0; remaining<=0; sample<=0;
        end else if (clear) begin
            pending<=0; pending_velocity<=0; active<=0;
            noise_lfsr<=NOISE_SEED; previous_noise<=0;
            envelope_q8<=0; remaining<=0; sample<=0;
        end else begin
            if (hit) begin pending<=1; pending_velocity<=velocity; end
            if (fs_tick) begin
                pending<=0;
                if (start_voice) begin
                    active<=1; envelope_q8<={event_velocity,16'd0}; remaining<=VOICE_TICKS;
                    // 空闲起音清历史；复触发保留噪声相位，本沿保持PCM，下一采样
                    // 使用新包络，避免在一个tick里重复消费hit。
                    if (!active) begin
                        noise_lfsr<=NOISE_SEED; previous_noise<=0; sample<=0;
                    end
                end else if (active) begin
                    if (remaining<=16'd1 || envelope_next==0) begin
                        active<=0; envelope_q8<=0; remaining<=0; sample<=0;
                        noise_lfsr<=NOISE_SEED; previous_noise<=0;
                    end else begin
                        remaining<=remaining-16'd1; envelope_q8<=envelope_next;
                        noise_lfsr<=noise_next; previous_noise<=raw_noise; sample<=pcm;
                    end
                end else sample<=0;
            end
        end
    end
endmodule
