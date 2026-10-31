`timescale 1ns/1ps
module tb_modes;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg [1:0] mode=2;
 reg running=1,suspended=0,restart=0,score_ready=1,expected_valid=1,midi_note_on=0;
 reg [6:0] expected_note=48,midi_note=0;
 reg [14:0] expected_offsets={5'd12,5'd7,5'd4};
 reg [5:0] step_index=0;
 reg [31:0] held_keys=0;
 wire practice_hold,demo_valid,demo_retrigger;
 wire [6:0] demo_note;wire [14:0] demo_offsets;
 guide_chord_modes dut(.*);
 integer checks=0,triggers=0,i;
 always @(posedge clk)if(demo_retrigger)triggers=triggers+1;
 task cycles(input integer n);begin repeat(n)begin @(posedge clk);#1;@(negedge clk);end end endtask
 task check(input condition,input [511:0] label);
  begin checks=checks+1;if(!condition)$fatal(1,"MODES: %0s",label);end
 endtask
 task fresh(input integer pitch);
  begin midi_note_on=0;cycles(1);held_keys[pitch-41]=1;midi_note=pitch;midi_note_on=1;
   cycles(1);midi_note_on=0;cycles(2);end
 endtask
 task next_step;
  begin step_index=step_index+1;cycles(3);check(practice_hold,"new step must hold");end
 endtask
 task chord;
  begin fresh(48);fresh(52);fresh(55);fresh(60);end
 endtask
 initial begin
  cycles(2);rst_n=1;cycles(4);
  check(practice_hold,"initial chord waiting");
  fresh(49);check(practice_hold,"wrong note accepted");held_keys=0;cycles(2);
  // Physical pre-hold without fresh receipts never completes.
  held_keys=(32'b1<<7)|(32'b1<<11)|(32'b1<<14)|(32'b1<<19);
  cycles(8);check(practice_hold,"preheld chord accepted");
  fresh(48);fresh(52);fresh(55);check(practice_hold,"missing fourth fresh note");
  fresh(60);check(!practice_hold,"four fresh held notes rejected");
  next_step;cycles(8);check(practice_hold,"repeated chord reused old receipts");
  fresh(48);fresh(52);fresh(55);check(practice_hold,"repeat needs all four fresh");
  fresh(60);check(!practice_hold,"repeat chord not accepted");
  // Sequential single taps cannot substitute for a held chord.
  next_step;held_keys=0;
  for(i=0;i<4;i=i+1)begin
   case(i)0:fresh(48);1:fresh(52);2:fresh(55);3:fresh(60);endcase
   check(practice_hold,"sequential tapping accepted");held_keys=0;cycles(2);
  end
  chord;check(!practice_hold,"chord after taps rejected");
  next_step;held_keys=0;fresh(48);fresh(52);
  // RAM bubble may publish invalid/changed data; preserve partial context.
  score_ready=0;expected_valid=0;expected_note=0;expected_offsets=0;cycles(3);
  check(practice_hold,"bubble advanced practice");
  score_ready=1;expected_valid=1;expected_note=48;expected_offsets={5'd12,5'd7,5'd4};cycles(2);
  fresh(55);fresh(60);check(!practice_hold,"bubble lost fresh receipts");
  next_step;held_keys=0;fresh(48);fresh(52);suspended=1;cycles(3);
  suspended=0;cycles(2);fresh(55);fresh(60);check(practice_hold,"pause kept partial attempt");
  fresh(48);fresh(52);check(!practice_hold,"resume restrike failed");
  next_step;held_keys=0;fresh(48);fresh(52);held_keys[7]=0;cycles(2);
  held_keys[7]=1;fresh(55);fresh(60);check(practice_hold,"release/rehold without receipt accepted");
  fresh(48);check(!practice_hold,"released member cannot be restruck");
  // Legacy mono still requires one fresh note.
  expected_offsets=0;next_step;cycles(3);check(practice_hold,"mono prehold accepted");
  fresh(48);check(!practice_hold,"legacy mono failed");
  expected_valid=0;cycles(2);check(!practice_hold,"rest held practice");
  mode=1;expected_valid=1;expected_offsets={5'd12,5'd7,5'd4};cycles(5);
  check(demo_valid&&demo_note==48&&demo_offsets==expected_offsets,"demo chord payload");
  i=triggers;score_ready=0;expected_valid=0;expected_note=0;cycles(4);
  check(demo_valid&&demo_note==48,"demo dropped during bubble");
  score_ready=1;expected_valid=1;expected_note=48;cycles(4);
  check(triggers==i,"same chord retriggered on RAM bubble");
  step_index=step_index+1;cycles(4);check(triggers==i+1,"repeat step missing retrigger");
  suspended=1;cycles(2);check(!demo_valid,"pause retained demo");
  suspended=0;cycles(4);check(demo_valid&&triggers==i+2,"resume did not retrigger");
  running=0;cycles(2);check(!demo_valid&&!practice_hold,"exit retained guide ownership");
  $display("CHORD_MODES_PASS checks=%0d triggers=%0d",checks,triggers);$finish;
 end
 initial begin #1000000;$fatal(1,"modes watchdog");end
endmodule
