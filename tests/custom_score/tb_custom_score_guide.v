`timescale 1ns/1ps
module tb_custom_score_guide;
    parameter SPB=23437;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,sample_tick=0,pause=0,start=0,restart=0,toggle=0;
    reg [1:0] song=3;
    reg we=0;reg [8:0] wa=0;reg [31:0] wd=0,cfg=0;
    wire [11:0] tick,cue,nextcue;
    wire [1:0] selected,target;
    wire active,done,valid,countin,pulse;
    wire [6:0] note;wire [5:0] step,steps,beats;wire [7:0] progress;
    piano_roll_guide #(.CUSTOM_SCORE_ENABLE(1),.BEAT_SAMPLES(67)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.pause(pause),
        .song_id(song),.ui_start(start),.ui_toggle(toggle),.ui_restart(restart),
        .roll_tick(tick),.roll_song(selected),.active(active),.done(done),
        .expected_note(note),.expected_valid(valid),.step_index(step),
        .total_steps(steps),.total_beats(beats),.beat_progress(progress),
        .target_beats(target),.beat_pulse(pulse),.cue_mask(cue),.next_mask(nextcue),
        .count_in(countin),.custom_write_clk(clk),.custom_write_en(we),
        .custom_write_addr(wa),.custom_write_data(wd),.custom_config(cfg));
    `include "tests/custom_score/score_fixture.vh"
    integer checks=0,n,q,oldtick,used=0,bank=0,want,oldphase,heldtick;
    reg [31:0] expected;
    function [11:0] fixture_mask;
        input [6:0] midi;
        begin
            case(midi)
                60:fixture_mask=1;62:fixture_mask=2;64:fixture_mask=4;
                65:fixture_mask=8;67:fixture_mask=16;69:fixture_mask=32;
                default:fixture_mask=0;
            endcase
        end
    endfunction
    task check;
        input condition;input [8*110-1:0] message;
        begin checks=checks+1;if(condition!==1)
            $fatal(1,"SPB=%0d sample=%0d tick=%0d bank=%0d %0s",SPB,used,tick,bank,message);
        end
    endtask
    task cycle;begin @(negedge clk);@(posedge clk);#1;end endtask
    task upload;
        input integer b;
        begin
            for(q=0;q<256;q=q+1)begin
                @(negedge clk);we=1;wa=b*256+q;wd=fixture_word(b,q);
                @(posedge clk);#1;
            end
            @(negedge clk);we=0;
        end
    endtask
    task launch;
        begin
            @(negedge clk);start=1;sample_tick=0;
            @(posedge clk);#1;used=0;
            check(tick==0 && selected==3,"custom start and latched song3");
            @(negedge clk);start=0;repeat(3)cycle;
        end
    endtask
    task samples;
        input integer count;
        integer i;
        begin
            for(i=0;i<count;i=i+1)begin
                @(negedge clk);sample_tick=1;oldtick=tick;
                @(posedge clk);#1;used=used+1;
                want=(used*64)/SPB;if(want>320)want=320;
                check(tick==want,"exact floor(samples*64/SPB), no cumulative drift");
                check(pulse==((tick/64)!=(oldtick/64)),"one-cycle beat pulse");
                check(done==(used>=5*SPB),"exact five-beat duration incl count-in/padding");
                check(countin==(!done && tick<128),"exact two-beat count-in");
                if(tick/16==oldtick/16)begin
                    expected=fixture_word(bank,tick/16);
                    check(valid==(active&&!done&&tick>=128&&expected[13]),"RAM current quarter validity");
                    check(cue==(valid?fixture_mask(expected[6:0]):0),"exact current visual cue mask");
                    check(nextcue==((active&&!done&&tick<320&&expected[23])?
                        fixture_mask(expected[22:16]):0),"precomputed next-note cue including count-in/rest");
                    if(valid)begin
                        check(note==expected[6:0] && step==expected[12:7],"RAM pitch and step");
                        check(progress==((tick%16)*16),"quarter progress without divider");
                        check(target==(expected[15]?2:1),"longnote HUD hint");
                    end
                    if(tick<128)check(!valid&&cue==0,"count-in never emits current cue");
                    if(tick>=288)check(!valid&&nextcue==0,"silent integer-beat tail");
                end else check(!valid,"old synchronous RAM word cannot leak at boundary");
            end
            @(negedge clk);sample_tick=0;repeat(2)cycle;
        end
    endtask
    initial begin
        #1;rst_n=0;repeat(3)cycle;rst_n=1;repeat(3)cycle;
        launch;check(done&&!active&&!valid&&steps==0&&beats==0,"no valid score safely finishes");
        upload(0);cfg=fixture_config(0,SPB);repeat(3)cycle;
        check(!done&&!active&&tick==0,"commit resets selected custom without undoing pause");
        launch;samples(SPB+19);heldtick=tick;oldphase=dut.fractional_phase;
        @(negedge clk);pause=1;sample_tick=1;
        repeat(19)begin cycle;check(tick==heldtick&&dut.fractional_phase==oldphase&&!pulse,"page/menu pause retains phase");end
        @(negedge clk);pause=0;sample_tick=0;
        samples(1);
        heldtick=tick;oldphase=dut.fractional_phase;
        @(negedge clk);toggle=1;sample_tick=1;@(posedge clk);#1;
        check(!active&&tick==heldtick,"user pause wins over sample");
        @(negedge clk);toggle=0;pause=1;repeat(4)cycle;
        @(negedge clk);pause=0;repeat(5)cycle;
        check(!active&&tick==heldtick&&dut.fractional_phase==oldphase,"page change does not undo user pause");
        @(negedge clk);toggle=1;@(posedge clk);#1;
        @(negedge clk);toggle=0;sample_tick=0;
        samples(2*SPB-used);check(tick==128&&valid&&note==60,"first note at exactly two beats");
        // Write inactive bank while source keeps displaying bank0.
        upload(1);repeat(3)cycle;check(note==60&&step==0,"inactive writes leave active source score intact");
        samples(5*SPB-used-1);check(!done&&active&&!valid,"final partial beat is silent, not early completion");
        samples(1);check(done&&!active&&tick==320&&step==4&&progress==255,"finished state");
        @(negedge clk);toggle=1;@(posedge clk);#1;check(done&&!active,"toggle cannot revive completed score");
        @(negedge clk);toggle=0;pause=1;cfg=fixture_config(1,SPB);bank=1;repeat(4)cycle;
        used=0;check(!active&&!done&&tick==0,"bank flip preserves paused completion state");
        launch;check(tick==0&&active,"explicit start through external pause");
        @(negedge clk);pause=0;samples(2*SPB);check(note==62&&valid,"new bank first note");
        // Changing only tempo is also a source config change/restart.
        @(negedge clk);cfg=fixture_config(1,31251);repeat(4)cycle;
        check(tick==0&&active&&!done,"tempo-only edit resets fractional phase");
        @(negedge clk);cfg[30]=0;repeat(4)cycle;
        check(done&&!valid&&note==0&&nextcue==0&&steps==0,"invalidated custom never falls back to song0");
        @(negedge clk);cfg=fixture_config(0,23436);repeat(4)cycle;
        check(done&&!valid,"out-of-range tempo rejected");
        @(negedge clk);cfg=fixture_config(0,187501);repeat(4)cycle;
        check(done&&!valid,"upper tempo limit rejected");
        @(negedge clk);cfg=fixture_config(0,SPB);cfg[29:24]=0;repeat(4)cycle;
        check(done&&!valid,"zero total_steps rejected");
        $display("CUSTOM_GUIDE_PASS SPB=%0d countin_samples=%0d duration_samples=%0d checks=%0d",SPB,2*SPB,5*SPB,checks);
        $finish;
    end
    initial begin #200000000;$fatal(1,"guide watchdog");end
endmodule
