// 三首固定练习曲的共享组合查谱器，源域时间轴和像素域渲染均可实例化。
// beat_index 是整首歌的绝对拍号：0/1 为两拍预备，2 才是第一个音符。
// note 为绝对 MIDI 音高；不采用鼓通道音符，也不把相邻同音合并为一个音。
// valid 表示本拍有旋律；onset 只标记音符第一拍，两拍音第二拍仍 valid。
// 渲染连续长条时须比较 step_index，不能只比较 note（相邻同音仍需分开）。
// total_beats 含预备拍但不含末尾额外空拍，固定为 50/38/38，小于64。
// 预备拍 step_index=0；结束/越界时固定到最后一步且 note/valid/onset=0。
// song_id=3 按小星星解释。全部输出均组合赋值，无寄存器、时钟或初始化ROM。
module piano_roll_score (
    input [1:0] song_id,
    input [5:0] beat_index,
    output reg [6:0] note,
    output reg valid,
    output reg onset,
    output reg [5:0] step_index,
    output reg [5:0] total_steps,
    output reg [5:0] total_beats
);
    reg [5:0] melody_beat;
    reg [3:0] slot;
    reg [5:0] base_step;
    always @* begin
        total_steps = (song_id == 1 || song_id == 2) ? 6'd32 : 6'd42;
        total_beats = (song_id == 1 || song_id == 2) ? 6'd38 : 6'd50;
        note = 0; valid = 0; onset = 0; step_index = 0;
        melody_beat = 0; slot = 0; base_step = 0;
        if (beat_index >= total_beats) begin
            step_index = total_steps - 6'd1;
        end else if (beat_index >= 2) begin
            melody_beat = beat_index - 6'd2;
            valid = 1; onset = 1;
            case (song_id)
                2'd1: begin
                    // 欢乐颂：四个9拍小节组，每组8音，末音两拍。
                    // 常数区间和减法替代运行时 /9 和 %9，避免推导除法网络。
                    if (melody_beat >= 27) begin
                        slot = melody_beat - 6'd27; base_step = 24;
                    end else if (melody_beat >= 18) begin
                        slot = melody_beat - 6'd18; base_step = 16;
                    end else if (melody_beat >= 9) begin
                        slot = melody_beat - 6'd9; base_step = 8;
                    end else slot = melody_beat[3:0];
                    step_index = base_step + ((slot == 8) ? 6'd7 : {2'b0,slot});
                    onset = (slot != 8);
                    // E E F G G F E D / C C D E E D D D /
                    // E E F G G F E D / C C D E D C C C。
                    case (step_index)
                        8,9,24,25,29,30,31: note = 60;
                        7,10,13,14,15,23,26,28: note = 62;
                        0,1,6,11,12,16,17,22,27: note = 64;
                        2,5,18,21: note = 65;
                        3,4,19,20: note = 67;
                        default: note = 0;
                    endcase
                end
                2'd2: begin
                    // 两只老虎：沿用历史32音编排，G4代替原曲低音G3。
                    // 第10/13/28/31步各两拍；其第二拍位于旋律拍11/15/31/35。
                    step_index = melody_beat - ((melody_beat >= 11) ? 6'd1 : 6'd0)
                                             - ((melody_beat >= 15) ? 6'd1 : 6'd0)
                                             - ((melody_beat >= 31) ? 6'd1 : 6'd0)
                                             - ((melody_beat >= 35) ? 6'd1 : 6'd0);
                    onset = melody_beat != 11 && melody_beat != 15 &&
                            melody_beat != 31 && melody_beat != 35;
                    case (step_index)
                        0,3,4,7,19,25,26,28,29,31: note = 60;
                        1,5: note = 62;
                        2,6,8,11,18,24: note = 64;
                        9,12,17,23: note = 65;
                        10,13,14,16,20,22,27,30: note = 67;
                        15,21: note = 69;
                        default: note = 0;
                    endcase
                end
                default: begin
                    // 小星星：六组8拍，每组7音，末音两拍。
                    // 拍号按位拆分后仅需常数移位/加减，不做逐音符线性扫描。
                    base_step = {melody_beat[5:3],3'b000} - {3'b000,melody_beat[5:3]};
                    slot = {1'b0,melody_beat[2:0]};
                    step_index = base_step + ((slot == 7) ? 6'd6 : {2'b0,slot});
                    onset = (slot != 7);
                    case (step_index)
                        0,1,13,28,29,41: note = 60;
                        11,12,20,27,39,40: note = 62;
                        9,10,18,19,25,26,37,38: note = 64;
                        7,8,16,17,23,24,35,36: note = 65;
                        2,3,6,14,15,21,22,30,31,34: note = 67;
                        4,5,32,33: note = 69;
                        default: note = 0;
                    endcase
                end
            endcase
        end
    end
endmodule
