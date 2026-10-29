`timescale 1ns/1ps
// MCP串行模型→模拟解码→真实键盘状态机→声部分配/合成/耳机PCM，验证实际连接。
module tb_touch_integration;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 wire[3:0] rows;reg[3:0] cols=15;tri1 scl,sda;
 wire cs,sck,mosi;reg miso=0;reg[11:0] sensor=0,latched=0;
 reg[23:0] command;integer edges=0,transfers=0;
 wire on_evt,off_evt,ghost;wire[6:0] note;wire[7:0] velocity,vol,v0,v1;
 wire[3:0] timbre,selected;wire[15:0] keys;wire signed[8:0] pitch;
 wire h0,h1,z,fault,stale,ready,remote,filter;wire[63:0] adc;
 wire tick;wire[15:0] pcm;wire[31:0] busy;wire overrun;
 wire [1:0] note_source,pressure_calibrated;wire panic_audio;wire[7:0] brightness,vibrato;
 integer ons=0,offs=0,pcm_nonzero=0;reg[6:0] last_note;
 reg[11:0] centers[0:15];
 instrument_inputs #(.TOUCH_ENABLE(1),.MIDI_ENABLE(1),.OPTICAL_ENABLE(1),.PRESSURE_EXPRESSION_ENABLE(1)) inputs(
 .clk(clk),.rst_n(rst_n),.matrix_rows(rows),.matrix_cols(cols),.adc_scl(scl),.adc_sda(sda),
 .uart_rx(1'b1),.uart_tx(),.synth_overrun(overrun),.suppress_controls(1'b0),
 .note_on(on_evt),.note_off(off_evt),.note(note),.velocity(velocity),.timbre(timbre),
 .key_state(keys),.selected_timbre(selected),.keypad_ghost(ghost),
 .slider_volume(vol),.slider_pitch(pitch),.hit0(h0),.hit1(h1),.velocity0(v0),.velocity1(v1),
 .digital_zero_test(z),.adc_fault(fault),.adc_stale(stale),.monitor_ready(ready),
 .monitor_remote(remote),.monitor_adc(adc),.touch_cs_n(cs),.touch_sclk(sck),.touch_mosi(mosi),.touch_miso(miso),
 .midi_rx(1'b1),.optical_beams(2'b11),.sample_tick(tick),.allow_performance(1'b1),
 .note_source(note_source),.panic_audio(panic_audio),.performance_keys(),.external_note(),.external_note_valid(),
 .pressure_brightness(brightness),.pressure_vibrato(vibrato),.pressure_calibrated(pressure_calibrated));
 instrument_audio #(.REDUCED_TIMBRES(1),.PHASE_RAM(1),.SOURCE_TAG_ENABLE(1),.PRESSURE_EXPRESSION_ENABLE(1)) audio(
 .clk(clk),.rst_n(rst_n),.note_on(on_evt),.note_off(off_evt),.note(note),.velocity(velocity),.timbre(timbre),
 .slider_volume(vol),.slider_pitch(pitch),.hit0(h0),.hit1(h1),.velocity0(v0),.velocity1(v1),
 .digital_zero_test(z),.filter_enable(1'b1),.test_owned(1'b0),.test_mode(1'b0),.test_clear(panic_audio),
 .event_source(note_source),.normal_input_ready(1'b1),.test_gate_mask(32'd0),.test_master_gain(9'd256),
 .hp_bck(),.hp_ws(),.hp_din(),.overrun(overrun),.monitor_tick(tick),.monitor_pcm(pcm),
 .monitor_pitch(),.monitor_busy(busy),.monitor_test_busy(),
 .pressure_brightness(brightness),.pressure_brightness_ready(pressure_calibrated[0]));
 always@(negedge cs)begin latched=sensor;edges=0;command=0;miso=0;end
 always@(posedge sck)if(!cs)begin command={command[22:0],mosi};edges=edges+1;end
 always@(negedge sck)if(!cs)begin
  if(edges>=12&&edges<24)miso=latched[23-edges];else miso=0;
 end
 always@(posedge cs)if(rst_n&&edges!=0)begin
  if(edges!=24||command!==24'h060000)$fatal(1,"TOUCH integration wrong MCP command %h edges=%0d",command,edges);
  transfers=transfers+1;
 end
 always@(posedge clk)begin #1;
 if(rst_n)begin
  if(on_evt)begin ons=ons+1;last_note=note;end
  if(off_evt)offs=offs+1;
  if(tick&&pcm!=0)pcm_nonzero=pcm_nonzero+1;
  if(ghost||overrun)$fatal(1,"TOUCH integration ghost/overrun");
 end end
 task hold_sample;input[11:0] code;begin sensor=code;repeat(190000)@(negedge clk);end endtask
 initial begin
 $readmemh("src/touch_centers.hex",centers);
 repeat(5)@(negedge clk);rst_n=1;hold_sample(0);
 if(keys!=0||ons!=0)$fatal(1,"TOUCH idle sounded");
 hold_sample(centers[0]);
 if(keys!==16'h0001||ons!=1||last_note!=60||pcm_nonzero<10)$fatal(1,"TOUCH S1 not audible keys=%h ons=%0d pcm=%0d",keys,ons,pcm_nonzero);
 hold_sample(0);if(keys!=0||offs!=1)$fatal(1,"TOUCH release S1");
 hold_sample(centers[4]);if(keys!==16'h0010||ons!=2||last_note!=67)$fatal(1,"TOUCH S5 row mapping");
 hold_sample(0);
 hold_sample(centers[13]);if(ons!=2)$fatal(1,"TOUCH control key sounded");
 hold_sample(0);if(selected!=1)$fatal(1,"TOUCH next timbre");
 hold_sample(4095);if(keys!=0||ons!=2)$fatal(1,"TOUCH full scale must not be a key");
 if(transfers<200||pcm_nonzero<30||offs!=2)$fatal(1,"TOUCH insufficient coverage");
 $display("TOUCH_INTEGRATION_TEST_PASS spi_transfers=%0d note_on=%0d note_off=%0d nonzero_pcm=%0d timbre=1 ADC_fault_does_not_block_notes=1",transfers,ons,offs,pcm_nonzero);$finish;
 end
 initial begin #30000000;$fatal(1,"TOUCH integration watchdog");end
endmodule
