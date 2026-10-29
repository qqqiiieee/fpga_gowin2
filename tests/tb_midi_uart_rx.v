`timescale 1ns/1ps
// 生产时钟的 UART 独立回归：全字节域、连续帧、每位正负1%抖动、毛刺、
// 坏停止位与长 break。记分板只看公开 data/data_valid/framing_error。
module tb_midi_uart_rx;
    reg clk=0,rst_n=0,rx=1;
    always #18.518519 clk=~clk;
    wire [7:0] data;
    wire valid,error;
    midi_uart_rx dut(.clk(clk),.rst_n(rst_n),.rx(rx),.data(data),
                    .data_valid(valid),.framing_error(error));
    reg [7:0] expected [0:1023];
    integer sent=0,got=0,errors=0,i,j;
    reg previous_valid=0,previous_error=0;
    always @(posedge clk) if (rst_n) begin
        if (valid) begin
            if (previous_valid) $fatal(1,"MIDI UART valid wider than one cycle");
            if (got>=sent || data!==expected[got])
                $fatal(1,"MIDI UART byte[%0d] got=%h expected=%h",got,data,expected[got]);
            got=got+1;
        end
        if (error) begin
            if (previous_error) $fatal(1,"MIDI UART framing pulse too long");
            errors=errors+1;
        end
        previous_valid=valid; previous_error=error;
    end
    task tick;
        input integer n;
        begin repeat(n) @(negedge clk); end
    endtask
    task frame;
        input [7:0] b;
        input integer skew,alternate,good;
        integer k,width;
        reg [9:0] bits;
        begin
            if (good) begin expected[sent]=b; sent=sent+1; end
            bits={good[0],b,1'b0};
            for (k=0;k<10;k=k+1) begin
                width=864+((alternate && k[0]) ? -skew : skew);
                rx=bits[k]; tick(width);
            end
        end
    endtask
    initial begin
        tick(8); rst_n=1; tick(1800);
        for (i=0;i<256;i=i+1) frame(i,0,0,1);
        // 855/873 是约 +/-1.04%；比所需 +/-1% 再略严一点。
        for (i=0;i<32;i=i+1) begin
            frame((i*73)&255,-9,0,1); frame((i*151)&255,9,0,1);
            frame((i*37)&255,9,1,1);
        end
        rx=0; tick(100); rx=1; tick(1800); // 小于半位的假起始毛刺。
        if (got!=sent || errors!=0) $fatal(1,"MIDI UART data/jitter/glitch");
        frame(8'h55,0,0,0); rx=1; tick(2600);
        if (errors!=1 || got!=sent) $fatal(1,"MIDI UART bad stop accepted");
        frame(8'ha5,0,0,1);
        rx=0; tick(864*45);
        if (errors!=2) $fatal(1,"MIDI UART break repeated framing error");
        // 短高脉冲不能解除 break 恢复锁定。
        rx=1; tick(200); rx=0; tick(864*12);
        if (errors!=2) $fatal(1,"MIDI UART break high glitch rearmed");
        rx=1; tick(864*3); frame(8'h90,0,0,1); frame(8'h7f,0,0,1);
        tick(864*2);
        if (got!=sent || errors!=2) $fatal(1,"MIDI UART recovery failed");
        $display("MIDI_CASE_PASS uart_27mhz_31250_all_bytes_jitter_break_glitch");
        $display("MIDI_UART_RX_TEST_PASS bytes=%0d errors=%0d",got,errors);
        $finish;
    end
    initial begin #200000000; $fatal(1,"MIDI UART watchdog"); end
endmodule
