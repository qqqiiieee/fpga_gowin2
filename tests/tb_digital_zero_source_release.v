`timescale 1ns/1ps
// Digital-zero integration regression: real MIDI bytes and beam transitions,
// local matrix-style one-cycle events, the real allocator/synth/PCM path.
// Only optical startup/filter and note hold are shortened. UART remains 864
// clocks/bit. PHASE_RAM=0 isolates this input fix from separate RAM validation.
module tb_digital_zero_source_release;
 reg clk=0,rst_n=0,zero=0,rx=1;
 always #5 clk=~clk;
 reg [1:0] beams=3;
 reg local_on=0,local_off=0;
 reg [6:0] local_note=60;
 reg [15:0] local_keys=0;
 wire evon,evoff,panic,tick,overrun;
 wire [6:0] note;
 wire [7:0] velocity,volume;
 wire [3:0] timbre;
 wire [1:0] source;
 wire signed [8:0] pitch;
 wire [15:0] pcm;
 wire [31:0] busy;
 wire legacy_on,legacy_off,legacy_panic;
 integer local_ons=0,midi_ons=0,optical_ons=0,panics=0;
 integer source0=0,source1=0,source2=0;
 integer before_local,before_midi,before_optical,nonzero_after=0;
 integer tick_count=0,zero_ticks=0,prezero_pcm=0;

 performance_input_hub #(.MIDI_ENABLE(1),.OPTICAL_ENABLE(1)) hub(
 .clk(clk),.rst_n(rst_n),.sample_tick(tick),.allow_performance(1'b1),.suppress_controls(1'b0),
 .remote_active(1'b0),.digital_zero(zero),.midi_rx(rx),.optical_beams(beams),
 .local_on(local_on),.local_off(local_off),.local_note(local_note),.local_velocity(8'd200),
 .local_timbre(4'd0),.selected_timbre(4'd0),.local_keys(local_keys),
 .physical_volume(8'd255),.physical_pitch(9'sd0),.note_on(evon),.note_off(evoff),
 .note(note),.velocity(velocity),.timbre(timbre),.event_source(source),
 .volume(volume),.pitch(pitch),.panic_audio(panic));
 defparam hub.optical_input.gesture.STARTUP_CYCLES=30;
 defparam hub.optical_input.gesture.FILTER_CYCLES=3;
 defparam hub.optical_input.player.HOLD_MS=1;

 instrument_audio #(.REDUCED_TIMBRES(1),.SOURCE_TAG_ENABLE(1),
 .TRANSITION_INPUT_ENABLE(1),.PHASE_RAM(0)) audio(
 .clk(clk),.rst_n(rst_n),.note_on(evon),.note_off(evoff),.note(note),
 .velocity(velocity),.timbre(timbre),.event_source(source),.slider_volume(volume),.slider_pitch(pitch),
 .hit0(1'b0),.hit1(1'b0),.velocity0(8'd0),.velocity1(8'd0),.digital_zero_test(zero),
 .filter_enable(1'b1),.test_owned(1'b0),.test_mode(1'b0),.test_clear(panic),
 .normal_input_ready(1'b1),.test_gate_mask(32'd0),.test_master_gain(9'd256),
 .monitor_tick(tick),.monitor_pcm(pcm),.monitor_busy(busy),.overrun(overrun));

 // Old independent callers disable both new inputs. Their local event and
 // zero-mask behavior must remain unchanged, with no new panic pulse.
 performance_input_hub legacy_hub(
 .clk(clk),.rst_n(rst_n),.sample_tick(tick),.allow_performance(1'b1),.suppress_controls(1'b0),
 .remote_active(1'b0),.digital_zero(zero),.midi_rx(1'b1),.optical_beams(2'b11),
 .local_on(local_on),.local_off(local_off),.local_note(local_note),.local_velocity(8'd200),
 .local_timbre(4'd0),.selected_timbre(4'd0),.local_keys(local_keys),
 .physical_volume(8'd255),.physical_pitch(9'sd0),
 .note_on(legacy_on),.note_off(legacy_off),.panic_audio(legacy_panic));

 always @(posedge clk) if(rst_n) begin
  if(panic)panics=panics+1;
  if(evon)case(source)
   0:local_ons=local_ons+1;
   1:midi_ons=midi_ons+1;
   2:optical_ons=optical_ons+1;
   default:$fatal(1,"invalid source tag");
  endcase
  if(legacy_on!==local_on || legacy_off!==local_off || legacy_panic!==0)
   $fatal(1,"digital zero changed legacy MIDI_ENABLE=OPTICAL_ENABLE=0 behavior");
  #1;
  if(overrun)$fatal(1,"audio overrun");
  if(zero && (evon || evoff || audio.gate!=0 || busy!=0 || pcm!=0))
   $fatal(1,"zero mode accepted event or retained sound state");
  if(tick)begin
   tick_count=tick_count+1;
   if(zero)zero_ticks=zero_ticks+1;
  end
 end

 task clocks;
 input integer count;
 begin repeat(count)@(negedge clk);end
 endtask
 task midi_byte;
 input [7:0] data;
 integer b;
 begin
  @(negedge clk);rx=0;clocks(864);
  for(b=0;b<8;b=b+1)begin rx=data[b];clocks(864);end
  rx=1;clocks(864);
 end
 endtask
 task midi_note;
 input [7:0] status,key,value;
 begin midi_byte(status);midi_byte(key);midi_byte(value);clocks(20);end
 endtask
 task local_event;
 input is_on;
 input [6:0] key;
 begin
  @(negedge clk);local_note=key;local_on=is_on;local_off=!is_on;
  @(negedge clk);local_on=0;local_off=0;
 end
 endtask
 task count_sources;
 integer k;
 begin
  source0=0;source1=0;source2=0;
  for(k=0;k<32;k=k+1)if(audio.u_alloc.gates[k])case(audio.u_alloc.sources[k])
   0:source0=source0+1;1:source1=source1+1;2:source2=source2+1;
  endcase
 end
 endtask
 task expect_silent;
 begin
  if(audio.gate!==0 || busy!==0 || pcm!==0 || hub.o_busy!==0)
   $fatal(1,"old input resumed gate=%h busy=%h pcm=%h strum=%0d",audio.gate,busy,pcm,hub.o_busy);
 end
 endtask

 initial begin
  clocks(5);rst_n=1;clocks(100);
  // Give MIDI a three-note chord, plus a local C4. The optical first C4
  // shares pitch with both sources while more strum notes remain pending.
  midi_note(8'h90,60,100);midi_note(8'h90,64,100);midi_note(8'h90,67,100);
  local_keys=1;local_event(1,60);
  beams=0;wait(optical_ons==1);@(negedge clk);
  repeat(10000)begin @(negedge clk);if(tick && pcm!=0)prezero_pcm=prezero_pcm+1;end
  count_sources;
  if(source0!=1 || source1!=3 || source2!=1 || prezero_pcm==0)
   $fatal(1,"setup needs all sources and nonzero PCM: %0d/%0d/%0d PCM=%0d",source0,source1,source2,prezero_pcm);
  before_local=local_ons;before_midi=midi_ons;before_optical=optical_ons;

  // A zero rising edge must clear every source exactly once. Local/MIDI
  // arrivals during zero must never create hidden gates behind the PCM mask.
  zero=1;clocks(10);expect_silent;
  if(panics!=1)$fatal(1,"zero rising edge must produce one global clear");
  local_event(1,69);local_event(0,69);
  midi_note(8'h90,72,100);
  clocks(1000);expect_silent;
  if(local_ons!=before_local || midi_ons!=before_midi || optical_ons!=before_optical)
   $fatal(1,"new on accepted during zero");
  if(zero_ticks<20)$fatal(1,"PT8211 sample cadence stopped in zero mode");

  // Keep beams blocked and local C4 held across exit: neither may replay.
  zero=0;
  repeat(300000)begin
   @(negedge clk);expect_silent;
   if(tick && pcm!=0)nonzero_after=nonzero_after+1;
  end
  if(local_ons!=before_local || midi_ons!=before_midi || optical_ons!=before_optical || panics!=1)
   $fatal(1,"zero exit replayed old input or produced extra panic");
  // MIDI keys held before/during suppression require release before rearm.
  midi_note(8'h90,60,100);midi_note(8'h90,72,100);expect_silent;
  if(midi_ons!=before_midi)$fatal(1,"held MIDI key bypassed release-to-rearm");
  midi_note(8'h80,60,0);midi_note(8'h90,60,100);
  count_sources;
  if(source1!=1 || source0!=0 || source2!=0)$fatal(1,"MIDI failed release/repress");

  // Local release does not cut MIDI's same-pitch C4; a new local press works.
  local_keys=0;local_event(0,60);clocks(2);count_sources;
  if(source1!=1 || source0!=0)$fatal(1,"local release cut MIDI C4");
  local_keys=1;local_event(1,60);clocks(2);count_sources;
  if(source0!=1 || source1!=1)$fatal(1,"local failed release/repress");

  // Beams must return idle, then a fresh gesture works. Its normal timed off
  // releases only source 2, preserving local and MIDI C4.
  beams=3;clocks(100);beams=0;
  wait(optical_ons==before_optical+1);@(negedge clk);beams=3;clocks(50000);
  count_sources;
  if(hub.o_busy || source2!=0 || source0!=1 || source1!=1)
   $fatal(1,"fresh strum failed rearm or its off cut another source");
  zero=1;clocks(10);expect_silent;
  if(panics!=2)$fatal(1,"second zero rising edge failed to clear");
  zero=0;clocks(1000);expect_silent;
  $display("DIGITAL_ZERO_SOURCE_RELEASE_TEST_PASS all_sources_clear=1 zero_rejects_local_MIDI=1 no_old_strum_replay=1 release_repress=1 source_isolation=1 legacy_default_unchanged=1 panic_edges=%0d zero_ticks=%0d nonzero_after=%0d",panics,zero_ticks,nonzero_after);
  $finish;
 end
 initial begin #12000000;$fatal(1,"DIGITAL_ZERO_SOURCE_RELEASE watchdog");end
endmodule
