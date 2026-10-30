`timescale 1ns/1ps
module tb_note_table_midi_range;
 reg[6:0] note=0;wire[23:0] increment;reg[23:0] old[0:127];integer n;real target,actual,cents,max_cents;
 note_table dut(note,increment);
 initial begin
 $readmemh("tests/fixtures/note_table_v018.hex",old);max_cents=0;
 // 独立组合模块没有复位口，先给一次真实输入变化，避免仿真初值同0不触发@*。
 note=127;#1;
 for(n=0;n<128;n=n+1)begin
 note=n;#1;
 if((^increment)===1'bx||increment==0)$fatal(1,"MIDI note table missing %0d",n);
 if(n>=21&&n<=108&&increment!==old[n])$fatal(1,"MIDI changed old note %0d",n);
 target=440.0*(2.0**((n-69)/12.0));actual=(increment*93750.0)/16777216.0;
 cents=1200.0*$ln(actual/target)/$ln(2.0);if(cents<0)cents=-cents;
 if(cents>max_cents)max_cents=cents;
 if(cents>1.5)$fatal(1,"MIDI table out of tune note=%0d cents=%f",n,cents);
 end
 $display("NOTE_TABLE_MIDI_RANGE_TEST_PASS full_range=128 legacy_exact=88 max_cents=%f",max_cents);$finish;
 end
endmodule
