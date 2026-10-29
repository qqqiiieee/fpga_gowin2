`timescale 1ns/1ps
module tb_remote_top;
  reg clk=0;always #5 clk=~clk;
  reg rx=1;
  reg [15:0] physical_keys=0;
  tri [3:0] rows;wire [3:0] cols;
  genvar c;
  generate for(c=0;c<4;c=c+1) begin
    assign cols[c]=!(((rows[0]===1'b0)&&physical_keys[c]) ||
                    ((rows[1]===1'b0)&&physical_keys[c+4]) ||
                    ((rows[2]===1'b0)&&physical_keys[c+8]) ||
                    ((rows[3]===1'b0)&&physical_keys[c+12]));
  end endgenerate
  tri1 scl,sda;wire bck,ws,din,pa,tx;wire [3:0] leds;
  instrument_audio_top #(.TEST_HOLD_SAMPLES(32),.TEST_MAX_SAMPLES(200000),.TEST_RAMP_DIV(1)) dut(.clk(clk),.matrix_rows(rows),.matrix_cols(cols),.hp_bck(bck),.hp_ws(ws),
    .hp_din(din),.pa_en(pa),.amp_bck(),.amp_lrc(),.amp_din(),
    .adc_scl(scl),.adc_sda(sda),.timbre_led_n(leds),.uart_rx(rx),.uart_tx(tx));
  tri [3:0] old_rows;tri1 old_scl,old_sda;
  wire old_bck,old_ws,old_din,old_pa,old_tx;wire [3:0] old_leds;
  legacy_top baseline(.clk(clk),.matrix_rows(old_rows),.matrix_cols(cols),
    .hp_bck(old_bck),.hp_ws(old_ws),.hp_din(old_din),.pa_en(old_pa),
    .amp_bck(),.amp_lrc(),.amp_din(),.adc_scl(old_scl),.adc_sda(old_sda),
    .timbre_led_n(old_leds),.uart_rx(rx),.uart_tx(old_tx));
  defparam baseline.link.CLK_HZ=100000;
  defparam baseline.link.BAUD=10000;
  defparam baseline.link.TIMEOUT_CYCLES=1500000;
  defparam baseline.u_keypad.ROW_CYCLES=4;
  defparam baseline.u_keypad.DEBOUNCE_FRAMES=2;
  defparam baseline.pads.CAL_SAMPLES=2;
  integer compared_cycles=0;reg test_started=0;
  always @(posedge clk) begin
    #1;
    if(dut.rst_n && baseline.rst_n && !test_started) begin
      if({rows,bck,ws,din,pa,tx,leds} !== {old_rows,old_bck,old_ws,old_din,old_pa,old_tx,old_leds})
        $fatal(1,"refactored top output differs from V008 at cycle %0d",compared_cycles);
      compared_cycles=compared_cycles+1;
    end
  end
  defparam dut.input_hub.link.CLK_HZ=100000;
  defparam dut.input_hub.link.BAUD=10000;
  defparam dut.input_hub.link.TIMEOUT_CYCLES=1500000;
  defparam dut.input_hub.u_keypad.ROW_CYCLES=4;
  defparam dut.input_hub.u_keypad.DEBOUNCE_FRAMES=2;
  defparam dut.input_hub.pads.CAL_SAMPLES=2;
  integer hits0=0,hits1=0,note_events=0,virtual_notes=0,nonzero=0;
  always @(posedge clk) begin
    if(dut.hit0) hits0=hits0+1;
    if(dut.hit1) hits1=hits1+1;
    if(dut.note_on) note_events=note_events+1;
    if(dut.note_on && dut.input_hub.remote_active && dut.note==60) virtual_notes=virtual_notes+1;
    if(dut.audio.fs_tick && dut.audio.headphone_sample!=0) nonzero=nonzero+1;
  end
  task byte_send;
    input [7:0] data;integer i;
    begin
      @(negedge clk);rx=0;repeat(10) @(negedge clk);
      for(i=0;i<8;i=i+1) begin rx=data[i];repeat(10) @(negedge clk);end
      rx=1;repeat(10) @(negedge clk);
    end
  endtask
  reg [7:0] packet[0:15];
  task command;
    input [7:0] seq,flags;
    input [15:0] keys,a0,a1,a2,a3;
    integer i;reg [7:0] check;
    begin
      packet[0]=8'ha5;packet[1]=8'h5a;packet[2]=seq;packet[3]=flags;
      packet[4]=keys[7:0];packet[5]=keys[15:8];packet[6]=160;
      packet[7]=a0[7:0];packet[8]=a0[15:8];packet[9]=a1[7:0];packet[10]=a1[15:8];
      packet[11]=a2[7:0];packet[12]=a2[15:8];packet[13]=a3[7:0];packet[14]=a3[15:8];
      check=0;for(i=2;i<15;i=i+1) check=check^packet[i];packet[15]=check;
      for(i=0;i<16;i=i+1) byte_send(packet[i]);
      // Let the ACK finish before the next command, matching the host protocol.
      repeat(1800) @(posedge clk);
      if(dut.input_hub.link.last_seq!==seq) $fatal(1,"command not accepted, seq=%0d",seq);
    end
  endtask
  initial begin
    repeat(1000) @(posedge clk);
    if(dut.input_hub.remote_active!==0 || pa!==1) $fatal(1,"unsafe startup");
    command(1,0,0,0,0,20000,13107);
    if(dut.input_hub.remote_active!==0) $fatal(1,"status handshake activated controls");
    physical_keys=16'h0002;
    command(2,1,16'h0001,0,0,20000,13107);
    repeat(600000) @(posedge clk);
    if(dut.key_state!==16'h0001) $fatal(1,"remote matrix override failed");
    if(nonzero==0 || virtual_notes==0) $fatal(1,"virtual note did not reach real PCM path");
    if(!dut.input_hub.pads_ready || dut.adc_fault || !dut.input_hub.sliders_ready) $fatal(1,"virtual ADC did not bypass physical fault");
    if(dut.slider_volume<190 || dut.slider_pitch!=0) $fatal(1,"virtual slider mapping failed");
    command(3,1,16'h0001,6000,0,20000,13107);
    repeat(220000) @(posedge clk);
    if(hits0!=1 || hits1!=0) $fatal(1,"virtual pressure attack failed");
    repeat(8) begin
      command(4,1,16'h0001,0,0,5000,13107);
      repeat(500000) @(posedge clk);
    end
    if(dut.slider_volume>60) $fatal(1,"volume sweep did not reach controls");
    command(5,1,16'h0001,6000,0,20000,13107);
    repeat(220000) @(posedge clk);
    if(hits0!=2) $fatal(1,"pressure did not rearm after release");
    command(6,3,16'h0001,0,0,20000,13107);
    repeat(10000) @(posedge clk);
    if(dut.audio.headphone_sample!==0 || din!==0) $fatal(1,"remote PCM zero failed");
    command(7,0,0,0,0,20000,13107);
    repeat(200) @(posedge clk);
    if(dut.input_hub.remote_active || dut.input_hub.remote_zero || dut.key_state!==physical_keys)
      $fatal(1,"physical control fallback failed");
    physical_keys=0;
    // 模块拆分后的音色选择与滤波组合也必须和 V008 保持一致。
    command(8,1,16'h1000,0,0,20000,13107);
    command(9,1,0,0,0,20000,13107);
    command(10,1,16'h1000,0,0,20000,13107);
    command(11,1,0,0,0,20000,13107);
    if(dut.selected_timbre!==1) $fatal(1,"selector release no longer advances timbre");
    command(12,1,16'h6000,0,0,20000,13107);
    if(dut.filter_enable!==0) $fatal(1,"filter A/B shortcut no longer toggles");
    command(13,1,0,0,0,20000,13107);
    if(dut.selected_timbre!==1) $fatal(1,"diagnostic chord changed selected timbre");
    command(14,1,16'h0001,0,0,20000,13107);
    repeat(1510000) @(posedge clk);
    if(dut.input_hub.remote_active || dut.input_hub.remote_keys!==0 || dut.key_state!==0)
      $fatal(1,"watchdog left a virtual note held");
    // 以真实串口包进入验证模式；省略原KEYS层不足32键的限制。
    test_started=1;
    command(20,1,16'h5000,0,0,20000,13107);
    repeat(200000) @(posedge clk);
    command(21,1,16'd0,0,0,20000,13107);
    repeat(250000) @(posedge clk);
    if(!dut.test_owned || !dut.test_mode || dut.test_requested!=32 ||
       dut.monitor_test_busy!==32'hffffffff || dut.overrun)
      $fatal(1,"UART keys did not enter real full32 path");
    command(22,0,16'd0,0,0,0,0);
    repeat(220000) @(posedge clk);
    if(dut.test_owned || dut.test_mode || dut.input_hub.remote_active)
      $fatal(1,"DISABLED source change did not release diagnostic mode");
    $display("REMOTE_TOP_TEST_PASS hits0=%0d notes=%0d nonzero=%0d",hits0,note_events,nonzero);
    $display("TOP_EQUIVALENCE_TEST_PASS compared_cycles=%0d",compared_cycles);
    $finish;
  end
  initial begin #100000000;$fatal(1,"test exceeded bounded deadline");end
endmodule
