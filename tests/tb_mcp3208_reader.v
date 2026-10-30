`timescale 1ns/1ps
// 独立ADC模型在引脚上解释命令，仅在下降沿改变DOUT；不读取DUT内部状态。
module tb_mcp3208_reader;
    parameter TEST_DIV = 27;
    parameter TEST_POLL = 5400;
    parameter EXHAUSTIVE = 0;
    localparam GAP = 14;
    localparam PERIOD = (TEST_POLL > 48*TEST_DIV+GAP) ? TEST_POLL : 48*TEST_DIV+GAP;
    reg clk = 0;
    always #18.5185 clk = ~clk;
    reg rst_n = 0;
    reg [2:0] channel = 0;
    wire cs_n, sclk, mosi, sample_valid;
    reg miso = 1'bz;
    wire [11:0] sample_data;
    wire [2:0] sample_channel;
    reg [11:0] offered_data = 0, adc_data = 0;
    reg [2:0] adc_channel = 0;
    integer cycles = 0, rises = 0, falls = 0, checks = 0;
    integer completed = 0, published = 0, last_start = -1, low_start = 0;
    integer high_start = -1, last_edge = 0, v, c;
    reg [23:0] command_word = 0;
    reg old_valid = 0;
    reg [11:0] old_data = 0;
    reg [2:0] old_channel = 0;
    reg [11:0] patterns [0:9];

    mcp3208_reader #(.SCLK_DIV(TEST_DIV), .POLL_CYCLES(TEST_POLL)) dut(
        .clk(clk), .rst_n(rst_n), .channel(channel), .cs_n(cs_n), .sclk(sclk),
        .mosi(mosi), .miso(miso), .sample_valid(sample_valid),
        .sample_data(sample_data), .sample_channel(sample_channel));

    task check;
        input condition;
        input [1023:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) $fatal(1, "%0s cycle=%0d", message, cycles);
        end
    endtask
    always @(posedge clk) cycles = cycles + 1;
    always @(negedge rst_n) begin
        last_start = -1;
        high_start = -1;
    end
    always @(negedge cs_n) if (rst_n) begin
        check(sclk === 0, "SPI mode0 must start with clock low");
        if (last_start >= 0) check(cycles-last_start == PERIOD, "start-to-start cadence changed");
        if (high_start >= 0) check(cycles-high_start >= GAP, "CS high gap shorter than 500ns");
        last_start = cycles;
        low_start = cycles;
        last_edge = cycles;
        rises = 0;
        falls = 0;
        command_word = 0;
        adc_channel = channel;
        adc_data = offered_data;
        miso = 1'bz;
    end
    always @(posedge sclk) if (rst_n) begin
        check(!cs_n, "SCLK rose while CS inactive");
        check(cycles-last_edge == TEST_DIV, "SCLK low/setup width");
        last_edge = cycles;
        rises = rises + 1;
        command_word = {command_word[22:0], mosi};
        if (rises <= 5) check(mosi === 0, "leading zero missing");
        if (rises == 6) check(mosi === 1, "Start bit missing");
        if (rises == 7) check(mosi === 1, "single-ended mode missing");
        if (rises == 8) check(mosi === adc_channel[2], "D2 channel changed during transaction");
        if (rises == 9) check(mosi === adc_channel[1], "D1 channel changed during transaction");
        if (rises == 10) check(mosi === adc_channel[0], "D0 channel changed during transaction");
    end
    always @(negedge sclk) if (rst_n) begin
        check(cycles-last_edge == TEST_DIV, "SCLK high width");
        last_edge = cycles;
        falls = falls + 1;
        // DS21298E图6-1：下降沿11输出空位，下降沿12输出B11，23输出B0。
        if (!cs_n) begin
            if (rises == 11) miso = 1'b0;
            else if (rises >= 12 && rises <= 23) miso = adc_data[23-rises];
        end
    end
    always @(posedge cs_n) begin
        // 允许最后一个下降沿的监视器在同一仿真时间片完成。
        #0.001;
        miso = 1'bz;
        if (rst_n && last_start >= 0) begin
            check(rises == 24 && falls == 24, "CS ended before full 24-clock frame");
            check(cycles-low_start == 48*TEST_DIV, "transaction length");
            check(command_word === {5'b0, 2'b11, adc_channel, 14'b0}, "24-bit command sequence");
            high_start = cycles;
            completed = completed + 1;
        end
    end
    always @(negedge clk) begin
        if (!rst_n) begin
            old_valid = 0;
            old_data = 0;
            old_channel = 0;
        end else begin
            check(!(sample_valid && old_valid), "sample_valid wider than one clk");
            if (sample_valid) begin
                check(cs_n && !sclk, "published before complete transaction");
                check(sample_data === adc_data, "ADC payload bit/order/edge mismatch");
                check(sample_channel === adc_channel, "sample_channel was not latched");
                published = published + 1;
            end else begin
                check(sample_data === old_data && sample_channel === old_channel,
                      "payload changed without sample_valid");
            end
            old_valid = sample_valid;
            old_data = sample_data;
            old_channel = sample_channel;
        end
    end
    task frame;
        input [2:0] requested_channel;
        input [11:0] value;
        begin
            @(negedge clk);
            channel = requested_channel;
            offered_data = value;
            @(negedge cs_n);
            // 在命令发送前就改变外部channel，迫使DUT使用事务锁存值。
            @(negedge clk);
            channel = requested_channel ^ 3'b111;
            wait(sample_valid);
            @(posedge clk);
            #0.001;
            check(sample_data === value && sample_channel === requested_channel, "requested frame mismatch");
        end
    endtask

    initial begin
        patterns[0]=12'h000; patterns[1]=12'hfff; patterns[2]=12'habc;
        patterns[3]=12'h001; patterns[4]=12'h7ff; patterns[5]=12'h800;
        patterns[6]=12'haaa; patterns[7]=12'h555; patterns[8]=12'hffe; patterns[9]=12'h801;
        repeat(4) @(negedge clk);
        rst_n = 1;
        for (c=0;c<2;c=c+1)
            for (v=0;v<10;v=v+1) frame(c ? 7 : 0, patterns[v]);
        if (EXHAUSTIVE)
            for (c=0;c<2;c=c+1)
                for (v=0;v<4096;v=v+1) frame(c ? 7 : 0, v[11:0]);
        // 复位打断半帧不应发布残帧，随后新事务正常恢复。
        @(negedge cs_n);
        repeat(7) @(posedge sclk);
        @(negedge clk);
        rst_n = 0;
        #0.001;
        check(cs_n && !sclk && !sample_valid && sample_data==0, "reset did not abort partial frame");
        repeat(4) @(negedge clk);
        rst_n = 1;
        frame(7, 12'habc);
        @(negedge clk);
        check(completed == published, "complete frames/publications not one-to-one");
        $display("MCP3208_READER_TEST_PASS checks=%0d frames=%0d exhaustive=%0d div=%0d poll=%0d",
                 checks, completed, EXHAUSTIVE, TEST_DIV, TEST_POLL);
        $finish;
    end
    initial begin #2000000000; $fatal(1, "SPI test timeout"); end
endmodule
