// 职责：三首练习曲的跟弹提示，等待正确键并在干净松键后推进，不合成或控制PCM。
// clk=27MHz，rst_n 异步低有效；keys/ghost 为源域状态，sample_tick 为93750Hz使能。
// keys bit0..15为S1..S16，1为按下；cue/next/wrong_mask低12位对应旋律键S1..S12。
// step_index 为0起始曲目步号，total_steps 为42或32；beat_progress 为0..255显示进度，
// target_beats 为0/1/2拍。正确按键后松开即可推进，代码不要求进度先达到255。
// active/done 是持续状态；done 保持到重开，掩码随当前状态组合产生，无输出valid事件。
// BEAT_SAMPLES 默认46875个采样/拍（120BPM），非正值按1；正值及两倍拍长需在
// integer算术范围内。EXTERNAL_UI 默认0兼容只用原曲及键盘快捷键，非0接受UI命令。
// song_id 0/1/2为小星星/欢乐颂/两只老虎，其他ID在外部重开时归0；内部锁存曲目。
// ui_start/ui_restart/ui_toggle 为单clk事件；外部命令优先于pause，start/restart时读song_id。
// pause冻结跟弹寄存状态与计时；它不停止音频、telemetry或wave_scope的PCM采集。
// 当前顶层在测试所有权、非演奏页和菜单单键期间暂停跟弹；scope另有双缓冲握手。
// 复位active=1、done=0、step=0，须先无ghost且全松再接受第一步；每步精确匹配
// 整个keys向量，额外控制键/鬼键也会使匹配无效。内部状态见release_required/matched。
module song_guide #(
    parameter BEAT_SAMPLES = 46875,
    parameter EXTERNAL_UI = 0
) (
    input clk,
    input rst_n,
    input sample_tick,
    input pause, // 验证模式暂停跟弹，保持当前曲目序号/计时；不产生新时钟。
    input [15:0] keys,
    input ghost,
    output reg active,
    output reg done,
    output [11:0] cue_mask,
    output [11:0] next_mask,
    output [11:0] wrong_mask,
    output reg [5:0] step_index,
    output [5:0] total_steps,
    output [7:0] beat_progress,
    output [1:0] target_beats,
    // Appended ports keep existing named instances valid. UI commands are
    // synchronous one-clock pulses; song_id is stable when start/restart arrives.
    input [1:0] song_id,
    input ui_start,
    input ui_toggle,
    input ui_restart
);
    // 根据最大双拍拍长展开计数位宽，并保证至少1位，避免小参数产生零宽状态。
    function integer bits_required;
        input integer value;
        integer remaining;
        begin
            remaining = value;
            bits_required = 0;
            while (remaining > 0) begin
                bits_required = bits_required + 1;
                remaining = remaining >> 1;
            end
            if (bits_required == 0)
                bits_required = 1;
        end
    endfunction

    // 常数商/余数在展开时求值；每个采样累加余数进位，运行时不用拍长乘除器。
    // 拍长很短时商可一次增加多格，进度到255饱和；不是按clk线性跳过音符。
    localparam integer BEAT_LENGTH = (BEAT_SAMPLES < 1) ? 1 : BEAT_SAMPLES;
    localparam integer TWO_BEAT_LENGTH = BEAT_LENGTH << 1;
    localparam integer PHASE_WIDTH = bits_required(TWO_BEAT_LENGTH);
    localparam [8:0] ONE_INCREMENT = 255 / BEAT_LENGTH;
    localparam [8:0] TWO_INCREMENT = 255 / TWO_BEAT_LENGTH;
    localparam [PHASE_WIDTH:0] ONE_REMAINDER = 255 % BEAT_LENGTH;
    localparam [PHASE_WIDTH:0] TWO_REMAINDER = 255 % TWO_BEAT_LENGTH;
    localparam [PHASE_WIDTH:0] ONE_LENGTH = BEAT_LENGTH;
    localparam [PHASE_WIDTH:0] TWO_LENGTH = TWO_BEAT_LENGTH;

    // 函数返回键位掩码，不是频率/PCM；各曲是适配此键盘范围的固定练习编排。
    function [11:0] melody_mask;
        input [1:0] selected;
        input [5:0] index;
        begin
            case (selected)
            2'd1: begin
                // Ode to Joy, C-major 32-press practice arrangement:
                // E E F G G F E D / C C D E E D D D /
                // E E F G G F E D / C C D E D C C C.
                // Rearticulate the final D/C cadence to give 16 presses/section.
                case (index)
                    8, 9, 24, 25, 29, 30, 31: melody_mask = 12'h001;
                    7, 10, 13, 14, 15, 23, 26, 28: melody_mask = 12'h002;
                    0, 1, 6, 11, 12, 16, 17, 22, 27: melody_mask = 12'h004;
                    2, 5, 18, 21: melody_mask = 12'h008;
                    3, 4, 19, 20: melody_mask = 12'h010;
                    default: melody_mask = 12'h000;
                endcase
            end
            2'd2: begin
                // Frere Jacques / Liang Zhi Lao Hu, 32 presses:
                // C D E C C D E C / E F G E F G /
                // G A G F E C G A G F E C / C G C C G C.
                // The two final C G C phrases use G4 (S5), not the traditional
                // G3 below C4: an explicit adaptation to this keyboard's range.
                case (index)
                    0, 3, 4, 7, 19, 25, 26, 28, 29, 31: melody_mask = 12'h001;
                    1, 5: melody_mask = 12'h002;
                    2, 6, 8, 11, 18, 24: melody_mask = 12'h004;
                    9, 12, 17, 23: melody_mask = 12'h008;
                    10, 13, 14, 16, 20, 22, 27, 30: melody_mask = 12'h010;
                    15, 21: melody_mask = 12'h020;
                    default: melody_mask = 12'h000;
                endcase
            end
            default: begin
            // C C G G A A G / F F E E D D C /
            // G G F F E E D / G G F F E E D /
            // C C G G A A G / F F E E D D C.
            case (index)
                0, 1, 13, 28, 29, 41: melody_mask = 12'h001; // S1 C4
                11, 12, 20, 27, 39, 40: melody_mask = 12'h002; // S2 D4
                9, 10, 18, 19, 25, 26, 37, 38:
                    melody_mask = 12'h004; // S3 E4
                7, 8, 16, 17, 23, 24, 35, 36:
                    melody_mask = 12'h008; // S4 F4
                2, 3, 6, 14, 15, 21, 22, 30, 31, 34:
                    melody_mask = 12'h010; // S5 G4
                4, 5, 32, 33: melody_mask = 12'h020; // S6 A4
                default: melody_mask = 12'h000;
            endcase
            end
            endcase
        end
    endfunction

    // 指定句尾双拍只改变显示进度的计时尺度，不额外触发声音或要求强制按满两拍。
    function long_note;
        input [1:0] selected;
        input [5:0] index;
        begin
            case (selected)
                2'd1: long_note = (index == 7) || (index == 15) ||
                                 (index == 23) || (index == 31);
                // Simplified one/two-beat rhythm; hold each G and final C
                // phrase ending twice as long as the other practice notes.
                2'd2: long_note = (index == 10) || (index == 13) ||
                                 (index == 28) || (index == 31);
                default: long_note = (index == 6) || (index == 13) ||
                                     (index == 20) || (index == 27) ||
                                     (index == 34) || (index == 41);
            endcase
        end
    endfunction

    reg [1:0] selected_song;
    // EXTERNAL_UI=0时不使用追加UI输入，兼容旧命名实例；快捷键仍可跟弹/重开原曲。
    // EXTERNAL_UI=1才在外部重开时锁存曲目，但下方键盘快捷键也仍参与判断。
    wire [1:0] current_song = EXTERNAL_UI ? selected_song : 2'd0;
    wire external_restart = EXTERNAL_UI ? (ui_start || ui_restart) : 1'b0;
    wire external_toggle = EXTERNAL_UI ? ui_toggle : 1'b0;
    wire [5:0] last_step = (current_song == 2'd0) ? 6'd41 : 6'd31;
    wire [11:0] current_note = melody_mask(current_song, step_index);
    wire phrase_end = long_note(current_song, step_index);
    wire exact_note = !ghost && (keys == {4'b0000, current_note});
    wire clean_release = !ghost && (keys == 16'h0000);
    wire toggle_chord = !ghost && (keys == 16'h9000);
    wire restart_chord = !ghost && (keys == 16'h3000);

    reg toggle_armed;
    reg restart_armed;
    reg release_required;
    reg matched;
    reg [7:0] progress;
    reg [PHASE_WIDTH-1:0] phase;

    wire [PHASE_WIDTH:0] progress_length = phrase_end ? TWO_LENGTH : ONE_LENGTH;
    wire [PHASE_WIDTH:0] phase_sum = {1'b0, phase} +
                                   (phrase_end ? TWO_REMAINDER : ONE_REMAINDER);
    wire phase_carry = phase_sum >= progress_length;
    wire [8:0] progress_sum = {1'b0, progress} +
                             (phrase_end ? TWO_INCREMENT : ONE_INCREMENT) +
                             {8'b00000000, phase_carry};

    assign total_steps = (current_song == 2'd0) ? 6'd42 : 6'd32;
    assign cue_mask = (active && !done) ? current_note : 12'h000;
    assign next_mask = (active && !done && step_index < last_step) ?
                      melody_mask(current_song, step_index + 6'd1) : 12'h000;
    assign wrong_mask = (active && !done) ? (keys[11:0] & ~current_note) : 12'h000;
    assign beat_progress = progress;
    assign target_beats = (active && !done) ? (phrase_end ? 2'd2 : 2'd1) : 2'd0;

    // 重开/开关命令每clk处理；只有正确音符的进度累加使用 sample_tick。
    // 必须先看到全松再接受下一步，正确按住只置matched，后续干净释放才消费该匹配。
    // 非阻塞赋值让释放分支使用清零前的matched；错误/ghost打断后不能用旧匹配推进。
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            selected_song <= 2'd0;
            active <= 1'b1;
            done <= 1'b0;
            step_index <= 6'd0;
            toggle_armed <= 1'b1;
            restart_armed <= 1'b1;
            release_required <= 1'b1;
            matched <= 1'b0;
            progress <= 8'd0;
            phase <= {PHASE_WIDTH{1'b0}};
        end else if (external_restart) begin
            // Menu commands take priority over pause and the playing-page
            // chords. The top changes song_id before this command pulse.
            case (song_id)
                2'd1: selected_song <= 2'd1;
                2'd2: selected_song <= 2'd2;
                default: selected_song <= 2'd0;
            endcase
            active <= 1'b1;
            done <= 1'b0;
            step_index <= 6'd0;
            release_required <= 1'b1;
            matched <= 1'b0;
            progress <= 8'd0;
            phase <= {PHASE_WIDTH{1'b0}};
        end else if (external_toggle) begin
            if (!done)
                active <= !active;
            release_required <= 1'b1;
            matched <= 1'b0;
            progress <= 8'd0;
            phase <= {PHASE_WIDTH{1'b0}};
        end else if(!pause) begin
            // Both members must be up together to rearm their chord. Losing
            // only one member, ghosting, or adding a third key cannot rearm it.
            if (!ghost && (keys & 16'h9000) == 16'h0000)
                toggle_armed <= 1'b1;
            if (!ghost && (keys & 16'h3000) == 16'h0000)
                restart_armed <= 1'b1;

            if (restart_chord && restart_armed) begin
                restart_armed <= 1'b0;
                active <= 1'b1;
                done <= 1'b0;
                step_index <= 6'd0;
                release_required <= 1'b1;
                matched <= 1'b0;
                progress <= 8'd0;
                phase <= {PHASE_WIDTH{1'b0}};
            end else if (toggle_chord && toggle_armed) begin
                toggle_armed <= 1'b0;
                // Completion remains latched until the restart chord.
                if (!done)
                    active <= !active;
                release_required <= 1'b1;
                matched <= 1'b0;
                progress <= 8'd0;
                phase <= {PHASE_WIDTH{1'b0}};
            end else if (!active || done) begin
                release_required <= 1'b1;
                matched <= 1'b0;
                progress <= 8'd0;
                phase <= {PHASE_WIDTH{1'b0}};
            end else if (release_required) begin
                if (clean_release)
                    release_required <= 1'b0;
                matched <= 1'b0;
                progress <= 8'd0;
                phase <= {PHASE_WIDTH{1'b0}};
            end else if (exact_note) begin
                matched <= 1'b1;
                if (sample_tick && progress != 8'hff) begin
                    if (phase_carry)
                        phase <= phase_sum - progress_length;
                    else
                        phase <= phase_sum[PHASE_WIDTH-1:0];
                    if (progress_sum >= 9'd255)
                        progress <= 8'hff;
                    else
                        progress <= progress_sum[7:0];
                end
            end else begin
                // Invalid/ghosted chords cancel the pending match. A clean
                // correct press can be retried; only its later release advances.
                matched <= 1'b0;
                progress <= 8'd0;
                phase <= {PHASE_WIDTH{1'b0}};
                if (clean_release && matched) begin
                    if (step_index == last_step) begin
                        active <= 1'b0;
                        done <= 1'b1;
                        release_required <= 1'b1;
                    end else begin
                        step_index <= step_index + 6'd1;
                    end
                end
            end
        end
    end
endmodule
