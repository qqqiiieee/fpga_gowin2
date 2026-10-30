`timescale 1ns/1ps
// 两音色显示的独立像素预期：常量在本bench冻结，不引用生成文本头文件、
// 不调用DUT的标签/字符函数构造答案。使用单独ROM存储及绝对坐标逐像素断言，
// 覆盖00柔和长笛、01拨弦、诊断页2音色帮助及中文左右半字/16行/空白填充。
module tb_timbre2_ui;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg [9:0] x=0,y=0;
    reg [3:0] timbre=0;
    reg [1:0] page=0;
    wire [23:0] rgb;
    localparam [23:0] BG=24'h0b101c,TEXT=24'he2e8f0,MUTED=24'h91a4be;
    localparam [287:0] FLUTE=288'h4120d0885100c06020bd5eef97dbf5ff0181100804020100804020100804020100804020;
    localparam [287:0] PLUCK=288'h4120d0885100c06220c964ef179100804020100804020100804020100804020100804020;
    localparam [287:0] HELP=288'h298c4662f298c46820fc7e7f5fb192090684428804020100804020100804020100804020;
    reg [7:0] reference_font[0:8191];
    integer checks=0,i;
    hdmi_instrument_dashboard #(.UI_ENABLE(1)) dut(
        .pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(1'b1),
        .keys(12'd0),.timbre(timbre),.note(7'd60),.note_valid(1'b0),.frequency_bcd(16'h0262),
        .volume_percent(8'd0),.level_dbfs(-8'sd60),.peak_percent(8'd0),.pitch(9'sd0),
        .voices(6'd0),.pressure0(8'd0),.pressure1(8'd0),.flags(8'd0),
        .guide_active(1'b0),.guide_done(1'b0),.cue_mask(12'd0),.next_mask(12'd0),.wrong_mask(12'd0),
        .guide_step(6'd0),.guide_total(6'd42),.beat_progress(8'd0),.target_beats(2'd1),
        .wave_current(16'sd0),.wave_previous(16'sd0),.scope_gain(4'd0),.wave_valid(1'b0),
        .test_active(1'b0),.test_requested(6'd0),.test_busy(32'd0),.test_gate(32'd0),
        .test_sweep(1'b0),.test_index(5'd0),.test_overrun(1'b0),
        .ui_page(page),.ui_cursor(2'd0),.ui_song(2'd0),.ui_controls(4'd0),
        .red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]));
    task expect_line;
        input integer px,py;
        input [287:0] label;
        input [23:0] foreground;
        integer gx,gy;
        reg [8:0] code;
        reg [23:0] expected;
        begin
            for(gy=0;gy<16;gy=gy+1)for(gx=0;gx<256;gx=gx+1)begin
                code=label[287-(gx/8)*9-:9];
                expected=reference_font[code*16+gy][7-(gx%8)]?foreground:BG;
                @(negedge clk);x=px+gx;y=py+gy;
                @(posedge clk);#1;checks=checks+1;
                if(rgb!==expected)$fatal(1,"TIMBRE2_UI page=%0d timbre=%0d pixel=%0d,%0d got=%h expected=%h",
                    page,timbre,x,y,rgb,expected);
            end
        end
    endtask
    initial begin
        $readmemh("src/ui_font.hex",reference_font);
        #1;
        for(i=0;i<8192;i=i+1)if((^reference_font[i])===1'bx)$fatal(1,"TIMBRE2_UI missing font row");
        repeat(3)@(negedge clk);rst_n=1;
        // 两个独立常量同时含中文名称与实际00/01数字，不能用DUT输出反算期望。
        timbre=0;expect_line(32,40,FLUTE,TEXT);
        timbre=1;expect_line(32,40,PLUCK,TEXT);
        // 所有非法ID都不显示旧音色名；数字区仍保留输入编号作为诊断信息。
        // 此处直接断言空白文本ID，不把动态数字区误判为名称；有效ID已在上方逐像素验证。
        for(i=2;i<16;i=i+1)begin
            timbre=i;
            @(negedge clk);x=32;y=40;#1;
            if(dut.zh_label!==8'd255)$fatal(1,"TIMBRE2_UI invalid ID must select blank text");
        end
        page=3;expect_line(32,464,HELP,MUTED);
        $display("TIMBRE2_UI_TEST_PASS pixels=%0d independent_labels=2 help_count=2 invalid_ids=14",checks);
        $finish;
    end
    initial begin #1000000;$fatal(1,"TIMBRE2_UI timeout");end
endmodule
