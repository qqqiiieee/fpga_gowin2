`timescale 1ns/1ps
// 真正的top层连接测试。仅HDMI物理发送器替换为边界桩，不能据此宣称显示已实测。
// Adapted V024: real phone/MIDI/USB serial pins and 32 voices; debounced GPIO keys replace touch.
`include "hdmi_display_stub.vh"
module tb_fourphone_system;
 reg clk=0;always #18.518 clk=~clk;
 reg phone_rx=1,midi_rx=1,debug_rx=1,miso=0;reg[1:0]beams=3;
 tri1 scl,sda;wire phone_tx,debug_tx,cs,sck,mosi;
 reg [3:0] buttons_n=15;
 top #(.BUTTON_DEBOUNCE_CYCLES(4)) dut(.clk(clk),.ui_buttons_n(buttons_n),.phone_uart_rx(phone_rx),.phone_uart_tx(phone_tx),
  .uart_rx(debug_rx),.uart_tx(debug_tx),.midi_rx(midi_rx),.optical_beams(beams),
  .touch_miso(miso),.touch_cs_n(cs),.touch_sclk(sck),.touch_mosi(mosi),
  .adc_scl(scl),.adc_sda(sda),.hp_bck(),.hp_ws(),.hp_din(),.pa_en(),
  .amp_bck(),.amp_lrc(),.amp_din(),.timbre_led_n(),
  .tmds_clk_p(),.tmds_clk_n(),.tmds_data_p(),.tmds_data_n());
 defparam dut.GUIDE_BEAT_SAMPLES=67;
 defparam dut.u_audio.input_hub.performance.optical_input.gesture.FILTER_CYCLES=8;
 defparam dut.u_audio.input_hub.performance.optical_input.gesture.STARTUP_CYCLES=128;
 defparam dut.u_audio.input_hub.performance.optical_input.gesture.CLK_HZ=27000;
 defparam dut.u_audio.input_hub.performance.optical_input.gesture.PAIR_WINDOW_CYCLES=2048;
 defparam dut.u_audio.input_hub.performance.optical_input.player.CLK_HZ=27000;
 wire[7:0]pbyte,dbyte;wire pvalid,dvalid,perror,derror;
 midi_uart_rx #(.BAUD(115200)) pmon(.clk(clk),.rst_n(dut.rst_n),.rx(phone_tx),.data(pbyte),.data_valid(pvalid),.framing_error(perror));
 midi_uart_rx #(.BAUD(115200)) dmon(.clk(clk),.rst_n(dut.rst_n),.rx(debug_tx),.data(dbyte),.data_valid(dvalid),.framing_error(derror));
 integer pr=0,dr=0,note_ons=0,pcm_nonzero=0,kicks=0,snares=0,closed=0,opened=0;
 reg[7:0]reply[0:1023];reg[7:0]dreplies[0:63];
 always @(posedge clk)begin
  if(dut.rst_n)begin
   if(pvalid)begin reply[pr]=pbyte;pr=pr+1;end
   if(dvalid)begin dreplies[dr]=dbyte;dr=dr+1;end
   if(perror || derror)$fatal(1,"UART TX frame error");
   if(dut.u_audio.note_on)note_ons=note_ons+1;
   if(dut.u_audio.hit0)kicks=kicks+1;
   if(dut.u_audio.hit1)snares=snares+1;
   if(dut.u_audio.hat_closed_hit)closed=closed+1;
   if(dut.u_audio.hat_open_hit)opened=opened+1;
   if(dut.u_audio.overrun)$fatal(1,"synth overrun");
   if(dut.sample_tick)begin
    if((^dut.pcm)===1'bx)$fatal(1,"PCM X");
    if(dut.pcm!=0)pcm_nonzero=pcm_nonzero+1;
   end
  end
 end
 task clocks(input integer n);begin repeat(n)@(negedge clk);end endtask
 task phone_byte(input[7:0]v);integer b;begin
  @(negedge clk);phone_rx=0;clocks(234);
  for(b=0;b<8;b=b+1)begin phone_rx=v[b];clocks(234);end
  phone_rx=1;clocks(234);
 end endtask
 integer seq=0;
 task phone(input[7:0]cmd,p,v,expected);integer base,b,age;reg[7:0]check;begin
  base=pr;phone_byte(8'ha5);phone_byte(8'h5a);phone_byte(1);phone_byte(seq);
  phone_byte(cmd);phone_byte(p);phone_byte(v);
  repeat(4)phone_byte(0);phone_byte(1^seq^cmd^p^v);
  age=0;while(pr<base+12 && age<40000)begin clocks(1);age=age+1;end
  if(pr!=base+12 || reply[base]!=8'h5a || reply[base+1]!=8'ha5 || reply[base+2]!=1 ||
    reply[base+3]!=seq || reply[base+4]!=0 || reply[base+5]!=p || reply[base+6]!=expected)
     $fatal(1,"system phone ACK param=%0d actual=%0d expected=%0d result=%0d",p,reply[base+6],expected,reply[base+4]);
  check=0;for(b=2;b<11;b=b+1)check=check^reply[base+b];
  if(reply[base+11]!=check)$fatal(1,"system phone XOR");
  seq=(seq+1)&255;clocks(100);
 end endtask
 task midi_byte(input[7:0]v);integer b;begin
  @(negedge clk);midi_rx=0;clocks(864);
  for(b=0;b<8;b=b+1)begin midi_rx=v[b];clocks(864);end
  midi_rx=1;clocks(864);
 end endtask
 task midi(input[7:0]s,a,b);begin midi_byte(s);midi_byte(a);midi_byte(b);clocks(200);end endtask
 task debug_byte(input[7:0]v);integer b;begin
  @(negedge clk);debug_rx=0;clocks(234);
  for(b=0;b<8;b=b+1)begin debug_rx=v[b];clocks(234);end
  debug_rx=1;clocks(234);
 end endtask
 task click(input integer n);begin
  buttons_n=~(4'b1<<n);clocks(30);
  if(dut.u_display.ui_controls!==(4'b1<<n))$fatal(1,"display button bit %0d",n);
  buttons_n=15;clocks(1024);
 end endtask
 integer optical_ons=0;reg [6:0] optical_notes[0:7];
 always @(posedge clk)if(dut.rst_n)begin
  if(dut.u_audio.note_on && dut.u_audio.note_source==2)begin
   if(optical_ons>=8)$fatal(1,"extra optical event");
   optical_notes[optical_ons]=dut.u_audio.note;optical_ons=optical_ons+1;
  end
  if(cs!==1 || sck!==0 || mosi!==0)$fatal(1,"legacy touch SPI reactivated");
  if(dut.keys!==0 || dut.ui_test_keys!==0 || dut.u_audio.input_hub.local_on)
   $fatal(1,"legacy touch/test/local note input reactivated");
 end
 integer i,oldnotes,oldpcm;reg[11:0]frozen_tick;
 initial begin
  clocks(3000);
  if(!dut.menu_key_pause || dut.roll_tick!=0)$fatal(1,"startup must await first start");
  if(dut.control_page!=2 || dut.fx_mode!=0)$fatal(1,"fixed FX/default OFF");
  phone(1,0,220,220);phone(1,1,1,1);phone(1,3,1,1);
  phone(1,4,120,120);phone(1,5,96,96);phone(1,6,80,80);phone(1,7,48,48);
  phone(1,8,10,10);phone(1,9,80,80);phone(1,10,192,192);phone(1,11,100,100);
  phone(1,12,3,3);click(0); // KEY1 from diagnostic wraps to LIVE on release.
  if(dut.ui_page!=0)$fatal(1,"four-key release page after phone change");
  phone(1,13,0,0);phone(1,13,1,1);
  if(dut.u_audio.input_hub.local_on)$fatal(1,"UI generated musical note");
  $display("FOURPHONE_CHECKPOINT phone_all_control_paths");
  // Every real MIDI Pad is percussion, no melodic voice allocation.
  oldnotes=note_ons;midi(8'h99,36,100);midi(8'h99,37,100);midi(8'h99,38,100);midi(8'h99,39,100);
  if(kicks!=1 || snares!=1 || closed!=1 || opened!=1 || note_ons!=oldnotes)$fatal(1,"Pads not exclusively four drums");
  // 独立音高事件和屏幕位图均保留半音，不经自然音级摘要压缩。
  midi(8'h90,60,100);midi(8'h90,61,100);
  if(dut.piano_keys!==32'h00003000 || dut.piano_outside)$fatal(1,"C4/C#4 physical display lost sharp");
  midi(8'h80,60,0);if(dut.piano_keys!==32'h00002000)$fatal(1,"white release cleared black key");
  midi(8'h80,61,0);if(dut.piano_keys!==0)$fatal(1,"black release left key lit");
  midi(8'h90,35,100);if(!dut.piano_outside || dut.piano_keys!==0)$fatal(1,"out of visible range not indicated");
  midi(8'h80,35,0);if(dut.piano_outside)$fatal(1,"out of range release stuck");
  click(2); // KEY3 restarts autonomous visual timeline; only guide rate is accelerated.
  if(dut.roll_tick==0 || dut.guide_done)$fatal(1,"timeline restart did not advance");
  phone(1,12,1,1);frozen_tick=dut.roll_tick;clocks(1200);
  if(dut.roll_tick!==frozen_tick)$fatal(1,"non-LIVE page failed to freeze timeline");
  phone(1,12,0,0);clocks(1200);
  if(dut.roll_tick<=frozen_tick)$fatal(1,"LIVE resume did not advance timeline");
  oldnotes=note_ons;
  // Knob near current target catches it, then all pages preserve fixed FX mapping.
  midi(8'hb0,93,48);midi(8'hb0,93,60);phone(0,5,0,120);
  phone(1,12,1,1);midi(8'hb0,93,70);phone(0,5,0,141);
  if(dut.control_page!=2 || dut.volume!=220)$fatal(1,"knob changed page/master volume");
  // All four knobs keep fixed FX roles through both physical and phone pages.
  click(0);midi(8'hb0,91,40);midi(8'hb0,91,50);phone(0,6,0,100);
  click(0);midi(8'hb0,71,24);midi(8'hb0,71,35);phone(0,7,0,70);
  click(0);midi(8'hb0,74,60);midi(8'hb0,74,75);phone(0,4,0,151);
  if(dut.knob_values!=={8'd151,8'd70,8'd100,8'd141} || dut.control_page!=2 || dut.volume!=220)
   $fatal(1,"all four fixed FX knob targets/readback mismatch");
  phone(1,5,200,200);midi(8'hb0,93,71);phone(0,5,0,200);
  midi(8'hb0,93,100);phone(0,5,0,201);
  midi(8'hb0,93,90);phone(0,5,0,181);
  phone(0,8,0,10);phone(0,9,0,80);phone(0,10,0,192);phone(0,11,0,100);
  // Multiple notes run through real synth and FX. Phone actions do not own notes.
  oldpcm=pcm_nonzero;
  for(i=0;i<4;i=i+1)midi(8'h90,60+i*4,100);
  clocks(30000);phone(1,12,0,0);
  click(0);click(3);click(2);
  if(dut.u_audio.audio.gate==0)$fatal(1,"four keys killed held MIDI chord");
  if(note_ons-oldnotes!=4 || dut.busy==0 || pcm_nonzero<=oldpcm)$fatal(1,"phone integration killed audio");
  // Independent USB 09 diagnostics remain available while phone interface exists.
  debug_byte(8'ha5);debug_byte(8'h5a);debug_byte(17);debug_byte(8'h80);
  repeat(11)debug_byte(0);debug_byte(8'h91);clocks(45000);
  if(dr!=16 || dreplies[0]!=8'h5a || dreplies[1]!=8'ha5 || dreplies[2]!=9 || dreplies[3]!=17)$fatal(1,"USB 09 compatibility");
  if(!dreplies[12][3] || !dreplies[12][1] || !dreplies[12][2])$fatal(1,"raw optical capability/electrical bits");
  phone(0,0,0,220);
  // Panic clears gates and FX tail; then normal key release/repress recovers.
  phone(2,0,0,220);clocks(10000);
  if(dut.busy!=0 || dut.pcm!=0 || dut.u_audio.audio.gate!=0)$fatal(1,"phone Panic left audio");
  for(i=0;i<4;i=i+1)midi(8'h80,60+i*4,0);
  phone(1,14,1,1);midi(8'h90,72,100);clocks(1000);
  if(dut.pcm!=0)$fatal(1,"phone digital zero");
  phone(1,14,0,0);midi(8'h80,72,0);midi(8'h90,72,100);clocks(10000);
  if(dut.busy==0)$fatal(1,"zero exit/repress recovery");
  phone(1,2,1,1);clocks(1000);
  if(dut.u_audio.audio.gate!=0)$fatal(1,"KEY STRUM handover left gates");
  phone(0,2,0,1);
  midi(8'h80,72,0);oldnotes=note_ons;
  midi(8'h90,82,100);midi(8'h90,85,100);midi(8'h90,89,100);
  if(note_ons!=oldnotes || dut.u_audio.audio.gate!=0)$fatal(1,"strum chord selection sounded");
  if(dut.u_audio.input_hub.performance.held!==((128'b1<<82)|(128'b1<<85)|(128'b1<<89)))
   $fatal(1,"strum chord selection mismatch");
  beams=2'b10;clocks(300);beams=2'b00;clocks(300);beams=2'b11;clocks(3000);
  if(optical_ons!=3 || optical_notes[0]!=82 || optical_notes[1]!=85 || optical_notes[2]!=89)
   $fatal(1,"phone-enabled optical strum did not play selected chord");
  phone(1,2,0,0);phone(0,2,0,0);
  midi(8'h80,82,0);midi(8'h80,85,0);midi(8'h80,89,0);
  phone(1,13,0,0);phone(0,13,0,0);
  if(dut.u_audio.filter_enable!==0)$fatal(1,"filter disable did not reach audio");
  phone(1,13,1,1);phone(0,13,0,1);
  if(dut.u_audio.filter_enable!==1)$fatal(1,"filter enable did not reach audio");
  $display("FOURPHONE_SYSTEM_PASS piano_sharp_bitmap=1 roll_page_pause=1 phone_uart=1 fixed_knobs=1 pads4=1 four_keys=1 all_knobs_pickup=1 optical_strum=1 touch_disabled=1 usb09=1 raw_beams=1 panic=1 zero=1 pcm=%0d",pcm_nonzero);$finish;
 end
 initial begin #180000000;$fatal(1,"FOURPHONE system watchdog");end
endmodule
