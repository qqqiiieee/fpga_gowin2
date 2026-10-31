`timescale 1ns/1ps
// Real performance hub: local event priority creates actual MIDI FIFO pressure.
module tb_hub_receipt;
 midi_test_driver #(.CLK_HZ(27000000)) d();
 reg local_on=0,remote=0,zero=0,manual_panic=0;reg [1:0] strum=0;
 wire receipt,note_on,note_off;wire [6:0] raw,note;wire [1:0] source;
 integer receipts=0,midi_ons=0,checks=0,n,i;reg [6:0] last_raw=0;
 performance_input_hub #(.MIDI_ENABLE(1),.CONTROL_BANK_ENABLE(1)) dut(
  .clk(d.clk),.rst_n(d.rst_n),.sample_tick(1'b0),.allow_performance(!d.suppress),.suppress_controls(1'b0),
  .remote_active(remote),.digital_zero(zero),.midi_rx(d.rx),.optical_beams(2'b11),
  .local_on(local_on),.local_off(1'b0),.local_note(7'd40),.local_velocity(8'd100),
  .local_timbre(4'd0),.selected_timbre(4'd0),.local_keys(16'd0),.physical_volume(8'd160),.physical_pitch(9'd0),
  .note_on(note_on),.note_off(note_off),.note(note),.event_source(source),.pressure_vibrato(8'd0),
  .strum_mode(strum),.manual_panic(manual_panic),.knob_volume_valid(1'b0),.knob_volume(8'd0),
  .mapping_enable(1'b0),.mapping_bank(1'b0),.mapping_commit(1'b0),.mapping_wr_en(1'b0),
  .mapping_wr_addr(8'd0),.mapping_wr_data(7'd0),.mapping_pad_notes(28'd0),.mapping_cc_numbers(28'd0),
  .monitor_note_receipt(receipt),.monitor_raw_note(raw));
 always @(posedge d.clk)if(d.rst_n)begin
  if(receipt)begin
   receipts=receipts+1;last_raw=raw;
   if(!dut.midi_input.keyboard.rx_valid)$fatal(1,"hub receipt delayed");
  end
  if(note_on && source==1)midi_ons=midi_ons+1;
 end
 task check(input c,input [1023:0] msg);
  begin checks=checks+1;if(c!==1'b1)$fatal(1,"%0s receipts=%0d delivered=%0d",msg,receipts,midi_ons);end
 endtask
 initial begin
  d.reset;local_on=1;
  for(i=0;i<4;i=i+1)d.msg(8'h90,60+i,100);
  check(receipts==4 && midi_ons==0 && dut.midi_input.keyboard.fifo_count==4,"hub local priority cannot delay receipts");
  local_on=0;d.tick(12);check(midi_ons==4 && receipts==4,"hub drain no receipt replay");
  strum=1;d.tick(8);n=receipts;d.msg(8'h90,70,100);
  check(receipts==n+1 && last_raw==70 && midi_ons==4,"strum mode still reports physical note receipt");
  d.msg(8'h90,70,0);d.msg(8'h99,36,100);check(receipts==n+1,"hub zero velocity and drums excluded");
  for(i=0;i<4;i=i+1)begin
   n=receipts;
   case(i)0:d.suppress=1;1:remote=1;2:zero=1;3:manual_panic=1;endcase
   d.tick(8);d.msg(8'h90,75+i,100);check(receipts==n,"hub cancel/suppress receipt gating");
   d.suppress=0;remote=0;zero=0;manual_panic=0;d.tick(8);d.msg(8'h80,75+i,0);
  end
  $display("V045_HUB_RECEIPT_PASS checks=%0d receipts=%0d fifo_backpressure_notes=4",checks,receipts);$finish;
 end
 initial begin #1000000000;$fatal(1,"hub timeout");end
endmodule
