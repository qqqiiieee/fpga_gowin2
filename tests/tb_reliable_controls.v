`timescale 1ns/1ps
module tb_reliable_controls;
 reg clk=0;always #5 clk=~clk;reg rst=0,ready=1,valid=0;
 reg [1:0] channel=0;reg [15:0] data=0;
 wire h0,h1;wire [7:0] v0,v1,volume;wire signed [8:0] pitch;
 wire [1:0] calibrated,armed;wire slider_ready;
 pressure_adaptive #(.CAL_SAMPLES(4)) pads(clk,rst,ready,valid,channel,data,h0,h1,v0,v1,calibrated,armed);
 slider_controls #(.STALE_CYCLES(400)) sliders(clk,rst,valid,channel,data,volume,pitch,slider_ready);
 reg [15:0] keys=0;reg ghost=0;wire muted;
 headphone_mute_guard #(.HOLD_CYCLES(20),.MAX_CYCLES(60)) guard(clk,rst,keys,ghost,muted);
 integer hits0=0,hits1=0,j;reg [7:0] weak;
 always @(negedge clk) begin if(h0)hits0=hits0+1;if(h1)hits1=hits1+1;end
 task cycles;input integer n;integer i;begin repeat(n) @(negedge clk);end endtask
 task send;input [1:0] c;input [15:0] d;begin
   @(negedge clk);channel=c;data=d;valid=1;@(negedge clk);valid=0;cycles(2);
 end endtask
 initial begin
   cycles(3);rst=1;cycles(3);
   if(volume!=160 || pitch!=0) $fatal(1,"default controls mute keyboard");
   for(j=0;j<4;j=j+1) begin send(0,1200);send(1,1800);end
   if(calibrated!=3 || armed!=3 || hits0 || hits1) $fatal(1,"nonzero rest calibration failed");
   send(0,1424);weak=v0;
   if(hits0!=1 || weak<96 || hits1) $fatal(1,"light strike missed");
   repeat(20)send(0,1424);
   if(hits0!=1) $fatal(1,"steady load repeated hits");
   send(0,1250);send(0,1474);
   if(hits0!=2) $fatal(1,"residual rest did not rearm");
   send(0,1250);send(0,1250);send(0,1250);send(0,10000);
   if(hits0!=3 || v0<=weak) $fatal(1,"strong velocity missing");
   send(0,10000);send(0,10000);send(0,3300);
   repeat(20)send(0,3300);
   if(hits0!=3) $fatal(1,"partial release plateau auto-retriggered");
   send(0,3524);send(1,2024);
   if(hits0!=4 || hits1!=1) $fatal(1,"independent light pads failed");
   ready=0;cycles(3);ready=1;
   for(j=0;j<4;j=j+1) begin send(0,7000);send(1,8000);end
   if(hits0!=4 || hits1!=1 || calibrated!=3) $fatal(1,"recovery calibration auto-hit held pad");
   send(0,1200);send(1,1800);send(0,1424);send(1,2024);
   if(hits0!=5 || hits1!=2) $fatal(1,"post-fault pads stuck");
   send(2,0);send(3,13107);
   if(volume!=0 || pitch!=0 || !slider_ready) $fatal(1,"slider low/center mapping");
   repeat(30)send(2,26400);repeat(30)send(3,26400);
   if(volume<254 || pitch<126) $fatal(1,"slider high mapping/smoothing");
   cycles(450);if(slider_ready || volume<254 || pitch<126) $fatal(1,"stale ADC lost last slider values");
   send(2,13107);send(3,0);
   if(volume<126 || volume>129 || pitch!=-128) $fatal(1,"slider reconnect mapping");
   keys=16'hc000;cycles(10);keys=0;cycles(10);
   if(muted) $fatal(1,"quick shortcut tap muted keys");
   keys=16'hc000;ghost=1;cycles(30);if(muted) $fatal(1,"ghost triggered mute");
   ghost=0;cycles(25);if(!muted) $fatal(1,"intentional mute unavailable");
   cycles(65);if(muted) $fatal(1,"stuck shortcut permanently muted");
   cycles(80);if(muted) $fatal(1,"stuck shortcut auto-rearmed");
   keys=16'h4000;cycles(30);keys=16'hc000;cycles(30);
   if(muted) $fatal(1,"partial release rearmed mute");
   keys=0;cycles(3);keys=16'hc000;cycles(25);if(!muted)$fatal(1,"full release failed to rearm");
   keys=0;cycles(3);if(muted)$fatal(1,"release failed to unmute");
   $display("RELIABLE_CONTROLS_TEST_PASS nonzero-rest/light/held/residual/strength/recovery/sliders/stale/ghost/mute-timeout");$finish;
 end
 initial begin #500000;$fatal(1,"controls timeout");end
endmodule
