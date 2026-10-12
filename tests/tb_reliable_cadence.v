`timescale 1ns/1ps
module tb_reliable_cadence;
 reg clk=0;always #5 clk=~clk;reg rst=0;
 tri1 scl,sda;wire valid,fault;wire [1:0] channel;wire [15:0] data;
 reg [63:0] analog_values={16'd13107,16'd20000,16'd1800,16'd1200};
 ads1115_reader #(.RETRY_CYCLES(10),.PRESSURE_PRIORITY(1)) adc(clk,rst,scl,sda,valid,channel,data,fault);
 mock_ads1115 mock(rst,analog_values,scl,sda);
 reg [1:0] seen=0;
 always @(posedge clk) if(!rst || fault) seen<=0;else if(valid && channel<2) seen[channel]<=1;
 wire h0,h1;wire [7:0] v0,v1;wire [1:0] calibrated,armed;
 pressure_adaptive pads(clk,rst,&seen,valid,channel,data,h0,h1,v0,v1,calibrated,armed);
 integer cycles=0,count=0,k,last_seen[0:3],period[0:3],changed,latency,expected;
 always @(posedge clk) if(rst) begin
   cycles=cycles+1;
   if(valid) begin
     case(count%6) 0,3:expected=0;1,4:expected=1;2:expected=2;5:expected=3;endcase
     if(channel!=expected) $fatal(1,"not pressure priority 012013 schedule");
     if(last_seen[channel]>=0) period[channel]=cycles-last_seen[channel];
     last_seen[channel]=cycles;count=count+1;
   end
 end
 initial begin
   for(k=0;k<4;k=k+1)begin last_seen[k]=-1;period[k]=0;end
   repeat(5) @(negedge clk);rst=1;wait(calibrated==3 && count>=60);
   wait(valid && channel==0);@(negedge clk);changed=cycles;analog_values[15:0]=1424;
   wait(h0);@(negedge clk);latency=cycles-changed;
   if(fault || period[0]<=0 || period[0]!=period[1] || h1 || v0<96) $fatal(1,"priority cadence/trigger failed");
   if(latency>216000 || period[2]>432000 || period[3]>432000) $fatal(1,"priority latency exceeded pad8ms/slider16ms");
   $display("Pressure period=%0d clk (%0f ms); slider period=%0d clk (%0f ms); light-hit worst-phase=%0d clk (%0f ms)",period[0],period[0]/27000.0,period[2],period[2]/27000.0,latency,latency/27000.0);
   $display("RELIABLE_CADENCE_TEST_PASS actual100kHz/conversion/012013/sliders/light-raw-hit");$finish;
 end
 initial begin #100000000;$fatal(1,"cadence timeout");end
endmodule
