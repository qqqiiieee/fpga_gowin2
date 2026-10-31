`timescale 1ns/1ps
module tb_fx;
 reg clk=0,rst_n=0,tick=0;
 always #5 clk=~clk;
 reg [15:0] melody=0;
 reg [7:0] balance=128;
 reg [1:0] mode=0;
 wire [15:0] dry_new,dry_old;
 wire signed [15:0] wet_new,wet_old;
 wire tail_new,tail_old;
 performance_mixer dut(.clk(clk),.rst_n(rst_n),.tick(tick),.melody(melody),
  .kick(16'd0),.snare(16'd0),.closed_hat(16'd0),.open_hat(16'd0),.balance(balance),.sample(dry_new));
 performance_mixer_before old(.clk(clk),.rst_n(rst_n),.tick(tick),.melody(melody),
  .kick(16'd0),.snare(16'd0),.closed_hat(16'd0),.open_hat(16'd0),.balance(balance),.sample(dry_old));
 audio_effects fx_new(.clk(clk),.rst_n(rst_n),.tick(tick),.clear(1'b0),.input_active(1'b1),
  .mode(mode),.amount(8'd192),.time_control(8'd0),.feedback_control(8'd96),.mod_control(8'd16),
  .sample_in(dry_new),.sample_out(wet_new),.tail_busy(tail_new));
 audio_effects fx_old(.clk(clk),.rst_n(rst_n),.tick(tick),.clear(1'b0),.input_active(1'b1),
  .mode(mode),.amount(8'd192),.time_control(8'd0),.feedback_control(8'd96),.mod_control(8'd16),
  .sample_in(dry_old),.sample_out(wet_old),.tail_busy(tail_old));
 integer m,i,j,wet_frames,positive,negative,captured,checks=0;
 initial begin
  for(m=0;m<4;m=m+1)begin
   @(negedge clk);rst_n=0;tick=0;mode=m;melody=0;balance=128;
   repeat(3)@(negedge clk);rst_n=1;wet_frames=0;positive=0;negative=0;
   for(i=0;i<4096;i=i+1)begin
    melody=i<3072?((i*177)%16000)-8000:0;
    balance=i%512<256?64:192;
    captured=$signed(dry_new);tick=1;
    for(j=0;j<288;j=j+1)begin
     @(posedge clk);#1;
     if(dry_new!==dry_old||wet_new!==wet_old||tail_new!==tail_old)
      $fatal(1,"melody or FX changed mode=%d frame=%d clk=%d",m,i,j);
     if((^wet_new)===1'bx)$fatal(1,"unknown FX output");
     @(negedge clk);tick=0;
    end
    if(wet_new!=captured)wet_frames=wet_frames+1;
    if(wet_new>0)positive=positive+1;if(wet_new<0)negative=negative+1;
    checks=checks+1;
   end
   if(m==0&&wet_frames!=0)$fatal(1,"bypass changed");
   if(m!=0&&wet_frames==0)$fatal(1,"FX was never active");
   if(positive==0||negative==0)$fatal(1,"missing bipolar FX coverage");
   $display("FX_MODE_PASS mode=%0d wet_frames=%0d positive=%0d negative=%0d",m,wet_frames,positive,negative);
  end
  $display("FX_PASS frames=%0d",checks);$finish;
 end
endmodule
