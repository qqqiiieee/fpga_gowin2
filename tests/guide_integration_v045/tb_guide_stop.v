`timescale 1ns/1ps
module tb_guide_stop;
 parameter integer ENABLE=1;
 reg clk=0,rst_n=0,stop=0,phone=0,mode=0,owned=0;always #5 clk=~clk;
 reg [3:0] keys=15;reg [1:0] command=1,requested_song=1;
 wire pause_key,restart,start,cycle_mode;wire [1:0] song;wire [3:0] down;
 integer checks=0,restarts=0,starts=0,modes=0,n,s,m;
 four_button_display_control #(.DEBOUNCE_CYCLES(2),.LONG_PRESS_CYCLES(64),
  .CUSTOM_SONG_ENABLE(1),.GUIDE_MODES_ENABLE(ENABLE)) dut(
  .clk(clk),.rst_n(rst_n),.keys_n(keys),.guide_done(1'b0),.test_owned(owned),
  .custom_song_available(1'b1),.phone_song_command_valid(phone),.phone_song_command(command),
  .phone_song_id(requested_song),.phone_guide_mode_valid(mode),.guide_stop(stop),
  .phone_set_valid(1'b0),.phone_param(8'd0),.phone_value(8'd0),.song_id(song),
  .song_start(start),.song_restart(restart),.guide_mode_cycle(cycle_mode),.key_pause(pause_key),.buttons_down(down));
 always @(posedge clk)begin #1;if(rst_n)begin
  if(restart)restarts=restarts+1;if(start)starts=starts+1;if(cycle_mode)modes=modes+1;
 end end
 task tick(input integer n);repeat(n)begin @(posedge clk);#2;end endtask
 task check(input c,input [1023:0] msg);
  begin checks=checks+1;if(c!==1'b1)$fatal(1,"%0s enable=%0d",msg,ENABLE);end
 endtask
 task phone_start;
  begin @(negedge clk);phone=1;tick(1);@(negedge clk);phone=0;tick(30);end
 endtask
 initial begin
  tick(4);@(negedge clk);rst_n=1;tick(30);phone_start;
  check(!pause_key && song==(ENABLE?1:3),"initial explicit start");
  n=restarts;s=starts;@(negedge clk);stop=1;tick(1);@(negedge clk);stop=0;tick(100);
  check(pause_key==ENABLE && restarts==n+ENABLE && starts==s,"stop latch vs legacy ignored");
  if(ENABLE)begin
   repeat(4)begin tick(100);check(pause_key,"stop remains paused without automatic restart");end
   // Mode changes and long4 are restart-only actions; neither explicitly starts.
   @(negedge clk);mode=1;tick(1);@(negedge clk);mode=0;tick(30);
   check(pause_key,"mode change must not start stopped guide");
   @(negedge clk);keys=7;tick(90);@(negedge clk);keys=15;tick(30);
   check(pause_key,"long4 must not start stopped guide");
  end
  phone_start;check(!pause_key,"explicit phone start rearms");
  // Simultaneous stop+phone-start must prefer stop in enabled mode.
  n=restarts;s=starts;@(negedge clk);stop=1;phone=1;tick(1);
  @(negedge clk);stop=0;phone=0;tick(40);
  check(pause_key==ENABLE && restarts==n+ENABLE && starts==s+!ENABLE,"stop highest priority over phone");
  if(ENABLE)begin
   phone_start;@(negedge clk);keys=7;tick(90);n=restarts;m=modes;
   @(negedge clk);stop=1;tick(1);@(negedge clk);stop=0;tick(3);
   @(negedge clk);keys=15;tick(40);
   check(pause_key && restarts==n+1 && modes==m,"stop clears held long4 gesture");
   // A normal short2 is an explicit physical start.
   @(negedge clk);keys=13;tick(16);@(negedge clk);keys=15;tick(40);
   check(!pause_key,"explicit panel start resumes after stop");
   @(negedge clk);owned=1;tick(30);n=restarts;
   @(negedge clk);stop=1;tick(1);@(negedge clk);stop=0;owned=0;tick(40);
   check(pause_key && restarts==n+1,"stop survives test ownership transition");
  end
  $display("V045_GUIDE_STOP_PASS checks=%0d enable=%0d",checks,ENABLE);$finish;
 end
 initial begin #1000000;$fatal(1,"stop timeout");end
endmodule
