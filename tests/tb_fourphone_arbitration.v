`timescale 1ns/1ps
// Actual production top, phone RX/TX bits and physical GPIO keys. Only HDMI is
// a passive boundary stub. Phone baud, debounce and guide/test timers shortened.
// Diagnostic entry ONLY: inject ui_test_keys at the existing engine boundary;
// no force of page/song/phone_set/owned/audio state or musical events.
`include "hdmi_display_stub.vh"
module tb_fourphone_arbitration;
 parameter DB=4;
 localparam BC=32,SETTLE=DB*4+16;
 reg clk=0;always #18.518 clk=~clk;
 reg phone_rx=1;reg [3:0] buttons_n=4'b1110;
 tri1 scl,sda;wire phone_tx;
 top #(.BUTTON_DEBOUNCE_CYCLES(DB),.GUIDE_BEAT_SAMPLES(7),
       .TEST_HOLD_SAMPLES(4),.TEST_RAMP_DIV(1),.TEST_MAX_SAMPLES(10000)) dut(
  .clk(clk),.ui_buttons_n(buttons_n),.phone_uart_rx(phone_rx),.phone_uart_tx(phone_tx),
  .uart_rx(1'b1),.midi_rx(1'b1),.touch_miso(1'b1),.optical_beams(2'b11),
  .adc_scl(scl),.adc_sda(sda));
 defparam dut.u_phone.CLK_HZ=BC*115200;
 wire [7:0] rx_byte;wire rx_valid,rx_error;
 midi_uart_rx #(.CLK_HZ(BC*115200),.BAUD(115200)) monitor(
  .clk(clk),.rst_n(dut.rst_n),.rx(phone_tx),.data(rx_byte),.data_valid(rx_valid),.framing_error(rx_error));
 reg [7:0] replies[0:4095];integer received=0,seq=0;
 integer starts=0,toggles=0,restarts=0,collisions=0,checks=0;
 reg [2:0] previous_pulses=0;
 always @(posedge clk)begin
  if(dut.rst_n)begin
   if(rx_error)$fatal(1,"phone ACK framing error");
   if(rx_valid)begin replies[received]=rx_byte;received=received+1;end
   if(dut.phone_set && dut.u_menu.armed && dut.buttons_down==0 && dut.u_menu.pending!=0)
    collisions=collisions+1;
  end
  #1;
  if(dut.rst_n)begin
   if((^{dut.ui_page,dut.ui_song,dut.ui_cursor,dut.ui_strum_mode,dut.ui_filter_enable,
         dut.ui_zero_mode,dut.buttons_down,dut.ui_start,dut.ui_toggle,dut.ui_restart})===1'bx)
    $fatal(1,"UI X / conflicting drive");
   if(({dut.ui_start,dut.ui_toggle,dut.ui_restart}&previous_pulses)!=0)
    $fatal(1,"UI event wider than one clock");
   previous_pulses={dut.ui_start,dut.ui_toggle,dut.ui_restart};
   if(dut.ui_start)starts=starts+1;
   if(dut.ui_toggle)toggles=toggles+1;
   if(dut.ui_restart)restarts=restarts+1;
   if(dut.ui_cursor!==dut.ui_song)$fatal(1,"selection cursor lost song");
   if(dut.u_display.ui_controls!==dut.buttons_down)$fatal(1,"HDMI status not connected to four keys");
   if(dut.u_audio.note_on || dut.u_audio.hit0 || dut.u_audio.hit1 || dut.u_audio.hat_closed_hit ||
      dut.u_audio.hat_open_hit)$fatal(1,"menu/phone generated musical event");
   if(dut.touch_cs_n!==1 || dut.touch_sclk!==0 || dut.touch_mosi!==0 || dut.keys!==0)
    $fatal(1,"old analog input active by default");
   if(dut.control_page!==2 || dut.ui_fx_cycle!==0)$fatal(1,"fixed FX changed");
   if(dut.u_audio.overrun)$fatal(1,"synth overrun");
   checks=checks+1;
  end
 end
 task automatic clocks(input integer n);begin repeat(n)@(negedge clk);end endtask
 task automatic level(input [3:0] down);begin
  @(negedge clk);buttons_n=~down;clocks(SETTLE);
  if(dut.buttons_down!==down || dut.u_display.ui_controls!==down)
   $fatal(1,"debounced/display level got=%b expected=%b",dut.buttons_down,down);
 end endtask
 reg [3:0] saved_ui;integer ss,st,sr;
 task automatic remember;begin saved_ui={dut.ui_page,dut.ui_song};ss=starts;st=toggles;sr=restarts;end endtask
 task automatic unchanged(input [511:0] label_text);begin
  if(saved_ui!=={dut.ui_page,dut.ui_song} || ss!=starts || st!=toggles || sr!=restarts)
   $fatal(1,"%0s: UI changed unexpectedly page/song=%d/%d",label_text,dut.ui_page,dut.ui_song);
 end endtask
 task automatic click(input integer key);begin level(4'b1<<key);level(0);end endtask
 task automatic byte_tx(input [7:0] v);integer b;begin
  @(negedge clk);phone_rx=0;clocks(BC);
  for(b=0;b<8;b=b+1)begin phone_rx=v[b];clocks(BC);end
  phone_rx=1;clocks(BC);
 end endtask
 task automatic phone(input [7:0] cmd,p,v,expected,result);integer base,b,age;reg [7:0] crc;begin
  base=received;byte_tx(8'ha5);byte_tx(8'h5a);byte_tx(1);byte_tx(seq);
  byte_tx(cmd);byte_tx(p);byte_tx(v);repeat(4)byte_tx(0);byte_tx(1^seq^cmd^p^v);
  age=0;while(received<base+12 && age<5000)begin clocks(1);age=age+1;end
  if(received!=base+12 || replies[base]!=8'h5a || replies[base+1]!=8'ha5 ||
     replies[base+2]!=1 || replies[base+3]!=seq || replies[base+4]!=result ||
     replies[base+5]!=p || replies[base+6]!=expected)
   $fatal(1,"ACK cmd=%0d p=%0d expected=%0d actual=%0d result=%0d wanted=%0d bytes=%0d",
          cmd,p,expected,replies[base+6],replies[base+4],result,received-base);
  crc=0;for(b=2;b<11;b=b+1)crc=crc^replies[base+b];
  if(replies[base+11]!=crc)$fatal(1,"ACK checksum");
  seq=(seq+1)&255;clocks(BC+SETTLE);
 end endtask
 // Release timing is derived from the REAL receiver's last checksum stop bit.
 // DB clocks left in STOP makes phone_set and the debounced release meet at the
 // menu's very same consuming edge. No protocol pulse/state is forced.
 task automatic release_at_commit(input integer offset);integer age;begin
  age=0;
  while(!(dut.u_phone.pos==11 && dut.u_phone.receiver.state==3 &&
          dut.u_phone.receiver.timer==DB+offset) && age<5000)begin clocks(1);age=age+1;end
  if(age==5000)$fatal(1,"could not align release with UART commit seq=%0d pos=%0d rxstate=%0d timer=%0d BC=%0d offset=%0d",seq,dut.u_phone.pos,dut.u_phone.receiver.state,dut.u_phone.receiver.timer,dut.u_phone.receiver.BIT_CYCLES,offset);
  buttons_n=15;
 end endtask
 integer i,j,k,oldcoll,oldstart,oldtoggle,oldrestart,age;
 reg [1:0] oldsong;reg [11:0] frozen;
 initial begin
  clocks(500);remember;clocks(SETTLE*2);unchanged("startup held KEY1");
  level(0);unchanged("startup release");
  if(!dut.menu_key_pause || dut.roll_tick!=0)$fatal(1,"startup autoplay");
  for(i=1;i<=4;i=i+1)begin click(0);if(dut.ui_page!==(i%4))$fatal(1,"page cycle");end
  for(i=1;i<=3;i=i+1)begin
   click(3);if(dut.ui_song!==(i%3) || dut.ui_page!=1 || !dut.menu_key_pause)$fatal(1,"song cycle");
   phone(1,12,0,0,0);frozen=dut.roll_tick;clocks(1200);
   if(dut.roll_tick!==frozen || !dut.menu_key_pause)$fatal(1,"phone page bypassed waiting-start");
   oldstart=starts;click(1);clocks(1200);
   if(starts!=oldstart+1 || dut.roll_song!==(i%3) || !dut.guide_active || dut.roll_tick==0)
    $fatal(1,"selected song did not start");
   oldtoggle=toggles;click(1);frozen=dut.roll_tick;clocks(1200);
   if(toggles!=oldtoggle+1 || dut.guide_active || dut.roll_tick!==frozen)$fatal(1,"pause failed");
   click(1);clocks(1200);if(!dut.guide_active || dut.roll_tick<=frozen)$fatal(1,"resume failed");
   oldrestart=restarts;click(2);
   if(restarts!=oldrestart+1 || dut.roll_tick>10 || !dut.guide_active)$fatal(1,"restart failed");
  end
  // Complete a real shortened timeline, then KEY2 starts instead of toggling.
  age=0;while(!dut.guide_done && age<1100000)begin clocks(1);age=age+1;end
  if(!dut.guide_done)$fatal(1,"real timeline completion timeout");
  oldstart=starts;click(1);
  if(starts!=oldstart+1 || dut.guide_done || !dut.guide_active)$fatal(1,"done restart failed");
  // All chords, staggered transitions and substitution cancel through release.
  for(i=0;i<4;i=i+1)for(j=i+1;j<4;j=j+1)begin
   remember;level((4'b1<<i)|(4'b1<<j));level(4'b1<<j);level(0);unchanged("chord");
   level(4'b1<<i);level((4'b1<<i)|(4'b1<<j));level(4'b1<<i);level(0);unchanged("staggered chord");
  end
  remember;level(2);level(4);level(0);unchanged("substitution");
  level(15);level(1);level(0);unchanged("all four chord");
  if(DB>1)begin
   for(i=0;i<4;i=i+1)begin buttons_n=~(4'b1<<i);clocks(1);level(0);unchanged("press bounce");end
   level(2);buttons_n=15;clocks(1);level(2);unchanged("release bounce");
   oldtoggle=toggles;level(0);if(toggles!=oldtoggle+1)$fatal(1,"bouncy release not once");
  end
  // SET/GET page leaves song/cursor intact. GET reflects subsequent KEY1.
  oldsong=dut.ui_song;
  for(i=0;i<4;i=i+1)begin
   phone(1,12,i,i,0);phone(0,12,0,i,0);
   if(dut.ui_song!==oldsong || dut.ui_cursor!==oldsong)$fatal(1,"phone page changed song");
   click(0);phone(0,12,0,(i+1)%4,0);
  end
  phone(1,12,0,0,0);
  phone(1,12,4,0,3); // Rejected range must leave actual page at zero.
  level(1);phone(1,12,3,3,0);level(0);
  if(dut.ui_page!=3)$fatal(1,"held gesture undid SET");
  click(0);if(dut.ui_page!=0)$fatal(1,"did not rearm after SET");
  // Every key loses its release to a simultaneous absolute page SET.
  for(k=0;k<4;k=k+1)begin
   phone(1,12,0,0,0);oldsong=dut.ui_song;ss=starts;st=toggles;sr=restarts;
   level(4'b1<<k);oldcoll=collisions;
   fork phone(1,12,3,3,0); release_at_commit(0); join
   if(collisions!=oldcoll+1 || dut.ui_page!=3 || dut.ui_song!==oldsong ||
      starts!=ss || toggles!=st || restarts!=sr)$fatal(1,"same-edge page priority key=%0d",k);
  end
  // Other phone UI settings cancel a pending song key on the same edge.
  for(k=0;k<3;k=k+1)begin
   level(8);remember;oldcoll=collisions;
   fork phone(1,(k==0?2:(k==1?13:14)),(k==1?0:1),(k==1?0:1),0); release_at_commit(0); join
   unchanged("phone mode/filter/zero priority");
   if(collisions!=oldcoll+1)$fatal(1,"missed UI SET collision");
  end
  phone(0,2,0,1,0);phone(0,13,0,0,0);phone(0,14,0,1,0);
  if(!dut.ui_strum_mode || dut.u_audio.filter_enable || !dut.flags[0])$fatal(1,"UI SET not applied");
  phone(1,2,0,0,0);phone(1,13,1,1,0);phone(1,14,0,0,0);
  // GET and non-UI SET are read/query or independent fields; don't swallow keys.
  phone(1,12,0,0,0);level(1);
  fork phone(0,12,0,1,0); release_at_commit(0); join
  if(dut.ui_page!=1)$fatal(1,"GET swallowed release or stale readback");
  phone(1,12,0,0,0);level(8);oldsong=dut.ui_song;oldcoll=collisions;
  fork phone(1,3,2,2,0); release_at_commit(0); join
  if(collisions!=oldcoll+1 || dut.ui_song!==((oldsong==2)?2'd0:oldsong+2'd1))
   $fatal(1,"unrelated FX SET swallowed song select");
  // Adjacent edges: release before SET commits once; release after SET cancels.
  for(i=-1;i<=1;i=i+2)begin
   phone(1,12,0,0,0);level(4);oldrestart=restarts;
   fork phone(1,12,3,3,0); release_at_commit(i); join
   if(dut.ui_page!=3 || restarts!=oldrestart+(i==1?1:0))$fatal(1,"adjacent release ordering offset=%0d",i);
  end
  $display("FOURPHONE_CHECKPOINT GPIO_UART_same_cycle collisions=%0d",collisions);
  // The new panel deliberately has NO diagnostic entry binding. Injection is
  // solely to exercise the real existing engine's ownership and Panic handoff.
  level(1);remember;
  force dut.ui_test_keys=16'h5000;
  age=0;while(!dut.test_owned && age<3000)begin clocks(1);age=age+1;end
  if(!dut.test_owned)$fatal(1,"diagnostic seam did not enter real engine");
  force dut.ui_test_keys=16'd0;
  level(0);unchanged("ownership entry pending key");
  for(k=0;k<4;k=k+1)begin level(4'b1<<k);level(0);unchanged("owned key");end
  phone(1,12,2,2,0);phone(0,12,0,2,0);
  phone(1,2,1,1,0);phone(1,13,0,0,0);
  phone(1,1,1,0,0); // Audio suppresses timbre while owned: ACK must NOT echo 1.
  level(8);oldsong=dut.ui_song;
  phone(2,0,0,dut.volume,0);
  age=0;while(dut.test_owned && age<250000)begin clocks(1);age=age+1;end
  if(dut.test_owned || dut.test_mode)$fatal(1,"phone Panic did not exit diagnostic");
  release dut.ui_test_keys;clocks(SETTLE*2);level(0);
  if(dut.ui_song!==oldsong || dut.ui_page!=2)$fatal(1,"held key fired on ownership exit");
  click(3);if(dut.ui_song!==((oldsong==2)?2'd0:oldsong+2'd1))$fatal(1,"ownership exit never rearmed");
  phone(1,1,1,1,0);phone(0,1,0,1,0);
  if(dut.ui_test_keys!==0)$fatal(1,"diagnostic injection failed to release");
  $display("FOURPHONE_ARBITRATION_PASS debounce=%0d checks=%0d same_edge=%0d startup=1 chords=1 song=1 done=1 readback=1 ownership=1",DB,checks,collisions);
  $finish;
 end
 initial begin #120000000;$fatal(1,"fourphone arbitration watchdog");end
endmodule
