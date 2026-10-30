`timescale 1ns/1ps
// Real ADS1115 I2C transactions + real 31,250-baud MIDI parser. Only I2C wait
// and optical gesture/player counters are scaled; no input values are forced.
module tb_v033_no_sliders;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 tri1 scl,sda;
 reg midi_rx=1,strum=0,pset=0;
 reg [7:0] param=0,value=0;
 reg [1:0] beams=3;
 reg [63:0] analog_values={16'd26400,16'd0,16'd900,16'd800};
 wire [7:0] volume,e0,e1;wire signed [8:0] pitch;
 wire [1:0] calibrated,source;wire [6:0] note;wire on_event,off_event;
 wire [63:0] adc_values;wire adc_fault,ready;
 integer checks=0,samples=0,ons=0,i,base,n;
 reg [6:0] played[0:31];
 instrument_inputs #(.MIDI_ENABLE(1),.OPTICAL_ENABLE(1),.TOUCH_ENABLE(0),
    .DISPLAY_TOUCH_ONLY(1),.PRESSURE_EXPRESSION_ENABLE(1)) dut(
    .clk(clk),.rst_n(rst_n),.matrix_rows(),.matrix_cols(4'hf),.adc_scl(scl),.adc_sda(sda),
    .uart_rx(1'b1),.uart_tx(),.synth_overrun(1'b0),.suppress_controls(1'b0),
    .note_on(on_event),.note_off(off_event),.note(note),.velocity(),.timbre(),
    .key_state(),.selected_timbre(),.keypad_ghost(),.slider_volume(volume),.slider_pitch(pitch),
    .hit0(),.hit1(),.velocity0(),.velocity1(),.digital_zero_test(),.adc_fault(adc_fault),.adc_stale(),
    .monitor_ready(ready),.monitor_remote(),.monitor_adc(adc_values),.touch_cs_n(),.touch_sclk(),.touch_mosi(),.touch_miso(1'b0),
    .midi_rx(midi_rx),.optical_beams(beams),.sample_tick(1'b1),.allow_performance(1'b1),
    .note_source(source),.panic_audio(),.performance_keys(),.external_note(),.external_note_valid(),
    .pressure_brightness(e0),.pressure_vibrato(e1),.pressure_calibrated(calibrated),
    .ui_panic(1'b0),.ui_strum_mode(strum),.ui_timbre_set_valid(1'b0),.ui_timbre_set_value(4'd0),
    .ui_filter_enable(1'b1),.ui_zero_mode(1'b0),.control_page(2'd2),.ui_fx_cycle(1'b0),
    .phone_set_valid(pset),.phone_param(param),.phone_value(value),.phone_query_param(8'd0));
 mock_ads1115 adc_model(.rst(rst_n),.analog_values(analog_values),.scl(scl),.sda(sda));
 defparam dut.adc.I2C_QUARTER=2;
 defparam dut.adc.CONVERT_CYCLES=16;
 defparam dut.adc.RETRY_CYCLES=128;
 defparam dut.adc.BYTE_TIMEOUT_CYCLES=10000;
 defparam dut.performance.optical_input.gesture.CLK_HZ=27000;
 defparam dut.performance.optical_input.gesture.FILTER_CYCLES=4;
 defparam dut.performance.optical_input.gesture.STARTUP_CYCLES=64;
 defparam dut.performance.optical_input.gesture.PAIR_WINDOW_CYCLES=512;
 defparam dut.performance.optical_input.player.CLK_HZ=27000;
 always @(posedge clk)if(rst_n)begin
    if(dut.hw_adc_valid)begin
       samples=samples+1;
       if(dut.hw_adc_channel>=2)$fatal(1,"Removed slider channel still polled");
    end
    if(on_event && source==2)begin
       if(ons>=32)$fatal(1,"Too many optical notes");played[ons]=note;ons=ons+1;
    end
 end
 task clocks(input integer c);repeat(c)@(negedge clk);endtask
 task check(input condition,input [8*110-1:0] message);begin
    checks=checks+1;if(condition!==1)$fatal(1,"%0s volume=%0d pitch=%0d pressure=%0d/%0d",message,volume,pitch,e0,e1);
 end endtask
 task sample_pairs(input integer pairs);integer target;begin
    target=samples+2*pairs;n=0;
    while(samples<target && n<500000)begin clocks(1);n=n+1;end
    check(samples>=target,"I2C sample progress");clocks(3);
 end endtask
 task midi_byte(input [7:0] b);integer k;begin
    @(negedge clk);midi_rx=0;clocks(864);
    for(k=0;k<8;k=k+1)begin midi_rx=b[k];clocks(864);end
    midi_rx=1;clocks(864);
 end endtask
 task message(input [7:0] s,a,b);begin midi_byte(s);midi_byte(a);midi_byte(b);clocks(100);end endtask
 task phone(input [7:0] p,v);begin
    @(negedge clk);param=p;value=v;pset=1;clocks(1);pset=0;clocks(8);
 end endtask
 task gesture(input reverse);begin
    beams=reverse?2'b01:2'b10;clocks(50);beams=0;clocks(1200);
    beams=3;clocks(5000);
 end endtask
 initial begin
    clocks(8);rst_n=1;sample_pairs(24);
    check(calibrated==3 && ready && !adc_fault,"FSR calibrates without either slider");
    check(volume==160 && pitch==0,"Startup volume160 and neutral bend");
    check(adc_values[63:32]==0,"Removed channels never published");
    phone(0,202);check(volume==202,"Phone master volume owns control");
    for(i=0;i<4;i=i+1)begin
       analog_values[63:32]=i[0]?32'h7fff0000:32'h00007fff;sample_pairs(3);
       check(volume==202 && pitch==0,"Disconnected slider values cannot steal phone volume");
    end
    message(8'hb0,74,0);message(8'hb0,74,127);check(volume==255,"K4 pickup and maximum volume");
    message(8'hb0,74,64);check(volume==129,"K4 intermediate volume");
    message(8'he0,127,127);check(pitch==255,"MIDI Pitch Bend remains active");
    analog_values[63:32]=32'h80007fff;sample_pairs(8);
    check(volume==129 && pitch==255,"ADC changes cannot steal K4/bend");
    message(8'he0,0,64);check(pitch==0,"MIDI bend returns to centre");
    analog_values[15:0]=4896;analog_values[31:16]=1924;sample_pairs(24);
    check(e0>=240 && e1>=60 && calibrated==3,"Both continuous FSR controls retained");
    check(volume==129,"FSR pressure does not replace master volume");
    analog_values[15:0]=800;analog_values[31:16]=900;sample_pairs(24);
    check(e0==0 && e1==0,"FSR release returns to zero");
    base=ons;gesture(0);check(ons==base,"KEYBOARD mode suppresses optical audio");
    strum=1;clocks(100);message(8'h90,60,100);message(8'h90,64,100);message(8'h90,67,100);
    base=ons;gesture(0);
    check(ons==base+3 && played[base]==60 && played[base+1]==64 && played[base+2]==67,"A then B: chosen chord ascending");
    base=ons;gesture(1);
    check(ons==base+3 && played[base]==67 && played[base+1]==64 && played[base+2]==60,"B then A: chosen chord descending");
    message(8'h80,60,0);message(8'h80,64,0);message(8'h80,67,0);base=ons;gesture(0);
    check(ons==base+4 && played[base]==60 && played[base+1]==64 && played[base+2]==67 && played[base+3]==72,"Empty keyboard: default C4 E4 G4 C5 chord");
    $display("V033_NO_SLIDERS_PASS checks=%0d ADS_I2C_samples=%0d optical_notes=%0d K4_phone_bend_FSR_ASC_DESC_default=PASS",checks,samples,ons);$finish;
 end
 initial begin #100000000;$fatal(1,"V033 integration watchdog");end
endmodule
