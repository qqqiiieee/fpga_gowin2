`timescale 1ns/1ps
// Real command executor connected to real panel control. Request ports are the
// RPC executor boundary; framed phone UART/ESP transport is outside this test.
module tb_phone;
 parameter integer ENABLE=1;
 reg clk=0,rst_n=0,request=0,owned=0;always #5 clk=~clk;
 reg [7:0] op=0;reg [39:0] data=0;reg [23:0] guide_status=24'ha5c39e;
 wire done;wire [7:0] status;wire [31:0] reply,score_config;
 wire command_valid,mode_valid;wire [1:0] command,song_req,mode_req;
 wire [1:0] song;wire start,toggle,restart,mode_cycle,pause_key;
 wire score_we,map_we,record_start,record_stop;
 integer checks=0,commands=0,modes=0,starts=0,toggles=0,restarts=0;
 integer old_commands,old_modes,old_starts,old_toggles,old_restarts,i,j,s;
 reg [31:0] saved_config;reg [1:0] saved_song,saved_mode;
 phone_extension_state #(.GUIDE_MODES_ENABLE(ENABLE)) dut(
  .clk(clk),.rst_n(rst_n),.request_valid(request),.op(op),.data(data),.done(done),.status(status),.reply(reply),
  .performance_idle(1'b1),.pixel_bank_ack(score_config[31]),.test_owned(owned),.score_config(score_config),
  .score_wr_en(score_we),.guide_command_valid(command_valid),.guide_command(command),.guide_song(song_req),
  .guide_mode_valid(mode_valid),.guide_mode_value(mode_req),.guide_status(guide_status),.mapping_wr_en(map_we),
  .mapping_wr_ready(1'b1),.mapping_commit_ready(1'b1),.mapping_commit_ack(1'b0),
  .record_start(record_start),.record_stop(record_stop),.record_active(1'b0),.record_busy(1'b0),
  .record_count(32'd0),.record_crc32(32'd0),.record_dropped(16'd0));
 four_button_display_control #(.DEBOUNCE_CYCLES(1),.LONG_PRESS_CYCLES(64),
  .CUSTOM_SONG_ENABLE(1),.GUIDE_MODES_ENABLE(ENABLE)) panel(
  .clk(clk),.rst_n(rst_n),.keys_n(4'hf),.guide_done(1'b0),.test_owned(owned),
  .custom_song_available(score_config[30]),.phone_song_command_valid(command_valid),.phone_song_command(command),
  .phone_song_id(song_req),.phone_guide_mode_valid(mode_valid),.guide_stop(1'b0),.phone_set_valid(1'b0),
  .phone_param(8'd0),.phone_value(8'd0),.song_id(song),.song_start(start),.song_toggle(toggle),
  .song_restart(restart),.guide_mode_cycle(mode_cycle),.key_pause(pause_key));
 always @(posedge clk)begin
  #1;if(rst_n)begin
   if(op>=20 && op<=22 && (score_we||map_we||record_start||record_stop))
    $fatal(1,"guide request leaked upload/record side effects");
   if(command_valid)commands=commands+1;if(mode_valid)modes=modes+1;
   if(start)starts=starts+1;if(toggle)toggles=toggles+1;if(restart)restarts=restarts+1;
   if(mode_cycle)$fatal(1,"phone mode incorrectly creates physical cycle");
  end
 end
 task tick(input integer n);repeat(n)begin @(posedge clk);#2;end endtask
 task check(input c,input [1023:0] m);
  begin checks=checks+1;if(c!==1'b1)$fatal(1,"%0s enable=%0d op=%0d data=%h status=%0d reply=%h",m,ENABLE,op,data,status,reply);end
 endtask
 task cmd(input [7:0] o,input [39:0] d,input [7:0] expect_status,input [31:0] expect_reply);
  integer timeout;
  begin
   @(negedge clk);op=o;data=d;request=1;tick(1);@(negedge clk);request=0;
   timeout=0;while(!done && timeout<300)begin tick(1);timeout=timeout+1;end
   check(done && status===expect_status && reply===expect_reply,"ACK status/reply");
   tick(12);check(!done && !command_valid && !mode_valid,"one-cycle done and command pulses");
  end
 endtask
 task remember;
  begin old_commands=commands;old_modes=modes;old_starts=starts;old_toggles=toggles;
   old_restarts=restarts;saved_config=score_config;saved_song=song;saved_mode=mode_req;end
 endtask
 task unchanged;
  check(commands==old_commands && modes==old_modes && starts==old_starts && toggles==old_toggles &&
   restarts==old_restarts && score_config===saved_config && song===saved_song && mode_req===saved_mode,
   "rejected/read-only request has no side effects");
 endtask
 initial begin
  tick(4);@(negedge clk);rst_n=1;tick(12);
  remember;for(i=0;i<4;i=i+1)cmd(20,i,6,0);unchanged;
  if(ENABLE)begin
   for(s=0;s<3;s=s+1)begin
    cmd(20,40'h10000+(s<<8),0,32'h10000+(s<<8));
    check(song==s && pause_key,"explicit builtin selected before custom exists");
    old_starts=starts;cmd(20,40'h10001+(s<<8),0,32'h10001+(s<<8));
    check(song==s && !pause_key && starts==old_starts+1,"explicit builtin start");
    old_toggles=toggles;cmd(20,40'h10002+(s<<8),0,32'h10002+(s<<8));
    check(toggles==old_toggles+1,"explicit builtin toggle");
    old_restarts=restarts;cmd(20,40'h10003+(s<<8),0,32'h10003+(s<<8));
    check(restarts==old_restarts+1,"explicit builtin restart");
   end
   remember;cmd(20,40'h10301,6,0);unchanged;
  end
  // Build the smallest valid custom score through real BEGIN/WRITE/COMMIT;
  // zero words are rests, and their checksum is zero. No force of config.
  cmd(16,(40'd23437<<16)+(40'd9<<8)+1,0,0);
  for(i=0;i<9;i=i+1)cmd(17,i,0,i+1);
  cmd(18,0,0,{1'b1,1'b1,6'd1,6'd3,18'd23437});
  check(score_config[30] && song==3 && pause_key,"real custom commit selects custom and waits");
  for(i=0;i<4;i=i+1)begin
   old_commands=commands;cmd(20,i,0,i);
   check(commands==old_commands+1 && command==i && song_req==3 && song==3,"legacy actions target custom");
  end
  $display("CASE_PASS phone_op20_legacy_custom_and_explicit_builtins");
  if(ENABLE)begin
   for(s=0;s<4;s=s+1)for(i=0;i<4;i=i+1)begin
    cmd(20,40'h10000+(s<<8)+i,0,32'h10000+(s<<8)+i);
    check(song_req==s && song==s && command==i,"all explicit song/action combinations");
   end
   for(i=2;i<40;i=i+1)if(i!=8 && i!=9 && i!=16)begin
    remember;cmd(20,40'h10001|(40'd1<<i),2,0);unchanged;
   end
   for(i=1;i<4;i=i+1)begin remember;cmd(20,(i<<8)|1,2,0);unchanged;end
  end else begin
   for(i=2;i<40;i=i+1)begin remember;cmd(20,40'd1<<i,2,0);unchanged;end
  end
  @(negedge clk);owned=1;remember;cmd(20,1,3,0);unchanged;
  if(ENABLE)begin remember;cmd(20,40'h10001,3,0);unchanged;end
  @(negedge clk);owned=0;
  $display("CASE_PASS phone_op20_reserved_bits_owned_and_legacy_parameter");
  for(i=0;i<3;i=i+1)begin
   remember;cmd(21,i,ENABLE?0:1,ENABLE?i:0);
   if(ENABLE)check(modes==old_modes+1 && mode_req==i && restarts==old_restarts+1 && commands==old_commands,
    "mode request ACK and exactly one panel restart");else unchanged;
  end
  remember;cmd(21,3,ENABLE?2:1,0);unchanged;
  for(i=2;i<40;i=i+1)begin remember;cmd(21,40'd1<<i,ENABLE?2:1,0);unchanged;end
  @(negedge clk);owned=1;remember;cmd(21,1,ENABLE?3:1,0);unchanged;
  // Readback is legal during diagnostic ownership and never mutates mode/song.
  for(i=0;i<24;i=i+1)begin
   @(negedge clk);guide_status=(24'd1<<i);remember;
   cmd(22,0,ENABLE?0:1,ENABLE?{8'd0,guide_status}:0);unchanged;
  end
  @(negedge clk);guide_status=24'hffffff;remember;cmd(22,0,ENABLE?0:1,ENABLE?32'h00ffffff:0);unchanged;
  @(negedge clk);owned=0;
  for(i=0;i<40;i=i+1)begin remember;cmd(22,40'd1<<i,ENABLE?2:1,0);unchanged;end
  remember;cmd(255,0,1,0);unchanged;
  $display("CASE_PASS phone_op21_mode_ack_op22_24bit_readonly_invalid_payloads");
  $display("V045_PHONE_PASS checks=%0d enable=%0d commands=%0d modes=%0d",checks,ENABLE,commands,modes);$finish;
 end
 initial begin #1000000;$fatal(1,"phone timeout");end
endmodule
