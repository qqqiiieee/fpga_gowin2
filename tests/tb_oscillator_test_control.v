`timescale 1ns/1ps
// 独立行为仿真：只需本文件和oscillator_test_control.v，不实例化音频引擎、
// FPGA原语或硬件顶层。采样使能人工推进，系统clk仍持续运行，检查两种时基。
module tb_oscillator_test_control;
    localparam integer HOLD = 5;
    localparam integer IDLE = 257; // 非二次幂，覆盖计数器末端而不是依赖自然回绕。
    localparam integer HALF = 3;
    localparam integer DIV  = 2;
    localparam [3:0] NORMAL=0, NORMAL_OUT=1, TEST_IN=2, ACTIVE=3,
                     OUT=4, WAIT_KEYS=5, NORMAL_IN=6;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    reg sample_tick = 0;
    reg [15:0] keys = 0;
    reg ghost = 0;
    reg remote_active = 0;
    wire owned, test_mode, sweep_active, clear_audio;
    wire [31:0] gate_mask;
    wire [5:0] requested_count;
    wire [4:0] sweep_index;
    wire [8:0] master_gain;
    wire [3:0] state_debug;
    wire tiny_done, clamp_done, odd_done;

    oscillator_test_control #(.HOLD_SAMPLES(HOLD), .MAX_SAMPLES(IDLE),
        .SWEEP_HALF_SAMPLES(HALF), .RAMP_DIV(DIV)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(sample_tick), .keys(keys),
        .ghost(ghost), .remote_active(remote_active), .owned(owned),
        .test_mode(test_mode), .gate_mask(gate_mask), .requested_count(requested_count),
        .sweep_active(sweep_active), .sweep_index(sweep_index), .master_gain(master_gain),
        .clear_audio(clear_audio), .state_debug(state_debug));

    // 同时验证最小正参数、非法参数钳位、以及奇数RAMP_DIV和1采样扫频半段。
    oscillator_test_control_parameter_case #(.CASE_ID(1), .HOLD(1), .IDLE(1),
        .HALF(1), .DIV(1)) tiny (.clk(clk), .done(tiny_done));
    oscillator_test_control_parameter_case #(.CASE_ID(2), .HOLD(0), .IDLE(-7),
        .HALF(0), .DIV(-2)) clamped (.clk(clk), .done(clamp_done));
    oscillator_test_control_parameter_case #(.CASE_ID(3), .HOLD(3), .IDLE(70),
        .HALF(1), .DIV(3)) odd (.clk(clk), .done(odd_done));

    task need;
        input condition;
        input [767:0] message;
        begin
            if (condition !== 1'b1) begin
                $display("FAIL at %0t state=%0d gain=%0d keys=%h: %0s",
                    $time, state_debug, master_gain, keys, message);
                $fatal(1, "oscillator controller assertion");
            end
        end
    endtask

    // 每个采样只有一个clk的高使能，结束在下降沿，读数已经跨过NBA更新。
    task sample;
        begin
            @(negedge clk); sample_tick = 1;
            @(posedge clk); #2;
            @(negedge clk); sample_tick = 0; #2;
        end
    endtask
    task samples;
        input integer n;
        integer j;
        begin for (j=0; j<n; j=j+1) sample; end
    endtask
    task clocks_only;
        input integer n;
        begin
            @(negedge clk); sample_tick = 0;
            repeat (n) begin @(posedge clk); #2; end
        end
    endtask
    task set_keys;
        input [15:0] value;
        input ghost_value;
        begin
            @(negedge clk); keys = value; ghost = ghost_value;
            @(posedge clk); #2;
        end
    endtask
    task key_at_sample;
        input [15:0] value;
        begin
            @(negedge clk); keys = value; ghost = 0; sample_tick = 1;
            @(posedge clk); #2;
            @(negedge clk); sample_tick = 0; #2;
        end
    endtask
    task set_source;
        input value;
        begin
            @(negedge clk); remote_active = value;
            @(posedge clk); #2;
        end
    endtask

    integer clear_pulses = 0;
    reg previous_clear = 0;
    reg previous_mode = 0;
    reg [8:0] previous_gain = 256;
    reg monitor_valid = 0;
    // 全程检查，而非只看几个终点：增益不越界、不跳步、不受clk空转影响；
    // 清零必须在零增益且仅1个clk，模式变化必须与该清零脉冲重合。
    always @(posedge clk) begin
        #1;
        if (!rst_n) begin
            clear_pulses = 0;
            previous_clear = 0;
            previous_mode = 0;
            previous_gain = 256;
            monitor_valid = 0;
        end else begin
            need(master_gain <= 9'd256, "gain must stay in 0..256 without X");
            need(state_debug <= NORMAL_IN, "state encoding must be known and bounded");
            need(owned == (state_debug != NORMAL), "ownership covers all non-normal phases");
            need(requested_count <= 32, "requested count bounded");
            need(!(previous_clear && clear_audio), "clear_audio is exactly one clk");
            if (clear_audio) begin
                clear_pulses = clear_pulses + 1;
                need(master_gain == 0, "clear only at zero gain");
                need((state_debug == TEST_IN) || (state_debug == WAIT_KEYS),
                    "clear only at mode transition boundaries");
            end
            if (monitor_valid) begin
                if (previous_mode != test_mode)
                    need(clear_audio, "mode changes require synchronous zero-gain clear pulse");
                if (previous_gain != master_gain) begin
                    need(sample_tick, "gain changes only on sample tick");
                    if (previous_gain > master_gain)
                        need(previous_gain - master_gain == 1, "fade down changes only one step");
                    else need(master_gain - previous_gain == 1, "fade up changes only one step");
                end
            end
            if (test_mode) need(owned, "test engine cannot be selected without ownership");
            if ((state_debug == NORMAL) || (state_debug == WAIT_KEYS) ||
                (state_debug == NORMAL_IN))
                need(!test_mode && !sweep_active && gate_mask == 0 && requested_count == 0,
                    "normal and recovery have no test gates");
            if (state_debug == WAIT_KEYS)
                need(owned && master_gain == 0, "wait-release holds zero with ownership");
            if (state_debug == NORMAL)
                need(!owned && master_gain == 256, "normal is full gain and unowned");
            previous_clear = clear_audio;
            previous_mode = test_mode;
            previous_gain = master_gain;
            monitor_valid = 1;
        end
    end

    task reset_main;
        begin
            @(negedge clk); rst_n = 0; sample_tick = 0; keys = 0;
            ghost = 0; remote_active = 0;
            repeat (3) @(negedge clk);
            rst_n = 1;
            @(posedge clk); #2;
            need(state_debug == NORMAL && !owned && master_gain == 256 && !clear_audio,
                "reset restores normal output immediately");
        end
    endtask
    task begin_entry;
        input source;
        begin
            set_source(source);
            set_keys(16'h5000, 0);
            samples(HOLD-1);
            need(!owned, "intent threshold has not yet been reached");
            sample;
            need(state_debug == NORMAL_OUT && owned && !test_mode && master_gain == 256,
                "exact hold starts owned preparation at unchanged gain");
        end
    endtask

    // 每一步都核对DIV周期和中途状态；可从任意整数增益开始淡出。
    task finish_ramp;
        input [3:0] from_state;
        input [3:0] to_state;
        input integer direction;
        integer start_gain, steps, j, d, expected_gain;
        begin
            need(state_debug == from_state, "ramp starts in expected phase");
            start_gain = master_gain;
            if (direction > 0) steps = 256 - start_gain;
            else steps = start_gain;
            if (steps == 0) begin
                // 零增益取消TEST_IN无需等待额外采样，出口仍产生独立清零脉冲。
                clocks_only(1);
                need(state_debug == to_state, "zero-gain exit completes without sample tick");
            end else begin
                for (j=0; j<steps; j=j+1) begin
                    for (d=1; d<=DIV; d=d+1) begin
                        sample;
                        expected_gain = start_gain + direction * j;
                        if (d == DIV) expected_gain = expected_gain + direction;
                        need(master_gain == expected_gain, "exact divided ramp gain");
                        if ((j == steps-1) && (d == DIV))
                            need(state_debug == to_state, "ramp reaches destination on last step");
                        else need(state_debug == from_state, "ramp cannot end early");
                    end
                end
            end
        end
    endtask
    task enter_active;
        input source;
        begin
            begin_entry(source);
            finish_ramp(NORMAL_OUT, TEST_IN, -1);
            need(clear_audio && test_mode && requested_count == 32 && gate_mask == 32'hffffffff,
                "enter-test clears once and selects all 32 at zero gain");
            finish_ramp(TEST_IN, ACTIVE, 1);
            need(!clear_audio && master_gain == 256 && owned, "active at full gain");
        end
    endtask
    task recover_normal;
        begin
            need(state_debug == WAIT_KEYS, "recovery requires wait-release");
            set_keys(0, 0);
            need(state_debug == NORMAL_IN && owned && master_gain == 0,
                "clean release starts normal fade-in");
            finish_ramp(NORMAL_IN, NORMAL, 1);
            need(!owned && !test_mode && master_gain == 256, "normal ownership is returned");
        end
    endtask

    function [5:0] expected_count;
        input integer key_number;
        begin
            case (key_number)
                0: expected_count=1;
                1: expected_count=4;
                2: expected_count=8;
                3: expected_count=16;
                default: expected_count=32;
            endcase
        end
    endfunction
    function [31:0] expected_prefix;
        input integer key_number;
        begin
            case (key_number)
                0: expected_prefix=32'h00000001;
                1: expected_prefix=32'h0000000f;
                2: expected_prefix=32'h000000ff;
                3: expected_prefix=32'h0000ffff;
                default: expected_prefix=32'hffffffff;
            endcase
        end
    endfunction

    integer i, j, pulse_before;
    reg [31:0] expected_off;
    initial begin
        reset_main;
        // 意图识别：全键精确匹配、无ghost、连续计时、无采样不累计。
        set_keys(16'h5001, 0); samples(HOLD+2);
        need(!owned, "entry chord plus extra key is rejected");
        set_keys(16'h5000, 1); samples(HOLD+2);
        need(!owned, "ghost entry chord is rejected");
        set_keys(16'h5000, 0); samples(HOLD-1); clocks_only(23);
        need(!owned, "hold counts samples instead of clocks");
        set_keys(16'h5000, 1); set_keys(16'h5000, 0); samples(HOLD-1);
        need(!owned, "ghost even between samples resets partial intent");
        set_keys(16'h5002, 0); set_keys(16'h5000, 0); samples(HOLD-1);
        need(!owned, "invalid combination resets partial intent");
        set_source(1); samples(HOLD-1);
        need(!owned, "input source change cannot concatenate partial hold");
        sample;
        need(owned && state_debug == NORMAL_OUT, "new source can complete its own hold");
        // 复位可取消已取得owned的准备，不遗留测试选择或清零脉冲。
        reset_main;

        enter_active(0);
        need(clear_pulses == 1, "entry has exactly one clear pulse");
        // 必须在ACTIVE之后看到整个键盘清洁松开才能操作。
        set_keys(16'h0001, 0);
        need(requested_count == 32, "first control before release is ignored");
        set_keys(0, 1); set_keys(16'h0002, 0);
        need(requested_count == 32, "ghost release does not arm controls");
        for (i=0; i<5; i=i+1) begin
            set_keys(0, 0); set_keys(16'h0001 << i, 0);
            need(requested_count == expected_count(i) && gate_mask == expected_prefix(i),
                "S1..S5 select exact count and low-bit prefix");
            samples(4);
            need(requested_count == expected_count(i) && !sweep_active,
                "held count key does not repeat");
        end

        // S6持续按住穿过完整扫频，若实现错误地按电平启动，索引无法推进。
        set_keys(0, 0); set_keys(16'h0020, 0);
        for (i=0; i<32; i=i+1) begin
            expected_off = 32'hffffffff ^ (32'h00000001 << i);
            need(sweep_active && sweep_index == i && gate_mask == expected_off && requested_count == 32,
                "each voice starts OFF with exactly one gate cleared");
            for (j=1; j<HALF; j=j+1) begin
                sample;
                need(sweep_index == i && gate_mask == expected_off && sweep_active,
                    "OFF persists for full half duration");
            end
            sample;
            need(sweep_index == i && gate_mask == 32'hffffffff && sweep_active,
                "OFF transitions to ON at exact half threshold");
            for (j=1; j<HALF; j=j+1) begin
                sample;
                need(sweep_index == i && gate_mask == 32'hffffffff && sweep_active,
                    "ON persists for full half duration");
            end
            sample;
        end
        need(!sweep_active && sweep_index == 31 && gate_mask == 32'hffffffff && requested_count == 32,
            "32 OFF/ON pairs finish on all gates, no index wrap");
        samples(9);
        need(!sweep_active && sweep_index == 31, "held S6 cannot restart finished sweep");
        set_keys(0, 0); set_keys(16'h0020, 0); samples(2);
        set_keys(0, 0); set_keys(16'h0004, 0);
        need(!sweep_active && requested_count == 8 && gate_mask == 32'h000000ff,
            "new count control cancels automatic sweep");

        // 无效组合及ghost的撤销不能制造上升沿，S16也遵守精确单键规则。
        set_keys(0, 0); set_keys(16'h0003, 0);
        need(requested_count == 8, "multi-key control is rejected");
        set_keys(16'h0001, 0);
        need(requested_count == 8, "removing extra key does not create a rising edge");
        set_keys(0, 0); set_keys(16'h0002, 1); set_keys(16'h0002, 0);
        need(requested_count == 8, "ghost removal cannot replay held control");
        set_keys(0, 0); set_keys(16'h8001, 0); set_keys(16'h8000, 0);
        need(state_debug == ACTIVE, "invalid exit combination and held S16 do not exit");
        set_keys(0, 0); set_keys(16'h8000, 1); set_keys(16'h8000, 0);
        need(state_debug == ACTIVE, "ghost exit and ghost removal do not exit");
        set_keys(0, 0); set_keys(16'h8000, 0);
        need(state_debug == OUT && master_gain == 256, "S16 exits active without abrupt gain jump");
        // 重按退出键不能重置已开始的渐变分频。
        sample;
        set_keys(0, 0); set_keys(16'h8000, 0);
        sample;
        need(master_gain == 255, "new exit edge in fade-out does not restart ramp divider");
        finish_ramp(OUT, WAIT_KEYS, -1);
        need(clear_audio && clear_pulses == 2, "exit clears exactly once at zero");
        samples(HOLD*2);
        need(state_debug == WAIT_KEYS && owned && master_gain == 0, "held exit waits at silence");
        set_keys(0, 1); samples(3);
        need(state_debug == WAIT_KEYS, "ghost release cannot restore normal audio");
        set_keys(16'h0040, 0); samples(3);
        need(state_debug == WAIT_KEYS, "any remaining key blocks clean release");
        set_keys(0, 0); samples(20);
        need(state_debug == NORMAL_IN && master_gain == 10, "normal restoration is also gradual");
        set_keys(16'h8000, 0);
        need(state_debug == OUT && master_gain == 10, "S16 can cancel normal restoration");
        finish_ramp(OUT, WAIT_KEYS, -1);
        recover_normal;

        // 最后一拍准备渐出时退出必须压过进入TEST_IN，不能误选测试音源。
        reset_main; begin_entry(0); samples(255*DIV + DIV-1);
        need(master_gain == 1 && !test_mode, "preparation at final fade boundary");
        key_at_sample(16'h8000);
        need(state_debug == OUT && !test_mode && !clear_audio && master_gain == 1,
            "canceled preparation never enters test at final tick");
        finish_ramp(OUT, WAIT_KEYS, -1);
        need(clear_pulses == 1 && !test_mode, "canceled preparation has only exit clear");
        recover_normal;

        // 来源变化在准备期间生效；仍按着进入组合时不能重新进入。
        reset_main; begin_entry(0); samples(8); set_source(1);
        need(state_debug == OUT && !test_mode && master_gain == 252, "source change cancels preparation");
        finish_ramp(OUT, WAIT_KEYS, -1); samples(HOLD+2);
        need(state_debug == WAIT_KEYS && !test_mode, "canceled chord cannot retrigger while held");
        recover_normal;
        need(remote_active && state_debug == NORMAL, "persistent new source does not trap recovery");

        // 零增益测试渐入中丢源：两个clear之间必须有低电平clk，不连成多拍复位。
        reset_main; begin_entry(1); finish_ramp(NORMAL_OUT, TEST_IN, -1);
        set_source(0);
        need(state_debug == OUT && master_gain == 0 && !clear_audio,
            "source loss cancels zero-gain test fade before first positive step");
        finish_ramp(OUT, WAIT_KEYS, -1);
        need(clear_pulses == 2 && !test_mode, "zero-gain cancellation has separate exit pulse");
        recover_normal;

        reset_main; begin_entry(0); finish_ramp(NORMAL_OUT, TEST_IN, -1); samples(17*DIV);
        set_keys(16'h8000, 0);
        need(state_debug == OUT && master_gain == 17, "S16 exits partway through test fade-in");
        finish_ramp(OUT, WAIT_KEYS, -1); recover_normal;

        // 两种入口来源都锁存：远程->本地、本地->远程均立即退出，不需采样使能。
        for (i=0; i<2; i=i+1) begin
            reset_main; enter_active(i != 0);
            set_keys(0, 0); set_keys(16'h0008, 0);
            set_source(i == 0);
            need(state_debug == OUT && master_gain == 256, "active source change starts bounded exit");
            finish_ramp(OUT, WAIT_KEYS, -1);
            clocks_only(10);
            need(state_debug == WAIT_KEYS, "source loss still requires clean key release");
            recover_normal;
        end

        // 未武装的进入组合长按不会保活；渐变的采样不计入ACTIVE空闲时间。
        reset_main; enter_active(0); samples(IDLE-1); clocks_only(101);
        need(state_debug == ACTIVE, "idle timeout counts only active sample ticks");
        sample;
        need(state_debug == OUT, "unreleased entry chord times out at exact idle bound");
        finish_ramp(OUT, WAIT_KEYS, -1); recover_normal;

        // 到期采样恰有新控制时控制优先；随后长按、无效组合、ghost都不能续期。
        reset_main; enter_active(0); set_keys(0, 0); samples(IDLE-1);
        key_at_sample(16'h0001);
        need(state_debug == ACTIVE && requested_count == 1, "real control at deadline resets idle");
        samples(128);
        set_keys(16'h0003, 0); samples(64);
        set_keys(16'h0001, 1); samples(64); clocks_only(37);
        need(state_debug == ACTIVE, "held and invalid inputs do not cause an early timeout");
        sample;
        need(state_debug == OUT, "held/ghost/invalid controls do not keep the test alive");
        finish_ramp(OUT, WAIT_KEYS, -1);
        set_keys(0, 1); samples(5);
        need(state_debug == WAIT_KEYS, "timeout waits for non-ghost release");
        recover_normal;

        // 扫频内部OFF/ON不是用户操作，完整扫频192拍后仍在原257拍截止时间退出。
        reset_main; enter_active(0); set_keys(0, 0); set_keys(16'h0020, 0);
        samples(IDLE-1);
        need(state_debug == ACTIVE && !sweep_active, "sweep does not alter idle deadline");
        sample;
        need(state_debug == OUT, "automatic sweep transitions cannot reset idle timer");
        finish_ramp(OUT, WAIT_KEYS, -1); recover_normal;

        // 采样暂停可持续任意clk；渐变状态不因系统时钟本身前进。
        reset_main; begin_entry(0); clocks_only(43);
        need(state_debug == NORMAL_OUT && master_gain == 256, "fade waits for sample enable");
        reset_main;
        need(tiny_done && clamp_done && odd_done, "all parameter boundary cases completed");
        $display("OSCILLATOR_TEST_CONTROL_TEST_PASS");
        $finish;
    end
    initial begin
        #5000000;
        $fatal(1, "standalone controller TB watchdog");
    end
endmodule

// 参数边界测试自带刺激和断言，共用系统clk但与主测试输入完全独立。
module oscillator_test_control_parameter_case #(
    parameter integer CASE_ID=0, HOLD=1, IDLE=1, HALF=1, DIV=1
) (input wire clk, output reg done=0);
    localparam integer H=(HOLD>0)?HOLD:1, M=(IDLE>0)?IDLE:1,
                       S=(HALF>0)?HALF:1, R=(DIV>0)?DIV:1;
    reg rst_n=0, tick=0, ghost=0;
    reg [15:0] keys=0;
    wire owned, mode, sweeping, clear;
    wire [31:0] gates;
    wire [5:0] requested;
    wire [4:0] index;
    wire [8:0] gain;
    wire [3:0] state;
    oscillator_test_control #(.HOLD_SAMPLES(HOLD), .MAX_SAMPLES(IDLE),
        .SWEEP_HALF_SAMPLES(HALF), .RAMP_DIV(DIV)) dut (
        .clk(clk), .rst_n(rst_n), .sample_tick(tick), .keys(keys), .ghost(ghost),
        .remote_active(1'b0), .owned(owned), .test_mode(mode), .gate_mask(gates),
        .requested_count(requested), .sweep_active(sweeping), .sweep_index(index),
        .master_gain(gain), .clear_audio(clear), .state_debug(state));
    task need;
        input condition;
        input [511:0] message;
        begin
            if (condition !== 1'b1) begin
                $display("PARAMETER_CASE_%0d FAIL: %0s", CASE_ID, message);
                $fatal(1, "parameter boundary assertion");
            end
        end
    endtask
    task sample;
        begin
            @(negedge clk); tick=1;
            @(posedge clk); #2;
            @(negedge clk); tick=0; #2;
        end
    endtask
    task set_keys;
        input [15:0] value;
        begin @(negedge clk); keys=value; @(posedge clk); #2; end
    endtask
    integer pulses=0;
    reg last_clear=0;
    always @(posedge clk) begin
        #1;
        if (!rst_n) begin pulses=0; last_clear=0; end
        else begin
            need(gain <= 256, "gain bounds for tiny parameters");
            need(!(clear && last_clear), "single-clock clear for tiny parameters");
            if (clear) begin
                pulses=pulses+1;
                need(gain == 0, "clear at zero for tiny parameters");
            end
            last_clear=clear;
        end
    end
    integer j, d, voice, half_tick, used;
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        set_keys(16'h5000);
        repeat(4) @(negedge clk);
        need(!owned, "no sampling means no entry");
        for(j=1; j<H; j=j+1) begin sample; need(!owned, "exact tiny hold threshold"); end
        sample;
        need(state == 1 && owned && gain == 256, "tiny hold enters preparation");
        for(j=0; j<256; j=j+1) begin
            for(d=1; d<=R; d=d+1) begin
                sample;
                if(d == R) need(gain == 255-j, "tiny fade-down step");
                else need(gain == 256-j, "odd divider holds between steps");
            end
        end
        need(state == 2 && mode && clear && requested == 32, "tiny test entry boundary");
        for(j=0; j<256; j=j+1) begin
            for(d=1; d<=R; d=d+1) begin
                sample;
                if(d == R) need(gain == j+1, "tiny fade-up step");
                else need(gain == j, "odd fade-up divider holds");
            end
        end
        need(state == 3 && gain == 256, "tiny parameters reach ACTIVE without idle during ramps");
        set_keys(0); set_keys(16'h0020);
        need(sweeping && index == 0 && gates == 32'hfffffffe, "tiny sweep starts OFF");
        used=0;
        if(M > 64*S) begin
            // HALF=1时每个使能沿都切换半段，逐个验证索引31而非只看最终掩码。
            for(voice=0; voice<32; voice=voice+1) begin
                need(index == voice && gates == (32'hffffffff ^ (32'h1 << voice)),
                    "tiny half OFF mask/index");
                for(half_tick=0; half_tick<S; half_tick=half_tick+1) begin sample; used=used+1; end
                need(index == voice && gates == 32'hffffffff && sweeping, "tiny half ON mask/index");
                for(half_tick=0; half_tick<S; half_tick=half_tick+1) begin sample; used=used+1; end
            end
            need(!sweeping && gates == 32'hffffffff && index == 31, "tiny sweep ends without wrap");
        end
        for(j=used; j<M-1; j=j+1) begin sample; need(state == 3, "tiny idle not early"); end
        sample;
        need(state == 4 && gain == 256 && !sweeping, "tiny exact idle cutoff");
        for(j=0; j<256*R; j=j+1) sample;
        need(state == 5 && owned && gain == 0 && !mode && gates == 0 && requested == 0,
            "tiny exit bounded and silent");
        need(pulses == 2, "tiny entry and exit each clear once");
        sample;
        need(state == 5, "held sweep key prevents recovery");
        @(negedge clk); keys=0; ghost=1;
        sample;
        need(state == 5, "tiny ghost release blocks recovery");
        @(negedge clk); ghost=0;
        @(posedge clk); #2;
        need(state == 6 && owned, "tiny clean release starts restoration");
        for(j=0; j<256*R; j=j+1) sample;
        need(state == 0 && !owned && gain == 256, "tiny recovery completes");
        done=1;
        $display("OSCILLATOR_PARAMETER_CASE_%0d_PASS", CASE_ID);
    end
endmodule
