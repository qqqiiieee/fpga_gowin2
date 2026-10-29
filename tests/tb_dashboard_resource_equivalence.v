`timescale 1ns/1ps
// 与冻结的V015渲染器逐像素比较；不调用DUT内部函数构造像素期望。
// 覆盖四页、帮助子页、测试优先级、可见区边界、数字字段和波形增益。
module tb_dashboard_resource_equivalence;
    reg clk=0,rst_n=0;
    always #5 clk=~clk;
    reg [9:0] x=0,y=0;
    reg de=1;
    reg [11:0] keys=0;
    reg [3:0] timbre=0,flags_low=0,scope_gain=0;
    reg [6:0] note=60;
    reg note_valid=1;
    reg [15:0] frequency_bcd=16'h0262;
    reg [7:0] volume_percent=73,peak_percent=86,pressure0=88,pressure1=128,flags=0,beat_progress=73;
    reg signed [7:0] level_dbfs=-18;
    reg signed [8:0] pitch=0;
    reg [5:0] voices=1,guide_step=1,guide_total=42,test_requested=32;
    reg guide_active=1,guide_done=0,test_active=0,test_sweep=0,test_overrun=0,wave_valid=1;
    reg [11:0] cue_mask=1,next_mask=2,wrong_mask=4;
    reg [1:0] target_beats=1,page=0,cursor=0,song=0;
    reg [3:0] controls=0;
    reg signed [15:0] wave_current=0,wave_previous=0;
    reg [31:0] test_busy=32'hffffffff,test_gate=32'hffffffff;
    reg [4:0] test_index=0;
    wire [23:0] expected,actual;
    integer px,py,scene,checks=0,frame_checks=0,seed=32'h12345678;
    reg [31:0] random_word;
    hdmi_instrument_dashboard #(.UI_ENABLE(1)) dut(.pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(de),
        .keys(keys),.ui_page(page),.ui_cursor(cursor),.ui_song(song),.ui_controls(controls),
        .timbre(timbre),.note(note),.note_valid(note_valid),.frequency_bcd(frequency_bcd),
        .volume_percent(volume_percent),.level_dbfs(level_dbfs),.peak_percent(peak_percent),.pitch(pitch),
        .voices(voices),.pressure0(pressure0),.pressure1(pressure1),.flags(flags),
        .guide_active(guide_active),.guide_done(guide_done),.cue_mask(cue_mask),.next_mask(next_mask),.wrong_mask(wrong_mask),
        .guide_step(guide_step),.guide_total(guide_total),.beat_progress(beat_progress),.target_beats(target_beats),
        .wave_current(wave_current),.wave_previous(wave_previous),.scope_gain(scope_gain),.wave_valid(wave_valid),
        .test_active(test_active),.test_requested(test_requested),.test_busy(test_busy),.test_gate(test_gate),
        .test_sweep(test_sweep),.test_index(test_index),.test_overrun(test_overrun),
        .red(actual[23:16]),.green(actual[15:8]),.blue(actual[7:0]));
    v015_dashboard_reference #(.UI_ENABLE(1)) reference(.pixel_clk(clk),.rst_n(rst_n),.x(x),.y(y),.de(de),
        .keys(keys),.ui_page(page),.ui_cursor(cursor),.ui_song(song),.ui_controls(controls),
        .timbre(timbre),.note(note),.note_valid(note_valid),.frequency_bcd(frequency_bcd),
        .volume_percent(volume_percent),.level_dbfs(level_dbfs),.peak_percent(peak_percent),.pitch(pitch),
        .voices(voices),.pressure0(pressure0),.pressure1(pressure1),.flags(flags),
        .guide_active(guide_active),.guide_done(guide_done),.cue_mask(cue_mask),.next_mask(next_mask),.wrong_mask(wrong_mask),
        .guide_step(guide_step),.guide_total(guide_total),.beat_progress(beat_progress),.target_beats(target_beats),
        .wave_current(wave_current),.wave_previous(wave_previous),.scope_gain(scope_gain),.wave_valid(wave_valid),
        .test_active(test_active),.test_requested(test_requested),.test_busy(test_busy),.test_gate(test_gate),
        .test_sweep(test_sweep),.test_index(test_index),.test_overrun(test_overrun),
        .red(expected[23:16]),.green(expected[15:8]),.blue(expected[7:0]));
    task compare;
        begin
            @(posedge clk);#1;
            if(rst_n)begin
                if(actual!==expected)$fatal(1,"V015 pixel mismatch scene=%0d x=%0d y=%0d actual=%h expected=%h",scene,x,y,actual,expected);
                checks=checks+1;
            end
        end
    endtask
    initial begin
        repeat(3)@(negedge clk);rst_n=1;
        for(scene=0;scene<7;scene=scene+1)begin
            page=scene<4?scene:2;
            cursor=scene>=4?scene-4:0;song=scene%3;
            test_active=(scene==6);
            guide_done=(scene==3);guide_active=(scene==0);
            controls=4'b0101;keys=12'h340;
            flags=scene*37;pitch=(scene&1)?-9'sd256:9'sd255;
            timbre=scene*2;voices=scene==6?32:scene+1;
            scope_gain=scene+1;test_index=scene*5;test_sweep=(scene&1);
            for(py=0;py<480;py=py+1)begin
                for(px=0;px<640;px=px+1)begin
                    @(negedge clk);x=px;y=py;
                    wave_previous=((px/2)%64-32)*900;
                    wave_current=(((px/2+1)%64)-32)*900;
                    compare();frame_checks=frame_checks+1;
                end
            end
        end
        // 任意组合状态及消隐/越界，验证8位ID选择与原宽文本路径一致。
        for(scene=0;scene<20000;scene=scene+1)begin
            @(negedge clk);
            random_word=$random(seed);
            x=random_word[9:0];y=random_word[19:10];de=random_word[20];
            page=random_word[22:21];cursor=random_word[24:23];song=random_word[26:25];
            test_active=random_word[27];guide_active=random_word[28];guide_done=random_word[29];
            wave_valid=random_word[30];note_valid=random_word[31];
            random_word=$random(seed);
            keys=random_word[11:0];controls=random_word[15:12];timbre=random_word[19:16];
            flags=random_word[27:20];scope_gain=random_word[31:28];
            random_word=$random(seed);note=random_word[6:0];pitch=random_word[15:7];
            pressure0=random_word[23:16];pressure1=random_word[31:24];
            random_word=$random(seed);volume_percent=random_word[7:0];peak_percent=random_word[15:8];
            level_dbfs=random_word[23:16];beat_progress=random_word[31:24];
            random_word=$random(seed);test_busy=random_word;test_gate=~random_word;
            test_index=random_word[4:0];test_requested=random_word[10:5];voices=random_word[16:11];
            frequency_bcd=random_word[31:16];guide_step=random_word[5:0];guide_total=random_word[11:6];
            test_sweep=random_word[12];test_overrun=random_word[13];
            compare();
        end
        $display("DASHBOARD_RESOURCE_EQUIVALENCE_TEST_PASS pixels=%0d random=%0d",frame_checks,checks-frame_checks);
        $finish;
    end
endmodule
