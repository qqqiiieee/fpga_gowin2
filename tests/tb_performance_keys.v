`timescale 1ns/1ps
module tb_performance_keys;
  reg clk=0;always #5 clk=~clk;
  reg rst=0;reg [15:0] pressed=0;
  wire [3:0] rows;reg [3:0] cols;
  wire on,off,ghost;wire [6:0] note;wire [7:0] velocity;
  wire [3:0] timbre,chosen;wire [15:0] state;
  matrix_keypad #(.ROW_CYCLES(10),.DEBOUNCE_FRAMES(3),.PERFORMANCE_MODE(1)) dut(
    .clk(clk),.rst_n(rst),.rows(rows),.cols(cols),.velocity(8'd200),
    .note_on(on),.note_off(off),.note(note),.vel_out(velocity),.timbre_out(timbre),
    .key_state(state),.ghost_active(ghost),.selected_timbre(chosen));
  // Real passive network: three corners connect a phantom fourth corner.
  reg [3:0] reached_rows,reached_cols;
  integer pass,r,c;
  always @(*) begin
    reached_rows=0;reached_cols=0;
    for(r=0;r<4;r=r+1) if(rows[r]===1'b0) reached_rows[r]=1;
    for(pass=0;pass<8;pass=pass+1)
      for(r=0;r<4;r=r+1) for(c=0;c<4;c=c+1)
        if(pressed[r*4+c]) begin
          if(reached_rows[r]) reached_cols[c]=1;
          if(reached_cols[c]) reached_rows[r]=1;
        end
    cols=~reached_cols;
  end
  integer ons=0,offs=0,counts[0:127],releases[0:127];
  reg [3:0] expected_timbre=0;
  always @(posedge clk) if(rst) begin
    if(on && off) $fatal(1,"note event collided");
    if(on) begin
      ons=ons+1;counts[note]=counts[note]+1;
      if(timbre!==expected_timbre || velocity!==200) $fatal(1,"new note timbre/velocity incorrect");
    end
    if(off) begin offs=offs+1;releases[note]=releases[note]+1;end
  end
  task cycles;input integer n;integer k;begin for(k=0;k<n;k=k+1) @(negedge clk);end endtask
  task tap;input [15:0] mask;begin pressed=mask;cycles(240);pressed=0;cycles(240);end endtask
  task select_check;input integer group,expected;
    begin tap(16'h1000<<group);if(chosen!==expected) $fatal(1,"group %0d selected %0d expected %0d",group,chosen,expected);end
  endtask
  function integer midi;input integer key;
    begin case(key)
      0:midi=60;1:midi=62;2:midi=64;3:midi=65;
      4:midi=67;5:midi=69;6:midi=71;7:midi=72;
      8:midi=74;9:midi=76;10:midi=77;default:midi=79;
    endcase end
  endfunction
  integer i,g,base_on,base_off;
  initial begin
    for(i=0;i<128;i=i+1) begin counts[i]=0;releases[i]=0;end
    cycles(5);rst=1;cycles(240);
    if(chosen!==0) $fatal(1,"default timbre incorrect");
    select_check(0,0);select_check(0,1);select_check(0,2);select_check(0,3);select_check(0,0);
    for(g=1;g<4;g=g+1) begin
      select_check(g,g*4);
      for(i=1;i<4;i=i+1) select_check(g,g*4+i);
    end
    if(ons || offs) $fatal(1,"selectors generated notes");
    select_check(1,7);select_check(1,4); // Recall variant then wrap.
    pressed=16'h2000;cycles(900);
    if(chosen!==5) $fatal(1,"held selector repeated");
    pressed=0;cycles(240);
    tap(16'h3000);tap(16'h9000);
    if(chosen!==5 || ons || offs) $fatal(1,"multi-selector shortcut changed timbre/played");
    expected_timbre=5;
    for(i=0;i<12;i=i+1) begin
      tap(16'h0001<<i);
      if(counts[midi(i)]!==1 || releases[midi(i)]!==1) $fatal(1,"12-key pitch/release mapping failed %0d",i);
    end
    base_on=ons;base_off=offs;tap(16'h000f);
    if(ons!=base_on+4 || offs!=base_off+4) $fatal(1,"same-timbre chord lost events");
    // A held playing key is neither released nor retriggered by selection.
    base_on=ons;base_off=offs;pressed=1;cycles(240);
    pressed=16'h2001;cycles(240);
    if(chosen!==6 || ons!=base_on+1 || offs!=base_off) $fatal(1,"selection retriggered held note");
    pressed=0;cycles(240);
    // Selector and new note in one scan must use the newly selected timbre.
    expected_timbre=15;pressed=16'h8001;cycles(300);
    if(chosen!==15 || ons!=base_on+2) $fatal(1,"simultaneous select/note failed");
    pressed=0;cycles(240);
    base_on=ons;base_off=offs;
    pressed=16'h8000;cycles(55);pressed=0;cycles(300);
    if(chosen!==15 || ons!=base_on) $fatal(1,"selector bounce was accepted");
    pressed=16'h0013;cycles(300);
    if(!ghost || ons!=base_on) $fatal(1,"phantom playing notes accepted");
    pressed=0;cycles(240);
    pressed=1;cycles(240);pressed=16'h1003;cycles(300);
    if(!ghost || chosen!==15 || ons!=base_on+1 || offs!=base_off) $fatal(1,"selector ghost changed choice or held note");
    pressed=0;cycles(300);
    if(state!==0 || offs!=base_off+1) $fatal(1,"ghost release recovery failed");
    $display("PERFORMANCE_KEYS_TEST_PASS 12 pitches, 16 timbres, recall/wrap, held notes, same-scan selection, debounce, real ghosts");$finish;
  end
  initial begin #2000000;$fatal(1,"performance keyboard timeout");end
endmodule
