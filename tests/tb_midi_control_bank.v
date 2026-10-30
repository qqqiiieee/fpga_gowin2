`timescale 1ns/1ps
// 真实MIDI UART -> 控制库 -> 真实音量仲裁 -> 实际回读；不force内部信号。
module tb_midi_control_bank;
 reg clk=0,rst_n=0,rx=1;always #5 clk=~clk;
 reg[7:0]physical_volume=160;reg suppress=0,manual_panic=0;
 wire[7:0]volume,request;wire request_valid,cc_valid;wire[6:0]cc_number,cc_value;
 reg phone_set_valid=0;reg[7:0]phone_param=0,phone_value=0;
 wire[31:0]knob_values;wire[1:0]fx_mode;wire[7:0]fx_amount;
 integer pulses=0,before_pulses;
 performance_input_hub #(.MIDI_ENABLE(1),.CONTROL_BANK_ENABLE(1),.PHONE_VOLUME_ENABLE(1)) hub(
  .clk(clk),.rst_n(rst_n),.sample_tick(1'b1),.allow_performance(!suppress),.suppress_controls(suppress),
  .remote_active(1'b0),.digital_zero(1'b0),.midi_rx(rx),.optical_beams(2'b11),
  .local_on(1'b0),.local_off(1'b0),.local_note(7'd0),.local_velocity(8'd0),.local_timbre(4'd0),
  .selected_timbre(4'd0),.local_keys(16'd0),.physical_volume(physical_volume),.physical_pitch(9'sd0),
  .volume(volume),.strum_mode(1'b0),.manual_panic(manual_panic),.pressure_vibrato(8'd0),
  .knob_volume_valid(request_valid),.knob_volume(request),.cc_valid(cc_valid),.cc_number(cc_number),.cc_value(cc_value));
 defparam hub.midi_input.keyboard.CLK_HZ=1000000;
 midi_control_bank bank(.clk(clk),.rst_n(rst_n),.cc_valid(cc_valid),.cc_number(cc_number),.cc_value(cc_value),
  .control_page(2'd2),.ui_fx_cycle(1'b0),.current_master_volume(volume),
  .master_volume(request),.master_volume_valid(request_valid),.knob_values(knob_values),
  .phone_set_valid(phone_set_valid),.phone_param(phone_param),.phone_value(phone_value),
  .phone_query_param(8'd0),.fx_mode(fx_mode),.fx_amount(fx_amount));
 always @(posedge clk)if(rst_n && request_valid)pulses=pulses+1;
 task tick;repeat(8)@(negedge clk);endtask
 task byte_midi(input[7:0]data);integer b;begin
  @(negedge clk);rx=0;repeat(32)@(negedge clk);
  for(b=0;b<8;b=b+1)begin rx=data[b];repeat(32)@(negedge clk);end
  rx=1;repeat(32)@(negedge clk);
 end endtask
 task midi(input[6:0]number,value);begin byte_midi(8'hb0);byte_midi(number);byte_midi(value);tick;end endtask
 task check(input[7:0]want);begin
  if(volume!==want || knob_values[31:24]!==want)$fatal(1,"volume/display got %0d expected %0d",volume,want);
 end endtask
 task phone(input[7:0]param,value);begin
  @(negedge clk);phone_param=param;phone_value=value;phone_set_valid=1;
  @(negedge clk);phone_set_valid=0;tick;
 end endtask
 initial begin
  tick;rst_n=1;tick;check(160);
  midi(74,0);check(160);midi(74,80);check(161);midi(74,100);check(201);
  physical_volume=161;tick;check(201);physical_volume=163;tick;check(201);
  physical_volume=164;tick;check(164);
  before_pulses=pulses;midi(74,100);check(164);
  if(pulses!=before_pulses)$fatal(1,"old K4 repeated after physical takeover");
  midi(74,82);check(165);midi(74,110);check(221);
  midi(7,30);check(60);midi(74,110);check(60);
  midi(74,30);check(60);midi(74,31);check(62);
  // CC7仍按hub既有共享上次请求值仲裁；K4刚写62后CC7的60是新变化。
  midi(7,30);check(60);midi(7,31);check(62);midi(7,32);check(64);
  midi(74,31);check(64);midi(74,32);check(64);midi(74,33);check(66);
  phone(0,77);check(77);midi(74,127);check(77);midi(74,38);check(76);
  midi(74,0);check(0);midi(74,127);check(255);
  physical_volume=170;tick;check(170);phone(0,255);check(255);
  physical_volume=174;tick;check(174);midi(74,127);check(174);
  // 手机音量也尊重原仲裁器抑制；解除后不得重发被拒绝的旧请求。
  suppress=1;tick;phone(0,99);check(174);suppress=0;tick;check(174);
  midi(74,87);check(175);midi(74,88);check(177);
  manual_panic=1;tick;manual_panic=0;tick;check(177); // 手机Panic清音，保留参数。
  midi(120,0);check(174); // 现有MIDI Panic另外把音量所有权归还滑杆。
  midi(74,88);check(174);midi(74,87);check(175);
  // 三效果走相同串口并真正进入控制库；K4不改效果，效果不改总音量。
  midi(93,32);midi(93,33);if(fx_mode!==1 || fx_amount!==66)$fatal(1,"Delay UART mapping");
  midi(91,32);midi(91,34);if(fx_mode!==2 || fx_amount!==68)$fatal(1,"Chorus UART mapping");
  midi(71,32);midi(71,35);if(fx_mode!==3 || fx_amount!==70)$fatal(1,"Reverb UART mapping");
  midi(93,33);if(fx_mode!==3)$fatal(1,"repeated inactive effect stole mode");
  check(175);
  $display("MIDI_CONTROL_BANK_TEST_PASS real_UART_bank_hub_slider_CC7_phone_panic_suppress pulses=%0d",pulses);$finish;
 end
 initial begin #5000000;$fatal(1,"control bank watchdog");end
endmodule
