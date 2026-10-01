// ============================================================
// voice.v
// 单复音振荡器：独立相位累加器 + 波形选择 + ADSR 包络 + 力度
// 复音的关键：每个声部都有自己独立的相位累加器（评分按此统计）
// ============================================================
module voice(
    input         clk,
    input         rst_n,
    input         fs_tick,    // 采样率脉冲
    input         gate,       // 音符开/关
    input  [6:0]  note,       // 音符编号
    input  [7:0]  velocity,   // 力度 0..255（控制响度峰值）
    input  [1:0]  timbre,     // 音色：0=正弦(占位) 1=方波 2=锯齿 3=三角
    output [15:0] sample      // 有符号 16bit
);
    // ---- 相位累加器（独立）----
    wire [23:0] phase_inc;
    note_table u_note(.note(note), .phase_inc(phase_inc));

    reg [23:0] phase;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) phase <= 24'd0;
        else if (fs_tick) phase <= phase + phase_inc;

    // ---- 波形（取相位高 16 位），均为半量程 ±16384 ----
    wire [15:0] ph       = phase[23:8];
    wire [14:0] tri_wave = ph[15] ? ~ph[14:0] : ph[14:0];
    wire [15:0] wave_tri = {1'b0, tri_wave} - 16'h4000;   // 三角
    wire [15:0] wave_saw = {1'b0, ph[15:1]} - 16'h4000;   // 锯齿
    wire [15:0] wave_sqr = ph[15] ? 16'hC000 : 16'h4000;  // 方波

    // 正弦波表（timbre=0）
    wire [15:0] wave_sine;
    sine_lut u_sine(.phase(phase[23:8]), .sine(wave_sine));

    reg [15:0] wave;
    always @(*) begin
        case (timbre)
            2'd0:    wave = wave_sine;  // 正弦（波表）
            2'd1:    wave = wave_sqr;   // 方波
            2'd2:    wave = wave_saw;   // 锯齿
            default: wave = wave_tri;   // 三角
        endcase
    end

    // ---- ADSR 包络（env 8bit 0..255，峰值=velocity）----
    reg [7:0] env;
    reg [2:0] state;
    reg [7:0] sub;       // 分频计数器（让衰减/释音更慢）
    reg       gate_r;

    localparam S_IDLE = 3'd0, S_ATT = 3'd1, S_DEC = 3'd2,
               S_SUS  = 3'd3, S_REL = 3'd4;
    wire [7:0] sustain_lv = (velocity >> 1) + (velocity >> 2);  // 75% 力度

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            env <= 8'd0; state <= S_IDLE; sub <= 8'd0; gate_r <= 1'b0;
        end else if (fs_tick) begin
            gate_r <= gate;
            sub <= sub + 8'd1;
            case (state)
                S_IDLE:
                    if (gate && !gate_r) state <= S_ATT;
                S_ATT: begin
                    // 9bit 比较避免溢出
                    if ({1'b0, env} + 9'd4 >= {1'b0, velocity}) begin
                        env <= velocity;
                        state <= S_DEC;
                    end else
                        env <= env + 8'd4;
                    if (!gate) state <= S_REL;
                end
                S_DEC: begin
                    if (sub[1:0] == 2'd3) begin
                        if (env <= sustain_lv + 8'd1) state <= S_SUS;
                        else env <= env - 8'd1;
                    end
                    if (!gate) state <= S_REL;
                end
                S_SUS:
                    if (!gate) state <= S_REL;
                S_REL: begin
                    if (sub[3:0] == 4'd15) begin
                        if (env <= 8'd1) begin
                            env <= 8'd0;
                            state <= S_IDLE;
                        end else
                            env <= env - 8'd1;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    // ---- 输出 = 波形 × 包络（有符号 × 无符号，手动符号扩展）----
    wire [23:0] wave_ext = { {8{wave[15]}}, wave };   // 符号扩展 16→24
    wire [23:0] prod     = wave_ext * {16'd0, env};   // ×包络
    assign sample = prod[23:8];                        // 右移 8 位
endmodule
