`timescale 1ns/1ps
// 实际MCP串行读数 -> 单键模拟解码 -> 纯UI；实际MIDI UART -> 32声部 -> PCM。
// 不用force伪造note_on；按芯片时钟周期模拟接口，物理接线/声学延迟仍须实测。
module tb_v021_touch_midi_integration;
 reg clk=0;always #18.518 clk=~clk;
 reg midi_rx=1,debug_rx=1,miso=0;reg [1:0] beams=2'b11;tri1 scl,sda;
 reg [11:0] sensor=0,latched=0,centers[0:15];reg [23:0] spi_command;
 integer edges=0,transfers=0,note_ons=0,note_offs=0,pcm_nonzero=0,optical_ons=0;
 reg [6:0] optical_notes[0:7];
 wire cs,sck,mosi,rst,tick;wire [15:0] keys,pcm,test_keys;
 wire [31:0] busy,testbusy,testgate,knobs;wire [7:0] flags,volume,e0,e1;
 wire owned,test_mode,panic,strum,tsv,filter,zero,fx_cycle;
 wire [3:0] tsv_value;wire [1:0] page,cursor,song,control_page,fx_mode;
 wire song_start,song_toggle,song_restart,key_pause;wire [5:0] requested;
 wire signed [8:0] pitch;
 instrument_audio_top #(.TOUCH_ENABLE(1),.MIDI_ENABLE(1),.OPTICAL_ENABLE(1),
   .PRESSURE_EXPRESSION_ENABLE(1),.PHASE_RAM(1),.DISPLAY_TOUCH_ONLY(1),
   .LIVE_ADSR_ENABLE(1),.EFFECTS_ENABLE(1),.TEST_HOLD_SAMPLES(32),
   .TEST_MAX_SAMPLES(20000),.TEST_RAMP_DIV(1)) dut(
   .clk(clk),.matrix_rows(),.matrix_cols(4'hf),.adc_scl(scl),.adc_sda(sda),
   .uart_rx(debug_rx),.uart_tx(),.hp_bck(),.hp_ws(),.hp_din(),.pa_en(),
   .amp_bck(),.amp_lrc(),.amp_din(),.timbre_led_n(),
   .monitor_rst_n(rst),.monitor_tick(tick),.monitor_pcm(pcm),.monitor_keys(keys),
   .monitor_timbre(),.monitor_volume(volume),.monitor_pitch(pitch),.monitor_busy(busy),
   .monitor_flags(flags),.monitor_adc(),.monitor_test_owned(owned),.monitor_test_mode(test_mode),
   .monitor_test_gate(testgate),.monitor_test_busy(testbusy),.monitor_test_requested(requested),
   .monitor_test_sweep(),.monitor_test_index(),.touch_cs_n(cs),.touch_sclk(sck),
   .touch_mosi(mosi),.touch_miso(miso),.midi_rx(midi_rx),.optical_beams(beams),
   .monitor_performance_keys(),.monitor_external_note(),.monitor_external_note_valid(),
   .monitor_expression0(e0),.monitor_expression1(e1),.monitor_pressure_calibrated(),
   .ui_test_keys(test_keys),.ui_panic(panic),.ui_strum_mode(strum),
   .ui_timbre_set_valid(tsv),.ui_timbre_set_value(tsv_value),.ui_filter_enable(filter),
   .ui_zero_mode(zero),.control_page(control_page),.ui_fx_cycle(fx_cycle),
   .monitor_fx_mode(fx_mode),.monitor_knob_values(knobs));
 // 只缩短光束资格/配对/播放计时以便数字集成；MIDI与音频仍用生产周期比。
 defparam dut.input_hub.performance.optical_input.gesture.CLK_HZ=27000;
 defparam dut.input_hub.performance.optical_input.gesture.FILTER_CYCLES=8;
 defparam dut.input_hub.performance.optical_input.gesture.STARTUP_CYCLES=128;
 defparam dut.input_hub.performance.optical_input.gesture.PAIR_WINDOW_CYCLES=2048;
 defparam dut.input_hub.performance.optical_input.player.CLK_HZ=27000;
 // MCP串行位序、通道、解码器保持真实连接，仅缩短测试轮询/串行半周期；
 // 每次事务仍完整24位且保留片选间隔，样本间隔64clk仍大于解码所需35clk。
 defparam dut.input_hub.touch_input.reader.SCLK_DIV=1;
 defparam dut.input_hub.touch_input.reader.POLL_CYCLES=64;
 defparam dut.input_hub.TOUCH_DIAG_HOLD_CYCLES=2048;
 defparam dut.input_hub.link.CLK_HZ=100000;
 defparam dut.input_hub.link.BAUD=10000;
 touch_display_control #(.HOLD_SAMPLES(128)) ui(.clk(clk),.rst_n(rst),.sample_tick(tick),
   .keys(keys),.ghost(flags[6]),.test_owned(owned),.page(page),.cursor(cursor),.song_id(song),
   .song_start(song_start),.song_toggle(song_toggle),.song_restart(song_restart),.key_pause(key_pause),
   .test_keys(test_keys),.panic_pulse(panic),.strum_mode(strum),.control_page(control_page),
   .fx_cycle(fx_cycle),.timbre_set_valid(tsv),.timbre_set_value(tsv_value),
   .filter_enable(filter),.zero_mode(zero));
 always @(negedge cs)begin latched=sensor;edges=0;spi_command=0;miso=0;end
 always @(posedge sck)if(!cs)begin spi_command={spi_command[22:0],mosi};edges=edges+1;end
 always @(negedge sck)if(!cs)begin
   if(edges>=12 && edges<24)miso=latched[23-edges];else miso=0;
 end
 always @(posedge cs)if(rst && edges!=0)begin
   if(edges!=24 || spi_command!==24'h060000)$fatal(1,"V021 wrong MCP channel/command");
   transfers=transfers+1;
 end
 always @(posedge clk)begin #1;
  if(rst)begin
   if(dut.input_hub.local_on || dut.input_hub.local_off)$fatal(1,"touch leaked local musical event");
   if(dut.note_on)begin
    note_ons=note_ons+1;
    if(dut.note_source==0)$fatal(1,"V021 allocated a local touch voice");
    if(dut.note_source==2)begin
     if(optical_ons>=8)$fatal(1,"unexpected extra optical note");
     optical_notes[optical_ons]=dut.note;optical_ons=optical_ons+1;
    end
   end
   if(dut.note_off)note_offs=note_offs+1;
   if(dut.overrun)$fatal(1,"V021 synth overrun");
   if(tick)begin
    if((^pcm)===1'bx)$fatal(1,"V021 PCM contains X");
    if(pcm!=0)pcm_nonzero=pcm_nonzero+1;
   end
  end
 end
 task clocks;input integer count;begin repeat(count)@(negedge clk);end endtask
 task touch;input integer index;begin
   sensor=centers[index];clocks(1024);
   if(keys!==(16'h0001<<index))$fatal(1,"touch key not decoded index=%0d keys=%h",index,keys);
   sensor=0;clocks(1024);
 end endtask
 task frames;input integer count;integer f;begin
  for(f=0;f<count;f=f+1)begin @(posedge tick);@(negedge clk);end
 end endtask
 task midi_byte;input [7:0] value;integer b;begin
  @(negedge clk);midi_rx=0;clocks(864);
  for(b=0;b<8;b=b+1)begin midi_rx=value[b];clocks(864);end
  midi_rx=1;clocks(864);
 end endtask
 task message;input [7:0] status,a,b;begin
  midi_byte(status);midi_byte(a);midi_byte(b);clocks(100);
 end endtask
 task debug_byte;input [7:0] value;integer b;begin
  @(negedge clk);debug_rx=0;clocks(10);
  for(b=0;b<8;b=b+1)begin debug_rx=value[b];clocks(10);end
  debug_rx=1;clocks(10);
 end endtask
 task diagnostic;integer j;begin
  debug_byte(8'ha5);debug_byte(8'h5a);debug_byte(1);debug_byte(8'h80);
  for(j=4;j<15;j=j+1)debug_byte(0);
  debug_byte(8'h81);clocks(10);
 end endtask
 integer k,before_notes,before_optical,before_pcm;
 initial begin
  $readmemh("src/touch_centers.hex",centers);clocks(3000);
  for(k=0;k<16;k=k+1)begin
   touch(k);
   if(note_ons!=0 || note_offs!=0 || busy!=0 || owned)
    $fatal(1,"touch %0d created a voice or short-press test entry",k+1);
  end
  if(pcm_nonzero!=0)$fatal(1,"UI-only operation emitted PCM");
  $display("V021_CHECKPOINT touch16_no_notes");
  diagnostic();sensor=centers[14];
  for(k=0;k<8;k=k+1)diagnostic();
  if(owned || note_ons!=0 || flags[1] || !dut.input_hub.touch_calibrating)
   $fatal(1,"calibration polling triggered test32 or remote takeover");
  sensor=0;clocks(3000);
  if(dut.input_hub.touch_calibrating)$fatal(1,"calibration UI holdoff did not expire");
  // 恢复键盘模式；全部16键已短按，S11之前会切到扫弦。
  if(strum)touch(10);
  if(strum || zero)$fatal(1,"mode/short S14 unexpectedly latched zero");
  message(8'hb0,7,127);frames(8);
  if(volume!==255)$fatal(1,"CC7 lost in touch-menu version");
  midi_byte(8'h90);
  for(k=0;k<32;k=k+1)begin midi_byte(48+k);midi_byte(100);end
  frames(160);
  if(dut.audio.gate!==32'hffffffff || busy!==32'hffffffff || pcm_nonzero<50)
   $fatal(1,"MIDI32 not sounding gate=%h busy=%h pcm=%0d",dut.audio.gate,busy,pcm_nonzero);
  $display("V021_CHECKPOINT full32_midi");
  before_notes=note_ons;touch(0);touch(1);touch(2);touch(4);touch(5);
  if(note_ons!=before_notes || dut.audio.gate!==32'hffffffff)$fatal(1,"UI interrupted held MIDI chord");
  // 主界面任意状态下的Panic均清音，不能残留效果器尾音。
  touch(12);frames(8);
  if(busy!=0 || dut.audio.gate!=0 || pcm!=0)$fatal(1,"touch Panic left voice/tail");
  // 扫弦模式：左手MIDI只选和弦，真正A/B光束时序才生成source2音符。
  touch(10);before_notes=note_ons;
  // 非默认且从未按过的和弦，排除Panic屏蔽和空和弦C/E/G回退造成的假通过。
  message(8'h90,82,100);message(8'h90,85,100);message(8'h90,89,100);frames(8);
  if(!strum || note_ons!=before_notes || dut.audio.gate!=0)$fatal(1,"strum chord selection sounded twice");
  if(dut.input_hub.performance.held!==((128'b1<<82)|(128'b1<<85)|(128'b1<<89)))
   $fatal(1,"MIDI-selected chord missing or contaminated");
  before_optical=optical_ons;
  beams=2'b10;clocks(300);beams=2'b00;clocks(300);beams=2'b11;clocks(3000);
  if(optical_ons!=before_optical+3 || optical_notes[before_optical]!=82 ||
     optical_notes[before_optical+1]!=85 || optical_notes[before_optical+2]!=89)
   $fatal(1,"paired optical gesture did not play exact selected chord in order");
  $display("V021_CHECKPOINT optical_chord");
  touch(12);touch(10);frames(8);
  if(strum || busy!=0 || dut.audio.gate!=0)$fatal(1,"strum exit/Panic left sound");
  // 单S15长按可进入测试，不需要模拟触摸板不支持的组合键。
  sensor=centers[14];clocks(180000);sensor=0;clocks(1024);frames(20);
  if(!owned || !test_mode || testgate!==32'hffffffff || testbusy!==32'hffffffff)
   $fatal(1,"single-key 32 test failed gate=%h busy=%h",testgate,testbusy);
  $display("V021_CHECKPOINT single_touch_test32");
  message(8'h90,84,127);frames(10);
  if(dut.audio.gate!=0 || pitch!==0 || !dut.input_hub.performance.midi_input.keyboard.blocked_notes[84])
   $fatal(1,"new MIDI note was not safely isolated during test32");
  touch(0);frames(8);
  if(requested!=1 || testgate!=1)$fatal(1,"single touch test count failed");
  touch(4);frames(8);
  if(requested!=32 || testbusy!==32'hffffffff)$fatal(1,"single touch restore32 failed");
  // S13在测试中也必须工作；立即静音，随后有界淡出退出而不是卡住。
  sensor=centers[12];clocks(1024);frames(2);
  if(pcm!==0)$fatal(1,"Panic in test mode not silent");
  sensor=0;clocks(1024);frames(550);
  if(owned || test_mode)$fatal(1,"Panic cannot exit test mode");
  // 69从起初32和弦一直未松开，Panic必须阻止其自动恢复；
  // 先从真实UART送松键，再重新按下，验证安全阻塞和恢复两条路径。
  if(!dut.input_hub.performance.midi_input.keyboard.blocked_notes[69])
   $fatal(1,"held note lost Panic safety block");
  message(8'h80,69,0);frames(2);
  if(dut.input_hub.performance.midi_input.keyboard.blocked_notes[69])$fatal(1,"release69 did not unblock");
  before_pcm=pcm_nonzero;
  message(8'h90,69,110);frames(150);
  if(dut.audio.gate==0 || busy==0 || pcm_nonzero<=before_pcm || dut.panic_test_mute)
   $fatal(1,"MIDI/PCM did not recover after test");
  message(8'h80,69,0);frames(8);
  if(dut.audio.gate!=0)$fatal(1,"MIDI note off lost after test");
  message(8'h80,84,0);frames(2);before_pcm=pcm_nonzero;
  message(8'h90,84,110);frames(150);
  if(dut.input_hub.performance.midi_input.keyboard.blocked_notes[84] || dut.audio.gate==0 || pcm_nonzero<=before_pcm)
   $fatal(1,"test-time blocked key did not recover after physical release/repress");
  $display("V021_TOUCH_MIDI_INTEGRATION_PASS touch16_no_notes=1 calibration_safe=1 held_midi_ui_isolated=1 full32=1 strum_no_double_sound=1 optical_chord=1 single_touch_test32=1 panic=1 test_panic=1 spi=%0d notes=%0d pcm=%0d",transfers,note_ons,pcm_nonzero);
  $finish;
 end
 initial begin #300000000;$fatal(1,"V021 integration watchdog");end
endmodule
