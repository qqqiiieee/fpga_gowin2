// ============================================================
// keypad.v
// 按键输入：去抖 + 音符触发（按下=低电平，板载按键带上拉）
// 现在用板载按键占位，之后换成矩阵键盘/触摸/压力触发
// ============================================================
module keypad #(
    parameter NUM_KEYS  = 2,
    parameter BASE_NOTE = 7'd60   // 键0 → C4，键1 → G4（纯五度，协和）
)(
    input         clk,
    input         rst_n,
    input  [NUM_KEYS-1:0] keys,     // 按键（按下为低）
    input  [7:0]  velocity,         // 力度（来自传感器，默认固定值）
    output reg    note_on,          // 单周期脉冲
    output reg    note_off,
    output reg [6:0] note,
    output reg [7:0] vel_out
);
    // 按键 → 音符偏移（相对 BASE_NOTE）
    // 键0 = C4(+0)，键1 = G4(+7 纯五度)，两键齐按为协和音程
    function [6:0] note_offset;
        input integer k;
        begin
            case (k)
                0: note_offset = 7'd0;
                1: note_offset = 7'd7;
                default: note_offset = 7'd0;
            endcase
        end
    endfunction

    // ---- 去抖定时器：约 1ms 采样一次 ----
    reg [15:0] timer;
    reg        sample_tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            timer <= 16'd0;
            sample_tick <= 1'b0;
        end else begin
            sample_tick <= 1'b0;
            if (timer == 16'd27000) begin
                timer <= 16'd0;
                sample_tick <= 1'b1;
            end else
                timer <= timer + 16'd1;
        end
    end

    // ---- 采样 + 边沿检测 ----
    reg [NUM_KEYS-1:0] cur, prev;
    always @(posedge clk or negedge rst_n) begin : proc
        integer i;
        if (!rst_n) begin
            cur <= {NUM_KEYS{1'b1}};
            prev <= {NUM_KEYS{1'b1}};
            note_on <= 1'b0; note_off <= 1'b0;
            note <= 7'd0; vel_out <= 8'd0;
        end else begin
            note_on <= 1'b0;
            note_off <= 1'b0;
            if (sample_tick) begin
                prev <= cur;
                cur  <= keys;
                for (i = 0; i < NUM_KEYS; i = i + 1) begin
                    if (!cur[i] && prev[i]) begin   // 下降沿 = 按下
                        note_on  <= 1'b1;
                        note     <= BASE_NOTE + note_offset(i);
                        vel_out  <= velocity;
                    end
                    if (cur[i] && !prev[i]) begin   // 上升沿 = 释放
                        note_off <= 1'b1;
                        note     <= BASE_NOTE + note_offset(i);
                    end
                end
            end
        end
    end
endmodule
