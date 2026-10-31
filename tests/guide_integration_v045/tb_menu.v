`timescale 1ns/1ps
module tb_menu;
 parameter integer DB=4;
 localparam integer HOLD=64,SETTLE=DB+12;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg [3:0] keys=15;reg owned=0,available=0,done=0,phone_valid=0,mode_valid=0,set_valid=0;
 reg [1:0] phone_song=0,action=0;reg [7:0] param=0,value=0;
 wire [1:0] song,page,cursor;wire [3:0] down;wire pause_key;
 wire start,toggle,restart,cycle_mode,timbre,play_mode,test_toggle,test_count,test_sweep,test_full;
 wire [9:0] events={cycle_mode,test_full,test_sweep,test_count,test_toggle,play_mode,timbre,restart,toggle,start};
 integer checks=0,totals[0:9],saved[0:9],k,i,h,before_restart,before_mode;
 reg [9:0] previous=0;
 four_button_display_control #(.DEBOUNCE_CYCLES(DB),.LONG_PRESS_CYCLES(HOLD),
  .CUSTOM_SONG_ENABLE(1),.GUIDE_MODES_ENABLE(1)) dut(
  .clk(clk),.rst_n(rst_n),.keys_n(keys),.guide_done(done),.test_owned(owned),
  .custom_song_available(available),.phone_song_command_valid(phone_valid),.phone_song_command(action),
  .phone_song_id(phone_song),.phone_guide_mode_valid(mode_valid),.guide_stop(1'b0),.phone_set_valid(set_valid),
  .phone_param(param),.phone_value(value),.page(page),.song_id(song),.cursor(cursor),
  .song_start(start),.song_toggle(toggle),.song_restart(restart),.key_pause(pause_key),.buttons_down(down),
  .timbre_cycle(timbre),.mode_cycle(play_mode),.guide_mode_cycle(cycle_mode),
  .test_toggle(test_toggle),.test_count_cycle(test_count),.test_sweep_toggle(test_sweep),.test_full(test_full));
 always @(posedge clk)begin
  #1;
  if(!rst_n)begin previous=0;for(k=0;k<10;k=k+1)totals[k]=0;end
  else begin
   if((^{events,page,song,down,pause_key})===1'bx)$fatal(1,"unknown menu output");
   if((events & previous)!=0)$fatal(1,"multi-clock menu command");
   if(owned && (cycle_mode||restart||start||toggle||timbre||play_mode))$fatal(1,"owned leaks normal gesture");
   if(cycle_mode && !restart)$fatal(1,"long4 must restart together with mode cycle");
   if(cursor!==song)$fatal(1,"cursor diverged");
   for(k=0;k<10;k=k+1)if(events[k])totals[k]=totals[k]+1;
   previous=events;
  end
 end
 task tick(input integer n);repeat(n)begin @(posedge clk);#2;end endtask
 task check(input c,input [1023:0] m);
  begin checks=checks+1;if(c!==1'b1)$fatal(1,"%0s DB=%0d song=%0d page=%0d",m,DB,song,page);end
 endtask
 task remember;for(i=0;i<10;i=i+1)saved[i]=totals[i];endtask
 task delta(input [9:0] expected);
  for(i=0;i<10;i=i+1)check(totals[i]==saved[i]+expected[i],"menu pulse counts");
 endtask
 task press4(input integer clocks);begin @(negedge clk);keys=7;tick(clocks);end endtask
 task release4;begin @(negedge clk);keys=15;tick(2*SETTLE);end endtask
 task song_command(input [1:0] s,input [1:0] a);
  begin @(negedge clk);phone_song=s;action=a;phone_valid=1;tick(1);
   @(negedge clk);phone_valid=0;tick(2*SETTLE);end
 endtask
 task mode_command;
  begin @(negedge clk);mode_valid=1;tick(1);@(negedge clk);mode_valid=0;tick(2);end
 endtask
 task release_to_commit_edge;
  begin @(negedge clk);keys=15;tick(1);
   while(down!=0)tick(1);
   // Stable release is now visible; next rising edge would commit the gesture.
   @(negedge clk);
  end
 endtask
 initial begin
  tick(4);@(negedge clk);rst_n=1;tick(2*SETTLE);
  check(song==0 && pause_key,"power-on waits for start");
  remember;press4(HOLD+SETTLE);delta(0);release4;delta(10'b1000000100);
  check(song==0 && pause_key,"long4 preserves selected song and waiting state");
  remember;press4(SETTLE);release4;delta(0);check(song==1 && page==1,"short4 next song");
  press4(SETTLE);release4;check(song==2,"short4 third builtin");
  press4(SETTLE);release4;check(song==0,"no custom skips slot3");
  available=1;
  for(h=0;h<4;h=h+1)begin press4(SETTLE);release4;end
  check(song==0,"custom enabled four-song wrap");
  song_command(2,1);check(song==2 && !pause_key,"phone builtin start");
  remember;press4(HOLD+SETTLE);release4;delta(10'b1000000100);
  check(song==2 && !pause_key,"long4 keeps started state");
  $display("CASE_PASS menu_long4_short4_and_song_range");

  @(negedge clk);owned=1;tick(2*SETTLE);remember;
  press4(HOLD+SETTLE);release4;delta(0);check(song==2,"owned long4 inert");
  remember;press4(SETTLE);release4;delta(10'b0100000000);
  remember;song_command(0,1);mode_command;tick(SETTLE);delta(0);check(song==2,"owned phone cannot change song/mode");
  @(negedge clk);owned=0;tick(2*SETTLE);
  remember;press4(HOLD+SETTLE);@(negedge clk);owned=1;tick(2);release4;delta(0);
  @(negedge clk);owned=0;tick(2*SETTLE);
  $display("CASE_PASS menu_owned_long4_short4_and_owner_edge_cancel");

  remember;press4(HOLD+SETTLE);release_to_commit_edge;
  phone_song=1;action=1;phone_valid=1;tick(1);@(negedge clk);phone_valid=0;tick(2*SETTLE);
  delta(10'b0000000001);check(song==1 && !pause_key,"phone start outranks long4 release");
  remember;press4(HOLD+SETTLE);release_to_commit_edge;
  mode_valid=1;tick(1);@(negedge clk);mode_valid=0;tick(2*SETTLE);
  delta(10'b0000000100);check(song==1 && !pause_key,"phone mode outranks long4 without extra mode cycle");
  remember;press4(HOLD+SETTLE);mode_command;release4;delta(10'b0000000100);
  check(song==1,"phone mode cancels held gesture through release");
  song_command(0,0);remember;mode_command;tick(2*SETTLE);delta(10'b0000000100);
  check(pause_key && song==0,"phone mode preserves wait for start");
  remember;press4(HOLD+SETTLE);release_to_commit_edge;
  param=12;value=3;set_valid=1;tick(1);@(negedge clk);set_valid=0;tick(2*SETTLE);
  delta(0);check(page==3 && song==0,"phone absolute page set outranks release");
  remember;press4(SETTLE);@(negedge clk);keys=3;tick(SETTLE);release4;delta(0);
  check(song==0,"multi-key gesture cancelled");
  $display("CASE_PASS menu_phone_same_edge_priority_and_gesture_cancel");
  $display("V045_MENU_PASS checks=%0d debounce=%0d",checks,DB);$finish;
 end
 initial begin #1000000;$fatal(1,"menu timeout");end
endmodule
