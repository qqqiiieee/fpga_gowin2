`timescale 1ns/1ps
module tb_tmds_encoder;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg [7:0] data=0;reg de=0,c0=0,c1=0;wire [9:0] symbol;
 tmds_encoder dut(clk,rst_n,data,de,c0,c1,symbol);
 reg [20:0] vectors [0:4107];
 integer n;
 initial begin
  $readmemh("tmds_vectors.hex",vectors);#12;rst_n=1;
  for(n=0;n<4108;n=n+1)begin
   @(negedge clk);{de,c1,c0,data}=vectors[n][20:10];
   @(posedge clk);#1;
   if(symbol!==vectors[n][9:0])$fatal(1,"TMDS independent vector mismatch n=%0d input=%02x got=%03x want=%03x",n,data,symbol,vectors[n][9:0]);
  end
  $display("TMDS_ENCODER_TEST_PASS 4108 independent vectors all input bytes/control tokens/running disparity");$finish;
 end
endmodule
