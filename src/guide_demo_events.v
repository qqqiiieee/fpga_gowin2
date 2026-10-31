// Converts the monophonic guide target into allocator events, source tag 3.
// Live input has priority. No stale NoteOn is queued: after contention the
// desired CURRENT target is reconciled. Old NoteOff always precedes new NoteOn.
// Even same-pitch repetitions release first: the allocator allocates a NEW slot
// on every NoteOn rather than finding an existing same-note slot.
module guide_demo_events(
 input clk,rst_n,clear,input blocked,
 input desired_valid,input [6:0] desired_note,input retrigger,
 output event_on,event_off,output [6:0] event_note
);
 reg sounding,pending;
 reg [6:0] sounding_note;
 wire release_old=sounding && (!desired_valid || sounding_note!=desired_note || pending || retrigger);
 assign event_off=rst_n && !clear && !blocked && release_old;
 assign event_on=rst_n && !clear && !blocked && !release_old && desired_valid &&
                 (!sounding || pending || retrigger);
 assign event_note=event_off?sounding_note:desired_note;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin sounding<=0;sounding_note<=0;pending<=0;end
  else if(clear)begin sounding<=0;sounding_note<=0;pending<=0;end
  else begin
   if(!desired_valid || event_on)pending<=0;
   else if(retrigger)pending<=1;
   if(event_off)sounding<=0;
   else if(event_on)begin sounding<=1;sounding_note<=desired_note;end
  end
endmodule
