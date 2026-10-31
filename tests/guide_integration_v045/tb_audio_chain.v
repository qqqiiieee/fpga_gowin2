`timescale 1ns/1ps
// Entire unmodified audio_top/input_hub/performance/parser/allocator chain.
// MIDI is genuine 31250 baud, 864 clocks per bit. The existing helper provides
// the clock and UART pin driver; its separate legacy DUT is not the oracle.
module tb_audio_chain;
 midi_test_driver #(.CLK_HZ(27000000)) d();
 tri1 scl,sda;
 reg map_write=0,map_commit=0,map_enable=0,panic_ui=0,zero_ui=0;
 reg [7:0] map_addr=188;reg [6:0] map_data=72;
 reg demo_valid=0,demo_retrigger=0;reg [6:0] demo_note=72;
 wire rst,receipt,write_ready,commit_ready,commit_ack;wire [6:0] raw_note;
 integer receipts=0,checks=0,event_count=0,cycles=0,i,j,n,live_gates,demo_gates,last_raw=0;
 reg [1:0] log_source[0:255];reg log_on[0:255];reg [6:0] log_note[0:255];
 instrument_audio_top #(.MIDI_ENABLE(1),.MAPPING_ENABLE(1),.GUIDE_MODES_ENABLE(1),
  .DISPLAY_TOUCH_ONLY(1),.PHASE_RAM(1),.LIVE_ADSR_ENABLE(1),.PANEL_TEST_ENABLE(1)) dut(
  .clk(d.clk),.matrix_cols(4'hf),.adc_scl(scl),.adc_sda(sda),.uart_rx(1'b1),
  .monitor_rst_n(rst),.touch_miso(1'b0),.midi_rx(d.rx),.optical_beams(2'b11),
  .ui_test_keys(16'd0),.ui_panic(panic_ui),.ui_strum_mode(2'd0),
  .ui_timbre_set_valid(1'b0),.ui_timbre_set_value(4'd0),.ui_filter_enable(1'b0),
  .ui_zero_mode(zero_ui),.control_page(2'd0),.ui_fx_cycle(1'b0),
  .phone_set_valid(1'b0),.phone_param(8'd0),.phone_value(8'd0),.phone_query_param(8'd0),
  .ui_test_enter(1'b0),.ui_test_exit(1'b0),.ui_test_count_valid(1'b0),.ui_test_count(6'd0),
  .ui_test_sweep_start(1'b0),.mapping_enable(map_enable),.mapping_bank(1'b1),.mapping_commit(map_commit),
  .mapping_wr_en(map_write),.mapping_wr_addr(map_addr),.mapping_wr_data(map_data),
  .mapping_pad_notes({7'd39,7'd37,7'd38,7'd36}),.mapping_cc_numbers({7'd74,7'd71,7'd91,7'd93}),
  .mapping_wr_ready(write_ready),.mapping_commit_ready(commit_ready),.mapping_commit_ack(commit_ack),
  .monitor_note_receipt(receipt),.monitor_raw_note(raw_note),
  .guide_demo_valid(demo_valid),.guide_demo_retrigger(demo_retrigger),.guide_demo_note(demo_note));
 always @(posedge d.clk)begin
  cycles=cycles+1;
  if(rst)begin
   if(receipt!==dut.input_hub.monitor_note_receipt ||
      receipt!==dut.input_hub.performance.monitor_note_receipt)$fatal(1,"receipt chain mismatch");
   if(receipt)begin
    receipts=receipts+1;last_raw=raw_note;
    if(!dut.input_hub.performance.midi_input.keyboard.rx_valid ||
       !dut.input_hub.performance.midi_input.keyboard.receipt_note_on ||
       raw_note!==dut.input_hub.performance.midi_input.keyboard.receipt_note)
      $fatal(1,"receipt delayed/remapped on audio_top chain");
   end
   if(dut.audio.note_on || dut.audio.note_off)begin
    log_source[event_count]=dut.audio.event_source;log_on[event_count]=dut.audio.note_on;
    log_note[event_count]=dut.audio.note;event_count=event_count+1;
    if((dut.note_on||dut.note_off) && (dut.demo_on||dut.demo_off))$fatal(1,"demo collides with live");
   end
   #1;live_gates=0;demo_gates=0;
   for(j=0;j<32;j=j+1)if(dut.audio.gate[j])begin
    if(dut.audio.u_alloc.sources[j]==1)live_gates=live_gates+1;
    if(dut.audio.u_alloc.sources[j]==3)demo_gates=demo_gates+1;
   end
   if(demo_gates>1)$fatal(1,"full chain demo gate accumulation");
  end
 end
 task check(input c,input [1023:0] msg);
  begin checks=checks+1;if(c!==1'b1)$fatal(1,"%0s receipt=%0d raw=%0d live=%0d demo=%0d",msg,receipts,last_raw,live_gates,demo_gates);end
 endtask
 task event_is(input integer idx,input [1:0] src,input onoff,input [6:0] pitch);
  check(event_count>idx && log_source[idx]===src && log_on[idx]===onoff && log_note[idx]===pitch,
        "full chain allocator event order/source/pitch");
 endtask
 initial begin
  d.reset;d.tick(10000);check(rst && dut.normal_input_ready,"real POR and normal input owner");
  check(write_ready && commit_ready,"mapper initially ready");
  map_write=1;d.tick(1);map_write=0;d.tick(2);map_enable=1;map_commit=1;
  d.tick(1);check(commit_ack,"real mapper commit ack");map_commit=0;d.tick(10);
  n=event_count;d.msg(8'h90,60,100);
  check(receipts==1 && last_raw==60 && live_gates==1,"mapped audio note preserves raw receipt60");
  event_is(n,1,1,72);
  demo_valid=1;d.tick(3);check(demo_gates==1 && live_gates==1,"same mapped MIDI/demo note coexist");
  for(i=0;i<16;i=i+1)begin
   n=event_count;demo_retrigger=1;d.tick(1);demo_retrigger=0;d.tick(3);
   event_is(n,3,0,72);event_is(n+1,3,1,72);
   check(demo_gates==1 && live_gates==1,"real audio allocator retrigger no accumulation");
  end
  $display("CASE_PASS audio_chain_raw_receipt_mapped_note_and_source3_retrigger");
  n=event_count;
  fork
   begin d.msg(8'h90,61,100);end
   begin
    wait(dut.note_on===1'b1);@(negedge d.clk);demo_note=65;
    d.tick(4);
   end
  join
  event_is(n,1,1,61);event_is(n+1,3,0,72);event_is(n+2,3,1,65);
  check(receipts==2 && last_raw==61 && demo_gates==1 && live_gates==2,"full chain live priority reconciliation");
  demo_valid=0;d.tick(4);check(demo_gates==0 && live_gates==2,"demo cancel leaves both MIDI gates");
  d.msg(8'h90,60,0);d.msg(8'h80,61,0);d.tick(4);
  check(receipts==2 && dut.audio.gate==0,"zero velocity/off release mapped and normal MIDI without receipt");
  d.msg(8'h99,36,100);check(receipts==2,"drum excluded at audio_top");
  zero_ui=1;d.tick(8);d.msg(8'h90,62,100);check(receipts==2,"audio_top digital zero suppresses receipt");
  zero_ui=0;d.tick(8);d.msg(8'h80,62,0);d.msg(8'h90,62,100);
  check(receipts==3 && last_raw==62,"audio_top zero exit requires release/repress");
  demo_note=62;demo_valid=1;d.tick(3);check(demo_gates==1 && live_gates==1,"pre-panic live and demo");
  panic_ui=1;demo_valid=0;d.tick(2);panic_ui=0;d.tick(30);
  check(dut.audio.gate==0 && demo_gates==0,"panic clears allocator and cancelled guide stays silent");
  $display("V045_AUDIO_CHAIN_PASS checks=%0d receipts=%0d events=%0d repeats=16",checks,receipts,event_count);$finish;
 end
 initial begin #1000000000;$fatal(1,"audio chain timeout");end
endmodule
