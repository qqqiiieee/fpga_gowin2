`timescale 1ps/1ps
// Direct command executor <-> UNMODIFIED real MIDI mapper. Only command and UART
// input pins are driven; ready/ack/panic and RAM contents are observed, NEVER forced.
// Clock is an exact27MHz rational accumulator at1ps precision, UART864clk/bit.
module tb_state_midi_real;
 reg clk=0;integer rem=0,dt;
 always begin dt=18518;rem=rem+14;if(rem>=27)begin dt=18519;rem=rem-27;end #(dt)clk=~clk;end
 reg rst_n=0,rx=1,request_valid=0;reg[7:0]op=0;reg[39:0]data=0;
 wire done;wire[7:0]status;wire[31:0]reply;
 wire me,mb,mc,mw,wr_ready,commit_ready,ack;
 wire[7:0]ma;wire[6:0]md;wire[27:0]pads,ccs;
 wire event_valid,event_on,event_off,panic;wire[6:0]note;wire[7:0]velocity;
 wire[127:0]held;wire performance_idle=(held==0 && !event_valid);
 wire cc_valid;wire[6:0]cc_number;
 wire kick,snare,ch,oh;
 phone_extension_state controller(.clk(clk),.rst_n(rst_n),.request_valid(request_valid),.op(op),.data(data),
 .done(done),.status(status),.reply(reply),.performance_idle(performance_idle),.pixel_bank_ack(1'b0),.test_owned(1'b0),
 .mapping_enable(me),.mapping_bank(mb),.mapping_commit(mc),.mapping_wr_en(mw),.mapping_wr_addr(ma),.mapping_wr_data(md),.mapping_pad_notes(pads),.mapping_cc_numbers(ccs),
 .mapping_wr_ready(wr_ready),.mapping_commit_ready(commit_ready),.mapping_commit_ack(ack),
 .record_active(1'b0),.record_busy(1'b0),.record_count(32'd0),.record_crc32(32'd0),.record_dropped(16'd0));
 midi_keyboard #(.MAPPING_ENABLE(1)) keyboard(.clk(clk),.rst_n(rst_n),.rx(rx),.suppress(1'b0),.event_ready(1'b1),
 .event_valid(event_valid),.event_on(event_on),.event_off(event_off),.event_note(note),.event_velocity(velocity),.held_notes(held),.panic(panic),
 .cc_valid(cc_valid),.cc_number(cc_number),.hit0(kick),.hit1(snare),.hat_closed_hit(ch),.hat_open_hit(oh),
 .mapping_enable(me),.mapping_bank(mb),.mapping_commit(mc),.mapping_wr_en(mw),.mapping_wr_addr(ma),.mapping_wr_data(md),.mapping_pad_notes(pads),.mapping_cc_numbers(ccs),
 .mapping_wr_ready(wr_ready),.mapping_commit_ready(commit_ready),.mapping_commit_ack(ack));
 integer cycles=0,checks=0,writes=0,accepts=0,ack_pulses=0,panics=0,commit_high_clocks=0;
 integer ons=0,offs=0,last_on=0,last_off=0,kicks=0,last_cc=0;
 integer watch_init=0,watch_upload=0,expected_bank=0,expected_shift=0,phase_writes=0;
 integer address_visits[0:127];integer init_done_cycle=0,last_init_write_cycle=0,init_batches=0;
 integer watch_commit=0,watch_accept_base=0,watch_ack_base=0,watch_panic_base=0;
 integer last_accept_cycle=0,last_ack_cycle=0,commit_done_cycle=0;
 integer accepted_while_held=0,pending_no_ack_clocks=0,commit_completions=0;
 reg accepted_edge,ack_edge;integer i,j,checksum=0,old_accepts,old_panics,old_acks,old_ons;
 task check;input c;input[1023:0]m;begin checks=checks+1;if(c!==1)$fatal(1,"%0s cycle=%0d",m,cycles);end endtask
 function integer mapped;input integer n,shift;begin mapped=(n+shift)&127;end endfunction
 // Clock-edge monitors count CONSUMED writes and commit acceptances, not requests.
 always @(posedge clk)begin
  cycles=cycles+1;
  accepted_edge=mc && commit_ready;ack_edge=ack;
  if(rst_n)begin
   if(keyboard.framing_error || keyboard.overflow)$fatal(1,"MIDI_TRANSPORT_FAULT");
   if(mw && wr_ready)begin
    writes=writes+1;
    if(watch_init || watch_upload)begin
     check(ma[7]==expected_bank && ma[6:0]==phase_writes,"write address sequence/bank");
     check(md==(watch_init?phase_writes:mapped(phase_writes,expected_shift)),"address/data pair aligned");
     address_visits[ma[6:0]]=address_visits[ma[6:0]]+1;phase_writes=phase_writes+1;
     if(watch_init)last_init_write_cycle=cycles;
    end else $fatal(1,"UNEXPECTED_RAM_WRITE cycle=%0d addr=%0d",cycles,ma);
   end
   if(mc)commit_high_clocks=commit_high_clocks+1;
   if(accepted_edge)begin
    accepts=accepts+1;last_accept_cycle=cycles;
    if(!performance_idle)begin
     accepted_while_held=accepted_while_held+1;
     $display("POLICY_OBSERVATION commit_accept_with_new_held_note cycle=%0d held=%032h",cycles,held);
    end
   end
   if(event_valid)begin
    if(event_on)begin ons=ons+1;last_on=note;end else begin offs=offs+1;last_off=note;end
   end
   if(kick)kicks=kicks+1;
   if(cc_valid)last_cc=cc_number;
   if(watch_commit && mc && !commit_ready && !ack)pending_no_ack_clocks=pending_no_ack_clocks+1;
   #1;
   if(ack)begin
    ack_pulses=ack_pulses+1;last_ack_cycle=cycles;
    check(accepted_edge,"registered ack must correspond to this edge's accept");
   end
   if(panic)panics=panics+1;
   if(watch_init && done)init_done_cycle=cycles;
   if(watch_commit && done)begin
    commit_done_cycle=cycles;
    check(ack_edge,"controller completion must consume REAL previous-edge registered ack");
    check(cycles==last_accept_cycle+1,"commit done exactly one clk after mapper acceptance");
    check(accepts==watch_accept_base+1 && ack_pulses==watch_ack_base+1 && panics==watch_panic_base+1,"single accept/ack/panic per command");
   end
   // The two blocks share clk: newly asserted ack must NEVER be combinatorially
   // consumed into done on its assertion edge. Parent observes it NEXT edge.
   if(watch_commit && accepted_edge)check(!done,"no premature done on commit acceptance edge");
  end
 end
 task clocks;input integer n;begin repeat(n)@(negedge clk);end endtask
 task await_done;input[7:0]expected_status;integer timeout;begin
  timeout=0;while(!done && timeout<25000)begin clocks(1);timeout=timeout+1;end
  check(done && status==expected_status,"command completion/status");
  // Model the synchronous RPC consumer: finish only AFTER the edge consuming done.
  // MAP_INIT's final registered write is consumed on that same edge.
  clocks(1);
 end endtask
 task command;input[7:0]operation;input[39:0]payload;input[7:0]expected_status;begin
  @(negedge clk);op=operation;data=payload;request_valid=1;
  @(negedge clk);request_valid=0;await_done(expected_status);
 end endtask
 task prepare_write_watch;input integer bank,shift,is_init;begin
  expected_bank=bank;expected_shift=shift;phase_writes=0;
  for(j=0;j<128;j=j+1)address_visits[j]=0;
  watch_init=is_init;watch_upload=!is_init;
 end endtask
 task begin_map;input integer bank;begin
  prepare_write_watch(bank,0,1);init_done_cycle=0;
  command(8'd32,40'd0,0);
  check(phase_writes==128,"128 real identity writes accepted");
  check(last_init_write_cycle==init_done_cycle+1,"init done/last-write registered pipeline boundary");
  for(j=0;j<128;j=j+1)begin
   check(address_visits[j]==1,"each identity address exactly once incl0/127");
   check(keyboard.dynamic_mapping.note_map[bank*128+j]===j[6:0],"identity memory content after real writes");
  end
  $display("INIT_BATCH_PASS bank=%0d writes=%0d first_visits=%0d last_visits=%0d done_cycle=%0d final_write_cycle=%0d",bank,phase_writes,address_visits[0],address_visits[127],init_done_cycle,last_init_write_cycle);
  watch_init=0;init_batches=init_batches+1;
 end endtask
 task upload;input integer bank,shift,pad_base,cc_base;integer n,value;begin
  prepare_write_watch(bank,shift,0);checksum=0;
  for(n=0;n<128;n=n+1)begin
   value=mapped(n,shift);command(8'd33,{25'd0,value[6:0],n[7:0]},0);
   check(reply==n+1,"NOTE_WRITE reply count");checksum=checksum+n+value;
  end
  check(phase_writes==128,"128 uploaded notes consumed");
  for(j=0;j<128;j=j+1)begin
   check(address_visits[j]==1,"uploaded note address exactly once");
   check(keyboard.dynamic_mapping.note_map[bank*128+j]===mapped(j,shift),"uploaded RAM image");
  end
  watch_upload=0;
  for(n=0;n<4;n=n+1)begin value=pad_base+n;command(8'd34,{25'd0,value[6:0],n[7:0]},0);checksum=checksum+n+value;check(reply==129+n,"PAD_WRITE count");end
  for(n=0;n<4;n=n+1)begin value=cc_base+n;command(8'd35,{25'd0,value[6:0],n[7:0]},0);checksum=checksum+n+value;check(reply==133+n,"CC_WRITE count");end
  check(controller.map_count==136 && controller.upload_sum==checksum,"all136 ordered writes/checksum");
  $display("UPLOAD_BATCH_PASS bank=%0d shift=%0d map_count=%0d checksum=%0d",bank,shift,controller.map_count,checksum);
 end endtask
 task start_commit_watch;begin
  watch_commit=1;watch_accept_base=accepts;watch_ack_base=ack_pulses;watch_panic_base=panics;commit_done_cycle=0;
 end endtask
 task finish_commit_watch;begin
  check(commit_done_cycle!=0 && accepts==watch_accept_base+1 && ack_pulses==watch_ack_base+1 && panics==watch_panic_base+1,"commit accepted exactly once");
  clocks(20);check(!mc && accepts==watch_accept_base+1 && panics==watch_panic_base+1,"no replay after ack/drop request");
  watch_commit=0;commit_completions=commit_completions+1;
 end endtask
 task safe_ready;integer timeout;begin
  timeout=0;while(!commit_ready && timeout<10000)begin clocks(1);timeout=timeout+1;end
  check(commit_ready && performance_idle,"ready and performance idle precondition");
 end endtask
 task byte_tail;input[7:0]v;integer b;begin
  // rx start bit was set on THIS negative edge by the caller.
  clocks(864);for(b=0;b<8;b=b+1)begin rx=v[b];clocks(864);end rx=1;clocks(864);
 end endtask
 task byte_tx;input[7:0]v;begin @(negedge clk);rx=0;byte_tail(v);end endtask
 task midi;input[7:0]st,a,b;begin byte_tx(st);byte_tx(a);byte_tx(b);clocks(32);end endtask
 initial begin
  for(j=0;j<128;j=j+1)address_visits[j]=0;
  clocks(8);rst_n=1;clocks(10);
  begin_map(1);upload(1,12,40,20);safe_ready;
  start_commit_watch;command(8'd36,{24'd0,checksum[15:0]},0);finish_commit_watch;
  check(keyboard.dynamic_mapping.enabled && keyboard.dynamic_mapping.bank==1,"bank1 really active");
  check(keyboard.pad_notes_active=={7'd43,7'd42,7'd41,7'd40} && keyboard.cc_numbers_active=={7'd23,7'd22,7'd21,7'd20},"Pad/CC committed atomically");
  midi(8'h90,60,100);check(last_on==72 && held[60] && !held[72],"real UART mapped NoteOn/raw held");
  midi(8'h80,60,0);check(last_off==72 && held==0,"real UART mapped NoteOff");
  midi(8'h99,40,100);check(kicks==1,"uploaded custom Pad effective");
  midi(8'hB0,20,32);check(last_cc==93,"uploaded CC normalized to canonical");
  // Active bank1 makes the PREVIOUS write address not-ready. BEGIN must preload
  // bank0 before checking ready, otherwise this second initialization deadlocks.
  check(!wr_ready,"last write address is now active, exercises BEGIN preload");
  begin_map(0);upload(0,5,44,24);
  midi(8'h90,60,100);old_accepts=accepts;old_panics=panics;
  command(8'd36,{24'd0,checksum[15:0]},3);
  check(accepts==old_accepts && panics==old_panics && held[60],"held-note commit rejected BUSY without panic/ack");
  midi(8'h80,60,0);check(!commit_ready && performance_idle,"raw held clears before UART idle guard expires");
  command(8'd36,{24'd0,checksum[15:0]},3);check(accepts==old_accepts,"ready-low command does not queue early commit");
  safe_ready;
  // Ready can drop after the parent's precheck but BEFORE the decoder samples the
  // registered commit. Drive a genuine UART byte at the next negedge to test it.
  @(negedge clk);op=36;data={24'd0,checksum[15:0]};request_valid=1;
  @(negedge clk);request_valid=0;rx=0;
  fork
   begin byte_tail(8'h90);byte_tx(60);end
   begin await_done(3);check(!mc && me && mb==1,"racing MIDI cancels commit and restores active metadata");end
  join
  clocks(9000);check(keyboard.have_first && !commit_ready && accepts==old_accepts,"partial message cannot commit later");
  byte_tx(100);clocks(9000);
  check(held[60] && last_on==72 && accepts==old_accepts && panics==old_panics,"new held note survives rejected commit using old map");
  check(accepted_while_held==0,"never accept mapping while a newly held note exists");
  midi(8'h80,60,0);check(last_off==72,"old mapping release after rejected commit");safe_ready;
  start_commit_watch;command(8'd36,{24'd0,checksum[15:0]},0);finish_commit_watch;
  check(keyboard.dynamic_mapping.bank==0 && held==0,"retry switches staged bank only after real ack");
  midi(8'h90,60,100);check(last_on==65,"bank0 mapping after actual ack");midi(8'h80,60,0);check(last_off==65,"bank0 off consistent");
  safe_ready;start_commit_watch;command(8'd38,40'd0,0);finish_commit_watch;
  check(!me && !keyboard.map_enabled,"38 disable effective only after real ack");
  midi(8'h90,60,100);check(last_on==60,"38 restores identity NoteOn");midi(8'h80,60,0);check(last_off==60,"38 restores identity NoteOff");
  midi(8'h99,35,100);midi(8'h99,36,100);check(kicks==3,"38 restores GM aliases35/36");
  midi(8'hB0,93,32);check(last_cc==93,"38 restores raw default CC93");
  // Reinitialize previously-transposed bank1 to identity. Stored content is no
  // longer the power-on identity, so the memory-content assertion is substantive.
  begin_map(1);command(8'd37,40'd0,0);check(!me && !keyboard.map_enabled,"cancel doesn't enable map");
  check(writes==640 && init_batches==3 && accepts==3 && ack_pulses==3 && panics==3,"all real write/commit/panic totals");
  $display("STATE_MIDI_REAL_PASS checks=%0d writes=%0d init_batches=%0d upload_batches=2 accepts=%0d registered_acks=%0d panics=%0d commit_high_clocks=%0d pending_no_ack_clocks=%0d accepts_while_new_note_held=%0d ons=%0d offs=%0d",checks,writes,init_batches,accepts,ack_pulses,panics,commit_high_clocks,pending_no_ack_clocks,accepted_while_held,ons,offs);
  $finish;
 end
 initial begin #50000000000;$fatal(1,"STATE_MIDI_REAL_TIMEOUT");end
endmodule
