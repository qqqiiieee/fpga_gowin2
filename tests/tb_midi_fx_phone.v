`timescale 1ns/1ps
// V031公开端口回归：三个独立强度、互斥效果、手机优先、实际音量软接管。
module tb_midi_fx_phone;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg cc_valid=0,ui_fx_cycle=0,phone_set_valid=0;
 reg[6:0]cc_number=0,cc_value=0;
 reg[1:0]control_page=0;
 reg[7:0]current_master_volume=160,phone_param=0,phone_value=0,phone_query_param=0;
 wire[7:0]phone_query_value,master_volume,mix_balance,brightness_base;
 wire master_volume_valid;
 wire[7:0]attack_ctrl,decay_ctrl,sustain_ctrl,release_ctrl,fx_amount,fx_time,fx_feedback,fx_mod;
 wire[1:0]fx_mode;wire[31:0]knob_values;
 integer checks=0,groups=0,pulses=0,k,v,p,m,n,before_pulses;
 reg echo=0;reg[31:0]saved;reg[1:0]saved_mode;
 midi_control_bank dut(.*);
 // 外部最终音量回读可以延后一拍，也可以拒绝请求，不能强制总跟随请求。
 always @(posedge clk)if(rst_n && master_volume_valid)begin
  pulses=pulses+1;if(echo)current_master_volume<=master_volume;
 end
 function[6:0]cc(input integer index);case(index)0:cc=93;1:cc=91;2:cc=71;default:cc=74;endcase endfunction
 function[7:0]expand(input integer value);expand=(value<<1)|(value>>6);endfunction
 task tick;repeat(4)@(negedge clk);endtask
 task reset;begin
  @(negedge clk);rst_n=0;cc_valid=0;phone_set_valid=0;ui_fx_cycle=0;echo=0;
  current_master_volume=160;control_page=0;tick;rst_n=1;tick;
  if(fx_mode!==0 || fx_amount!==64 || knob_values!==32'ha0404040 || fx_time!==96 ||
     fx_feedback!==80 || fx_mod!==48 || master_volume_valid!==0)$fatal(1,"defaults");
 end endtask
 task event_drive(input bit cv,input[6:0]num,value,input bit sv,input[7:0]param,data);begin
  @(negedge clk);cc_valid=cv;cc_number=num;cc_value=value;phone_set_valid=sv;phone_param=param;phone_value=data;
  @(negedge clk);cc_valid=0;phone_set_valid=0;tick;
 end endtask
 task midi(input[6:0]num,value);event_drive(1,num,value,0,0,0);endtask
 task phone(input[7:0]param,data);event_drive(0,0,0,1,param,data);endtask
 task mode_amount(input[1:0]mode,input[7:0]amount);begin
  checks=checks+1;if(fx_mode!==mode || fx_amount!==amount)$fatal(1,"mode/amount got %0d/%0d want %0d/%0d",fx_mode,fx_amount,mode,amount);
  phone_query_param=3;#1;if(phone_query_value!=={6'd0,mode})$fatal(1,"GET3");
  phone_query_param=4;#1;if(phone_query_value!==amount)$fatal(1,"GET4");
 end endtask
 task query(input[7:0]param,value);begin
  phone_query_param=param;#1;checks=checks+1;if(phone_query_value!==value)$fatal(1,"GET%0d got %0d expected %0d",param,phone_query_value,value);
 end endtask
 task group(input[8*100-1:0]label);begin groups=groups+1;$display("FX_PHONE_CASE_PASS %0s",label);end endtask
 initial begin
  reset;mode_amount(0,64);query(0,160);
  saved=knob_values;cc_number=93;cc_value=127;phone_param=3;phone_value=3;tick;
  if(knob_values!==saved || fx_mode!==0)$fatal(1,"payload without valid");
  for(v=0;v<128;v=v+1)if(v!=93 && v!=91 && v!=71 && v!=74)begin
   midi(v,127);if(knob_values!==saved || fx_mode!==0 || master_volume_valid)$fatal(1,"unknown CC changed controls");
  end
  group("defaults_OFF_valid_gating_unknown_CC_CC7_independent");
  for(p=0;p<4;p=p+1)begin
   reset;control_page=p;
   for(k=0;k<3;k=k+1)begin
    midi(cc(k),127);if(knob_values[k*8+:8]!==64)$fatal(1,"unpicked jumped");
    saved_mode=fx_mode;midi(cc(k),32);if(fx_mode!==saved_mode)$fatal(1,"same accepted value stole mode");
    for(v=0;v<128;v=v+1)begin
     midi(cc(k),v);mode_amount(k+1,expand(v));
     if(knob_values[k*8+:8]!==expand(v) || knob_values[31:24]!==160)$fatal(1,"stored target/display");
    end
   end
   mode_amount(3,255);midi(93,127);mode_amount(3,255);midi(91,127);mode_amount(3,255);
   midi(93,126);mode_amount(1,253);midi(71,126);mode_amount(3,253);
   if(fx_time!==96 || fx_feedback!==80 || fx_mod!==48 || attack_ctrl!==32)$fatal(1,"knobs changed phone detail controls");
  end
  group("three_effects_all_pages_1536_values_restore_inactive_target_repeat_does_not_steal");
  for(k=0;k<3;k=k+1)begin
   reset;phone(3,k+1);phone(4,100);mode_amount(k+1,100);
   midi(cc(k),127);mode_amount(k+1,100);midi(cc(k),0);mode_amount(k+1,0);
   phone(4,100);midi(cc(k),0);mode_amount(k+1,100);midi(cc(k),60);mode_amount(k+1,120);
   for(v=0;v<256;v=v+1)begin
    phone(4,v);midi(cc(k),v>>1);mode_amount(k+1,expand(v>>1));
    if(knob_values[k*8+:8]!==expand(v>>1))$fatal(1,"phone stored amount mismatch");
   end
   phone(4,100);midi(cc(k),49);mode_amount(k+1,100);
   phone(4,100);midi(cc(k),51);mode_amount(k+1,100);
  end
  group("phone_768_strength_targets_near_one_crossing_distance_two_retarget_history");
  reset;phone(4,100);mode_amount(0,100);phone(3,1);mode_amount(1,100);
  phone(3,2);mode_amount(2,64);phone(4,200);phone(3,3);mode_amount(3,64);
  phone(3,1);mode_amount(1,100);phone(3,2);mode_amount(2,200);
  phone(3,0);phone(4,77);mode_amount(0,77);phone(3,2);mode_amount(2,77);
  group("phone_mode_restores_per_effect_amount_OFF_edits_recent_effect");
  for(k=0;k<3;k=k+1)for(m=0;m<4;m=m+1)begin
   reset;midi(cc(k),32);saved=knob_values;
   event_drive(1,cc(k),60,1,3,m);
   if(knob_values!==saved)$fatal(1,"phone mode collision committed CC");mode_amount(m,64);
   midi(cc(k),127);mode_amount(m,64); // 同拍采样没有遗留成假跨越。
   midi(cc(k),32);mode_amount(m,64);midi(cc(k),33);mode_amount(k+1,66);
  end
  reset;phone(3,1);midi(91,32);
  event_drive(1,91,60,1,4,100);mode_amount(1,100);
  if(knob_values[15:8]!==64)$fatal(1,"SET4 collision changed inactive effect");
  midi(93,127);mode_amount(1,100);midi(93,50);mode_amount(1,100);midi(93,51);mode_amount(1,102);
  for(v=4;v<256;v=v+1)begin saved=knob_values;phone(3,v);if(knob_values!==saved || fx_mode!==1)$fatal(1,"invalid mode accepted");end
  group("phone_SET3_all_modes_wins_discards_CC_SET4_syncs_owner_invalid_modes_ignored");
  for(p=5;p<=11;p=p+1)for(v=0;v<256;v=v+1)begin phone(p,v);query(p,v);end
  saved=knob_values;for(p=0;p<256;p=p+1)if(p!=0 && !(p>=3 && p<=11))begin
   phone(p,255);query(p,0);if(knob_values!==saved)$fatal(1,"unknown phone mutated target");
  end
  group("detail_time_feedback_mod_ADSR_1792_writes_and_unknown_queries");
  reset;echo=1;before_pulses=pulses;
  midi(74,0);if(pulses!=before_pulses)$fatal(1,"unpicked volume pulse");
  midi(74,80);query(0,161); // 160不可精确表示，容差1允许接管。
  for(v=0;v<128;v=v+1)begin midi(74,v);query(0,expand(v));end
  before_pulses=pulses;midi(74,127);if(pulses!=before_pulses)$fatal(1,"repeat steals volume");
  @(negedge clk);current_master_volume=100;tick;
  midi(74,127);query(0,100);midi(74,50);query(0,100);midi(74,51);query(0,102);
  // 同拍外部音量变化不能继承旧picked/history，必须面对新真实目标。
  @(negedge clk);current_master_volume=200;cc_valid=1;cc_number=74;cc_value=0;
  @(negedge clk);cc_valid=0;tick;query(0,200);
  midi(74,100);query(0,201);midi(74,101);query(0,203);
  event_drive(1,74,0,1,0,77);query(0,77);
  midi(74,127);query(0,77);midi(74,38);query(0,76);
  mode_amount(0,64);
  group("K4_128_values_own_ack_keeps_pickup_external_change_rearms_phone_volume_priority");
  reset;before_pulses=pulses;midi(74,80);midi(74,80);
  if(pulses!=before_pulses+1)$fatal(1,"unacknowledged repeated volume resent");
  query(0,160);if(knob_values[31:24]!==160)$fatal(1,"display showed requested not actual");
  for(v=0;v<256;v=v+1)begin phone(0,v);query(0,160);if(master_volume!==v)$fatal(1,"phone volume truncation");end
  group("rejected_volume_request_not_repeated_GET_display_actual_phone_256_values");
  reset;event_drive(1,93,0,1,5,231);midi(93,127);mode_amount(1,255);query(5,231);
  phone(3,0);midi(93,127);mode_amount(0,255);midi(93,126);mode_amount(1,253);
  reset;mode_amount(0,64);
  group("unrelated_phone_allows_effect_change_OFF_requires_new_changed_value_reset");
  $display("MIDI_FX_PHONE_TEST_PASS groups=%0d checks=%0d",groups,checks);$finish;
 end
 initial begin #5000000;$fatal(1,"FX phone watchdog");end
endmodule
