`timescale 1ns/1ps
`include "tests/pcm5102a_serial_checker.vh"
module tb_pcm5102a_i2s;
 reg clk=0,rst=0;always #18.518519 clk=~clk;
 reg [15:0] sample=0;
 wire bck,lrck,din,hb,hw,hd,tick;wire [31:0] words,nonzero_words;
 pcm5102a_i2s dut(.clk(clk),.rst_n(rst),.sample(sample),.bck(bck),.lrck(lrck),.din(din));
 pt8211_driver original(.clk(clk),.rst_n(rst),.sample(sample),.bck(hb),.ws(hw),.din(hd),.fs_tick(tick));
 pcm5102a_serial_checker check_serial(.clk(clk),.rst_n(rst),.tick(tick),.pcm(sample),
  .bck(bck),.lrck(lrck),.din(din),.hp_bck(hb),.hp_ws(hw),.hp_din(hd),
  .words(words),.nonzero_words(nonzero_words));
 integer n,k,epoch,total_words=0;reg[15:0] lfsr=16'hace1;
 task frame;input[15:0] value;begin
  // 改变整个帧内的输入，证明两个声道只使用边界缓存，不随sample撕裂。
  @(negedge clk);sample=value;@(posedge tick);@(negedge clk);
  repeat(37)@(negedge clk);sample=~value;
  repeat(150)@(negedge clk);
 end endtask
 initial begin
  #3;rst=1;#7;rst=0;#23;
  if({bck,lrck,din}!==0)$fatal(1,"asynchronous reset did not clear outputs");
  @(negedge clk);rst=1;
  for(epoch=0;epoch<3;epoch=epoch+1)begin
   frame(0);frame(16'h7fff);frame(16'h8000);frame(16'hffff);frame(16'h0001);
   frame(16'h8001);frame(16'haaaa);frame(16'h5555);
   for(k=0;k<16;k=k+1)begin frame(16'h1<<k);frame(~(16'h1<<k));end
   for(n=0;n<128;n=n+1)begin
    lfsr={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};frame(lfsr);
   end
   // 保持数字零若干整帧，包括由非零转入静音的边界。
   @(negedge clk);sample=0;repeat(288*5)@(negedge clk);
   if(words<300 || nonzero_words<250)$fatal(1,"insufficient decoded coverage");
   total_words=total_words+words;
   // 在不同半帧中异步复位，再次验证启动零帧和完整左右声道。
   repeat(31+epoch*83)@(negedge clk);#7;rst=0;#1;
   if({bck,lrck,din,hb,hw,hd}!==0)$fatal(1,"mid-frame reset did not clear");
   #47;@(negedge clk);rst=1;
  end
  $display("PCM5102A_I2S_TEST_PASS decoded_words=%0d reset_epochs=3 signed_patterns=1 frame_latching=1",total_words);$finish;
 end
 initial begin #10000000;$fatal(1,"I2S test timeout");end
endmodule
