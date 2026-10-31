// 视觉专用自主落键时间轴：不读取按键、不等待正确音、不产生Note/PCM或评分。
// clk 为27MHz源域；sample_tick 是93750Hz音频采样使能，默认46875采样/拍=120BPM。
// roll_tick 单位为1/64拍，12位，包含两拍预备；roll_song 是命令到达时锁存的曲目。
// pause 由顶层合并非LIVE页、菜单占用、测试所有权；冻结位置和分数相位。
// ui_toggle 切换 active，保留全部时基；ui_start/ui_restart 锁存song_id并归零，
// 优先于 toggle/pause/sample_tick。曲目输入在普通运行中改变不会造成跳曲。
// 复位立即从曲目0预备拍开始，沿用历史guide的active=1启动约定。
// 自然结束停在 total_beats*64，完整走完最后一音的一/两拍后才置done。
// done锁存至重开，toggle不能复活已结束曲目。所有控制事件均为clk域单拍。
// SONG_LIBRARY_ENABLE=1: V045 quarter-resolution synchronous BRAM replaces
// BOTH old combinational score decoders; default=0 preserves legacy tests.
// Production beat periods are 46875/50223/56250 (120/112/100 BPM). Accelerated
// BEAT_SAMPLES overrides stay parameter-driven; custom tempo stays config-driven.
module piano_roll_guide #(
    parameter BEAT_SAMPLES = 46875,
    parameter CUSTOM_SCORE_ENABLE = 0,
    parameter SONG_LIBRARY_ENABLE = 0
) (
    input clk, input rst_n, input sample_tick, input pause,
    input [1:0] song_id,
    input ui_start, input ui_toggle, input ui_restart,
    output reg [11:0] roll_tick,
    output reg [1:0] roll_song,
    output reg active, output reg done,
    output [5:0] step_index, output [5:0] total_steps,
    output [7:0] beat_progress, output [1:0] target_beats,
    output reg beat_pulse,
    output [5:0] total_beats,
    output [6:0] expected_note, output expected_valid,
    output [11:0] cue_mask, output [11:0] next_mask, output count_in,
    // Public write bus: custom_write_clk and clk MUST be the same 27MHz
    // source clock. The second RAM copy is read on the pixel clock.
    input custom_write_clk, input custom_write_en,
    input [8:0] custom_write_addr, input [31:0] custom_write_data,
    input [31:0] custom_config,
    // Validity of the CURRENT address, including rests/count-in. A low value
    // is a synchronous-RAM bubble, not a rest; practice/demo must use this.
    // Legacy combinational scores are always ready. No clock-domain crossing.
    output score_ready, output [14:0] expected_offsets
);
    function integer bits_required;
        input integer value;
        integer remaining;
        begin
            remaining = value; bits_required = 0;
            while (remaining > 0) begin
                bits_required = bits_required + 1;
                remaining = remaining >> 1;
            end
            if (bits_required == 0) bits_required = 1;
        end
    endfunction
    localparam integer BEAT_LENGTH = (BEAT_SAMPLES < 1) ? 1 : BEAT_SAMPLES;
    // The largest built-in period (56250) still fits the default 16-bit phase;
    // only custom's 187500-sample upper limit needs 18 bits.
    localparam integer PHASE_WIDTH = CUSTOM_SCORE_ENABLE && BEAT_LENGTH < 187500 ?
                                    18 : bits_required(BEAT_LENGTH);
    // 除法/余数只在参数展开时求值；每个有效采样只执行加法、比较和减法。
    // floor(N*64/BEAT_LENGTH) 的余数始终保留，不将单tick长度四舍五入，
    // 因而46875、67等不能被64整除的拍长也不会逐拍漂移。
    // BEAT_LENGTH<64时可单次推进多tick，仍保证每拍精确BEAT_LENGTH个采样。
    localparam [6:0] TICK_INCREMENT = 64 / BEAT_LENGTH;
    localparam [PHASE_WIDTH:0] TICK_REMAINDER = 64 % BEAT_LENGTH;
    localparam [PHASE_WIDTH:0] PHASE_LIMIT = BEAT_LENGTH;
    reg [PHASE_WIDTH-1:0] fractional_phase;
    wire is_custom = CUSTOM_SCORE_ENABLE && roll_song == 2'd3;
    wire [31:0] custom_cfg;
    wire custom_cfg_changed, custom_cfg_valid;
    wire [31:0] custom_word;
    wire custom_word_ready;
    generate if (CUSTOM_SCORE_ENABLE) begin: custom_score
        reg [31:0] config_latched;
        // Entire config is synchronous to clk. Any edit while custom is
        // selected restarts at tick0, including while paused/done. Preserve
        // user pause; external ownership pause also freezes fresh count-in.
        always @(posedge clk or negedge rst_n)
            if (!rst_n) config_latched <= 0;
            else config_latched <= custom_config;
        assign custom_cfg = config_latched;
        assign custom_cfg_changed = custom_config != config_latched;
        assign custom_cfg_valid = custom_cfg[30] && custom_cfg[29:24] != 0 &&
            custom_cfg[23:18] != 0 && custom_cfg[17:0] >= 23437 &&
            custom_cfg[17:0] <= 187500;
        wire [8:0] address = {custom_cfg[31],roll_tick[11:4]};
        reg [8:0] read_tag;
        reg read_valid;
        custom_score_ram ram(.custom_write_clk(custom_write_clk),
            .custom_write_en(custom_write_en),.custom_write_addr(custom_write_addr),
            .custom_write_data(custom_write_data),.read_clk(clk),
            .read_addr(address),.read_data(custom_word));
        always @(posedge clk or negedge rst_n)
            if (!rst_n) begin read_tag<=0;read_valid<=0;end
            else begin read_tag<=address;read_valid<=1;end
        // At a quarter/bank transition the synchronous RAM still contains
        // the old address for ONE 27MHz cycle. Mask it, never publish the old
        // note under the new tick. It settles long before the next sample
        // (288 clocks/sample in production); no audio gate uses this data.
        assign custom_word_ready = read_valid && read_tag == address &&
                                   !custom_cfg_changed;
    end else begin: no_custom_score
        assign custom_cfg=0;
        assign custom_cfg_changed=0;
        assign custom_cfg_valid=0;
        assign custom_word=0;
        assign custom_word_ready=0;
    end endgenerate
    // No variable divide/modulo. For custom scores the accumulator adds64
    // each enabled sample, then compare/subtracts the run-time beat length.
    // Supported denominators are >=23437, hence at most one carry/sample.
    // Built-in small-parameter tests retain their constant multi-tick path.
    // Production built-ins use 120/112/100 BPM at 93750 samples/s. Any explicit
    // non-default BEAT_SAMPLES keeps the legacy accelerated parameter timebase,
    // including <64 samples/beat and its multi-tick increments. Custom tempo
    // remains config-driven regardless of either built-in parameter.
    wire [17:0] builtin_beat_samples;
    wire library_tempo = SONG_LIBRARY_ENABLE && BEAT_SAMPLES == 46875;
    wire variable_tempo = is_custom || library_tempo;
    wire [PHASE_WIDTH:0] phase_limit = is_custom ? custom_cfg[17:0] :
        (library_tempo ? builtin_beat_samples : PHASE_LIMIT);
    wire [PHASE_WIDTH:0] phase_sum = {1'b0,fractional_phase} +
        (variable_tempo ? 7'd64 : TICK_REMAINDER);
    wire phase_carry = phase_sum >= phase_limit;
    wire [12:0] next_tick = {1'b0,roll_tick} + (variable_tempo ? 7'd0 : TICK_INCREMENT) +
                            {12'd0,phase_carry};
    wire [11:0] end_tick = {total_beats,6'b000000};
    wire [6:0] score_note, builtin_note;
    wire score_valid, score_onset, builtin_valid, builtin_onset;
    wire [5:0] builtin_step,builtin_steps,builtin_beats;
    wire builtin_ready, builtin_long_note;
    wire [6:0] builtin_next_note;
    wire builtin_next_valid;
    generate if (SONG_LIBRARY_ENABLE) begin: builtin_library
        wire [9:0] address = {roll_song,roll_tick[11:4]};
        wire [31:0] word_data;
        reg [9:0] read_tag;
        reg read_valid;
        piano_builtin_score_ram ram(.read_clk(clk),.read_addr(address),
            .read_data(word_data),.total_steps(builtin_steps),
            .total_beats(builtin_beats),.beat_samples(builtin_beat_samples));
        always @(posedge clk or negedge rst_n)
            if (!rst_n) begin read_tag<=0;read_valid<=0;end
            else begin read_tag<=address;read_valid<=1;end
        assign builtin_ready = read_valid && read_tag == address;
        wire in_range = roll_song != 2'd3 && roll_tick >= 128 &&
                        roll_tick < {builtin_beats,6'd0};
        assign builtin_note = (builtin_ready && in_range) ? word_data[6:0] : 7'd0;
        assign builtin_valid = builtin_ready && in_range && word_data[13];
        assign builtin_onset = word_data[14];
        assign builtin_long_note = word_data[15];
        // The final step is stable even on the one-clock end-address bubble.
        assign builtin_step = done ? builtin_steps-6'd1 :
                              (builtin_ready ? word_data[12:7] : 6'd0);
        assign builtin_next_note = word_data[22:16];
        assign builtin_next_valid = builtin_ready && roll_song != 2'd3 &&
                                    roll_tick < {builtin_beats,6'd0} && word_data[23];
    end else begin: legacy_builtin
        piano_roll_score score (
            .song_id(roll_song),.beat_index(roll_tick[11:6]),
            .note(builtin_note),.valid(builtin_valid),.onset(builtin_onset),
            .step_index(builtin_step),.total_steps(builtin_steps),.total_beats(builtin_beats)
        );
        reg long_note;
        always @* begin
            case (roll_song)
                1: long_note = step_index==7 || step_index==15 || step_index==23 || step_index==31;
                2: long_note = step_index==10 || step_index==13 || step_index==28 || step_index==31;
                default: long_note = step_index==6 || step_index==13 || step_index==20 ||
                                     step_index==27 || step_index==34 || step_index==41;
            endcase
        end
        assign builtin_long_note = long_note;
        wire [5:0] next_beat_index = !score_valid ? 6'd2 :
            roll_tick[11:6] + ((long_note && score_onset) ? 6'd2 : 6'd1);
        piano_roll_score next_score (
            .song_id(roll_song),.beat_index(next_beat_index),
            .note(builtin_next_note),.valid(builtin_next_valid),
            .onset(),.step_index(),.total_steps(),.total_beats()
        );
        assign builtin_ready = 1'b1;
        assign builtin_beat_samples = BEAT_LENGTH;
    end endgenerate
    assign score_ready = is_custom ? (custom_cfg_valid && custom_word_ready) : builtin_ready;
    wire custom_in_range = custom_cfg_valid && roll_tick >= 128 &&
                           roll_tick < {custom_cfg[23:18],6'd0};
    assign score_note = is_custom ?
        ((custom_in_range && custom_word_ready) ? custom_word[6:0] : 7'd0) : builtin_note;
    assign score_valid = is_custom ?
        (custom_in_range && custom_word_ready && custom_word[13]) : builtin_valid;
    assign score_onset = is_custom ? custom_word[14] : builtin_onset;
    assign total_steps = is_custom ? (custom_cfg_valid ? custom_cfg[29:24] : 6'd0) : builtin_steps;
    assign total_beats = is_custom ? (custom_cfg_valid ? custom_cfg[23:18] : 6'd0) : builtin_beats;
    assign step_index = !is_custom ? builtin_step :
        (!custom_cfg_valid ? 6'd0 : (done ? custom_cfg[29:24]-6'd1 :
        ((custom_in_range && custom_word_ready) ? custom_word[12:7] : 6'd0)));
    wire long_note = is_custom ? custom_word[15] : builtin_long_note;
    assign count_in = !done && (roll_tick < 12'd128);
    assign expected_note = score_note;
    // V047 flag31 selects root + three 5-bit intervals; old words unchanged.
    assign expected_offsets = is_custom && custom_word[31] ? custom_word[30:16] : 15'd0;
    assign expected_valid = active && !done && score_valid;
    // Legacy进度按完整音符时长归一化；两拍音第一拍0..126，第二拍128..254。
    // V045/custom use quarter progress and the coarse duration hint below.
    // 只做位拼接，不用运行时除法；done后显示255，末音步号保留以供完成画面。
    // toggle暂停保留进度；外部pause同样不影响当前提示状态。
    assign beat_progress = done ? 8'hff : (!score_valid ? 8'd0 :
                           ((is_custom || SONG_LIBRARY_ENABLE) ? {roll_tick[3:0],4'b0000} :
                            long_note ? {!score_onset,roll_tick[5:0],1'b0} :
                                        {roll_tick[5:0],2'b00}));
    assign target_beats = (!done && score_valid) ? (long_note ? 2'd2 : 2'd1) : 2'd0;
    // Custom/V045 words contain no exact note-duration field. The numeric
    // HUD shows phase within the current quarter (0..240), with longnote as
    // a coarse 1-or-2-beat hint. Actual roll duration/onsets come from all quarter
    // entries and are exact; no note-length division/search logic is added.
    function [11:0] note_mask;
        input [6:0] midi_note;
        begin
            case (midi_note)
                60: note_mask=12'h001; 62: note_mask=12'h002; 64: note_mask=12'h004;
                65: note_mask=12'h008; 67: note_mask=12'h010; 69: note_mask=12'h020;
                71: note_mask=12'h040; 72: note_mask=12'h080; 74: note_mask=12'h100;
                76: note_mask=12'h200; 77: note_mask=12'h400; 79: note_mask=12'h800;
                default: note_mask=0;
            endcase
        end
    endfunction
    // Legacy next_score skips whole notes in its legacy-only generate branch
    // above. V045/custom instead read precomputed next fields from the SAME
    // word: no second lookup or read port, including count-in/rest/end.
    wire [6:0] next_note;
    wire next_valid;
    // next_note/next_valid are precomputed by the uploader, including the
    // eight count-in quarters. Never instantiate another read port/RAM.
    assign next_note = is_custom ? custom_word[22:16] : builtin_next_note;
    assign next_valid = is_custom ? (custom_cfg_valid && custom_word_ready && !custom_word[31] &&
        roll_tick < end_tick && custom_word[23]) : builtin_next_valid;
    assign cue_mask = expected_valid ? note_mask(score_note) : 12'd0;
    assign next_mask = (active && !done && next_valid) ? note_mask(next_note) : 12'd0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            roll_tick<=0; roll_song<=0; active<=1; done<=0;
            fractional_phase<=0; beat_pulse<=0;
        end else begin
            // beat_pulse是一个clk脉冲，冻结期间不保留上一次脉冲。
            beat_pulse<=0;
            if (ui_start || ui_restart) begin
                roll_song <= (song_id==1 || song_id==2 ||
                              (CUSTOM_SCORE_ENABLE && song_id==3)) ? song_id : 2'd0;
                roll_tick<=0; fractional_phase<=0; active<=1; done<=0;
            end else if (is_custom && custom_cfg_changed) begin
                roll_tick<=0; fractional_phase<=0; done<=0;
                // A commit never revives user pause/completion on its own.
                // A simultaneous toggle is still honoured, allowing parent
                // controller commit/select/pause and phone op20 control.
                if (ui_toggle) active<=!active;
            end else if (is_custom && !custom_cfg_valid) begin
                // Empty/malformed config must never expose uninitialised RAM
                // or silently fall back to built-in song0.
                roll_tick<=0; fractional_phase<=0; active<=0; done<=1;
            end else if (ui_toggle) begin
                if (!done) active<=!active;
            end else if (active && !done && !pause && sample_tick) begin
                if (phase_carry) fractional_phase<=phase_sum-phase_limit;
                else fractional_phase<=phase_sum[PHASE_WIDTH-1:0];
                beat_pulse <= next_tick[12:6] != {1'b0,roll_tick[11:6]};
                if (next_tick >= {1'b0,end_tick}) begin
                    roll_tick<=end_tick; fractional_phase<=0; active<=0; done<=1;
                end else roll_tick<=next_tick[11:0];
            end
        end
    end
endmodule
