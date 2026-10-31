`timescale 1ns/1ps
// V041 command executor. No audio is generated here. Uploads target inactive
// banks, validate monotonically increasing indexes and a final sum, then commit.
// Reuse of a score bank waits for the pixel-domain acknowledgement so the
// renderer can never read the bank being cleared for the next upload.
module phone_extension_state #(parameter CHORD_SCORE_ENABLE=0,parameter GUIDE_MODES_ENABLE=0)(
 input wire clk,rst_n,request_valid,input wire [7:0] op,input wire [39:0] data,
 output reg done,output reg [7:0] status,output reg [31:0] reply,
 input wire performance_idle,input wire pixel_bank_ack,input wire test_owned,
 output reg score_wr_en,output reg [8:0] score_wr_addr,output reg [31:0] score_wr_data,
 output reg [31:0] score_config,
 output reg guide_command_valid,output reg [1:0] guide_command,
 output reg [1:0] guide_song,output reg guide_mode_valid,output reg [1:0] guide_mode_value,
 input wire [23:0] guide_status,
 output wire mapping_enable,mapping_bank,mapping_commit,
 output reg mapping_wr_en,output reg [7:0] mapping_wr_addr,output reg [6:0] mapping_wr_data,
 output wire [27:0] mapping_pad_notes,mapping_cc_numbers,
 input wire mapping_wr_ready,mapping_commit_ready,mapping_commit_ack,
 output reg record_start,record_stop,
 input wire record_active,record_busy,input wire [31:0] record_count,record_crc32,
 input wire [15:0] record_dropped
);
 localparam IDLE=0,SCORE_CLEAR=1,SCORE_WRITE=2,MAP_INIT=3,MAP_WRITE=4,MAP_COMMIT=5,MAP_ACK=6;
 reg [2:0] state;
 reg [7:0] clear_index,score_count,score_quarters,map_count;
 reg [5:0] score_steps;
 reg [17:0] score_beat_samples;
 reg [15:0] upload_sum;
 reg stage_bank;
 reg [27:0] stage_pads,stage_ccs;
 // Candidate metadata is visible only during the two-clock commit handshake.
 // Active metadata is published AFTER the decoder's registered acknowledgement.
 // If MIDI activity begins between precheck and acceptance, return BUSY immediately
 // and preserve the inactive upload so the host can retry after releasing keys.
 reg active_map_enable,active_map_bank,disable_pending;
 reg [27:0] active_pads,active_ccs;
 wire map_pending=(state==MAP_COMMIT || state==MAP_ACK);
 assign mapping_enable=map_pending?!disable_pending:active_map_enable;
 assign mapping_bank=map_pending&&!disable_pending?stage_bank:active_map_bank;
 assign mapping_pad_notes=map_pending&&!disable_pending?stage_pads:active_pads;
 assign mapping_cc_numbers=map_pending&&!disable_pending?stage_ccs:active_ccs;
 assign mapping_commit=(state==MAP_COMMIT)&&performance_idle&&mapping_commit_ready;
 reg ack_meta,ack_sync;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin ack_meta<=0;ack_sync<=0;end
  else begin ack_meta<=pixel_bank_ack;ack_sync<=ack_meta;end
 wire [7:0] index=data[7:0];
 wire [31:0] word=data[39:8];
 wire [15:0] word_sum={8'd0,word[7:0]}+{8'd0,word[15:8]}+
                       {8'd0,word[23:16]}+{8'd0,word[31:24]};
 wire [6:0] custom_beats=({1'b0,score_quarters}+9'd3)>>2;
 // Packed chord slots must be ascending and in range. No aliases/overflow.
 wire [4:0] d1=word[20:16],d2=word[25:21],d3=word[30:26];
 wire [7:0] top_pitch={1'b0,word[6:0]}+{3'd0,(d3!=0?d3:d2!=0?d2:d1)};
 wire bad_chord=!CHORD_SCORE_ENABLE || !word[13] || d1==0 ||
     (d2!=0 && d2<=d1) || (d3!=0 && (d2==0 || d3<=d2)) || top_pitch>72;
 wire bad_word=(word[31] && bad_chord) || (word[13] && (word[6:0]<41 || word[6:0]>72 || word[12:7]>=score_steps)) ||
                            (!word[31] && word[23] && (word[22:16]<41 || word[22:16]>72));
 function forbidden_cc;input [6:0] cc;
  begin forbidden_cc=cc==1 || cc==7 || cc==64 || cc==120 || cc==121 || cc==123;end
 endfunction
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;done<=0;status<=0;reply<=0;
   clear_index<=0;score_count<=0;score_quarters<=0;map_count<=0;
   score_steps<=0;score_beat_samples<=46875;upload_sum<=0;stage_bank<=1;
   score_wr_en<=0;score_wr_addr<=0;score_wr_data<=0;score_config<=0;
   guide_command_valid<=0;guide_command<=0;guide_song<=3;guide_mode_valid<=0;guide_mode_value<=0;
   active_map_enable<=0;active_map_bank<=0;disable_pending<=0;
   mapping_wr_en<=0;mapping_wr_addr<=0;mapping_wr_data<=0;
   active_pads<={7'd39,7'd37,7'd38,7'd36};
   active_ccs<={7'd74,7'd71,7'd91,7'd93};
   stage_pads<={7'd39,7'd37,7'd38,7'd36};stage_ccs<={7'd74,7'd71,7'd91,7'd93};
   record_start<=0;record_stop<=0;
  end else begin
   done<=0;mapping_wr_en<=0;score_wr_en<=0;guide_command_valid<=0;guide_mode_valid<=0;
   record_start<=0;record_stop<=0;
   if(state==SCORE_CLEAR)begin
    score_wr_en<=1;score_wr_addr<={stage_bank,clear_index};score_wr_data<=0;
    if(clear_index==255)begin state<=SCORE_WRITE;done<=1;status<=0;reply<=0;end
    else clear_index<=clear_index+1'b1;
   end else if(state==MAP_INIT)begin
    // Every initialization write targets the same inactive bank. The first
    // address was set at BEGIN so ready is meaningful before the first strobe.
    if(mapping_wr_ready)begin
     mapping_wr_en<=1;mapping_wr_addr<={stage_bank,clear_index[6:0]};mapping_wr_data<=clear_index[6:0];
     if(clear_index==127)begin state<=MAP_WRITE;done<=1;status<=0;reply<=0;end
     else clear_index<=clear_index+1'b1;
    end
   end else if(state==MAP_COMMIT)begin
    if(mapping_commit)state<=MAP_ACK; // exactly one accepted handshake edge
    else begin
     done<=1;status<=3;reply<=0;state<=disable_pending?IDLE:MAP_WRITE;
    end
   end else if(state==MAP_ACK)begin
    if(mapping_commit_ack)begin
     active_map_enable<=!disable_pending;
     if(!disable_pending)begin
      active_map_bank<=stage_bank;active_pads<=stage_pads;active_ccs<=stage_ccs;
     end
     done<=1;status<=0;reply<={31'd0,!disable_pending};state<=IDLE;
    end
   end else if(request_valid)begin
    done<=1;status<=0;reply<=0;
    case(op)
     0:reply<=CHORD_SCORE_ENABLE?32'h0001000f:32'h00010007;
     1:begin
      status<=0;
      reply<={27'd0,(record_dropped!=0),record_busy,record_active,mapping_enable,score_config[30]};
     end
     16:begin
      if(state!=IDLE || record_busy || ack_sync!=score_config[31])status<=3;
      else if(data[7:0]<1 || data[7:0]>63 || data[15:8]<9 || data[15:8]>252 ||
              data[39:16]<23437 || data[39:16]>187500)status<=2;
      else begin
       state<=SCORE_CLEAR;done<=0;stage_bank<=~score_config[31];clear_index<=0;
       score_steps<=data[5:0];score_quarters<=data[15:8];score_beat_samples<=data[33:16];
       score_count<=0;upload_sum<=0;
      end
     end
     17:begin
      if(state!=SCORE_WRITE)status<=6;
      else if(index!=score_count || score_count>=score_quarters)status<=4;
      else if(bad_word)status<=2;
      else begin
       score_wr_en<=1;score_wr_addr<={stage_bank,index};score_wr_data<=word;
       score_count<=score_count+1'b1;upload_sum<=upload_sum+word_sum;
       reply<={24'd0,score_count}+32'd1;
      end
     end
     18:begin
      if(state!=SCORE_WRITE)status<=6;
      else if(score_count!=score_quarters)status<=4;
      else if(data[39:16]!=0 || data[15:0]!=upload_sum)status<=5;
      else begin
       score_config<={stage_bank,1'b1,score_steps,custom_beats[5:0],score_beat_samples};
       guide_command_valid<=1;guide_command<=0;guide_song<=3;
       state<=IDLE;reply<={stage_bank,1'b1,score_steps,custom_beats[5:0],score_beat_samples};
      end
     end
     19:if(state==SCORE_WRITE)begin state<=IDLE;end else if(state!=IDLE)status<=3;
     20:begin
      // Legacy payload0..3 means custom. Bit16 opts into an explicit song.
      if((!GUIDE_MODES_ENABLE || !data[16] || data[9:8]==3) && !score_config[30])status<=6;
      else if(test_owned)status<=3;
      else if((!GUIDE_MODES_ENABLE && data[39:2]!=0) ||
              (GUIDE_MODES_ENABLE && ((data & ~40'h0000010303)!=0 || (!data[16] && data[9:8]!=0))))status<=2;
      else begin
       guide_command_valid<=1;guide_command<=data[1:0];
       guide_song<=(GUIDE_MODES_ENABLE && data[16])?data[9:8]:2'd3;
       reply<=data[31:0];
      end
     end
     21:begin
      if(!GUIDE_MODES_ENABLE)status<=1;
      else if(test_owned)status<=3;
      else if(data>2)status<=2;
      else begin guide_mode_valid<=1;guide_mode_value<=data[1:0];reply<=data[31:0];end
     end
     22:begin
      if(!GUIDE_MODES_ENABLE)status<=1;
      else if(data!=0)status<=2;
      else reply<={8'd0,guide_status};
     end
     32:begin
      if(state!=IDLE || record_busy || !performance_idle)status<=3;
      else if(data!=0)status<=2;
      else begin
       state<=MAP_INIT;done<=0;stage_bank<=~mapping_bank;clear_index<=0;map_count<=0;upload_sum<=0;
       mapping_wr_addr<={~mapping_bank,7'd0};
       stage_pads<={7'd39,7'd37,7'd38,7'd36};stage_ccs<={7'd74,7'd71,7'd91,7'd93};
      end
     end
     33:begin
      if(state!=MAP_WRITE)status<=6;
      else if(map_count>=128 || index!=map_count)status<=4;
      else if(data[39:15]!=0)status<=2;
      else if(!mapping_wr_ready)status<=3;
      else begin
       mapping_wr_en<=1;mapping_wr_addr<={stage_bank,index[6:0]};mapping_wr_data<=data[14:8];
       map_count<=map_count+1'b1;upload_sum<=upload_sum+{8'd0,index}+{9'd0,data[14:8]};
       reply<={24'd0,map_count}+32'd1;
      end
     end
     34:begin
      if(state!=MAP_WRITE)status<=6;
      else if(map_count<128 || map_count>=132 || index!=(map_count-128))status<=4;
      else if(data[39:15]!=0)status<=2;
      else begin
       stage_pads[index[1:0]*7+:7]<=data[14:8];map_count<=map_count+1'b1;
       upload_sum<=upload_sum+{8'd0,index}+{9'd0,data[14:8]};reply<={24'd0,map_count}+32'd1;
      end
     end
     35:begin
      if(state!=MAP_WRITE)status<=6;
      else if(map_count<132 || map_count>=136 || index!=(map_count-132))status<=4;
      else if(data[39:15]!=0 || forbidden_cc(data[14:8]))status<=2;
      else begin
       stage_ccs[index[1:0]*7+:7]<=data[14:8];map_count<=map_count+1'b1;
       upload_sum<=upload_sum+{8'd0,index}+{9'd0,data[14:8]};reply<={24'd0,map_count}+32'd1;
      end
     end
     36:begin
      if(state!=MAP_WRITE)status<=6;
      else if(!performance_idle || record_busy || !mapping_commit_ready)status<=3;
      else if(map_count!=136)status<=4;
      else if(data[39:16]!=0 || data[15:0]!=upload_sum)status<=5;
      else if(stage_pads[6:0]==stage_pads[13:7] || stage_pads[6:0]==stage_pads[20:14] ||
              stage_pads[6:0]==stage_pads[27:21] || stage_pads[13:7]==stage_pads[20:14] ||
              stage_pads[13:7]==stage_pads[27:21] || stage_pads[20:14]==stage_pads[27:21] ||
              stage_ccs[6:0]==stage_ccs[13:7] || stage_ccs[6:0]==stage_ccs[20:14] ||
              stage_ccs[6:0]==stage_ccs[27:21] || stage_ccs[13:7]==stage_ccs[20:14] ||
              stage_ccs[13:7]==stage_ccs[27:21] || stage_ccs[20:14]==stage_ccs[27:21])status<=2;
      else begin
       disable_pending<=0;state<=MAP_COMMIT;done<=0;
      end
     end
     37:if(state==MAP_WRITE)state<=IDLE;else if(state!=IDLE)status<=3;
     38:begin
      if(state!=IDLE || !performance_idle || record_busy || !mapping_commit_ready)status<=3;
      else if(data!=0)status<=2;
      else begin disable_pending<=1;state<=MAP_COMMIT;done<=0;end
     end
     48:begin
      if(record_busy || state!=IDLE)status<=3;
      else if(data!=0)status<=2;
      else record_start<=1;
     end
     49:begin if(data!=0)status<=2;else record_stop<=1;end
     50:begin if(record_busy)status<=3;else reply<=record_crc32;end
     51:begin
      // Byte6 remains an error code (0); state flags occupy reply[31:29].
      reply<={record_dropped!=0,record_busy,record_active,record_count[28:0]};
     end
     default:status<=1;
    endcase
   end
  end
 end
endmodule
