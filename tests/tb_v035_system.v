`timescale 1ns/1ps
// Real top, button GPIO, serial MIDI/phone, ADS I2C and 32-slot RAM synth.
// Only HDMI is passive. ADC wait/button/phone/MIDI ratios are parameter-scaled;
// audio still runs its actual 288-clock frames. Never force internal DUT state.
`include "hdmi_display_stub.vh"
module tb_v035_system;
 parameter CASE=0; // 0 lifecycle/spectrum; 1 expression HUD; 2 timeout/Panic.
 localparam DB=4,HOLD=80,BC=64,PBC=32;
 reg clk=0;always #18.518 clk=~clk;
 reg [3:0] buttons_n=4'b1011; // cold boot while physical key 3 is held.
 reg midi_rx=1,phone_rx=1;
 tri1 scl,sda;wire phone_tx;
 reg [63:0] analog_values={16'd23000,16'd17000,16'd900,16'd800};
 top #(.BUTTON_DEBOUNCE_CYCLES(DB),.BUTTON_LONG_PRESS_CYCLES(HOLD),
  .TEST_RAMP_DIV(1),.TEST_MAX_SAMPLES(CASE==2?768:32768),
  .TEST_SWEEP_HALF_SAMPLES(4),.GUIDE_BEAT_SAMPLES(67),.TOUCH_ENABLE(0)) dut(
  .clk(clk),.ui_buttons_n(buttons_n),.uart_rx(1'b1),.midi_rx(midi_rx),
  .phone_uart_rx(phone_rx),.phone_uart_tx(phone_tx),.optical_beams(2'b11),
  .adc_scl(scl),.adc_sda(sda));
 mock_ads1115 adc_model(.rst(dut.rst_n),.analog_values(analog_values),.scl(scl),.sda(sda));
 defparam dut.u_audio.input_hub.adc.I2C_QUARTER=2;
 defparam dut.u_audio.input_hub.adc.CONVERT_CYCLES=16;
 defparam dut.u_audio.input_hub.adc.RETRY_CYCLES=128;
 defparam dut.u_audio.input_hub.adc.BYTE_TIMEOUT_CYCLES=10000;
 defparam dut.u_audio.input_hub.performance.midi_input.keyboard.CLK_HZ=BC*31250;
 defparam dut.u_phone.CLK_HZ=PBC*115200;
 wire [7:0] phone_byte_rx;wire phone_valid,phone_error;
 midi_uart_rx #(.CLK_HZ(PBC*115200),.BAUD(115200)) phone_monitor(
  .clk(clk),.rst_n(dut.rst_n),.rx(phone_tx),.data(phone_byte_rx),
  .data_valid(phone_valid),.framing_error(phone_error));
`define TC dut.u_audio.test_control
`define SY dut.u_audio.audio.synth
`define HUB dut.u_audio.input_hub.performance
 integer checks=0,cycles=0,ads_samples=0,ons=0,offs=0,handshakes=0;
 integer restarts=0,starts=0,toggles=0,clears=0,pcm_nonzero=0;
 integer received=0,seq=0,previous_tick_cycle=0,sweep_offs=0,sweep_ons=0;
 reg [7:0] replies[0:4095];
 reg [31:0] phase_seen=0;reg [23:0] phase_oracle[0:31];
 integer phase_visits[0:31];integer phase_total=0;
 reg previous_clear=0,previous_mode=0,previous_owned=0;
 reg [8:0] previous_gain=256;reg [11:0] previous_roll=0;
 reg [8:0] previous_events=0;
 reg capture=0;integer capture_count=0,pcm_file=0;reg [2047:0] pcm_path;
 reg [1:0] saved_page,saved_song;integer i,j,age,before_on,before_off,prior_restart;
 reg [31:0] expect_mask;reg [63:0] numerator;reg [23:0] expect_increment;
 integer slot,raw_latched=0;reg raw_handshake=0,old_tick;
 task automatic clocks(input integer n);repeat(n)@(negedge clk);endtask
 task automatic check(input condition,input [1023:0] text);begin
  checks=checks+1;if(condition!==1)$fatal(1,"%0s case=%0d state=%0d requested=%0d gate=%h busy=%h gain=%0d",text,CASE,`TC.state_debug,dut.test_requested,dut.test_gate,dut.test_busy,`TC.master_gain);
 end endtask
 task automatic samples(input integer n);integer k;begin
  for(k=0;k<n;k=k+1)begin @(posedge clk);while(!dut.sample_tick)@(posedge clk);@(negedge clk);end
 end endtask
 task automatic click(input integer key,input integer duration);begin
  buttons_n=~(4'b1<<key);clocks(duration);buttons_n=15;clocks(40);
 end endtask
 task automatic active_wait;integer n;begin
  n=0;while(`TC.state_debug!=3 && n<170000)begin clocks(1);n=n+1;end
  check(n<170000,"test reaches ACTIVE through complete fades");clocks(20);
 end endtask
 task automatic normal_wait;integer n;begin
  n=0;while(dut.test_owned && n<170000)begin clocks(1);n=n+1;end
  check(n<170000 && !dut.test_mode && dut.test_gate==0 && dut.test_requested==0,"exit clears test mode/gates/request and returns ownership");clocks(40);
 end endtask
 task automatic enter_test;begin
  saved_page=dut.ui_page;saved_song=dut.ui_song;prior_restart=restarts;
  buttons_n=11;clocks(HOLD*3);
  check(!dut.test_owned && restarts==prior_restart,"long3 does not enter or restart before release");
  buttons_n=15;clocks(40);check(dut.test_owned,"long3 released requests test ownership");
  active_wait;
  check(dut.test_requested==32 && dut.test_gate==32'hffffffff && !dut.test_sweep,"entry defaults full32");
  check(dut.ui_page==saved_page && dut.ui_song==saved_song && restarts==prior_restart,"entry preserves menu/song and consumes short3");
 end endtask
 task automatic midi_byte(input [7:0] v);integer bit_no;begin
  @(negedge clk);midi_rx=0;clocks(BC);
  for(bit_no=0;bit_no<8;bit_no=bit_no+1)begin midi_rx=v[bit_no];clocks(BC);end
  midi_rx=1;clocks(BC);
 end endtask
 task automatic midi(input [7:0] s,n,v);begin midi_byte(s);midi_byte(n);midi_byte(v);clocks(160);end endtask
 task automatic phone_byte(input [7:0] v);integer bit_no;begin
  @(negedge clk);phone_rx=0;clocks(PBC);
  for(bit_no=0;bit_no<8;bit_no=bit_no+1)begin phone_rx=v[bit_no];clocks(PBC);end
  phone_rx=1;clocks(PBC);
 end endtask
 task automatic phone(input [7:0] cmd,p,v,expected);integer base,k,n;reg [7:0] crc;begin
  base=received;phone_byte(8'ha5);phone_byte(8'h5a);phone_byte(1);phone_byte(seq);
  phone_byte(cmd);phone_byte(p);phone_byte(v);repeat(4)phone_byte(0);phone_byte(1^seq^cmd^p^v);
  n=0;while(received<base+12 && n<5000)begin clocks(1);n=n+1;end
  check(received==base+12,"real UART exactly one ACK");
  check(replies[base]==8'h5a && replies[base+1]==8'ha5 && replies[base+2]==1 && replies[base+3]==seq && replies[base+4]==0 && replies[base+5]==p && replies[base+6]==expected,"actual phone protocol ACK payload");
  crc=0;for(k=2;k<11;k=k+1)crc=crc^replies[base+k];check(replies[base+11]==crc,"phone ACK checksum");
  seq=(seq+1)&255;clocks(40);
 end endtask
 task automatic adc_pairs(input integer pairs);integer target,n;begin
  target=ads_samples+pairs*2;n=0;
  while(ads_samples<target && n<500000)begin clocks(1);n=n+1;end
  check(ads_samples>=target,"real ADS1115 I2C polling progress");clocks(4);
 end endtask
 task automatic midi_recovers(input [6:0] note_no);begin
  midi(8'h80,note_no,0);before_on=ons;before_off=offs;
  midi(8'h90,note_no,100);samples(100);
  check(ons==before_on+1 && dut.u_audio.audio.gate!=0 && dut.busy!=0,"exit recovers real MIDI note-on and real synth");
  midi(8'h80,note_no,0);check(offs==before_off+1 && dut.u_audio.audio.gate==0 && `HUB.held==0,"real MIDI note-off clears gate/held without stuck note");
 end endtask
 always @(posedge clk)begin
  cycles=cycles+1;old_tick=dut.sample_tick;
  raw_handshake=dut.rst_n && `HUB.m_valid && `HUB.m_ready && `HUB.m_on && !`HUB.ext_suppress;
  if(raw_handshake)begin raw_latched=`HUB.m_velocity>>1;handshakes=handshakes+1;end
  if(dut.rst_n)begin
   if(dut.u_audio.input_hub.hw_adc_valid)begin
    ads_samples=ads_samples+1;if(dut.u_audio.input_hub.hw_adc_channel>1)$fatal(1,"Removed MCP/slider channel polled");
   end
   if(phone_error)$fatal(1,"phone UART response framing");
   if(phone_valid)begin if(received>=4096)$fatal(1,"ACK buffer overflow");replies[received]=phone_byte_rx;received=received+1;end
   if(dut.u_audio.note_on)ons=ons+1;if(dut.u_audio.note_off)offs=offs+1;
   if(`HUB.m_error || `HUB.m_overflow)$fatal(1,"MIDI parser framing or overflow");
   if(dut.u_audio.overrun)$fatal(1,"synth exceeded real288-clock frame budget");
   if(dut.sample_tick)begin
    if(previous_tick_cycle!=0 && cycles-previous_tick_cycle!=288)$fatal(1,"audio sample clock interrupted by test/reset");
    previous_tick_cycle=cycles;
    if((^dut.pcm)===1'bx)$fatal(1,"unknown final PCM");
    if(dut.pcm!=0)pcm_nonzero=pcm_nonzero+1;
    if(capture)begin $fdisplay(pcm_file,"%0d",$signed(dut.pcm));capture_count=capture_count+1;end
   end
   if(!dut.u_audio.audio.audio_rst_n)phase_seen=0;
   else if(`SY.phase_ram.write_enable && `SY.test_frame)begin
    slot=`SY.voice_index;numerator=400+97*slot;numerator=numerator*16777216+46875;expect_increment=numerator/93750;
    if(`SY.selected_increment!==expect_increment)$fatal(1,"wrong actual selected DDS increment voice=%0d got=%0d expected=%0d",slot,`SY.selected_increment,expect_increment);
    if(phase_seen[slot] && `SY.current_phase!==phase_oracle[slot])$fatal(1,"phase RAM cross-voice/prefetch identity voice=%0d",slot);
    if(!phase_seen[slot] && `SY.current_phase!==0)$fatal(1,"phase-valid mask failed clear on mode boundary");
    phase_oracle[slot]=`SY.current_phase+expect_increment;phase_seen[slot]=1;phase_visits[slot]=phase_visits[slot]+1;phase_total=phase_total+1;
   end
  end
  #1;
  if(dut.rst_n)begin
   if(dut.u_display.test_active!==dut.test_owned || dut.u_display.test_requested!==dut.test_requested || dut.u_display.test_gate!==dut.test_gate || dut.u_display.test_busy!==dut.test_busy || dut.u_display.test_sweep!==dut.test_sweep || dut.u_display.test_index!==dut.test_index)$fatal(1,"HDMI test boundary mismatches real audio ownership/request/gate/busy/sweep/index");
   if(dut.u_display.expression_adc!==dut.adc_values[31:0] || dut.u_display.expression_calibrated!==dut.pressure_calibrated || dut.u_display.pressure0!==dut.expression0 || dut.u_display.pressure1!==dut.expression1)$fatal(1,"HUD raw/calibrated/processed FSR wiring");
   if(dut.u_display.midi_velocity!==dut.midi_velocity || dut.u_display.midi_bend!==dut.midi_bend || dut.u_display.midi_modulation!==dut.midi_modulation)$fatal(1,"HUD MIDI expression wiring");
   if(raw_handshake && dut.u_display.midi_velocity!==raw_latched)$fatal(1,"raw MIDI velocity not latched on real valid/ready handshake");
   if(dut.midi_velocity>127 || dut.midi_modulation>127)$fatal(1,"MIDI HUD range exceeded0..127");
   if(`TC.master_gain>256)$fatal(1,"test fade gain range");
   if(previous_clear && `TC.clear_audio)$fatal(1,"clear_audio lasted longer than one clock");
   if(`TC.clear_audio)begin clears=clears+1;if(`TC.master_gain!=0)$fatal(1,"audio cleared away from zero-gain boundary");end
   if(previous_mode!=dut.test_mode && !`TC.clear_audio)$fatal(1,"mode changed without zero-gain clear");
   if(previous_gain!=`TC.master_gain && (!old_tick || ((previous_gain>`TC.master_gain)?previous_gain-`TC.master_gain:`TC.master_gain-previous_gain)!=1))$fatal(1,"fade skipped a step or changed outside sample enable");
   if(previous_owned && dut.test_owned && dut.roll_tick!=previous_roll)$fatal(1,"teaching advances under test ownership");
   if(({dut.ui_start,dut.ui_toggle,dut.ui_restart,dut.panel_timbre_cycle,dut.panel_mode_cycle,dut.panel_test_toggle,dut.panel_test_count_cycle,dut.panel_test_sweep_toggle,dut.panel_test_full}&previous_events)!=0)$fatal(1,"panel command wider than one clock");
   if(dut.ui_restart)restarts=restarts+1;if(dut.ui_start)starts=starts+1;if(dut.ui_toggle)toggles=toggles+1;
   previous_events={dut.ui_start,dut.ui_toggle,dut.ui_restart,dut.panel_timbre_cycle,dut.panel_mode_cycle,dut.panel_test_toggle,dut.panel_test_count_cycle,dut.panel_test_sweep_toggle,dut.panel_test_full};
   previous_clear=`TC.clear_audio;previous_gain=`TC.master_gain;previous_mode=dut.test_mode;previous_owned=dut.test_owned;previous_roll=dut.roll_tick;
  end
 end
 initial begin
  for(i=0;i<32;i=i+1)begin phase_visits[i]=0;phase_oracle[i]=0;end
  clocks(120);check(!dut.rst_n && !dut.test_owned && !dut.test_mode && dut.test_gate==0,"configuration POR reset holds clean audio/test state");
  clocks(500);check(dut.rst_n && !dut.test_owned && restarts==0,"boot-held long3 cannot enter/restart");
  buttons_n=15;clocks(80);check(!dut.test_owned && restarts==0,"boot-held release is discarded");
  check(dut.u_display.expression_adc==0 || dut.pressure_calibrated==0,"FSR begins uncalibrated, no fabricated pressure");
  if(CASE==1)begin
   adc_pairs(24);check(dut.pressure_calibrated==3 && !dut.flags[3],"both FSR channels calibrate with actual I2C and no MCP");
   check(dut.u_display.expression_adc=={16'd900,16'd800} && dut.expression0==0 && dut.expression1==0,"separate A0/A1 raw codes, low16=A0 high16=A1");
   analog_values[15:0]=4896;adc_pairs(24);
   check(dut.u_display.expression_adc=={16'd900,16'd4896} && dut.expression0>=240 && dut.expression1==0,"only FSR0 increases brightness, raw and level stay distinct");
   analog_values[31:16]=2948;adc_pairs(24);
   check(dut.u_display.expression_adc=={16'd2948,16'd4896} && dut.expression0>=240 && dut.expression1>=120 && dut.pressure_calibrated==3,"FSR1 independent damping value and calibration displayed");
   analog_values[15:0]=800;adc_pairs(24);check(dut.expression0==0 && dut.expression1>=120,"FSR0 release does not clear FSR1");
   analog_values[31:16]=900;adc_pairs(24);check(dut.expression0==0 && dut.expression1==0,"both FSR levels return to zero on release");
   check(dut.adc_values[63:32]==0,"unused slider/MCP ADC values never published");
   midi(8'h90,60,40);check(dut.u_display.midi_velocity==40 && ons==1 && handshakes==1,"real velocity40 displayed as raw7bit");
   midi(8'h80,60,0);check(dut.u_display.midi_velocity==40,"note-off does not masquerade as new strike velocity");
   midi(8'h90,64,100);check(dut.u_display.midi_velocity==100 && ons==2 && handshakes==2,"real velocity100 not expanded200 on HUD");
   midi(8'he0,0,0);check($signed(dut.u_display.midi_bend)==-256,"negative bend HUD uses signed9bit");
   midi(8'he0,127,127);check($signed(dut.u_display.midi_bend)==255,"positive bend HUD uses signed9bit");
   midi(8'he0,0,64);check(dut.u_display.midi_bend==0,"bend centre HUD zero");
   midi(8'hb0,1,127);check(dut.u_display.midi_modulation==127,"CC1 max127 transmitted to HUD");
   midi(8'hb0,1,0);check(dut.u_display.midi_modulation==0,"CC1 zero transmitted to HUD");
   midi(8'h80,64,0);midi(8'h90,67,127);check(dut.u_display.midi_velocity==127,"velocity127 boundary retained");
   midi(8'h90,67,0);check(dut.u_audio.audio.gate==0 && dut.u_display.midi_velocity==127,"zero-velocity NoteOn is release, no false velocity0 strike");
   samples(100);check(pcm_nonzero>0 && dut.u_display.expression_calibrated==3,"real synth and FSR return values coexist");
  end else if(CASE==0)begin
   click(2,20);check(restarts==1 && !dut.test_owned && dut.guide_active,"ordinary short3 remains restart");
   buttons_n=10;clocks(HOLD*3);buttons_n=15;clocks(40);
   check(!dut.test_owned && restarts==1,"multi-key long gesture cannot enter test or restart");
   click(3,20);click(0,20);saved_page=dut.ui_page;saved_song=dut.ui_song;
   click(2,20);samples(4);
   check(dut.ui_page==0 && dut.guide_active && dut.roll_tick>0,"LIVE teaching advances before ownership alone pauses it");
   enter_test;samples(100);
   check(dut.test_busy==32'hffffffff && dut.u_display.voices==32,"all32 actual audible voices and telemetry, not only requested counter");
   if(!$value$plusargs("PCM_PATH=%s",pcm_path))pcm_path="v035_pcm.csv";
   pcm_file=$fopen(pcm_path,"w");check(pcm_file!=0,"open live final PCM capture");capture=1;
   samples(4096);capture=0;$fclose(pcm_file);
   check(capture_count==4096 && pcm_nonzero>4000,"capture4096 final PCM samples from live32 path");
   for(i=0;i<32;i=i+1)check(phase_visits[i]>=4096,"each independently indexed frequency consumes phase RAM every frame");
   for(j=0;j<5;j=j+1)begin
    click(0,20);case(j)0:expect_mask=1;1:expect_mask=15;2:expect_mask=255;3:expect_mask=65535;default:expect_mask=32'hffffffff;endcase
    check(dut.test_gate==expect_mask && dut.test_requested==(j==0?1:j==1?4:j==2?8:j==3?16:32),"short1 cycles32-1-4-8-16-32 actual gates");
    if(j==0)check(dut.test_busy==32'hffffffff,"busy retains release tails while requested/gate becomes1");
   end
   check(dut.ui_page==saved_page && dut.ui_song==saved_song,"test count controls never leak to page/song");
   click(1,20);check(dut.test_sweep && dut.test_requested==32 && dut.test_index==0,"short2 begins sequential OFF/ON");
   for(j=0;j<32;j=j+1)begin
    age=0;while(!(dut.test_sweep && dut.test_index==j && dut.test_gate==~(32'b1<<j)) && age<3000)begin clocks(1);age=age+1;end
    check(age<3000,"sequential voice OFF observed");sweep_offs=sweep_offs+1;
    age=0;while(!(dut.test_sweep && dut.test_index==j && dut.test_gate==32'hffffffff) && age<3000)begin clocks(1);age=age+1;end
    check(age<3000,"sequential voice ON observed");sweep_ons=sweep_ons+1;
   end
   samples(5);check(!dut.test_sweep && dut.test_index==31 && dut.test_gate==32'hffffffff,"full32 OFF/ON completes without index wrap");
   click(1,20);samples(12);click(1,20);check(!dut.test_sweep && dut.test_requested==32 && dut.test_gate==32'hffffffff,"second short2 stops sweep into full32");
   click(0,20);check(dut.test_requested==1,"count1 before direct full32");click(3,20);
   check(dut.test_requested==32 && dut.test_gate==32'hffffffff && dut.ui_song==saved_song,"short4 full32 without changing song");
   before_on=ons;midi(8'h90,65,100);check(ons==before_on && `HUB.held==0,"MIDI pressed under test suppressed, no pending stuck note");
   click(2,20);normal_wait;check(dut.ui_page==saved_page && dut.ui_song==saved_song,"short3 exit preserves page/song");
   check(dut.u_audio.audio.gate==0,"test-held MIDI cannot auto-sound on exit");
   before_on=ons;midi(8'h90,65,100);
   check(ons==before_on && dut.u_audio.audio.gate==0,"test-held key stays blocked until physical NoteOff then new NoteOn");midi_recovers(65);
   enter_test;click(2,20);normal_wait;midi_recovers(69);
   // Abort a fresh request during the normal fade-out: no test sine may start.
   prior_restart=restarts;click(2,HOLD*3);check(dut.test_owned && !dut.test_mode,"early entry is still normal-audio fade-out");
   click(2,20);normal_wait;check(restarts==prior_restart && dut.test_busy==0,"early short3 safely cancels entry without leaking restart");
  end else if(CASE==2)begin
   enter_test;
   age=0;while(dut.test_owned && age<400000)begin clocks(1);age=age+1;end
   check(age<400000 && !dut.test_mode && dut.test_gate==0,"idle timeout uses safe fade and returns normal");clocks(40);midi_recovers(60);
   enter_test;before_on=ons;midi(8'h90,67,100);check(ons==before_on,"Panic scenario key held during test blocked");
   phone(2,0,0,160);normal_wait;
   check(dut.pcm==0 && dut.u_audio.audio.gate==0 && dut.test_gate==0,"phone Panic clears test and audio, no re-gating");
   midi_recovers(67);
   enter_test;midi(8'hb0,120,0);normal_wait;
   check(dut.u_audio.audio.gate==0 && dut.test_gate==0,"MIDI CC120 Panic also aborts test");midi_recovers(72);
  end
  check(!dut.u_audio.overrun,"no synth overrun");
  $display("V035_SYSTEM_PASS case=%0d checks=%0d ADS=%0d MIDI_on=%0d off=%0d handshakes=%0d phase_updates=%0d PCM=%0d capture=%0d sweep_OFF=%0d ON=%0d clears=%0d reset=coldPOR hardware=0",CASE,checks,ads_samples,ons,offs,handshakes,phase_total,pcm_nonzero,capture_count,sweep_offs,sweep_ons,clears);
  $finish;
 end
 initial begin #500000000;$fatal(1,"V035 system watchdog case=%0d",CASE);end
`undef TC
`undef SY
`undef HUB
endmodule
