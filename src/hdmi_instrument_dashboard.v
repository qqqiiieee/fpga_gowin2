// 纯显示渲染器：像素域输入是父层帧快照，本模块不控制音频、不处理触控。
// UI_ENABLE默认0保留旧单页，生产1四页；test_active优先显示32路验证页。
// x/y为10bit光栅坐标，de=0或越界输出黑；RGB各8bit。pixel_clk只用于同步字模及背景对齐。
// 固定布局640×480，普通图形/数码组合生成，中文8×16半字单元经字模ROM一拍输出。
// 页/游标/曲目均2bit；keys仅S1..S12，ui_controls为S13..S16，诊断页组合成完整16键。
// 位0对应逻辑S1；实体第二第三行的调整在CST，renderer和虚拟协议不重复换行。
// UI文本常量在hdmi_ui_text.vh，由assets/ui_texts.json生成，保留原288bit编码。
// 颜色/坐标/数字占位和优先级是显示契约；修改后须过独立布局/字体像素预期检查。
// 按键/包络busy/gate/超时均显示源域状态，屏幕32格亮起不等于32个模拟谱峰验证。
// wave_*与scope_gain只用于绘图，显示dBFS是数字PCM统计，不是声压计或模拟噪声测量。
// 诊断页S16脚注为演奏，与菜单控制器的短按/长按返回操作一致。

