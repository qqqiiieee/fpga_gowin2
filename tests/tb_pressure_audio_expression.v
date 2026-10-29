`timescale 1ns/1ps
// Independent offline tests. No force/deposit, replacement RTL, or DUT writes.
// The short clock accelerates simulation; frequency claims use production ticks.
module tb_pressure_audio_expression;
 reg clk=0; always #5 clk=~clk;
 reg rst_n=0,tick=0,quiet=0,enable=0,ready=1;
 reg [15:0] pcm=0,mirror_pcm=0;
 reg [7:0] pressure[0:2];
 wire [15:0] y[0:2],yn[0:2],legacy,bypass,lp0;
 genvar g;
 generate for(g=0;g<3;g=g+1)begin:filters
  audio_cleanup #(.EXPRESSION_ENABLE(1)) dut(.clk(clk),.rst_n(rst_n),.tick(tick),
   .quiet(quiet),.enable(enable),.sample_in(pcm),.sample_out(y[g]),
   .expression(pressure[g]),.expression_ready(ready));
  audio_cleanup #(.EXPRESSION_ENABLE(1)) negative(.clk(clk),.rst_n(rst_n),.tick(tick),
   .quiet(quiet),.enable(enable),.sample_in(mirror_pcm),.sample_out(yn[g]),
   .expression(pressure[g]),.expression_ready(ready));
 end endgenerate
 // Deliberately omit both new inputs for backward-compatibility/X testing.
 audio_cleanup old_default(.clk(clk),.rst_n(rst_n),.tick(tick),.quiet(quiet),
  .enable(enable),.sample_in(pcm),.sample_out(legacy));
 audio_cleanup #(.LOWPASS_ENABLE(0)) old_bypass(.clk(clk),.rst_n(rst_n),.tick(tick),
  .quiet(quiet),.enable(enable),.sample_in(pcm),.sample_out(bypass));
 audio_cleanup #(.LOWPASS_ENABLE(0),.EXPRESSION_ENABLE(1)) new_lp0(
  .clk(clk),.rst_n(rst_n),.tick(tick),.quiet(quiet),.enable(enable),.sample_in(pcm),
  .sample_out(lp0),.expression(pressure[0]),.expression_ready(ready));
 longint signed state[0:2],negative_state[0:2],legacy_state,d,inc,next_q;
 integer alpha[0:2],divider=0,total=0,i,j,goal,expected,old_expected;
 integer previous[0:2],lower,upper,inverse_value,fd,seed=32'h5632a19d;
 reg [15:0] low_sine[0:9374],high_sine[0:9374];
 reg [15:0] saved[0:2];
 function automatic longint signed update_q;
  input longint signed old_q; input integer value,coefficient;
  longint signed delta,product,step;
  begin
   delta=256*value-old_q;product=delta*coefficient;step=product/256;
   if(step==0 && delta!=0)step=(delta<0)?-1:1;
   update_q=old_q+step;
  end
 endfunction
 task reset_all;
  begin
   @(negedge clk);rst_n=0;tick=0;quiet=0;
   repeat(3)@(negedge clk);
   rst_n=1;divider=0;legacy_state=0;
   for(j=0;j<3;j=j+1)begin state[j]=0;negative_state[j]=0;alpha[j]=128;end
  end
 endtask
 task sample;
  input signed [15:0] value;
  begin
   inverse_value=(value == -32768)?32767:-value;
   @(negedge clk);tick=1;pcm=value;mirror_pcm=inverse_value;
   @(posedge clk);#1;
   total=total+1;
   legacy_state=update_q(legacy_state,value,128);
   old_expected=enable?(legacy_state/256):value;
   if((^legacy)===1'bx || $signed(legacy)!=old_expected)
    $fatal(1,"legacy/default unconnected mismatch sample=%0d got=%0d expected=%0d",total,$signed(legacy),old_expected);
   if($signed(bypass)!=value)$fatal(1,"LOWPASS_ENABLE=0 legacy bypass");
   for(j=0;j<3;j=j+1)begin
    state[j]=update_q(state[j],value,alpha[j]);
    negative_state[j]=update_q(negative_state[j],inverse_value,alpha[j]);
    expected=(ready || enable)?(state[j]/256):value;
    if((^y[j])===1'bx || $signed(y[j])!=expected)
     $fatal(1,"expression signed model mismatch n=%0d pressure=%0d alpha=%0d in=%0d got=%0d expected=%0d",total,pressure[j],alpha[j],value,$signed(y[j]),expected);
    expected=(ready || enable)?(negative_state[j]/256):inverse_value;
    if((^yn[j])===1'bx || $signed(yn[j])!=expected)
     $fatal(1,"negative PCM model mismatch pressure=%0d got=%0d expected=%0d",pressure[j],$signed(yn[j]),expected);
   end
   if(ready)begin
    if(lp0!==y[0])$fatal(1,"ready expression incorrectly depends on LOWPASS_ENABLE");
   end else if(lp0!==pcm)$fatal(1,"unready LOWPASS_ENABLE=0 must bypass");
   if(divider==15)begin
    for(j=0;j<3;j=j+1)begin
     goal=ready?(8+pressure[j]/2):128;
     if(alpha[j]<goal)alpha[j]=alpha[j]+1;
     else if(alpha[j]>goal)alpha[j]=alpha[j]-1;
    end
   end
   divider=(divider+1)%16;
   @(negedge clk);tick=0;
  end
 endtask
 task clear_quiet;
  begin
   @(negedge clk);tick=0;quiet=1;
   @(posedge clk);#1;
   for(j=0;j<3;j=j+1)begin
    if(y[j]!==0 || yn[j]!==0)$fatal(1,"quiet without tick did not clear immediately");
    state[j]=0;negative_state[j]=0;
   end
   legacy_state=0;
   if(legacy!==0 || bypass!==0 || lp0!==0)$fatal(1,"quiet did not clear bypass/legacy");
   @(negedge clk);quiet=0;
  end
 endtask
 task symmetric;
  begin for(j=0;j<3;j=j+1)
   if($signed(y[j]) != -$signed(yn[j]))$fatal(1,"positive/negative asymmetry pressure=%0d",pressure[j]);
  end
 endtask
 task dc_step;
  input integer value;
  begin
   for(j=0;j<3;j=j+1)previous[j]=$signed(y[j]);
   for(i=0;i<1600;i=i+1)begin
    sample(value);
    for(j=0;j<3;j=j+1)begin
     lower=(previous[j]<value)?previous[j]:value;
     upper=(previous[j]>value)?previous[j]:value;
     if($signed(y[j])<lower || $signed(y[j])>upper)
      $fatal(1,"DC step overshoot/wrap pressure=%0d previous=%0d target=%0d got=%0d",pressure[j],previous[j],value,$signed(y[j]));
     previous[j]=$signed(y[j]);
    end
   end
   for(j=0;j<3;j=j+1)if($signed(y[j])!=value)$fatal(1,"DC did not converge exactly");
  end
 endtask
 initial begin
  pressure[0]=0;pressure[1]=128;pressure[2]=255;
  $readmemh("sine_400.hex",low_sine);$readmemh("sine_6000.hex",high_sine);
  reset_all;
  // A nonzero broadband signal exercises the entire coefficient ramp.
  for(i=0;i<2200;i=i+1)begin sample((i%2)?30000:-30000);symmetric;end
  if(alpha[0]!=8 || alpha[1]!=72 || alpha[2]!=135)$fatal(1,"coefficients not settled");
  $display("PRESSURE_CASE_PASS filter_coefficient_slew_16ticks_and_signed_model");
  clear_quiet;
  dc_step(32767);dc_step(-32768);dc_step(0);dc_step(-1);dc_step(1);dc_step(20000);dc_step(-20000);
  $display("PRESSURE_CASE_PASS DC_full_scale_monotonic_no_wrap_exact_convergence");
  clear_quiet;
  for(i=0;i<3000;i=i+1)begin sample((i%2)?32767:-32767);symmetric;end
  for(j=0;j<3;j=j+1)saved[j]=y[j];
  repeat(17)begin
   @(negedge clk);pcm=16'h8000;mirror_pcm=16'h7fff;
   @(posedge clk);#1;
   for(j=0;j<3;j=j+1)if(y[j]!==saved[j])$fatal(1,"output changed without tick");
  end
  clear_quiet;
  $display("PRESSURE_CASE_PASS mirrored_full_scale_PCM_no_X_hold_and_quiet_without_tick");
  // Separate coherent tones: each 9375-sample file is 0.1 s at production Fs.
  fd=$fopen("filter_pcm.csv","w");
  if(!fd)$fatal(1,"cannot open filter evidence");
  $fdisplay(fd,"frequency_hz,index,input,pressure0,pressure128,pressure255");
  for(i=0;i<2;i=i+1)begin:tone
   integer k,v,f;
   clear_quiet;
   f=(i==0)?400:6000;
   for(k=0;k<9375;k=k+1)begin
    v=(i==0)?$signed(low_sine[k]):$signed(high_sine[k]);sample(v);symmetric;
   end
   for(k=0;k<9375;k=k+1)begin
    v=(i==0)?$signed(low_sine[k]):$signed(high_sine[k]);sample(v);symmetric;
    $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d",f,k,v,$signed(y[0]),$signed(y[1]),$signed(y[2]));
   end
  end
  $fclose(fd);
  $display("PRESSURE_CASE_PASS independent_400Hz_6000Hz_sine_PCM_captured_after_settle");
  // Return from calibrated coefficients to alpha128, then erase both histories.
  ready=0;enable=1;
  for(i=0;i<2200;i=i+1)sample($signed(high_sine[i%9375]));
  for(j=0;j<3;j=j+1)if(alpha[j]!=128)$fatal(1,"fallback coefficient did not settle");
  clear_quiet;
  for(i=0;i<4096;i=i+1)begin
   sample($random(seed));
   for(j=0;j<3;j=j+1)if(y[j]!==legacy)$fatal(1,"unready alpha128 not cycle-identical to default branch");
  end
  enable=0;
  for(i=0;i<200;i=i+1)begin sample((i%2)?32767:-32768);
   for(j=0;j<3;j=j+1)if(y[j]!==pcm)$fatal(1,"unready runtime disable must bypass");
  end
  // Reassert ready with legacy enable=0 and check the second ramp, too.
  ready=1;
  for(i=0;i<2200;i=i+1)sample((i%2)?25000:-25000);
  clear_quiet;
  $display("PRESSURE_CASE_PASS unready_settled_alpha128_cycle_miter_and_ready_independent_legacy_enable");
  $display("PRESSURE_AUDIO_EXPRESSION_TEST_PASS checked_samples=%0d",total);$finish;
 end
 initial begin #5000000;$fatal(1,"filter watchdog");end
endmodule

module tb_pressure_vibrato_hub;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,tick=0,allow=1,remote=0,zero=0,rx=1;
 reg [7:0] pressure=0;
 reg signed [8:0] physical_pitch=0;
 wire signed [8:0] pitch[0:2];
 genvar g;
 generate for(g=0;g<2;g=g+1)begin:hubs
  performance_input_hub #(.MIDI_ENABLE(g),.OPTICAL_ENABLE(0),.PRESSURE_EXPRESSION_ENABLE(1)) dut(
   .clk(clk),.rst_n(rst_n),.sample_tick(tick),.allow_performance(allow),.suppress_controls(!allow),
   .remote_active(remote),.digital_zero(zero),.midi_rx(rx),.optical_beams(2'b11),
   .local_on(1'b0),.local_off(1'b0),.local_note(7'd60),.local_velocity(8'd200),
   .local_timbre(4'd0),.selected_timbre(4'd0),.local_keys(16'd0),
   .physical_volume(8'd160),.physical_pitch(physical_pitch),.pitch(pitch[g]),
   .pressure_vibrato(pressure));
 end endgenerate
 performance_input_hub old_default(.clk(clk),.rst_n(rst_n),.sample_tick(tick),
  .allow_performance(allow),.suppress_controls(!allow),.remote_active(remote),.digital_zero(zero),
  .midi_rx(1'b1),.optical_beams(2'b11),.local_on(1'b0),.local_off(1'b0),
  .local_note(7'd0),.local_velocity(8'd0),.local_timbre(4'd0),.selected_timbre(4'd0),
  .local_keys(16'd0),.physical_volume(8'd160),.physical_pitch(physical_pitch),.pitch(pitch[2]));
 integer phase=0,cc1=0,midi_base=0,owns_midi=0,checks=0,fd,k,b;
 integer minima[0:1],maxima[0:1];
 function integer saturate;
  input integer value;
  begin saturate=(value>255)?255:((value< -256)?-256:value);end
 endfunction
 task check_outputs;
  integer n,triangle_value,d0,depth,product,offset,expected,base;
  begin
   n=phase/65536;
   // Build a triangle independently from the full phase byte.
   triangle_value=((n<128)?n:(255-n))-64;
   for(n=0;n<2;n=n+1)begin
    d0=(allow && !zero)?pressure:0;
    depth=(n==1 && allow && !zero && !remote && cc1>d0)?cc1:d0;
    product=triangle_value*depth;offset=product/128;
    if(product<0 && product%128!=0)offset=offset-1;
    base=(n==1 && owns_midi && !remote)?midi_base:$signed(physical_pitch);
    expected=saturate(base+offset);
    if((^pitch[n])===1'bx || $signed(pitch[n])!=expected)
     $fatal(1,"hub signed/range/max/add/saturate mismatch n=%0d phase=%0d pressure=%0d cc1=%0d base=%0d got=%0d expected=%0d",n,phase,pressure,cc1,base,$signed(pitch[n]),expected);
    if($signed(pitch[n])<minima[n])minima[n]=$signed(pitch[n]);
    if($signed(pitch[n])>maxima[n])maxima[n]=$signed(pitch[n]);
   end
   if((^pitch[2])===1'bx || pitch[2]!==physical_pitch)$fatal(1,"default hub with unconnected pressure is not compatible");
   checks=checks+1;
  end
 endtask
 task scan;
  input integer count;input [8*80-1:0] label;
  integer t;
  begin
   for(t=0;t<2;t=t+1)begin minima[t]=999;maxima[t]=-999;end
   for(t=0;t<count;t=t+1)begin
    @(negedge clk);tick=1;
    @(posedge clk);#1;phase=(phase+1074)%16777216;check_outputs;
    $fdisplay(fd,"%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",checks,phase,pressure,$signed(physical_pitch),allow,remote,zero,$signed(pitch[0]),$signed(pitch[1]));
   end
   @(negedge clk);tick=0;
   $display("PRESSURE_CASE_PASS %0s samples=%0d midi_off_min=%0d max=%0d midi_on_min=%0d max=%0d",label,count,minima[0],maxima[0],minima[1],maxima[1]);
  end
 endtask
 task midi_byte;
  input [7:0] value;integer bitno;
  begin
   @(negedge clk);rx=0;repeat(864)@(negedge clk);
   for(bitno=0;bitno<8;bitno=bitno+1)begin rx=value[bitno];repeat(864)@(negedge clk);end
   rx=1;repeat(864)@(negedge clk);
  end
 endtask
 task modulation;
  input integer value;
  begin midi_byte(8'hb0);midi_byte(1);midi_byte(value);repeat(40)@(negedge clk);cc1=value;end
 endtask
 task bend;
  input integer value;integer raw;
  begin
   raw=8192+32*value;
   midi_byte(8'he0);midi_byte(raw%128);midi_byte(raw/128);
   repeat(40)@(negedge clk);owns_midi=1;midi_base=value;
  end
 endtask
 initial begin
  fd=$fopen("hub_pitch.csv","w");if(!fd)$fatal(1,"cannot open hub evidence");
  $fdisplay(fd,"sample_index,phase,pressure,physical_pitch,allow,remote,digital_zero,pitch_midi_off,pitch_midi_on");
  repeat(4)@(negedge clk);rst_n=1;
  scan(17000,"FSR0_no_vibrato");
  pressure=255;scan(32000,"FSR255_full_range_MIDI_disabled_and_enabled");
  if(minima[0]!=-128 || maxima[0]<125 || maxima[0]>126)$fatal(1,"full pressure depth wrong");
  pressure=128;scan(17000,"FSR128_half_depth");
  pressure=255;physical_pitch=77;scan(17000,"physical_pitch_77_preserved_plus_vibrato");
  physical_pitch=250;scan(17000,"upper_pitch_saturation_no_wrap");
  if(maxima[0]!=255)$fatal(1,"positive clamp missing");
  physical_pitch=-250;scan(17000,"lower_pitch_saturation_no_wrap");
  if(minima[0]!=-256)$fatal(1,"negative clamp missing");
  pressure=0;scan(100,"FSR_release_restores_base_immediately");
  physical_pitch=20;pressure=255;remote=1;scan(17000,"remote_active_preserves_virtual_pressure");
  allow=0;scan(17000,"allow_performance0_disables_vibrato");
  allow=1;zero=1;scan(17000,"digitalzero_disables_vibrato");
  zero=0;remote=0;physical_pitch=0;pressure=0;
  modulation(127);scan(17000,"real_UART_CC1_max127_depth");
  pressure=64;scan(17000,"CC1_127_wins_over_FSR64_no_addition");
  pressure=128;scan(17000,"FSR128_wins_over_CC1_127");
  pressure=255;modulation(64);scan(17000,"FSR255_wins_over_CC1_64");
  allow=0;scan(17000,"allow_performance0_disables_both_pressure_and_CC1");
  allow=1;zero=1;scan(17000,"digitalzero_disables_both_pressure_and_CC1");zero=0;
  bend(180);scan(17000,"real_UART_bend_base_plus_pressure_and_saturation");
  physical_pitch=-80;owns_midi=0;scan(17000,"physical_slider_takes_back_base_pitch");
  remote=1;pressure=0;scan(17000,"remote_active_suppresses_MIDI_CC1");
  remote=0;modulation(0);pressure=0;scan(100,"both_sources_release_recovers_base");
  // With sample_tick low, arbitrary main clocks cannot advance modulation.
  repeat(103)begin @(posedge clk);#1;check_outputs;end
  $display("PRESSURE_CASE_PASS sampletick_count_preserved_phase_hold_without_tick");
  $fclose(fd);
  $display("PRESSURE_VIBRATO_HUB_TEST_PASS checks=%0d production_hz=6.001442671 phase_step=1074",checks);$finish;
 end
 initial begin #12000000;$fatal(1,"hub watchdog");end
endmodule

module tb_pressure_instrument_audio;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,note_on=0,note_off=0,owned=0,mode=0,clear_audio=0,zero=0;
 reg [31:0] mask=0;
 reg [7:0] pressure[0:1];
 wire [15:0] pcm[0:1];wire tick[0:1],overrun[0:1];
 wire [31:0] audible[0:1],busy[0:1];
 genvar g;
 generate for(g=0;g<2;g=g+1)begin:audio_pair
  instrument_audio #(.REDUCED_TIMBRES(1),.PHASE_RAM(1),.PRESSURE_EXPRESSION_ENABLE(1)) dut(
   .clk(clk),.rst_n(rst_n),.note_on(note_on),.note_off(note_off),.note(7'd96),
   .velocity(8'd240),.timbre(4'd0),.slider_volume(8'd220),.slider_pitch(9'sd0),
   .hit0(1'b0),.hit1(1'b0),.velocity0(8'd0),.velocity1(8'd0),
   .digital_zero_test(zero),.filter_enable(1'b0),.test_owned(owned),.test_mode(mode),
   .test_clear(clear_audio),.normal_input_ready(1'b1),.test_gate_mask(mask),.test_master_gain(9'd256),
   .hp_bck(),.hp_ws(),.hp_din(),.overrun(overrun[g]),.monitor_tick(tick[g]),
   .monitor_pcm(pcm[g]),.monitor_pitch(),.monitor_busy(busy[g]),.monitor_test_busy(audible[g]),
   .event_source(2'd0),.pressure_brightness(pressure[g]),.pressure_brightness_ready(1'b1));
 end endgenerate
 integer i,j,fd,nz0=0,nz1=0,different=0,frames=0;
 task frame;
  begin
   @(negedge clk);while(!tick[0])@(negedge clk);
   if(tick[0]!==tick[1])$fatal(1,"audio frame cadence differs");
   for(j=0;j<2;j=j+1)begin
    if(overrun[j])$fatal(1,"PHASE_RAM=1 32voice frame deadline overrun");
    if((^pcm[j])===1'bx)$fatal(1,"audio PCM is X");
   end
   frames=frames+1;
  end
 endtask
 initial begin
  pressure[0]=0;pressure[1]=255;
  repeat(8)@(negedge clk);rst_n=1;
  // Silent frames still settle brightness coefficients at real frame cadence.
  repeat(2200)frame;
  @(negedge clk);note_on=1;@(negedge clk);note_on=0;
  repeat(1800)frame;
  fd=$fopen("instrument_pcm.csv","w");if(!fd)$fatal(1,"cannot open integration evidence");
  $fdisplay(fd,"mode,index,pressure0,pressure255");
  for(i=0;i<2048;i=i+1)begin
   frame;
   if(pcm[0]!=0)nz0=nz0+1;if(pcm[1]!=0)nz1=nz1+1;
   if(pcm[0]!==pcm[1])different=different+1;
   $fdisplay(fd,"normal,%0d,%0d,%0d",i,$signed(pcm[0]),$signed(pcm[1]));
  end
  if(nz0<1800 || nz1<1800 || different<1800)$fatal(1,"normal expression has no valid audible PCM effect");
  $display("PRESSURE_CASE_PASS actual_instrument_audio_EXPR1_PHASERAM1_valid_PCM_changes_filter_enable0 differences=%0d",different);
  @(negedge clk);owned=1;mode=1;mask=32'hffffffff;clear_audio=1;
  repeat(2)@(negedge clk);clear_audio=0;
  repeat(2200)frame;
  if(audible[0]!==32'hffffffff || audible[1]!==32'hffffffff)$fatal(1,"32test envelopes not all active");
  nz0=0;
  for(i=0;i<2048;i=i+1)begin
   frame;
   if(pcm[0]!==pcm[1])$fatal(1,"pressure altered 32test PCM sample %0d",i);
   if(pcm[0]!=0)nz0=nz0+1;
   $fdisplay(fd,"test32,%0d,%0d,%0d",i,$signed(pcm[0]),$signed(pcm[1]));
  end
  if(nz0<1800)$fatal(1,"32test equality was vacuous silence");
  $display("PRESSURE_CASE_PASS test32_nonzero_PCM_bit_identical_across_pressure0_255_all32_active");
  // Changing expression dynamically must also be unable to alter test output.
  pressure[0]=255;pressure[1]=0;
  for(i=0;i<2200;i=i+1)begin frame;if(pcm[0]!==pcm[1])$fatal(1,"dynamic pressure leaked into32test");end
  @(negedge clk);zero=1;#1;
  if(pcm[0]!==0 || pcm[1]!==0)$fatal(1,"digital zero not immediate");
  repeat(20)frame;
  $display("PRESSURE_CASE_PASS test32_dynamic_pressure_isolation_and_digitalzero");
  $fclose(fd);
  $display("PRESSURE_INSTRUMENT_AUDIO_TEST_PASS frames=%0d production_clocks_per_frame=288",frames);$finish;
 end
 initial begin #50000000;$fatal(1,"instrument audio watchdog");end
endmodule
