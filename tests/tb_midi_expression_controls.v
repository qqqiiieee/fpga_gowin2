`timescale 1ns/1ps
// 串口CC/弯音→最后变化来源仲裁；合成时钟使能在此加速，检查LFO幅度/归零。
module tb_midi_expression_controls;
 reg clk=0,rst_n=0,rx=1;always #5 clk=~clk;
 reg[7:0] physical_volume=50;reg signed[8:0] physical_pitch=0;
 wire[7:0] volume;wire signed[8:0] pitch;wire panic;
 integer minimum=0,maximum=0,i,panics=0;
 performance_input_hub #(.MIDI_ENABLE(1)) dut(
 .clk(clk),.rst_n(rst_n),.sample_tick(1'b1),.allow_performance(1'b1),.suppress_controls(1'b0),
 .remote_active(1'b0),.digital_zero(1'b0),.midi_rx(rx),.optical_beams(2'b11),
 .local_on(1'b0),.local_off(1'b0),.local_note(7'd0),.local_velocity(8'd0),.local_timbre(4'd0),
 .selected_timbre(4'd0),.local_keys(16'd0),.physical_volume(physical_volume),.physical_pitch(physical_pitch),
 .note_on(),.note_off(),.note(),.velocity(),.timbre(),.event_source(),.volume(volume),.pitch(pitch),
 .program_valid(),.program_timbre(),.midi_hit0(),.midi_hit1(),.midi_drum_velocity0(),.midi_drum_velocity1(),
 .panic_audio(panic),.performance_keys(),.primary_note(),.primary_valid(),.diagnostic_status());
 always@(posedge clk)if(panic)panics=panics+1;
 task byte_midi;input[7:0] data;integer b;begin
 @(negedge clk);rx=0;repeat(864)@(negedge clk);
 for(b=0;b<8;b=b+1)begin rx=data[b];repeat(864)@(negedge clk);end
 rx=1;repeat(864)@(negedge clk);end endtask
 task message;input[7:0] s,a,b;begin byte_midi(s);byte_midi(a);byte_midi(b);repeat(50)@(negedge clk);end endtask
 initial begin
 repeat(5)@(negedge clk);rst_n=1;repeat(5)@(negedge clk);
 if(volume!=50)$fatal(1,"physical volume initial");
 message(8'hb0,7,100);if(volume!=201)$fatal(1,"MIDI first volume ownership");
 physical_volume=90;repeat(5)@(negedge clk);if(volume!=90)$fatal(1,"physical volume retake");
 message(8'hb0,7,100);if(volume!=90)$fatal(1,"unchanged MIDI volume stole ownership");
 message(8'hb0,7,101);if(volume!=203)$fatal(1,"changed MIDI volume failed retake");
 message(8'he0,127,127);if(pitch!==9'sd255)$fatal(1,"MIDI first bend ownership");
 physical_pitch=-30;repeat(5)@(negedge clk);if(pitch!==-9'sd30)$fatal(1,"physical pitch retake");
 message(8'he0,127,127);if(pitch!==-9'sd30)$fatal(1,"unchanged MIDI bend stole ownership");
 message(8'he0,0,64);if(pitch!==0)$fatal(1,"changed MIDI bend failed retake");
 physical_pitch=0;repeat(5)@(negedge clk);
 message(8'hb0,1,127);
 for(i=0;i<20000;i=i+1)begin @(negedge clk);if(pitch<minimum)minimum=pitch;if(pitch>maximum)maximum=pitch;end
 if(minimum> -40||maximum<40)$fatal(1,"CC1 vibrato not significant min=%0d max=%0d",minimum,maximum);
 message(8'hb0,1,0);if(pitch!==0)$fatal(1,"CC1 zero left vibrato");
 message(8'hb0,120,0);
 if(panics!=1||volume!=90||pitch!=0)$fatal(1,"panic controls did not return to physical");
 $display("MIDI_EXPRESSION_CONTROLS_TEST_PASS same_value_does_not_steal=1 physical_retake=1 changed_MIDI_retake=1 vibrato_min=%0d vibrato_max=%0d panic=%0d",minimum,maximum,panics);$finish;
 end
 initial begin #10000000;$fatal(1,"MIDI expression watchdog");end
endmodule
