// ============================================================
// voice_allocator.v
// 复音分配器：把音符事件分配到 NUM_VOICES 个声部（轮转）
// 每个声部保存自己的音符、力度、门控，实现复音并发
// ============================================================
module voice_allocator #(
    parameter NUM_VOICES = 8
)(
    input         clk,
    input         rst_n,
    input         note_on,      // 单周期脉冲：新音符
    input         note_off,     // 单周期脉冲：释放音符
    input  [6:0]  note,         // 音符编号
    input  [7:0]  velocity,     // 力度
    output [NUM_VOICES-1:0]   gate,        // 每声部门控
    output [NUM_VOICES*7-1:0] note_bus,    // 每声部音符（note_bus[i*7 +: 7]）
    output [NUM_VOICES*8-1:0] vel_bus      // 每声部力度（vel_bus[i*8 +: 8]）
);
    reg [6:0] note_r [0:NUM_VOICES-1];
    reg [7:0] vel_r  [0:NUM_VOICES-1];
    reg [NUM_VOICES-1:0] gate_r;
    reg [7:0] ptr;    // 下一个可分配声部指针（轮转）

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            gate_r <= {NUM_VOICES{1'b0}};
            ptr    <= 8'd0;
            for (i = 0; i < NUM_VOICES; i = i + 1) begin
                note_r[i] <= 7'd0;
                vel_r[i]  <= 8'd0;
            end
        end else begin
            if (note_on) begin
                // 轮转分配到下一个声部
                note_r[ptr] <= note;
                vel_r[ptr]  <= velocity;
                gate_r[ptr] <= 1'b1;
                ptr <= (ptr == NUM_VOICES-1) ? 8'd0 : ptr + 8'd1;
            end
            if (note_off) begin
                // 释放所有演奏该音符的声部
                for (i = 0; i < NUM_VOICES; i = i + 1)
                    if (note_r[i] == note)
                        gate_r[i] <= 1'b0;
            end
        end
    end

    assign gate = gate_r;

    genvar g;
    generate
        for (g = 0; g < NUM_VOICES; g = g + 1) begin : gen_assign
            assign note_bus[g*7 +: 7] = note_r[g];
            assign vel_bus [g*8 +: 8] = vel_r[g];
        end
    endgenerate
endmodule
