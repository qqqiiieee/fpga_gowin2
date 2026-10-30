`timescale 1ns/1ps
// External-pin regression: no forced DUT state. Counts are scaled, not bypassed.
module tb_v034_buttons;
 parameter DB=4;
 localparam HOLD=64, SETTLE=DB+8;
 reg clk=0,rst_n=0; always #5 clk=~clk;
 reg [3:0] keys_n=4'he;
 reg guide_done=0,test_owned=0,pset=0;
 reg [7:0] param=0,value=0;
 wire [1:0] page,song,cursor;
 wire start,toggle,restart,timbre,mode,pause;
 wire [3:0] down;
 wire [4:0] pulses={start,toggle,restart,timbre,mode};
 reg [4:0] previous=0;
 integer starts=0,toggles=0,restarts=0,timbres=0,modes=0,checks=0;
 integer ss,st,sr,tt,mm,i,j,age;
 reg [3:0] saved_ui;
 four_button_display_control #(.DEBOUNCE_CYCLES(DB),.LONG_PRESS_CYCLES(HOLD)) dut(
  .clk(clk),.rst_n(rst_n),.keys_n(keys_n),.guide_done(guide_done),.test_owned(test_owned),
  .page(page),.song_id(song),.cursor(cursor),.song_start(start),.song_toggle(toggle),
  .song_restart(restart),.key_pause(pause),.buttons_down(down),
  .phone_set_valid(pset),.phone_param(param),.phone_value(value),
  .timbre_cycle(timbre),.mode_cycle(mode));
 always @(posedge clk) begin
  #1;
  if(!rst_n) previous=0;
  else begin
   if((^{page,song,cursor,down,pulses,pause})===1'bx)$fatal(1,"controller X");
   if((previous&pulses)!=0)$fatal(1,"event lasted more than one clock");
   if(pulses!=0 && down!=0)$fatal(1,"action before debounced release");
   if((pulses&(pulses-1))!=0)$fatal(1,"two actions from one release");
   if(cursor!==song)$fatal(1,"song cursor diverged");
   previous=pulses;
   if(start)starts=starts+1;if(toggle)toggles=toggles+1;
   if(restart)restarts=restarts+1;if(timbre)timbres=timbres+1;if(mode)modes=modes+1;
  end
 end
 task clocks(input integer n);repeat(n)@(negedge clk);endtask
 task check(input condition,input [799:0] text);begin
  checks=checks+1;if(condition!==1)$fatal(1,"%0s DB=%0d page/song=%0d/%0d actions=%0d/%0d/%0d/%0d/%0d",text,DB,page,song,starts,toggles,restarts,timbres,modes);
 end endtask
 task remember;begin saved_ui={page,song};ss=starts;st=toggles;sr=restarts;tt=timbres;mm=modes;end endtask
 task unchanged(input [799:0] text);begin
  check(saved_ui=={page,song} && ss==starts && st==toggles && sr==restarts && tt==timbres && mm==modes,text);
 end endtask
 task level(input [3:0] mask,input integer n);begin keys_n=~mask;clocks(n);end endtask
 task release_keys;begin level(0,SETTLE*2);end endtask
 task click(input integer key);begin level(1<<key,SETTLE);release_keys;end endtask
 task long_click(input integer key);begin
  remember;level(1<<key,HOLD*4);unchanged("long hold neither repeats nor fires early");release_keys;
 end endtask
 task phone(input integer p,v);begin param=p;value=v;pset=1;clocks(1);pset=0;clocks(2);end endtask
 initial begin
  clocks(5);rst_n=1;clocks(HOLD*2);remember;release_keys;
  unchanged("boot-held KEY1 release must not act");check(pause,"boot waits for start");
  for(i=1;i<=4;i=i+1)begin click(0);check(page==i%4,"short KEY1 cycles four pages");end
  click(1);check(starts==1 && !pause,"short KEY2 starts");
  click(1);check(toggles==1,"short KEY2 toggles after start");
  guide_done=1;click(1);guide_done=0;check(starts==2,"done KEY2 starts again");
  long_click(0);check(timbres==tt+1 && page==saved_ui[3:2],"long KEY1 only timbre");
  check(starts==ss && toggles==st && restarts==sr && modes==mm,"long KEY1 isolated");
  long_click(1);check(modes==mm+1 && saved_ui=={page,song},"long KEY2 only mode");
  check(starts==ss && toggles==st && restarts==sr && timbres==tt,"long KEY2 has no play/pause");
  // Equal press/release debounce delays preserve raw stable gesture duration.
  // HOLD is a power of two: the long hold above crosses twice the counter range.
  remember;level(1,HOLD-1);release_keys;
  check(timbres==tt && page==((saved_ui[3:2]+1)%4),"one cycle below threshold is short");
  remember;level(1,HOLD);release_keys;
  check(timbres==tt+1 && page==saved_ui[3:2],"exact threshold is long");
  click(2);check(restarts==1 && page==0,"KEY3 restart remains");
  for(i=1;i<=3;i=i+1)begin click(3);check(song==i%3 && page==1 && pause,"KEY4 song cycle waits");end
  // Sub-debounce press/release chatter cannot become a new gesture.
  remember;
  for(i=0;i<4;i=i+1)begin
   level(1<<i,DB-1);release_keys;unchanged("press bounce ignored");
  end
  level(1,SETTLE);level(0,DB-1);level(1,SETTLE);unchanged("release bounce deferred");
  release_keys;check(page==((saved_ui[3:2]+1)%4) && timbres==tt,"bouncy short KEY1 once");
  // Every pair: simultaneous, staggered and substitution are cancelled to all-up.
  for(i=0;i<4;i=i+1)for(j=i+1;j<4;j=j+1)begin
   remember;level((1<<i)|(1<<j),HOLD*2);level(1<<i,SETTLE);release_keys;unchanged("chord cancelled");
   level(1<<i,HOLD+SETTLE);level((1<<i)|(1<<j),SETTLE);level(1<<j,SETTLE);release_keys;unchanged("long then chord cancelled");
   level(1<<i,SETTLE);level(1<<j,SETTLE);release_keys;unchanged("direct key substitution cancelled");
  end
  // All five absolute UI parameters cancel both short/long pending gestures.
  for(i=0;i<5;i=i+1)for(j=0;j<2;j=j+1)begin
   release_keys;remember;level(1<<j,HOLD*2);
   phone(i==0?1:(i==1?2:(i==2?12:(i==3?13:14))),i==2?saved_ui[3:2]:1);
   release_keys;unchanged("phone SET cancels held long gesture");
  end
  // Precisely collide with the consumer edge after debounced release.
  for(j=0;j<2;j=j+1)begin
   remember;level(1<<j,HOLD*2);keys_n=15;age=0;
   while(down!=0 && age<SETTLE*2)begin clocks(1);age=age+1;end
   check(down==0,"collision found release boundary");
   phone(j==0?1:2,1);release_keys;unchanged("same-edge absolute SET outranks release");
  end
  // Unrelated volume SET must not consume a legitimate mode gesture.
  remember;level(2,HOLD*2);phone(0,200);release_keys;
  check(modes==mm+1 && starts==ss && toggles==st,"unrelated SET preserves long mode gesture");
  // Enter ownership while held; exit still held and release must remain inert.
  remember;level(1,HOLD*2);test_owned=1;clocks(SETTLE);
  level(2,HOLD*2);test_owned=0;clocks(HOLD*2);release_keys;
  unchanged("test ownership consumes held/exit gesture");
  long_click(0);check(timbres==tt+1,"ownership exit rearms after full release");
  $display("V034_BUTTONS_PASS checks=%0d debounce=%0d release_only=1 long_short=1 bounce=1 chords=1 phone=1 boot=1 ownership=1",checks,DB);$finish;
 end
 initial begin #1000000;$fatal(1,"V034 buttons watchdog");end
endmodule
