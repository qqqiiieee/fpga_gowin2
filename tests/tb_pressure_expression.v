`timescale 1ns/1ps
// Independent black-box tests: DUT ports only, no hierarchical state access.
// MODE 0: full directed suite; 1: tiny timer boundaries; 2: real default timer;
// MODE 3: extreme parameters; 4: every signed 16-bit ADC bit pattern.
module tb_pressure_expression #(
    parameter integer TEST_CAL_SAMPLES = 16,
    parameter integer TEST_DEAD_COUNT = 64,
    parameter integer TEST_SCALE_SHIFT = 4,
    parameter integer TEST_STALE_CYCLES = 128,
    parameter integer MODE = 0
);
    reg clk = 0;
    always #18.518 clk = !clk;
    reg rst_n = 0, ready = 0, adc_valid = 0;
    reg [1:0] adc_channel = 0;
    reg [15:0] adc_data = 0;
    wire [7:0] level0, level1;
    wire [1:0] calibrated;
    integer checks = 0, groups = 0;
    integer e0 = 0, e1 = 0;
    integer i, j, k, b0, b1, sum0, sum1, probe, micro, goal, old0, old1;

    pressure_expression #(
        .CAL_SAMPLES(TEST_CAL_SAMPLES), .DEAD_COUNT(TEST_DEAD_COUNT),
        .SCALE_SHIFT(TEST_SCALE_SHIFT), .STALE_CYCLES(TEST_STALE_CYCLES)
    ) dut (
        .clk(clk), .rst_n(rst_n), .ready(ready), .adc_valid(adc_valid),
        .adc_channel(adc_channel), .adc_data(adc_data),
        .level0(level0), .level1(level1), .calibrated(calibrated)
    );

    task check;
        input condition;
        input [8*160-1:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                $display("FAIL %0s time=%0t cal=%b levels=%0d/%0d input=%b/%0d/%0h",
                         message, $time, calibrated, level0, level1,
                         adc_valid, adc_channel, adc_data);
                $fatal(1, "black-box assertion failed");
            end
        end
    endtask

    task group_pass;
        input [8*100-1:0] name;
        begin
            groups = groups + 1;
            $display("GROUP_PASS %0s", name);
        end
    endtask

    // Every call advances exactly one sampled clk edge; samples may be adjacent.
    task cycle;
        input valid;
        input [1:0] ch;
        input [15:0] data;
        begin
            @(negedge clk);
            adc_valid = valid; adc_channel = ch; adc_data = data;
            @(posedge clk); #1;
            check((^{calibrated, level0, level1}) !== 1'bx, "no X/Z outputs");
        end
    endtask

    task reset_dut;
        begin
            @(negedge clk); rst_n = 0; ready = 0; adc_valid = 0;
            #1;
            check({calibrated, level0, level1} === 18'd0, "asynchronous reset clears outputs");
            repeat (2) @(posedge clk);
            @(negedge clk); rst_n = 1; ready = 1;
            e0 = 0; e1 = 0;
        end
    endtask

    function integer mapped;
        input integer delta;
        integer value;
        begin
            value = (delta < 0) ? 0 : delta;
            if (value <= TEST_DEAD_COUNT) mapped = 0;
            else begin
                value = value / (2 ** TEST_SCALE_SHIFT);
                mapped = (value > 255) ? 255 : value;
            end
        end
    endfunction

    function integer tracked;
        input integer previous;
        input integer target;
        integer difference, amount;
        begin
            difference = (target > previous) ? target - previous : previous - target;
            amount = (difference < 4) ? difference : difference / 4;
            tracked = (target >= previous) ? previous + amount : previous - amount;
        end
    endfunction

    // The reference uses mathematical output arithmetic and caller-specified
    // target, rather than duplicating/calculating DUT calibration or age state.
    task expect_sample;
        input [1:0] ch;
        input [15:0] data;
        input integer target;
        begin
            if (ch == 0) e0 = tracked(e0, target);
            else e1 = tracked(e1, target);
            cycle(1, ch, data);
            check(calibrated === 2'b11, "both channels remain independently calibrated");
            check(level0 === e0[7:0] && level1 === e1[7:0],
                  "exact quarter-distance smoothing and unchanged opposite channel");
        end
    endtask

    task fresh_pair;
        input integer base0;
        input integer base1;
        integer n;
        begin
            reset_dut;
            for (n = 0; n < TEST_CAL_SAMPLES; n = n + 1) begin
                cycle(1, 0, base0);
                check(calibrated === ((n == TEST_CAL_SAMPLES-1) ? 2'b01 : 2'b00),
                      "A0 exact calibration sample count");
                check(level0 === 0 && level1 === 0, "calibration outputs zero");
                cycle(1, 1, base1);
                check(calibrated === ((n == TEST_CAL_SAMPLES-1) ? 2'b11 : 2'b00),
                      "A1 exact calibration sample count");
                check(level0 === 0 && level1 === 0, "final calibration sample still zero");
            end
        end
    endtask

    task hold_pair;
        input integer raw0;
        input integer raw1;
        input integer target0;
        input integer target1;
        input integer count;
        integer n;
        begin
            for (n = 0; n < count; n = n + 1) begin
                expect_sample(0, raw0, target0);
                expect_sample(1, raw1, target1);
            end
        end
    endtask

    task full_suite;
        begin
            check(TEST_STALE_CYCLES >= 16, "full suite needs timer >=16");
            probe = ((TEST_DEAD_COUNT >> TEST_SCALE_SHIFT) + 8) * (2 ** TEST_SCALE_SHIFT);
            micro = TEST_DEAD_COUNT + 1;
            if (micro < (2 ** TEST_SCALE_SHIFT)) micro = 2 ** TEST_SCALE_SHIFT;

            reset_dut;
            for (i = 0; i < TEST_CAL_SAMPLES-1; i = i + 1) begin
                cycle(1, 0, 1000);
                cycle(1, 2, 16'h7fff);
                cycle(1, 3, 16'h8000);
                cycle(0, 1, 3000);
                check(calibrated === 0, "only accepted own-channel samples count");
            end
            cycle(1, 0, 1000);
            check(calibrated === 1, "A0 calibrates without A1");
            cycle(1, 0, 1000 + probe);
            check(level0 === tracked(0, mapped(probe)) && level1 === 0,
                  "A0 responds while A1 is still uncalibrated");
            for (i = 0; i < TEST_CAL_SAMPLES; i = i + 1) begin
                cycle(1, 1, 3000);
                check(calibrated === ((i == TEST_CAL_SAMPLES-1) ? 3 : 1),
                      "A1 calibration independent of A0 history");
                cycle(1, 0, 1000);
            end
            group_pass("independent_calibration_and_valid_channel_gating");

            reset_dut;
            sum0 = 0; sum1 = 0;
            for (i = 0; i < TEST_CAL_SAMPLES; i = i + 1) begin
                b0 = 1000 + (i % 2) * 16;
                b1 = 3000 + (i % 3) * 16;
                sum0 = sum0 + b0; sum1 = sum1 + b1;
                cycle(1, 0, b0); cycle(1, 1, b1);
                check(level0 === 0 && level1 === 0, "variable calibration stays muted");
            end
            b0 = sum0 / TEST_CAL_SAMPLES; b1 = sum1 / TEST_CAL_SAMPLES;
            hold_pair(b0 + probe, b1 + probe, mapped(probe), mapped(probe), 32);
            check(level0 === mapped(probe) && level1 === mapped(probe), "arithmetic mean is used");
            fresh_pair(32767, 32767);
            hold_pair(32767, 32767, 0, 0, 32);
            check(level0 === 0 && level1 === 0, "fullscale calibration sum does not overflow");
            group_pass("mean_rounding_non_power_of_two_and_max_sum");

            fresh_pair(1000, 3000);
            for (j = 0; j <= 255; j = j + 1) begin
                goal = mapped(j * (2 ** TEST_SCALE_SHIFT));
                old0 = level0; old1 = level1;
                hold_pair(1000 + j * (2 ** TEST_SCALE_SHIFT),
                          3000 + j * (2 ** TEST_SCALE_SHIFT), goal, goal, 32);
                check(level0 >= old0 && level1 >= old1, "settled rising ramp is monotonic");
                check(level0 === goal && level1 === goal, "every scale bin settles exactly");
            end
            check(level0 === 255 && level1 === 255, "ramp reaches 255 without overflow");
            for (j = 255; j >= 0; j = j - 1) begin
                goal = mapped(j * (2 ** TEST_SCALE_SHIFT));
                old0 = level0; old1 = level1;
                hold_pair(1000 + j * (2 ** TEST_SCALE_SHIFT),
                          3000 + j * (2 ** TEST_SCALE_SHIFT), goal, goal, 32);
                check(level0 <= old0 && level1 <= old1, "settled falling ramp is monotonic");
                check(level0 === goal && level1 === goal, "falling bins and final <4 residual complete");
            end
            check(level0 === 0 && level1 === 0, "release reaches exact zero");
            group_pass("mapping_monotonic_0_to_255_and_release_smoothing");

            fresh_pair(1000, 3000);
            hold_pair(1000 + TEST_DEAD_COUNT, 3000 + TEST_DEAD_COUNT, 0, 0, 32);
            check(level0 === 0 && level1 === 0, "deadband includes its boundary");
            hold_pair(1000 + micro, 3000 + 4096, mapped(micro), mapped(4096), 32);
            check(level0 > 0, "micro pressure is visible");
            hold_pair(1000 + micro, 3000 + 4096, mapped(micro), mapped(4096), 8192);
            check(level0 === mapped(micro) && level1 === mapped(4096),
                  "sustained light and strong pressure cannot be swallowed");
            hold_pair(1000, 3000, 0, 0, 32);
            check(level0 === 0 && level1 === 0, "release to baseline reaches zero");
            fresh_pair(1000, 3000);
            for (j = 0; j <= TEST_DEAD_COUNT + 128; j = j + 1)
                hold_pair(1000 + j, 3000 + j, mapped(j), mapped(j), 4);
            hold_pair(1128 + TEST_DEAD_COUNT, 3128 + TEST_DEAD_COUNT,
                      mapped(TEST_DEAD_COUNT+128), mapped(TEST_DEAD_COUNT+128), 32);
            check(level0 === mapped(TEST_DEAD_COUNT+128), "slow rising pressure does not ratchet baseline up");
            group_pass("deadband_micro_pressure_sustain_slow_ramp_and_release");

            reset_dut;
            for (i = 0; i < TEST_CAL_SAMPLES; i = i + 1) begin
                cycle(1, 0, (i % 2) ? 16'hffff : 16'h8000);
                cycle(1, 1, 3000);
            end
            check(calibrated === 3, "negative samples are valid zero calibration samples");
            hold_pair(32767, 3000 + probe, mapped(32767), mapped(probe), 32);
            check(level0 === 255, "maximum positive ADC saturates level");
            hold_pair(16'h8000, 16'hffff, 0, 0, 32);
            check(level0 === 0 && level1 === 0, "both signed-negative extremes clamp to zero");
            hold_pair(16'hffff, 16'h8000, 0, 0, 32);
            group_pass("negative_adc_calibration_release_and_positive_saturation");

            fresh_pair(8000, 12000);
            expect_sample(0, 7904, 0); // 96 counts lower: slow baseline step must be 3.
            expect_sample(1, 12000, 0);
            hold_pair(7997 + probe, 12000, mapped(probe), 0, 32);
            check(level0 === mapped(probe), "lower baseline follows slowly rather than jumping");
            hold_pair(7000, 11000, 0, 0, 512);
            hold_pair(7000 + probe, 11000 + probe, mapped(probe), mapped(probe), 32);
            check(level0 === mapped(probe) && level1 === mapped(probe),
                  "slow downward baseline converges with no integer stall");
            group_pass("downward_only_baseline_slow_step_and_convergence");

            fresh_pair(1000, 3000);
            hold_pair(1000 + probe, 3000 + 4096, mapped(probe), mapped(4096), 32);
            expect_sample(0, 1000 + probe, mapped(probe)); // exactly age0=0 here
            old0 = level0; old1 = level1;
            for (i = 1; i < TEST_STALE_CYCLES; i = i + 1) begin
                cycle(1, 1, 3000 + 4096);
                check(calibrated === 3 && level0 === old0 && level1 === old1,
                      "A1 traffic cannot refresh or prematurely expire A0");
            end
            cycle(1, 1, 3000 + 4096);
            check(calibrated === 2 && level0 === 0 && level1 === old1,
                  "A0 expires at exact per-channel deadline while ready stays high");
            for (i = 0; i < TEST_CAL_SAMPLES; i = i + 1) begin
                cycle(1, 0, 5000);
                check(calibrated === ((i == TEST_CAL_SAMPLES-1) ? 3 : 2),
                      "A0 recovery requires a complete fresh calibration");
                check(level0 === 0 && level1 === old1, "A0 stale/recovery does not disturb A1");
                cycle(1, 1, 3000 + 4096);
            end
            e0 = 0; e1 = old1;
            hold_pair(5000 + probe, 3000 + 4096, mapped(probe), mapped(4096), 32);
            fresh_pair(1000, 3000);
            hold_pair(1000 + probe, 3000 + probe, mapped(probe), mapped(probe), 32);
            expect_sample(1, 3000 + probe, mapped(probe));
            for (i = 1; i < TEST_STALE_CYCLES; i = i + 1) begin
                cycle(1, 0, 1000 + probe);
                check(calibrated === 3, "symmetric A1 timeout not early");
            end
            cycle(1, 0, 1000 + probe);
            check(calibrated === 1 && level1 === 0 && level0 === mapped(probe),
                  "A1 independently expires despite A0 traffic");
            group_pass("single_channel_stale_both_directions_and_recalibration");

            fresh_pair(1000, 3000);
            hold_pair(1000 + probe, 3000 + probe, mapped(probe), mapped(probe), 32);
            old0 = level0; old1 = level1;
            for (i = 0; i < TEST_STALE_CYCLES+2; i = i + 1) begin
                cycle(1, (i % 2) ? 2 : 3, 16'h7fff);
                if (i < 4)
                    check(level0 === old0 && level1 === old1, "A2/A3 never feed either smoother");
            end
            check({calibrated, level0, level1} === 0, "A2/A3 stream cannot keep either FSR live");
            for (i = 0; i < TEST_CAL_SAMPLES+2; i = i + 1) cycle(0, 0, 1000);
            check(calibrated === 0, "adc_valid=0 cannot calibrate or refresh");
            group_pass("ignored_A2_A3_and_invalid_stream_do_not_keepalive");

            if (TEST_CAL_SAMPLES > 1) begin
                reset_dut;
                for (i = 0; i < TEST_CAL_SAMPLES-1; i = i + 1) cycle(1, 0, 1000);
                for (i = 0; i < TEST_STALE_CYCLES; i = i + 1) cycle(0, 0, 1000);
                for (i = 0; i < TEST_CAL_SAMPLES-1; i = i + 1) begin
                    cycle(1, 0, 6000);
                    check(calibrated === 0, "stale partial calibration count discarded");
                end
                cycle(1, 0, 6000);
                check(calibrated === 1 && level0 === 0, "fresh calibration completes after partial stale");
                e0 = 0;
                for (i = 0; i < 32; i = i + 1) begin
                    e0 = tracked(e0, mapped(probe));
                    cycle(1, 0, 6000 + probe);
                    check(level0 === e0[7:0], "partial calibration sum was also discarded");
                end
            end
            group_pass("stale_during_partial_calibration_discards_sum_and_count");

            fresh_pair(1000, 3000);
            hold_pair(1000 + probe, 3000 + probe, mapped(probe), mapped(probe), 32);
            @(negedge clk); ready = 0; adc_valid = 0;
            for (i = 0; i < TEST_CAL_SAMPLES+2; i = i + 1) begin
                cycle(1, i % 2, 32767);
                check({calibrated, level0, level1} === 0, "ready low clears and rejects samples");
            end
            @(negedge clk); ready = 1; adc_valid = 0;
            e0 = 0; e1 = 0;
            for (i = 0; i < TEST_CAL_SAMPLES; i = i + 1) begin
                cycle(1, 0, 5000);
                check(calibrated === ((i == TEST_CAL_SAMPLES-1) ? 1 : 0), "ready recovery fresh A0 count");
                cycle(1, 1, 9000);
                check(calibrated === ((i == TEST_CAL_SAMPLES-1) ? 3 : 0), "ready recovery fresh A1 count");
                check(level0 === 0 && level1 === 0, "ready recovery calibrates changed unloaded values");
            end
            hold_pair(5000 + probe, 9000 + probe, mapped(probe), mapped(probe), 32);
            @(negedge clk); rst_n = 0;
            #1;
            check({calibrated, level0, level1} === 0, "reset immediately clears active pressure");
            group_pass("ready_drop_recalibration_and_async_reset");
        end
    endtask

    task tiny_timer;
        begin
            reset_dut;
            for (i = 0; i < TEST_CAL_SAMPLES; i = i + 1) cycle(1, 0, 1000);
            check(calibrated === 1, "contiguous calibration works with tiny timeout");
            for (i = 0; i < 32; i = i + 1) cycle(1, 0, 5080);
            check(level0 === 255 && level1 === 0, "continuous samples do not timeout");
            for (i = 1; i < TEST_STALE_CYCLES; i = i + 1) begin
                cycle(1, 2, 32767);
                check(calibrated === 1 && level0 === 255, "tiny timer not early");
            end
            cycle(1, 0, 5080); // a fresh own sample on the exact expiry edge wins
            check(calibrated === 1 && level0 === 255, "fresh sample wins expiry edge");
            for (i = 1; i < TEST_STALE_CYCLES; i = i + 1) cycle(1, 3, 32767);
            cycle(0, 0, 5080);
            check(calibrated === 0 && level0 === 0, "tiny timeout exact and invalid own sample ignored");
            for (i = 0; i < TEST_CAL_SAMPLES; i = i + 1) begin
                cycle(1, 0, 7000);
                check(calibrated === ((i == TEST_CAL_SAMPLES-1) ? 1 : 0), "tiny timer recovery count");
                check(level0 === 0, "tiny timer recovery zeros level");
            end
            group_pass("tiny_timer_width_expiry_priority_and_recovery");
        end
    endtask

    task production_timer;
        begin
            reset_dut;
            for (i = 0; i < TEST_CAL_SAMPLES; i = i + 1) cycle(1, 0, 1000);
            for (i = 0; i < 32; i = i + 1) cycle(1, 0, 5080);
            check(calibrated === 1 && level0 === 255, "production timer setup");
            @(negedge clk); adc_valid = 0;
            repeat (TEST_STALE_CYCLES-1) @(posedge clk);
            #1;
            check(calibrated === 1 && level0 === 255, "default 6750000 timer no early clear");
            @(posedge clk); #1;
            check(calibrated === 0 && level0 === 0, "default 250ms exact cycle clear");
            group_pass("unscaled_production_6750000_cycle_boundary");
        end
    endtask

    task parameter_extremes;
        begin
            fresh_pair(0, 32767);
            for (j = 0; j < 512; j = j + 1) begin
                expect_sample(0, (j % 2) ? 32767 : 16'h8000, mapped((j % 2) ? 32767 : 0));
                expect_sample(1, 32767, 0);
            end
            check(level1 === 0, "upper calibration sum and lower scale boundary");
            group_pass("dead_count_32767_scale_shift_15_and_calibration_256_bounds");
        end
    endtask

    task exhaustive_adc;
        integer raw0, raw1;
        begin
            fresh_pair(0, 0);
            for (j = 0; j < 65536; j = j + 1) begin
                raw0 = (j >= 32768) ? 0 : j;
                raw1 = (65535-j >= 32768) ? 0 : 65535-j;
                expect_sample(0, j, mapped(raw0));
                expect_sample(1, 65535-j, mapped(raw1));
            end
            hold_pair(0, 0, 0, 0, 32);
            check(level0 === 0 && level1 === 0, "exhaustive signed ADC ends at exact zero");
            group_pass("all_65536_adc_words_both_channels_exact_public_output_model");
        end
    endtask

    initial begin
        $display("PARAMETERS CAL=%0d DEAD=%0d SHIFT=%0d STALE=%0d MODE=%0d",
                 TEST_CAL_SAMPLES, TEST_DEAD_COUNT, TEST_SCALE_SHIFT, TEST_STALE_CYCLES, MODE);
        case (MODE)
            0: full_suite;
            1: tiny_timer;
            2: production_timer;
            3: parameter_extremes;
            4: exhaustive_adc;
            default: $fatal(1, "unsupported test mode");
        endcase
        $display("PRESSURE_EXPRESSION_TEST_PASS checks=%0d groups=%0d", checks, groups);
        $finish;
    end
    initial begin
        #1000000000;
        $fatal(1, "simulation watchdog");
    end
endmodule
