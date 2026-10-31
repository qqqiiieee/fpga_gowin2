`timescale 1ns/1ps
module tb_demo_allocator;
 reg clk=0,rst_n=0,clear=0,blocked=0,valid=0,again=0;
 reg [6:0] desired=60,live_note=60;
 reg live_on=0,live_off=0;
 reg [31:0] busy=0;
 always #5 clk=~clk;
 wire on_event,off_event;wire [6:0] event_note;
 wire [31:0] gates,triggers;wire [223:0] note_bus;
 wire live=live_on||live_off;
 guide_demo_events dut(.clk(clk),.rst_n(rst_n),.clear(clear),.blocked(blocked||live),
  .desired_valid(valid),.desired_note(desired),.retrigger(again),
  .event_on(on_event),.event_off(off_event),.event_note(event_note));
 voice_allocator #(.NUM_VOICES(32),.SOURCE_TAG_ENABLE(1)) alloc(
  .clk(clk),.rst_n(rst_n&&!clear),.note_on(live_on||on_event),.note_off(live_off||off_event),
  .note(live?live_note:event_note),.velocity(8'd192),.timbre(4'd0),.voice_busy(busy),
  .gate(gates),.retrigger(triggers),.note_bus(note_bus),.vel_bus(),.timbre_bus(),
  .fs_tick(1'b0),.event_source(live?2'd1:2'd3));
 integer checks=0,count=0,i,j,n,cycle=0,live_count,demo_count,max_demo=0;
 reg log_on[0:1023];reg [6:0] log_note[0:1023];integer log_cycle[0:1023];
 always @(posedge clk)begin
  cycle=cycle+1;
  if(rst_n)begin
   if(on_event && off_event)$fatal(1,"simultaneous demo on/off");
   if((blocked||live||clear) && (on_event||off_event))$fatal(1,"demo bypassed live/cancel priority");
   if(on_event||off_event)begin
    log_on[count]=on_event;log_note[count]=event_note;log_cycle[count]=cycle;count=count+1;
   end
   #1;demo_count=0;live_count=0;
   for(j=0;j<32;j=j+1)if(gates[j])begin
    if(alloc.sources[j]==3)demo_count=demo_count+1;
    if(alloc.sources[j]==1)live_count=live_count+1;
   end
   if(demo_count>max_demo)max_demo=demo_count;
   if(demo_count>1)$fatal(1,"demo gate accumulation count=%0d",demo_count);
  end
 end
 task tick(input integer n);repeat(n)begin @(posedge clk);#2;end endtask
 task check(input c,input [1023:0] m);
  begin checks=checks+1;if(c!==1'b1)$fatal(1,"%0s events=%0d live=%0d demo=%0d",m,count,live_count,demo_count);end
 endtask
 task set_target(input v,input [6:0] p,input r);
  begin @(negedge clk);valid=v;desired=p;again=r;end
 endtask
 task edge_is(input integer idx,input onoff,input [6:0] pitch);
  check(count>idx && log_on[idx]===onoff && log_note[idx]===pitch,"event ordering/pitch");
 endtask
 initial begin
  tick(4);@(negedge clk);rst_n=1;tick(2);
  @(negedge clk);live_on=1;tick(1);@(negedge clk);live_on=0;
  set_target(1,60,0);tick(1);edge_is(0,1,60);
  check(demo_count==1 && live_count==1,"source1/source3 same pitch coexist");
  for(i=0;i<80;i=i+1)begin
   // First half models no release tail, second half all voices still busy.
   @(negedge clk);busy=(i<40)?32'd0:32'hffffffff;
   n=count;set_target(1,60,1);tick(1);edge_is(n,0,60);
   check(demo_count==0 && live_count==1,"same-pitch old off only source3");
   @(negedge clk);again=0;tick(1);edge_is(n+1,1,60);
   check(log_cycle[n+1]==log_cycle[n]+1,"off/on on successive cycles");
   check(demo_count==1 && live_count==1,"retrigger cannot accumulate gates");
   tick(3);check(count==n+2,"no repeated steady on");
  end
  $display("CASE_PASS demo_80_same_pitch_off_on_source_isolation");
  n=count;@(negedge clk);blocked=1;again=1;tick(1);
  @(negedge clk);again=0;tick(6);check(count==n,"blocked retrigger queued once");
  @(negedge clk);blocked=0;tick(1);edge_is(n,0,60);tick(1);edge_is(n+1,1,60);
  n=count;@(negedge clk);blocked=1;tick(2);
  set_target(1,62,1);tick(2);set_target(1,64,0);tick(2);
  @(negedge clk);blocked=0;tick(1);edge_is(n,0,60);tick(1);edge_is(n+1,1,64);
  check(count==n+2 && live_count==1,"only latest target after contention");
  n=count;@(negedge clk);blocked=1;tick(1);set_target(1,67,1);tick(1);
  set_target(0,67,0);tick(1);@(negedge clk);blocked=0;tick(3);edge_is(n,0,64);
  check(count==n+1 && demo_count==0 && live_count==1,"cancel cannot replay stale queued on");
  $display("CASE_PASS demo_contention_latest_target_and_cancel");
  set_target(1,60,0);tick(1);n=count;
  set_target(1,62,0);tick(1);edge_is(n,0,60);
  set_target(0,62,0);tick(3);check(count==n+1 && demo_count==0,"cancel between off and on");
  set_target(1,60,0);tick(1);n=count;
  @(negedge clk);live_off=1;tick(1);check(live_count==0 && demo_count==1,"source1 off cannot close demo same pitch");
  @(negedge clk);live_off=0;live_on=1;desired=65;tick(1);
  check(count==n && live_count==1,"live on beats simultaneous demo pitch change");
  @(negedge clk);live_on=0;tick(1);edge_is(n,0,60);tick(1);edge_is(n+1,1,65);
  set_target(0,65,0);tick(3);check(demo_count==0 && live_count==1,"all demo gates released live survives");
  @(negedge clk);live_off=1;tick(1);@(negedge clk);live_off=0;
  check(gates==0,"all gates released by respective sources");
  n=count;@(negedge clk);blocked=1;valid=1;desired=70;again=1;tick(1);
  @(negedge clk);clear=1;tick(1);@(negedge clk);valid=0;again=0;clear=0;blocked=0;
  tick(4);check(count==n && gates==0,"global clear discards pending target");
  $display("V045_DEMO_ALLOCATOR_PASS checks=%0d events=%0d repeats=80 max_demo_gates=%0d",checks,count,max_demo);$finish;
 end
 initial begin #1000000;$fatal(1,"demo timeout");end
endmodule
