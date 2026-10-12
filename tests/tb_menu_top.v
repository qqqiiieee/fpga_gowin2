`timescale 1ns/1ps
// Production-top wiring test: menu commands really reach EXTERNAL_UI song_guide.
// Keys are injected AFTER scan/debounce; pin mapping is independently tested by
// tb_keypad_physical_map. No claim that this injection is a board key press.
module tb_menu_top;
 reg clk=0;always #18.518519 clk=~clk;
 reg [15:0] injected_keys=0;
 wire [3:0] rows,led;
 tri scl,sda;pullup(scl);pullup(sda);
 wire bck,ws,din,pa,ab,al,ad,tx,cp,cn;wire [2:0] dp,dn;
 top #(.UI_HOLD_SAMPLES(4)) dut(.clk(clk),.matrix_rows(rows),.matrix_cols(4'hf),
  .hp_bck(bck),.hp_ws(ws),.hp_din(din),.pa_en(pa),.amp_bck(ab),.amp_lrc(al),.amp_din(ad),
  .adc_scl(scl),.adc_sda(sda),.timbre_led_n(led),.uart_rx(1'b1),.uart_tx(tx),
  .tmds_clk_p(cp),.tmds_clk_n(cn),.tmds_data_p(dp),.tmds_data_n(dn));
 GSR GSR(.GSRI(1'b1));
 integer checks=0;
 task hold_cycles;input [15:0] mask;input integer n;begin
  @(negedge clk);injected_keys=mask;repeat(n)@(posedge clk);#1;
 end endtask
 task tap;input [15:0] mask;begin hold_cycles(mask,20);hold_cycles(0,20);end endtask
 task check;input condition;input [511:0] msg;begin
  checks=checks+1;if(condition!==1'b1)$fatal(1,"MENU_TOP_FAIL %0s",msg);
 end endtask
 reg [5:0] previous_step;reg [7:0] previous_progress;
 initial begin
  force dut.keys=injected_keys;
  force dut.flags[6]=1'b0;force dut.flags[1]=1'b0;
  wait(dut.rst_n);hold_cycles(0,20);
  check(dut.ui_page==0 && dut.ui_song==0,"initial menu and selected song");
  tap(16'h4000);check(dut.ui_page==1,"S15 reaches library");
  tap(16'h8000);check(dut.ui_cursor==1,"S16 chooses Ode");
  hold_cycles(16'h8000,6*288);hold_cycles(0,20);
  check(dut.ui_page==0 && dut.ui_song==1,"long confirm returns live with ID1");
  check(dut.u_guide.selected_song==1 && dut.guide_active && !dut.guide_done,"start pulse latched ID1");
  check(dut.guide_total==32 && dut.cue_mask==12'h004 && dut.guide_step==0,"Ode starts E4");
  hold_cycles(16'h0004,288*4);
  previous_step=dut.guide_step;previous_progress=dut.beat_progress;
  // Transition to a menu key: single-key navigation pauses guide immediately.
  hold_cycles(16'h4000,288*4);
  check(dut.guide_step==previous_step && dut.beat_progress==previous_progress,"menu key preserves guide state");
  hold_cycles(0,20);check(dut.ui_page==0,"note-to-menu without all-up cancels navigation");
  tap(16'h4000);check(dut.ui_page==1,"fresh all-up S15 release page action");
  previous_step=dut.guide_step;previous_progress=dut.beat_progress;
  hold_cycles(0,288*4);check(dut.guide_step==previous_step && dut.beat_progress==previous_progress,"library freezes guide");
  tap(16'h8000);check(dut.ui_cursor==2,"library selects Tigers");
  hold_cycles(16'h8000,6*288);hold_cycles(0,20);
  check(dut.ui_song==2 && dut.u_guide.selected_song==2 && dut.guide_total==32 && dut.cue_mask==1,"Tigers starts C4");
  tap(16'h8000);check(!dut.guide_active,"single S16 toggles guide off");
  tap(16'h8000);check(dut.guide_active,"single S16 toggles guide on");
  hold_cycles(16'h8000,6*288);hold_cycles(0,20);
  check(dut.guide_active && dut.guide_step==0 && dut.ui_song==2,"long S16 restarts same song");
  tap(16'h9000);check(!dut.guide_active && dut.ui_page==0,"legacy guide chord is not swallowed by pause");
  tap(16'h3000);check(dut.guide_active && dut.ui_page==0,"legacy restart chord survives two selectors");
  tap(16'h4000);tap(16'h4000);tap(16'h4000);
  check(dut.ui_page==3,"three taps reaches wiring diagnostic");
  hold_cycles(16'h0340,20);check(dut.keys[9] && dut.keys[8] && dut.keys[6],"diagnostic bits S10 S9 S7");
  hold_cycles(0,20);tap(16'h4000);check(dut.ui_page==0,"diagnostic returns live");
  check(pa===1'b1 && dut.u_audio.audio.synth.NUM_VOICES==32,"audio routing remains enabled");
  $display("MENU_TOP_TEST_PASS checks=%0d source-domain production menu/song wiring",checks);$finish;
 end
 initial begin #10000000;$fatal(1,"Menu top test timeout");end
endmodule
