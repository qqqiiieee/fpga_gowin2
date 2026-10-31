`timescale 1ns/1ps
// Compare every audio/output cycle against the archived V035 synthesizer.
// Independently enumerate its valid samples to verify voice0/1 tap alignment.
module tb_v036_audio_taps;
 reg clk=0,rst_n=0,tick=0,test_mode=0;always #5 clk=~clk;
 reg [31:0] gate=0,retrigger=0;
 reg [223:0] notes=0;reg [255:0] velocities=0;reg [31:0] timbres=0;
 reg signed [8:0] pitch=0;
 wire [15:0] pcm,ref_pcm;wire done,ref_done,overrun,ref_overrun;
 wire [31:0] busy,ref_busy,audible,ref_audible;
 wire signed [15:0] tap0,tap1;
`define PARAMS .NUM_VOICES(32),.COMPACT_ROM(1),.PACKED_FILE("src/timbre_dual_half.hex"), \
 .TIMBRE_BITS(1),.NUM_TIMBRES(2),.DUAL_PROFILE(1),.PHASE_RAM(1),.LIVE_ADSR_ENABLE(1)
`define PORTS .clk(clk),.rst_n(rst_n),.fs_tick(tick),.test_mode(test_mode), \
 .gate(gate),.retrigger(retrigger),.note_bus(notes),.vel_bus(velocities),.timbre_bus(timbres), \
 .pitch(pitch),.attack_ctrl(8'd0),.decay_ctrl(8'd64),.sustain_ctrl(8'd192), \
 .release_ctrl(8'd48),.damping(8'd0)
 wavetable_synth #(`PARAMS,.VISUAL_MONITOR_ENABLE(1)) dut(`PORTS,
  .sample(pcm),.frame_done(done),.overrun(overrun),.voice_busy(busy),.voice_audible(audible),
  .monitor_voice0(tap0),.monitor_voice1(tap1));
 wavetable_synth_v035_reference #(`PARAMS) reference(`PORTS,
  .sample(ref_pcm),.frame_done(ref_done),.overrun(ref_overrun),.voice_busy(ref_busy),.voice_audible(ref_audible));
`undef PARAMS
`undef PORTS
 integer clocks=0,frames=0,ordinal=0,tapchecks=0,xy_nonzero=0,i,f;
 reg signed [15:0] expected0=0,expected1=0;
 reg ref_valid;reg signed[15:0] ref_value;
 always @(posedge clk)begin
  ref_valid=reference.v3;ref_value=reference.sample3;
  if(!rst_n)begin ordinal=0;expected0=0;expected1=0;end
  else begin
   if(tick)ordinal=0;
   if(ref_valid)begin
    if(ordinal==0)expected0=ref_value;
    if(ordinal==1)expected1=ref_value;
    ordinal=ordinal+1;
   end
  end
  #1;
  if(rst_n)begin
   clocks=clocks+1;
   if({pcm,done,overrun,busy,audible} !== {ref_pcm,ref_done,ref_overrun,ref_busy,ref_audible})
    $fatal(1,"Audio differs from V035 atclock%0d",clocks);
   if(tap0!==expected0 || tap1!==expected1)$fatal(1,"Tap sample/tag alignment error");
   if(ref_valid)tapchecks=tapchecks+1;
   if(done)begin frames=frames+1;if(tap0!=0&&tap1!=0&&tap0!=tap1)xy_nonzero=xy_nonzero+1;end
   if(overrun)$fatal(1,"Audio frame overrun");
  end
 end
 task frame;
  begin
   @(negedge clk);tick=1;@(negedge clk);tick=0;
   repeat(287)@(negedge clk);
  end
 endtask
 initial begin
  for(i=0;i<32;i=i+1)begin notes[i*7+:7]=41+i;velocities[i*8+:8]=192;timbres[i]=i[0];end
  repeat(4)@(negedge clk);rst_n=1;
  for(f=0;f<512;f=f+1)begin
   case(f)
    0:gate=3;
    80:begin pitch=-137;gate=32'h80000003;end
    160:begin gate=0;pitch=255;end
    220:begin test_mode=1;gate=32'hffffffff;pitch=0;end
    380:gate=32'hfffffeff;
    420:begin test_mode=0;gate=3;end
    470:gate=0;
    default:;
   endcase
   frame;
  end
  repeat(300)@(negedge clk);
  if(frames!=512 || tapchecks<16000 || xy_nonzero<200)$fatal(1,"Insufficient coverage frames%0d checks%0d xy%0d",frames,tapchecks,xy_nonzero);
  $display("V036_AUDIO_TAPS_PASS clocks=%0d frames=%0d taps=%0d independentXY=%0d exactV035=1",clocks,frames,tapchecks,xy_nonzero);
  $finish;
 end
 initial begin #10000000;$fatal(1,"tap miter timeout");end
endmodule
