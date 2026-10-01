// ============================================================
// sensor_interface.v
// 压力/力度传感器接口【占位模块】
// 目标：把压力传感器读数转成 力度(velocity) 和 表情(expression) 两个控制维度
// 物理层可选：外部 SPI/I2C ADC 或 FPGA 模拟前端，按实际器件接线后实现
// ============================================================
module sensor_interface(
    input        clk,
    input        rst_n,
    // ---- 预留物理接口（按实际传感器接线修改）----
    input  [11:0] adc_data,   // 外部 ADC 读数（压力 → 电压，12bit）
    input         adc_valid,  // ADC 数据有效脉冲
    // 若用 SPI 传感器，可在此增加 sclk/mosi/miso/cs 等引脚
    // ---- 处理后的控制量输出 ----
    output reg [7:0] velocity,    // 力度 0..255
    output reg [7:0] expression   // 表情/调控 0..255
);
    // TODO: 这里做去抖、滤波、量程映射（压力→力度曲线）
    // 当前实现：直接把 12bit 读数映射到两个 8bit 维度
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            velocity   <= 8'd64;   // 默认中等力度
            expression <= 8'd0;
        end else if (adc_valid) begin
            velocity   <= adc_data[11:4];        // 高 8 位 → 力度
            expression <= {adc_data[3:0], 4'b0}; // 低 4 位 → 表情
        end
    end
endmodule
