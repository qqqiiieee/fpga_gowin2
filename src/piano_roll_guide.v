// 视觉专用自主落键时间轴：不读取按键、不等待正确音、不产生Note/PCM或评分。
// clk 为27MHz源域；sample_tick 是93750Hz音频采样使能，默认46875采样/拍=120BPM。
// roll_tick 单位为1/64拍，12位，包含两拍预备；roll_song 是命令到达时锁存的曲目。
// pause 由顶层合并非LIVE页、菜单占用、测试所有权；冻结位置和分数相位。
// ui_toggle 切换 active，保留全部时基；ui_start/ui_restart 锁存song_id并归零，
// 优先于 toggle/pause/sample_tick。曲目输入在普通运行中改变不会造成跳曲。
// 复位立即从曲目0预备拍开始，沿用历史guide的active=1启动约定。
// 自然结束停在 total_beats*64，完整走完最后一音的一/两拍后才置done。
// done锁存至重开，toggle不能复活已结束曲目。所有控制事件均为clk域单拍。
module piano_roll_guide #(
    parameter BEAT_SAMPLES = 46875
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
    output [11:0] cue_mask, output [11:0] next_mask, output count_in
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
    localparam integer PHASE_WIDTH = bits_required(BEAT_LENGTH);
    // 除法/余数只在参数展开时求值；每个有效采样只执行加法、比较和减法。
    // floor(N*64/BEAT_LENGTH) 的余数始终保留，不将单tick长度四舍五入，
    // 因而46875、67等不能被64整除的拍长也不会逐拍漂移。
    // BEAT_LENGTH<64时可单次推进多tick，仍保证每拍精确BEAT_LENGTH个采样。
    localparam [6:0] TICK_INCREMENT = 64 / BEAT_LENGTH;
    localparam [PHASE_WIDTH:0] TICK_REMAINDER = 64 % BEAT_LENGTH;
    localparam [PHASE_WIDTH:0] PHASE_LIMIT = BEAT_LENGTH;
    reg [PHASE_WIDTH-1:0] fractional_phase;
    wire [PHASE_WIDTH:0] phase_sum = {1'b0,fractional_phase} + TICK_REMAINDER;
    wire phase_carry = phase_sum >= PHASE_LIMIT;
    wire [12:0] next_tick = {1'b0,roll_tick} + {6'd0,TICK_INCREMENT} +
                            {12'd0,phase_carry};
    wire [11:0] end_tick = {total_beats,6'b000000};
    wire [6:0] score_note;
    wire score_valid, score_onset;
    piano_roll_score score (
        .song_id(roll_song),.beat_index(roll_tick[11:6]),
        .note(score_note),.valid(score_valid),.onset(score_onset),
        .step_index(step_index),.total_steps(total_steps),.total_beats(total_beats)
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
    assign count_in = !done && (roll_tick < 12'd128);
    assign expected_note = score_note;
    assign expected_valid = active && !done && score_valid;
    // 进度按当前音符完整时长归一化；两拍音第一拍0..126，第二拍128..254。
    // 只做位拼接，不用运行时除法；done后显示255，末音步号保留以供完成画面。
    // toggle暂停保留进度；外部pause同样不影响当前提示状态。
    assign beat_progress = done ? 8'hff : (!score_valid ? 8'd0 :
                           (long_note ? {!score_onset,roll_tick[5:0],1'b0} :
                                        {roll_tick[5:0],2'b00}));
    assign target_beats = (!done && score_valid) ? (long_note ? 2'd2 : 2'd1) : 2'd0;
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
    // 下个提示按音符而非按拍查找，长音第一拍直接跨两拍，第二拍跨一拍。
    // 预备拍期间预告第一音，最后一音期间查询自然越界，不错误回绕到曲首。
    wire [5:0] next_beat_index = !score_valid ? 6'd2 :
        roll_tick[11:6] + ((long_note && score_onset) ? 6'd2 : 6'd1);
    wire [6:0] next_note;
    wire next_valid;
    piano_roll_score next_score (
        .song_id(roll_song),.beat_index(next_beat_index),.note(next_note),.valid(next_valid),
        .onset(),.step_index(),.total_steps(),.total_beats()
    );
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
                roll_song <= (song_id==1 || song_id==2) ? song_id : 2'd0;
                roll_tick<=0; fractional_phase<=0; active<=1; done<=0;
            end else if (ui_toggle) begin
                if (!done) active<=!active;
            end else if (active && !done && !pause && sample_tick) begin
                if (phase_carry) fractional_phase<=phase_sum-PHASE_LIMIT;
                else fractional_phase<=phase_sum[PHASE_WIDTH-1:0];
                beat_pulse <= next_tick[12:6] != {1'b0,roll_tick[11:6]};
                if (next_tick >= {1'b0,end_tick}) begin
                    roll_tick<=end_tick; fractional_phase<=0; active<=0; done<=1;
                end else roll_tick<=next_tick[11:0];
            end
        end
    end
endmodule
