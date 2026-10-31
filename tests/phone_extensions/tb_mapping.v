`timescale 1ns/1ps
module tb_mapping;
 reg clk=0,rx=1;always #18.518519 clk=~clk;
 reg enable=0,bank=0,commit=0,we=0;reg[7:0]addr=0;reg[6:0]data=0;
 reg[27:0]pads={7'd43,7'd42,7'd41,7'd40};reg[27:0]ccs={7'd23,7'd22,7'd21,7'd20};
 wire wr_ready,commit_ready,ack,rst_n;wire[31:0]held_display,voices;wire[7:0]vol;wire[1:0]fx;
 tri1 scl,sda;
 instrument_audio_top #(.MIDI_ENABLE(1),.OPTICAL_ENABLE(0),.DISPLAY_TOUCH_ONLY(1),.PHASE_RAM(1),.LIVE_ADSR_ENABLE(1),.EFFECTS_ENABLE(1),.MAPPING_ENABLE(1)) dut(
 .clk(clk),.matrix_cols(4'hF),.adc_scl(scl),.adc_sda(sda),.uart_rx(1'b1),.midi_rx(rx),.optical_beams(2'b11),.touch_miso(1'b1),
 .ui_test_keys(16'd0),.ui_panic(1'b0),.ui_strum_mode(2'd0),.ui_timbre_set_valid(1'b0),.ui_timbre_set_value(4'd0),.ui_filter_enable(1'b0),.ui_zero_mode(1'b0),.control_page(2'd0),.ui_fx_cycle(1'b0),
 .phone_set_valid(1'b0),.phone_param(8'd0),.phone_value(8'd0),.phone_query_param(8'd0),.ui_test_enter(1'b0),.ui_test_exit(1'b0),.ui_test_count_valid(1'b0),.ui_test_count(6'd0),.ui_test_sweep_start(1'b0),
 .monitor_rst_n(rst_n),.monitor_piano_keys32(held_display),.monitor_busy(voices),.monitor_volume(vol),.monitor_fx_mode(fx),
 .mapping_enable(enable),.mapping_bank(bank),.mapping_commit(commit),.mapping_wr_en(we),.mapping_wr_addr(addr),.mapping_wr_data(data),.mapping_pad_notes(pads),.mapping_cc_numbers(ccs),.mapping_wr_ready(wr_ready),.mapping_commit_ready(commit_ready),.mapping_commit_ack(ack));
 `define K dut.input_hub.performance.midi_input.keyboard
 `define H dut.input_hub.performance
 integer ons=0,offs=0,panics=0,acks=0,hits[0:3],cc_seen=0,last_cc=0;integer last_on=0,last_off=0,checks=0;
 always @(posedge clk)if(rst_n)begin
  if(dut.note_on)begin ons=ons+1;last_on=dut.note;end
  if(dut.note_off)begin offs=offs+1;last_off=dut.note;end
  if(dut.panic_audio)panics=panics+1;
  if(ack)acks=acks+1;
  if(dut.hit0)hits[0]=hits[0]+1;if(dut.hit1)hits[1]=hits[1]+1;
  if(dut.hat_closed_hit)hits[2]=hits[2]+1;if(dut.hat_open_hit)hits[3]=hits[3]+1;
  if(`H.cc_valid)begin cc_seen=cc_seen+1;last_cc=`H.cc_number;end
 end
 task check;input c;input[511:0]msg;begin checks=checks+1;if(c!==1)$fatal(1,"%0s",msg);end endtask
 task clocks;input integer n;begin repeat(n)@(negedge clk);end endtask
 task byte_tx;input[7:0]v;integer b;begin @(negedge clk);rx=0;clocks(864);for(b=0;b<8;b=b+1)begin rx=v[b];clocks(864);end rx=1;clocks(864);end endtask
 task msg;input[7:0]s,a,b;begin byte_tx(s);byte_tx(a);byte_tx(b);clocks(300);end endtask
 task write_map;input[7:0]a;input[6:0]v;begin @(negedge clk);addr=a;data=v;we=1;#1;check(wr_ready,"staging write ready");@(negedge clk);we=0;end endtask
 task apply_map;input e,b;begin enable=e;bank=b;wait(commit_ready);@(negedge clk);commit=1;@(negedge clk);check(ack,"commit ack");commit=0;clocks(8);end endtask
 integer i,old_count,old_off,old_panic,old_cc,old_hit;
 initial begin
  for(i=0;i<4;i=i+1)hits[i]=0;
  wait(rst_n);clocks(40);
  // Runtime disabled is identity, including old drum aliases and raw CC defaults.
  msg(8'h90,60,100);check(last_on==60 && `K.held_notes[60],"identity NoteOn");
  msg(8'h80,60,0);check(last_off==60 && !`K.held_notes[60],"identity NoteOff");
  msg(8'h99,35,100);check(hits[0]==1,"legacy drum alias35");
  msg(8'hB0,93,32);msg(8'hB0,93,33);check(fx==1,"legacy CC93");
  write_map(8'd60,7'd72);write_map(8'd61,7'd73);
  old_panic=panics;apply_map(1,0);check(panics==old_panic+1 && dut.audio.gate==0 && `K.held_notes==0,"commit panic reaches actual audio allocator");
  @(negedge clk);addr=60;data=99;we=1;#1;check(!wr_ready,"active bank write rejected");@(negedge clk);we=0;
  msg(8'h90,60,100);check(last_on==72 && `K.held_notes[60] && !`K.held_notes[72] && held_display[19],"mapped sound with raw held/display");
  check(dut.audio.u_alloc.notes[0]==72 && dut.audio.gate[0],"actual allocator receives mapped note");
  msg(8'h80,60,0);check(last_off==72 && `K.held_notes==0,"mapped NoteOff consistent");
  // Running status NoteOn velocity0 shares the same synchronous note lookup.
  msg(8'h90,61,110);byte_tx(61);byte_tx(0);clocks(300);check(last_on==73 && last_off==73,"running status zero-velocity off");
  msg(8'h90,60,100);msg(8'hB0,64,127);old_off=offs;
  msg(8'h80,60,0);check(offs==old_off && !`K.held_notes[60],"pedal holds mapped note while raw held clears");
  msg(8'hB0,64,0);check(offs==old_off+1 && last_off==72,"pedal release scan maps raw note once");
  msg(8'h90,60,100);msg(8'h90,61,100);old_off=offs;msg(8'hB0,123,0);
  check(offs==old_off+2 && `K.held_notes==0,"CC123 releases all mapped notes");
  for(i=0;i<4;i=i+1)begin old_hit=hits[i];msg(8'h99,40+i,100);check(hits[i]==old_hit+1,"custom pad");end
  old_hit=hits[0];msg(8'h99,36,100);check(hits[0]==old_hit,"old default pad replaced");
  msg(8'hB0,20,32);check(last_cc==93 && fx==1,"custom CC0 -> Delay");
  msg(8'hB0,21,32);msg(8'hB0,21,33);check(last_cc==91 && fx==2,"custom CC1 -> Chorus");
  msg(8'hB0,22,32);msg(8'hB0,22,33);check(last_cc==71 && fx==3,"custom CC2 -> Reverb");
  msg(8'hB0,23,80);check(last_cc==74 && vol==161,"custom CC3 -> volume pickup");
  old_cc=cc_seen;msg(8'hB0,93,40);check(cc_seen==old_cc && fx==3,"unassigned old knob CC suppressed");
  msg(8'hB0,1,55);check(`K.modulation==55,"built-in CC1 unaffected");
  msg(8'hB0,7,50);check(vol==100,"built-in CC7 unaffected");
  msg(8'h90,60,100);old_panic=panics;msg(8'hB0,120,0);
  check(panics==old_panic+1 && `K.held_notes==0 && dut.audio.gate==0,"CC120 panic with mapping");
  write_map(8'd188,7'd67);write_map(8'd189,7'd68);
  msg(8'h90,60,100);check(last_on==72,"bank0 still active during staging");
  old_panic=panics;apply_map(1,1);check(panics==old_panic+1 && dut.audio.gate==0,"atomic bank swap clears sound");
  msg(8'h90,60,100);check(last_on==67,"bank1 NoteOn");msg(8'h80,60,0);check(last_off==67,"bank1 NoteOff");
  // No mid-message commit: have_first blocks commit even after a long idle high.
  byte_tx(8'h90);byte_tx(61);clocks(9000);enable=0;bank=0;commit=1;clocks(20);
  check(!commit_ready && !ack,"partial message commit not accepted");
  byte_tx(100);clocks(10000);commit=0;clocks(10);
  check(!`K.map_enabled && dut.audio.gate==0,"deferred disable commit panic");
  msg(8'h90,60,100);check(last_on==60,"disabled mapping returns identity");
  $display("MAPPING_TEST_PASS checks=%0d ons=%0d offs=%0d commits=%0d panics=%0d",checks,ons,offs,acks,panics);$finish;
 end
 initial begin #100000000;$fatal(1,"MAPPING_TIMEOUT");end
endmodule
