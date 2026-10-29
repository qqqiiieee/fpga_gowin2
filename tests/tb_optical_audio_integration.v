`timescale 1ns/1ps
// 实际beam引脚→识别→和弦快照→事件仲裁→带来源分配器→非零PCM。
// 识别滤波/启动参数缩短，独立optical_agent已另测生产周期。
module tb_optical_audio_integration;
 reg clk=0,rst_n=0,rx=1;always #5 clk=~clk;
 reg[1:0] beams=3;reg allow=1,suppress=0,clear=0;
 wire tick,evon,evoff,pc,pvalid,panic;wire[6:0] note,primary;
 wire[7:0] velocity,volume,md0,md1;wire[3:0] timbre,pt;wire[1:0] source;
 wire signed[8:0] pitch;wire h0,h1;wire[11:0] perf;wire[13:0] status;
 wire[15:0] pcm;wire[31:0] busy;wire overrun;
 integer on_count=0,off_count=0,n,nonzero=0,post_panic_ons=0;
 reg[6:0] played[0:15];
 performance_input_hub #(.MIDI_ENABLE(1),.OPTICAL_ENABLE(1)) hub(
 .clk(clk),.rst_n(rst_n),.sample_tick(tick),.allow_performance(allow),.suppress_controls(suppress),
 .remote_active(1'b0),.digital_zero(1'b0),.midi_rx(rx),.optical_beams(beams),
 .local_on(1'b0),.local_off(1'b0),.local_note(7'd0),.local_velocity(8'd0),
 .local_timbre(4'd0),.selected_timbre(4'd0),.local_keys(16'd0),.physical_volume(8'd255),.physical_pitch(9'sd0),
 .note_on(evon),.note_off(evoff),.note(note),.velocity(velocity),.timbre(timbre),.event_source(source),
 .volume(volume),.pitch(pitch),.program_valid(pc),.program_timbre(pt),.midi_hit0(h0),.midi_hit1(h1),
 .midi_drum_velocity0(md0),.midi_drum_velocity1(md1),.panic_audio(panic),.performance_keys(perf),
 .primary_note(primary),.primary_valid(pvalid),.diagnostic_status(status));
 defparam hub.optical_input.gesture.STARTUP_CYCLES=300;
 defparam hub.optical_input.gesture.FILTER_CYCLES=27;
 defparam hub.optical_input.gesture.PAIR_WINDOW_CYCLES=3000;
 defparam hub.optical_input.player.HOLD_MS=5;
 instrument_audio #(.REDUCED_TIMBRES(1),.SOURCE_TAG_ENABLE(1),.PHASE_RAM(1)) audio(
 .clk(clk),.rst_n(rst_n),.note_on(evon),.note_off(evoff),.note(note),.velocity(velocity),.timbre(timbre),
 .event_source(source),.slider_volume(volume),.slider_pitch(pitch),.hit0(h0),.hit1(h1),.velocity0(md0),.velocity1(md1),
 .digital_zero_test(1'b0),.filter_enable(1'b1),.test_owned(1'b0),.test_mode(1'b0),.test_clear(panic||clear),
 .normal_input_ready(1'b1),.test_gate_mask(32'd0),.test_master_gain(9'd256),.hp_bck(),.hp_ws(),.hp_din(),
 .overrun(overrun),.monitor_tick(tick),.monitor_pcm(pcm),.monitor_pitch(),.monitor_busy(busy),.monitor_test_busy());
 always@(posedge clk)begin
 if(rst_n&&source==2)begin
  if(evon)begin played[on_count]=note;on_count=on_count+1;if(timbre!=1)$fatal(1,"OPTICAL wrong timbre");end
  if(evoff)off_count=off_count+1;
 end
 #1;if(rst_n&&tick&&pcm!=0)nonzero=nonzero+1;
 if(overrun)$fatal(1,"OPTICAL audio overrun");
 end
 task byte_midi;input[7:0] data;integer b;begin
 @(negedge clk);rx=0;repeat(864)@(negedge clk);
 for(b=0;b<8;b=b+1)begin rx=data[b];repeat(864)@(negedge clk);end
 rx=1;repeat(864)@(negedge clk);
 end endtask
 task gesture;input rev;begin
 beams=3;repeat(100)@(negedge clk);
 beams=rev?2'b01:2'b10;repeat(100)@(negedge clk);
 beams=0;repeat(100)@(negedge clk);beams=3;
 end endtask
 task wait_off;input integer goal;integer cycles;begin cycles=0;
 while(off_count<goal&&cycles<600000)begin @(negedge clk);cycles=cycles+1;end
 if(off_count!=goal)$fatal(1,"OPTICAL missing off goal=%0d actual=%0d",goal,off_count);
 repeat(1000)@(negedge clk);end endtask
 initial begin
 repeat(5)@(negedge clk);rst_n=1;repeat(600)@(negedge clk);
 gesture(0);wait_off(4);
 if(on_count!=4||played[0]!=60||played[1]!=64||played[2]!=67||played[3]!=72||audio.gate!=0||nonzero<20)
 $fatal(1,"OPTICAL default chord/audio on=%0d off=%0d pcm=%0d",on_count,off_count,nonzero);
 byte_midi(8'h90);byte_midi(48);byte_midi(100);byte_midi(52);byte_midi(100);byte_midi(55);byte_midi(100);
 repeat(1000)@(negedge clk);gesture(1);wait_off(7);
 if(on_count!=7||played[4]!=55||played[5]!=52||played[6]!=48)$fatal(1,"OPTICAL MIDI snapshot reverse chord");
 n=0;for(integer k=0;k<32;k=k+1)if(audio.u_alloc.gates[k]&&audio.u_alloc.sources[k]==1)n=n+1;
 if(n!=3)$fatal(1,"OPTICAL off released MIDI same pitch");
 // 抑制阶段不产生beam演奏；全局清由系统验证控制器负责，此处给相同接口脉冲。
 allow=0;suppress=1;clear=1;@(negedge clk);clear=0;gesture(0);repeat(6000)@(negedge clk);
 if(audio.gate!=0||on_count!=7)$fatal(1,"OPTICAL leaked while suppressed");
 allow=1;suppress=0;beams=3;repeat(300)@(negedge clk);
 byte_midi(8'hb0);byte_midi(123);byte_midi(0);repeat(1000)@(negedge clk);
 if(hub.held!=0)$fatal(1,"OPTICAL held MIDI cleanup");
 gesture(0);wait_off(11);
 if(on_count!=11||audio.gate!=0)$fatal(1,"OPTICAL cannot resume after suppression");
 // 在旧扫弦只弹出第一个音时panic，后面已排定的旧音绝不能重新发声。
 gesture(0);repeat(100)@(negedge clk);
 byte_midi(8'hb0);byte_midi(120);byte_midi(0);repeat(100)@(negedge clk);
 post_panic_ons=on_count;repeat(400000)@(negedge clk);
 if(on_count!=post_panic_ons||audio.gate!=0||busy!=0||pcm!=0||hub.optical_input.player.busy)
 $fatal(1,"OPTICAL global panic allowed stale strum to resume");
 $display("OPTICAL_AUDIO_INTEGRATION_TEST_PASS fallback_default=1 MIDI_chord_reverse=1 source_isolation=1 suppression=1 note_on=%0d note_off=%0d nonzero_pcm=%0d",on_count,off_count,nonzero);$finish;
 end
 initial begin #40000000;$fatal(1,"OPTICAL_AUDIO_INTEGRATION watchdog");end
endmodule
