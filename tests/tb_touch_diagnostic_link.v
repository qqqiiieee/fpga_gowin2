`timescale 1ns/1ps
// 新诊断09与旧控制08的端口级UART回归；不强制DUT内部串口或状态。
module tb_touch_diagnostic_link;
 reg clk=0,rst_n=0,rx=1;
 always #5 clk=~clk;
 wire tx,remote,zero,park,accepted,cal_write;
 wire [15:0] keys;wire [7:0] velocity,seq;wire [63:0] adc;
 wire [3:0] ci;wire [11:0] cv;
 integer writes=0,acks=0,k,j;reg [7:0] cmd[0:15],reply[0:15];
 reg [7:0] sum,value;reg [3:0] captured_index;reg [11:0] captured_value;
 remote_debug_link #(.CLK_HZ(100000),.BAUD(10000),.TIMEOUT_CYCLES(50000),.DIAG_ENABLE(1)) dut(
 .clk(clk),.rst_n(rst_n),.uart_rx(rx),.uart_tx(tx),.physical_keys(16'h0123),
 .physical_adc(64'h1111222233334444),.status_flags(8'h28),
 .remote_active(remote),.zero_mode(zero),.park_i2c(park),.virtual_keys(keys),
 .velocity(velocity),.virtual_adc(adc),.accepted(accepted),.last_seq(seq),
 .diagnostic_data(64'h1234000380010abc),.cal_write(cal_write),.cal_index(ci),.cal_value(cv));
 always @(posedge clk)begin #1;if(cal_write)begin writes=writes+1;captured_index=ci;captured_value=cv;end end
 // 应答解码与发命令独立并行，整帧只按线上BCLK位时间读取。
 initial forever begin
  @(negedge tx);
  for(j=0;j<16;j=j+1)begin
   repeat(15)@(negedge clk);
   for(k=0;k<8;k=k+1)begin value[k]=tx;repeat(10)@(negedge clk);end
   if(tx!==1)$fatal(1,"DIAG stop bit");reply[j]=value;
   if(j<15)@(negedge tx);else repeat(5)@(negedge clk);
  end
  sum=0;for(j=2;j<15;j=j+1)sum=sum^reply[j];
  if(reply[0]!==8'h5a||reply[1]!==8'ha5||reply[15]!==sum)$fatal(1,"DIAG response frame/XOR");
  acks=acks+1;
 end
 task request;
 input[7:0] id,flags,index;input[15:0] val;input corrupt;
 integer i,b;reg[7:0] check;
 begin
  for(i=0;i<16;i=i+1)cmd[i]=0;
  cmd[0]=8'ha5;cmd[1]=8'h5a;cmd[2]=id;cmd[3]=flags;cmd[4]=index;
  cmd[6]=160;cmd[7]=val[7:0];cmd[8]=val[15:8];check=0;
  for(i=2;i<15;i=i+1)check=check^cmd[i];cmd[15]=check^corrupt;
  for(i=0;i<16;i=i+1)begin
   @(negedge clk);rx=0;repeat(10)@(negedge clk);
   for(b=0;b<8;b=b+1)begin rx=cmd[i][b];repeat(10)@(negedge clk);end
   rx=1;repeat(10)@(negedge clk);
  end
 end endtask
 task wait_ack;input integer count;integer n;begin
  n=0;while(acks<count&&n<2200)begin @(negedge clk);n=n+1;end
  if(acks!=count)$fatal(1,"DIAG missing ACK expected=%0d actual=%0d",count,acks);
  repeat(20)@(negedge clk);
 end endtask
 initial begin
 repeat(4)@(negedge clk);rst_n=1;
 request(8'h31,8'h80,0,0,0);wait_ack(1);
 if(reply[2]!==9||reply[3]!==8'h31||{reply[8],reply[7]}!==16'h0abc||
    {reply[10],reply[9]}!==16'h8001||remote||writes)$fatal(1,"DIAG read payload/side effect");
 request(8'h32,8'h81,10,16'h0321,0);wait_ack(2);
 if(writes!=1||captured_index!=10||captured_value!=12'h321||remote||
    {reply[12],reply[11]}!==16'ha321||{reply[14],reply[13]}!==16'ha10a)
    $fatal(1,"DIAG calibration commit/echo");
 request(8'h33,8'h81,0,4095,0);repeat(2200)@(negedge clk);
 if(acks!=2||writes!=1)$fatal(1,"DIAG accepted full-scale invalid calibration");
 request(8'h34,8'h81,1,400,1);repeat(2200)@(negedge clk);
 if(acks!=2||writes!=1)$fatal(1,"DIAG accepted corrupt calibration");
 request(8'h35,8'h01,8'h42,100,0);wait_ack(3);
 if(reply[2]!==8||!remote||keys!=16'h0042||seq!=8'h35)$fatal(1,"DIAG broke legacy protocol");
 request(8'h36,8'h80,0,0,0);wait_ack(4);
 if(!remote||keys!=16'h0042||seq!=8'h35||reply[2]!==9)$fatal(1,"DIAG query changed remote controls");
 // 查询不得刷新远程watchdog，随后仍按最后08控制命令超时释放。
 repeat(50000)@(negedge clk);
 if(remote||keys!=0)$fatal(1,"DIAG prevented remote timeout");
 $display("TOUCH_DIAGNOSTIC_LINK_TEST_PASS acks=%0d cal_writes=%0d old08_and_new09=1 invalid_rejected=2",acks,writes);$finish;
 end
 initial begin #3000000;$fatal(1,"TOUCH_DIAGNOSTIC_LINK watchdog");end
endmodule
