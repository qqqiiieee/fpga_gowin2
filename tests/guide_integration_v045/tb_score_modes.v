`timescale 1ns/1ps
// Real synchronous built-in score -> modes -> adapter -> real allocator.
// Oracle event start/end/pitch comes from RAW source.json, not DUT functions/HEX.
// All changes enter public ports. No force or DUT state/memory writes.
module tb_score_modes;
 parameter integer MODE=2,GAP=4;
 reg clk=0,rst_n=0,suspended=0,start=0,toggle=0,midi_on=0,sample=0;
 reg [1:0] song=0,mode=MODE;reg [6:0] midi_note=0;
 always #5 clk=~clk;
 integer sample_phase=0;
 always @(negedge clk)begin
  if(!rst_n)begin sample_phase=0;sample=0;end
  else begin sample=(sample_phase==0);sample_phase=(sample_phase+1)%GAP;end
 end
 wire [11:0] roll_tick;wire [1:0] selected;wire active,done,ready,expected_valid,count_in,hold;
 wire [6:0] expected_note,demo_note,event_note;wire [5:0] step,steps,beats;
 wire demo_valid,demo_again,on_event,off_event;wire [31:0] gates;
 piano_roll_guide #(.BEAT_SAMPLES(64),.SONG_LIBRARY_ENABLE(1)) guide(
  .clk(clk),.rst_n(rst_n),.sample_tick(sample),.pause(suspended||hold),.song_id(song),
  .ui_start(start),.ui_toggle(toggle),.ui_restart(1'b0),.roll_tick(roll_tick),.roll_song(selected),
  .active(active),.done(done),.step_index(step),.total_steps(steps),.total_beats(beats),
  .expected_note(expected_note),.expected_valid(expected_valid),.score_ready(ready),.count_in(count_in),
  .custom_write_clk(clk),.custom_write_en(1'b0),.custom_write_addr(9'd0),
  .custom_write_data(32'd0),.custom_config(32'd0));
 guide_play_modes modes(.clk(clk),.rst_n(rst_n),.mode(mode),.running(active&&!done),
  .suspended(suspended),.restart(start),.score_ready(ready),.expected_note(expected_note),
  .expected_valid(expected_valid),.step_index(step),.midi_note_on(midi_on),.midi_note(midi_note),
  .practice_hold(hold),.demo_valid(demo_valid),.demo_note(demo_note),.demo_note_retrigger(demo_again));
 guide_demo_events adapter(.clk(clk),.rst_n(rst_n),.clear(1'b0),.blocked(1'b0),
  .desired_valid(demo_valid),.desired_note(demo_note),.retrigger(demo_again),
  .event_on(on_event),.event_off(off_event),.event_note(event_note));
 voice_allocator #(.NUM_VOICES(32),.SOURCE_TAG_ENABLE(1)) alloc(
  .clk(clk),.rst_n(rst_n),.note_on(on_event),.note_off(off_event),.note(event_note),
  .velocity(8'd192),.timbre(4'd0),.voice_busy(32'd0),.gate(gates),.fs_tick(1'b0),.event_source(2'd3));
 reg [31:0] oracle[0:191],metadata[0:2];
 integer checks=0,used=0,ons=0,offs=0,bubbles=0,next_event=0,last_pitch=0,gate_count=0;
 integer s,e,k,guard,old_tick,before_ons,before_offs,practiced=0,rest_steps=0,repeats=0;
 integer total_ons=0,total_offs=0,total_bubbles=0,full_runs=0,paused_tick;
 reg full_scoreboard=0,was_demo=0,previous_sounding=0;
 function integer n_events(input integer sid);n_events=metadata[sid][7:0];endfunction
 function integer n_pitched(input integer sid);n_pitched=metadata[sid][15:8];endfunction
 function integer n_beats(input integer sid);n_beats=metadata[sid][23:16];endfunction
 function integer pitch(input integer sid,input integer idx);pitch=oracle[sid*64+idx][7:0];endfunction
 function integer first_tick(input integer sid,input integer idx);first_tick=oracle[sid*64+idx][31:20];endfunction
 function integer last_tick(input integer sid,input integer idx);last_tick=oracle[sid*64+idx][19:8];endfunction
 task check(input c,input [1023:0] msg);
  begin checks=checks+1;if(c!==1'b1)$fatal(1,"%0s MODE=%0d GAP=%0d song=%0d step=%0d tick=%0d ready=%0b hold=%0b on/off=%0d/%0d",msg,MODE,GAP,selected,step,roll_tick,ready,hold,ons,offs);end
 endtask
 task cycles(input integer n);repeat(n)begin @(posedge clk);#2;end endtask
 always @(posedge clk)begin
  if(!rst_n)begin used=0;ons=0;offs=0;bubbles=0;next_event=0;previous_sounding=0;end
  else if(start)begin used=0;ons=0;offs=0;bubbles=0;next_event=0;end
  else begin
   if(active&&!done&&sample&&!suspended&&!hold)used=used+1;
   if(on_event)begin
    if(full_scoreboard)begin
     while(next_event<n_events(selected) && pitch(selected,next_event)==0)next_event=next_event+1;
     check(next_event<n_events(selected),"no extra demo onset from a score_ready bubble");
     check(event_note==pitch(selected,next_event),"demo pitch/order equals raw score events");
     next_event=next_event+1;
    end
    check(!previous_sounding,"every demo on follows release of old gate");
    previous_sounding=1;last_pitch=event_note;ons=ons+1;
   end
   if(off_event)begin
    check(previous_sounding && event_note==last_pitch,"off releases currently sounding raw pitch");
    previous_sounding=0;offs=offs+1;
   end
  end
  was_demo=demo_valid;
  if(rst_n)begin
   #1;
   check(roll_tick==(used<n_beats(selected)*64?used:n_beats(selected)*64),"sample-accepted timeline matches independent tick count");
   if(!ready)bubbles=bubbles+1;
   if(mode!=1)check(!demo_valid&&!on_event,"fixed/practice cannot generate audio");
   if(!ready && was_demo && mode==1 && !suspended && !start && active)
    check(demo_valid,"RAM bubble must preserve demo gate until real next score data");
   gate_count=0;for(k=0;k<32;k=k+1)if(gates[k])gate_count=gate_count+1;
   check(gate_count<=1,"adapter plus allocator never accumulates gates");
   if(count_in)check(!expected_valid&&!demo_valid,"two-beat count-in silent");
  end
 end
 task launch(input integer sid);
  begin
   @(negedge clk);song=sid;mode=MODE;suspended=0;midi_on=0;start=1;toggle=0;
   cycles(1);@(negedge clk);start=0;
   check(roll_tick==0 && selected==sid && active&&!done,"start selects song at count-in zero");
   cycles(3);check(steps==n_events(sid) && beats==n_beats(sid),"ROM metadata matches raw source");
  end
 endtask
 task fresh(input [6:0] p,input leave_high);
  begin @(negedge clk);midi_note=p;midi_on=1;cycles(1);
   if(!leave_high)begin @(negedge clk);midi_on=0;end
  end
 endtask
 task reach_event(input integer idx);
  begin
   guard=0;
   while(!(ready && step==idx && roll_tick>=first_tick(s,idx) && !done))begin
    cycles(1);guard=guard+1;check(guard<20000,"real score_ready bubble must not deadlock practice");
   end
  end
 endtask
 task finish_song;
  begin
   guard=0;while(!done)begin cycles(1);guard=guard+1;check(guard<20000,"natural end reached");end
   cycles(6);
   check(done&&!active && roll_tick==n_beats(s)*64,"complete final duration");
   check(!demo_valid&&!hold && gates==0 && !previous_sounding,"natural end clears adapter/allocator/hold");
   if(MODE==1)check(ons==n_pitched(s) && offs==n_pitched(s),"demo on/off counts equal PITCHED events, excluding rests");
   else check(ons==0 && offs==0,"no demo sound outside mode1");
   check(bubbles>0,"test exercised actual synchronous score_ready bubbles");
   total_ons=total_ons+ons;total_offs=total_offs+offs;total_bubbles=total_bubbles+bubbles;full_runs=full_runs+1;
   $display("SCORE_SONG_PASS mode=%0d gap=%0d song=%0d steps=%0d pitched=%0d rests=%0d ons=%0d offs=%0d bubbles=%0d samples=%0d",MODE,GAP,s,n_events(s),n_pitched(s),n_events(s)-n_pitched(s),ons,offs,bubbles,used);
   old_tick=roll_tick;@(negedge clk);toggle=1;cycles(1);@(negedge clk);toggle=0;cycles(6);
   check(done && !active && roll_tick==old_tick && gates==0,"toggle cannot revive completed song");
  end
 endtask
 initial begin
  $readmemh("tests/guide_integration_v045/song_events.hex",oracle);
  $readmemh("tests/guide_integration_v045/song_metadata.hex",metadata);
  cycles(4);@(negedge clk);rst_n=1;
  for(s=0;s<3;s=s+1)begin
   full_scoreboard=1;launch(s);
   // Count-in keys cannot pre-accept the first note.
   if(MODE==2)begin fresh(pitch(s,0),0);end
   guard=0;
   while(roll_tick<128)begin
    cycles(1);guard=guard+1;check(guard<1024,"count-in progresses without a key");
    if(roll_tick<128)check(count_in,"two-beat pre-roll retained");
   end
   check(!count_in,"count-in ends exactly at tick128");
   if(MODE==2)begin
    for(e=0;e<n_events(s);e=e+1)begin
     reach_event(e);
     if(pitch(s,e)==0)begin
      check(!expected_valid && !hold,"real rest progresses without key");rest_steps=rest_steps+1;
      // A matching future pitch held across a rest is not an advance credit.
      if(e+1<n_events(s))fresh(pitch(s,e+1),1);
     end else begin
      check(expected_valid && expected_note==pitch(s,e) && hold,"each pitched step initially waits");
      old_tick=roll_tick;cycles(4);check(hold&&roll_tick==old_tick,"held/spanning/previous receipt cannot advance next step");
      if(e>0 && pitch(s,e)==pitch(s,e-1))repeats=repeats+1;
      @(negedge clk);midi_on=0;cycles(3);
      fresh(pitch(s,e)^7'h01,0);cycles(2);check(hold&&roll_tick==old_tick,"wrong fresh note does not advance");
      if(e==0)begin
       @(negedge clk);suspended=1;fresh(pitch(s,e),1);cycles(5);
       check(roll_tick==old_tick&&hold,"matching key while paused is discarded");
       @(negedge clk);suspended=0;cycles(4);check(hold,"paused key spanning resume cannot unlock");
       @(negedge clk);midi_on=0;cycles(3);
      end
      fresh(pitch(s,e),e==0);check(!hold&&roll_tick==old_tick,"one correct fresh event releases this step only");
      practiced=practiced+1;
      if(e==0)begin
       cycles(5);@(negedge clk);suspended=1;paused_tick=roll_tick;cycles(7);
       check(roll_tick==paused_tick,"accepted step pauses without advancing");
       @(negedge clk);suspended=0;cycles(3);
       if(ready && step==e)check(!hold,"accepted step resumes without a second key");
      end
     end
     guard=0;
     while(roll_tick<last_tick(s,e) && !done)begin
      cycles(1);guard=guard+1;check(guard<12000,"accepted note/rest crosses real quarter bubbles without deadlock");
      if(ready && step==e)check(!hold,"acceptance retained across all quarters of same step");
     end
    end
    @(negedge clk);midi_on=0;
   end
   finish_song;
  end
  if(MODE==2)begin
   check(practiced==n_pitched(0)+n_pitched(1)+n_pitched(2),"exactly one accepted receipt per pitched event");
   check(rest_steps==n_events(0)+n_events(1)+n_events(2)-practiced && rest_steps>0,"all actual ROM rests exercised");
   check(repeats>0,"actual adjacent same-pitch steps exercised");
  end
  if(MODE==1)begin
   full_scoreboard=0;launch(0);guard=0;
   while(ons==0)begin cycles(1);guard=guard+1;check(guard<1024,"demo first onset for pause probe");end
   cycles(2);@(negedge clk);suspended=1;paused_tick=roll_tick;cycles(8);
   check(roll_tick==paused_tick && gates==0 && offs==1,"demo pause freezes and releases gate");
   @(negedge clk);suspended=0;cycles(8);
   check(ons==2 && gate_count==1 && last_pitch==pitch(0,0),"demo resume rearticulates remaining same note once");
   @(negedge clk);suspended=1;cycles(8);check(gates==0 && offs==2,"demo pause cleanup");
  end
  $display("V045_SCORE_MODES_PASS checks=%0d mode=%0d gap=%0d songs=%0d ons=%0d offs=%0d bubbles=%0d accepted=%0d rests=%0d adjacent_repeats=%0d",checks,MODE,GAP,full_runs,total_ons,total_offs,total_bubbles,practiced,rest_steps,repeats);$finish;
 end
 initial begin #10000000;$fatal(1,"score modes watchdog");end
endmodule
