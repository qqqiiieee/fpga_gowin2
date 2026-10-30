`timescale 1ns/1ps
module tb_song_rhythm;
 reg clk=0,rst_n=0,tick=0,pause=0;always #5 clk=~clk;
 reg [15:0] keys=0;wire [5:0] step;wire beat;integer beats=0;
 song_guide #(.BEAT_SAMPLES(10),.EXTERNAL_UI(1),.RHYTHM_ENABLE(1)) dut(
  .clk(clk),.rst_n(rst_n),.sample_tick(tick),.pause(pause),.keys(keys),.ghost(1'b0),
  .active(),.done(),.cue_mask(),.next_mask(),.wrong_mask(),.step_index(step),
  .total_steps(),.beat_progress(),.target_beats(),.song_id(2'd0),.ui_start(1'b0),
  .ui_toggle(1'b0),.ui_restart(1'b0),.beat_pulse(beat));
 always @(posedge clk)begin #1;if(beat)beats=beats+1;end
 task samples;input integer n;integer k;begin
  for(k=0;k<n;k=k+1)begin @(negedge clk);tick=1;@(negedge clk);tick=0;end
 end endtask
 integer saved;
 initial begin
  repeat(3)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
  samples(20);if(beats!=2)$fatal(1,"independent metronome needs no key");
  keys=1;samples(6);keys=0;repeat(3)@(negedge clk);
  if(step!=0)$fatal(1,"early release wrongly advanced song");
  keys=1;samples(9);keys=0;repeat(3)@(negedge clk);
  if(step!=1)$fatal(1,"duration-qualified note failed");
  saved=beats;pause=1;samples(30);if(beats!=saved)$fatal(1,"pause did not freeze metronome");
  $display("SONG_RHYTHM_TEST_PASS independent_beat=1 early_release_retry=1 duration_match=1 pause=1");$finish;
 end
endmodule
