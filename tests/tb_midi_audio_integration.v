`timescale 1ns/1ps
// 生产27MHz/31250比例的串口→真实输入层→分配器/ADSR/耳机PCM全链路。
module tb_midi_audio_integration;
 reg clk=0;always #18.518 clk=~clk;
 reg rx=1;wire[3:0] rows;reg[3:0] cols=15;reg[15:0] buttons=0;tri1 scl,sda;
 wire tick,rst,owned,mode;wire[15:0] pcm,keys;wire[3:0] selected;
 wire[31:0] busy,testbusy,testgate;wire[7:0] vol;wire signed[8:0] pitch;
 wire[6:0] primary;wire primary_valid;wire[11:0] performance;
 integer r,c,k,n,nonzero=0,midi60=0,local60=0;
 instrument_audio_top #(.TOUCH_ENABLE(1),.MIDI_ENABLE(1),.OPTICAL_ENABLE(0),.PHASE_RAM(1),.PRESSURE_EXPRESSION_ENABLE(1),
  .TEST_HOLD_SAMPLES(8),.TEST_MAX_SAMPLES(500000),.TEST_RAMP_DIV(1)) dut(
 .clk(clk),.matrix_rows(rows),.matrix_cols(cols),.adc_scl(scl),.adc_sda(sda),
 .uart_rx(1'b1),.uart_tx(),.hp_bck(),.hp_ws(),.hp_din(),.pa_en(),
 .amp_bck(),.amp_lrc(),.amp_din(),.timbre_led_n(),
 .monitor_rst_n(rst),.monitor_tick(tick),.monitor_pcm(pcm),.monitor_keys(keys),.monitor_timbre(selected),
 .monitor_volume(vol),.monitor_pitch(pitch),.monitor_busy(busy),.monitor_flags(),.monitor_adc(),
 .monitor_test_owned(owned),.monitor_test_mode(mode),.monitor_test_gate(testgate),.monitor_test_busy(testbusy),
 .monitor_test_requested(),.monitor_test_sweep(),.monitor_test_index(),
 .touch_cs_n(),.touch_sclk(),.touch_mosi(),.touch_miso(1'b0),.midi_rx(rx),.optical_beams(2'b11),
 .monitor_performance_keys(performance),.monitor_external_note(primary),.monitor_external_note_valid(primary_valid));
 always@*begin cols=15;for(r=0;r<4;r=r+1)if(rows[r]===1'b0)
  for(c=0;c<4;c=c+1)if(buttons[r*4+c])cols[c]=0;end
 always@(posedge clk)begin #1;if(rst&&tick&&pcm!=0)nonzero=nonzero+1;end
 task byte_midi;input[7:0] data;integer b;begin
  @(negedge clk);rx=0;repeat(864)@(negedge clk);
  for(b=0;b<8;b=b+1)begin rx=data[b];repeat(864)@(negedge clk);end
  rx=1;repeat(864)@(negedge clk);
 end endtask
 task message;input[7:0] s,a,b;begin byte_midi(s);byte_midi(a);byte_midi(b);repeat(300)@(negedge clk);end endtask
 task frames;input integer count;integer f;begin for(f=0;f<count;f=f+1)begin @(posedge tick);@(negedge clk);end end endtask
 task count60;begin midi60=0;local60=0;
  for(n=0;n<32;n=n+1)if(dut.audio.u_alloc.gates[n]&&dut.audio.u_alloc.notes[n]==60)begin
   if(dut.audio.u_alloc.sources[n]==1)midi60=midi60+1;
   if(dut.audio.u_alloc.sources[n]==0)local60=local60+1;
  end
 end endtask
 initial begin
 repeat(1000)@(negedge clk);
 message(8'hb0,7,127);if(vol!=255)$fatal(1,"MIDI CC7 not integrated");
 byte_midi(8'h90);for(k=0;k<32;k=k+1)begin byte_midi(48+k);byte_midi(96);end
 frames(200);
 if(dut.audio.gate!==32'hffffffff || busy!==32'hffffffff || nonzero<100)
  $fatal(1,"MIDI full32 not sounding gate=%h busy=%h nonzero=%0d",dut.audio.gate,busy,nonzero);
 if(!primary_valid||primary!=79||performance!==12'hfff)$fatal(1,"MIDI display/guide mapping");
 for(k=0;k<32;k=k+1)if(dut.audio.u_alloc.sources[k]!==1)$fatal(1,"MIDI source tag missing");
 // 已满32槽时本地C4正常抢占一槽；放开本地C4不得关闭仍按住的MIDI C4。
 buttons=16'h0001;frames(550);count60;
 if(local60!=1||midi60!=1)$fatal(1,"MIDI/local same pitch did not allocate separately");
 buttons=0;frames(550);count60;
 if(local60!=0||midi60!=1)$fatal(1,"local off released MIDI same pitch");
 message(8'hb0,64,127);
 byte_midi(8'h80);for(k=0;k<32;k=k+1)begin byte_midi(48+k);byte_midi(0);end
 frames(20);count60;
 if(midi60!=1||dut.input_hub.performance.held!=0)$fatal(1,"sustain did not retain released MIDI note");
 message(8'hb0,64,0);frames(40);
 if(dut.audio.gate!=0)$fatal(1,"pedal up left gated notes");
 byte_midi(8'hc0);byte_midi(1);frames(4);
 if(selected!=1)$fatal(1,"MIDI PC did not update physical timbre selector");
 message(8'he0,127,127);
 if(dut.input_hub.slider_pitch!==9'sd255)$fatal(1,"MIDI bend max not integrated");
 message(8'he0,0,64);
 if(dut.input_hub.slider_pitch!==0)$fatal(1,"MIDI bend center not integrated");
 message(8'h90,69,127);frames(100);
 message(8'hb0,120,0);frames(8);
 if(dut.audio.gate!=0||busy!=0||pcm!=0)$fatal(1,"MIDI panic did not clear global audio");
 // 实体组合进入32路验证，期间MIDI演奏不能污染普通分配器。
 buttons=16'h5000;frames(700);buttons=0;frames(700);
 if(!owned||!mode||testgate!==32'hffffffff||testbusy!==32'hffffffff)$fatal(1,"MIDI build broke 32-mode entry");
 message(8'h90,65,127);frames(20);
 if(dut.audio.gate!=0||dut.audio.monitor_pitch!=0)$fatal(1,"MIDI leaked into32 verification");
 buttons=16'h8000;frames(500);buttons=0;frames(600);
 if(owned||mode)$fatal(1,"MIDI build cannot exit32 mode");
 message(8'h80,65,0);message(8'h90,67,110);frames(100);
 if(dut.audio.gate==0||pcm==0)$fatal(1,"MIDI cannot play after32 return");
 message(8'h80,67,0);frames(32);
 if(dut.audio.gate!=0)$fatal(1,"MIDI off after32 return lost");
 $display("MIDI_AUDIO_INTEGRATION_TEST_PASS full32=1 same_pitch_source_isolation=1 sustain=1 program=1 volume=1 bend=1 panic=1 test32_isolation=1 nonzero_pcm=%0d",nonzero);$finish;
 end
 initial begin #500000000;$fatal(1,"MIDI_AUDIO_INTEGRATION watchdog");end
endmodule
