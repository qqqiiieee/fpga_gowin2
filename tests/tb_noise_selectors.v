`timescale 1ns/1ps
module tb_noise_selectors;
 reg clk=0;always #5 clk=~clk;
 reg rst=0;reg [15:0] pressed=0;wire [3:0] rows;reg [3:0] cols;
 wire on,off,ghost;wire [6:0] note;wire [7:0] velocity;
 wire [3:0] timbre,chosen;wire [15:0] state;
 matrix_keypad #(.ROW_CYCLES(10),.DEBOUNCE_FRAMES(3),.PERFORMANCE_MODE(1),.SELECT_ON_RELEASE(1)) dut(
   .clk(clk),.rst_n(rst),.rows(rows),.cols(cols),.velocity(8'd160),
   .note_on(on),.note_off(off),.note(note),.vel_out(velocity),.timbre_out(timbre),
   .key_state(state),.ghost_active(ghost),.selected_timbre(chosen));
 reg [3:0] reached_rows,reached_cols;
 integer pass,r,c,ons=0,offs=0,g,v,before_choice,baseline;
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
 always @(negedge clk) if(rst) begin
   if(on) ons=ons+1;
   if(off) offs=offs+1;
 end
 task cycles;input integer n;integer x;begin for(x=0;x<n;x=x+1) @(negedge clk);end endtask
 task select_check;input integer group,expected;begin
   before_choice=chosen;pressed=16'h1000<<group;cycles(700);
   if(chosen!=before_choice) $fatal(1,"choice changed before selector release");
   pressed=0;cycles(400);
   if(chosen!=expected) $fatal(1,"selector %0d result %0d expected %0d",group,chosen,expected);
 end endtask
 task staggered_chord;input [15:0] first,both,remaining;begin
   before_choice=chosen;
   pressed=first;cycles(400);pressed=both;cycles(400);pressed=remaining;cycles(400);
   pressed=0;cycles(400);
   if(chosen!=before_choice) $fatal(1,"shortcut changed timbre: %h",both);
 end endtask
 initial begin
   cycles(5);rst=1;cycles(400);
   select_check(0,0);
   for(v=1;v<5;v=v+1) select_check(0,v%4);
   for(g=1;g<4;g=g+1) begin
     select_check(g,g*4);
     for(v=1;v<5;v=v+1) select_check(g,g*4+v%4);
   end
   select_check(1,4);select_check(1,5);select_check(3,12);select_check(1,5);
   staggered_chord(16'h2000,16'h6000,16'h4000);
   staggered_chord(16'h4000,16'h6000,16'h2000);
   staggered_chord(16'h4000,16'hc000,16'h8000);
   staggered_chord(16'h8000,16'hc000,16'h4000);
   if(ons || offs) $fatal(1,"selectors/chords generated pitch events");
   baseline=ons;pressed=1;cycles(400);pressed=16'h2001;cycles(400);
   if(chosen!=5 || ons!=baseline+1 || offs!=0) $fatal(1,"held selector retriggered note");
   pressed=1;cycles(400);
   if(chosen!=6 || ons!=baseline+1 || offs!=0) $fatal(1,"selector release affected held note");
   pressed=0;cycles(400);if(offs!=1) $fatal(1,"pitch release missing");
   pressed=16'h8000;cycles(55);pressed=0;cycles(400);
   if(chosen!=6) $fatal(1,"selector bounce accepted");
   // Two unambiguous keys then a ghost rectangle must not create selector chords.
   pressed=16'h6000;cycles(400);pressed=16'h6002;cycles(400);
   if(!ghost || chosen!=6) $fatal(1,"selector ghost failed");
   pressed=16'h6000;cycles(400);pressed=0;cycles(400);
   if(chosen!=6 || state!=0) $fatal(1,"ghost/chord release changed choice");
   $display("NOISE_SELECTORS_TEST_PASS release-selection/16timbres/recall/wrap/staggeredABchords/heldnotes/bounce/ghosts");
   $finish;
 end
 initial begin #2000000;$fatal(1,"selector timeout");end
endmodule
