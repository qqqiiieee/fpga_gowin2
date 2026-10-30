`timescale 1ns/1ps
// 并行比较闭/开镲公开PCM：采样保持、力度增益、能量衰减、尾音期限与clear。
module tb_hat_voice;
    reg clk=0, rst_n=0, fs_tick=0, clear=0, hit=0;
    reg [7:0] velocity=0;
    wire [15:0] closed_sample, open_sample;
    wire closed_busy, open_busy;
    integer i, closed_end, open_end, c, o;
    reg [15:0] held_closed, held_open;
    reg [63:0] early_closed, late_closed, early_open, late_open, low_sum, high_sum;
    reg [15:0] low_wave [0:127];
    always #5 clk=~clk;
    hat_voice #(.OPEN(0)) closed_hat (.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),
        .clear(clear),.hit(hit),.velocity(velocity),.sample(closed_sample),.busy(closed_busy));
    hat_voice #(.OPEN(1)) open_hat (.clk(clk),.rst_n(rst_n),.fs_tick(fs_tick),
        .clear(clear),.hit(hit),.velocity(velocity),.sample(open_sample),.busy(open_busy));
    task idle; input integer n; begin repeat(n) @(negedge clk); end endtask
    task step;
        begin
            @(negedge clk); fs_tick=1;
            @(negedge clk); fs_tick=0;
        end
    endtask
    task strike;
        input [7:0] v;
        begin
            @(negedge clk); hit=1; velocity=v;
            @(negedge clk); hit=0;
        end
    endtask
    task erase;
        begin
            @(negedge clk); clear=1;
            @(negedge clk); clear=0;
            if (closed_busy || open_busy || closed_sample!==0 || open_sample!==0)
                $fatal(1,"clear did not immediately silence voice and pending hit");
        end
    endtask
    function integer abs_pcm;
        input [15:0] value;
        integer s;
        begin s=$signed(value); abs_pcm=(s<0) ? -s : s; end
    endfunction
    // 每clk验证幅值上界和无X，既检查采样沿也检查无fs_tick的保持区间。
    always @(posedge clk) if (rst_n) begin
        #1;
        if ((^closed_sample)===1'bx || (^open_sample)===1'bx ||
            abs_pcm(closed_sample)>8159 || abs_pcm(open_sample)>8159)
            $fatal(1,"hat PCM unknown / exceeded bounded gain");
        if ((!closed_busy && closed_sample!=0) || (!open_busy && open_sample!=0))
            $fatal(1,"idle hat left nonzero PCM");
    end
    initial begin
        idle(3); rst_n=1; idle(3);
        if (closed_busy || open_busy || closed_sample!==0 || open_sample!==0)
            $fatal(1,"reset was not silent");
        strike(0); step;
        if (closed_busy || open_busy) $fatal(1,"zero velocity started idle voice");
        strike(255); idle(5);
        if (!closed_busy || !open_busy || closed_sample!=0 || open_sample!=0)
            $fatal(1,"pending hit was not buffered before sample tick");
        step; step;
        held_closed=closed_sample; held_open=open_sample;
        idle(20);
        if (closed_sample!==held_closed || open_sample!==held_open)
            $fatal(1,"sample advanced without fs_tick");
        $display("HAT_CASE_PASS reset_zero_pending_sample_hold");

        erase; strike(255); step;
        early_closed=0; late_closed=0; early_open=0; late_open=0;
        closed_end=0; open_end=0;
        for (i=1;i<=60000;i=i+1) begin
            step; c=abs_pcm(closed_sample); o=abs_pcm(open_sample);
            if (i<=1024) begin early_closed=early_closed+c; early_open=early_open+o; end
            if (i>=4096 && i<5120) late_closed=late_closed+c;
            if (i>=40000 && i<41024) late_open=late_open+o;
            if (!closed_busy && closed_end==0) closed_end=i;
            if (!open_busy && open_end==0) open_end=i;
        end
        if (early_closed<10000 || early_open<10000 ||
            late_closed*8>=early_closed || late_open*8>=early_open)
            $fatal(1,"hat decay / nonzero noise failed closed=%0d,%0d open=%0d,%0d",
                early_closed,late_closed,early_open,late_open);
        if (closed_end<100 || closed_end>9375 || open_end<=closed_end*3 || open_end>56250 ||
            closed_busy || open_busy || closed_sample!=0 || open_sample!=0)
            $fatal(1,"open/closed bounded tail duration closed=%0d open=%0d",closed_end,open_end);
        $display("HAT_CASE_PASS bounded_noise_decay_and_tail closed_ticks=%0d open_ticks=%0d",closed_end,open_end);

        // 同一冷启动种子在不同力度下逐样本比较，防止力度被忽略或负增益回绕。
        erase; strike(64); step; low_sum=0;
        for (i=0;i<128;i=i+1) begin
            step; low_wave[i]=closed_sample; low_sum=low_sum+abs_pcm(closed_sample);
        end
        erase; strike(255); step; high_sum=0;
        for (i=0;i<128;i=i+1) begin
            step;
            if (abs_pcm(closed_sample)<abs_pcm(low_wave[i])) $fatal(1,"velocity gain reversed");
            high_sum=high_sum+abs_pcm(closed_sample);
        end
        if (high_sum<low_sum*3 || low_sum==0) $fatal(1,"velocity did not scale noise");
        $display("HAT_CASE_PASS velocity_scales_pcm_without_overflow");

        // clear优先于同沿hit/fs_tick；清掉pending后下一tick也不得迟发。
        @(negedge clk); hit=1; velocity=255; clear=1; fs_tick=1;
        @(negedge clk); hit=0; clear=0; fs_tick=0;
        if (closed_busy || open_busy || closed_sample!=0 || open_sample!=0)
            $fatal(1,"clear lost priority over hit and fs_tick");
        step;
        if (closed_busy || open_busy) $fatal(1,"clear left delayed trigger");
        strike(255); erase; step;
        if (closed_busy || open_busy) $fatal(1,"pending event survived clear");
        strike(255); step; step; erase;
        $display("HAT_CASE_PASS clear_active_pending_same_edge_priority");

        // 两次采样间最新力度覆盖旧值；同沿hit覆盖旧pending并只消费一次。
        strike(255); strike(0); step;
        if (closed_busy || open_busy) $fatal(1,"latest pending zero did not replace hit");
        strike(0);
        @(negedge clk); hit=1; velocity=64; fs_tick=1;
        @(negedge clk); hit=0; fs_tick=0;
        if (!closed_busy || !open_busy) $fatal(1,"same edge hit failed to override pending");
        for (i=0;i<128;i=i+1) begin
            step;
            if (closed_sample!==low_wave[i]) $fatal(1,"same edge hit wrong velocity / duplicate event");
        end
        // 零力度不得重装正在发声的尾音；非零复触发则应重装窗口。
        strike(0); step;
        // 已走128个采样，零力度消费为第129个；必须仍在原第9375/56250拍结束。
        for (i=130;i<=9375;i=i+1) step;
        if (closed_busy) $fatal(1,"zero event incorrectly extended closed tail");
        for (i=9376;i<=56250;i=i+1) step;
        if (closed_busy || open_busy) $fatal(1,"zero event incorrectly extended open tail");
        strike(255); step;
        for (i=0;i<9000;i=i+1) step;
        strike(64); step;
        for (i=0;i<1000;i=i+1) step;
        if (!closed_busy || !open_busy) $fatal(1,"nonzero retrigger failed to renew tail");
        $display("HAT_CASE_PASS latest_pending_same_tick_retrigger");

        // 异步复位无需fs_tick，且松开复位后不得重新播放旧pending。
        strike(255); @(negedge clk); rst_n=0; #1;
        if (closed_busy || open_busy || closed_sample!=0 || open_sample!=0)
            $fatal(1,"asynchronous reset did not silence");
        idle(2); rst_n=1; step;
        if (closed_busy || open_busy) $fatal(1,"reset resurrected event");
        $display("HAT_CASE_PASS asynchronous_reset_no_replay");
        $display("HAT_VOICE_TEST_PASS"); $finish;
    end
    initial begin #20000000; $fatal(1,"hat watchdog"); end
endmodule
