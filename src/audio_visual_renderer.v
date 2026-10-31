// V036 overlay. All ports are pixel-domain. Exactly TWO registered stages.
// Addresses are combinational for input x/y; external RAM q arrives at the
// first posedge. Stage1 holds geometry, stage2 consumes that q and emits RGB.
// Interior coordinates (inclusive): normal FFT 32..287,80..335; XY 320..575,
// 80..335 (2x2 per logical point). Compact FFT 32..287,144..271; XY 384..511,
// 148..275 (1x1). Borders extend one pixel, except compact FFT top is clipped
// to y144 (drawn on that row), keeping ALL compact coverage within y144..279.
// covered=0,rgb=0 outside those boxes, disabled, de=0, or beyond 640x480.
// level=0 draws no FFT bar; normal height=level, compact height=level>>1.
// Invalid RAM keeps only the background/grid/border, never a fabricated trace.
module audio_visual_renderer(
    input pixel_clk,input rst_n,input [9:0] x,y,input de,enabled,compact,
    input [7:0] fft_level,input xy_dot,fft_valid,xy_valid,
    output [7:0] fft_read_addr,output [13:0] xy_read_addr,
    output reg [23:0] rgb,output reg covered
);
    localparam [23:0] PANEL=24'h0b101c,BORDER=24'h34465f,
        GRID=24'h22324a,CENTER=24'h34465f,CYAN=24'h51d6e8,GREEN=24'h21c6a8;
    wire visible=de && enabled && x<640 && y<480;
    wire [9:0] fft_top=compact ? 10'd144 : 10'd80;
    wire [9:0] fft_bottom=compact ? 10'd271 : 10'd335;
    wire [9:0] xy_left=compact ? 10'd384 : 10'd320;
    wire [9:0] xy_right=compact ? 10'd511 : 10'd575;
    wire [9:0] xy_top=compact ? 10'd148 : 10'd80;
    wire [9:0] xy_bottom=compact ? 10'd275 : 10'd335;
    wire fft_inside=x>=32 && x<=287 && y>=fft_top && y<=fft_bottom;
    wire xy_inside=x>=xy_left && x<=xy_right && y>=xy_top && y<=xy_bottom;
    wire fft_box=x>=31 && x<=288 &&
        y>=(compact ? 10'd144 : 10'd79) && y<=fft_bottom+10'd1;
    wire xy_box=x>=xy_left-10'd1 && x<=xy_right+10'd1 &&
        y>=xy_top-10'd1 && y<=xy_bottom+10'd1;
    wire [7:0] fft_x=x-10'd32;
    wire [7:0] fft_y=y-fft_top;
    wire [7:0] height_from_bottom=fft_bottom-y;
    wire [7:0] local_x=x-xy_left;
    wire [7:0] local_y=y-xy_top;
    wire [6:0] logical_x=compact ? local_x[6:0] : local_x[7:1];
    wire [6:0] logical_y=compact ? local_y[6:0] : local_y[7:1];
    assign fft_read_addr=visible && fft_inside ? fft_x : 8'd0;
    assign xy_read_addr=visible && xy_inside ? {logical_y,logical_x} : 14'd0;
    wire fft_grid=fft_x[4:0]==0 || (compact ? fft_y[4:0]==0 : fft_y[5:0]==0);
    wire xy_grid=logical_x[4:0]==0 || logical_y[4:0]==0;
    wire xy_center=logical_x==64 || logical_y==64;
    reg fft0,xy0,border0,grid0,center0,covered0,compact0,fft_valid0,xy_valid0;
    reg [7:0] bottom0;
    wire [7:0] bar_height=compact0 ? {1'b0,fft_level[7:1]} : fft_level;
    always @(posedge pixel_clk or negedge rst_n)begin
        if(!rst_n)begin
            fft0<=0;xy0<=0;border0<=0;grid0<=0;center0<=0;covered0<=0;
            compact0<=0;fft_valid0<=0;xy_valid0<=0;bottom0<=0;
            rgb<=0;covered<=0;
        end else begin
            fft0<=fft_inside;xy0<=xy_inside;
            border0<=(fft_box && (!fft_inside || (compact && y==144))) ||
                (xy_box && !xy_inside);
            grid0<=(fft_inside && fft_grid) || (xy_inside && xy_grid);
            center0<=xy_inside && xy_center;
            covered0<=visible && (fft_box || xy_box);
            compact0<=compact;bottom0<=height_from_bottom;
            fft_valid0<=fft_valid;xy_valid0<=xy_valid;
            covered<=covered0;
            if(!covered0)rgb<=0;
            else if(border0)rgb<=BORDER;
            else if(xy0 && xy_valid0 && xy_dot)rgb<=CYAN;
            else if(fft0 && fft_valid0 && bottom0<bar_height)rgb<=GREEN;
            else if(center0)rgb<=CENTER;
            else if(grid0)rgb<=GRID;
            else rgb<=PANEL;
        end
    end
endmodule
