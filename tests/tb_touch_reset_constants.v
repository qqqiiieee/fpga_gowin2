`timescale 1ns/1ps
// 针对DI0004的硬件复位契约：16字经校准修改后，无时钟的短复位也恢复默认值。
module tb_touch_reset_constants;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=1,cal_write=0;reg [3:0] cal_index=0;reg [11:0] cal_value=0;
 reg [11:0] expected[0:15];integer i,checks=0;
 analog_touch_keypad dut(.clk(clk),.rst_n(rst_n),.sample_valid(1'b0),.sample_data(12'd0),
   .cal_write(cal_write),.cal_index(cal_index),.cal_value(cal_value),
   .keys(),.raw_value(),.valid(),.fault());
 task verify;
  integer k;begin
   for(k=0;k<16;k=k+1)begin
    if(dut.centers[k]!==expected[k])$fatal(1,"async default mismatch index=%0d got=%h expected=%h",k,dut.centers[k],expected[k]);
    checks=checks+1;
   end
  end
 endtask
 initial begin
  $readmemh("src/touch_centers.hex",expected);
  #1;rst_n=0;#1;verify;rst_n=1;
  for(i=0;i<16;i=i+1)begin
   @(negedge clk);cal_write=1;cal_index=i;cal_value=~expected[i];
   @(posedge clk);#1;
   if(dut.centers[i]!==cal_value)$fatal(1,"runtime calibration did not update center %0d",i);
  end
  @(negedge clk);cal_write=0;
  // Between the falling edge at x0 and rising edge at x5: pulse contains NO posedge.
  #1;rst_n=0;#1;verify;rst_n=1;#1;verify;
  if(dut.centers[0]!==12'h04f)$fatal(1,"default key1 bit11 did not clear after calibrating it high");
  $display("TOUCH_RESET_CONSTANTS_TEST_PASS checks=%0d async_without_clock=1 calibrated_bit11_restored=1",checks);
  $finish;
 end
endmodule
