// Stateless 640x480 renderer, Verilog-2001. The parent owns clocks, CDC,
// telemetry snapshots and wave RAM. No clock, frame store or per-pixel divide.
// wave_current/previous must match floor((x-32)/2) for x=32..543.
module hdmi_baseline_dashboard(
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
    output reg [7:0] red, green, blue
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

    function [127:0] timbre_name;
        input [3:0] value;
        begin
            case (value)
                0:  timbre_name = "SINE            ";
                1:  timbre_name = "SOFT FLUTE      ";
                2:  timbre_name = "WOODWIND        ";
                3:  timbre_name = "WARM ORGAN      ";
                4:  timbre_name = "HOLLOW PIPE     ";
                5:  timbre_name = "SOFT BRASS      ";
                6:  timbre_name = "MALLET          ";
                7:  timbre_name = "PLUCK           ";
                8:  timbre_name = "SOFT STRINGS    ";
                9:  timbre_name = "REED            ";
                10: timbre_name = "BRIGHT ORGAN    ";
                11: timbre_name = "CHIME           ";
                12: timbre_name = "HARMONICA       ";
                13: timbre_name = "FAT SYNTH       ";
                14: timbre_name = "METAL           ";
                15: timbre_name = "BRIGHT SYNTH    ";
                default: timbre_name = "UNKNOWN         ";
            endcase
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

    reg [23:0] pixel, ink, key_fill, flag_ink, progress_ink;
    reg [255:0] label_text;
    reg text_enable, small_text, key_note_text, guided, guide_wrong, guide_hold;
    reg [9:0] text_x, text_y, key_x, key_y, scope_x;
    reg [9:0] wave_y0, wave_y1, wave_top, wave_bottom;
    reg [3:0] key_index;
    reg [4:0] character_index, digit_start;
    reg [2:0] glyph_x, glyph_y, digit_count, flag_index;
    reg [7:0] character;
    reg [8:0] number_value;
    reg [11:0] digits;
    reg [4:0] glyph;
    reg [15:0] key_name;
    reg [1:0] text_kind;
    localparam [1:0] ORDINARY = 0, NOTE_TEXT = 2, STEP_TEXT = 3;

    always @* begin
        pixel = BACKGROUND;
        ink = TEXT;
        key_fill = PANEL;
        flag_ink = MUTED;
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
        flag_index = 0;
        character = " ";
        number_value = 0;
        digits = 0;
        glyph = 0;
        key_name = "--";
        text_kind = ORDINARY;
        wave_y0 = sample_y(wave_previous,scope_gain);
        wave_y1 = sample_y(wave_current,scope_gain);
        wave_top = wave_y0 < wave_y1 ? wave_y0 : wave_y1;
        wave_bottom = wave_y0 > wave_y1 ? wave_y0 : wave_y1;

        // Border is outside the specified sample rectangle, so both pixels
        // of samples 0 and 255 remain visible, including x=32 and x=543.
        if (x >= 31 && x <= 544 && y >= 143 && y <= 280) begin
            pixel = BORDER;
            if (x >= 32 && x <= 543 && y >= 144 && y <= 279) begin
                pixel = PANEL;
                if (scope_x[5:0] == 0 || y == 176 || y == 248) pixel = GRID;
                if (y == 212) pixel = BORDER;
                if (wave_valid && y >= wave_top && y <= wave_bottom) pixel = CYAN;
            end
        end

        // Physical row-major layout: 4 columns, 3 rows, 64x48 slots.
        // Each card is 56x40. The row decode uses compares, not division.
        if (x >= 32 && x < 288 && y >= 296 && y < 432) begin
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

        if (x >= 304 && x <= 560 && y >= 374 && y <= 389) begin
            pixel = PANEL;
            if (guide_done) progress_ink = GREEN;
            else if (guide_wrong) progress_ink = ALERT;
            else if (guide_hold) progress_ink = GREEN;
            if (guide_done || (guided && (x - 10'd305) < {2'd0,beat_progress}))
                pixel = progress_ink;
            if (x == 304 || x == 560 || y == 374 || y == 389) pixel = BORDER;
        end

        // Select one text region before the common glyph/digit mux.
        if (x >= 32 && x < 632) begin
            if (y >= 16 && y < 30) begin
                text_enable = 1; text_y = y - 10'd16;
                if (x < 320) begin
                    label_text = "LIVE INSTRUMENT                 ";
                    text_x = x - 10'd32; ink = CYAN;
                end else if (x >= 368) begin
                    text_x = x - 10'd368;
                    if (guide_done) begin label_text = "FINISHED                        "; ink = GREEN; end
                    else if (guided) begin label_text = "TWINKLE GUIDE                   "; ink = AMBER; end
                    else begin label_text = "FREE PLAY                       "; ink = CYAN; end
                end else text_enable = 0;
            end else if (y >= 40 && y < 54) begin
                label_text = {"TIMBRE 00 ",timbre_name(timbre),"      "};
                text_enable = 1; text_x = x - 10'd32; text_y = y - 10'd40;
                number_value = {5'd0,timbre}; digit_start = 7; digit_count = 2;
            end else if (y >= 64 && y < 78) begin
                text_enable = 1; text_y = y - 10'd64;
                if (x < 208) begin
                    label_text = "VOLUME 000%                     ";
                    text_x = x - 10'd32; number_value = {1'b0,volume_percent};
                    digit_start = 7; digit_count = 3;
                end else if (x >= 224 && x < 432) begin
                    label_text = level_dbfs[7] ? "RMS -000 DBFS                   " : "RMS +000 DBFS                   ";
                    text_x = x - 10'd224;
                    number_value = level_dbfs[7] ? {1'b0,(~level_dbfs + 8'd1)} : {1'b0,level_dbfs};
                    digit_start = 5; digit_count = 3;
                end else if (x >= 448) begin
                    label_text = "PEAK 000%                       ";
                    text_x = x - 10'd448; number_value = {1'b0,peak_percent};
                    digit_start = 5; digit_count = 3;
                end else text_enable = 0;
            end else if (y >= 88 && y < 102) begin
                text_enable = 1; text_y = y - 10'd88;
                if (x < 336) begin
                    label_text = "NOTE ---- HZ ----               ";
                    text_x = x - 10'd32; text_kind = NOTE_TEXT;
                end else if (x >= 384) begin
                    label_text = pitch[8] ? "PITCH -000                      " : "PITCH +000                      ";
                    text_x = x - 10'd384;
                    number_value = pitch[8] ? (~pitch + 9'd1) : pitch;
                    digit_start = 7; digit_count = 3;
                end else text_enable = 0;
            end else if (y >= 112 && y < 119) begin
                text_enable = 1; small_text = 1; text_y = y - 10'd112;
                if (x < 240) begin
                    label_text = "LOWEST HELD MELODY SETTING      ";
                    text_x = x - 10'd32; ink = MUTED;
                end else if (x >= 256 && x < 336) begin
                    label_text = "VOICES 00                       ";
                    text_x = x - 10'd256; number_value = {3'd0,voices};
                    digit_start = 7; digit_count = 2;
                end else if (x >= 352 && x < 416) begin
                    label_text = "PAD0 000                        ";
                    text_x = x - 10'd352; number_value = {1'b0,pressure0};
                    digit_start = 5; digit_count = 3;
                end else if (x >= 432 && x < 496) begin
                    label_text = "PAD1 000                        ";
                    text_x = x - 10'd432; number_value = {1'b0,pressure1};
                    digit_start = 5; digit_count = 3;
                end else text_enable = 0;
            end else if (y >= 128 && y < 135) begin
                text_enable = 1; small_text = 1; text_y = y - 10'd128;
                if (x < 304) begin
                    label_text = "LIVE PCM  GAIN 2^00             ";
                    text_x = x - 10'd32; ink = CYAN;
                    number_value = {5'd0,scope_gain}; digit_start = 17; digit_count = 2;
                end else if (x >= 552) begin
                    label_text = {"FLAGS ",hex_ascii(flags[7:4]),hex_ascii(flags[3:0]),"                        "};
                    text_x = x - 10'd552; ink = MUTED;
                end else text_enable = 0;
            end else if (!wave_valid && x >= 256 && x < 320 && y >= 204 && y < 218) begin
                label_text = "WAIT                            ";
                text_enable = 1; text_x = x - 10'd256; text_y = y - 10'd204; ink = AMBER;
            end else if (x >= 552 && y >= 144 && y < 272) begin
                flag_index = 3'd7 - ((y - 10'd144) >> 4);
                case (flag_index)
                    7: begin label_text = "ALERT/CLIP                      "; flag_ink = ALERT; end
                    6: begin label_text = "GHOST                           "; flag_ink = AMBER; end
                    5: begin label_text = "ADC RDY                         "; flag_ink = GREEN; end
                    4: begin label_text = "STALE                           "; flag_ink = AMBER; end
                    3: begin label_text = "FAULT                           "; flag_ink = ALERT; end
                    2: begin label_text = "FILTER                          "; flag_ink = CYAN; end
                    1: begin label_text = "REMOTE                          "; flag_ink = CYAN; end
                    0: begin label_text = "ZERO                            "; flag_ink = AMBER; end
                endcase
                text_y = (y - 10'd144) & 10'd15;
                text_enable = text_y < 7; small_text = 1;
                text_x = x - 10'd552; ink = flags[flag_index] ? flag_ink : MUTED;
            end else if (y >= 284 && y < 291) begin
                text_enable = 1; small_text = 1; text_y = y - 10'd284; ink = MUTED;
                if (x < 288) begin label_text = "KEYPAD S1-S12  4 COL X 3 ROW    "; text_x = x - 10'd32; end
                else if (x >= 304) begin label_text = "TWINKLE TRAINING / FREE PLAY    "; text_x = x - 10'd304; end
                else text_enable = 0;
            end else if (x >= 304) begin
                text_x = x - 10'd304;
                if (y >= 296 && y < 310) begin
                    label_text = "TWINKLE                         ";
                    text_enable = 1; text_y = y - 10'd296; ink = AMBER;
                end else if (y >= 320 && y < 334) begin
                    label_text = "STEP 00/00                      ";
                    text_enable = 1; text_y = y - 10'd320; text_kind = STEP_TEXT;
                end else if (y >= 344 && y < 358) begin
                    text_enable = 1; text_y = y - 10'd344;
                    if (x < 432) begin
                        label_text = "BEATS 0                         ";
                        number_value = {7'd0,target_beats}; digit_start = 6; digit_count = 1;
                    end else begin
                        text_x = x - 10'd432;
                        if (guide_done) begin label_text = "FINISHED                        "; ink = GREEN; end
                        else if (!guided) begin label_text = "FREE                            "; ink = CYAN; end
                        else if (guide_wrong) begin label_text = "WRONG                           "; ink = ALERT; end
                        else if (guide_hold) begin label_text = "HOLD                            "; ink = GREEN; end
                        else begin label_text = "WAIT                            "; ink = AMBER; end
                    end
                end else if (y >= 400 && y < 407) begin
                    label_text = {"PLAY ",(guided ? mask_name(cue_mask) : 16'h2d2d),
                                  "     NEXT ",(guided ? mask_name(next_mask) : 16'h2d2d),"             "};
                    text_enable = 1; small_text = 1; text_y = y - 10'd400;
                end else if (y >= 416 && y < 423) begin
                    label_text = "AMBER CUE  GREEN HIT  RED ERROR ";
                    text_enable = 1; small_text = 1; text_y = y - 10'd416; ink = MUTED;
                end else if (y >= 432 && y < 439) begin
                    label_text = "CYAN FREE   TRIANGLE NEXT       ";
                    text_enable = 1; small_text = 1; text_y = y - 10'd432; ink = MUTED;
                end
            end
        end
        if (x >= 32 && x < 608 && y >= 448 && y < 455) begin
            label_text = "S13+S16 GUIDE   S13+S14 RESTART ";
            text_enable = 1; small_text = 1;
            text_x = x - 10'd32; text_y = y - 10'd448; ink = TEXT;
        end
        if (x >= 32 && x < 608 && y >= 464 && y < 471) begin
            label_text = "DIGITAL RMS DBFS / LIVE MIX PCM ";
            text_enable = 1; small_text = 1;
            text_x = x - 10'd32; text_y = y - 10'd464; ink = MUTED;
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
                if (text_kind == STEP_TEXT) begin
                    number_value = character_index >= 8 ? {3'd0,guide_total} : {3'd0,guide_step};
                    digit_start = character_index >= 8 ? 8 : 5;
                    digit_count = 2;
                end
                digits = decimal_bcd(number_value);
                if (digit_count != 0 && character_index >= digit_start &&
                    character_index < (digit_start + digit_count)) begin
                    if (digit_count == 3 && character_index == digit_start) character = hex_ascii(digits[11:8]);
                    else if (digit_count >= 2 && character_index == (digit_start + digit_count - 1'b1 - 1'b1))
                        character = hex_ascii(digits[7:4]);
                    else character = hex_ascii(digits[3:0]);
                end
                if (key_note_text) character = character_index == 0 ? key_name[15:8] : key_name[7:0];
                if (text_kind == NOTE_TEXT && note_valid) begin
                    case (character_index)
                        5,6,7,8: character = midi_name(note) >> {(5'd8-character_index),3'b000};
                        13: character = frequency_bcd[15:12] < 10 ? hex_ascii(frequency_bcd[15:12]) : "-";
                        14: character = frequency_bcd[11:8] < 10 ? hex_ascii(frequency_bcd[11:8]) : "-";
                        15: character = frequency_bcd[7:4] < 10 ? hex_ascii(frequency_bcd[7:4]) : "-";
                        16: character = frequency_bcd[3:0] < 10 ? hex_ascii(frequency_bcd[3:0]) : "-";
                        default: begin end
                    endcase
                end
                glyph = font_row(character,glyph_y);
                if (glyph_x < 5 && glyph_y < 7 && glyph[3'd4-glyph_x]) pixel = ink;
            end
        end
        if (!de || x >= 640 || y >= 480) pixel = 24'h000000;
        red = pixel[23:16]; green = pixel[15:8]; blue = pixel[7:0];
    end
endmodule
