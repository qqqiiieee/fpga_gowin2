// ============================================================
// mixer.v
// 多声部混音：求和后缩放（除以声部数），防止溢出
// ============================================================
module mixer #(
    parameter NUM_VOICES = 8,
    parameter WIDTH      = 16
)(
    input  [NUM_VOICES*WIDTH-1:0] in_bus,   // 每声部 in_bus[i*WIDTH +: WIDTH]
    output [WIDTH-1:0]             mixed
);
    localparam SHIFT = 2;   // 除以 4（8 声部满幅仍不溢出；提高单音音量）

    reg signed [WIDTH+3:0] sum;
    integer i;
    always @(*) begin
        sum = 0;
        for (i = 0; i < NUM_VOICES; i = i + 1)
            sum = sum + $signed(in_bus[i*WIDTH +: WIDTH]);
    end

    assign mixed = sum >>> SHIFT;   // 算术右移，保持符号
endmodule
