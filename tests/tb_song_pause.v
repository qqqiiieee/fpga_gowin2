// 新测试模式只能暂停跟弹，不应清空曲目序号/进度或接受测试按键。
module tb_song_pause;
    reg clk=0;always #5 clk=~clk;
    reg rst_n=0,pause=0;
    reg [15:0] keys=0;
    wire active,done;wire [5:0] step;wire [7:0] progress;
    song_guide #(.BEAT_SAMPLES(100)) dut(.clk(clk),.rst_n(rst_n),.sample_tick(1'b1),
        .pause(pause),.keys(keys),.ghost(1'b0),.active(active),.done(done),
        .cue_mask(),.next_mask(),.wrong_mask(),.step_index(step),.total_steps(),
        .beat_progress(progress),.target_beats());
    reg [7:0] saved_progress;reg saved_active;
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        repeat(3)@(negedge clk);keys=1;repeat(20)@(negedge clk);
        if(progress==0)$fatal(1,"no initial guide progress");
        pause=1;saved_progress=progress;saved_active=active;
        keys=16'h3000;repeat(300)@(negedge clk);
        if(step!=0 || progress!==saved_progress || active!==saved_active || done)
            $fatal(1,"test pause changed guide through restart keys");
        keys=16'h9000;repeat(300)@(negedge clk);
        if(progress!==saved_progress || active!==saved_active)$fatal(1,"pause accepted toggle");
        keys=1;pause=0;repeat(10)@(negedge clk);
        if(progress<=saved_progress)$fatal(1,"guide did not resume beat progress");
        keys=0;repeat(3)@(negedge clk);
        if(step!=1)$fatal(1,"guide did not resume from previous score step");
        $display("SONG_PAUSE_TEST_PASS preserved score/progress/control state");$finish;
    end
endmodule
