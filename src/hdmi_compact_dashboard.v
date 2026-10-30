`include "src/piano_layout.vh"
// V034：三种演奏模式、面板短按/长按说明及底部独立按键状态。
// 生产固定control_page=2，旋钮为Delay/Chorus/Reverb强度及总音量。
// 精简生产HDMI渲染器，固定640x480。全部输入属于pixel_clk域，由父层在帧边界快照。
// rst_n异步低有效；de=0、x>=640或y>=480的输入像素，在同样两级延迟后输出纯黑。
// 字符ROM2048x9：64条共享文本、每条32个8x16半字符单元；中文继续占两个单元。
// 文本常量仅在initial初始化ROM时展开，不在像素路径传288位整行选择器。
// 逐像素只选择6位行号和5位列号，同步读字符后再读原hdmi_ui_font，不扩中文字库。
// 两级流水：第一级锁存字符/数字覆盖/背景/字色/行列偏移，第二级锁存字体对应背景。
// 输出RGB为第二级有效像素；父层DE/HS/VS须跟随两拍，含波形RAM和RGB寄存共四拍。
// 页面ui_page=0演奏、1曲库、2帮助、3诊断；test_active优先于所有页面显示32路测试。
// ui_cursor=0..2选择菜单行；ui_song=0..2；keys[11:0]+ui_controls[3:0]仅用于显示。
// control_page=0 MAIN、1 ADSR、2 FX，knob_values低到高每8位对应K1..K4参数目标0..255。
// MAIN为音量/旋律鼓平衡/基础亮度/干湿；ADSR为A/D/S/R；FX为时间/反馈/调制/干湿。
// strum_mode=0键盘、1扫弦、2混合；fx_mode为主层效果状态(0..3)，本模块不修改控制值。
// flags沿用父层：[7]溢出/削波警报、[5]ADC、[2]滤波、[0]数字静音；只显示数字状态。
// note为MIDI数字音符，frequency_bcd是四位BCD，note_valid=0或BCD非法时显示横线。
// 音量/峰值为数字PCM百分比，level_dbfs为有符号数字dBFS，不表示模拟声压测量。
// 测试requested为请求路数，voices为实际busy计数；gate/busy分别显示完整32位掩码。
// test_index为0..31；test_sweep/overrun分别显示扫频状态和超时，不把请求数当实测数。
// 波形保持旧坐标和采样地址：x32..543每两像素一采样，y144..279，中线212，限幅60。
// 普通演奏页与测试页绘制波形；无有效波形保留网格，测试页另外标PCM: WAIT。
// 文本区域左x32..287/右x320..575；y=16+32*band，band0..14，每行高度16。
// 新像素oracle和旧截图适用范围详见assets/menu_layout.json的compact节。
// 这里只做显示，无音源、触摸采样、事件发送或实际HDMI物理链路判断。
// Compact 640x480 renderer. One 2048x9 synchronous character ROM shared by all
// pages, then the existing 8192x8 hdmi_ui_font. Exactly TWO pixel clock stages.
// No old column decoder or 5x7 font. The parent delays DE/HS/VS by two stages.
// Input status is a coherent frame snapshot. Wave window/address are unchanged:
// x=32..543 uses floor((x-32)/2); y=144..279, centre212, clamp +/-60.
// control_page 0/1/2 = MAIN/ADSR/FX. knob_values[7:0]=K1,...,[31:24]=K4.
// flags use the existing parent contract: [7]alert,[5]ADC,[2]filter,[0]zero.
module hdmi_compact_dashboard #(parameter PIANO_ROLL_ENABLE=0)(
    input pixel_clk,input rst_n,input [9:0] x,y,input de,
    input [11:0] keys,input [3:0] timbre,input [6:0] note,input note_valid,
    input [15:0] frequency_bcd,input [7:0] volume_percent,
    input signed [7:0] level_dbfs,input [7:0] peak_percent,
    input [5:0] voices,input [7:0] flags,
    input [11:0] cue_mask,next_mask,wrong_mask,
    input [5:0] guide_step,guide_total,
    input signed [15:0] wave_current,wave_previous,input [3:0] scope_gain,input wave_valid,
    input test_active,input [5:0] test_requested,input [31:0] test_busy,test_gate,
    input test_sweep,input [4:0] test_index,input test_overrun,
    input [1:0] ui_page,ui_cursor,ui_song,input [3:0] ui_controls,
    input [1:0] control_page,fx_mode,input [1:0] strum_mode,input [31:0] knob_values,
    output wire [7:0] red,green,blue,
    input [31:0] piano_keys,input piano_outside,
    input [11:0] roll_tick,input [1:0] roll_song,input roll_active,roll_done
);
    localparam [23:0] BG=24'h0b101c,PANEL=24'h172338,BORDER=24'h34465f,
        GRID=24'h22324a,TEXT=24'he2e8f0,CYAN=24'h51d6e8,
        GREEN=24'h21c6a8,AMBER=24'hf4bb4f,ALERT=24'hff5964;
    `include "src/hdmi_ui_text.vh"
    localparam [5:0] NAV=1,PAGES=2,PLAY=3,TONES=4,MODE_KEY=10,MODE_STRUM=11,
        ADSR_K=12,FX_K=13,KNOBS=14,FX_STATE=15,FLUTE=16,PLUCK=17,
        NOTE=18,METERS=19,VOICES=20,SONG=21,START=22,TOUCH=23,MUSICAL=24,
        WIRING=25,KEYS=26,HW=27,REQUEST=28,GATE=29,BUSY=30,
        COUNTS=31,SWEEP_KEYS=32,SWEEP=33,WAIT_WAVE=34,WAVE=35,
        MAIN=36,ADSR=37,FX=38,SELECT=39,CONFIRM=40,CUE=41,SELECT_SONG=42,
        LIVE_TITLE=43,LIB_TITLE=44,HELP_TITLE=45,DIAG_TITLE=46,TEST_TITLE=47,
        SONG0=48,SONG1=49,SONG2=50,MAIN_K=51,FX_LEGEND=52,
        ROLL_PLAY=53,ROLL_PAUSE=54,ROLL_DONE=55;
    function [287:0] ascii_row;
        input [255:0] message;
        integer cell_index;
        begin
            for(cell_index=0;cell_index<32;cell_index=cell_index+1)
                ascii_row[287-cell_index*9 -: 9]={1'b0,message[255-cell_index*8 -: 8]};
        end
    endfunction
    localparam [5:0] BUTTON_STATES=56, LIVE_NAV1=57, LIVE_NAV2=58,
        MODE_HYBRID=59,HOLD_TIMBRE=60,HOLD_MODE=61,HOLD_RELEASE=62;
    // Shared row selection for LIVE/LIBRARY/HELP/DIAGNOSTIC/OSC headers.
    // One-bit legacy callers zero-extend to KEY or STRUM automatically.
    wire [5:0] mode_row=strum_mode==2'd2 ? MODE_HYBRID :
        (strum_mode==2'd1 ? MODE_STRUM : MODE_KEY);
    // 初始化专用的宽行常量：综合时应映射常量ROM，像素路径不调用此函数。
    // Wide constants are used only to initialize storage, never as a pixel mux.
    function [287:0] initial_row;
        input integer index;
        begin
            case(index)
                1:initial_row=TXT_COMPACT_00; 2:initial_row=TXT_COMPACT_01;
                3:initial_row=TXT_COMPACT_02; 4:initial_row=TXT_COMPACT_03;
                5:initial_row=TXT_COMPACT_04; 6:initial_row=TXT_COMPACT_05;
                7:initial_row=TXT_COMPACT_06; 8:initial_row=TXT_COMPACT_07;
                9:initial_row=TXT_COMPACT_08; 10:initial_row=TXT_COMPACT_09;
                11:initial_row=TXT_COMPACT_10;12:initial_row=TXT_COMPACT_11;
                13:initial_row=TXT_COMPACT_12;14:initial_row=TXT_COMPACT_13;
                15:initial_row=TXT_COMPACT_14;16:initial_row=TXT_COMPACT_15;
                17:initial_row=TXT_COMPACT_16;18:initial_row=TXT_COMPACT_17;
                19:initial_row=TXT_COMPACT_18;20:initial_row=TXT_COMPACT_19;
                21:initial_row=TXT_COMPACT_20;22:initial_row=TXT_COMPACT_21;
                23:initial_row=TXT_COMPACT_22;24:initial_row=TXT_COMPACT_23;
                25:initial_row=TXT_COMPACT_24;26:initial_row=TXT_COMPACT_25;
                27:initial_row=TXT_COMPACT_26;28:initial_row=TXT_COMPACT_27;
                29:initial_row=TXT_COMPACT_28;30:initial_row=TXT_COMPACT_29;
                31:initial_row=TXT_COMPACT_30;32:initial_row=TXT_COMPACT_31;
                33:initial_row=TXT_COMPACT_32;34:initial_row=TXT_COMPACT_33;
                35:initial_row=TXT_COMPACT_34;36:initial_row=TXT_COMPACT_35;
                37:initial_row=TXT_COMPACT_36;38:initial_row=TXT_COMPACT_37;
                39:initial_row=TXT_COMPACT_38;40:initial_row=TXT_COMPACT_39;
                41:initial_row=TXT_COMPACT_40;42:initial_row=TXT_COMPACT_41;
                43:initial_row=TXT_111;44:initial_row=TXT_020;45:initial_row=TXT_033;
                46:initial_row=TXT_065;47:initial_row=TXT_044;
                48:initial_row=TXT_022;49:initial_row=TXT_024;50:initial_row=TXT_026;
                51:initial_row=TXT_COMPACT_42;52:initial_row=TXT_COMPACT_43;
                53:initial_row=PIANO_ROLL_ENABLE ? ascii_row("PLAY    120 BPM    64 px/beat   ") : TXT_000;
                54:initial_row=PIANO_ROLL_ENABLE ? ascii_row("PAUSE   120 BPM    64 px/beat   ") : TXT_000;
                55:initial_row=PIANO_ROLL_ENABLE ? ascii_row("DONE    120 BPM    64 px/beat   ") : TXT_000;
                56:initial_row=TXT_BUTTON_STATES;
                57:initial_row=ascii_row("1 PAGE  2 PLAY/PAUSE            ");
                58:initial_row=ascii_row("3 RESTART  4 SONG               ");
                59:initial_row=TXT_MODE_HYBRID;
                60:initial_row=TXT_HOLD_TIMBRE;
                61:initial_row=TXT_HOLD_MODE;
                62:initial_row=TXT_HOLD_RELEASE;
                default:initial_row=TXT_000;
            endcase
        end
    endfunction
    reg [8:0] character_rom[0:2047] /* synthesis syn_romstyle = "block_rom" */;
    integer ri,ci;
    reg [287:0] init_text;
    initial begin
        for(ri=0;ri<64;ri=ri+1)begin
            init_text=initial_row(ri);
            for(ci=0;ci<32;ci=ci+1)character_rom[ri*32+ci]=init_text[287-ci*9 -: 9];
        end
    end
    // 所有数字窗口共用一个8位转BCD单元；移位加3，避免逐像素除法/取模。
    function [11:0] bcd8;
        input [7:0] value;
        integer bit_index;
        reg [11:0] v;
        begin
            v=0;
            for(bit_index=7;bit_index>=0;bit_index=bit_index-1)begin
                if(v[3:0]>=5)v[3:0]=v[3:0]+3;
                if(v[7:4]>=5)v[7:4]=v[7:4]+3;
                if(v[11:8]>=5)v[11:8]=v[11:8]+3;
                v={v[10:0],value[bit_index]};
            end
            bcd8=v;
        end
    endfunction
    function [8:0] hex_char;
        input [3:0] v;
        begin hex_char=v<10 ? 9'd48+v : 9'd55+v;end
    endfunction
    // Full MIDI0..127 note spelling; bounded subtracts, no pixel-path / or %.
    // Natural notes are C4, sharps C#4; MIDI0..11 retain the negative octave.
    function [8:0] note_char;
        input [6:0] midi;
        input [1:0] position;
        reg [3:0] oct,pc;
        reg [6:0] base;
        reg [8:0] letter,octchar;
        reg sharp,negative;
        begin
            if(midi>=120)begin oct=9;base=120;end
            else if(midi>=108)begin oct=8;base=108;end
            else if(midi>=96)begin oct=7;base=96;end
            else if(midi>=84)begin oct=6;base=84;end
            else if(midi>=72)begin oct=5;base=72;end
            else if(midi>=60)begin oct=4;base=60;end
            else if(midi>=48)begin oct=3;base=48;end
            else if(midi>=36)begin oct=2;base=36;end
            else if(midi>=24)begin oct=1;base=24;end
            else if(midi>=12)begin oct=0;base=12;end
            else begin oct=0;base=0;end
            pc=midi-base;negative=midi<12;octchar=9'd48+oct;
            sharp=pc==1 || pc==3 || pc==6 || pc==8 || pc==10;
            case(pc)
                0,1:letter="C";2,3:letter="D";4:letter="E";
                5,6:letter="F";7,8:letter="G";9,10:letter="A";
                default:letter="B";
            endcase
            case(position)
                0:note_char=letter;
                1:note_char=sharp ? 9'd35 : (negative ? 9'd45 : octchar);
                2:note_char=sharp ? (negative ? 9'd45 : octchar) : (negative ? 9'd49 : 9'd32);
                default:note_char=sharp && negative ? 9'd49 : 9'd32;
            endcase
        end
    endfunction
    function [9:0] sample_y;
        input signed [15:0] sample;
        input [3:0] gain;
        reg signed [21:0] displacement;
        begin
            displacement={{6{sample[15]}},sample};
            if(gain<=9)displacement=displacement >>> (9-gain);
            else displacement=displacement <<< (gain-9);
            if(displacement>60)sample_y=152;
            else if(displacement< -60)sample_y=272;
            else sample_y=10'd212-displacement[9:0];
        end
    endfunction
    wire visible=de && x<640 && y<480;
    wire piano_live=PIANO_ROLL_ENABLE && !test_active && ui_page==0;
    wire right_side=x>=320;
    wire [9:0] local_x=right_side ? x-10'd320 : x-10'd32;
    // FX rows occupy416..463; dedicated KEY status row464..479 uses normal origin.
    // Keep piano through400 clear and prevent band14 from falling outside480 lines.
    wire [9:0] local_y=(piano_live && y>=416 && y<464) ? y-10'd32 : y-10'd16;
    wire text_window=visible && y>=16 && !local_y[4] &&
        ((x>=32 && x<288) || (x>=320 && x<576));
    wire [3:0] band=local_y[8:5];
    wire [4:0] column=local_x[7:3];
    wire [15:0] all_keys={ui_controls,keys};
    wire [5:0] selected_song=ui_song<3 ? SONG0+{4'd0,ui_song} : SONG0;
    reg [5:0] row_id;
    reg [23:0] background,ink;
    reg [9:0] wave0,wave1;
    reg [7:0] number;
    reg [1:0] digit;
    reg decimal_enable,override_enable;
    reg [8:0] override_char;
    reg [3:0] nibble;
    reg [11:0] bcd;
    // F2 and each following C: 19 white keys start F,G,A,B,C...
    // Constant octave math elaborates away; labels share the held/roll window.
    wire piano_label=piano_live && y>=380 && y<396 &&
        ((x>=44 && x<60) || (x>=164 && x<180) ||
         (x>=374 && x<390) || (x>=584 && x<600));
    wire [9:0] label_x=x<60 ? x-10'd44 : (x<180 ? x-10'd164 :
        (x<390 ? x-10'd374 : x-10'd584));
    localparam [8:0] FIRST_OCTAVE_CHAR=48+(`PIANO_BASE_NOTE/12)-1;
    wire [8:0] label_char=!label_x[3] ? (x<60 ? 9'd70 : 9'd67) :
        (x<60 ? FIRST_OCTAVE_CHAR : (x<180 ? FIRST_OCTAVE_CHAR+9'd1 :
        (x<390 ? FIRST_OCTAVE_CHAR+9'd2 : FIRST_OCTAVE_CHAR+9'd3)));
    wire [23:0] piano_rgb;
    wire piano_covered;
    generate if(PIANO_ROLL_ENABLE)begin:piano_panel
        piano_roll_renderer u_piano(.pixel_clk(pixel_clk),.rst_n(rst_n),.x(x),.y(y),
            .de(de && piano_live),.piano_keys(piano_keys),.piano_outside(piano_outside),
            .roll_tick(roll_tick),.roll_song(roll_song),.roll_active(roll_active),.roll_done(roll_done),
            .rgb(piano_rgb),.covered(piano_covered));
    end else begin:no_piano_panel
        assign piano_rgb=24'd0;assign piano_covered=1'b0;
    end endgenerate

    // 只选择当前窗口需要的一条共享文本；曲库游标用字色突出，不增加额外字体。
    always @* begin
        row_id=0;ink=TEXT;background=BG;
        wave0=sample_y(wave_previous,scope_gain);wave1=sample_y(wave_current,scope_gain);
        // Only LIVE and diagnostic ownership draw the scope. Never draw outside
        // its original address window, even for signed extremes and gain15.
        if(test_active || (ui_page==0 && !PIANO_ROLL_ENABLE) ||
            (PIANO_ROLL_ENABLE && ui_page==3))begin
            if(x>=31 && x<=544 && y>=143 && y<=280)begin
                background=BORDER;
                if(x>=32 && x<544 && y>=144 && y<280)begin
                    background=PANEL;
                    if(x[5:0]==32 || y==176 || y==248)background=GRID;
                    if(y==212)background=BORDER;
                    if(wave_valid && ((wave0<=wave1 && y>=wave0 && y<=wave1) ||
                                      (wave1< wave0 && y>=wave1 && y<=wave0)))background=CYAN;
                end
            end
        end
        if(text_window)begin
            if(test_active)begin
                case(band)
                    0:row_id=right_side ? mode_row : TEST_TITLE;
                    1:row_id=right_side ? SWEEP : REQUEST;
                    2:row_id=right_side ? BUSY : GATE;
                    3:row_id=right_side ? WAVE : METERS;
                    9:row_id=right_side ? SWEEP_KEYS : COUNTS;
                    10:row_id=right_side ? TOUCH : (wave_valid?WAVE:WAIT_WAVE);
                    11:row_id=right_side ? VOICES : REQUEST;
                    12:row_id=right_side ? BUSY : GATE;
                    13:row_id=right_side ? 9 : SWEEP_KEYS;
                    default:row_id=0;
                endcase
            end else begin
                case(ui_page)
                    0:case(band)
                        0:row_id=right_side ? mode_row : LIVE_TITLE;
                        1:row_id=right_side ? NOTE : (timbre==1?PLUCK:FLUTE);
                        2:row_id=right_side ? VOICES : METERS;
                        3:row_id=right_side ? CUE : SONG;
                        9:row_id=right_side ? FX_STATE : (control_page==1?ADSR:(control_page==2?FX:MAIN));
                        10:row_id=right_side ? KNOBS : (control_page==1?ADSR_K:(control_page==2?FX_K:MAIN_K));
                        11:row_id=right_side ? TONES : FX_LEGEND;
                        12:row_id=right_side ? TONES : PLAY;
                        13:row_id=right_side ? 6 : 5;
                        default:row_id=0;
                    endcase
                    1:case(band)
                        0:row_id=right_side ? mode_row : LIB_TITLE;
                        1:row_id=right_side ? selected_song : SELECT_SONG;
                        2:row_id=right_side ? 0 : SONG0;
                        3:row_id=right_side ? 0 : SONG1;
                        4:row_id=right_side ? 0 : SONG2;
                        5:row_id=right_side ? PLAY : START;
                        7:row_id=right_side ? FX_STATE : KNOBS;
                        9:row_id=right_side ? MUSICAL : TOUCH;
                        12:row_id=right_side ? 8 : 7;
                        13:row_id=right_side ? 9 : NAV;
                        default:row_id=0;
                    endcase
                    2:case(band)
                        0:row_id=right_side ? mode_row : HELP_TITLE;
                        1:row_id=right_side ? MUSICAL : TOUCH;
                        2:row_id=right_side ? PAGES : NAV;
                        3:row_id=right_side ? TONES : PLAY;
                        4:row_id=right_side ? 6 : 5;
                        5:row_id=right_side ? 8 : 7;
                        6:row_id=right_side ? WIRING : 9;
                        7:row_id=right_side ? KNOBS : FX_K;
                        8:row_id=right_side ? FX_STATE : KNOBS;
                        9:row_id=right_side ? SWEEP_KEYS : COUNTS;
                        10:row_id=right_side ? HOLD_MODE : HOLD_TIMBRE;
                        11:row_id=right_side ? TONES : HOLD_RELEASE;
                        13:row_id=right_side ? 9 : NAV;
                        default:row_id=0;
                    endcase
                    3:case(band)
                        0:row_id=right_side ? mode_row : DIAG_TITLE;
                        1:row_id=right_side ? KEYS : WIRING;
                        2:row_id=right_side ? VOICES : METERS;
                        3:row_id=right_side ? KNOBS : HW;
                        4:row_id=right_side ? BUSY : GATE;
                        5:row_id=right_side ? KNOBS : FX_K;
                        6:row_id=right_side ? FX_STATE : CUE;
                        7:row_id=right_side ? 0 : FX_LEGEND;
                        8:row_id=right_side ? MUSICAL : TOUCH;
                        10:row_id=right_side ? 8 : 7;
                        12:row_id=right_side ? 6 : 5;
                        13:row_id=right_side ? 9 : NAV;
                        default:row_id=0;
                    endcase
                endcase
            end
            if(piano_live)begin
                // Retain header/status; replace scope and old large settings.
                if(band==3 && right_side)row_id=roll_done ? ROLL_DONE : (roll_active ? ROLL_PLAY : ROLL_PAUSE);
                if(y>=144 && y<416)row_id=0;
                if(y>=416)case(band)
                    12:row_id=right_side ? FX_STATE : FX_K;
                    13:row_id=right_side ? KNOBS : LIVE_NAV1;
                    default:row_id=0;
                endcase
            end
            // 所有页面固定显示四个消抖后的真实按键状态，含下落谱页。
            if(band==14)row_id=right_side ? BUTTON_STATES : (piano_live ? LIVE_NAV2 : NAV);
            if(PIANO_ROLL_ENABLE && ui_page==3 && !test_active && y>=144 && y<288)row_id=0;
            if(band==0)ink=CYAN;
            if(ui_page==1 && !test_active && !right_side && band>=2 && band<=4 && band=={2'd0,ui_cursor}+2)
                ink=AMBER;
            if(ui_page==0 && !test_active && band==11 && !right_side)ink=AMBER;
            if(row_id==REQUEST || row_id==GATE || row_id==BUSY)ink=GREEN;
            if((row_id==SWEEP && test_overrun) || (row_id==VOICES && flags[7]))ink=ALERT;
        end

        // A single decimal converter shared by all numeric cells. Hex masks use
        // one selected nibble; no per-label converters or wide text shifting.
        number=0;digit=0;decimal_enable=0;override_enable=0;override_char=32;nibble=0;bcd=0;
        case(row_id)
            // 这里只观察四路消抖状态；两位一起变1可见，不修改多键取消规则。
            // KEY1..KEY4为面板键，MIDI旋钮仍用K1..K4，不混淆二者。
            BUTTON_STATES:begin
                case(column)
                    5:begin override_enable=1;override_char=9'd48+ui_controls[0];end
                    12:begin override_enable=1;override_char=9'd48+ui_controls[1];end
                    19:begin override_enable=1;override_char=9'd48+ui_controls[2];end
                    26:begin override_enable=1;override_char=9'd48+ui_controls[3];end
                    default:begin end
                endcase
            end
            KNOBS:begin
                if(column>=3 && column<=5)begin number=knob_values[7:0];digit=5-column;decimal_enable=1;end
                if(column>=10 && column<=12)begin number=knob_values[15:8];digit=12-column;decimal_enable=1;end
                if(column>=17 && column<=19)begin number=knob_values[23:16];digit=19-column;decimal_enable=1;end
                if(column>=24 && column<=26)begin number=knob_values[31:24];digit=26-column;decimal_enable=1;end
            end
            FX_STATE:begin
                if(column==8)begin override_enable=1;override_char=9'd48+fx_mode;end
                if(column==17)begin override_enable=1;override_char=9'd48+flags[2];end
                if(column==24)begin override_enable=1;override_char=9'd48+flags[0];end
            end
            NOTE:begin
                if(PIANO_ROLL_ENABLE && column>=5 && column<=8)begin
                    override_enable=1;
                    override_char=note_valid ? note_char(note,column-5) : 9'd45;
                end else if(column>=5 && column<=7)begin
                    if(note_valid)begin number={1'b0,note};digit=7-column;decimal_enable=1;end
                    else begin override_enable=1;override_char="-";end
                end
                if(column>=14 && column<=17)begin
                    nibble=frequency_bcd[(17-column)*4 +: 4];override_enable=1;
                    override_char=note_valid && nibble<10 ? hex_char(nibble) : 9'd45;
                end
            end
            METERS:begin
                if(column>=4 && column<=6)begin number=volume_percent;digit=6-column;decimal_enable=1;end
                if(column==13)begin override_enable=1;override_char=level_dbfs[7]?9'd45:9'd43;end
                if(column>=14 && column<=16)begin
                    number=level_dbfs[7] ? (~level_dbfs+8'd1) : level_dbfs;digit=16-column;decimal_enable=1;
                end
                if(column>=25 && column<=27)begin number=peak_percent;digit=27-column;decimal_enable=1;end
            end
            VOICES:begin
                if(column>=7 && column<=8)begin number={2'd0,voices};digit=8-column;decimal_enable=1;end
                if(column==18 || column==19)begin
                    override_enable=1;override_char=hex_char(column==18 ? flags[7:4] : flags[3:0]);
                end
            end
            SONG:begin
                if(column==5)begin override_enable=1;override_char=9'd49+ui_song;end
                if(column>=12 && column<=13)begin number={2'd0,guide_step};digit=13-column;decimal_enable=1;end
                if(column>=15 && column<=16)begin number={2'd0,guide_total};digit=16-column;decimal_enable=1;end
            end
            KEYS:if(column>=7 && column<=10)begin
                override_enable=1;override_char=hex_char(all_keys[(10-column)*4 +: 4]);
            end
            HW:begin
                if(column==7)begin override_enable=1;override_char=9'd48+flags[2];end
                if(column==14)begin override_enable=1;override_char=9'd48+flags[0];end
                if(column==20)begin override_enable=1;override_char=9'd48+flags[5];end
            end
            REQUEST:begin
                if(column>=8 && column<=9)begin number={2'd0,test_requested};digit=9-column;decimal_enable=1;end
                if(column>=18 && column<=19)begin number={2'd0,voices};digit=19-column;decimal_enable=1;end
                if(column>=27 && column<=28)begin number={3'd0,test_index};digit=28-column;decimal_enable=1;end
            end
            GATE,BUSY:if(column>=7 && column<=14)begin
                override_enable=1;
                if(row_id==GATE)nibble=test_gate[(14-column)*4 +: 4];
                else nibble=test_busy[(14-column)*4 +: 4];
                override_char=hex_char(nibble);
            end
            SWEEP:begin
                if(column==6)begin override_enable=1;override_char=9'd48+test_sweep;end
                if(column==16)begin override_enable=1;override_char=9'd48+test_overrun;end
            end
            WAVE:if(column>=12 && column<=13)begin number={4'd0,scope_gain};digit=13-column;decimal_enable=1;end
            CUE:begin
                if(column>=6 && column<=8)begin override_enable=1;override_char=hex_char(cue_mask[(8-column)*4 +: 4]);end
                if(column>=17 && column<=19)begin override_enable=1;override_char=hex_char(next_mask[(19-column)*4 +: 4]);end
                if(column>=27 && column<=29)begin override_enable=1;override_char=hex_char(wrong_mask[(29-column)*4 +: 4]);end
            end
            default:begin end
        endcase
        bcd=bcd8(number);
        if(decimal_enable)begin
            override_enable=1;
            case(digit)
                2:override_char=hex_char(bcd[11:8]);
                1:override_char=hex_char(bcd[7:4]);
                default:override_char=hex_char(bcd[3:0]);
            endcase
        end
    end

    reg [8:0] rom_character,override0;
    reg override_valid0,text0,visible0,text1,visible1;
    reg [3:0] font_row0;
    reg [2:0] font_x0,font_x1;
    reg [23:0] background0,ink0,background1,ink1;
    // 字符ROM常开同步读取；复位/可见性走旁路有效位，避免给ROM本体增加复位端口。
    // 数字覆盖字符也延迟一拍，不能直接接当前像素的组合数字，否则会与字体错位。
    // Character ROM is always clocked; validity is carried separately.
    always @(posedge pixel_clk)rom_character<=character_rom[{row_id,column}];
    wire [8:0] glyph=override_valid0 ? override0 : rom_character;
    wire [7:0] font_bits;
    hdmi_ui_font u_font(pixel_clk,{glyph,font_row0},font_bits);
    always @(posedge pixel_clk or negedge rst_n)begin
        if(!rst_n)begin
            override0<=32;override_valid0<=0;text0<=0;visible0<=0;font_row0<=0;font_x0<=0;
            background0<=0;ink0<=0;text1<=0;visible1<=0;font_x1<=0;background1<=0;ink1<=0;
        end else begin
            override0<=piano_label ? label_char : override_char;
            override_valid0<=piano_label || override_enable;
            text0<=piano_label || (text_window && row_id!=0);visible0<=visible;
            font_row0<=piano_label ? y-10'd380 : local_y[3:0];
            font_x0<=piano_label ? label_x[2:0] : local_x[2:0];
            background0<=background;ink0<=piano_label ? 24'h172338 : ink;
            text1<=text0;visible1<=visible0;font_x1<=font_x0;background1<=background0;ink1<=ink0;
        end
    end
    wire [23:0] rgb=visible1 ? ((text1 && font_bits[7-font_x1]) ? ink1 :
        (piano_covered ? piano_rgb : background1)) : 24'd0;
    assign {red,green,blue}=rgb;
endmodule
