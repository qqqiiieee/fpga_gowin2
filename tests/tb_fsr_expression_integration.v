`timescale 1ns/1ps
// 实际UART包->虚拟ADC定序->FSR连续控制->真实声部/PCM；只缩短输入采样/消抖计数。
module tb_fsr_expression_integration;
 reg clk=0,rx=1;always #18.518 clk=~clk;
 wire[3:0] rows;tri1 scl,sda;wire tick,rst,owned,mode;wire[15:0] pcm,keys;
 wire[7:0] e0,e1,volume;wire[1:0] calibrated;wire signed[8:0] pitch;
 wire[31:0] busy;wire[7:0] flags;wire[31:0] testbusy;
 integer h0=0,h1=0,notes=0,frames=0,pcm_frames=0;
 integer pitch_min=1000,pitch_max=-1000;
 reg[7:0] packet[0:15];
 instrument_audio_top #(.PRESSURE_EXPRESSION_ENABLE(1),.PHASE_RAM(1),
 .MIDI_ENABLE(1),.OPTICAL_ENABLE(1),.VIRTUAL_ADC_CYCLES(128),
 .TEST_HOLD_SAMPLES(4),.TEST_MAX_SAMPLES(500000),.TEST_RAMP_DIV(1)) dut(
 .clk(clk),.matrix_rows(rows),.matrix_cols(4'b1111),.adc_scl(scl),.adc_sda(sda),
 .uart_rx(rx),.uart_tx(),.hp_bck(),.hp_ws(),.hp_din(),.pa_en(),.amp_bck(),.amp_lrc(),.amp_din(),.timbre_led_n(),
 .monitor_rst_n(rst),.monitor_tick(tick),.monitor_pcm(pcm),.monitor_keys(keys),.monitor_timbre(),
 .monitor_volume(volume),.monitor_pitch(pitch),.monitor_busy(busy),.monitor_flags(flags),.monitor_adc(),
 .monitor_test_owned(owned),.monitor_test_mode(mode),.monitor_test_gate(),.monitor_test_busy(testbusy),
 .monitor_test_requested(),.monitor_test_sweep(),.monitor_test_index(),
 .touch_cs_n(),.touch_sclk(),.touch_mosi(),.touch_miso(1'b0),.midi_rx(1'b1),.optical_beams(2'b11),
 .monitor_performance_keys(),.monitor_external_note(),.monitor_external_note_valid(),
 .monitor_expression0(e0),.monitor_expression1(e1),.monitor_pressure_calibrated(calibrated));
 defparam dut.input_hub.link.CLK_HZ=100000;
 defparam dut.input_hub.link.BAUD=10000;
 defparam dut.input_hub.link.TIMEOUT_CYCLES=8000000;
 defparam dut.input_hub.u_keypad.ROW_CYCLES=4;
 defparam dut.input_hub.u_keypad.DEBOUNCE_FRAMES=2;
 always@(posedge clk)begin #1;
   if(rst)begin
     if(dut.hit0)h0=h0+1;if(dut.hit1)h1=h1+1;if(dut.note_on)notes=notes+1;
     if(dut.overrun)$fatal(1,"synth overrun");
     if(tick)begin frames=frames+1;if(pcm!=0)pcm_frames=pcm_frames+1;end
   end
 end
 task clocks;input integer n;begin repeat(n)@(negedge clk);end endtask
 task byte_send;input[7:0] data;integer b;begin
   @(negedge clk);rx=0;clocks(10);
   for(b=0;b<8;b=b+1)begin rx=data[b];clocks(10);end
   rx=1;clocks(10);
 end endtask
 task command;input[7:0] seq,options;input[15:0] key,a0,a1,a2,a3;integer b;reg[7:0] check;begin
   packet[0]=8'ha5;packet[1]=8'h5a;packet[2]=seq;packet[3]=options;
   packet[4]=key[7:0];packet[5]=key[15:8];packet[6]=180;
   packet[7]=a0[7:0];packet[8]=a0[15:8];packet[9]=a1[7:0];packet[10]=a1[15:8];
   packet[11]=a2[7:0];packet[12]=a2[15:8];packet[13]=a3[7:0];packet[14]=a3[15:8];
   check=0;for(b=2;b<15;b=b+1)check=check^packet[b];packet[15]=check;
   for(b=0;b<16;b=b+1)byte_send(packet[b]);clocks(1800);
   if(dut.input_hub.link.last_seq!==seq)$fatal(1,"UART command not accepted");
 end endtask
 task sample_frames;input integer n;integer f;begin
   for(f=0;f<n;f=f+1)begin @(posedge tick);@(negedge clk);end
 end endtask
 integer f,saved_notes,saved_pcm;
 initial begin
   clocks(1000);
   command(1,1,0,1000,2000,20000,13107);clocks(12000);
   if(calibrated!==3 || e0!==0 || e1!==0)$fatal(1,"FSR resting calibration");
   command(2,1,0,6000,7000,20000,13107);clocks(16000);
   if(e0!=255 || e1!=255 || h0!=0 || h1!=0 || notes!=0 || pcm!=0)
     $fatal(1,"pressure alone generated notes/drums or failed levels e0=%d e1=%d",e0,e1);
   // 压住后保持不被动态基线吞掉；原滑杆仍拥有音量/基础音高。
   clocks(100000);if(e0!=255 || e1!=255)$fatal(1,"held pressure decayed");
   command(3,1,1,6000,7000,20000,13107);
   sample_frames(512);if(notes!=1 || busy==0 || pcm_frames<20 || volume<185)$fatal(1,"key/volume path failed");
   saved_notes=notes;saved_pcm=pcm_frames;
   // 压力满值产生正负揉弦；真实93750Hz控制tick，无修改LFO常数。
   for(f=0;f<17000;f=f+1)begin
     @(posedge tick);@(negedge clk);
     if($signed(pitch)<pitch_min)pitch_min=$signed(pitch);
     if($signed(pitch)>pitch_max)pitch_max=$signed(pitch);
   end
   if(pitch_min> -95 || pitch_max<95)$fatal(1,"weak vibrato range min=%d max=%d",pitch_min,pitch_max);
   if(notes!=saved_notes || h0 || h1 || pcm_frames<=saved_pcm)$fatal(1,"FSR changed note events or caused drums");
   command(4,1,1,1000,2000,5000,13107);sample_frames(1800);
   if(e0!=0 || e1!=0 || $signed(pitch)!=0 || volume>55)$fatal(1,"release or volume slider lost");
   command(5,1,1,1000,2000,5000,20000);sample_frames(1800);
   if($signed(pitch)<40)$fatal(1,"pitch slider removed");
   command(6,1,0,1000,2000,20000,13107);sample_frames(1800);
   if(notes!=1 || h0 || h1)$fatal(1,"normal release generated attack");
   // 原32频测试进入后，不让压力改变测试音高或PCM路径。
   command(7,1,16'h5000,1000,2000,20000,13107);sample_frames(2500);
   if(!mode || !owned || testbusy!==32'hffffffff || pitch!==0)$fatal(1,"32-tone mode entry failed");
   command(8,1,0,6000,7000,20000,13107);sample_frames(1500);
   if(e0!=255 || e1!=255 || pitch!==0 || testbusy!==32'hffffffff)$fatal(1,"pressure polluted 32-tone mode");
   command(9,3,0,6000,7000,20000,13107);sample_frames(30);
   if(pcm!==0)$fatal(1,"digital zero failed with pressure");
   $display("FSR_EXPRESSION_INTEGRATION_TEST_PASS no_FSR_drums=1 levels=255 continuous=1 sliders=1 real_PCM=1 vibrato_min=%0d vibrato_max=%0d test32_isolated=1",pitch_min,pitch_max);$finish;
 end
 initial begin #1000000000;$fatal(1,"FSR expression integration timeout");end
endmodule
