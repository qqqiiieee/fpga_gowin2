`timescale 1ns/1ps
// Functional UART ratios are scaled by CLK_HZ=1MHz, 32clocks/bit. No latency claim.
module tb_mapping_release;
 reg clk=0,rst=0,rx=1,suppress=0,ready=1,en=1,bank=0,commit=0,we=0;
 reg[7:0]addr=0;reg[6:0]data=0;wire wr,cr,ack,valid,on_event,off_event,panic;wire[6:0]note;wire[127:0]held;
 midi_keyboard #(.CLK_HZ(1000000),.ACTIVE_SENSE_MS(0),.MAPPING_ENABLE(1)) dut(
 .clk(clk),.rst_n(rst),.rx(rx),.suppress(suppress),.event_ready(ready),.event_valid(valid),.event_on(on_event),.event_off(off_event),.event_note(note),.held_notes(held),.panic(panic),
 .mapping_enable(en),.mapping_bank(bank),.mapping_commit(commit),.mapping_wr_en(we),.mapping_wr_addr(addr),.mapping_wr_data(data),.mapping_pad_notes({7'd39,7'd37,7'd38,7'd36}),.mapping_cc_numbers({7'd74,7'd71,7'd91,7'd93}),.mapping_wr_ready(wr),.mapping_commit_ready(cr),.mapping_commit_ack(ack));
 always #5 clk=~clk;
 integer ons=0,offs=0,last=0,pc=0,i,base,checks=0,kick=0,snare=0,closed_hat=0,open_hat=0,last_cc=0;reg stalled=0;reg[15:0]saved;
 always @(posedge clk)if(rst)begin
  if(stalled && !panic && !commit && !suppress && (!valid || {on_event,note,dut.event_velocity}!==saved))$fatal(1,"MIDI_STALL_UNSTABLE");
  if(valid && ready)begin if(on_event)ons=ons+1;else offs=offs+1;last=note;end
  if(panic)pc=pc+1;
  if(dut.hit0)kick=kick+1;if(dut.hit1)snare=snare+1;
  if(dut.hat_closed_hit)closed_hat=closed_hat+1;if(dut.hat_open_hit)open_hat=open_hat+1;
  if(dut.cc_valid)last_cc=dut.cc_number;
  stalled=valid && !ready;saved={on_event,note,dut.event_velocity};
 end
 task clocks;input integer n;begin repeat(n)@(negedge clk);end endtask
 task byte_tx;input[7:0]v;integer b;begin @(negedge clk);rx=0;clocks(32);for(b=0;b<8;b=b+1)begin rx=v[b];clocks(32);end rx=1;clocks(32);end endtask
 task msg;input[7:0]s,a,b;begin byte_tx(s);byte_tx(a);byte_tx(b);clocks(150);end endtask
 task check;input c;input[511:0]m;begin checks=checks+1;if(c!==1)$fatal(1,"%0s",m);end endtask
 task apply;begin wait(cr);@(negedge clk);commit=1;@(negedge clk);check(ack,"commit ack");commit=0;clocks(8);end endtask
 initial begin
  clocks(5);rst=1;clocks(4);addr=60;data=72;we=1;clocks(1);we=0;apply;
  msg(8'h90,60,100);check(ons==1 && last==72 && dut.delivered_notes[60] && !dut.delivered_notes[72],"raw delivered metadata");
  base=offs;suppress=1;clocks(200);check(offs==base+1 && last==72 && held==0,"suppress scans RAW then maps exactly once");
  suppress=0;msg(8'h80,60,0);clocks(200);
  ready=0;base=ons;msg(8'h90,60,100);check(valid && on_event && note==72,"mapped queued event");
  clocks(20);apply;clocks(20);ready=1;clocks(200);check(ons==base && !valid && held==0,"commit cancels queued on under backpressure");
  // Write and commit identity bank1; old bank0 data must not leak from read_q.
  bank=1;apply;msg(8'h90,60,100);check(last==60,"bank1 identity sync read");msg(8'h80,60,0);check(last==60,"bank1 identity off");
  en=0;apply;
  msg(8'h99,35,100);msg(8'h99,36,100);check(kick==2,"disable restores GM kick35/36");
  msg(8'h99,38,100);msg(8'h99,40,100);check(snare==2,"disable restores GM snare38/40");
  msg(8'h99,37,100);msg(8'h99,42,100);check(closed_hat==2,"disable restores closed37/42");
  msg(8'h99,39,100);msg(8'h99,46,100);check(open_hat==2,"disable restores open39/46");
  msg(8'hB0,93,40);check(last_cc==93,"disable restores raw CC93");
  msg(8'h90,60,100);check(last==60,"disable restores identity60 after bank0 remap");
  msg(8'h80,60,0);check(last==60,"disable identity off");
  // Duplicate CC/Pad policy is documented lowest-index-first; default path legacy
  // regressions separately test all original CC and drum aliases.
  $display("MAPPING_RELEASE_TEST_PASS checks=%0d on=%0d off=%0d panic=%0d",checks,ons,offs,pc);$finish;
 end
 initial begin #10000000;$fatal(1,"MAPPING_RELEASE_TIMEOUT");end
endmodule
