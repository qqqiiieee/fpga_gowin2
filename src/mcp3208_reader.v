// MCP3208 单端轮询器；全部逻辑使用 clk，sclk 仅作为外部 SPI 引脚。
// 已核对 Microchip DS21298E 第5节、第6.1节及图6-1：SPI mode 0，
// DIN 在上升沿被 ADC 接收，DOUT 在下降沿更新，主机在上升沿接收。
// 官方资料：https://ww1.microchip.com/downloads/aemDocuments/documents/APID/ProductDocuments/DataSheets/21298e.pdf
// 24位发送序列：00000, Start=1, SGL=1, D2,D1,D0, 14个0。
// 第12个上升沿是空位；下降沿12推出B11，上升沿13..24接收B11..B0。
// SCLK_DIV 是半周期的系统时钟数；27MHz/（2*27）=500kHz。
// POLL_CYCLES 是事务开始到下次事务开始的最短周期数，包括传输时间；
// 27000对应1kHz，5400对应5kHz。周期过短时由完整事务和CS高间隔限速。
// channel 只在 CS 拉低时锁存；sample_valid 仅在24个完整时钟后脉冲一拍。
// MISO 是相对本模块所发 SCLK 定时的同步串行输入，在采样沿前应已稳定。
// 本器件无应答/存在检测协议；恒0、恒1均可能是合法满量程数据，不伪造故障检测。
module mcp3208_reader #(
    parameter CLK_HZ = 27000000,
    parameter SCLK_DIV = 27,
    parameter POLL_CYCLES = 27000
)(
    input clk,
    input rst_n,
    input [2:0] channel,
    output reg cs_n,
    output reg sclk,
    output reg mosi,
    input miso,
    output reg sample_valid,
    output reg [11:0] sample_data,
    output reg [2:0] sample_channel
);
    localparam HALF_CYCLES = (SCLK_DIV > 0) ? SCLK_DIV : 1;
    localparam POLL_LIMIT = (POLL_CYCLES > 0) ? POLL_CYCLES : 1;
    // tCSH至少500ns；向上取整，不因不合理的短轮询参数取消片选间隔。
    localparam GAP_CALC = (CLK_HZ + 1999999) / 2000000;
    localparam GAP_CYCLES = (GAP_CALC > 0) ? GAP_CALC : 1;
    localparam HALF_WIDTH = (HALF_CYCLES > 1) ? $clog2(HALF_CYCLES) : 1;
    localparam POLL_WIDTH = (POLL_LIMIT > 1) ? $clog2(POLL_LIMIT) : 1;
    localparam GAP_WIDTH = (GAP_CYCLES > 1) ? $clog2(GAP_CYCLES) : 1;
    reg [HALF_WIDTH-1:0] half_timer;
    reg [POLL_WIDTH-1:0] poll_timer;
    reg [GAP_WIDTH-1:0] gap_timer;
    reg busy;
    reg [4:0] bit_index;
    reg [23:0] tx_shift;
    reg [11:0] rx_shift;
    reg [2:0] active_channel;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cs_n <= 1'b1;
            sclk <= 1'b0;
            mosi <= 1'b0;
            sample_valid <= 1'b0;
            sample_data <= 0;
            sample_channel <= 0;
            half_timer <= 0;
            poll_timer <= 0;
            gap_timer <= 0;
            busy <= 1'b0;
            bit_index <= 0;
            tx_shift <= 0;
            rx_shift <= 0;
            active_channel <= 0;
        end else begin
            sample_valid <= 1'b0;
            // 饱和计数器在传输中也计时，保持开始到开始的轮询节拍。
            if (poll_timer < POLL_LIMIT-1)
                poll_timer <= poll_timer + 1'b1;
            if (!busy) begin
                sclk <= 1'b0;
                mosi <= 1'b0;
                if (gap_timer < GAP_CYCLES-1)
                    gap_timer <= gap_timer + 1'b1;
                if ((poll_timer >= POLL_LIMIT-1) &&
                    (gap_timer >= GAP_CYCLES-1)) begin
                    cs_n <= 1'b0;
                    busy <= 1'b1;
                    active_channel <= channel;
                    tx_shift <= {5'b00000, 2'b11, channel, 14'b0};
                    rx_shift <= 0;
                    bit_index <= 0;
                    half_timer <= 0;
                    poll_timer <= 0;
                    gap_timer <= 0;
                end
            end else if (half_timer == HALF_CYCLES-1) begin
                half_timer <= 0;
                if (!sclk) begin
                    sclk <= 1'b1;
                    // 位号从0计数；只采集最后12位，忽略高阻区和空位。
                    if (bit_index >= 12)
                        rx_shift <= {rx_shift[10:0], miso};
                end else begin
                    sclk <= 1'b0;
                    if (bit_index == 23) begin
                        // B0 已在前一个上升沿进入 rx_shift，至此完整帧结束。
                        busy <= 1'b0;
                        cs_n <= 1'b1;
                        mosi <= 1'b0;
                        gap_timer <= 0;
                        sample_data <= rx_shift;
                        sample_channel <= active_channel;
                        sample_valid <= 1'b1;
                    end else begin
                        bit_index <= bit_index + 1'b1;
                        tx_shift <= {tx_shift[22:0], 1'b0};
                        mosi <= tx_shift[22];
                    end
                end
            end else begin
                half_timer <= half_timer + 1'b1;
            end
        end
    end
endmodule
