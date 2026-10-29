`timescale 1ns/1ps
// 原12键之外的7位MIDI代表音符/Hz显示；高Hz不会静默丢失万位。
module tb_midi_telemetry_range;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg[6:0] ext_note=69;reg ext_valid=1;reg signed[8:0] pitch=0;
 wire[15:0] hz,bcd;wire[6:0] note;wire valid;
 instrument_telemetry #(.EXTERNAL_NOTE_ENABLE(1)) dut(
 .clk(clk),.rst_n(rst_n),.sample_tick(1'b0),.pcm(16'd0),.keys(12'd0),.volume(8'd160),.pitch(pitch),.busy(32'd0),
 .peak(),.rms(),.level_dbfs(),.peak_percent(),.volume_percent(),.voices(),.primary_note(note),.note_valid(valid),
 .frequency_hz(hz),.frequency_bcd(bcd),.clip(),.external_note(ext_note),.external_note_valid(ext_valid));
 initial begin
 repeat(3)@(negedge clk);rst_n=1;repeat(100)@(negedge clk);
 if(!valid||note!=69||hz!=440||bcd!==16'h0440)$fatal(1,"MIDI telemetry A4");
 ext_note=127;repeat(100)@(negedge clk);
 if(!valid||note!=127||hz<12542||hz>12545||bcd!==16'h9999)$fatal(1,"MIDI telemetry high clamp note=%0d Hz=%0d BCD=%h",note,hz,bcd);
 ext_note=0;repeat(100)@(negedge clk);
 if(!valid||note!=0||hz<8||hz>9||bcd!==16'h0008)$fatal(1,"MIDI telemetry low note");
 ext_valid=0;repeat(100)@(negedge clk);
 if(valid||hz!=0||bcd!=0)$fatal(1,"MIDI telemetry note invalid");
 $display("MIDI_TELEMETRY_RANGE_TEST_PASS notes_0_69_127=1 high_hz_clamp=1 independent_from_12_keys=1");$finish;
 end
endmodule
