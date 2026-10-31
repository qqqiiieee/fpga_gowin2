`timescale 1ns/1ps
module tb_v041_phone_extensions;
 reg clk=0;always #18.5185185 clk=~clk;
 reg rst_n=0,rx=1;
 wire tx,set_valid,panic,get_valid,ext_valid,ext_done;
 wire [7:0] param,value,ext_op,ext_status;
 wire [39:0] ext_data;wire [31:0] ext_reply;
 reg audio_valid=1;reg [47:0] audio_payload=48'h1234fedc5678;
 wire audio_ready;wire sw,mw,mc,me,mb,rs,rt,gcv;wire [1:0]gc;
 wire [8:0]sa;wire[31:0]sd,sc;wire[7:0]ma;wire[6:0]md;wire[27:0]pads,ccs;
 reg idle=1,pixelack=0,recordbusy=0; reg mc_ack=0; always @(posedge clk) mc_ack<=mc;
 phone_extended_link link(.clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),
  .set_valid(set_valid),.panic(panic),.param(param),.value(value),.get_valid(get_valid),
  .read_value(8'd42),.status_flags(8'd0),.current_timbre(8'd0),.current_fx(8'd0),.current_volume(8'd160),
  .ext_valid(ext_valid),.ext_op(ext_op),.ext_data(ext_data),.ext_done(ext_done),.ext_status(ext_status),.ext_reply(ext_reply),
  .audio_valid(audio_valid),.audio_type(8'h40),.audio_payload(audio_payload),.audio_ready(audio_ready));
 phone_extension_state state(.clk(clk),.rst_n(rst_n),.request_valid(ext_valid),.op(ext_op),.data(ext_data),
  .done(ext_done),.status(ext_status),.reply(ext_reply),.performance_idle(idle),.pixel_bank_ack(pixelack),.test_owned(1'b0),
  .score_wr_en(sw),.score_wr_addr(sa),.score_wr_data(sd),.score_config(sc),
  .guide_command_valid(gcv),.guide_command(gc),.mapping_enable(me),.mapping_bank(mb),.mapping_commit(mc),
  .mapping_wr_en(mw),.mapping_wr_addr(ma),.mapping_wr_data(md),.mapping_pad_notes(pads),.mapping_cc_numbers(ccs),
  .mapping_wr_ready(1'b1),.mapping_commit_ready(1'b1),.mapping_commit_ack(mc_ack),
  .record_start(rs),.record_stop(rt),.record_active(recordbusy),.record_busy(recordbusy),
  .record_count(32'd99),.record_crc32(32'hcbf43926),.record_dropped(16'd0));
 wire[7:0]ob;wire ov,oe;
 midi_uart_rx #(.BAUD(1000000)) monitor(.clk(clk),.rst_n(rst_n),.rx(tx),.data(ob),.data_valid(ov),.framing_error(oe));
 reg[7:0] frame[0:11];integer outpos=0,ack_count=0,audio_count=0,checks=0,sets=0,gets=0,commits=0,score_writes=0;
 reg[7:0]last_seq,last_result,last_op,last_status;reg[31:0]last_reply;
 reg[7:0]cx;integer j;
 always @(posedge clk)if(rst_n)begin
  if(oe)$fatal(1,"TX UART framing error");
  if(set_valid)sets=sets+1;if(get_valid)gets=gets+1;if(mc)commits=commits+1;
  if(sw)score_writes=score_writes+1;
  if(ov)begin
   frame[outpos]=ob;
   if(outpos==11)begin
    cx=0;for(j=2;j<=10;j=j+1)cx=cx^frame[j];
    if(frame[0]!=8'h5a || frame[1]!=8'ha5 || frame[2]!=1 || cx!=ob)$fatal(1,"outgoing frame malformed");
    if(frame[4]==8'h40)audio_count=audio_count+1;
    else begin
     last_seq=frame[3];last_result=frame[4];last_op=frame[5];last_status=frame[6];
     last_reply={frame[10],frame[9],frame[8],frame[7]};ack_count=ack_count+1;
    end
    outpos=0;
   end else outpos=outpos+1;
  end
 end
 task clocks(input integer n);repeat(n)@(negedge clk);endtask
 task check(input condition,input[1023:0]message);begin
  checks=checks+1;if(condition!==1)$fatal(1,"%0s seq=%d result=%h status=%d",message,last_seq,last_result,last_status);
 end endtask
 task byte_out(input[7:0]v);integer b;begin
  rx=0;clocks(27);for(b=0;b<8;b=b+1)begin rx=v[b];clocks(27);end rx=1;clocks(27);
 end endtask
 reg[7:0]request[0:11];integer before_ack,n,t;reg[7:0]x;
 task rpc(input[7:0]seq,cmd,op,input[39:0]data,input[7:0]expected_result,expected_status);begin
  request[0]=8'ha5;request[1]=8'h5a;request[2]=1;request[3]=seq;request[4]=cmd;request[5]=op;
  request[6]=data[7:0];request[7]=data[15:8];request[8]=data[23:16];request[9]=data[31:24];request[10]=data[39:32];
  x=0;for(n=2;n<=10;n=n+1)x=x^request[n];request[11]=x;
  before_ack=ack_count;for(n=0;n<12;n=n+1)byte_out(request[n]);
  t=0;while(ack_count==before_ack && t<15000)begin clocks(1);t=t+1;end
  check(t<15000,"RPC timeout during continuously transmitting audio");
  check(last_seq==seq && last_result==expected_result && last_status==expected_status,"RPC response value");
 end endtask
 integer i,k,saved;reg[15:0]sum;reg[31:0]word;
 initial begin
  clocks(20);rst_n=1;clocks(200);
  rpc(1,0,0,0,0,42);check(gets==1 && audio_count>0,"legacy GET survives full duplex PCM");
  rpc(2,1,0,40'h0000010012,4,42);check(sets==0,"legacy reserved bytes remain protected");
  rpc(3,3,0,0,8'h20,0);check(last_reply==32'h00010007,"extension capability");
  rpc(4,3,16,{24'd46875,8'd12,8'd1},8'h20,0);check(score_writes==256,"BEGIN clears exactly inactive score bank");
  sum=0;
  for(i=0;i<12;i=i+1)begin
   word=i<8 ? ((32'd60<<16)|(1<<23)) : ((32'd100<<24)|60|(1<<13)|((i==8)?(1<<14):0));
   rpc(10+i,3,17,{word,i[7:0]},8'h20,0);
   sum=sum+word[7:0]+word[15:8]+word[23:16]+word[31:24];
   if(i==3)begin
    saved=score_writes;rpc(10+i,3,17,{word,i[7:0]},8'h20,0);
    check(score_writes==saved,"duplicate write ACK without replay");
   end
  end
  rpc(30,3,18,{24'd0,sum},8'h20,0);check(sc[31:30]==3 && sc[29:24]==1 && sc[23:18]==3,"atomic score metadata");
  rpc(31,3,16,{24'd46875,8'd12,8'd1},8'h21,3);check(sc[31:30]==3,"old pixel bank cannot be overwritten");
  pixelack=1;clocks(5);rpc(32,3,16,{24'd46875,8'd12,8'd1},8'h20,0);
  rpc(33,3,19,0,8'h20,0);check(sc[31:30]==3,"cancel does not replace active score");
  idle=0;rpc(34,3,32,0,8'h21,3);idle=1;
  rpc(35,3,32,0,8'h20,0);sum=0;
  for(i=0;i<128;i=i+1)begin
   k=(i==60)?62:i;
   rpc(40+i,3,33,{24'd0,k[7:0],i[7:0]},8'h20,0);sum=sum+i+k;
  end
  for(i=0;i<4;i=i+1)begin
   k=36+i;rpc(170+i,3,34,{24'd0,k[7:0],i[7:0]},8'h20,0);sum=sum+i+k;
  end
  for(i=0;i<4;i=i+1)begin
   case(i)0:k=93;1:k=91;2:k=71;3:k=74;endcase
   rpc(180+i,3,35,{24'd0,k[7:0],i[7:0]},8'h20,0);sum=sum+i+k;
  end
  idle=0;rpc(190,3,36,{24'd0,sum},8'h21,3);check(!me,"held performance prevents map commit");idle=1;
  rpc(191,3,36,{24'd0,sum},8'h20,0);check(me && mb && commits==1,"map commit exactly once");
  rpc(191,3,36,{24'd0,sum},8'h20,0);check(commits==1,"map retry cannot replay panic/commit");
  recordbusy=1;rpc(192,3,16,{24'd46875,8'd12,8'd1},8'h21,3);
  rpc(193,3,50,0,8'h21,3);recordbusy=0;
  rpc(194,3,50,0,8'h20,0);check(last_reply==32'hcbf43926,"CRC readback");
  check(audio_count>100,"many audio frames passed while RPCs progressed");
  $display("V041_PHONE_EXT_LINK_STATE_PASS checks=%0d audio_packets=%0d ACKs=%0d",checks,audio_count,ack_count);$finish;
 end
 initial begin #100000000;$fatal(1,"test watchdog");end
endmodule
