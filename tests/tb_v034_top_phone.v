`timescale 1ns/1ps
// Real top and UART framing. Only physical HDMI is replaced by the shared stub.
`include "hdmi_display_stub.vh"
module tb_v034_top_phone;
 localparam DB=4,HOLD=64,BC=32,SETTLE=DB+10;
 reg clk=0;always #18.518 clk=~clk;
 reg rx=1;reg [3:0] keys_n=15;
 tri1 scl,sda;wire tx;
 top #(.BUTTON_DEBOUNCE_CYCLES(DB),.BUTTON_LONG_PRESS_CYCLES(HOLD)) dut(
  .clk(clk),.ui_buttons_n(keys_n),.phone_uart_rx(rx),.phone_uart_tx(tx),
  .uart_rx(1'b1),.midi_rx(1'b1),.optical_beams(2'b11),.adc_scl(scl),.adc_sda(sda));
 defparam dut.u_phone.CLK_HZ=BC*115200;
 wire [7:0] byte_rx;wire valid,error;
 midi_uart_rx #(.CLK_HZ(BC*115200),.BAUD(115200)) monitor(
  .clk(clk),.rst_n(dut.rst_n),.rx(tx),.data(byte_rx),.data_valid(valid),.framing_error(error));
 reg [7:0] replies[0:4095];integer received=0,seq=0,checks=0;
 integer starts=0,toggles=0,restarts=0,timbres=0,modes=0,panics=0,sets=0,collisions=0;
 integer ss,st,sr,tt,mm,pp,ii,previous_mode=0;
 reg [4:0] previous_pulses=0;
 reg [1:0] saved_page,saved_song;
 always @(posedge clk)begin
  if(dut.rst_n)begin
   if(error)$fatal(1,"phone response framing");
   if(valid)begin if(received>=4096)$fatal(1,"reply overflow");replies[received]=byte_rx;received=received+1;end
   if(dut.phone_set)sets=sets+1;
   if(dut.phone_set && dut.buttons_down==0 && dut.u_menu.pending!=0)collisions=collisions+1;
   if(dut.u_audio.panic_audio)panics=panics+1;
  end
  #1;
  if(dut.rst_n)begin
   if((^{dut.ui_strum_mode,dut.timbre,dut.ui_page,dut.buttons_down})===1'bx)$fatal(1,"top UI X");
   if(dut.ui_strum_mode>2)$fatal(1,"invalid top mode");
   if(dut.u_display.strum_mode!==dut.ui_strum_mode)$fatal(1,"HDMI boundary lost two-bit mode");
   if(({dut.ui_start,dut.ui_toggle,dut.ui_restart,dut.panel_timbre_cycle,dut.panel_mode_cycle}&previous_pulses)!=0)
    $fatal(1,"top event exceeds one cycle");
   previous_pulses={dut.ui_start,dut.ui_toggle,dut.ui_restart,dut.panel_timbre_cycle,dut.panel_mode_cycle};
   if(dut.ui_start)starts=starts+1;if(dut.ui_toggle)toggles=toggles+1;
   if(dut.ui_restart)restarts=restarts+1;if(dut.panel_timbre_cycle)timbres=timbres+1;if(dut.panel_mode_cycle)modes=modes+1;
   if(dut.u_audio.note_on || dut.u_audio.note_off)$fatal(1,"UI/phone produced musical note");
   if(dut.u_audio.overrun)$fatal(1,"audio overrun");
  end
 end
 task automatic clocks(input integer n);repeat(n)@(negedge clk);endtask
 task automatic check(input condition,input [799:0] text);begin checks=checks+1;if(condition!==1)$fatal(1,"%0s mode=%0d timbre=%0d page=%0d",text,dut.ui_strum_mode,dut.timbre,dut.ui_page);end endtask
 task automatic remember;begin saved_page=dut.ui_page;saved_song=dut.ui_song;ss=starts;st=toggles;sr=restarts;tt=timbres;mm=modes;pp=panics;end endtask
 task automatic untouched_short;begin check(dut.ui_page==saved_page && dut.ui_song==saved_song && starts==ss && toggles==st && restarts==sr,"no unintended short/menu action");end endtask
 task automatic byte_tx(input [7:0] v);integer b;begin
  @(negedge clk);rx=0;clocks(BC);for(b=0;b<8;b=b+1)begin rx=v[b];clocks(BC);end rx=1;clocks(BC);
 end endtask
 task automatic phone(input [7:0] cmd,p,v,expected,result);integer base,b,age,oldsets;reg[7:0] crc;begin
  base=received;oldsets=sets;
  byte_tx(8'ha5);byte_tx(8'h5a);byte_tx(1);byte_tx(seq);byte_tx(cmd);byte_tx(p);byte_tx(v);
  repeat(4)byte_tx(0);byte_tx(1^seq^cmd^p^v);
  age=0;while(received<base+12 && age<5000)begin clocks(1);age=age+1;end
  check(received==base+12,"exactly one twelve-byte ACK");
  if(replies[base]!=8'h5a || replies[base+1]!=8'ha5 || replies[base+2]!=1 || replies[base+3]!=seq ||
     replies[base+4]!=result || replies[base+5]!=p || replies[base+6]!=expected)
   $fatal(1,"ACK cmd=%0d param=%0d value=%0d result=%0d expected=%0d/%0d",cmd,p,replies[base+6],replies[base+4],expected,result);
  crc=0;for(b=2;b<11;b=b+1)crc=crc^replies[base+b];check(replies[base+11]==crc,"ACK XOR");
  check(sets==oldsets+((cmd==1 && result==0)?1:0),"GET/invalid SET does not publish set_valid");
  if(p==2 && result==0)check(replies[base+7][4]==(expected!=0),"status optical-enabled bit for all modes");
  seq=(seq+1)&255;clocks(SETTLE*2);
 end endtask
 task automatic click(input integer key,input integer duration);begin keys_n=~(4'b1<<key);clocks(duration);keys_n=15;clocks(SETTLE*2);end endtask
 // Align physical release with the real RX checksum stop-bit commit.
 task automatic release_at_commit;integer age;begin
  age=0;while(!(dut.u_phone.pos==11 && dut.u_phone.receiver.state==3 && dut.u_phone.receiver.timer==DB) && age<5000)begin clocks(1);age=age+1;end
  if(age==5000)$fatal(1,"UART release alignment timed out seq=%0d pos=%0d state=%0d rxstate=%0d timer=%0d bitcycles=%0d",seq,dut.u_phone.pos,dut.u_phone.state,dut.u_phone.receiver.state,dut.u_phone.receiver.timer,dut.u_phone.receiver.BIT_CYCLES);keys_n=15;
 end endtask
 integer oldcoll,oldsets;
 initial begin
  clocks(600);check(dut.ui_strum_mode==0 && dut.timbre==0,"reset KEY/flute");
  phone(0,2,0,0,0);remember;phone(1,2,2,2,0);phone(0,2,0,2,0);
  check(panics==pp+1,"one mode panic on KEY to HYBRID");
  remember;phone(1,2,2,2,0);phone(1,2,3,2,3);phone(0,2,0,2,0);
  check(dut.ui_strum_mode==2 && panics==pp,"same mode and invalid3 neither mutate nor panic");untouched_short;
  phone(1,2,0,0,0);
  for(ii=1;ii<=3;ii=ii+1)begin
   remember;keys_n=13;clocks(HOLD*3);check(dut.ui_strum_mode==((ii-1)%3),"mode changes only on release");untouched_short;
   keys_n=15;clocks(SETTLE*2);check(dut.ui_strum_mode==(ii%3) && modes==mm+1,"panel cycles KEY STRUM HYBRID KEY");
   check(panics==pp+1,"exactly one panic per panel mode transition");untouched_short;phone(0,2,0,ii%3,0);
  end
  for(ii=1;ii<=2;ii=ii+1)begin
   remember;click(0,HOLD*3);check(dut.timbre==(ii%2) && timbres==tt+1,"panel toggles both actual timbres");
   check(panics==pp,"timbre change does not panic");untouched_short;phone(0,1,0,ii%2,0);
  end
  // Cancel held long gesture by absolute phone values; no release action leaks.
  remember;keys_n=14;clocks(HOLD*2);phone(1,1,1,1,0);keys_n=15;clocks(SETTLE*2);
  check(timbres==tt && dut.timbre==1,"phone timbre cancels long KEY1");untouched_short;
  remember;keys_n=13;clocks(HOLD*2);oldcoll=collisions;
  fork phone(1,2,2,2,0);release_at_commit;join
  check(collisions==oldcoll+1 && modes==mm && dut.ui_strum_mode==2,"same-edge phone mode outranks long release");untouched_short;
  // GET reads the new value after release and must not swallow the gesture.
  remember;keys_n=14;clocks(HOLD*2);
  fork phone(0,1,0,0,0);release_at_commit;join
  check(timbres==tt+1 && dut.timbre==0,"GET does not cancel long timbre");untouched_short;
  // Short bindings still execute, without changing mode or timbre.
  remember;click(0,SETTLE);check(dut.ui_page==((saved_page+1)%4) && timbres==tt && modes==mm,"short page preserved");
  remember;click(1,SETTLE);check(starts==ss+1 && modes==mm && dut.ui_page==0,"short start preserved");
  remember;click(1,SETTLE);check(toggles==st+1 && modes==mm,"short pause preserved");
  remember;click(2,SETTLE);check(restarts==sr+1,"restart preserved");
  remember;click(3,SETTLE);check(dut.ui_song==(saved_song==2?0:saved_song+1) && dut.ui_page==1,"song preserved");
  phone(0,2,0,2,0);phone(0,1,0,0,0);
  $display("V034_TOP_PHONE_PASS checks=%0d uart=1 invalid3=1 panel_cycle=1 actual_timbres=1 collision=1 short_bindings=1 panics=%0d",checks,panics);$finish;
 end
 initial begin #20000000;$fatal(1,"V034 top phone watchdog");end
endmodule
