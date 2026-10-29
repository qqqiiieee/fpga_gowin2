`timescale 1ns/1ps
// Two continuous FSR controls from ADS1115 A0/A1; no hit/note/drum outputs.
// clk: 27 MHz, rst_n: asynchronous active-low reset, ready: synchronous enable.
// adc_valid qualifies one complete sample. A2/A3 never change either channel.
// ADS1115 +/-4.096 V: 1 count = 125 uV; negative signed samples become zero.
// Start/reconnect with both sensors unloaded: each channel learns its own mean
// of CAL_SAMPLES accepted samples. The last calibration sample still outputs 0.
//
// Parameters (constant integers, no automatic clamping):
//   CAL_SAMPLES: 1..256 samples PER CHANNEL; default 16, arithmetic mean rounded
//                down. Non-power-of-two values are supported (constant divide).
//   DEAD_COUNT:  0..32767 ADC counts; delta <= DEAD_COUNT gives target 0.
//   SCALE_SHIFT: 0..15; otherwise target = min(255, delta >> SCALE_SHIFT).
//                Deadband is a gate, NOT subtracted before scaling. Defaults:
//                delta 64 -> 0, 65 -> 4, 4080 -> 255 (8 mV / 0.510 V).
//   STALE_CYCLES: 1..2147483647 clk cycles without THIS CHANNEL's valid sample;
//                 default 6750000 = 250 ms at 27 MHz. A sample on the expiry
//                 edge wins. ready=0 clears both channels on the next clk.
//
// Each stale channel clears level, baseline, partial calibration and calibrated
// independently, even while ready stays high and the other ADC channels flow.
// Recovery starts a NEW CAL_SAMPLES-sample calibration (no old mean/history).
// After calibration baseline NEVER rises, including in the deadband: this
// deliberately prevents repeated subthreshold upward steps eating a slow press.
// It follows lower raw samples by max(1, floor((baseline-raw)/32)) per accepted
// sample. Thus a constant positive pressure cannot be absorbed by the baseline.
// level follows target by floor(abs(target-level)/4) per own accepted sample;
// a remaining distance <4 is completed directly. No sample means no filtering.
// All stored counters are sized packed vectors; no integer state is inferred.
module pressure_expression #(
    parameter integer CAL_SAMPLES = 16,
    parameter integer DEAD_COUNT = 64,
    parameter integer SCALE_SHIFT = 4,
    parameter integer STALE_CYCLES = 6750000
)(
    input wire clk,
    input wire rst_n,
    input wire ready,
    input wire adc_valid,
    input wire [1:0] adc_channel,
    input wire [15:0] adc_data,
    output wire [7:0] level0,
    output wire [7:0] level1,
    output wire [1:0] calibrated
);
    localparam integer CAL_WIDTH = (CAL_SAMPLES <= 1) ? 1 : $clog2(CAL_SAMPLES);
    localparam integer SUM_WIDTH = 16 + CAL_WIDTH;
    localparam integer AGE_WIDTH = (STALE_CYCLES <= 1) ? 1 : $clog2(STALE_CYCLES);
    localparam [CAL_WIDTH-1:0] CAL_LAST = CAL_SAMPLES - 1;
    localparam [AGE_WIDTH-1:0] AGE_LAST = STALE_CYCLES - 1;
    localparam [15:0] DEAD_LIMIT = DEAD_COUNT;
    wire [15:0] raw = adc_data[15] ? 16'd0 : adc_data;
    wire [7:0] levels [0:1];
    assign level0 = levels[0];
    assign level1 = levels[1];

    genvar ch;
    generate for (ch = 0; ch < 2; ch = ch + 1) begin : channel_state
        reg [15:0] baseline;
        reg [SUM_WIDTH-1:0] cal_sum;
        reg [CAL_WIDTH-1:0] cal_count;
        reg [AGE_WIDTH-1:0] age;
        reg [7:0] level;
        reg cal_done;
        wire own_sample = adc_valid && (adc_channel == ch);
        wire [SUM_WIDTH-1:0] sum_with_sample =
            cal_sum + {{(SUM_WIDTH-16){1'b0}}, raw};
        wire [15:0] mean_with_sample = sum_with_sample / CAL_SAMPLES;
        wire [15:0] delta = (raw > baseline) ? raw - baseline : 16'd0;
        wire [15:0] scaled = delta >> SCALE_SHIFT;
        wire [7:0] target = (delta <= DEAD_LIMIT) ? 8'd0 :
                                   ((scaled >= 16'd255) ? 8'd255 : scaled[7:0]);
        wire [7:0] distance = (target > level) ? target - level : level - target;
        wire [7:0] step = (distance < 8'd4) ? distance : (distance >> 2);
        wire [15:0] down_distance = (baseline > raw) ? baseline - raw : 16'd0;
        wire [15:0] down_step = (down_distance < 16'd32) ? 16'd1 :
                                                                        (down_distance >> 5);
        assign levels[ch] = level;
        assign calibrated[ch] = cal_done;

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                baseline <= 16'd0;
                cal_sum <= {SUM_WIDTH{1'b0}};
                cal_count <= {CAL_WIDTH{1'b0}};
                age <= {AGE_WIDTH{1'b0}};
                level <= 8'd0;
                cal_done <= 1'b0;
            end else if (!ready) begin
                baseline <= 16'd0;
                cal_sum <= {SUM_WIDTH{1'b0}};
                cal_count <= {CAL_WIDTH{1'b0}};
                age <= {AGE_WIDTH{1'b0}};
                level <= 8'd0;
                cal_done <= 1'b0;
            end else if (own_sample) begin
                // Highest priority: a fresh sample on the timeout edge is live.
                age <= {AGE_WIDTH{1'b0}};
                if (!cal_done) begin
                    cal_sum <= sum_with_sample;
                    level <= 8'd0;
                    if (cal_count == CAL_LAST) begin
                        baseline <= mean_with_sample;
                        cal_done <= 1'b1;
                    end else begin
                        cal_count <= cal_count + 1'b1;
                    end
                end else begin
                    if (raw < baseline)
                        baseline <= baseline - down_step;
                    if (target >= level)
                        level <= level + step;
                    else
                        level <= level - step;
                end
            end else if (age == AGE_LAST) begin
                // Saturate age here. No other channel can refresh this timer.
                baseline <= 16'd0;
                cal_sum <= {SUM_WIDTH{1'b0}};
                cal_count <= {CAL_WIDTH{1'b0}};
                level <= 8'd0;
                cal_done <= 1'b0;
            end else begin
                age <= age + 1'b1;
            end
        end
    end endgenerate
endmodule
