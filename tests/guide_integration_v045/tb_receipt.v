`timescale 1ns/1ps
// Reuses the existing pin-level serial driver and FIFO stability scoreboard.
// No force, parser injection, or modified production source.
module tb_receipt;
 parameter integer CLK_HZ=1000000;
 midi_test_driver #(.CLK_HZ(CLK_HZ)) d();
 integer receipts=0,checks=0,i,n,before_count;
 reg previous=0;
 reg [6:0] notes[0:255];
 always @(posedge d.clk) begin
  if(!d.rst_n)begin receipts=0;previous=0;end
  else begin
   if(d.dut.receipt_note_on)begin
    if(previous)$fatal(1,"receipt wider than one clock");
    // At the sampling edge receipt must coincide with the UART's velocity byte,
    // not a later event_ready handshake or another FIFO entry.
    if(!d.dut.rx_valid || d.dut.rx_data[7] || d.dut.rx_data[6:0]==0)
      $fatal(1,"receipt delayed beyond UART data-valid");
    notes[receipts]=d.dut.receipt_note;receipts=receipts+1;
   end
   previous=d.dut.receipt_note_on;
  end
 end
 task check(input c,input [1023:0] m);
  begin checks=checks+1;if(c!==1'b1)$fatal(1,"%0s receipts=%0d",m,receipts);end
 endtask
 initial begin
  d.reset; d.ready=0;
  d.msg(8'h90,60,100);
  check(receipts==1 && notes[0]==60 && d.count==0,"receipt with FIFO backpressure");
  d.tx(61);d.tx(8'hf8);d.tx(1);
  check(receipts==2 && notes[1]==61 && d.count==0,"running status realtime byte receipt");
  d.msg(8'h90,60,127);
  check(receipts==3 && notes[2]==60,"same pitch real receipt retrigger");
  d.tick(100);check(receipts==3,"no receipt replay while stalled");
  d.ready=1;d.expect_event(1,60,201);d.expect_event(1,61,2);d.expect_event(1,60,255);
  d.quiet;check(receipts==3,"draining queued events must not retrigger receipt");
  $display("CASE_PASS receipt_before_fifo_delivery_and_no_replay");

  n=receipts;
  d.msg(8'h90,60,0);d.msg(8'h80,61,64);
  d.msg(8'h99,36,100);d.msg(8'h99,38,100);d.msg(8'h99,60,100);
  for(i=1;i<16;i=i+1)if(i!=9)d.msg(8'h90+i,64,100);
  d.msg(8'hb0,1,90);d.msg(8'ha0,60,100);d.tx(8'hc0);d.tx(1);
  check(receipts==n,"velocity zero/off/drums/other channels/control not receipt");
  d.tx(8'h90);d.tx(62);check(receipts==n,"partial message no receipt");
  d.tx(8'hf1);d.tx(100);d.tx(62);d.tx(100);
  d.tx(8'hf0);d.tx(60);d.tx(100);d.tx(8'hf8);d.tx(8'hf7);
  d.tx(60);d.tx(100);check(receipts==n,"system common/sysex orphan bytes no receipt");
  d.msg(8'h90,127,100);check(receipts==n+1 && notes[n]==127,"raw upper range");
  d.msg(8'h90,0,100);check(receipts==n+2 && notes[n+1]==0,"raw lower range");
  $display("CASE_PASS receipt_protocol_filters_and_raw_range");

  d.reset;d.suppress=1;d.tick(4);d.msg(8'h90,64,100);
  check(receipts==0,"suppressed note no receipt");
  d.suppress=0;d.tick(4);d.msg(8'h90,64,100);
  check(receipts==0,"held suppressed key cannot replay after restore");
  d.msg(8'h80,64,0);d.msg(8'h90,64,100);
  check(receipts==1 && notes[0]==64,"release to rearm suppress");
  d.msg(8'h90,65,100);d.suppress=1;d.tick(4);d.msg(8'h90,65,100);
  check(receipts==2,"pre-suppress held note blocked");
  $display("CASE_PASS receipt_suppress_rearm");

  d.reset;d.tx(8'h90);d.tx(66);d.serial(100,0,0);
  d.rx=1;d.tick(3*d.BIT_CYCLES);
  check(receipts==0 && d.framing_error && d.panics==1,"bad stop no receipt");
  d.tx(66);d.tx(100);check(receipts==0,"after error require fresh status");
  d.msg(8'h90,67,100);check(receipts==1 && notes[0]==67,"framing recovery");
  d.tx(8'h90);d.tx(68);d.tx(8'hff);d.tx(100);
  check(receipts==1,"system reset cancels partial note");
  $display("CASE_PASS receipt_bad_frame_and_parser_cancel");

  d.reset;d.ready=0;d.tx(8'h90);
  for(i=0;i<16;i=i+1)begin d.tx(40+i);d.tx(100);end
  check(receipts==16 && d.count==0 && !d.overflow,"full FIFO receipts remain immediate");
  d.tx(80);d.tx(100);
  check(receipts==16 && d.overflow && d.panics==1,"overflow-cancelled note no receipt");
  d.ready=1;d.tick(200);check(receipts==16,"panic queue cannot replay receipt");
  $display("CASE_PASS receipt_full_fifo_and_overflow_cancel");
  $display("V045_RECEIPT_PASS checks=%0d clk_hz=%0d",checks,CLK_HZ);$finish;
 end
 initial begin #1000000000;$fatal(1,"receipt timeout");end
endmodule
