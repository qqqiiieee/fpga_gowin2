// V047: reconcile up to four desired pitches into source-tag-3 events.
// ALL obsolete NoteOffs precede any new NoteOn: common pitches may change
// chord slots, and a late old Off must not kill a newly allocated same pitch.
// Live input has priority. No stale desired On is queued under backpressure.
module guide_chord_events(
 input clk,rst_n,clear,blocked,desired_valid,input [6:0] desired_note,
 input [14:0] desired_offsets,input retrigger,
 output event_on,event_off,output [6:0] event_note
);
 reg [27:0] sounding_notes;
 reg [3:0] active,pending;
 wire [27:0] wanted;
 wire [3:0] valid,release_mask,on_mask;
 genvar i;
 generate for(i=0;i<4;i=i+1)begin:g
  wire [4:0] delta;
  if(i==0)assign delta=0;else assign delta=desired_offsets[(i-1)*5+:5];
  assign wanted[i*7+:7]=desired_note+{2'b0,delta};
  assign valid[i]=desired_valid && (i==0 || delta!=0);
  assign release_mask[i]=active[i] && (!valid[i] || sounding_notes[i*7+:7]!=wanted[i*7+:7] || pending[i] || retrigger);
  assign on_mask[i]=valid[i] && !active[i];
 end endgenerate
 wire release_any=|release_mask;
 wire [3:0] candidates=release_any?release_mask:on_mask;
 wire [1:0] slot=candidates[0]?0:candidates[1]?1:candidates[2]?2:3;
 assign event_off=rst_n && !clear && !blocked && release_any;
 assign event_on=rst_n && !clear && !blocked && !release_any && |on_mask;
 assign event_note=event_off?sounding_notes[slot*7+:7]:wanted[slot*7+:7];
 integer j;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin sounding_notes<=0;active<=0;pending<=0;end
  else if(clear)begin active<=0;pending<=0;end
  else begin
   for(j=0;j<4;j=j+1)begin
    if(!valid[j] || (event_on && slot==j))pending[j]<=0;
    else if(retrigger)pending[j]<=1;
   end
   if(event_off)active[slot]<=0;
   else if(event_on)begin active[slot]<=1;sounding_notes[slot*7+:7]<=wanted[slot*7+:7];end
  end
endmodule
