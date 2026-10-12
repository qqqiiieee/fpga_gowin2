// 640×480@60Hz光栅：pixel25.2MHz，每行800点、每帧525行，负极性同步。
// 所有计数在pixel域，rst_n异步低有效且父层同步释放。x/y含消隐区坐标。
// de仅640×480有效区为1；hSync低656..751，vSync低490..491。
// frame_start在(0,0)为一拍，用于整包状态与波形银行更新，不能当新时钟。
// 行末更新vcount，帧末归零；不要仅改分辨率常数而不重算PLL、porch和renderer。

// 640x480p60: 25.2 MHz pixel clock, 800x525 total, negative sync.
module video_timing(input pixel_clk, input rst_n,
    output [9:0] x, output [9:0] y, output de,
    output hsync, output vsync, output frame_start);
    reg [9:0] hcount, vcount;
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin hcount<=0; vcount<=0; end
        else if(hcount==799) begin
            hcount<=0;
            if(vcount==524) vcount<=0; else vcount<=vcount+1'b1;
        end else hcount<=hcount+1'b1;
    end
    assign x=hcount;
    assign y=vcount;
    assign de=(hcount<640 && vcount<480);
    assign hsync=!(hcount>=656 && hcount<752);
    assign vsync=!(vcount>=490 && vcount<492);
    assign frame_start=(hcount==0 && vcount==0);
endmodule
