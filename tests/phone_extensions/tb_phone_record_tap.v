`timescale 1ns/1ps
module tb_phone_record_tap;
 parameter LIMIT=7;
 reg clk=0,rst_n=0,tick=0,start=0,stop=0,ready=1;
 reg signed[15:0]pcm=0;wire active,busy,valid;wire[31:0]count,crc;wire[15:0]dropped;wire[7:0]typ;wire[47:0]payload;
 phone_record_tap #(.MAX_SAMPLES(LIMIT)) dut(.clk(clk),.rst_n(rst_n),.sample_tick(tick),.pcm(pcm),.start(start),.stop(stop),.active(active),.busy(busy),.sample_count(count),.dropped(dropped),.packet_valid(valid),.packet_type(typ),.packet_payload(payload),.packet_ready(ready),.pcm_crc32(crc));
 always #5 clk=~clk;
 integer which=0,session=0,cycles=0,packets=0,eofs=0,n=0,k=0,target=0;
 reg stalled=0;reg[55:0]held_packet;reg[31:0]crc_when_eof;
 always @(posedge clk)begin
 cycles=cycles+1;
 if(rst_n)begin
  if(stalled && (!valid || {typ,payload}!==held_packet))$fatal(1,"PACKET_CHANGED_UNDER_BACKPRESSURE");
  if(valid && typ==8'h41)begin
   if(active || dut.crc_bits!=0)$fatal(1,"EARLY_EOF");
   crc_when_eof=crc;
  end
  if(valid && ready)begin
   packets=packets+1;
   if(typ==8'h40)$display("REC_DATA session=%0d a=%0d b=%0d c=%0d",session,$signed(payload[15:0]),$signed(payload[31:16]),$signed(payload[47:32]));
   else if(typ==8'h41)begin eofs=eofs+1;$display("REC_EOF session=%0d count=%0d dropped=%0d crc=%08h",session,payload[31:0],payload[47:32],crc);end
   else $fatal(1,"BAD_PACKET_TYPE");
  end
  stalled=valid && !ready;held_packet={typ,payload};
 end else stalled=0;
 end
 task input_sample;input integer value;begin
  @(negedge clk);pcm=value;tick=1;@(negedge clk);tick=0;repeat(2)@(negedge clk);
 end endtask
 function integer raw;input integer i;begin
  case(i/6%7)
   0:raw=-32768;
   1:raw=-5+i%6;
   2:raw=5-i%6;
   3:raw=32767;
   4:raw=(i%2)?32767:-32768;
   5:raw=100+i%6;
   default:raw=-100-i%6;
  endcase
 end endfunction
 task begin_record;begin @(negedge clk);start=1;@(negedge clk);start=0;if(!busy || !active)$fatal(1,"START_NOT_ACCEPTED");end endtask
 initial begin
  if($value$plusargs("CASE=%d",which))begin end
  repeat(4)@(negedge clk);rst_n=1;begin_record;
  if(which==2 || which==3)ready=0;
  target=(which==1)?5:LIMIT;
  for(n=0;n<target*6;n=n+1)begin
   input_sample(raw(n));
   if(n==8)begin start=1;@(negedge clk);start=0;end // busy start MUST NOT reset count/CRC.
   if(which==0)ready=(n%7!=0);
  end
  if(which==1)begin
   input_sample(30000);input_sample(30000);input_sample(30000);
   @(negedge clk);pcm=30000;tick=1;stop=1;@(negedge clk);tick=0;stop=0;
  end
  if(which==2 || which==3)begin
   if(active || count!=LIMIT || dropped==0)$fatal(1,"OVERFLOW_OR_LIMIT_NOT_REACHED");
   ready=1;
  end else ready=1;
  // Hold EOF itself, attempt re-entry, then consume exactly one EOF.
  wait(valid && typ==8'h41);@(negedge clk);ready=0;start=1;
  repeat(5)@(negedge clk);
  if(!busy || active || count!=target || crc!=crc_when_eof)$fatal(1,"EOF_STALL_OR_REENTRY");
  start=0;ready=1;wait(!busy);repeat(5)@(negedge clk);
  if(eofs!=1 || active)$fatal(1,"EOF_SEQUENCE");
  // Empty next session proves accepted start invalidates stale FIFO and CRC.
  session=1;begin_record;@(negedge clk);stop=1;@(negedge clk);stop=0;
  wait(!busy);repeat(5)@(negedge clk);
  if(eofs!=2 || count!=0 || crc!=0 || dropped!=0)$fatal(1,"RESTART_EMPTY_CRC");
  $display("RECORD_TEST_PASS case=%0d packets=%0d",which,packets);$finish;
 end
 initial begin #1000000000;$fatal(1,"RECORD_TIMEOUT");end
endmodule
