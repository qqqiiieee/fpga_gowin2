`timescale 1ns/1ps
module tb_state_ram;
 parameter LIVE=1;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,fs_tick=0,test_mode=0;
 reg[31:0]gate=0,retrigger=0;
 reg[223:0]notes=0;reg[255:0]vel=0;reg[31:0]timbres=0;
 reg signed[8:0]pitch=0;
 reg[7:0]attack=0,decay=0,sustain=200,release_ctrl=0,damping=0;
 wire[15:0]pcm[0:2],m0[0:2],m1[0:2];wire[2:0]done,overrun;
 wire[31:0]busy[0:2],audible[0:2];
 wavetable_synth_reference #(.TIMBRE_BITS(1),.NUM_TIMBRES(2),.DUAL_PROFILE(1),.COMPACT_ROM(1),.PACKED_FILE("src/timbre_dual_half.hex"),.PHASE_RAM(1),.LIVE_ADSR_ENABLE(LIVE),.VISUAL_MONITOR_ENABLE(1)) ref_dut(
 .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(test_mode),.gate(gate),.retrigger(retrigger),.note_bus(notes),.vel_bus(vel),.timbre_bus(timbres),.pitch(pitch),.sample(pcm[0]),.frame_done(done[0]),.overrun(overrun[0]),.voice_busy(busy[0]),.voice_audible(audible[0]),.attack_ctrl(attack),.decay_ctrl(decay),.sustain_ctrl(sustain),.release_ctrl(release_ctrl),.damping(damping),.monitor_voice0(m0[0]),.monitor_voice1(m1[0]));
 for(genvar n=1;n<=2;n=n+1)begin:g
 wavetable_synth #(.TIMBRE_BITS(1),.NUM_TIMBRES(2),.DUAL_PROFILE(1),.COMPACT_ROM(1),.PACKED_FILE("src/timbre_dual_half.hex"),.PHASE_RAM(1),.STATE_RAM(n-1),.LIVE_ADSR_ENABLE(LIVE),.VISUAL_MONITOR_ENABLE(1)) dut(
 .clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),.test_mode(test_mode),.gate(gate),.retrigger(retrigger),.note_bus(notes),.vel_bus(vel),.timbre_bus(timbres),.pitch(pitch),.sample(pcm[n]),.frame_done(done[n]),.overrun(overrun[n]),.voice_busy(busy[n]),.voice_audible(audible[n]),.attack_ctrl(attack),.decay_ctrl(decay),.sustain_ctrl(sustain),.release_ctrl(release_ctrl),.damping(damping),.monitor_voice0(m0[n]),.monitor_voice1(m1[n]));
 end
 integer cycles=0,frames=0,nonzero=0,checks=0,seed=32'h5132041,i,f,c,interval;
 always @(posedge clk)begin
  #1;cycles=cycles+1;
  if(rst_n)begin
   for(integer k=1;k<=2;k=k+1)begin
    checks=checks+1;
    if({pcm[k],done[k],overrun[k],busy[k],audible[k],m0[k],m1[k]}!=={pcm[0],done[0],overrun[0],busy[0],audible[0],m0[0],m1[0]})
      $fatal(1,"STATE_RAM_MISMATCH live=%0d dut=%0d cycle=%0d frame=%0d pcm=%h/%h flags=%h/%h",LIVE,k,cycles,frames,pcm[k],pcm[0],busy[k],busy[0]);
   end
   if(done[0])begin frames=frames+1;if(pcm[0]!=0)nonzero=nonzero+1;end
  end
 end
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  for(i=0;i<32;i=i+1)begin notes[i*7+:7]=41+i;vel[i*8+:8]=192;timbres[i]=i%2;end
  // Directed 32-voice attack, decay/sustain, release, pressure, test mode; then
  // seeded asynchronous edits, resets and early frame ticks stress RAM validity.
  for(f=0;f<1800;f=f+1)begin
   if(f==0)gate=32'hffffffff;
   if(f==160)gate=0;
   if(f==400)begin gate=32'hffffffff;attack=30;release_ctrl=10;end
   if(f==500)damping=80;
   if(f==550)damping=0;
   if(f==600)test_mode=1;
   if(f==750)begin test_mode=0;attack=0;decay=0;release_ctrl=0;end
   if(f>=800)begin
    gate=$random(seed);pitch=$random(seed);sustain=$random(seed);
    timbres=$random(seed);damping=(f%4==0)?$random(seed):0;
    for(i=0;i<32;i=i+1)begin notes[i*7+:7]=($random(seed)&127);vel[i*8+:8]=$random(seed);end
    if(f%51==0)test_mode=~test_mode;
   end
   interval=(f>=1500 && f%3==0)?(1+(f%256)):288;
   fs_tick=1;@(negedge clk);fs_tick=0;
   for(c=1;c<interval;c=c+1)begin
    retrigger=(f>=800 && c%17==0)?$random(seed):0;
    if(f>=800 && c==123)gate=$random(seed);
    if(f%199==198 && c==111)rst_n=0;
    if(f%199==198 && c==114)rst_n=1;
    @(negedge clk);
   end
  end
  if(frames<1200 || nonzero<500)$fatal(1,"INSUFFICIENT_ACTIVITY");
  $display("STATE_RAM_EQUIVALENCE_PASS live=%0d cycles=%0d checks=%0d frames=%0d nonzero=%0d",LIVE,cycles,checks,frames,nonzero);$finish;
 end
endmodule
