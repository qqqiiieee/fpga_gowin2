module tb_audio_hdmi_equivalence;
 reg clk=0;always #18.518519 clk=~clk;
 reg [15:0] physical_keys=0;
 wire [3:0] rows,ref_rows,cols,ref_cols;
 genvar c;
 generate for(c=0;c<4;c=c+1)begin
  assign cols[c]=!(((rows[0]===1'b0)&&physical_keys[c]) ||
   ((rows[1]===1'b0)&&physical_keys[c+4]) ||
   ((rows[2]===1'b0)&&physical_keys[c+8]) ||
   ((rows[3]===1'b0)&&physical_keys[c+12]));
  assign ref_cols[c]=!(((ref_rows[0]===1'b0)&&physical_keys[c]) ||
   ((ref_rows[1]===1'b0)&&physical_keys[c+4]) ||
   ((ref_rows[2]===1'b0)&&physical_keys[c+8]) ||
   ((ref_rows[3]===1'b0)&&physical_keys[c+12]));
 end endgenerate
 tri1 scl,sda,ref_scl,ref_sda;
 wire bck,ws,din,pa,tx,rbck,rws,rdin,rpa,rtx,cp,cn;
 wire [2:0] dp,dn;
 wire [3:0] leds,rleds;
 top dut(.clk(clk),.matrix_rows(rows),.matrix_cols(cols),
  .hp_bck(bck),.hp_ws(ws),.hp_din(din),.pa_en(pa),
  .amp_bck(),.amp_lrc(),.amp_din(),.adc_scl(scl),.adc_sda(sda),
  .timbre_led_n(leds),.uart_rx(1'b1),.uart_tx(tx),
  .tmds_clk_p(cp),.tmds_clk_n(cn),.tmds_data_p(dp),.tmds_data_n(dn));
 baseline_audio_top reference(.clk(clk),.matrix_rows(ref_rows),.matrix_cols(ref_cols),
  .hp_bck(rbck),.hp_ws(rws),.hp_din(rdin),.pa_en(rpa),
  .amp_bck(),.amp_lrc(),.amp_din(),.adc_scl(ref_scl),.adc_sda(ref_sda),
  .timbre_led_n(rleds),.uart_rx(1'b1),.uart_tx(rtx));
 defparam dut.u_audio.input_hub.u_keypad.ROW_CYCLES=16;
 defparam dut.u_audio.input_hub.u_keypad.DEBOUNCE_FRAMES=2;
 defparam reference.input_hub.u_keypad.ROW_CYCLES=16;
 defparam reference.input_hub.u_keypad.DEBOUNCE_FRAMES=2;
 GSR GSR(.GSRI(1'b1));
 integer count=0,nonzero=0;
 always @(negedge clk)if(dut.rst_n)begin
  count=count+1;
  if({bck,ws,din,pa,tx,leds}!={rbck,rws,rdin,rpa,rtx,rleds})
   $fatal(1,"HDMI integration changed existing audio/output pins");
  if(rows!==ref_rows || scl!==ref_scl || sda!==ref_sda)
   $fatal(1,"HDMI integration changed matrix/I2C electrical outputs");
  if(dut.pcm!==reference.audio.headphone_sample)$fatal(1,"PCM differs from V009 baseline");
  if(dut.sample_tick && dut.pcm!=0)nonzero=nonzero+1;
  if(dut.u_audio.overrun)$fatal(1,"audio frame deadline missed");
 end
 initial begin
  repeat(1000)@(negedge clk);
  physical_keys=16'h0020;repeat(120000)@(negedge clk);
  if(dut.hz!=440 || dut.note!=69 || !dut.note_valid)$fatal(1,"A4 telemetry not connected");
  physical_keys=16'h0021;repeat(120000)@(negedge clk);
  if(dut.note!=60 || dut.hz!=262)$fatal(1,"chord priority setting wrong");
  physical_keys=0;repeat(120000)@(negedge clk);
  if(dut.note_valid)$fatal(1,"released key still has primary setting");
  repeat(150000)@(negedge clk);
  if(count<500000 || nonzero<100)$fatal(1,"insufficient audio regression coverage");
  if(!dut.pll_locked || !dut.u_display.scope_valid)$fatal(1,"HDMI and real waveform not running with audio");
  if(dut.u_display.d_step!=1)$fatal(1,"guide display must start at step1 rather than zero");
  if(cn!==!cp || dn!==~dp || (^{cp,cn,dp,dn})===1'bx)$fatal(1,"invalid HDMI pins");
  $display("AUDIO_HDMI_EQUIVALENCE_TEST_PASS cycles=%0d nonzero_pcm=%0d",count,nonzero);$finish;
 end
 initial begin #30000000;$fatal(1,"audio HDMI equivalence timeout");end
endmodule
