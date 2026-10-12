`timescale 1ns/1ps
module tb_hdmi_link;
 reg clk27=0,rst_n=0;always #18.518519 clk27=~clk27;
 wire sclk,pclk,locked;wire cp,cn;wire [2:0] dp,dn;
 hdmi_clocks clocks(clk27,rst_n,sclk,pclk,locked);
 // Constant black active video produces stable all-zero encoded data.
 hdmi_tx dut(pclk,sclk,rst_n && locked,8'd0,8'd0,8'd0,1'b0,1'b0,1'b1,cp,cn,dp,dn);
 GSR GSR(.GSRI(1'b1));
 realtime last_pixel,last_serial,pperiod,speriod;integer n,k,rot;
 reg [9:0] cword,bword,gword,rword;
 reg [9:0] rotated,expected_clock;
 initial begin
  #200;rst_n=1;wait(locked);repeat(30)@(posedge pclk);
  @(posedge pclk);last_pixel=$realtime;@(posedge pclk);pperiod=$realtime-last_pixel;
  @(posedge sclk);last_serial=$realtime;@(posedge sclk);speriod=$realtime-last_serial;
  if(pperiod<39.67 || pperiod>39.70 || speriod<7.92 || speriod>7.95)$fatal(1,"Clock frequency wrong pixel=%f serial=%f",pperiod,speriod);
  rot=-1;
  for(n=0;n<100;n=n+1)begin
   for(k=0;k<10;k=k+1)begin
    @(sclk);#0.1;cword[k]=cp;bword[k]=dp[0];gword[k]=dp[1];rword[k]=dp[2];
    if(cn!==!cp || dn!==~dp)$fatal(1,"Differential complement failure");
   end
   // Find bit rotation once, then enforce same alignment on every channel.
   if(n==0)begin
    expected_clock=10'b0000011111;
    for(k=0;k<10;k=k+1)begin
     rotated=(expected_clock>>k)|(expected_clock<<(10-k));
     if(cword===rotated)rot=k;
    end
    if(rot<0)$fatal(1,"Clock lane is not 5 high/5 low");
   end
   expected_clock=10'b0000011111;
   rotated=(expected_clock>>rot)|(expected_clock<<(10-rot));
   if(cword!==rotated)$fatal(1,"Clock lane alignment changed");
   expected_clock=10'b0101010100; // VS=1,HS=0 control word on blue.
   rotated=(expected_clock>>rot)|(expected_clock<<(10-rot));
   if(bword!==rotated)$fatal(1,"Blue serializer bit order/alignment failure %b rot=%0d",bword,rot);
   expected_clock=10'b1101010100;
   rotated=(expected_clock>>rot)|(expected_clock<<(10-rot));
   if(gword!==rotated || rword!==rotated)$fatal(1,"Red/green serializer order failure");
  end
  $display("HDMI_LINK_TEST_PASS vendor PLL CLKDIV OSER10 TLVDS models: pixel=%fns serial=%fns",pperiod,speriod);$finish;
 end
 initial begin #1000000;$fatal(1,"PLL/serializer timeout");end
endmodule
