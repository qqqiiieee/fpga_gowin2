`timescale 1ns/1ps
// V041: shared 12-byte phone transport. RX never stops while TX streams PCM.
// The original GET/SET/Panic and atomic-telemetry semantics remain intact.
// Only CMD3 may use the four formerly reserved bytes; extension execution and
// PCM production live outside this module. ACK wins at whole-packet boundaries.
module phone_extended_link #(
 parameter integer CLK_HZ=27000000, BAUD=1000000,
 parameter integer TIMEOUT_CYCLES=540000, TELEMETRY_ENABLE=1
)(
 input wire clk,rst_n,rx, output wire tx,
 output reg set_valid,panic, output reg [7:0] param,value,
 input wire [7:0] read_value,status_flags,current_timbre,current_fx,current_volume,
 output reg get_valid,
 output reg ext_valid, output reg [7:0] ext_op, output reg [39:0] ext_data,
 input wire ext_done, input wire [7:0] ext_status, input wire [31:0] ext_reply,
 input wire audio_valid, input wire [7:0] audio_type,
 input wire [47:0] audio_payload, output reg audio_ready
);
 localparam integer BC=(CLK_HZ+BAUD/2)/BAUD;
 localparam integer BW=BC<2?1:$clog2(BC);
 localparam integer TW=TIMEOUT_CYCLES<2?1:$clog2(TIMEOUT_CYCLES);
 wire [7:0] rb;wire rv,re;
 midi_uart_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) receiver(
  .clk(clk),.rst_n(rst_n),.rx(rx),.data(rb),.data_valid(rv),.framing_error(re));
 reg [95:0] incoming;
 reg [3:0] pos;
 reg [7:0] rx_xor;
 reg [TW-1:0] age;
 wire [7:0] rq_version=incoming[23:16],rq_seq=incoming[31:24];
 wire [7:0] rq_cmd=incoming[39:32],rq_param=incoming[47:40];
 wire [7:0] rq_value=incoming[55:48];
 wire [39:0] rq_data=incoming[87:48];
 reg rpc_busy,reply_ready;
 reg [1:0] rpc_state;
 localparam SETTLE=1,EXT_WAIT=2,QUEUED=3;
 reg [2:0] settle;
 reg [7:0] pending_seq,pending_result;
 reg [95:0] reply_packet;
 reg previous_was_snapshot;
 reg [7:0] previous_snapshot_seq;
 // One successful extension request is cached independently of GET polling.
 // Repeating its sequence and all request bytes returns the same ACK and never
 // replays BEGIN/WRITE/COMMIT/START/STOP side effects.
 reg ext_cache_valid;
 reg [71:0] ext_cache_request,pending_ext_request;
 reg [95:0] ext_cache_packet;
 reg tx_active,tx_is_rpc;
 reg [95:0] tx_packet;
 reg [9:0] serial_word;
 reg [BW-1:0] bit_timer;
 reg [3:0] bit_index,byte_index;
 reg [7:0] audio_seq;
 assign tx=tx_active?serial_word[0]:1'b1;
 function [95:0] make_packet;
  input [7:0] seq,result;
  input [47:0] payload;
  reg [95:0] p;reg [7:0] x;integer k;
  begin
   p={8'd0,payload,result,seq,8'd1,16'ha55a};x=0;
   for(k=2;k<=10;k=k+1)x=x^p[k*8+:8];
   p[95:88]=x;make_packet=p;
  end
 endfunction
 function [7:0] legacy_result;
  input [7:0] ver,cmd,idx,val;input reserved_bad;
  begin
   legacy_result=0;
   if(ver!=1 || reserved_bad)legacy_result=4;
   else if(cmd>2)legacy_result=1;
   else if(cmd==2)begin if(idx!=0 || val!=0)legacy_result=3;end
   else if(idx>(TELEMETRY_ENABLE?31:15) || (cmd==1 && idx>=15))legacy_result=2;
   else if(cmd==0 && val!=0)legacy_result=3;
   else if(cmd==1)case(idx)
    1,13,14:if(val>1)legacy_result=3;
    2:if(val>2)legacy_result=3;
    3,12:if(val>3)legacy_result=3;
    default:;
   endcase
  end
 endfunction
 wire [7:0] checked_result=legacy_result(rq_version,rq_cmd,rq_param,rq_value,|incoming[87:56]);
 wire [95:0] fresh_ext_reply=make_packet(pending_seq,ext_status==0?8'h20:8'h21,
                                       {ext_reply,ext_status,ext_op});
 wire [95:0] fresh_audio=make_packet(audio_seq,audio_type,audio_payload);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   incoming<=0;pos<=0;rx_xor<=0;age<=0;
   rpc_busy<=0;reply_ready<=0;rpc_state<=0;settle<=0;
   pending_seq<=0;pending_result<=0;reply_packet<=0;
   previous_was_snapshot<=0;previous_snapshot_seq<=0;
   ext_cache_valid<=0;ext_cache_request<=0;pending_ext_request<=0;ext_cache_packet<=0;
   set_valid<=0;panic<=0;get_valid<=0;param<=0;value<=0;
   ext_valid<=0;ext_op<=0;ext_data<=0;
   tx_active<=0;tx_is_rpc<=0;tx_packet<=0;serial_word<=10'h3ff;
   bit_timer<=0;bit_index<=0;byte_index<=0;audio_seq<=0;audio_ready<=0;
  end else begin
   set_valid<=0;panic<=0;get_valid<=0;ext_valid<=0;audio_ready<=0;
   // RX/parser and serializer run concurrently. Partial-frame timeout does not
   // depend on whether the output UART happens to be transmitting.
   if(pos==0)age<=0;
   else if(age==TIMEOUT_CYCLES-1)begin pos<=0;age<=0;end
   else age<=age+1'b1;
   if(re)begin pos<=0;age<=0;end
   else if(rv)begin
    age<=0;
    case(pos)
     0:if(rb==8'ha5)begin incoming[7:0]<=rb;pos<=1;end
     1:if(rb==8'h5a)begin incoming[15:8]<=rb;pos<=2;rx_xor<=0;end
       else if(rb!=8'ha5)pos<=0;
     11:begin
      pos<=0;
      if(rb==rx_xor && !rpc_busy)begin
       rpc_busy<=1;pending_seq<=rq_seq;param<=rq_param;value<=rq_value;
       settle<=0;
       if(rq_cmd==3 && rq_version==1)begin
        previous_was_snapshot<=0;
        if(ext_cache_valid && incoming[87:16]==ext_cache_request)begin
         reply_packet<=ext_cache_packet;reply_ready<=1;rpc_state<=QUEUED;
        end else if(ext_cache_valid && rq_seq==ext_cache_request[15:8] && rq_param!=0)begin
         reply_packet<=make_packet(rq_seq,8'h21,{32'd0,8'd4,rq_param});
         reply_ready<=1;rpc_state<=QUEUED;
        end else begin
         ext_op<=rq_param;ext_data<=rq_data;ext_valid<=1;
         pending_ext_request<=incoming[87:16];rpc_state<=EXT_WAIT;
        end
       end else begin
        pending_result<=checked_result;rpc_state<=SETTLE;
        if(checked_result==0)begin
         if(rq_cmd==1)set_valid<=1;
         if(rq_cmd==2)panic<=1;
         if(rq_cmd==0 && !(rq_param==16 && previous_was_snapshot && previous_snapshot_seq==rq_seq))get_valid<=1;
         previous_was_snapshot<=rq_cmd==0 && rq_param==16;
         previous_snapshot_seq<=rq_seq;
        end
       end
      end
     end
     default:begin incoming[pos*8+:8]<=rb;rx_xor<=rx_xor^rb;pos<=pos+1'b1;end
    endcase
   end
   if(rpc_busy && rpc_state==SETTLE)begin
    if(settle==5)begin
     reply_packet<=make_packet(pending_seq,pending_result,
       {current_volume,current_fx,current_timbre,status_flags,read_value,param});
     reply_ready<=1;rpc_state<=QUEUED;
    end else settle<=settle+1'b1;
   end
   if(rpc_busy && rpc_state==EXT_WAIT && ext_done)begin
    reply_packet<=fresh_ext_reply;reply_ready<=1;rpc_state<=QUEUED;
    if(ext_status==0)begin
     ext_cache_valid<=1;ext_cache_request<=pending_ext_request;ext_cache_packet<=fresh_ext_reply;
    end
   end
   if(!tx_active)begin
    if(reply_ready)begin
     tx_is_rpc<=1;tx_active<=1;tx_packet<={8'd0,reply_packet[95:8]};
     serial_word<={1'b1,reply_packet[7:0],1'b0};
     bit_timer<=BC-1;bit_index<=0;byte_index<=0;
    end else if(audio_valid)begin
     tx_is_rpc<=0;tx_active<=1;tx_packet<={8'd0,fresh_audio[95:8]};
     serial_word<={1'b1,fresh_audio[7:0],1'b0};
     bit_timer<=BC-1;bit_index<=0;byte_index<=0;
     audio_ready<=1;audio_seq<=audio_seq+1'b1;
    end
   end else if(bit_timer==0)begin
    bit_timer<=BC-1;
    if(bit_index==9)begin
     if(byte_index==11)begin
      tx_active<=0;
      if(tx_is_rpc)begin reply_ready<=0;rpc_busy<=0;rpc_state<=0;end
     end else begin
      byte_index<=byte_index+1'b1;bit_index<=0;
      serial_word<={1'b1,tx_packet[7:0],1'b0};tx_packet<={8'd0,tx_packet[95:8]};
     end
    end else begin bit_index<=bit_index+1'b1;serial_word<={1'b1,serial_word[9:1]};end
   end else bit_timer<=bit_timer-1'b1;
  end
 end
endmodule
