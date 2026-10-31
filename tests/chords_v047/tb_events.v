`timescale 1ns/1ps
module tb_events;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg clear=0,blocked=0,desired_valid=0,retrigger=0;
 reg [6:0] desired_note=48;reg [14:0] desired_offsets={5'd12,5'd7,5'd4};
 wire event_on,event_off;wire [6:0] event_note;
 guide_chord_events dut(.*);
 reg live_on=0,live_off=0;reg [6:0] live_note=55;
 wire [31:0] gate,voice_retrigger;
 wire [223:0] note_bus;wire [255:0] vel_bus;wire [31:0] timbre_bus;
 voice_allocator #(.NUM_VOICES(32),.SOURCE_TAG_ENABLE(1),.TIMBRE_BITS(1)) alloc(
  .clk(clk),.rst_n(rst_n&&!clear),.note_on(live_on||event_on),.note_off(live_off||event_off),
  .note(live_on||live_off?live_note:event_note),.velocity(8'd160),.timbre(1'b0),
  .voice_busy(32'd0),.gate(gate),.retrigger(voice_retrigger),.note_bus(note_bus),.vel_bus(vel_bus),
  .timbre_bus(timbre_bus),.fs_tick(1'b0),.event_source(live_on||live_off?2'd1:2'd3));
 integer checks=0,ons=0,offs=0,i,old_ons,old_offs,phase_ons=0;
 reg ordering=0,latest_only=0;
 always @(posedge clk)begin
  if(event_on&&event_off)$fatal(1,"adapter emitted On and Off together");
  if(blocked&&(event_on||event_off))$fatal(1,"adapter stole live event");
  if(event_on)begin
   ons=ons+1;if(ordering)phase_ons=phase_ons+1;
   if(latest_only && event_note!=60 && event_note!=64 && event_note!=67 && event_note!=72)
    $fatal(1,"stale desired On escaped backpressure note=%d",event_note);
  end
  if(event_off)begin offs=offs+1;if(ordering&&phase_ons!=0)$fatal(1,"late Off after new On");end
 end
 task cycles(input integer n);begin repeat(n)begin @(posedge clk);#1;@(negedge clk);end end endtask
 function integer count(input integer pitch,source);
  integer k;begin count=0;for(k=0;k<32;k=k+1)
   if(gate[k]&&note_bus[k*7+:7]==pitch&&alloc.sources[k]==source)count=count+1;end
 endfunction
 task check(input condition,input [511:0] label);
  begin checks=checks+1;if(!condition)$fatal(1,"EVENTS: %0s",label);end
 endtask
 task verify(input integer a,b,c,d);
  integer p,n;begin n=0;
   for(p=0;p<128;p=p+1)begin
    if(count(p,3)!=(p==a||p==b||p==c||p==d))$fatal(1,"source3 set mismatch note=%d",p);
    n=n+count(p,3);
   end
   check(n==4,"not exactly four guide voices");
   check(count(55,1)==1,"guide released same-pitch live voice");
  end
 endtask
 initial begin
  cycles(2);rst_n=1;cycles(2);
  blocked=1;live_on=1;cycles(1);live_on=0;blocked=0;
  desired_valid=1;cycles(12);verify(48,52,55,60);
  // Three common pitches move slots. All old Offs must precede new Ons.
  ordering=1;phase_ons=0;desired_note=52;desired_offsets={5'd12,5'd8,5'd3};
  cycles(14);ordering=0;verify(52,55,60,64);
  old_ons=ons;old_offs=offs;retrigger=1;cycles(1);retrigger=0;cycles(14);
  verify(52,55,60,64);check(ons-old_ons==4&&offs-old_offs==4,"repeat must release/restrike all four");
  // Multiple rapid requests must converge without duplicate stuck voices.
  for(i=0;i<3;i=i+1)begin retrigger=1;cycles(1);retrigger=0;cycles(1);end
  cycles(20);verify(52,55,60,64);
  blocked=1;old_ons=ons;old_offs=offs;
  desired_note=41;desired_offsets={5'd12,5'd7,5'd4};retrigger=1;cycles(1);retrigger=0;cycles(3);
  desired_note=60;desired_offsets={5'd12,5'd7,5'd4};cycles(3);
  check(ons==old_ons&&offs==old_offs,"blocked emitted events");
  latest_only=1;blocked=0;cycles(20);latest_only=0;verify(60,64,67,72);
  blocked=1;desired_valid=0;cycles(4);blocked=0;cycles(12);
  for(i=0;i<128;i=i+1)check(count(i,3)==0,"exit left guide voice");
  check(count(55,1)==1,"exit killed live voice");
  desired_valid=1;cycles(12);verify(60,64,67,72);
  clear=1;cycles(1);check(gate==0&&!event_on&&!event_off,"global clear failed");
  clear=0;desired_valid=0;cycles(5);check(gate==0,"clear restored stale voice");
  $display("CHORD_EVENTS_PASS checks=%0d ons=%0d offs=%0d",checks,ons,offs);$finish;
 end
 initial begin #1000000;$fatal(1,"events watchdog");end
endmodule