// 中文640x480界面，Verilog-2001。父模块负责相干状态与波形RAM。
// 本模块新增一拍同步字模读取；RGB与同步信号必须在父模块同步增加一拍。
// wave_current/previous must match floor((x-32)/2) for x=32..543.
module hdmi_instrument_dashboard #(parameter UI_ENABLE=0)(
    input [9:0] x, y,
    input de,
    input [11:0] keys,
    input [3:0] timbre,
    input [6:0] note,
    input note_valid,
    input [15:0] frequency_bcd,
    input [7:0] volume_percent,
    input signed [7:0] level_dbfs,
    input [7:0] peak_percent,
    input signed [8:0] pitch,
    input [5:0] voices,
    input [7:0] pressure0, pressure1,
    input [7:0] flags, // [7] overrun OR digital clipping; [6:0] per parent contract
    input guide_active, guide_done,
    input [11:0] cue_mask, next_mask, wrong_mask,
    input [5:0] guide_step, guide_total,
    input [7:0] beat_progress,
    input [1:0] target_beats,
    input signed [15:0] wave_current, wave_previous,
    input [3:0] scope_gain,
    input wave_valid,
    output reg [7:0] red, green, blue,
    // 新增测试状态共 78 位（1+6+32+32+1+5+1），已由 wrapper 按帧相干跨域。
    // active 是音频所有权（含交接过程），requested 是设定路数 0..32；
    // busy/gate 是 32 路实际活动/门控掩码，bit i 与网格索引 i 一一对应。
    // sweep/index 给出扫频模式/0..31 当前索引，overrun 给出测试调度错误。
    // voices 由父模块统计 busy，作为实际活动路数；本模块不从 requested 推测声音。
    input test_active,
    input [5:0] test_requested,
    input [31:0] test_busy, test_gate,
    input test_sweep,
    input [4:0] test_index,
    input test_overrun,
    input pixel_clk, input rst_n,
    input [1:0] ui_page,ui_cursor,ui_song,input [3:0] ui_controls
);
    localparam [23:0] BACKGROUND = 24'h0b101c;
    localparam [23:0] PANEL      = 24'h172338;
    localparam [23:0] BORDER     = 24'h34465f;
    localparam [23:0] GRID       = 24'h22324a;
    localparam [23:0] TEXT       = 24'he2e8f0;
    localparam [23:0] MUTED      = 24'h91a4be;
    localparam [23:0] CYAN       = 24'h51d6e8;
    localparam [23:0] GREEN      = 24'h21c6a8;
    localparam [23:0] AMBER      = 24'hf4bb4f;
    localparam [23:0] ALERT      = 24'hff5964;

    // 5x7 font adapted from the standalone HDMI foundation. One shared
    // character/row mux handles every label. Bit four is the leftmost pixel.
    function [4:0] font_row;
        input [7:0] character;
        input [2:0] row;
        reg [34:0] bitmap;
        begin
            case (character)
                "0": bitmap = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
                "1": bitmap = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "2": bitmap = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
                "3": bitmap = {5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
                "4": bitmap = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
                "5": bitmap = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
                "6": bitmap = {5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
                "7": bitmap = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
                "8": bitmap = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
                "9": bitmap = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
                "A": bitmap = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "B": bitmap = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
                "C": bitmap = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
                "D": bitmap = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
                "E": bitmap = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
                "F": bitmap = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
                "G": bitmap = {5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111};
                "H": bitmap = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
                "I": bitmap = {5'b01110,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
                "J": bitmap = {5'b00111,5'b00010,5'b00010,5'b00010,5'b00010,5'b10010,5'b01100};
                "K": bitmap = {5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
                "L": bitmap = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
                "M": bitmap = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
                "N": bitmap = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
                "O": bitmap = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "P": bitmap = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
                "Q": bitmap = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101};
                "R": bitmap = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
                "S": bitmap = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
                "T": bitmap = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
                "U": bitmap = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
                "V": bitmap = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
                "W": bitmap = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
                "X": bitmap = {5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
                "Y": bitmap = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
                "Z": bitmap = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111};
                "+": bitmap = {5'b00000,5'b00100,5'b00100,5'b11111,5'b00100,5'b00100,5'b00000};
                "-": bitmap = {5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
                "/": bitmap = {5'b00001,5'b00010,5'b00010,5'b00100,5'b01000,5'b01000,5'b10000};
                "%": bitmap = {5'b11001,5'b11010,5'b00010,5'b00100,5'b01000,5'b01011,5'b10011};
                "#": bitmap = {5'b01010,5'b11111,5'b01010,5'b01010,5'b11111,5'b01010,5'b00000};
                "^": bitmap = {5'b00100,5'b01010,5'b10001,5'b00000,5'b00000,5'b00000,5'b00000};
                default: bitmap = 35'd0;
            endcase
            case (row)
                0: font_row = bitmap[34:30];
                1: font_row = bitmap[29:25];
                2: font_row = bitmap[24:20];
                3: font_row = bitmap[19:15];
                4: font_row = bitmap[14:10];
                5: font_row = bitmap[9:5];
                6: font_row = bitmap[4:0];
                default: font_row = 5'd0;
            endcase
        end
    endfunction

    // 测试振荡器频率是配置值 f(i)=400+97*i Hz，不是 FFT 测量结果。
    // 直接查 32 项常量 BCD，避免逐像素乘法、除法和四位二进制转十进制。
    function [15:0] test_frequency_bcd;
        input [4:0] index;
        begin
            case (index)
                0: test_frequency_bcd=16'h0400;  1: test_frequency_bcd=16'h0497;
                2: test_frequency_bcd=16'h0594;  3: test_frequency_bcd=16'h0691;
                4: test_frequency_bcd=16'h0788;  5: test_frequency_bcd=16'h0885;
                6: test_frequency_bcd=16'h0982;  7: test_frequency_bcd=16'h1079;
                8: test_frequency_bcd=16'h1176;  9: test_frequency_bcd=16'h1273;
                10: test_frequency_bcd=16'h1370; 11: test_frequency_bcd=16'h1467;
                12: test_frequency_bcd=16'h1564; 13: test_frequency_bcd=16'h1661;
                14: test_frequency_bcd=16'h1758; 15: test_frequency_bcd=16'h1855;
                16: test_frequency_bcd=16'h1952; 17: test_frequency_bcd=16'h2049;
                18: test_frequency_bcd=16'h2146; 19: test_frequency_bcd=16'h2243;
                20: test_frequency_bcd=16'h2340; 21: test_frequency_bcd=16'h2437;
                22: test_frequency_bcd=16'h2534; 23: test_frequency_bcd=16'h2631;
                24: test_frequency_bcd=16'h2728; 25: test_frequency_bcd=16'h2825;
                26: test_frequency_bcd=16'h2922; 27: test_frequency_bcd=16'h3019;
                28: test_frequency_bcd=16'h3116; 29: test_frequency_bcd=16'h3213;
                30: test_frequency_bcd=16'h3310; 31: test_frequency_bcd=16'h3407;
                default: test_frequency_bcd=16'h0000;
            endcase
        end
    endfunction

    function [7:0] hex_ascii;
        input [3:0] digit;
        begin
            hex_ascii = digit < 10 ? (8'h30 + {4'd0,digit}) :
                                     (8'h41 + {4'd0,digit} - 8'd10);
        end
    endfunction

    // Fixed nine-round shift/add-3 converter, shared by the selected text.
    // The largest signed magnitude is 256. There is no division or modulo.
    function [11:0] decimal_bcd;
        input [8:0] value;
        reg [11:0] bcd;
        integer bit_index;
        begin
            bcd = 0;
            for (bit_index = 8; bit_index >= 0; bit_index = bit_index - 1) begin
                if (bcd[3:0] >= 5) bcd[3:0] = bcd[3:0] + 4'd3;
                if (bcd[7:4] >= 5) bcd[7:4] = bcd[7:4] + 4'd3;
                if (bcd[11:8] >= 5) bcd[11:8] = bcd[11:8] + 4'd3;
                bcd = {bcd[10:0],value[bit_index]};
            end
            decimal_bcd = bcd;
        end
    endfunction

    // MIDI 0..127 -> four printable characters, including octave -1.
    function [31:0] midi_name;
        input [6:0] value;
        reg [6:0] semitone;
        reg [7:0] octave, letter, sharp, tail;
        begin
            tail = " ";
            if      (value >= 120) begin semitone = value - 7'd120; octave = "9"; end
            else if (value >= 108) begin semitone = value - 7'd108; octave = "8"; end
            else if (value >= 96)  begin semitone = value - 7'd96;  octave = "7"; end
            else if (value >= 84)  begin semitone = value - 7'd84;  octave = "6"; end
            else if (value >= 72)  begin semitone = value - 7'd72;  octave = "5"; end
            else if (value >= 60)  begin semitone = value - 7'd60;  octave = "4"; end
            else if (value >= 48)  begin semitone = value - 7'd48;  octave = "3"; end
            else if (value >= 36)  begin semitone = value - 7'd36;  octave = "2"; end
            else if (value >= 24)  begin semitone = value - 7'd24;  octave = "1"; end
            else if (value >= 12)  begin semitone = value - 7'd12;  octave = "0"; end
            else begin semitone = value; octave = "-"; tail = "1"; end
            sharp = " ";
            case (semitone)
                0:  letter = "C";
                1:  begin letter = "C"; sharp = "#"; end
                2:  letter = "D";
                3:  begin letter = "D"; sharp = "#"; end
                4:  letter = "E";
                5:  letter = "F";
                6:  begin letter = "F"; sharp = "#"; end
                7:  letter = "G";
                8:  begin letter = "G"; sharp = "#"; end
                9:  letter = "A";
                10: begin letter = "A"; sharp = "#"; end
                default: letter = "B";
            endcase
            midi_name = {letter,sharp,octave,tail};
        end
    endfunction

    function [15:0] pad_name;
        input [3:0] index;
        begin
            case (index)
                0: pad_name = "C4";  1: pad_name = "D4";
                2: pad_name = "E4";  3: pad_name = "F4";
                4: pad_name = "G4";  5: pad_name = "A4";
                6: pad_name = "B4";  7: pad_name = "C5";
                8: pad_name = "D5";  9: pad_name = "E5";
                10: pad_name = "F5"; 11: pad_name = "G5";
                default: pad_name = "--";
            endcase
        end
    endfunction

    function [15:0] mask_name;
        input [11:0] mask;
        reg [3:0] first;
        begin
            if      (mask[0]) first = 0;
            else if (mask[1]) first = 1;
            else if (mask[2]) first = 2;
            else if (mask[3]) first = 3;
            else if (mask[4]) first = 4;
            else if (mask[5]) first = 5;
            else if (mask[6]) first = 6;
            else if (mask[7]) first = 7;
            else if (mask[8]) first = 8;
            else if (mask[9]) first = 9;
            else if (mask[10]) first = 10;
            else if (mask[11]) first = 11;
            else first = 15;
            mask_name = pad_name(first);
        end
    endfunction

    function [9:0] sample_y;
        input signed [15:0] sample;
        input [3:0] gain;
        reg signed [21:0] displacement;
        begin
            // Equivalent to (sample * 2^gain) >>> 9 without a multiplier.
            // Moving the right shift ahead of a possible left shift keeps
            // the barrel shifter at 22 bits, safe even at gain=15.
            displacement = {{6{sample[15]}},sample};
            if (gain <= 9) displacement = displacement >>> (4'd9-gain);
            else displacement = displacement <<< (gain-4'd9);
            if (displacement > 22'sd60) sample_y = 10'd152;
            else if (displacement < -22'sd60) sample_y = 10'd272;
            else sample_y = 10'd212 - displacement[9:0];
        end
    endfunction

    // 文本编码由 assets/ui_texts.json 生成，32 个 9-bit 半字字符单元。
    `include "src/hdmi_ui_text.vh"

    reg [23:0] pixel, ink, key_fill, progress_ink;
    reg [255:0] label_text;
    reg text_enable, small_text, key_note_text, guided, guide_wrong, guide_hold;
    reg [9:0] text_x, text_y, key_x, key_y, scope_x;
    reg [9:0] wave_y0, wave_y1, wave_top, wave_bottom;
    reg [3:0] key_index;
    reg [4:0] character_index, digit_start;
    reg [2:0] glyph_x, glyph_y, digit_count;
    reg [7:0] character;
    reg [8:0] number_value;
    reg [11:0] digits;
    reg [4:0] glyph;
    reg [15:0] key_name;
    reg [9:0] test_grid_x, test_grid_y;
    reg [4:0] test_cell_index, test_frequency_index;
    reg [15:0] test_frequency_digits;
    reg test_cell_text, test_frequency_text;

    function [287:0] timbre_label;
        input [3:0] value;
        begin
            case(value)
                0: timbre_label=TXT_000; // 00 正弦
                1: timbre_label=TXT_001; // 01 柔和长笛
                2: timbre_label=TXT_002; // 02 木管
                3: timbre_label=TXT_003; // 03 暖音风琴
                4: timbre_label=TXT_004; // 04 空心管
                5: timbre_label=TXT_005; // 05 柔和铜管
                6: timbre_label=TXT_006; // 06 木琴
                7: timbre_label=TXT_007; // 07 拨弦
                8: timbre_label=TXT_008; // 08 柔和弦乐
                9: timbre_label=TXT_009; // 09 簧片
                10: timbre_label=TXT_010; // 10 明亮风琴
                11: timbre_label=TXT_011; // 11 钟声
                12: timbre_label=TXT_012; // 12 口琴
                13: timbre_label=TXT_013; // 13 厚合成
                14: timbre_label=TXT_014; // 14 金属
                15: timbre_label=TXT_015; // 15 明亮合成
                default: timbre_label=TXT_016;
            endcase
        end
    endfunction

    // 曲库名称与song_guide的0/1/2索引严格对应，超范围回退小星星。
    function [287:0] song_label;
        input [1:0] id;
        begin case(id)
            1:song_label=TXT_017;
            2:song_label=TXT_018;
            default:song_label=TXT_019;
        endcase end
    endfunction
    // UI_ENABLE=0 保留旧组件测试接口；生产顶层显式启用四页界面。
    wire [15:0] diagnostic_keys={ui_controls,keys};
    reg [9:0] diagnostic_x,diagnostic_y;
    reg [3:0] diagnostic_index;
    reg [1:0] library_row;
    reg zh_enable;
    reg [9:0] zh_x,zh_y;
    reg [287:0] zh_label;
    reg [8:0] zh_character;
    reg [4:0] zh_index,zh_digit_start;
    reg [2:0] zh_digit_count,zh_kind;
    reg [31:0] selected_note;
    reg [15:0] current_pad,next_pad;
    reg [3:0] frequency_digit;
    reg [12:0] font_address;
    wire [7:0] font_row_bits;
    hdmi_ui_font u_font(pixel_clk,font_address,font_row_bits);
    reg [23:0] background_pipe,ink_pipe;
    reg [2:0] font_x_pipe;
    reg font_enable_pipe,visible_pipe;

    // 同步ROM只读一行字模。背景、墨色、像素横坐标与DE同拍保存，
    // 因而字体不会向右偏一像素，行末也不会把上行字模带到下一行。
    always @(posedge pixel_clk or negedge rst_n) begin
        if(!rst_n) begin
            background_pipe<=0; ink_pipe<=0; font_x_pipe<=0;
            font_enable_pipe<=0; visible_pipe<=0;
        end else begin
            background_pipe<=pixel; ink_pipe<=ink; font_x_pipe<=zh_x[2:0];
            font_enable_pipe<=zh_enable; visible_pipe<=de && x<640 && y<480;
        end
    end
    always @* begin
        {red,green,blue}=24'd0;
        if(visible_pipe) begin
            {red,green,blue}=background_pipe;
            if(font_enable_pipe && font_row_bits[3'd7-font_x_pipe])
                {red,green,blue}=ink_pipe;
        end
    end
    always @* begin
        diagnostic_x=x-10'd32;diagnostic_y=y-10'd160;diagnostic_index=0;library_row=0;
        zh_enable=0; zh_x=0; zh_y=0; zh_label=0; zh_character=32;
        zh_index=0; zh_digit_start=0; zh_digit_count=0; zh_kind=0;
        selected_note=midi_name(note); current_pad=mask_name(cue_mask); next_pad=mask_name(next_mask);
        font_address=0; frequency_digit=0;
        pixel = BACKGROUND;
        ink = TEXT;
        key_fill = PANEL;
        progress_ink = AMBER;
        label_text = 256'd0;
        text_enable = 0;
        small_text = 0;
        key_note_text = 0;
        guided = guide_active && !guide_done;
        guide_wrong = guided && (|(keys & (wrong_mask | ~cue_mask)));
        guide_hold = guided && !guide_wrong && (cue_mask != 0) &&
                     ((keys & cue_mask) == cue_mask);
        text_x = 0;
        text_y = 0;
        key_x = x - 10'd32;
        key_y = y - 10'd296;
        scope_x = x - 10'd32;
        key_index = 0;
        character_index = 0;
        digit_start = 0;
        digit_count = 0;
        glyph_x = 0;
        glyph_y = 0;
        character = " ";
        number_value = 0;
        digits = 0;
        glyph = 0;
        key_name = "--";
        test_grid_x = x - 10'd32;
        test_grid_y = y - 10'd296;
        test_cell_index = {test_grid_y[6:5],test_grid_x[8:6]};
        test_frequency_index = test_index;
        test_frequency_digits = 0;
        test_cell_text = 0;
        test_frequency_text = 0;
        wave_y0 = sample_y(wave_previous,scope_gain);
        wave_y1 = sample_y(wave_current,scope_gain);
        wave_top = wave_y0 < wave_y1 ? wave_y0 : wave_y1;
        wave_bottom = wave_y0 > wave_y1 ? wave_y0 : wave_y1;

        // Border is outside the specified sample rectangle, so both pixels
        // of samples 0 and 255 remain visible, including x=32 and x=543.
        if ((test_active || !UI_ENABLE || ui_page==0) && x >= 31 && x <= 544 && y >= 143 && y <= 280) begin
            pixel = BORDER;
            if (x >= 32 && x <= 543 && y >= 144 && y <= 279) begin
                pixel = PANEL;
                if (scope_x[5:0] == 0 || y == 176 || y == 248) pixel = GRID;
                if (y == 212) pixel = BORDER;
                if (wave_valid && y >= wave_top && y <= wave_bottom) pixel = CYAN;
            end
        end

        if (test_active) begin
            if (x >= 32 && x < 544 && y >= 296 && y < 424 &&
                test_grid_x[5:0] < 60 && test_grid_y[4:0] < 28) begin
                pixel = PANEL;
                if (test_grid_x[5:0] == 0 || test_grid_x[5:0] == 59 ||
                    test_grid_y[4:0] == 0 || test_grid_y[4:0] == 27)
                    pixel = test_sweep && test_cell_index == test_index ? CYAN : BORDER;
                if (test_grid_x[5:0] >= 4 && test_grid_x[5:0] < 52) begin
                    text_x = {4'd0,test_grid_x[5:0]} - 10'd4;
                    small_text = 1;
                    if (test_grid_y[4:0] >= 3 && test_grid_y[4:0] < 10) begin
                        label_text = "00 G A                          ";
                        text_y = {5'd0,test_grid_y[4:0]} - 10'd3;
                        text_enable = 1; test_cell_text = 1;
                        number_value = {4'd0,test_cell_index}; digit_start = 0; digit_count = 2;
                    end else if (test_grid_y[4:0] >= 16 && test_grid_y[4:0] < 23) begin
                        label_text = "0000HZ                          ";
                        text_y = {5'd0,test_grid_y[4:0]} - 10'd16;
                        text_enable = 1; test_frequency_text = 1;
                        test_frequency_index = test_cell_index;
                        ink = MUTED;
                    end
                end
            end
        end else begin
        if ((!UI_ENABLE || ui_page==0) && x >= 32 && x < 288 && y >= 296 && y < 432) begin
            if (y >= 392) begin key_y = y - 10'd392; key_index = 8; end
            else if (y >= 344) begin key_y = y - 10'd344; key_index = 4; end
            key_index = key_index + {2'd0,key_x[7:6]};
            key_name = pad_name(key_index);
            if (key_x[5:0] < 56 && key_y < 40) begin
                if (guided && cue_mask[key_index]) key_fill = AMBER;
                if (keys[key_index]) begin
                    if (!guided) key_fill = CYAN;
                    else if (wrong_mask[key_index] || !cue_mask[key_index]) key_fill = ALERT;
                    else key_fill = GREEN;
                end
                pixel = key_fill;
                if (key_x[5:0] == 0 || key_x[5:0] == 55 || key_y == 0 || key_y == 39)
                    pixel = (guided && (cue_mask[key_index] || next_mask[key_index])) ? AMBER : BORDER;
                // Amber triangle = following note, independent of hit color.
                if (guided && next_mask[key_index] && key_y >= 3 && key_y <= 9 &&
                    key_x[5:0] >= 45 && key_x[5:0] <= (6'd45 + key_y[5:0] - 6'd3))
                    pixel = AMBER;
                ink = key_fill == PANEL ? MUTED : BACKGROUND;
                if (key_x[5:0] >= 8 && key_x[5:0] < 32 && key_y >= 5 && key_y < 12) begin
                    label_text = "S00                             ";
                    text_x = {4'd0,key_x[5:0]} - 10'd8;
                    text_y = key_y - 10'd5;
                    text_enable = 1;
                    small_text = 1;
                    number_value = {5'd0,key_index} + 9'd1;
                    digit_start = 1;
                    digit_count = 2;
                end else if (key_x[5:0] >= 8 && key_x[5:0] < 40 && key_y >= 20 && key_y < 34) begin
                    text_x = {4'd0,key_x[5:0]} - 10'd8;
                    text_y = key_y - 10'd20;
                    text_enable = 1;
                    key_note_text = 1;
                end
            end
        end

        if ((!UI_ENABLE || ui_page==0) && x >= 304 && x <= 560 && y >= 374 && y <= 389) begin
            pixel = PANEL;
            if (guide_done) progress_ink = GREEN;
            else if (guide_wrong) progress_ink = ALERT;
            else if (guide_hold) progress_ink = GREEN;
            if (guide_done || (guided && (x - 10'd305) < {2'd0,beat_progress}))
                pixel = progress_ink;
            if (x == 304 || x == 560 || y == 374 || y == 389) pixel = BORDER;
        end

        end
        // 曲库选择框；诊断页显示包括四个控制键在内的完整实体逻辑矩阵。
        if(UI_ENABLE && !test_active && ui_page==1 && x>=32 && x<=607 && y>=96 && y<312) begin
            if(y>=256)begin library_row=2;diagnostic_y=y-256;end
            else if(y>=176)begin library_row=1;diagnostic_y=y-176;end
            else begin library_row=0;diagnostic_y=y-96;end
            if(diagnostic_y<56) begin
                pixel=PANEL;
                if(x==32 || x==607 || diagnostic_y==0 || diagnostic_y==55)
                    pixel=ui_cursor==library_row ? AMBER : BORDER;
                if(x>32 && x<36 && diagnostic_y>0 && diagnostic_y<55 && ui_song==library_row)pixel=GREEN;
            end
        end
        if(UI_ENABLE && !test_active && ui_page==3 && x>=32 && x<288 && y>=160 && y<352) begin
            if(y>=304)begin diagnostic_index=12;diagnostic_y=y-304;end
            else if(y>=256)begin diagnostic_index=8;diagnostic_y=y-256;end
            else if(y>=208)begin diagnostic_index=4;diagnostic_y=y-208;end
            diagnostic_index=diagnostic_index+{2'd0,diagnostic_x[7:6]};
            if(diagnostic_x[5:0]<56 && diagnostic_y<40) begin
                pixel=diagnostic_keys[diagnostic_index] ? CYAN : PANEL;
                if(diagnostic_x[5:0]==0 || diagnostic_x[5:0]==55 || diagnostic_y==0 || diagnostic_y==39)pixel=BORDER;
                if(diagnostic_x[5:0]>=4 && diagnostic_x[5:0]<52 && diagnostic_y>=12 && diagnostic_y<26)begin
                    label_text="S00                             ";text_enable=1;small_text=0;
                    text_x={4'd0,diagnostic_x[5:0]}-4;text_y=diagnostic_y-12;
                    number_value={5'd0,diagnostic_index}+9'd1;digit_start=1;digit_count=2;
                    ink=diagnostic_keys[diagnostic_index] ? BACKGROUND : MUTED;
                end
            end
        end
        if (text_enable) begin
            if (small_text) begin
                character_index = text_x[7:3]; glyph_x = text_x[2:0]; glyph_y = text_y[2:0];
            end else begin
                character_index = text_x[8:4]; glyph_x = text_x[3:1]; glyph_y = text_y[3:1];
            end
            // Labels are limited to 32 cells; guard against index wrapping.
            if ((small_text && text_x < 256) || (!small_text && text_x < 512)) begin
                character = label_text >> {(5'd31-character_index),3'b000};
                digits = decimal_bcd(number_value);
                if (digit_count != 0 && character_index >= digit_start &&
                    character_index < (digit_start + digit_count)) begin
                    if (digit_count == 3 && character_index == digit_start) character = hex_ascii(digits[11:8]);
                    else if (digit_count >= 2 && character_index == (digit_start + digit_count - 1'b1 - 1'b1))
                        character = hex_ascii(digits[7:4]);
                    else character = hex_ascii(digits[3:0]);
                end
                if (key_note_text) character = character_index == 0 ? key_name[15:8] : key_name[7:0];
                // 测试页仍走同一个字模 mux；每卡两行仅覆盖索引/频率和 G/A 的墨色。
                // G=gate（琥珀），A=busy（绿色）；释放时 G 熄而 A 可继续亮。
                if (test_cell_text) begin
                    if (character_index == 3) ink = test_gate[test_cell_index] ? AMBER : MUTED;
                    else if (character_index == 5) ink = test_busy[test_cell_index] ? GREEN : MUTED;
                end
                if (test_frequency_text) begin
                    // 网格频率与 SET 字段先选 5 位索引，再共用唯一一次频率表查找。
                    test_frequency_digits = test_frequency_bcd(test_frequency_index);
                    if (character_index == 5'd0) character = hex_ascii(test_frequency_digits[15:12]);
                    else if (character_index == 5'd1) character = hex_ascii(test_frequency_digits[11:8]);
                    else if (character_index == 5'd2) character = hex_ascii(test_frequency_digits[7:4]);
                    else if (character_index == 5'd3) character = hex_ascii(test_frequency_digits[3:0]);
                end
                glyph = font_row(character,glyph_y);
                if (glyph_x < 5 && glyph_y < 7 && glyph[3'd4-glyph_x]) pixel = ink;
            end
        end

        if(UI_ENABLE && !test_active && ui_page!=0) begin
            // 明确页优先级；验证所有权总是覆盖普通菜单。
            if(ui_page==1) begin
            if(x>=32 && x<288 && y>=16 && y<32) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd16;zh_label=TXT_020;ink=CYAN;
            end
            else if(x>=368 && x<624 && y>=16 && y<32) begin
                zh_enable=1;zh_x=x-10'd368;zh_y=y-10'd16;zh_label=TXT_021;ink=AMBER;
            end
            else if(x>=56 && x<312 && y>=112 && y<128) begin
                zh_enable=1;zh_x=x-10'd56;zh_y=y-10'd112;zh_label=TXT_022;ink=ui_cursor==0 ? AMBER : TEXT;
            end
            else if(x>=384 && x<608 && y>=112 && y<128) begin
                zh_enable=1;zh_x=x-10'd384;zh_y=y-10'd112;zh_label=TXT_023;ink=MUTED;
            end
            else if(x>=56 && x<312 && y>=192 && y<208) begin
                zh_enable=1;zh_x=x-10'd56;zh_y=y-10'd192;zh_label=TXT_024;ink=ui_cursor==1 ? AMBER : TEXT;
            end
            else if(x>=384 && x<608 && y>=192 && y<208) begin
                zh_enable=1;zh_x=x-10'd384;zh_y=y-10'd192;zh_label=TXT_025;ink=MUTED;
            end
            else if(x>=56 && x<312 && y>=272 && y<288) begin
                zh_enable=1;zh_x=x-10'd56;zh_y=y-10'd272;zh_label=TXT_026;ink=ui_cursor==2 ? AMBER : TEXT;
            end
            else if(x>=384 && x<608 && y>=272 && y<288) begin
                zh_enable=1;zh_x=x-10'd384;zh_y=y-10'd272;zh_label=TXT_025;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=352 && y<368) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd352;zh_label=TXT_027;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=376 && y<392) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd376;zh_label=TXT_028;ink=AMBER;
            end
            else if(x>=320 && x<576 && y>=352 && y<368) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd352;zh_label=TXT_029;ink=TEXT;
            end
            else if(x>=320 && x<576 && y>=376 && y<392) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd376;zh_label=song_label(ui_song);ink=GREEN;
            end
            else if(x>=32 && x<288 && y>=424 && y<440) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd424;zh_label=TXT_030;ink=MUTED;
            end
            else if(x>=320 && x<576 && y>=424 && y<440) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd424;zh_label=TXT_031;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=464 && y<480) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd464;zh_label=TXT_032;ink=MUTED;
            end
            end else if(ui_page==2) begin
            if(x>=32 && x<288 && y>=16 && y<32) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd16;zh_label=TXT_033;ink=CYAN;
            end
            else if(x>=368 && x<624 && y>=16 && y<32) begin
                zh_enable=1;zh_x=x-10'd368;zh_y=y-10'd16;zh_label=TXT_034;ink=AMBER;
                number_value={7'd0,ui_cursor}+9'd1;zh_digit_start=0;zh_digit_count=2;
            end
            else begin
                if(ui_cursor==0) begin
                if(x>=32 && x<288 && y>=80 && y<96) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd80;zh_label=TXT_035;ink=CYAN;
            end
            else if(x>=32 && x<288 && y>=112 && y<128) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd112;zh_label=TXT_036;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=144 && y<160) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd144;zh_label=TXT_037;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=176 && y<192) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd176;zh_label=TXT_038;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=208 && y<224) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd208;zh_label=TXT_039;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=240 && y<256) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd240;zh_label=TXT_040;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=272 && y<288) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd272;zh_label=TXT_041;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=304 && y<320) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd304;zh_label=TXT_042;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=336 && y<352) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd336;zh_label=TXT_043;ink=MUTED;
            end
                end else if(ui_cursor==1) begin
                if(x>=32 && x<288 && y>=80 && y<96) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd80;zh_label=TXT_044;ink=CYAN;
            end
            else if(x>=32 && x<288 && y>=112 && y<128) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd112;zh_label=TXT_045;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=144 && y<160) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd144;zh_label=TXT_046;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=176 && y<192) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd176;zh_label=TXT_047;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=208 && y<224) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd208;zh_label=TXT_048;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=240 && y<256) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd240;zh_label=TXT_049;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=272 && y<288) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd272;zh_label=TXT_050;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=304 && y<320) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd304;zh_label=TXT_051;ink=AMBER;
            end
            else if(x>=32 && x<288 && y>=336 && y<352) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd336;zh_label=TXT_052;ink=MUTED;
            end
                end else begin
                if(x>=32 && x<288 && y>=80 && y<96) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd80;zh_label=TXT_053;ink=CYAN;
            end
            else if(x>=32 && x<288 && y>=112 && y<128) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd112;zh_label=TXT_054;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=144 && y<160) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd144;zh_label=TXT_055;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=176 && y<192) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd176;zh_label=TXT_056;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=208 && y<224) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd208;zh_label=TXT_057;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=240 && y<256) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd240;zh_label=TXT_058;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=272 && y<288) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd272;zh_label=TXT_059;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=304 && y<320) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd304;zh_label=TXT_060;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=336 && y<352) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd336;zh_label=TXT_061;ink=MUTED;
            end
                end
                if(x>=32 && x<288 && y>=400 && y<416) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd400;zh_label=TXT_062;ink=TEXT;
                zh_kind=5;
            end
            else if(x>=320 && x<576 && y>=400 && y<416) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd400;zh_label=TXT_063;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=448 && y<464) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd448;zh_label=TXT_027;ink=TEXT;
            end
            else if(x>=320 && x<576 && y>=448 && y<464) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd448;zh_label=TXT_029;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=464 && y<480) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd464;zh_label=TXT_064;ink=MUTED;
            end
            end
            end else begin
            if(x>=32 && x<288 && y>=16 && y<32) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd16;zh_label=TXT_065;ink=CYAN;
            end
            else if(x>=368 && x<624 && y>=16 && y<32) begin
                zh_enable=1;zh_x=x-10'd368;zh_y=y-10'd16;zh_label=TXT_066;ink=AMBER;
            end
            else if(x>=32 && x<288 && y>=64 && y<80) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd64;zh_label=TXT_062;ink=TEXT;
                zh_kind=5;
            end
            else if(x>=320 && x<576 && y>=64 && y<80) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd64;zh_label=TXT_067;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=96 && y<112) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd96;zh_label=TXT_068;ink=MUTED;
            end
            else if(x>=320 && x<576 && y>=96 && y<112) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd96;zh_label=TXT_069;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=128 && y<144) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd128;zh_label=TXT_070;ink=MUTED;
            end
            else if(x>=320 && x<576 && y>=160 && y<176) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd160;zh_label=TXT_071;ink=TEXT;
                number_value={1'b0,volume_percent};zh_digit_start=5;zh_digit_count=3;
            end
            else if(x>=320 && x<576 && y>=192 && y<208) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd192;zh_label=pitch[8] ? TXT_072 : TXT_073;ink=TEXT;
                number_value=pitch[8] ? (~pitch+9'd1) : pitch;zh_digit_start=6;zh_digit_count=3;
            end
            else if(x>=320 && x<576 && y>=224 && y<240) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd224;zh_label=TXT_074;ink=TEXT;
                number_value={1'b0,pressure0};zh_digit_start=4;zh_digit_count=3;
            end
            else if(x>=320 && x<576 && y>=256 && y<272) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd256;zh_label=TXT_075;ink=TEXT;
                number_value={1'b0,pressure1};zh_digit_start=4;zh_digit_count=3;
            end
            else if(x>=320 && x<576 && y>=288 && y<304) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd288;zh_label=flags[3] || flags[4] ? TXT_076 : TXT_077;ink=flags[3] || flags[4] ? ALERT : GREEN;
            end
            else if(x>=320 && x<576 && y>=320 && y<336) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd320;zh_label=flags[1] ? TXT_078 : TXT_079;ink=flags[1] ? AMBER : CYAN;
            end
            else if(x>=32 && x<288 && y>=384 && y<400) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd384;zh_label=TXT_080;ink=AMBER;
            end
            else if(x>=320 && x<576 && y>=384 && y<400) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd384;zh_label=TXT_081;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=416 && y<432) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd416;zh_label=TXT_082;ink=MUTED;
            end
            else if(x>=320 && x<576 && y>=416 && y<432) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd416;zh_label=TXT_083;ink=MUTED;
            end
            else if(x>=32 && x<288 && y>=448 && y<464) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd448;zh_label=TXT_029;ink=TEXT;
            end
            else if(x>=320 && x<576 && y>=448 && y<464) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd448;zh_label=TXT_DIAG_EXIT;ink=TEXT;
            end
            else if(x>=32 && x<288 && y>=464 && y<480) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd464;zh_label=TXT_084;ink=MUTED;
            end
            end
        end else if(test_active) begin
            if (x >= 32 && x < 288 && y >= 16 && y < 32) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd16;
                zh_label=TXT_044; ink=CYAN;
            end
            else if (x >= 368 && x < 624 && y >= 16 && y < 32) begin
                zh_enable=1; zh_x=x-10'd368; zh_y=y-10'd16;
                zh_label=TXT_085; ink=AMBER;
            end
            else if (x >= 32 && x < 240 && y >= 40 && y < 56) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd40;
                zh_label=TXT_086; ink=TEXT;
                number_value={3'd0,test_requested}; zh_digit_start=5; zh_digit_count=2;
            end
            else if (x >= 256 && x < 432 && y >= 40 && y < 56) begin
                zh_enable=1; zh_x=x-10'd256; zh_y=y-10'd40;
                zh_label=TXT_087; ink=GREEN;
                number_value={3'd0,voices}; zh_digit_start=5; zh_digit_count=2;
            end
            else if (x >= 448 && x < 632 && y >= 40 && y < 56) begin
                zh_enable=1; zh_x=x-10'd448; zh_y=y-10'd40;
                zh_label=test_sweep ? TXT_088 : TXT_089; ink=test_sweep ? CYAN : MUTED;
            end
            else if (x >= 32 && x < 240 && y >= 64 && y < 80) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd64;
                zh_label=level_dbfs[7] ? TXT_090 : TXT_091; ink=TEXT;
                number_value=level_dbfs[7] ? {1'b0,(~level_dbfs+8'd1)} : {1'b0,level_dbfs}; zh_digit_start=5; zh_digit_count=3;
            end
            else if (x >= 256 && x < 432 && y >= 64 && y < 80) begin
                zh_enable=1; zh_x=x-10'd256; zh_y=y-10'd64;
                zh_label=TXT_092; ink=TEXT;
                number_value={1'b0,peak_percent}; zh_digit_start=5; zh_digit_count=3;
            end
            else if (x >= 448 && x < 632 && y >= 64 && y < 80) begin
                zh_enable=1; zh_x=x-10'd448; zh_y=y-10'd64;
                zh_label=TXT_093; ink=TEXT;
            end
            else if (x >= 32 && x < 288 && y >= 88 && y < 104) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd88;
                zh_label=TXT_050; ink=MUTED;
            end
            else if (x >= 320 && x < 576 && y >= 88 && y < 104) begin
                zh_enable=1; zh_x=x-10'd320; zh_y=y-10'd88;
                zh_label=TXT_094; ink=TEXT;
            end
            else if (x >= 32 && x < 208 && y >= 112 && y < 128) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd112;
                zh_label=TXT_095; ink=test_sweep ? CYAN : MUTED;
                number_value={4'd0,test_index}; zh_digit_start=5; zh_digit_count=2;
            end
            else if (x >= 224 && x < 432 && y >= 112 && y < 128) begin
                zh_enable=1; zh_x=x-10'd224; zh_y=y-10'd112;
                zh_label=TXT_096; ink=MUTED;
                zh_kind=4;
            end
            else if (x >= 448 && x < 632 && y >= 112 && y < 128) begin
                zh_enable=1; zh_x=x-10'd448; zh_y=y-10'd112;
                zh_label=test_overrun ? TXT_097 : TXT_098; ink=test_overrun ? ALERT : GREEN;
            end
            else if (x >= 32 && x < 288 && y >= 128 && y < 144) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd128;
                zh_label=TXT_099; ink=CYAN;
                number_value={5'd0,scope_gain}; zh_digit_start=11; zh_digit_count=2;
            end
            else if (x >= 552 && x < 632 && y >= 128 && y < 144) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd128;
                zh_label=TXT_100; ink=MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 144 && y < 160) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd144;
                zh_label=TXT_101; ink=test_overrun ? ALERT : MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 160 && y < 176) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd160;
                zh_label=TXT_102; ink=(test_overrun || flags[7] || flags[3]) ? ALERT : MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 176 && y < 192) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd176;
                zh_label=TXT_103; ink=flags[7] ? ALERT : MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 192 && y < 208) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd192;
                zh_label=TXT_104; ink=flags[3] ? ALERT : MUTED;
            end
            else if (!wave_valid && x >= 256 && x < 336 && y >= 204 && y < 220) begin
                zh_enable=1; zh_x=x-10'd256; zh_y=y-10'd204;
                zh_label=TXT_105; ink=AMBER;
            end
            else if (x >= 32 && x < 288 && y >= 280 && y < 296) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd280;
                zh_label=TXT_106; ink=MUTED;
            end
            else if (x >= 32 && x < 288 && y >= 432 && y < 448) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd432;
                zh_label=TXT_107; ink=TEXT;
            end
            else if (x >= 320 && x < 576 && y >= 432 && y < 448) begin
                zh_enable=1; zh_x=x-10'd320; zh_y=y-10'd432;
                zh_label=TXT_108; ink=MUTED;
            end
            else if (x >= 32 && x < 288 && y >= 448 && y < 464) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd448;
                zh_label=TXT_050; ink=MUTED;
            end
            else if (x >= 320 && x < 576 && y >= 448 && y < 464) begin
                zh_enable=1; zh_x=x-10'd320; zh_y=y-10'd448;
                zh_label=TXT_051; ink=AMBER;
            end
            else if (x >= 32 && x < 288 && y >= 464 && y < 480) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd464;
                zh_label=TXT_109; ink=MUTED;
            end
            else if (x >= 320 && x < 576 && y >= 464 && y < 480) begin
                zh_enable=1; zh_x=x-10'd320; zh_y=y-10'd464;
                zh_label=TXT_110; ink=MUTED;
            end
        end else begin
            if (x >= 32 && x < 288 && y >= 16 && y < 32) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd16;
                zh_label=TXT_111; ink=CYAN;
            end
            else if (x >= 368 && x < 624 && y >= 16 && y < 32) begin
                zh_enable=1; zh_x=x-10'd368; zh_y=y-10'd16;
                zh_label=guide_done ? TXT_112 : (guided ? (UI_ENABLE ? song_label(ui_song) : TXT_019) : TXT_035); ink=guide_done ? GREEN : (guided ? AMBER : CYAN);
            end
            else if (x >= 32 && x < 288 && y >= 40 && y < 56) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd40;
                zh_label=timbre_label(timbre); ink=TEXT;
                number_value={5'd0,timbre}; zh_digit_start=5; zh_digit_count=2;
            end
            else if (x >= 304 && x < 560 && y >= 40 && y < 56) begin
                zh_enable=1; zh_x=x-10'd304; zh_y=y-10'd40;
                zh_label=TXT_113; ink=TEXT;
                zh_kind=1;
            end
            else if (x >= 32 && x < 208 && y >= 64 && y < 80) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd64;
                zh_label=TXT_071; ink=TEXT;
                number_value={1'b0,volume_percent}; zh_digit_start=5; zh_digit_count=3;
            end
            else if (x >= 224 && x < 432 && y >= 64 && y < 80) begin
                zh_enable=1; zh_x=x-10'd224; zh_y=y-10'd64;
                zh_label=level_dbfs[7] ? TXT_090 : TXT_091; ink=TEXT;
                number_value=level_dbfs[7] ? {1'b0,(~level_dbfs+8'd1)} : {1'b0,level_dbfs}; zh_digit_start=5; zh_digit_count=3;
            end
            else if (x >= 448 && x < 632 && y >= 64 && y < 80) begin
                zh_enable=1; zh_x=x-10'd448; zh_y=y-10'd64;
                zh_label=TXT_092; ink=TEXT;
                number_value={1'b0,peak_percent}; zh_digit_start=5; zh_digit_count=3;
            end
            else if (x >= 32 && x < 144 && y >= 88 && y < 104) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd88;
                zh_label=TXT_114; ink=TEXT;
                number_value={3'd0,voices}; zh_digit_start=5; zh_digit_count=2;
            end
            else if (x >= 160 && x < 272 && y >= 88 && y < 104) begin
                zh_enable=1; zh_x=x-10'd160; zh_y=y-10'd88;
                zh_label=TXT_074; ink=TEXT;
                number_value={1'b0,pressure0}; zh_digit_start=4; zh_digit_count=3;
            end
            else if (x >= 288 && x < 400 && y >= 88 && y < 104) begin
                zh_enable=1; zh_x=x-10'd288; zh_y=y-10'd88;
                zh_label=TXT_075; ink=TEXT;
                number_value={1'b0,pressure1}; zh_digit_start=4; zh_digit_count=3;
            end
            else if (x >= 432 && x < 624 && y >= 88 && y < 104) begin
                zh_enable=1; zh_x=x-10'd432; zh_y=y-10'd88;
                zh_label=pitch[8] ? TXT_072 : TXT_073; ink=TEXT;
                number_value=pitch[8] ? (~pitch+9'd1) : pitch; zh_digit_start=6; zh_digit_count=3;
            end
            else if (x >= 32 && x < 288 && y >= 112 && y < 128) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd112;
                zh_label=TXT_115; ink=MUTED;
            end
            else if (x >= 448 && x < 632 && y >= 112 && y < 128) begin
                zh_enable=1; zh_x=x-10'd448; zh_y=y-10'd112;
                zh_label=TXT_094; ink=MUTED;
            end
            else if (x >= 32 && x < 288 && y >= 128 && y < 144) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd128;
                zh_label=TXT_099; ink=CYAN;
                number_value={5'd0,scope_gain}; zh_digit_start=11; zh_digit_count=2;
            end
            else if (x >= 552 && x < 632 && y >= 128 && y < 144) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd128;
                zh_label=TXT_100; ink=MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 144 && y < 160) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd144;
                zh_label=TXT_103; ink=flags[7] ? ALERT : MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 160 && y < 176) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd160;
                zh_label=TXT_116; ink=flags[6] ? AMBER : MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 176 && y < 192) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd176;
                zh_label=TXT_117; ink=flags[5] ? GREEN : MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 192 && y < 208) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd192;
                zh_label=TXT_118; ink=flags[4] ? AMBER : MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 208 && y < 224) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd208;
                zh_label=TXT_104; ink=flags[3] ? ALERT : MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 224 && y < 240) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd224;
                zh_label=TXT_119; ink=flags[2] ? CYAN : MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 240 && y < 256) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd240;
                zh_label=TXT_078; ink=flags[1] ? CYAN : MUTED;
            end
            else if (x >= 552 && x < 632 && y >= 256 && y < 272) begin
                zh_enable=1; zh_x=x-10'd552; zh_y=y-10'd256;
                zh_label=TXT_120; ink=flags[0] ? AMBER : MUTED;
            end
            else if (!wave_valid && x >= 256 && x < 336 && y >= 204 && y < 220) begin
                zh_enable=1; zh_x=x-10'd256; zh_y=y-10'd204;
                zh_label=TXT_105; ink=AMBER;
            end
            else if (x >= 32 && x < 288 && y >= 280 && y < 296) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd280;
                zh_label=TXT_121; ink=MUTED;
            end
            else if (x >= 304 && x < 560 && y >= 296 && y < 312) begin
                zh_enable=1; zh_x=x-10'd304; zh_y=y-10'd296;
                zh_label=UI_ENABLE ? song_label(ui_song) : TXT_019; ink=AMBER;
            end
            else if (x >= 304 && x < 560 && y >= 320 && y < 336) begin
                zh_enable=1; zh_x=x-10'd304; zh_y=y-10'd320;
                zh_label=TXT_122; ink=TEXT;
                zh_kind=2;
            end
            else if (x >= 304 && x < 416 && y >= 344 && y < 360) begin
                zh_enable=1; zh_x=x-10'd304; zh_y=y-10'd344;
                zh_label=TXT_123; ink=TEXT;
                number_value={7'd0,target_beats}; zh_digit_start=5; zh_digit_count=1;
            end
            else if (x >= 432 && x < 624 && y >= 344 && y < 360) begin
                zh_enable=1; zh_x=x-10'd432; zh_y=y-10'd344;
                zh_label=guide_done ? TXT_124 : (!guided ? TXT_035 : (guide_wrong ? TXT_125 : (guide_hold ? TXT_126 : TXT_105))); ink=guide_done ? GREEN : (!guided ? CYAN : (guide_wrong ? ALERT : (guide_hold ? GREEN : AMBER)));
            end
            else if (x >= 304 && x < 560 && y >= 400 && y < 416) begin
                zh_enable=1; zh_x=x-10'd304; zh_y=y-10'd400;
                zh_label=TXT_127; ink=TEXT;
                zh_kind=3;
            end
            else if (x >= 304 && x < 560 && y >= 416 && y < 432) begin
                zh_enable=1; zh_x=x-10'd304; zh_y=y-10'd416;
                zh_label=TXT_128; ink=MUTED;
            end
            else if (x >= 304 && x < 560 && y >= 432 && y < 448) begin
                zh_enable=1; zh_x=x-10'd304; zh_y=y-10'd432;
                zh_label=TXT_129; ink=MUTED;
            end
            else if (x >= 32 && x < 288 && y >= 448 && y < 464) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd448;
                zh_label=TXT_040; ink=TEXT;
            end
            else if (x >= 320 && x < 576 && y >= 448 && y < 464) begin
                zh_enable=1; zh_x=x-10'd320; zh_y=y-10'd448;
                zh_label=TXT_041; ink=TEXT;
            end
            else if (x >= 32 && x < 288 && y >= 464 && y < 480) begin
                zh_enable=1; zh_x=x-10'd32; zh_y=y-10'd464;
                zh_label=TXT_130; ink=MUTED;
            end
            else if (x >= 320 && x < 576 && y >= 464 && y < 480) begin
                zh_enable=1; zh_x=x-10'd320; zh_y=y-10'd464;
                zh_label=TXT_131; ink=MUTED;
            end
        end

        if(UI_ENABLE && !test_active && ui_page==0) begin
            if(x>=32 && x<288 && y>=448 && y<464) begin
                zh_enable=1;zh_x=x-10'd32;zh_y=y-10'd448;zh_label=TXT_132;ink=TEXT;
            end
            else if(x>=320 && x<576 && y>=448 && y<464) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd448;zh_label=TXT_133;ink=TEXT;
            end
            else if(x>=320 && x<576 && y>=464 && y<480) begin
                zh_enable=1;zh_x=x-10'd320;zh_y=y-10'd464;zh_label=TXT_134;ink=MUTED;
            end
        end
        // 两套文字共享字段墨色，但中文只在独立矩形范围内显示。
        // 8px宽半字符地址：一汉字由左右两个半字组成，没有UTF8硬件解析。
        if(zh_enable) begin
            zh_index=zh_x[7:3];
            zh_character=zh_label[287-({4'd0,zh_index,3'b000}+{7'd0,zh_index}) -: 9];
            if(zh_kind==2) begin // 进度 00/00
                number_value=zh_index>=8 ? {3'd0,guide_total} : {3'd0,guide_step};
                zh_digit_start=zh_index>=8 ? 8 : 5; zh_digit_count=2;
            end
            digits=decimal_bcd(number_value);
            if(zh_digit_count!=0 && zh_index>=zh_digit_start && zh_index<zh_digit_start+zh_digit_count) begin
                if(zh_digit_count==3 && zh_index==zh_digit_start) zh_character={1'b0,hex_ascii(digits[11:8])};
                else if(zh_digit_count>=2 && zh_index==zh_digit_start+zh_digit_count-2)
                    zh_character={1'b0,hex_ascii(digits[7:4])};
                else zh_character={1'b0,hex_ascii(digits[3:0])};
            end
            if(zh_kind==1) begin // 当前 ---- 0000Hz；无有效音符时只保留----。
                if(zh_index>=5 && zh_index<=8 && note_valid)
                    zh_character=(selected_note >> {(5'd8-zh_index),3'b000}) & 9'h0ff;
                if(zh_index>=10 && zh_index<=13) begin
                    frequency_digit=frequency_bcd >> {(5'd13-zh_index),2'b00};
                    zh_character={1'b0,(note_valid && frequency_digit<10) ? hex_ascii(frequency_digit) : 8'h2d};
                end
            end
            if(zh_kind==3) begin // 当前 -- 下一个 --
                if(zh_index==5) zh_character={1'b0,guided ? current_pad[15:8] : 8'h2d};
                if(zh_index==6) zh_character={1'b0,guided ? current_pad[7:0] : 8'h2d};
                if(zh_index==15) zh_character={1'b0,guided ? next_pad[15:8] : 8'h2d};
                if(zh_index==16) zh_character={1'b0,guided ? next_pad[7:0] : 8'h2d};
            end
            if(zh_kind==4 && zh_index>=5 && zh_index<=8) begin
                test_frequency_digits=test_frequency_bcd(test_index);
                zh_character={1'b0,hex_ascii((test_frequency_digits >> {(5'd8-zh_index),2'b00}) & 4'hf)};
            end
            if(zh_kind==5 && zh_index>=7 && zh_index<=10)
                zh_character={1'b0,hex_ascii((diagnostic_keys >> {(5'd10-zh_index),2'b00}) & 4'hf)};
            font_address={zh_character,zh_y[3:0]};
        end
    end
endmodule
