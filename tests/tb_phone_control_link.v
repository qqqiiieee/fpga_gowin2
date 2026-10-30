`timescale 1ns/1ps
module tb_phone_control_link;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,rx=1;
 wire tx,set_valid,panic;wire[7:0]param,value;
 reg[7:0] data[0:15];
 wire[7:0]read_value=data[param[3:0]];
 wire[7:0]outbyte;wire outvalid,outerror;
 integer commits=0,panics=0,received=0,i,j,base,old;
 reg[7:0] reply[0:255];reg[7:0] request[0:11];reg[7:0]sum;
 phone_control_link #(.CLK_HZ(1000000),.BAUD(100000),.TIMEOUT_CYCLES(250)) dut(
  .clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),.set_valid(set_valid),.panic(panic),
  .param(param),.value(value),.read_value(read_value),.status_flags(8'h19),
  .current_timbre(8'd1),.current_fx(8'd2),.current_volume(8'd180));
 midi_uart_rx #(.CLK_HZ(1000000),.BAUD(100000)) monitor(
  .clk(clk),.rst_n(rst_n),.rx(tx),.data(outbyte),.data_valid(outvalid),.framing_error(outerror));
 always @(posedge clk)if(rst_n)begin
  if(set_valid)begin commits<=commits+1;data[param[3:0]]<=value;end
  if(panic)panics<=panics+1;
  if(outerror)$fatal(1,"bad UART reply stop bit");
  if(outvalid)begin reply[received%256]<=outbyte;received<=received+1;end
 end
 task byte_send(input[7:0]v);integer n;begin
  @(negedge clk);rx=0;repeat(10)@(negedge clk);
  for(n=0;n<8;n=n+1)begin rx=v[n];repeat(10)@(negedge clk);end
  rx=1;repeat(10)@(negedge clk);
 end endtask
 task make(input[7:0]seq,cmd,p,v);integer n;begin
  request[0]=8'ha5;request[1]=8'h5a;request[2]=1;request[3]=seq;
  request[4]=cmd;request[5]=p;request[6]=v;
  for(n=7;n<11;n=n+1)request[n]=0;
  sum=0;for(n=2;n<11;n=n+1)sum=sum^request[n];request[11]=sum;
 end endtask
 task checksum_fix;integer n;begin
  sum=0;for(n=2;n<11;n=n+1)sum=sum^request[n];request[11]=sum;
 end endtask
 task send;integer n;begin base=received;for(n=0;n<12;n=n+1)byte_send(request[n]);end endtask
 task expect_reply(input[7:0]result,effective);integer n,age;reg[7:0]check;begin
  age=0;while(received<base+12 && age<2000)begin @(negedge clk);age=age+1;end
  if(received!=base+12)$fatal(1,"reply missing count=%0d base=%0d",received,base);
  if(reply[(base+0)%256]!=8'h5a || reply[(base+1)%256]!=8'ha5 || reply[(base+2)%256]!=1 ||
     reply[(base+3)%256]!=request[3] || reply[(base+4)%256]!=result ||
     reply[(base+5)%256]!=request[5] || reply[(base+6)%256]!=effective)
     $fatal(1,"wrong reply seq=%0d result=%0d value=%0d expected=%0d/%0d",request[3],reply[(base+4)%256],reply[(base+6)%256],result,effective);
  if(reply[(base+7)%256]!=8'h19 || reply[(base+8)%256]!=1 || reply[(base+9)%256]!=2 || reply[(base+10)%256]!=180)$fatal(1,"status snapshot");
  check=0;for(n=2;n<11;n=n+1)check=check^reply[(base+n)%256];
  if(reply[(base+11)%256]!=check)$fatal(1,"reply XOR");
  repeat(20)@(negedge clk);
 end endtask
 initial begin
  for(i=0;i<16;i=i+1)data[i]=0;
  data[0]=180;data[3]=0;data[4]=64;
  repeat(5)@(negedge clk);rst_n=1;repeat(20)@(negedge clk);
  make(0,0,4,0);send;expect_reply(0,64);
  make(1,1,4,200);send;expect_reply(0,200);
  // ACK comes from actual state, repeated absolute SET remains same value.
  make(1,1,4,200);send;expect_reply(0,200);
  make(255,1,3,3);send;expect_reply(0,3);
  make(0,0,3,0);send;expect_reply(0,3);
  old=commits;
  make(2,1,3,4);send;expect_reply(3,3);
  make(3,1,1,2);send;expect_reply(3,0);
  make(4,1,12,4);send;expect_reply(3,0);
  make(5,1,15,1);send;expect_reply(2,0);
  make(6,7,0,0);send;expect_reply(1,180);
  make(7,0,0,1);send;expect_reply(3,180);
  make(8,1,4,99);request[7]=1;checksum_fix;send;expect_reply(4,200);
  make(9,1,4,99);request[2]=2;checksum_fix;send;expect_reply(4,200);
  make(10,0,16,0);send;expect_reply(2,180);
  if(commits!=old)$fatal(1,"invalid requests committed");
  make(11,1,4,99);request[11]=request[11]^1;send;repeat(1500)@(negedge clk);
  if(received!=base || commits!=old)$fatal(1,"bad XOR caused action");
  // Half frame timeout, noise and repeated header byte all recover.
  byte_send(8'ha5);byte_send(8'h5a);byte_send(1);repeat(300)@(negedge clk);
  byte_send(8'h00);byte_send(8'ha5);byte_send(8'ha5);
  make(12,0,4,0);send;expect_reply(0,200);
  make(13,2,0,0);send;expect_reply(0,180);
  if(panics!=1)$fatal(1,"Panic not one pulse");
  make(14,2,1,0);send;expect_reply(3,0);
  if(panics!=1)$fatal(1,"invalid Panic committed");
  // Exercise every legal parameter boundary; read-only flags GET is allowed.
  for(j=0;j<15;j=j+1)begin
   i=(j==1 || j==2 || j==13 || j==14)?1:((j==3 || j==12)?3:255);
   make(20+j,1,j,i);send;expect_reply(0,i);
   make(50+j,0,j,0);send;expect_reply(0,i);
  end
  make(80,0,15,0);send;expect_reply(0,0);
  $display("PHONE_CONTROL_LINK_PASS validated_set=%0d panic=%0d reply_bytes=%0d",commits,panics,received);$finish;
 end
 initial begin #3000000;$fatal(1,"test timeout");end
endmodule
