`timescale 1ns/1ps
module tb_pressure_expression_preflight;
    reg clk = 0;
    always #18.518 clk = !clk;
    reg rst_n = 0, ready = 0, adc_valid = 0;
    reg [1:0] adc_channel = 0;
    reg [15:0] adc_data = 0;
    wire [7:0] level0, level1;
    wire [1:0] calibrated;
    pressure_expression #(.STALE_CYCLES(32)) dut(
        .clk(clk), .rst_n(rst_n), .ready(ready), .adc_valid(adc_valid),
        .adc_channel(adc_channel), .adc_data(adc_data),
        .level0(level0), .level1(level1), .calibrated(calibrated));
    task sample;
        input [1:0] ch;
        input [15:0] data;
        begin
            @(negedge clk); adc_valid = 1; adc_channel = ch; adc_data = data;
            @(posedge clk); #1;
        end
    endtask
    integer i;
    initial begin
        #1; rst_n = 0;
        repeat (2) @(posedge clk);
        @(negedge clk); rst_n = 1; ready = 1;
        for (i = 0; i < 16; i = i + 1) begin
            sample(0, 1000); sample(1, 3000);
        end
        if (calibrated !== 2'b11 || level0 !== 0 || level1 !== 0) $fatal(1, "calibration");
        for (i = 0; i < 1024; i = i + 1) begin
            sample(0, 1065); sample(1, 7080);
        end
        if (level0 !== 4 || level1 !== 255) $fatal(1, "sustained pressure");
        for (i = 2; i < 32; i = i + 1) begin
            sample(1, 7080);
            if (calibrated !== 2'b11 || level0 !== 4) $fatal(1, "early timeout");
        end
        // One A1 sample already occurred after A0's last sample above.
        if (calibrated !== 2'b11) $fatal(1, "timeout boundary setup");
        sample(1, 7080);
        if (calibrated !== 2'b10 || level0 !== 0 || level1 !== 255) $fatal(1, "independent timeout");
        $display("PRESSURE_EXPRESSION_PREFLIGHT_PASS");
        $finish;
    end
endmodule
