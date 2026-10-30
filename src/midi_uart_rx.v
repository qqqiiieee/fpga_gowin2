`timescale 1ns/1ps
// 独立 MIDI 电平接收器：输入是 BMV51M001 的 3.3V、空闲高 RX，绝非 USB。
// 默认 27MHz / 31250baud / 8N1，恰好每位 864 拍。rx 经过两级同步，
// 在起始位中心复核低电平，再在各数据位及停止位中心采样，数据低位先到。
// data_valid/framing_error 都只持续一拍；坏停止位不提交 data。
// 坏帧/长低 break 后，必须连续看到一整位高电平才重新接收，避免把 break
// 尾部或零碎跳变当成新字节。此恢复要求发送方在坏帧后提供至少一位空闲高。
module midi_uart_rx #(
    parameter integer CLK_HZ = 27000000,
    parameter integer BAUD = 31250
)(
    input wire clk,
    input wire rst_n,
    input wire rx,
    output reg [7:0] data,
    output reg data_valid,
    output reg framing_error
);
    localparam integer BIT_CYCLES = (CLK_HZ + BAUD/2) / BAUD;
    localparam integer HALF_CYCLES = BIT_CYCLES / 2;
    localparam integer TIMER_BITS = (BIT_CYCLES <= 2) ? 1 : $clog2(BIT_CYCLES);
    localparam [2:0] IDLE=0, START=1, BITS=2, STOP=3, RECOVER=4;
    (* syn_preserve = 1, async_reg = "true" *) reg rx_meta, rx_sync;
    reg [2:0] state, bit_index;
    reg [TIMER_BITS-1:0] timer;
    reg [7:0] shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            bit_index <= 0;
            timer <= 0;
            shift <= 0;
            data <= 0;
            data_valid <= 0;
            framing_error <= 0;
        end else begin
            data_valid <= 0;
            framing_error <= 0;
            case (state)
                IDLE: if (!rx_sync) begin
                    timer <= HALF_CYCLES-1;
                    state <= START;
                end
                START: if (timer != 0) timer <= timer-1'b1;
                else if (rx_sync) state <= IDLE; // 半位之前结束的毛刺不算帧。
                else begin
                    timer <= BIT_CYCLES-1;
                    bit_index <= 0;
                    state <= BITS;
                end
                BITS: if (timer != 0) timer <= timer-1'b1;
                else begin
                    shift[bit_index] <= rx_sync;
                    timer <= BIT_CYCLES-1;
                    if (bit_index == 7) state <= STOP;
                    else bit_index <= bit_index+1'b1;
                end
                STOP: if (timer != 0) timer <= timer-1'b1;
                else if (rx_sync) begin
                    data <= shift;
                    data_valid <= 1;
                    state <= IDLE;
                end else begin
                    framing_error <= 1;
                    timer <= BIT_CYCLES-1;
                    state <= RECOVER;
                end
                RECOVER: if (!rx_sync) timer <= BIT_CYCLES-1;
                else if (timer != 0) timer <= timer-1'b1;
                else state <= IDLE;
                default: state <= RECOVER;
            endcase
        end
    end
endmodule
