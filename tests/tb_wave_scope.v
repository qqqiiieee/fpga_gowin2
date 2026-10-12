module tb_wave_scope;
 reg sclk=0,pclk=0;
 always #5 sclk=~sclk;
 always #7 pclk=~pclk;
 reg srst=0,prst=0,tick=0,frame=0;
 reg [15:0] pcm=0,peak=10000;
 reg [7:0] addr=0;
 wire signed [15:0] cur,prev;
 wire [3:0] gain;
 wire valid;
 wave_scope #(.TRIGGER_TIMEOUT(8)) dut(sclk,srst,tick,pcm,pclk,prst,frame,addr,cur,prev,gain,valid);
 task need;
  input condition;input [511:0] message;
  begin if(condition!==1'b1)begin $display("FAIL %s",message);$fatal;end end
 endtask
 task frame_edge;
  begin @(negedge pclk);frame=1;@(negedge pclk);frame=0;repeat(8)@(negedge pclk);end
 endtask
 task sample_value;
  input [15:0] value;
  begin @(negedge sclk);pcm=value;tick=1;@(negedge sclk);tick=0;repeat(5)@(negedge sclk);end
 endtask
 integer i;
 initial begin
  repeat(5)@(negedge sclk);srst=1;prst=1;repeat(10)@(negedge sclk);
  need(!valid && cur==0,"no uninitialized RAM is displayed");
  frame_edge;
  sample_value(16'hffff);sample_value(16'd1000);
  for(i=1;i<=1020;i=i+1)sample_value(1000+i);
  repeat(12)@(negedge pclk);
  need(!valid,"back bank hidden before frame swap");
  frame_edge;
  need(valid && gain==3,"first snapshot gain belongs to captured PCM bank");
  addr=0;repeat(3)@(negedge pclk);need(cur==1000 && prev==1000,"trigger point");
  addr=1;repeat(3)@(negedge pclk);need(cur==1004 && prev==1000,"four sample spacing and continuous segments");
  addr=255;repeat(3)@(negedge pclk);need(cur==2020 && prev==2016,"last sample point");
  // New capture must not modify the displayed bank while it is being written.
  peak=100;sample_value(16'hffff);sample_value(16'd3000);
  for(i=1;i<=1020;i=i+1)sample_value(3000+i);
  addr=1;repeat(4)@(negedge pclk);need(cur==1004 && gain==3,"front and gain immutable during back capture");
  frame_edge;
  addr=1;repeat(3)@(negedge pclk);need(cur==3004 && gain==2,"second waveform/gain snapshot visible together");
  // Unipolar/DC input must eventually capture by timeout.
  for(i=0;i<1030;i=i+1)sample_value(16'd777);
  frame_edge;addr=255;repeat(3)@(negedge pclk);need(cur==777 && prev==777,"DC trigger timeout");
  srst=0;prst=0;repeat(5)@(negedge pclk);need(!valid && cur==0,"joint reset hides previous frame");
  srst=1;prst=1;frame_edge;
  for(i=0;i<1024;i=i+1)sample_value(16'd0);
  frame_edge;repeat(3)@(negedge pclk);need(valid && cur==0 && prev==0,"reset rearm and flat true zero");
  $display("WAVE_SCOPE_TEST_PASS");$finish;
 end
 initial begin #2000000;$fatal(1,"scope timeout");end
endmodule
