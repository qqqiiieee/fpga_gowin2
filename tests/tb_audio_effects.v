`timescale 1ns/1fs
// 中文测试导航：CASE0穷举65536个有符号干声字；CASE1验证百毫秒Delay的
// 正负脉冲位置及逐次衰减；CASE2用独立LFO/环形缓存/插值模型逐样本比较；
// CASE3用独立四梳状+两全通模型比较正负混响尾音；CASE4检查时间端点、
// 反馈端点、满幅正负持续输入的饱和及amount0即时干声；CASE5检查脏RAM、
// 模式切换、异步复位和不同处理时刻clear（含第63clk发布边沿）；CASE6检查
// 参数限速与输入锁存；CASE7验证自然尾音与生产参数完整750000采样的8秒上限。
// 所有用例使用持续运行的27MHz时钟、288clk真实采样间隔；不force/deposit，
// 不预填DUT内存，不缩短尾音计数。事件监视器检查完整63clk稳定窗口、任何
// busy/输出异常变化和X/Z；每个采样仍检查运算完成期限与数值参考模型。
// 1fs精度下半周期量化为18.518519ns；以下周期常数与真实时钟边沿严格一致。
// Independent arithmetic/reference memories below are simulation-only.
// No force/deposit of DUT state, no preinitialization of DUT history, no
// shortened timeout, and a continuously running 27 MHz clock in every case.
module tb_audio_effects;
    reg clk=0;
    always #18.518518519 clk=~clk;
    reg rst_n=0, tick=0, clear=0, input_active=0;
    reg [1:0] mode=0;
    reg [7:0] amount=0, time_control=0, feedback_control=0, mod_control=0;
    reg signed [15:0] sample_in=0;
    wire signed [15:0] sample_out;
    wire tail_busy;
    audio_effects dut(.*);

    integer test_case=0, checks=0, max_ready=0, samples=0;
    integer i,j,k,n,out_value,expected,x,d,echo_value,echoes,nonzero;
    integer reference [0:16383];
    integer p,valid,a,b,v,y,sum,wet_ref,frac,lag_q,lag,min_lag,max_lag;
    integer phase_ref,tri_ref,ap0,ap1,comb_d,fb,gain,interpolated;
    integer previous,first_ready,cycle,latched,min_gap,last_nonzero,frac_count;
    integer nonzero_before,nonzero_after;
    reg [31:0] rng=32'hb1937a41;
    reg signed [15:0] held_output;
    realtime previous_tick=-1.0, this_tick;

    // 仅优化bench调度，DUT时钟仍连续运行，tick仍精确相隔288个clk。
    // 事件监视覆盖整个窗口，也能发现两个时钟边沿之间的提前输出变化。
    localparam real CLOCK_PERIOD_NS=37.037038;
    reg monitor_frame=0;
    realtime accepted_edge;
    integer ready_cycle=0;
    integer progress_fd=0;
    reg [8191:0] progress_path;
    always @(sample_out or dut.busy) begin
        if(monitor_frame && $realtime < accepted_edge+63.0*CLOCK_PERIOD_NS-0.01) begin
            if(sample_out!==held_output || dut.busy!==1'b1)
                check(0,"output/busy changed before fixed publication");
        end
        if(monitor_frame && dut.busy===1'b0) begin
            if($realtime < accepted_edge+63.0*CLOCK_PERIOD_NS-0.01 ||
               $realtime > accepted_edge+63.0*CLOCK_PERIOD_NS+0.01)
                check(0,"busy publication must be exactly 63 clocks");
        end
    end
    always @(dut.result_ready) begin
        if(monitor_frame && dut.result_ready===1'b1 && ready_cycle==0)
            ready_cycle=$rtoi(($realtime-accepted_edge)/CLOCK_PERIOD_NS+0.5);
    end
    // 独立文件实时刷新，避免subprocess的stdout捕获把长用例进度藏到结束。
    task write_progress;
        begin
            if(progress_fd!=0) begin
                $fdisplay(progress_fd,
                    "{\"case\":%0d,\"samples\":%0d,\"simulated_time_ns\":%.3f,\"mode\":%0d,\"time_control\":%0d,\"feedback_control\":%0d,\"worker_max_clocks\":%0d}",
                    test_case,samples,$realtime,mode,time_control,feedback_control,max_ready);
                $fflush(progress_fd);
            end
        end
    endtask

    function integer sat;
        input integer value;
        begin sat=value>32767 ? 32767 : value < -32768 ? -32768 : value; end
    endfunction

    task check;
        input condition;
        input [511:0] reason;
        begin
            checks=checks+1;
            if (condition !== 1'b1) begin
                $display("FAIL case=%0d sample=%0d: %0s",test_case,samples,reason);
                $fatal(1,"audio_effects assertion failed");
            end
        end
    endtask

    // 每帧检查：固定63clk发布、运算先完成；稳定性由上面的事件监视器连续检查。
    // 224个空闲clk全部真实运行，只用一次时间等待代替224次bench唤醒。
    task send;
        input integer value;
        input active;
        output integer observed;
        begin
            @(negedge clk);
            sample_in=value; input_active=active; tick=1;
            held_output=sample_out;
            @(posedge clk); #1;
            accepted_edge=$realtime-1.0;
            this_tick=$realtime;
            if (previous_tick>=0.0)
                check(this_tick-previous_tick>288.0*CLOCK_PERIOD_NS-0.01 &&
                      this_tick-previous_tick<288.0*CLOCK_PERIOD_NS+0.01,
                      "tick spacing must be exactly 288 production clocks");
            previous_tick=this_tick;
            check(dut.busy===1'b1,"tick accepted");
            ready_cycle=0; monitor_frame=1;
            @(negedge clk); tick=0;
            #(62.0*CLOCK_PERIOD_NS);
            @(posedge clk); #1;
            check(dut.busy===1'b0,"must finish on clock 63");
            check(dut.result_ready===1'b1,"computation finished before publish");
            check(ready_cycle>0 && ready_cycle<63,"worker completes before publication");
            check((^sample_out)!==1'bx && tail_busy!==1'bx,"no X/Z on outputs");
            if(ready_cycle>max_ready) max_ready=ready_cycle;
            monitor_frame=0;
            observed=$signed(sample_out); samples=samples+1;
            if((samples & 2047)==0) write_progress;
            #(224.0*CLOCK_PERIOD_NS);
        end
    endtask

    task setup;
        input integer m,amt,t,f,modc;
        integer z;
        begin
            @(negedge clk);
            clear=1; mode=m; amount=amt; time_control=t;
            feedback_control=f; mod_control=modc; sample_in=0; input_active=0;
            @(posedge clk); #1;
            check(sample_out===16'sd0 && tail_busy===0,"clear synchronously zeros output/tail");
            check(dut.fill_count===0 && dut.busy===0,"clear invalidates/aborts");
            @(negedge clk); clear=0;
            previous_tick=-1.0;
            for(z=0;z<260;z=z+1) begin
                send(0,0,out_value);
                check(out_value==0,"cold uninitialized RAM masked");
            end
        end
    endtask

    task bypass_tests;
        integer m,z;
        begin
            // All 65536 signed input words, across all four amount-zero modes.
            for(m=0;m<4;m=m+1) begin
                setup(m,0,255,255,255);
                for(z=0;z<16384;z=z+1) begin
                    x=(m*16384+z)-32768;
                    send(x,z[0],out_value);
                    check(out_value==x,"amount=0 bit-exact signed dry");
                    check(tail_busy===0,"amount=0 cannot hold quiet gate");
                end
            end
            setup(0,255,0,255,255);
            for(z=0;z<512;z=z+1) begin
                rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
                x=$signed(rng[15:0]); send(x,1,out_value);
                check(out_value==x,"mode=0 bit-exact dry at maximum amount");
            end
        end
    endtask

    task delay_tests;
        integer polarity,z;
        begin
            // 106.496 ms delay. Independent impulse timing and Q4 decay.
            for(polarity=0;polarity<2;polarity=polarity+1) begin
                setup(1,255,160,160,0); d=1024+56*160;
                echo_value=polarity ? -16384 : 16384;
                for(z=0;z<=3*d+8;z=z+1) begin
                    x=z==0 ? echo_value : 0;
                    send(x,z==0,out_value);
                    expected=0;
                    if(z==0) expected=x;
                    else if(z%d==0) begin
                        expected=echo_value*255/256;
                        echo_value=echo_value*10/16;
                    end
                    check(out_value==expected,"100 ms impulse position/feedback/polarity");
                    if(z<3*d) check(tail_busy===1,"input_active=0 retains delay gaps/tail");
                end
            end
        end
    endtask

    task chorus_tests;
        integer z;
        begin
            setup(2,255,64,255,255);
            // The reference uses the public control equations, its own memory,
            // integer division and phase; it never reads DUT taps or history.
            for(z=0;z<16384;z=z+1) reference[z]=0;
            p=260; valid=260; phase_ref=260*542;
            min_lag=16384; max_lag=0; frac_count=0;
            for(z=0;z<62000;z=z+1) begin
                tri_ref=(phase_ref & 24'h7fffff)>>7;
                if(phase_ref & 24'h800000) tri_ref=65535-tri_ref;
                lag_q=196608+64*2048+(((tri_ref-32768)*255)>>>6);
                lag=lag_q>>8; frac=lag_q & 255;
                if(lag<min_lag) min_lag=lag;
                if(lag>max_lag) max_lag=lag;
                if(frac!=0) frac_count=frac_count+1;
                a=valid>=lag ? reference[(p-lag)&16383] : 0;
                b=valid>=lag+1 ? reference[(p-lag-1)&16383] : 0;
                interpolated=a+(b-a)*frac/256;
                x=(z%2000)*8-8000;
                expected=sat(x+interpolated*255/256);
                send(x,1,out_value);
                if(out_value!=expected)
                    $display("chorus z=%0d D=%0d f=%0d a=%0d b=%0d got=%0d exp=%0d",
                        z,lag,frac,a,b,out_value,expected);
                check(out_value==expected,"LFO fractional-delay reference PCM");
                reference[p]=x; p=(p+1)&16383;
                if(valid<16384) valid=valid+1;
                phase_ref=(phase_ref+542)&24'hffffff;
            end
            check(max_lag-min_lag>=1000,"LFO actually sweeps delay across full cycle");
            check(frac_count>60000,"fractional interpolation exercised");
            $display("CHORUS lag_min=%0d lag_max=%0d fractional_samples=%0d",
                min_lag,max_lag,frac_count);
        end
    endtask

    task reverb_tests;
        integer z,c,polarity;
        begin
            for(polarity=0;polarity<2;polarity=polarity+1) begin
                setup(3,255,96,255,0);
                // Independent Schroeder reference: four disjoint comb rings
                // and two allpasses, signed saturating writes in each loop.
                for(z=0;z<16384;z=z+1) reference[z]=0;
                p=260; valid=260; nonzero=0; min_gap=99999; last_nonzero=-1;
                for(z=0;z<16000;z=z+1) begin
                    x=z==0 ? (polarity ? -16384 : 16384) : 0;
                    sum=0;
                    for(c=0;c<4;c=c+1) begin
                        case(c)
                            0: comb_d=701+3*96;
                            1: comb_d=907+3*96;
                            2: comb_d=1151+3*96;
                            3: comb_d=1277+3*96;
                        endcase
                        a=valid>=comb_d ? reference[c*2048+((p-comb_d)&2047)] : 0;
                        reference[c*2048+(p&2047)]=sat(x/2+a*14/16);
                        sum=sum+a;
                    end
                    wet_ref=sum/4;
                    for(c=0;c<2;c=c+1) begin
                        d=c==0 ? 113+96/2 : 337+96/2;
                        a=valid>=d ? reference[8192+c*1024+((p-d)&1023)] : 0;
                        v=sat(wet_ref+a/2);
                        reference[8192+c*1024+(p&1023)]=v;
                        wet_ref=a-v/2;
                    end
                    expected=sat(x+wet_ref*255/256);
                    send(x,z==0,out_value);
                    if(out_value!=expected)
                        $display("reverb z=%0d got=%0d exp=%0d wet=%0d",z,out_value,expected,wet_ref);
                    check(out_value==expected,"four comb + two allpass reference PCM");
                    if(z>0 && out_value!=0) begin
                        nonzero=nonzero+1;
                        if(last_nonzero>=0 && z-last_nonzero<min_gap) min_gap=z-last_nonzero;
                        last_nonzero=z;
                    end
                    p=(p+1)&16383;
                    if(valid<16384) valid=valid+1;
                end
                check(nonzero>1000 && min_gap==1,"reverb develops dense, multiple-path tail");
                $display("REVERB polarity=%0d nonzero_tail_samples=%0d min_gap=%0d",
                    polarity,nonzero,min_gap);
            end
        end
    endtask

    task boundary_tests;
        integer z,m,edge_value,polarity;
        begin
            // Exact minimum/maximum Delay, zero feedback = one single echo.
            for(edge_value=0;edge_value<=255;edge_value=edge_value+255) begin
                setup(1,255,edge_value,0,255); d=1024+56*edge_value;
                for(z=0;z<=2*d;z=z+1) begin
                    send(z==0 ? -32768 : 0,z==0,out_value);
                    expected=z==0 ? -32768 : z==d ? -32640 : 0;
                    check(out_value==expected,"time boundary / zero feedback / -32768");
                end
            end
            // Positive and negative saturation in every effect at both time
            // endpoints; output must clip, never wrap or invert its sign.
            for(m=1;m<=3;m=m+1)
                for(edge_value=0;edge_value<=255;edge_value=edge_value+255)
                    for(polarity=0;polarity<2;polarity=polarity+1) begin
                        setup(m,255,edge_value,255,edge_value);
                        x=polarity ? -32768 : 32767;
                        nonzero=0;
                        for(z=0;z<17000;z=z+1) begin
                            send(x,1,out_value);
                            check(out_value>=-32768 && out_value<=32767,"signed saturation range");
                            if(z>16000 && out_value==x) nonzero=nonzero+1;
                        end
                        check(nonzero>900,"sustained same-sign wet saturates at PCM rail");
                        // amount 0 is immediate, even with full-scale history.
                        amount=0;
                        for(z=0;z<16;z=z+1) begin
                            send(-x/3,0,out_value);
                            check(out_value==-x/3,"amount-zero overrides smoothing/history");
                        end
                    end
        end
    endtask

    task clear_switch_tests;
        integer z,m,c,abort_cycle;
        begin
            setup(1,255,255,255,255);
            for(z=0;z<17000;z=z+1) send(20000,1,out_value);
            // Reuse dirty memory in every new mode; clear must mask it all.
            for(m=1;m<=3;m=m+1) begin
                setup(m,255,255,255,255);
                for(z=0;z<17000;z=z+1) begin
                    send(0,0,out_value);
                    check(out_value==0,"clear masks all old/never-written partitions");
                end
                for(z=0;z<2200;z=z+1) send(-19000,1,out_value);
            end
            // Abort in flight at RAM read, serial products, and publication.
            for(c=0;c<=10;c=c+1) begin
                abort_cycle=c==10 ? 63 : 1+6*c;
                @(negedge clk); sample_in=30000; tick=1; input_active=1;
                @(posedge clk); #1;
                @(negedge clk); tick=0;
                repeat(abort_cycle-1) @(posedge clk);
                @(negedge clk); clear=1;
                @(posedge clk); #1;
                check(sample_out===0 && tail_busy===0 && dut.busy===0,"mid-transaction clear wins");
                @(negedge clk); clear=0; sample_in=0; input_active=0;
                repeat(70) @(posedge clk);
                #1; check(sample_out===0,"aborted pipeline cannot publish late");
                previous_tick=-1.0;
                send(0,0,out_value); check(out_value==0,"aborted RAM work stays invalid");
            end
            // Switching all three effects without clear must invalidate old
            // history when the fade reaches zero; no resurrection afterwards.
            for(m=1;m<=3;m=m+1) begin
                setup(m,255,0,255,255);
                for(z=0;z<2300;z=z+1) send(18000,1,out_value);
                mode=m==3 ? 1 : m+1;
                for(z=0;z<256;z=z+1) send(0,0,out_value);
                check(dut.active_mode==mode,"mode adopted after bounded fade");
                for(z=0;z<6500;z=z+1) begin
                    send(0,0,out_value);
                    check(out_value==0,"new mode cannot replay old tail");
                end
            end
            // Asynchronous reset with dirty memory, then no clear at startup.
            @(negedge clk); rst_n=0;
            #1; check(sample_out===0 && tail_busy===0,"asynchronous reset zeros outputs");
            @(negedge clk); rst_n=1; mode=3; amount=255;
            previous_tick=-1.0;
            for(z=0;z<6000;z=z+1) begin
                send(0,0,out_value); check(out_value==0,"reset does not expose dirty RAM");
            end
        end
    endtask

    task smoothing_tests;
        integer z,old_gain,old_time,old_feedback,old_mod,old_delay;
        begin
            setup(1,255,0,0,0);
            time_control=255; feedback_control=255; mod_control=255; amount=32;
            for(z=0;z<3000;z=z+1) begin
                old_gain=dut.wet_gain; old_time=dut.time_smooth;
                old_feedback=dut.feedback_smooth; old_mod=dut.mod_smooth;
                old_delay=dut.delay_q;
                send(0,0,out_value);
                check(dut.wet_gain>=old_gain-1 && dut.wet_gain<=old_gain+1,"wet gain slew bounded");
                check(dut.time_smooth>=old_time && dut.time_smooth<=old_time+1,"time control slew bounded");
                check(dut.feedback_smooth>=old_feedback && dut.feedback_smooth<=old_feedback+1,"feedback slew bounded");
                check(dut.mod_smooth>=old_mod && dut.mod_smooth<=old_mod+1,"modulation slew bounded");
                check(dut.delay_q>=old_delay && dut.delay_q<=old_delay+32,"fractional delay slew <=1/8 sample");
                check(out_value==0,"silent parameter changes remain silent");
            end
            check(dut.wet_gain==32 && dut.feedback_q4==14,"target amount and feedback ceiling reached");
            // Tick latches signed PCM, amount and mode for a whole transaction.
            @(negedge clk); sample_in=-12345; amount=0; tick=1;
            @(posedge clk); #1;
            @(negedge clk); tick=0; sample_in=23456; amount=255; mode=2;
            repeat(63) @(posedge clk);
            #1; check(sample_out===-16'sd12345,"inputs latched for fixed pipeline");
        end
    endtask

    task tail_tests;
        integer z,echo_amp,tail_gain;
        begin
            // Natural tail expiry (no sign-dependent -1 feedback limit cycle).
            setup(1,255,0,255,0);
            send(-10,1,out_value);
            for(z=1;z<27000;z=z+1) send(0,0,out_value);
            check(tail_busy===0 && out_value==0,"small negative tail naturally expires");

            // Full production 8-second cap: NO parameter/counter overrides.
            // Longest delay and maximum feedback leave real energy at 8 s.
            setup(1,255,255,255,0); d=15304; echo_amp=32767;
            for(z=0;z<=750020;z=z+1) begin
                send(z==0 ? 32767 : 0,z==0,out_value);
                expected=z==0 ? 32767 : 0;
                if(z>0 && z%d==0 && z<750000) begin
                    tail_gain=z<=749745 ? 255 : 255-(z-749745);
                    if(tail_gain<0) tail_gain=0;
                    expected=echo_amp*tail_gain/256;
                    echo_amp=echo_amp*14/16;
                end
                check(out_value==expected,"maximum-feedback tail and final safety fade");
                if(z<750000) check(tail_busy===1,"tail not truncated by quiet gaps or inactive voices");
                else check(tail_busy===0,"8-second finite tail invalidation");
                if(z%100000==0) $display("TAIL_PROGRESS samples=%0d",z);
            end
            check(dut.fill_count<30,"hard expiry invalidates history without RAM erase");
            // New activity following timeout cannot uncover the expired echo.
            for(z=0;z<16000;z=z+1) begin
                send(0,1,out_value); check(out_value==0,"expired history never reappears");
            end
        end
    endtask

    // Check transitions too, rather than looking only at sample boundaries.
    always @(sample_out or tail_busy) begin
        if(rst_n===1'b1) begin
            if((^sample_out)===1'bx || tail_busy===1'bx)
                $fatal(1,"X/Z output transition");
        end
    end

    initial begin
        if(!$value$plusargs("CASE=%d",test_case)) test_case=0;
        if($value$plusargs("PROGRESS=%s",progress_path)) begin
            progress_fd=$fopen(progress_path,"w");
            if(progress_fd==0) $fatal(1,"cannot open progress file");
            write_progress;
        end
        repeat(3) @(negedge clk);
        rst_n=1;
        case(test_case)
            0: bypass_tests;
            1: delay_tests;
            2: chorus_tests;
            3: reverb_tests;
            4: boundary_tests;
            5: clear_switch_tests;
            6: smoothing_tests;
            7: tail_tests;
            default: $fatal(1,"unknown case");
        endcase
        $display("EFFECTS_TEST_PASS case=%0d samples=%0d checks=%0d worker_max_clocks=%0d latency_clocks=63 ram_words=16384 ram_bits=262144 estimated_bsram=16",
            test_case,samples,checks,max_ready);
        write_progress;
        if(progress_fd!=0) $fclose(progress_fd);
        $finish;
    end
    initial begin
        #10000000000; // 10 seconds of simulated time; full tail case needs 8.4.
        $fatal(1,"testbench watchdog");
    end
endmodule
