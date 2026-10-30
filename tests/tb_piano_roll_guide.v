`timescale 1ns/1ps
// 独立参考：手工旋律字符串+逐音时值累加，与DUT按拍号分段的实现不同。
// 时间参考直接用有效采样数乘64再除拍长，仅测试端允许乘除。
module tb_piano_roll_guide;
    parameter TEST_BEAT_SAMPLES=67;
    localparam integer B=(TEST_BEAT_SAMPLES<1)?1:TEST_BEAT_SAMPLES;
    reg clk=0; always #5 clk=~clk;
    reg rst_n=1,sample_tick=0,pause=0,ui_start=0,ui_toggle=0,ui_restart=0;
    reg [1:0] song_id=0,query_song;
    reg [5:0] query_beat;
    wire [11:0] roll_tick,cue,next_cue;
    wire [1:0] roll_song,target_beats;
    wire active,done,beat_pulse,count_in,expected_valid;
    wire [5:0] step_index,total_steps,total_beats;
    wire [6:0] expected_note,qnote;
    wire [7:0] progress;
    wire qvalid,qonset;
    wire [5:0] qstep,qsteps,qbeats;
    piano_roll_guide #(.BEAT_SAMPLES(TEST_BEAT_SAMPLES)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(sample_tick),.pause(pause),
        .song_id(song_id),.ui_start(ui_start),.ui_toggle(ui_toggle),.ui_restart(ui_restart),
        .roll_tick(roll_tick),.roll_song(roll_song),.active(active),.done(done),
        .step_index(step_index),.total_steps(total_steps),.total_beats(total_beats),
        .beat_progress(progress),.target_beats(target_beats),.beat_pulse(beat_pulse),
        .expected_note(expected_note),.expected_valid(expected_valid),.cue_mask(cue),.next_mask(next_cue),.count_in(count_in));
    piano_roll_score lookup(.song_id(query_song),.beat_index(query_beat),.note(qnote),
        .valid(qvalid),.onset(qonset),.step_index(qstep),.total_steps(qsteps),.total_beats(qbeats));
    // 用自然音名手工列旋律，保留相邻重复音；不引用song_guide或DUT函数。
    reg [8*42-1:0] song0;
    reg [8*32-1:0] song1,song2;
    integer checks=0,s,b,i,k,used,oldtick,wanttick,ref_step,ref_note,ref_start,ref_duration;
    integer ref_total,ref_beats,wantprogress,canon;
    reg ref_valid,ref_onset;
    reg [11:0] ref_mask;
    task check;
        input condition;
        input [8*110-1:0] message;
        begin
            checks=checks+1;
            if(condition!==1)begin
                $display("PIANO_ROLL_GUIDE_FAIL B=%0d song=%0d tick=%0d used=%0d: %0s",
                         B,roll_song,roll_tick,used,message);
                $fatal(1,"piano roll assertion");
            end
        end
    endtask
    function integer duration;
        input integer song,index;
        begin
            // 独立逐步参考中只列句尾，完全不通过拍号反推音符。
            case(song)
                0: duration=((index+1)%7==0)?2:1;
                1: duration=((index+1)%8==0)?2:1;
                2: duration=(index==10||index==13||index==28||index==31)?2:1;
            endcase
        end
    endfunction
    task reference;
        input integer selected,absolute_beat;
        integer j,cursor,len,letter;
        begin
            canon=(selected==3)?0:selected;
            ref_total=(canon==0)?42:32; ref_beats=2;
            for(j=0;j<ref_total;j=j+1)ref_beats=ref_beats+duration(canon,j);
            ref_valid=0;ref_onset=0;ref_note=0;ref_step=0;ref_start=0;ref_duration=0;
            cursor=2;
            for(j=0;j<ref_total;j=j+1)begin
                len=duration(canon,j);
                if(absolute_beat>=cursor&&absolute_beat<cursor+len)begin
                    ref_valid=1;ref_onset=(absolute_beat==cursor);ref_step=j;
                    ref_start=cursor;ref_duration=len;
                    case(canon)
                        0:letter=song0[(41-j)*8 +: 8];
                        1:letter=song1[(31-j)*8 +: 8];
                        2:letter=song2[(31-j)*8 +: 8];
                    endcase
                    case(letter)
                        "C":ref_note=60;"D":ref_note=62;"E":ref_note=64;
                        "F":ref_note=65;"G":ref_note=67;"A":ref_note=69;
                        default:$fatal(1,"bad independent reference melody");
                    endcase
                end
                cursor=cursor+len;
            end
            if(absolute_beat>=ref_beats)ref_step=ref_total-1;
        end
    endtask
    task outputs;
        begin
            reference(roll_song,roll_tick/64);
            check(step_index==ref_step&&total_steps==ref_total&&total_beats==ref_beats,
                  "independent current step and totals");
            check(expected_note==ref_note&&expected_valid==(active&&!done&&ref_valid),
                  "independent absolute expected MIDI note");
            ref_mask=0;
            case(ref_note)
                60:ref_mask=1;62:ref_mask=2;64:ref_mask=4;
                65:ref_mask=8;67:ref_mask=16;69:ref_mask=32;
            endcase
            check(cue==((active&&!done&&ref_valid)?ref_mask:0),"cue is current note only");
            check(target_beats==((done||!ref_valid)?0:ref_duration),"one/two-beat cue length");
            wantprogress=done?255:(!ref_valid?0:((roll_tick-ref_start*64)*256/(ref_duration*64)));
            check(progress==wantprogress,"whole-note progress includes both beats");
            check(count_in==(!done&&roll_tick<128),"two beat count-in");
            reference(roll_song,ref_valid?(ref_start+ref_duration):2);
            ref_mask=0;
            case(ref_note)
                60:ref_mask=1;62:ref_mask=2;64:ref_mask=4;
                65:ref_mask=8;67:ref_mask=16;69:ref_mask=32;
            endcase
            check(next_cue==((active&&!done&&ref_valid)?ref_mask:0),"next cue skips complete long-note duration");
        end
    endtask
    task cycle;
        begin @(negedge clk); @(posedge clk); #1; end
    endtask
    task restart_song;
        input integer selected;
        input integer start_not_restart;
        begin
            @(negedge clk); song_id=selected;ui_start=start_not_restart;ui_restart=!start_not_restart;
            @(posedge clk);#1;
            used=0;
            check(roll_tick==0&&active&&!done&&!beat_pulse,"start/restart resets timeline");
            check(roll_song==((selected==3)?0:selected),"start/restart latches normalized song");
            outputs;
            @(negedge clk);ui_start=0;ui_restart=0;ui_toggle=0;sample_tick=0;
        end
    endtask
    // 每个采样核对独立有理数位置和节拍脉冲；音符只在位置变化时重新查参考。
    task samples;
        input integer count;
        integer n;
        begin
            for(n=0;n<count;n=n+1)begin
                @(negedge clk);sample_tick=1;oldtick=roll_tick;
                @(posedge clk);#1;
                used=used+1;
                wanttick=(used*64)/B;
                if(wanttick>total_beats*64)wanttick=total_beats*64;
                check(roll_tick==wanttick,"no fractional-tick drift at any sample");
                check(beat_pulse==((wanttick/64)!=(oldtick/64)),"one-clock beat boundary pulse");
                check(done==(used>=total_beats*B),"natural completion exactly after final duration");
                if(roll_tick!=oldtick)outputs;
            end
            @(negedge clk);sample_tick=0;
        end
    endtask
    initial begin
        song0="CCGGAAGFFEEDDCGGFFEEDGGFFEEDCCGGAAGFFEEDDC";
        song1="EEFGGFEDCCDEEDDDEEFGGFEDCCDEDCCC";
        // 两只老虎上行片段直接分组拼接，避免空格成为旋律字符。
        song2="CDECCDECEFGEFGGAGFECGAGFECCGCCGC";
        // 所有曲目和全部64拍穷举，覆盖预备、长音第二拍、边界及无效曲目3。
        for(s=0;s<4;s=s+1)for(b=0;b<64;b=b+1)begin
            query_song=s;query_beat=b;#1;reference(s,b);
            if(qnote!==ref_note||qvalid!==ref_valid||qonset!==ref_onset||qstep!==ref_step||
               qsteps!==ref_total||qbeats!==ref_beats)
                $display("lookup song=%0d beat=%0d got note=%0d valid=%0d onset=%0d step=%0d totals=%0d/%0d ref=%0d/%0d/%0d/%0d/%0d/%0d",
                         s,b,qnote,qvalid,qonset,qstep,qsteps,qbeats,ref_note,ref_valid,ref_onset,ref_step,ref_total,ref_beats);
            check(qnote==ref_note&&qvalid==ref_valid&&qonset==ref_onset&&qstep==ref_step&&
                  qsteps==ref_total&&qbeats==ref_beats,"exhaustive independent score lookup");
        end
        rst_n=0;#1;used=0;check(active&&!done&&roll_tick==0&&roll_song==0,"async reset");outputs;
        @(negedge clk);rst_n=1;
        // 仅主时钟和曲目输入变化都不能推进或切曲。
        song_id=2;repeat(7)cycle;
        check(roll_tick==0&&roll_song==0&&!beat_pulse,"clock-only idle and latched song");
        for(s=0;s<3;s=s+1)begin
            restart_song(s,1);
            samples(B+((B>3)?3:0));
            oldtick=roll_tick;
            // 外部所有权暂停保留分数相位；恢复后的独立参考仍用原used计数。
            @(negedge clk);pause=1;sample_tick=1;
            repeat(13)begin cycle;check(roll_tick==oldtick&&!beat_pulse,"ownership pause freezes");end
            @(negedge clk);pause=0;sample_tick=0;
            samples(1);
            // toggle优先于采样，暂停期间外部pause变化不会丢失用户暂停状态。
            @(negedge clk);ui_toggle=1;sample_tick=1;oldtick=roll_tick;
            @(posedge clk);#1;check(!active&&roll_tick==oldtick&&!beat_pulse,"toggle pauses");
            @(negedge clk);ui_toggle=0;pause=1;
            repeat(3)cycle;
            @(negedge clk);pause=0;repeat(5)cycle;
            check(!active&&roll_tick==oldtick,"leaving menu does not unpause user pause");
            @(negedge clk);ui_toggle=1;
            @(posedge clk);#1;check(active&&roll_tick==oldtick,"toggle resumes without phase reset");
            @(negedge clk);ui_toggle=0;sample_tick=0;
            samples(total_beats*B-used-1);
            check(!done&&active&&step_index==total_steps-1&&target_beats==2,"last note still running before final sample");
            samples(1);
            check(done&&!active&&progress==255,"full final duration completed");outputs;
            oldtick=roll_tick;
            @(negedge clk);sample_tick=1;ui_toggle=1;
            cycle;
            @(negedge clk);ui_toggle=0;repeat(9)cycle;
            check(done&&!active&&roll_tick==oldtick&&!beat_pulse,"done stays latched with samples/toggle");
            @(negedge clk);sample_tick=0;
        end
        // 在所有权暂停、采样和toggle同拍时，重开仍有最高优先级。
        pause=1;sample_tick=1;ui_toggle=1;
        restart_song(2,0);
        check(roll_song==2&&roll_tick==0,"restart while paused");
        @(negedge clk);ui_toggle=0;sample_tick=1;repeat(5)cycle;
        check(roll_tick==0&&active,"pause still respected after restart");
        @(negedge clk);pause=0;sample_tick=0;
        samples(B*2);check(roll_tick==128&&expected_note==60,"first cue after exactly two beats");
        restart_song(3,0);check(roll_song==0,"invalid song normalizes to zero");
        samples(1);restart_song(1,1);samples(1);
        check(roll_tick==(64/B),"restart clears fractional phase");
        $display("PIANO_ROLL_GUIDE_TEST_PASS B=%0d checks=%0d lookup=256 full_songs=3 no_drift=1 pause_restart=1",B,checks);
        $finish;
    end
    initial begin #2000000000;$fatal(1,"piano roll watchdog");end
endmodule
