`timescale 1ns/1ps
module tb_builtin_guide;
    parameter B=67;
    localparam integer FIXED=(B<1)?1:B;
    reg clk=0;always #5 clk=~clk;
    reg rst=0,sample=0,pause=0,start=0,restart=0,toggle=0;
    reg [1:0] song=0;
    wire [11:0] tick,cue,nextcue;
    wire [1:0] selected,target;
    wire active,done,pulse,ready,valid,countin;
    wire [6:0] note;
    wire [5:0] step,steps,beats;
    wire [7:0] progress;
    piano_roll_guide #(.BEAT_SAMPLES(B),.SONG_LIBRARY_ENABLE(1)) dut(
        .clk(clk),.rst_n(rst),.sample_tick(sample),.pause(pause),.song_id(song),
        .ui_start(start),.ui_restart(restart),.ui_toggle(toggle),.roll_tick(tick),
        .roll_song(selected),.active(active),.done(done),.beat_pulse(pulse),
        .score_ready(ready),.expected_note(note),.expected_valid(valid),
        .step_index(step),.total_steps(steps),.total_beats(beats),.beat_progress(progress),
        .target_beats(target),.cue_mask(cue),.next_mask(nextcue),.count_in(countin),
        .custom_write_clk(clk),.custom_write_en(1'b0),.custom_write_addr(9'd0),
        .custom_write_data(32'd0),.custom_config(32'd0));
    // Oracle is produced ONLY from source.json raw note/duration pairs by the
    // runner's independent chronological walk, not from the DUT HEX/include.
    reg [31:0] oracle[0:1023];
    reg [31:0] want;
    integer s,n,period,used,oldtick,wanttick,checks=0,bubbles=0,heldtick,heldphase;
    function [11:0] mask;
        input [6:0] pitch;
        begin
            case(pitch)
                60:mask=1;62:mask=2;64:mask=4;65:mask=8;67:mask=16;
                69:mask=32;71:mask=64;72:mask=128;74:mask=256;
                76:mask=512;77:mask=1024;79:mask=2048;default:mask=0;
            endcase
        end
    endfunction
    task check;
        input ok;input [8*90-1:0] message;
        begin checks=checks+1;if(ok!==1)
            $fatal(1,"B=%0d song=%0d used=%0d tick=%0d %0s",B,selected,used,tick,message);end
    endtask
    task outputs;
        begin
            want=oracle[{selected,tick[11:4]}];
            check(ready,"tag settled after idle clock (including rest/count-in/end)");
            check(note==want[6:0] && valid==(active&&!done&&want[13]),"pitch/valid from raw events");
            check(step==want[12:7],"step includes rests; final step retained");
            check(steps==(selected==0?42:48) && beats==(selected==0?50:34),"V045 metadata");
            check(cue==(valid?mask(want[6:0]):0),"legacy cue mapping only; no transposition");
            check(nextcue==((active&&!done&&want[23])?mask(want[22:16]):0),"next note skips rests/count-in/final");
            check(progress==(done?255:(valid?((tick%16)*16):0)),"quarter HUD progress");
            check(target==((!done&&want[13])?(want[15]?2:1):0),"coarse duration hint");
            check(countin==(!done&&tick<128),"count-in exactly two beats");
        end
    endtask
    task cycle;begin @(negedge clk);@(posedge clk);#1;end endtask
    task launch;
        input integer which;
        begin
            @(negedge clk);song=which;start=1;sample=0;
            @(posedge clk);#1;used=0;
            check(tick==0 && selected==which && active&&!done,"start latch/reset");
            if(which!=0)check(!ready&&!valid&&nextcue==0,"new song tag masks old data");
            @(negedge clk);start=0;cycle;outputs;
        end
    endtask
    task samples;
        input integer count;
        integer i;
        begin
            for(i=0;i<count;i=i+1)begin
                @(negedge clk);sample=1;oldtick=tick;
                @(posedge clk);#1;used=used+1;
                wanttick=(used*64)/period;if(wanttick>beats*64)wanttick=beats*64;
                check(tick==wanttick,"exact floor(samples*64/period), no drift");
                check(pulse==((tick/64)!=(oldtick/64)),"single-cycle beat boundary pulse");
                check(done==(used>=beats*period),"full final duration and exact end");
                if(tick/16!=oldtick/16)begin
                    check(!ready&&!valid&&note==0&&cue==0&&nextcue==0,"old quarter cannot escape new tag");
                    bubbles=bubbles+1;
                end
                // Production has 287 idle source clocks per sample; one is
                // sufficient to settle the RAM even for B=1 accelerated runs.
                @(negedge clk);sample=0;@(posedge clk);#1;
                if(tick!=oldtick)outputs;
            end
        end
    endtask
    initial begin
        $readmemh("tests/builtin_score_v045/oracle.hex",oracle);
        #1;rst=0;cycle;rst=1;cycle;
        for(s=0;s<3;s=s+1)begin
            period=(B==46875)?(s==0?46875:(s==1?50223:56250)):FIXED;
            launch(s);song=(s+1)%3; // live menu selection must not change song
            samples(period+3);
            heldtick=tick;heldphase=dut.fractional_phase;
            @(negedge clk);pause=1;sample=1;
            repeat(7)cycle;
            check(tick==heldtick && dut.fractional_phase==heldphase && !pulse,"ownership pause preserves phase");
            @(negedge clk);toggle=1;@(posedge clk);#1;
            check(!active && tick==heldtick,"toggle wins over sample");
            @(negedge clk);toggle=0;pause=0;repeat(3)cycle;
            check(!active && tick==heldtick,"leaving ownership pause retains user pause");
            @(negedge clk);toggle=1;@(posedge clk);#1;
            @(negedge clk);toggle=0;sample=0;
            samples(beats*period-used-1);
            check(active&&!done,"not complete before last sample");
            samples(1);outputs;
            check(done&&!active && progress==255,"natural completion");
            @(negedge clk);sample=1;toggle=1;cycle;
            @(negedge clk);toggle=0;repeat(3)cycle;
            check(done&&!active&&tick==beats*64,"toggle/sample cannot revive done");
            @(negedge clk);sample=0;
        end
        // Controls also win over sample during a frozen ownership interval.
        @(negedge clk);pause=1;sample=1;toggle=1;restart=1;song=1;
        @(posedge clk);#1;check(tick==0&&active&&!done&&selected==1,"restart priority");
        @(negedge clk);restart=0;toggle=0;repeat(3)cycle;
        check(tick==0&&ready&&!valid,"restart count-in remains paused");
        $display("BUILTIN_GUIDE_PASS B=%0d checks=%0d bubbles=%0d songs=3 exact_BPM_duration=1",B,checks,bubbles);
        $finish;
    end
    initial begin #1000000000;$fatal(1,"guide watchdog");end
endmodule
