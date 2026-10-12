module tb_instrument_telemetry;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,tick=0;
 reg [15:0] pcm=0;
 reg [11:0] keys=0;
 reg [7:0] volume=128;
 reg signed [8:0] pitch=0;
 reg [31:0] busy=0;
 wire [15:0] peak,rms,hz,bcd;
 wire signed [7:0] dbfs;
 wire [7:0] peak_percent,volume_percent;
 wire [5:0] voices;
 wire [6:0] note;
 wire valid,clip;
 integer change_cycle;
 instrument_telemetry dut(clk,rst_n,tick,pcm,keys,volume,pitch,busy,
   peak,rms,dbfs,peak_percent,volume_percent,voices,note,valid,hz,bcd,clip);
 task need;
  input condition;
  input [511:0] message;
  begin if(condition!==1'b1)begin $display("FAIL %s",message);$fatal;end end
 endtask
 task samples;
  input integer count;
  input [15:0] value;
  integer i;
  begin
   pcm=value;
   for(i=0;i<count;i=i+1)begin
    @(negedge clk);tick=1;@(negedge clk);tick=0;
    repeat(287)@(negedge clk);
   end
   repeat(60)@(negedge clk);
  end
 endtask
 initial begin
  repeat(5)@(negedge clk);rst_n=1;
  repeat(150)@(negedge clk);
  need(dbfs==-96 && hz==0 && bcd==0 && !valid,"silent/reset status");
  need(volume_percent==50,"volume128 is50percent");
  volume=255;busy=32'hffffffff;keys=12'h020;
  repeat(150)@(negedge clk);
  need(volume_percent==100 && voices==32,"gain and voice population");
  need(valid && note==69 && hz==440 && bcd==16'h0440,"A4 uses actual DDS frequency");
  pitch=127;repeat(150)@(negedge clk);
  need(hz==467 && bcd==16'h0467,"positive pitch bend");
  pitch=-128;repeat(150)@(negedge clk);
  need(hz==413 && bcd==16'h0413,"negative pitch bend");
  pitch=0;keys=12'h021;repeat(150)@(negedge clk);
  need(note==60 && hz==262 && bcd==16'h0262,"chord lowest held setting");
  keys=12'h020;
  for(change_cycle=0;change_cycle<100;change_cycle=change_cycle+1)begin
   @(negedge clk);
   if(valid)begin
    if(note==60)need(bcd==16'h0262,"C4 note and digits publish atomically");
    else if(note==69)need(bcd==16'h0440,"A4 note and digits publish atomically");
    else need(0,"unexpected transitional note");
   end
  end
  need(note==69 && bcd==16'h0440,"atomic A4 change completes");
  keys=0;repeat(150)@(negedge clk);
  need(!valid && hz==0 && bcd==0,"release clears setting");
  samples(2048,16'd10000);
  need(peak==10000 && rms==10000 && dbfs==-10 && peak_percent==31,"true RMS constant10000");
  samples(2048,16'hd8f0);
  need(peak==10000 && rms==10000,"negative PCM signed magnitude");
  samples(2048,16'h8000);
  need(peak==32768 && rms==32768 && dbfs==0 && peak_percent==100 && clip,"signed minimum full scale");
  samples(12288,16'd0);
  need(peak==0 && rms==0 && dbfs==-96 && !clip,"zero clears level and clipping hold");
  $display("INSTRUMENT_TELEMETRY_TEST_PASS");$finish;
 end
 initial begin #70000000;$fatal(1,"telemetry timeout");end
endmodule
