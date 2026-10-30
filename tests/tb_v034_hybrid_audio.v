`timescale 1ns/1ps
// Full production input -> MIDI/optical arbitration -> real 32-slot allocator
// -> synth/audio gate path. MIDI is SERIAL 8N1 (ratio scaled to 64 clocks/bit).
// Only gesture/player and MIDI timing parameters are accelerated. No forced
// note, gate, mode-change panic, allocator state, or synthetic audio boundary.
module tb_v034_hybrid_audio;
 localparam BC=64;
 reg clk=0;always #18.518 clk=~clk;
 reg midi_rx=1;reg [1:0] mode=0,beams=3;
 tri1 scl,sda;wire rst_n,tick;wire [15:0] pcm;
 wire [31:0] busy;
 instrument_audio_top #(.MIDI_ENABLE(1),.OPTICAL_ENABLE(1),.DISPLAY_TOUCH_ONLY(1),
  .PHASE_RAM(1),.LIVE_ADSR_ENABLE(1),.EFFECTS_ENABLE(1),.PRESSURE_EXPRESSION_ENABLE(1)) dut(
  .clk(clk),.matrix_cols(4'hf),.adc_scl(scl),.adc_sda(sda),.uart_rx(1'b1),
  .touch_miso(1'b0),.midi_rx(midi_rx),.optical_beams(beams),
  .ui_test_keys(16'd0),.ui_panic(1'b0),.ui_strum_mode(mode),
  .ui_timbre_set_valid(1'b0),.ui_timbre_set_value(4'd0),.ui_filter_enable(1'b1),
  .ui_zero_mode(1'b0),.control_page(2'd2),.ui_fx_cycle(1'b0),
  .phone_set_valid(1'b0),.phone_param(8'd0),.phone_value(8'd0),.phone_query_param(8'd0),
  .monitor_rst_n(rst_n),.monitor_tick(tick),.monitor_pcm(pcm),.monitor_busy(busy));
 defparam dut.input_hub.performance.midi_input.keyboard.CLK_HZ=BC*31250;
 defparam dut.input_hub.performance.optical_input.gesture.CLK_HZ=27000;
 defparam dut.input_hub.performance.optical_input.gesture.FILTER_CYCLES=4;
 defparam dut.input_hub.performance.optical_input.gesture.STARTUP_CYCLES=64;
 defparam dut.input_hub.performance.optical_input.gesture.PAIR_WINDOW_CYCLES=512;
 defparam dut.input_hub.performance.optical_input.player.CLK_HZ=54000;
 integer checks=0,midi_ons=0,opt_ons=0,midi_offs=0,opt_offs=0,panics=0,pcm_nonzero=0;
 integer mo,oo,mf,of,pp,age,i;
 reg [6:0] opt_notes[0:63];
 always @(posedge clk)if(rst_n)begin
  if(dut.panic_audio)panics=panics+1;
  if(dut.overrun)$fatal(1,"synth overrun");
  if(dut.input_hub.performance.m_error || dut.input_hub.performance.m_overflow)$fatal(1,"MIDI framing/FIFO failure");
  if(dut.note_on || dut.note_off)begin
   if(dut.note_source==1)begin
    if(dut.note_on)midi_ons=midi_ons+1;if(dut.note_off)midi_offs=midi_offs+1;
    if(dut.timbre!==0)$fatal(1,"keyboard lost selected flute timbre");
   end else if(dut.note_source==2)begin
    if(dut.timbre!==1)$fatal(1,"optical event is not plucked");
    if(dut.note_on)begin
     if(opt_ons>=64)$fatal(1,"optical event buffer overflow");opt_notes[opt_ons]=dut.note;opt_ons=opt_ons+1;
    end
    if(dut.note_off)opt_offs=opt_offs+1;
   end else $fatal(1,"unexpected local note source");
  end
  if(tick)begin
   if((^pcm)===1'bx)$fatal(1,"PCM X");
   if(pcm!=0)pcm_nonzero=pcm_nonzero+1;
  end
 end
 task clocks(input integer n);repeat(n)@(negedge clk);endtask
 task check(input condition,input [1023:0] text);begin
  checks=checks+1;if(condition!==1)$fatal(1,"%0s mode=%0d MIDIon/off=%0d/%0d optical=%0d/%0d gate=%h",text,mode,midi_ons,midi_offs,opt_ons,opt_offs,dut.audio.gate);
 end endtask
 function integer gates_for(input integer src,n);
  integer k;begin gates_for=0;
   for(k=0;k<32;k=k+1)if(dut.audio.gate[k] && dut.audio.u_alloc.sources[k]==src && (n<0 || dut.audio.u_alloc.notes[k]==n))gates_for=gates_for+1;
  end
 endfunction
 task midi_byte(input [7:0] v);integer b;begin
  @(negedge clk);midi_rx=0;clocks(BC);
  for(b=0;b<8;b=b+1)begin midi_rx=v[b];clocks(BC);end midi_rx=1;clocks(BC);
 end endtask
 task midi(input [7:0] s,n,v);begin midi_byte(s);midi_byte(n);midi_byte(v);clocks(100);end endtask
 task gesture(input reverse);begin
  beams=reverse?2'b01:2'b10;clocks(50);beams=0;clocks(100);beams=3;clocks(800);
 end endtask
 task switch_mode(input [1:0] v);begin
  pp=panics;mode=v;clocks(20);
  check(panics==pp+1,"each changed mode emits one panic");
  check(dut.audio.gate==0 && !dut.input_hub.performance.o_busy,"mode panic clears all sources and optical queue");
 end endtask
 task wait_optical_end;begin
  age=0;while((dut.input_hub.performance.o_busy || gates_for(2,-1)!=0) && age<12000)begin clocks(1);age=age+1;end
  check(age<12000 && gates_for(2,-1)==0,"optical auto-release completes without stuck gate");
 end endtask
 initial begin
  clocks(1200);check(rst_n && !dut.test_owned,"normal ownership ready");
  // KEY only: live MIDI sounds, optical gesture must neither allocate nor panic.
  midi(8'h90,60,100);check(midi_ons==1 && gates_for(1,60)==1,"KEY accepts actual MIDI");
  oo=opt_ons;pp=panics;gesture(0);check(opt_ons==oo && gates_for(2,-1)==0 && panics==pp,"KEY suppresses optical only");
  midi(8'h80,60,0);check(gates_for(1,60)==0,"KEY releases MIDI");
  // STRUM only: physical MIDI contributes held chord but does not sound itself.
  switch_mode(1);mo=midi_ons;mf=midi_offs;
  midi(8'h90,60,100);midi(8'h90,64,100);midi(8'h90,67,100);
  check(midi_ons==mo && dut.audio.gate==0,"STRUM consumes MIDI note-ons without audio");
  check(dut.input_hub.performance.held==((128'b1<<60)|(128'b1<<64)|(128'b1<<67)),"STRUM keeps actual held chord");
  oo=opt_ons;gesture(0);
  check(opt_ons==oo+3 && opt_notes[oo]==60 && opt_notes[oo+1]==64 && opt_notes[oo+2]==67,"STRUM ascending selected chord/source2");
  check(gates_for(2,-1)==3 && gates_for(1,-1)==0,"STRUM allocates exactly optical source");
  wait_optical_end;
  midi(8'h80,60,0);midi(8'h80,64,0);midi(8'h80,67,0);
  check(midi_offs==mf && dut.input_hub.performance.held==0,"STRUM consumes MIDI release too");
  // HYBRID held triad allocates both independent sources with the same pitches.
  switch_mode(2);mo=midi_ons;oo=opt_ons;of=opt_offs;
  midi(8'h90,60,100);midi(8'h90,64,100);midi(8'h90,67,100);
  check(midi_ons==mo+3 && gates_for(1,-1)==3,"HYBRID direct keyboard route enabled");
  gesture(0);check(opt_ons==oo+3 && gates_for(2,-1)==3 && gates_for(1,-1)==3,"HYBRID six independent layered gates");
  for(i=0;i<3;i=i+1)begin
   check(opt_notes[oo+i]==(i==0?60:(i==1?64:67)),"HYBRID optical chord follows real held notes");
   check(gates_for(1,opt_notes[oo+i])==1 && gates_for(2,opt_notes[oo+i])==1,"same pitch has separate source1/source2 slots");
  end
  wait_optical_end;check(opt_offs==of+3 && gates_for(1,-1)==3,"optical offs cannot cut held same-pitch MIDI");
  clocks(10000);check(pcm_nonzero>0 && busy!=0,"real synthesizer produces finite nonzero PCM");
  // Reverse strum while the same MIDI triad still held. Releasing one MIDI key
  // during the optical hold must preserve its source2 voice and other two keys.
  oo=opt_ons;gesture(1);
  check(opt_ons==oo+3 && opt_notes[oo]==67 && opt_notes[oo+1]==64 && opt_notes[oo+2]==60,"HYBRID descending gesture");
  midi(8'h80,60,0);
  check(gates_for(1,60)==0 && gates_for(2,60)==1 && gates_for(1,64)==1 && gates_for(1,67)==1,"MIDI note-off cannot cut same-pitch optical gate");
  // Change mode with BOTH sources and an unfinished strum: old optical offs or
  // queued ons cannot reassert gates after panic. Keyboard remains usable.
  mo=midi_ons;oo=opt_ons;switch_mode(0);clocks(12000);
  check(dut.audio.gate==0 && opt_ons==oo && midi_ons==mo,"mode panic has no queued optical resurrection");
  midi(8'h80,64,0);midi(8'h80,67,0);midi(8'h90,72,100);
  check(gates_for(1,72)==1 && gates_for(2,-1)==0,"KEY recovers after hybrid panic");
  midi(8'h80,72,0);check(dut.audio.gate==0,"final release leaves no gates");
  $display("V034_HYBRID_AUDIO_PASS checks=%0d key_strum_hybrid=1 same_pitch_both_release_directions=1 mode_panic=1 MIDIons=%0d opticalons=%0d nonzeroPCM=%0d",checks,midi_ons,opt_ons,pcm_nonzero);$finish;
 end
 initial begin #20000000;$fatal(1,"V034 hybrid audio watchdog");end
endmodule
