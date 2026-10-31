`timescale 1ns/1ps
module tb_score_pixels;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg request_valid=0;reg [7:0] op=0;reg [39:0] data=0;
 wire done;wire [7:0] status;wire [31:0] reply,score_config;
 wire score_wr_en;wire [8:0] score_wr_addr;wire [31:0] score_wr_data;wire ack;
 phone_extension_state #(.CHORD_SCORE_ENABLE(1),.GUIDE_MODES_ENABLE(1)) state(
  .clk(clk),.rst_n(rst_n),.request_valid(request_valid),.op(op),.data(data),
  .done(done),.status(status),.reply(reply),.performance_idle(1'b1),.pixel_bank_ack(ack),.test_owned(1'b0),
  .score_wr_en(score_wr_en),.score_wr_addr(score_wr_addr),.score_wr_data(score_wr_data),.score_config(score_config),
  .guide_status(24'd0),.mapping_wr_ready(1'b1),.mapping_commit_ready(1'b1),.mapping_commit_ack(1'b1),
  .record_active(1'b0),.record_busy(1'b0),.record_count(32'd0),.record_crc32(32'd0),.record_dropped(16'd0));
 reg sample_tick=0,start=0;
 wire [11:0] guide_tick;wire [6:0] expected_note;wire [14:0] expected_offsets;
 wire expected_valid,score_ready;wire [5:0] step_index;
 piano_roll_guide #(.CUSTOM_SCORE_ENABLE(1)) guide(.clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),
  .pause(1'b0),.song_id(2'd3),.ui_start(start),.ui_toggle(1'b0),.ui_restart(1'b0),
  .roll_tick(guide_tick),.step_index(step_index),.expected_note(expected_note),.expected_offsets(expected_offsets),
  .expected_valid(expected_valid),.score_ready(score_ready),.custom_write_clk(clk),.custom_write_en(score_wr_en),
  .custom_write_addr(score_wr_addr),.custom_write_data(score_wr_data),.custom_config(score_config));
 reg [9:0] x=0,y=0;reg de=1,frame=0,roll_done=0,roll_active=1,roll_bank=1;
 reg [11:0] roll_tick=128;reg [31:0] held=0;
 wire [23:0] rgb;wire covered;
 piano_roll_renderer #(.CUSTOM_SCORE_ENABLE(1)) pixels(.pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(de),
  .piano_keys(held),.piano_outside(1'b0),.roll_tick(roll_tick),.roll_song(2'd3),.roll_active(roll_active),.roll_done(roll_done),
  .rgb(rgb),.covered(covered),.custom_write_clk(clk),.custom_write_en(score_wr_en),.custom_write_addr(score_wr_addr),
  .custom_write_data(score_wr_data),.custom_config(score_config),.frame_tick(frame),.roll_custom_bank(roll_bank),.custom_bank_ack(ack));
 integer checks=0,rejected=0,i,n,checksum=0,bubbles=0,cx;reg [31:0] word;
 localparam CYAN=24'h51d6e8,PANEL=24'h172338,AMBER=24'hf4bb4f,GREEN=24'h21c6a8,BORDER=24'h34465f,GRID=24'h22324a;
 function [31:0] chord(input integer root,d1,d2,d3,step);
  chord=32'h80006000|root|(step<<7)|(d1<<16)|(d2<<21)|(d3<<26);
 endfunction
 // Independent physical centres for MIDI41..72, including all 13 black keys.
 function integer center(input integer pitch);
  begin case(pitch)
   41:center=50;42:center=65;43:center=80;44:center=95;45:center=110;46:center=125;
   47:center=140;48:center=170;49:center=185;50:center=200;51:center=215;52:center=230;
   53:center=260;54:center=275;55:center=290;56:center=305;57:center=320;58:center=335;
   59:center=350;60:center=380;61:center=395;62:center=410;63:center=425;64:center=440;
   65:center=470;66:center=485;67:center=500;68:center=515;69:center=530;70:center=545;
   71:center=560;72:center=590;default:center=0;endcase end
 endfunction
 task cycles(input integer n);begin repeat(n)begin @(posedge clk);#1;@(negedge clk);end end endtask
 task check(input condition,input [511:0] label);
  begin checks=checks+1;if(!condition)$fatal(1,"SCORE_PIXELS: %0s",label);end
 endtask
 task command(input integer operation,input [39:0] payload,input integer expected_status);
  integer timeout;begin
   op=operation;data=payload;request_valid=1;cycles(1);request_valid=0;timeout=0;
   while(!done&&timeout<300)begin cycles(1);timeout=timeout+1;end
   if(!done||status!=expected_status)$fatal(1,"op=%d status=%d expected=%d",operation,status,expected_status);
   checks=checks+1;if(expected_status==2)rejected=rejected+1;cycles(2);
  end
 endtask
 task pixel(input integer xx,yy,input [23:0] colour,input cov);
  begin x=xx;y=yy;cycles(6);checks=checks+1;
   if(rgb!==colour||covered!==cov)$fatal(1,"pixel x=%d y=%d tick=%d got=%h cover=%b expected=%h/%b",xx,yy,roll_tick,rgb,covered,colour,cov);
  end
 endtask
 task reach(input integer position);
  integer watchdog;begin sample_tick=1;watchdog=0;
   while(guide_tick<position&&watchdog<100000)begin cycles(1);watchdog=watchdog+1;if(!score_ready)bubbles=bubbles+1;end
   sample_tick=0;cycles(3);check(guide_tick==position&&score_ready,"guide failed to reach ready position");end
 endtask
 initial begin
  cycles(3);rst_n=1;cycles(8);
  command(0,0,0);check(reply==32'h1000f,"chord capability missing");
  command(16,(40'd23437<<16)|(40'd16<<8)|4,0);
  // Illegal flag31 mono, holes, duplicates, descending deltas and range overflow.
  command(17,{chord(48,0,0,0,0),8'd0},2);
  command(17,{chord(48,4,0,12,0),8'd0},2);
  command(17,{chord(48,4,4,12,0),8'd0},2);
  command(17,{chord(48,7,4,12,0),8'd0},2);
  command(17,{chord(48,4,7,6,0),8'd0},2);
  command(17,{chord(65,4,7,8,0),8'd0},2);
  command(17,{chord(40,4,7,12,0),8'd0},2);
  command(17,{chord(73,1,0,0,0),8'd0},2);
  command(17,{chord(48,4,7,12,4),8'd0},2);
  command(17,{(chord(48,4,7,12,0)&~32'h2000),8'd0},2);
  for(i=0;i<16;i=i+1)begin
   case(i)
    8:word=chord(41,1,7,31,0);
    9:word=chord(41,1,7,31,1);
    10:word=32'h00806000|(72<<16)|60|(2<<7); // old mono next-note metadata
    11:word=chord(65,2,4,7,3);
    12:word=chord(60,4,0,0,3); // two-note chord
    13:word=chord(60,4,7,0,3); // three-note chord
    default:word=0;
   endcase
   command(17,{word,i[7:0]},0);checksum=(checksum+word[7:0]+word[15:8]+word[23:16]+word[31:24])&65535;
  end
  command(18,checksum,0);cycles(25);frame=1;cycles(1);frame=0;cycles(6);
  check(ack==1&&score_config[31:30]==3,"commit not acknowledged by renderer");
  start=1;cycles(1);start=0;reach(128);
  check(expected_valid&&expected_note==41&&expected_offsets=={5'd31,5'd7,5'd1}&&step_index==0,"guide chord decoding");
  for(i=41;i<=72;i=i+1)begin
   pixel(center(i),317,(i==41||i==42||i==48||i==72)?CYAN:PANEL,1);
   // Only target keys checked for keyboard colour; black/white background differs.
   if(i==41||i==42||i==48||i==72)pixel(center(i),340,AMBER,1);
  end
  held=(32'b1<<0)|(32'b1<<1)|(32'b1<<7)|(32'b1<<31);
  pixel(50,340,GREEN,1);pixel(65,340,GREEN,1);pixel(170,340,GREEN,1);pixel(590,340,GREEN,1);held=0;
  pixel(33,317,0,0);pixel(34,317,BORDER,1);pixel(605,317,BORDER,1);pixel(606,317,0,0);
  pixel(50,142,0,0);pixel(50,143,BORDER,1);pixel(50,400,BORDER,1);pixel(50,401,0,0);
  de=0;pixel(50,317,0,0);de=1;
  roll_tick=126;pixel(50,318,GRID,1);pixel(50,317,PANEL,1);pixel(50,316,CYAN,1);
  roll_tick=128;roll_bank=0;pixel(50,317,PANEL,1);roll_bank=1;
  roll_done=1;pixel(50,317,PANEL,1);roll_done=0;
  reach(144);check(expected_valid&&step_index==1&&expected_offsets=={5'd31,5'd7,5'd1},"same chord next step");
  reach(160);check(expected_valid&&expected_note==60&&expected_offsets==0,"old mono offsets changed");
  roll_tick=160;pixel(center(60),317,CYAN,1);pixel(center(72),317,PANEL,1);
  reach(176);check(expected_valid&&expected_note==65&&expected_offsets=={5'd7,5'd4,5'd2},"upper edge chord");
  roll_tick=176;pixel(center(65),317,CYAN,1);pixel(center(67),317,CYAN,1);
  pixel(center(69),317,CYAN,1);pixel(center(72),317,CYAN,1);pixel(center(41),317,PANEL,1);
  roll_tick=256;pixel(center(65),317,PANEL,1);roll_tick=4095;pixel(center(41),144,PANEL,1);
  check(bubbles>0,"no actual synchronous score bubble observed");
  $display("CHORD_SCORE_PIXELS_PASS checks=%0d invalid_words=%0d bubbles=%0d",checks,rejected,bubbles);$finish;
 end
 initial begin #5000000;$fatal(1,"score/pixels watchdog");end
endmodule
