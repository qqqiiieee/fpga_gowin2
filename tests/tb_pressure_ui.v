`timescale 1ns/1ps
// Focused independent pixel oracle for V020's changed labels and dynamic values.
// Frozen font-map codes: 明=[408,409], 亮=[410,411]; no DUT text helper is used.
module tb_pressure_ui;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg[9:0] x=0,y=0;reg[1:0] page=0;reg[7:0] a=0,b=255;
 wire[23:0] rgb;reg[7:0] font[0:8191];integer checks=0,j,v;
 hdmi_instrument_dashboard #(.UI_ENABLE(1)) dut(
 .pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(1'b1),.keys(12'd0),.timbre(4'd0),
 .note(7'd60),.note_valid(1'b0),.frequency_bcd(16'h0262),.volume_percent(8'd0),
 .level_dbfs(-8'sd60),.peak_percent(8'd0),.pitch(9'sd0),.voices(6'd0),.pressure0(a),.pressure1(b),.flags(8'd0),
 .guide_active(1'b0),.guide_done(1'b0),.cue_mask(12'd0),.next_mask(12'd0),.wrong_mask(12'd0),
 .guide_step(6'd0),.guide_total(6'd42),.beat_progress(8'd0),.target_beats(2'd1),
 .wave_current(16'sd0),.wave_previous(16'sd0),.scope_gain(4'd0),.wave_valid(1'b0),
 .test_active(1'b0),.test_requested(6'd0),.test_busy(32'd0),.test_gate(32'd0),.test_sweep(1'b0),
 .test_index(5'd0),.test_overrun(1'b0),.ui_page(page),.ui_cursor(2'd0),.ui_song(2'd0),.ui_controls(4'd0),
 .red(rgb[23:16]),.green(rgb[15:8]),.blue(rgb[7:0]));
 task line;
 input integer px,py,width,is_vib,value;
 integer gx,gy,col;reg[8:0] code;reg[23:0] expected;
 begin
  for(gy=0;gy<16;gy=gy+1)for(gx=0;gx<width;gx=gx+1)begin
   col=gx/8;code=32;
   if(col<4)begin
    if(is_vib)case(col)0:code=86;1:code=73;2:code=66;3:code=32;endcase
    else case(col)0:code=408;1:code=409;2:code=410;3:code=411;endcase
   end else if(col==4)code=48+value/100;
   else if(col==5)code=48+(value/10)%10;
   else if(col==6)code=48+value%10;
   expected=font[code*16+gy][7-gx%8]?24'he2e8f0:24'h0b101c;
   @(negedge clk);x=px+gx;y=py+gy;@(posedge clk);#1;checks=checks+1;
   if(rgb!==expected)$fatal(1,"pressure label page=%d value=%d at %d,%d got=%h expected=%h",page,value,x,y,rgb,expected);
  end
 end endtask
 initial begin
  $readmemh("src/ui_font.hex",font);repeat(3)@(negedge clk);rst_n=1;
  for(j=0;j<5;j=j+1)begin
   case(j)0:v=0;1:v=1;2:v=64;3:v=128;4:v=255;endcase
   a=v;b=255-v;page=0;line(160,88,112,0,a);line(288,88,112,1,b);
   page=3;line(320,224,256,0,a);line(320,256,256,1,b);
  end
  $display("PRESSURE_UI_TEST_PASS pixels=%0d pages=2 labels=2 distinct_channel_values=5 no_overlap=1",checks);$finish;
 end
 initial begin #2000000;$fatal(1,"pressure UI timeout");end
endmodule
